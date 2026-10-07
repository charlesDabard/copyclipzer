import AppKit
import SwiftUI

/// L'état du panneau de recherche, partagé entre l'assemblage et la vue. Les événements
/// sont des fermetures et non des `@Published`, même raison que `OverlayModel` : ce sont
/// des gestes, les publier redessinerait le panneau pour rien.
/// Une application proposée à l'exclusion dans le menu des réglages : son identifiant de
/// bundle (ce que `CapturePolicy` compare) et un nom lisible.
struct AppExcluable: Identifiable, Equatable {
    let id: String
    let nom: String
}

final class RechercheModel: ObservableObject {
    @Published var requete: String = ""
    @Published var lignes: [LigneDeMenu] = []
    @Published var index: Int = 0
    /// Le numéro de la dernière version publiée quand elle est plus récente que
    /// l'installée, nil sinon. Renseigné par le check de mise à jour au lancement ;
    /// le pied affiche une pastille discrète tant qu'il est non nil.
    @Published var majDisponible: String?

    /// Reflète l'état réel de l'ouverture au démarrage (élément d'ouverture de session),
    /// pour la bascule du menu de l'engrenage. Rafraîchi à chaque ouverture du panneau.
    @Published var ouvertureAuDemarrage: Bool = false

    // Les réglages passent par des types PRIMITIFS, et non par `Reglages`/`RaccourciGlobal` :
    // cette vue est symlinkée dans la cible Captures, qui n'a pas ces types. L'assemblage
    // (AppDelegate) traduit vers `Reglages` et rafraîchit ces champs à chaque ouverture.
    @Published var taillesPossibles: [Int] = []
    @Published var tailleHistorique: Int = 0
    /// Valeurs de rétention proposées, en jours ; 0 = désactivée.
    @Published var retentionsPossibles: [Int] = []
    @Published var retentionJours: Int = 0
    /// Libellés des raccourcis prédéfinis et l'index de celui qui est actif.
    @Published var raccourcisLibelles: [String] = []
    @Published var raccourciActif: Int = 0
    /// Les apps proposées à l'exclusion (en cours d'exécution ou déjà exclues) : identifiant
    /// de bundle et nom lisible. `appsExclues` porte les identifiants cochés.
    @Published var appsExcluables: [AppExcluable] = []
    @Published var appsExclues: Set<String> = []

    var onChoisirTaille: ((Int) -> Void)?
    var onChoisirRetention: ((Int) -> Void)?
    var onChoisirRaccourci: ((Int) -> Void)?
    var onBasculerApp: ((String) -> Void)?

    var onRequete: ((String) -> Void)?
    /// L'entrée validée, et si le collage doit se faire en TEXTE BRUT. Le second
    /// paramètre vient du geste clavier : Entrée colle normalement, Option+Entrée en
    /// texte brut, exactement comme la touche Z du geste Cmd maintenu.
    var onValider: ((String, Bool) -> Void)?
    var onEpingler: ((String) -> Void)?
    var onSupprimer: ((String) -> Void)?
    var onAction: ((String) -> Void)?
    var onFermer: (() -> Void)?
    var onToutSupprimer: (() -> Void)?
    var onSupprimerSaufEpingles: (() -> Void)?
    var onOuvrirMaj: (() -> Void)?
    var onBasculerDemarrage: (() -> Void)?
}

/// Le champ de recherche, en AppKit parce que SwiftUI sur macOS 13 ne sait pas
/// intercepter les flèches et Entrée dans un `TextField`. Le délégué fait les deux
/// seules choses qui comptent : refléter la frappe en direct, et transformer flèches,
/// Entrée et Échap en gestes de navigation au lieu de les laisser au champ.
///
/// C'est ce qui remplace le `NSMenu` : le champ vit dans un panneau clavier ordinaire,
/// donc rien ne le retire entre deux frappes et il ne perd jamais le focus. C'était la
/// cause exacte du bug « je tape une lettre puis je dois recliquer dans la barre ».
struct ChampDeRecherche: NSViewRepresentable {
    @Binding var texte: String
    var surChangement: (String) -> Void
    var surMonter: () -> Void
    var surDescendre: () -> Void
    var surValider: (Bool) -> Void
    var surFermer: () -> Void
    var enregistrerLeChamp: (NSSearchField) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let champ = NSSearchField()
        champ.delegate = context.coordinator
        champ.font = .systemFont(ofSize: 15)
        champ.placeholderString = l10n("recherche.placeholder", "Champ de recherche : texte indicatif")
        champ.focusRingType = .none
        champ.sendsWholeSearchString = false
        champ.sendsSearchStringImmediately = true
        enregistrerLeChamp(champ)
        return champ
    }

    func updateNSView(_ champ: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if champ.stringValue != texte {
            champ.stringValue = texte
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ChampDeRecherche
        init(_ parent: ChampDeRecherche) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let champ = notification.object as? NSSearchField else { return }
            parent.texte = champ.stringValue
            parent.surChangement(champ.stringValue)
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Entrée est le seul cas qui porte un modificateur utile : Option+Entrée
            // colle en texte brut, Entrée seule colle normalement. Le modificateur se
            // lit sur l'événement EN COURS, pas sur un état mémorisé, pour qu'un
            // relâchement d'Option avant la frappe ne laisse pas un drapeau en l'air.
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
                parent.surValider(option)
                return true
            }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.surDescendre(); return true
            case #selector(NSResponder.moveUp(_:)): parent.surMonter(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.surFermer(); return true
            default: return false
            }
        }
    }
}

