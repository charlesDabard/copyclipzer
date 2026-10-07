import AppKit
import Combine
import SwiftUI

/// Une seule propriété compte : le panneau ne prend JAMAIS le focus, sinon
/// l'application cible le perd et le collage part au mauvais endroit. Les touches
/// n'arrivent donc pas par le panneau mais par le tap clavier, ce qui est
/// exactement ce qui rend le maintien de Cmd possible.
///
/// Mesuré le 2026-08-25 sur cette machine, avec cette configuration exacte : Firefox
/// est resté au premier plan, `isKeyWindow` et `canBecomeKey` valent `false`, et la vue
/// se dessine. Preuve : `screenshots/2026-08-25-spike-panneau-non-activant.png`.
final class OverlayPanel {
    /// Largeur figée du panneau. `NSHostingView` sait rendre la hauteur idéale de son
    /// contenu, mais laisser la largeur suivre le contenu ferait sauter le panneau de
    /// taille à chaque entrée affichée, puisque le titre le plus long la dicterait.
    private static let largeur: CGFloat = 460
    /// Hauteur de repli si la mesure du contenu rend zéro. Un panneau de hauteur nulle
    /// s'ordonnerait au premier plan sans rien montrer, ce qui ne se distingue pas d'un
    /// panneau qui ne s'affiche pas.
    private static let hauteurMinimale: CGFloat = 44

    private let panel: NSPanel
    private let model: OverlayModel
    private let hote: NSHostingView<OverlayView>
    /// Abonnement au modèle, gardé vivant par le panneau. C'est lui qui rend
    /// `rafraichir()` branché plutôt que disponible : voir son commentaire.
    private var abonnement: AnyCancellable?

    init(model: OverlayModel) {
        self.model = model
        hote = NSHostingView(rootView: OverlayView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: OverlayPanel.largeur,
                                            height: OverlayPanel.hauteurMinimale),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        // `true` par défaut, alors qu'`OverlayPanel` garde une référence forte sur le
        // panneau. `masquer()` fait `orderOut`, donc rien ne casse aujourd'hui, mais
        // le jour où quelqu'un ajoute un `close()` c'est une sur-libération.
        panel.isReleasedWhenClosed = false
        panel.contentView = hote

        // Le rafraîchissement est branché ICI et non laissé au site d'appel. La règle
        // « un garde-fou non branché est un garde-fou absent » s'applique mot pour mot :
        // `rafraichir()` seulement disponible, c'est un appel que la tâche 14 peut
        // oublier sur `.basculerTexteBrut`, et l'utilisateur appuie sur Z sans voir la
        // mention apparaître. `objectWillChange` part AVANT la mutation, d'où le renvoi
        // d'un tour de boucle : SwiftUI doit avoir remis en page pour que
        // `fittingSize` mesure la bonne hauteur.
        abonnement = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rafraichir() }
        }
    }

    /// Le cadre du panneau en coordonnées d'écran, pour que le panneau d'aperçu sache
    /// où se poser. Lecture seule : personne d'autre ne place l'overlay.
    var cadre: CGRect { panel.frame }

    /// Vrai quand le panneau est réellement à l'écran. Le geste ouvre LOGIQUEMENT à
    /// chaque Cmd-V mais n'affiche qu'après 150 ms : sans cette distinction, l'aperçu
    /// se poserait à côté d'un overlay invisible.
    var estVisible: Bool { panel.isVisible }

    func afficher() {
        rafraichir()
        panel.orderFrontRegardless()
    }

    /// Réaccorde la taille au contenu et recentre, sur un panneau DÉJÀ affiché.
    ///
    /// Sans ce point d'entrée, la taille n'était accordée qu'à l'ouverture. Or la
    /// touche Z bascule `texteBrut` sur un panneau ouvert, et `OverlayView` ajoute
    /// alors un `Divider` et une ligne : 276 points sans la mention, 312 avec, mesuré
    /// à la tâche 11. Les 36 points de la mention « collage en texte brut » se
    /// dessinaient hors du `contentView` et étaient rognés, donc l'utilisateur
    /// appuyait sur Z et n'obtenait AUCUN retour visuel, c'est-à-dire exactement la
    /// fonction que cette mention existe pour rendre. Même chose à chaque changement
    /// d'`items`, où le nombre de lignes change.
    ///
    /// À appeler après toute mutation du modèle qui change le nombre de lignes ou la
    /// présence de la mention.
    func rafraichir() {
        accorderLaTailleAuContenu()
        if let ecran = NSScreen.main {
            let f = ecran.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.midY - panel.frame.height / 2))
        }
    }

    func masquer() {
        panel.orderOut(nil)
    }

    /// Accorde la hauteur du panneau à celle du contenu réellement mesuré. Sans ce
    /// calcul, la hauteur reste celle du `contentRect` de départ : neuf entrées plus la
    /// mention du texte brut débordent par le bas, et une liste de deux entrées laisse
    /// une grande zone transparente qui avale les clics.
    private func accorderLaTailleAuContenu() {
        hote.layoutSubtreeIfNeeded()
        let mesure = hote.fittingSize.height
        let hauteur = mesure > 0 ? mesure : OverlayPanel.hauteurMinimale
        panel.setContentSize(NSSize(width: OverlayPanel.largeur, height: hauteur))
    }

    /// Lecture seule, pour la vérification manuelle de la tâche 14 et pour le banc
    /// d'essai : la taille effective du panneau après accord au contenu.
    var tailleMesuree: NSSize {
        panel.frame.size
    }
}
