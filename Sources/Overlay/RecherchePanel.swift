import AppKit
import SwiftUI

/// Un `NSPanel` qui PEUT devenir clavier, contrairement à l'overlay du geste Cmd. Le
/// panneau de recherche a besoin du focus pour que la frappe arrive dans le champ ;
/// l'overlay, lui, ne doit jamais le prendre, sinon le collage part au mauvais endroit.
/// Toute la différence entre les deux surfaces tient dans cette seule propriété.
final class PanneauClavier: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Cmd+chiffre, posé par `RecherchePanel`. Routé ici par `performKeyEquivalent` et
    /// NON par le délégué du champ : un Cmd+chiffre est un équivalent clavier, donc la
    /// fenêtre le reçoit AVANT qu'il n'atteigne `doCommandBy`. L'y attendre serait
    /// attendre un événement qui n'arrive jamais. Rend vrai quand le rang a été collé.
    var surChiffreCmd: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let touche = event.charactersIgnoringModifiers,
           surChiffreCmd?(touche) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Le panneau de recherche : il s'ouvre au clic sur l'icône de la barre des menus, prend
/// le focus, filtre en direct, et rend le focus à l'application précédente quand on colle.
/// Il remplace le menu de barre, dont la reconstruction à chaque frappe faisait perdre le
/// focus au champ.
final class RecherchePanel: NSObject {
    private let panel: PanneauClavier
    private let model: RechercheModel
    private var hote: NSHostingView<RechercheView>!
    private weak var champ: NSSearchField?
    private var appPrecedente: NSRunningApplication?
    /// Moniteur de clic extérieur, vivant seulement tant que le panneau est affiché.
    private var moniteurClic: Any?

    /// Appelé à CHAQUE fermeture du panneau, quelle qu'en soit la cause : Échap, clic
    /// extérieur, bascule, ou collage. `masquer()` est le seul point de sortie, donc
    /// brancher ici garantit qu'aucun chemin n'oublie de ranger l'aperçu qui vit à côté.
    var onMasquer: (() -> Void)?

    /// Appelé une fois le panneau rendu visible et la liste déjà peuplée. Sert à rafraîchir
    /// l'aperçu à l'ouverture : le filtrage initial (`onRequete`) peuple la liste AVANT que
    /// le panneau soit visible, donc l'abonnement qui suit la sélection se déclenche alors
    /// que `estVisible` est encore faux et se contente de masquer. Sans ce rappel, l'aperçu
    /// n'apparaîtrait qu'au premier changement de sélection, jamais à l'ouverture.
    var onAffiche: (() -> Void)?

    init(model: RechercheModel) {
        self.model = model
        panel = PanneauClavier(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        let vue = RechercheView(model: model, enregistrerLeChamp: { [weak self] champ in
            self?.champ = champ
        })
        hote = NSHostingView(rootView: vue)
        hote.layoutSubtreeIfNeeded()
        hote.frame = NSRect(origin: .zero, size: hote.fittingSize)

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // L'ombre et les coins arrondis sont dessinés par SwiftUI : une ombre AppKit
        // serait rectangulaire autour d'un contenu transparent.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = hote

        model.onFermer = { [weak self] in self?.masquer() }
        panel.surChiffreCmd = { [weak self] touche in
            self?.collerLeRang(touche) ?? false
        }
    }

    var estVisible: Bool {
        panel.isVisible
    }

    /// Le cadre du panneau en coordonnées d'écran, pour que le panneau d'aperçu sache où
    /// se poser. Lecture seule : personne d'autre ne place le panneau de recherche. Même
    /// contrat que `OverlayPanel.cadre`, et c'est ce qui permet aux deux surfaces de
    /// confier le même calcul de placement à `placementDuPanneau`.
    var cadre: CGRect {
        panel.frame
    }

    func basculer() {
        estVisible ? masquer() : afficher()
    }

    /// Ouvre le panneau, repart d'une recherche vide, prend le focus. L'application de
    /// devant est relevée AVANT toute activation, pour pouvoir y rendre le focus au
    /// collage : un clic sur l'icône de barre ne la fait pas encore passer au second plan.
    func afficher() {
        appPrecedente = NSWorkspace.shared.frontmostApplication
        model.requete = ""
        model.onRequete?("")
        accorderLaTaille()
        positionner()
        // `ignoringOtherApps: true` et NON le `NSApp.activate()` poli de macOS 14+ : pour
        // une application accessoire déclenchée depuis l'icône de barre, la version polie
        // n'active pas l'app, le panneau s'affichait donc sans jamais devenir clavier
        // (mesuré : visible=1, key=0), donc impossible à focaliser et à taper dedans. La
        // version qui force reste la seule à rendre le panneau réellement clé ici.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        surveillerLeClicExterieur()
        // Le panneau est désormais visible et la liste déjà peuplée : c'est le moment où
        // l'aperçu de la sélection peut enfin se poser (voir `onAffiche`).
        onAffiche?()
        DispatchQueue.main.async { [weak self] in self?.focaliserLeChamp() }
    }

    func masquer() {
        arreterLaSurveillanceDuClic()
        panel.orderOut(nil)
        onMasquer?()
    }

    /// Referme, rend le focus à l'application d'avant, PUIS colle. L'ordre compte : le
    /// Cmd-V synthétisé par `Paster` va à l'application de devant, elle doit donc être
    /// redevenue active avant. Le court délai laisse l'activation aboutir.
    func collerDans(_ geste: @escaping () -> Void) {
        masquer()
        if let app = appPrecedente, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: geste)
    }

