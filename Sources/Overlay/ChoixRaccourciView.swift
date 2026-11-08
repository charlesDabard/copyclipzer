import SwiftUI

/// L'état de la fenêtre de choix du raccourci d'ouverture. Types PRIMITIFS, comme
/// `RechercheModel` : la vue est symlinkée dans le harnais de capture, et c'est
/// l'assemblage (`FenetreRaccourci`) qui traduit vers `RaccourciDOuverture`.
final class ChoixRaccourciModel: ObservableObject {
    /// Les libellés proposés, fn+Maj en tête. La ligne « Autre combinaison » vient après,
    /// à l'index `libelles.count`.
    @Published var libelles: [String] = []
    @Published var selection: Int = 0
    /// Le libellé de la combinaison enregistrée à la main, nil tant qu'il n'y en a pas.
    @Published var personnalise: String?
    /// La ligne « Autre combinaison » écoute le clavier.
    @Published var enregistrement = false
    /// Ce que l'enregistreur a reçu en dernier : les modificateurs tenus en direct, puis la
    /// combinaison complète, refusée ou non. Sans ce retour, une frappe refusée ne laissait
    /// aucune trace à l'écran et l'enregistreur semblait sourd (signalé le 2026-11-08).
    @Published var saisieEnCours: String?
    /// Pourquoi la dernière combinaison tapée a été refusée.
    @Published var erreur: String?
    /// Premier choix : la fenêtre ne se ferme pas sans lui, et le bouton Annuler disparaît.
    @Published var obligatoire = true

    var onEnregistrer: (() -> Void)?
    var onValider: (() -> Void)?
    var onAnnuler: (() -> Void)?

    var indexPersonnalise: Int {
        libelles.count
    }

    var peutValider: Bool {
        selection != indexPersonnalise || personnalise != nil
    }
}

struct ChoixRaccourciView: View {
    @ObservedObject var model: ChoixRaccourciModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n("choix_raccourci.titre"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(l10n("choix_raccourci.explication"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 2) {
                ForEach(Array(model.libelles.enumerated()), id: \.offset) { i, libelle in
                    ligne(index: i) {
                        Text(libelle).font(.system(size: 13, weight: .medium, design: .rounded))
                        if i == 0 {
                            Text(l10n("choix_raccourci.recommande"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(.tint)
                            Text(l10n("choix_raccourci.fnmaj_aide"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                ligne(index: model.indexPersonnalise) {
                    Text(l10n("choix_raccourci.autre")).font(.system(size: 13))
                    Spacer(minLength: 8)
                    enregistreur
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            if let erreur = model.erreur {
                Label(erreur, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(l10n("choix_raccourci.modifiable"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.obligatoire {
                    Button(l10n("commun.annuler")) { model.onAnnuler?() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(l10n("choix_raccourci.valider")) { model.onValider?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.peutValider)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Une ligne sélectionnable, cercle de sélection compris. Dessinée à la main plutôt
    /// qu'un `Picker` en boutons radio : la ligne « Autre combinaison » doit porter son
    /// enregistreur, ce qu'un `Picker` ne sait pas faire.
    private func ligne<Contenu: View>(index: Int, @ViewBuilder contenu: () -> Contenu) -> some View {
        let choisie = model.selection == index
        return HStack(spacing: 10) {
            Image(systemName: choisie ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(choisie ? Color.accentColor : Color.secondary)
            contenu()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(choisie ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = index }
    }

    private var enregistreur: some View {
        Button {
            model.selection = model.indexPersonnalise
            model.onEnregistrer?()
        } label: {
            Text(model.enregistrement ? (model.saisieEnCours ?? l10n("choix_raccourci.tape"))
                : (model.personnalise ?? l10n("choix_raccourci.enregistrer")))
                .font(.system(size: 12, weight: model.personnalise != nil && !model.enregistrement
                        ? .medium : .regular, design: .rounded))
                .foregroundStyle(model.enregistrement ? Color.accentColor : Color.primary)
                .frame(minWidth: 130)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(model.enregistrement ? Color.accentColor : Color.secondary.opacity(0.4),
                                  lineWidth: model.enregistrement ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
