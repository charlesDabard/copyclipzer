import AppKit
import Combine
import SwiftUI

/// Le modèle du panneau d'aperçu : une entrée, ou rien.
final class ApercuModel: ObservableObject {
    @Published var item: ClipItem?
}

/// Ce que montre le panneau : la vignette en grand quand il y en a une, le texte
/// complet plafonné, puis le pied de métadonnées.
///
/// Le texte et le pied viennent de `MenuFormat.swift`, pur et testé. Ce fichier ne
/// décide rien, il dessine.
struct ApercuView: View {
    @ObservedObject var model: ApercuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = model.item {
                if let octets = item.thumb, let vignette = NSImage(data: octets) {
                    Image(nsImage: vignette)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 200)
                        .cornerRadius(6)
                }
                // Le corps saute quand il répéterait le pied. Voir
                // `corpsRedondantAvecLePied`, la règle vit dans le fichier pur.
                if !corpsRedondantAvecLePied(item) {
                    Text(corpsDeLApercu(item))
                        .font(.system(size: 12))
                        .textSelection(.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().opacity(0.4)
                }
                Text(piedDeLApercu(item))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: largeurDeLApercu, alignment: .leading)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Le panneau d'aperçu, UN SEUL pour les deux surfaces.
///
/// Le menu de barre le montre au survol d'une ligne, le geste maintenu le fait suivre
/// la sélection au clavier. Deux panneaux jumeaux divergeraient au premier réglage,
/// et il n'y a jamais deux aperçus à l'écran en même temps de toute façon.
///
/// `canBecomeKey` reste `false`, exactement comme `OverlayPanel` et pour la même
/// raison : prendre le focus ferait perdre à l'application cible son premier plan,
/// donc enverrait le collage au mauvais endroit. Un panneau d'aperçu qui casserait le
/// collage serait un comble.
final class ApercuPanel {
    private let panel: NSPanel
    private let model = ApercuModel()
    private let hote: NSHostingView<ApercuView>

    /// Le report d'affichage, et son annulation, appartiennent au panneau lui-même.
    /// Voir `ReportAnnulable` : le compteur vivait dans l'assemblage, et deux des trois
    /// chemins de fermeture masquaient sans annuler.
    private var report = ReportAnnulable()

    init() {
        hote = NSHostingView(rootView: ApercuView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: largeurDeLApercu,
                                            height: hauteurMinimaleDeLApercu),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        // Au-dessus du menu, et non simplement au-dessus des fenêtres. Un `NSMenu`
        // ouvert vit au niveau `popUpMenuWindow` : un panneau posé au même niveau
        // passerait DERRIÈRE le menu une fois sur deux, sans que rien n'explique
        // pourquoi il disparaît parfois.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // PAS de `.canJoinAllSpaces`, contrairement à l'overlay. Un aperçu est
        // transitoire et appartient au bureau où il s'est ouvert : le faire voyager
        // avec l'utilisateur, c'est précisément ce qui le rendait impossible à semer.
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // Le panneau ne doit RIEN intercepter : il se pose par-dessus le menu ouvert,
        // et un clic qui l'atteindrait au lieu d'atteindre la ligne en dessous
        // annulerait le geste que l'aperçu est censé accompagner.
        panel.ignoresMouseEvents = true
        panel.contentView = hote

        // Deux filets, pour un panneau qui vit AU-DESSUS du menu et qui ignore les
        // clics : rien de ce que fait l'utilisateur ne l'atteint jamais. La cause
        // racine est traitée par `ReportAnnulable`, mais un panneau sans porte de
        // sortie mérite qu'on en pose deux, et aucun des deux ne peut se déclencher à
        // tort puisque changer de bureau ou d'application ferme déjà le menu.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.masquer()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Sauf NOTRE application. Le panneau de recherche s'active lui-même
            // (`NSApp.activate`) pour prendre le clavier : sans ce filtre, la
            // notification d'activation de notre propre app annulerait l'aperçu à
            // l'instant même où il vient d'être programmé, et l'aperçu du panneau de
            // recherche ne s'afficherait jamais. Le geste, lui, n'active rien : ce
            // filtre ne change rien à son comportement.
            let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            if active?.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.masquer()
            }
        }
    }

    /// Montre l'aperçu d'une entrée à côté d'une ancre donnée en coordonnées d'écran.
    /// Une entrée nulle masque le panneau : c'est le même appel pour montrer et pour
    /// cacher, donc pas de chemin où l'on oublie de refermer.
    ///
    /// L'affichage est REPORTÉ de `delaiAvantLApercu` et annulable. Sans le report,
    /// balayer le menu construisait un panneau SwiftUI par ligne traversée, sur le
    /// thread principal, et c'est le suivi du menu qui prenait du retard. Sans
    /// l'annulation, le report se posait après la fermeture et le panneau devenait
    /// orphelin.
    func afficher(_ item: ClipItem?, pres ancre: CGRect) {
        guard let item else { masquer(); return }
        let jeton = report.programmer()
        DispatchQueue.main.asyncAfter(deadline: .now() + delaiAvantLApercu) { [weak self] in
            guard let self, report.estValide(jeton) else { return }
            poser(item, pres: ancre)
        }
    }

    /// Le dessin proprement dit, une fois le report honoré.
    private func poser(_ item: ClipItem, pres ancre: CGRect) {
        model.item = item
        hote.layout()

        let mesuree = hote.fittingSize.height
        let hauteur = min(max(mesuree, hauteurMinimaleDeLApercu), hauteurMaximaleDeLApercu)
        panel.setContentSize(NSSize(width: largeurDeLApercu, height: hauteur))

        let ecran = (NSScreen.screens.first { $0.frame.intersects(ancre) } ?? NSScreen.main)?
            .visibleFrame ?? .zero
        panel.setFrameOrigin(placementDuPanneau(ancre: ancre,
                                                taille: panel.frame.size,
                                                ecran: ecran))
        panel.orderFrontRegardless()
    }

    /// Masque, et ANNULE tout affichage en attente. C'est le même appel pour les trois
    /// chemins de fermeture, celui du menu, celui du geste et celui du survol qui sort,
    /// donc aucun ne peut oublier d'annuler.
    ///
    /// Immédiat, jamais reporté : un panneau qui traîne après la fermeture se voit, un
    /// panneau qui arrive 120 ms trop tard ne se voit pas.
    func masquer() {
        report.annuler()
        model.item = nil
        panel.orderOut(nil)
    }
}