/// Le panneau de recherche : barre en haut TOUJOURS visible, liste filtrée dessous, pied
/// d'actions. Mesures et matériau alignés sur `OverlayView` pour que les deux surfaces se
/// ressemblent. La logique pure (filtrage, ordre, libellés) reste dans `MenuFormat.swift`
/// et nourrit `model.lignes` : cette vue ne décide rien, elle dessine.
struct RechercheView: View {
    @ObservedObject var model: RechercheModel
    var enregistrerLeChamp: (NSSearchField) -> Void = { _ in }

    /// Vrai le temps d'un déplacement AU CLAVIER, pour que seul celui-là fasse défiler la
    /// liste. Le survol souris déplace aussi la sélection, mais défiler sur un survol ferait
    /// sauter la liste sous le curseur : on ne centre donc que sur les flèches.
    @State private var defilementClavier = false

    /// Dernière position connue du pointeur, en coordonnées d'écran. Le survol ne déplace la
    /// sélection que si le pointeur a VRAIMENT bougé depuis : quand la liste se refiltre sous
    /// un curseur immobile (pendant qu'on tape une recherche), le survol se redéclenche au
    /// même point, et sans ce garde il volerait la sélection au premier résultat que le
    /// filtrage vient de poser. C'est le comportement des menus macOS natifs.
    @State private var dernierPointeur: CGPoint?