    /// Demande confirmation avant un geste destructeur (vider l'historique). Modal. Les
    /// clics sur l'alerte sont des événements LOCAUX de notre application, donc le moniteur
    /// de clic extérieur ne les voit pas et ne referme pas le panneau sous l'alerte.
    func confirmer(_ titre: String, _ info: String, _ boutonOK: String,
                   geste: @escaping () -> Void)
    {
        let alerte = NSAlert()
        alerte.messageText = titre
        alerte.informativeText = info
        alerte.alertStyle = .warning
        alerte.addButton(withTitle: boutonOK)
        alerte.addButton(withTitle: l10n("commun.annuler"))
        let reponse = alerte.runModal()
        if reponse == .alertFirstButtonReturn {
            geste()
        }
        focaliserLeChamp()
    }

    /// Referme le panneau sur un clic AILLEURS, par un moniteur global, et non sur la perte
    /// du focus clavier. C'est le même choix que l'overlay du geste (voir
    /// `AppDelegate.surveillerLeClicExterieur`) : une application accessoire perd le focus
    /// clavier pour un rien, et s'y accrocher faisait disparaître le panneau au moindre
    /// soubresaut, dès l'ouverture sous automatisation. Un clic DANS le panneau est un
    /// événement local, jamais vu ici ; seuls les clics dans une autre fenêtre le referment.
    /// Échap et le collage ferment par ailleurs.
    private func surveillerLeClicExterieur() {
        guard moniteurClic == nil else { return }
        moniteurClic = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.masquer()
        }
    }

    private func arreterLaSurveillanceDuClic() {
        if let moniteurClic {
            NSEvent.removeMonitor(moniteurClic)
        }
        moniteurClic = nil
    }

    /// Choisit la Nième ligne de la liste pour un Cmd+chiffre et la colle, exactement
    /// comme un clic : l'index vient de la règle pure `indexPourTouche`, puis le même
    /// `onValider` que le reste du panneau est appelé en mode normal. Rend faux quand
    /// le chiffre ne désigne aucune ligne : l'événement n'est alors pas consommé et
    /// retombe sur le comportement normal du système, au lieu d'être avalé en silence.
    private func collerLeRang(_ touche: String) -> Bool {
        guard let index = indexPourTouche(touche, nombreDeLignes: model.lignes.count),
              model.lignes.indices.contains(index) else { return false }
        model.index = index
        model.onValider?(model.lignes[index].id, false)
        return true
    }

    private func focaliserLeChamp() {
        let cible = champ ?? trouverChamp(dans: panel.contentView)
        champ = cible
        if let cible {
            panel.makeFirstResponder(cible)
        }
    }

    private func trouverChamp(dans vue: NSView?) -> NSSearchField? {
        guard let vue else { return nil }
        if let sf = vue as? NSSearchField {
            return sf
        }
        for sous in vue.subviews {
            if let sf = trouverChamp(dans: sous) {
                return sf
            }
        }
        return nil
    }

    private func accorderLaTaille() {
        hote.layoutSubtreeIfNeeded()
        panel.setContentSize(hote.fittingSize)
    }

    private func positionner() {
        // Sur l'écran où est le CURSEUR, pas `NSScreen.main` : avec deux écrans, le
        // panneau s'ouvrait là où était la dernière fenêtre active, souvent pas là où
        // l'utilisateur vient de cliquer l'icône. On le pose là où est sa main.
        let souris = NSEvent.mouseLocation
        let ecran = NSScreen.screens.first { NSMouseInRect(souris, $0.frame, false) } ?? NSScreen.main
        guard let ecran else { return }
        let f = ecran.visibleFrame
        let t = panel.frame.size
        // Juste sous la barre des menus : le haut du cadre à `f.maxY` (sommet de la zone
        // utile), et la marge de 16 px de l'ombre laisse un petit jour sous la topbar.
        panel.setFrameOrigin(NSPoint(x: f.midX - t.width / 2,
                                     y: f.maxY - t.height))
    }
}