    private static let largeur: CGFloat = 520
    private static let hauteur: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            ChampDeRecherche(
                texte: $model.requete,
                surChangement: { model.onRequete?($0) },
                surMonter: monter,
                surDescendre: descendre,
                surValider: valider,
                surFermer: { model.onFermer?() },
                enregistrerLeChamp: enregistrerLeChamp
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.4)
            liste
            Divider().opacity(0.4)
            pied
        }
        .frame(width: Self.largeur, height: Self.hauteur)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(16)
    }

    @ViewBuilder private var liste: some View {
        if model.lignes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.requete.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(model.requete.isEmpty ? l10n("recherche.historique_vide")
                    : l10n("recherche.aucun_resultat"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.lignes.enumerated()), id: \.element.id) { rang, ligne in
                            // UNE seule identité, celle de l'entrée. Un `.id(rang)` en plus
                            // entrait en conflit avec l'`id: \.element.id` du ForEach : au
                            // refiltrage, les `element.id` changent mais les `rang` non, et
                            // SwiftUI réutilisait les vues de travers, gardant un fond de
                            // sélection périmé (surbrillance qui « disparaissait » en
                            // recherche). Le défilement vise donc aussi l'entrée, pas le rang.
                            ligneVue(rang: rang, ligne: ligne).id(ligne.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.index) { nouveau in
                    // Ne centrer que sur un déplacement clavier. Au survol souris, la ligne
                    // est forcément déjà visible, et défiler ferait sauter la liste sous le
                    // curseur.
                    guard defilementClavier, model.lignes.indices.contains(nouveau) else { return }
                    defilementClavier = false
                    let cible = model.lignes[nouveau].id
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(cible, anchor: .center) }
                }
            }
        }
    }

    private func ligneVue(rang: Int, ligne: LigneDeMenu) -> some View {
        let selectionnee = rang == model.index
        return HStack(spacing: 10) {
            vignetteOuIcone(ligne).frame(width: 22, height: 22)
            Text(ligne.titre)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = ligne.action {
                Button { model.onAction?(ligne.id) } label: {
                    Image(systemName: iconeDeLAction(action)).font(.system(size: 12))
                }
                .buttonStyle(.plain).help("Exécuter l'action suggérée")
            }
            if selectionnee {
                Button { model.onEpingler?(ligne.id) } label: {
                    Image(systemName: ligne.epingle ? "pin.fill" : "pin").font(.system(size: 12))
                }
                .buttonStyle(.plain).help(ligne.epingle ? l10n("action.deseingler")
                    : l10n("action.epingler"))
                Button { model.onSupprimer?(ligne.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain).help(l10n("action.supprimer"))
            } else if ligne.epingle {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selectionnee ? Color.accentColor.opacity(0.9) : Color.clear)
        )
        .foregroundStyle(selectionnee ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
        // Survoler une ligne LA SÉLECTIONNE : un seul surlignage, le bleu, qui suit la
        // souris comme les flèches, et l'aperçu suit avec. `.onContinuousHover` et non
        // `.onHover` : dans un `ScrollView`, les zones de suivi d'`.onHover` sont posées en
        // coordonnées de contenu et ne suivent pas le défilement, si bien que le survol se
        // décalerait du nombre de lignes défilées. `.onContinuousHover` se fonde sur la
        // position réelle du pointeur, donc il reste juste même quand la liste a défilé.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case let .active(point) = phase else { return }
            // Seulement sur un VRAI mouvement de souris : si le pointeur n'a pas bougé (la
            // liste se refiltre sous un curseur immobile), on ne vole pas la sélection que
            // le filtrage vient de poser sur le premier résultat.
            guard point != dernierPointeur else { return }
            dernierPointeur = point
            if model.index != rang {
                defilementClavier = false // un survol ne doit jamais faire défiler
                model.index = rang
            }
        }
        .onTapGesture { model.index = rang; valider() }
    }

    @ViewBuilder private func vignetteOuIcone(_ ligne: LigneDeMenu) -> some View {
        if let data = ligne.vignette, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: ligne.icone).font(.system(size: 14))
        }
    }

    private var pied: some View {
        HStack(spacing: 8) {
            Menu {
                Toggle(l10n("menu.ouvrir_demarrage"), isOn: Binding(
                    get: { model.ouvertureAuDemarrage },
                    set: { _ in model.onBasculerDemarrage?() }
                ))

                Picker(l10n("reglages.section.historique"), selection: Binding(
                    get: { model.tailleHistorique },
                    set: { model.onChoisirTaille?($0) }
                )) {
                    ForEach(model.taillesPossibles, id: \.self) { n in
                        Text(String(format: l10n("reglages.historique.valeur"), n)).tag(n)
                    }
                }

                Picker(l10n("reglages.section.retention"), selection: Binding(
                    get: { model.retentionJours },
                    set: { model.onChoisirRetention?($0) }
                )) {
                    ForEach(model.retentionsPossibles, id: \.self) { j in
                        Text(libelleRetention(j)).tag(j)
                    }
                }

                Menu(l10n("reglages.section.exclusions")) {
                    if model.appsExcluables.isEmpty {
                        Text(l10n("reglages.exclusions.aucune"))
                    }
                    ForEach(model.appsExcluables) { app in
                        Toggle(app.nom, isOn: Binding(
                            get: { model.appsExclues.contains(app.id) },
                            set: { _ in model.onBasculerApp?(app.id) }
                        ))
                    }
                }

                Picker(l10n("reglages.section.raccourci"), selection: Binding(
                    get: { model.raccourciActif },
                    set: { model.onChoisirRaccourci?($0) }
                )) {
                    ForEach(Array(model.raccourcisLibelles.enumerated()), id: \.offset) { i, lib in
                        Text(lib).tag(i)
                    }
                }

                Divider()
                Button(l10n("action.tout_sauf_epingles")) { model.onSupprimerSaufEpingles?() }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(.secondary)

            if let version = model.majDisponible {
                Button { model.onOuvrirMaj?() } label: {
                    Label(String(format: l10n("maj.disponible"), version), systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(l10n("maj.aide"))
            }

            Spacer()

            Button { model.onToutSupprimer?() } label: {
                Label(l10n("action.tout_supprimer"), systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.9)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func monter() {
        defilementClavier = true
        model.index = max(0, model.index - 1)
    }

    private func descendre() {
        defilementClavier = true
        model.index = min(model.lignes.count - 1, model.index + 1)
    }

    private func valider(texteBrut: Bool = false) {
        guard model.lignes.indices.contains(model.index) else { return }
        model.onValider?(model.lignes[model.index].id, texteBrut)
    }

    private func libelleRetention(_ jours: Int) -> String {
        jours == 0 ? l10n("reglages.retention.desactivee")
            : String(format: l10n("reglages.retention.jours"), jours)
    }
}
