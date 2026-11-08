import AppKit
import SwiftUI

/// La fenêtre qui fait choisir le raccourci d'ouverture. Imposée au premier lancement
/// (demandé le 2026-11-08) : sans bouton de fermeture tant qu'aucun choix n'existe, et
/// rouverte à chaque lancement tant qu'il manque. Rouverte aussi depuis le menu de
/// l'engrenage, où elle redevient fermable.
///
/// Glu AppKit, non testée : la règle (ce qui est accepté, ce qui agit pendant le choix)
/// vit dans `RaccourciDOuverture.swift`. Ici, la fenêtre, et l'écoute du clavier pendant
/// l'enregistrement d'une combinaison libre.
final class FenetreRaccourci: NSObject, NSWindowDelegate {
    let model = ChoixRaccourciModel()
    /// Le choix validé. L'assemblage l'écrit dans `Reglages`.
    var onChoisi: ((RaccourciDOuverture) -> Void)?

    private var fenetre: NSWindow?
    /// Écoute locale du clavier, vivante seulement pendant un enregistrement.
    private var moniteur: Any?
    /// La dernière combinaison libre acceptée.
    private var personnalise: RaccourciDOuverture?
    /// L'accord de modificateurs en cours d'enregistrement, voir `EnregistreurDAccord`.
    private var enregistreurDAccord = EnregistreurDAccord()

    /// Vrai tant que la fenêtre est à l'écran. L'assemblage coupe alors tout raccourci,
    /// voir `raccourciEnVigueur`.
    var estOuverte: Bool {
        fenetre?.isVisible == true
    }

    override init() {
        super.init()
        model.libelles = RaccourciDOuverture.proposes.map(\.libelle)
        model.onEnregistrer = { [weak self] in self?.commencerLEnregistrement() }
        model.onValider = { [weak self] in self?.valider() }
        model.onAnnuler = { [weak self] in self?.fermer() }
    }

    /// `actuel` nil : premier choix, obligatoire, fn+Maj présélectionné.
    func afficher(actuel: RaccourciDOuverture?) {
        model.obligatoire = actuel == nil
        model.erreur = nil
        if let actuel, !RaccourciDOuverture.proposes.contains(actuel) {
            personnalise = actuel
        }
        model.personnalise = personnalise?.libelle
        model.selection = actuel.flatMap { RaccourciDOuverture.proposes.firstIndex(of: $0) }
            ?? (actuel == nil ? 0 : model.indexPersonnalise)

        let fenetre = self.fenetre ?? creerLaFenetre()
        self.fenetre = fenetre
        fenetre.styleMask = model.obligatoire ? [.titled] : [.titled, .closable]
        fenetre.center()
        NSApp.activate(ignoringOtherApps: true)
        fenetre.makeKeyAndOrderFront(nil)
        journal.info("raccourci", "fenêtre de choix ouverte (\(model.obligatoire ? "premier choix, obligatoire" : "modification"))")
    }

    private func creerLaFenetre() -> NSWindow {
        let hote = NSHostingController(rootView: ChoixRaccourciView(model: model))
        let fenetre = NSWindow(contentViewController: hote)
        fenetre.title = "Copyclipzer"
        // Au-dessus des fenêtres ordinaires : l'app n'a pas d'icône de Dock, une fenêtre
        // passée derrière une autre serait perdue, alors qu'elle bloque tout raccourci.
        fenetre.level = .floating
        fenetre.isReleasedWhenClosed = false
        fenetre.delegate = self
        return fenetre
    }

    /// La seule porte de sortie hors validation, et elle reste close au premier choix.
    func windowShouldClose(_: NSWindow) -> Bool {
        !model.obligatoire
    }

    func windowWillClose(_: Notification) {
        arreterLEnregistrement()
    }

    private func valider() {
        let choix: RaccourciDOuverture?
        if model.selection == model.indexPersonnalise {
            choix = personnalise
        } else {
            choix = RaccourciDOuverture.proposes.indices.contains(model.selection)
                ? RaccourciDOuverture.proposes[model.selection] : nil
        }
        guard let choix else { return }
        journal.info("raccourci", "raccourci d'ouverture choisi : \(choix.libelle)")
        onChoisi?(choix)
        fermer()
    }

    private func fermer() {
        arreterLEnregistrement()
        fenetre?.orderOut(nil)
    }

    private func commencerLEnregistrement() {
        guard moniteur == nil else { return }
        journal.info("raccourci", "enregistrement : écoute du clavier")
        model.enregistrement = true
        model.erreur = nil
        model.saisieEnCours = nil
        moniteur = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] evenement in
            if evenement.type == .flagsChanged {
                self?.suivreLesModificateurs(evenement)
            } else {
                self?.enregistreurDAccord.frappe()
                self?.enregistrer(evenement)
            }
            return nil // la frappe enregistrée ne doit rien déclencher d'autre
        }
    }

    private func arreterLEnregistrement() {
        if let moniteur { NSEvent.removeMonitor(moniteur) }
        moniteur = nil
        model.enregistrement = false
        model.saisieEnCours = nil
        enregistreurDAccord = EnregistreurDAccord()
    }

    /// Les modificateurs tenus, affichés en direct, fn compris : « fn + ⇧ » avant même la
    /// touche. L'affichage garde le maximum tenu, il ne s'efface pas au relâchement. Un
    /// accord relâché sans touche (fn+Maj) s'enregistre comme une combinaison.
    private func suivreLesModificateurs(_ evenement: NSEvent) {
        let d = evenement.modifierFlags
        let tenus = Modificateurs(fn: d.contains(.function), option: d.contains(.option),
                                  commande: d.contains(.command), majuscule: d.contains(.shift),
                                  controle: d.contains(.control))
        let accord = enregistreurDAccord.modificateurs(tenus)
        if !enregistreurDAccord.pic.vide, !enregistreurDAccord.touchee {
            model.saisieEnCours = enregistreurDAccord.pic.libelle
            model.erreur = nil
        }
        guard let accord else { return }
        if let choix = choixPourAccord(accord) {
            journal.info("raccourci", "accord enregistré : \(choix.libelle)")
            adopter(choix)
        } else {
            model.saisieEnCours = accord.libelle
            model.erreur = l10n("choix_raccourci.refus.accord")
            journal.info("raccourci", "accord refusé : \(accord.libelle)")
        }
    }

    private func adopter(_ choix: RaccourciDOuverture) {
        personnalise = choix
        model.personnalise = choix.libelle
        model.selection = model.indexPersonnalise
        model.erreur = nil
        arreterLEnregistrement()
    }

    private func enregistrer(_ evenement: NSEvent) {
        let drapeaux = evenement.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Échap seul abandonne l'enregistrement, comme dans les Réglages Système.
        if evenement.keyCode == 53, drapeaux.intersection([.command, .control, .option, .shift]).isEmpty {
            arreterLEnregistrement()
            return
        }
        let combinaison = RaccourciGlobal(keycode: Int(evenement.keyCode),
                                          option: drapeaux.contains(.option),
                                          commande: drapeaux.contains(.command),
                                          majuscule: drapeaux.contains(.shift),
                                          controle: drapeaux.contains(.control))
        let choix = RaccourciDOuverture.combinaison(combinaison,
                                                     touche: evenement.charactersIgnoringModifiers ?? "")
        if let refus = refusDuRaccourci(combinaison) {
            // La combinaison refusée reste affichée, avec la raison : l'utilisateur voit
            // que sa frappe a été reçue, et ce qu'il doit y changer. Sans ce retour,
            // l'enregistreur semblait sourd (signalé le 2026-11-08).
            model.saisieEnCours = choix.libelle
            model.erreur = FenetreRaccourci.message(refus)
            journal.info("raccourci", "combinaison refusée : \(choix.libelle) (\(refus))")
            return
        }
        journal.info("raccourci", "combinaison enregistrée : \(choix.libelle)")
        adopter(choix)
    }

    private static func message(_ refus: RefusDeRaccourci) -> String {
        switch refus {
        case .toucheModificatrice: return l10n("choix_raccourci.refus.modificatrice")
        case .sansCmdNiCtrl: return l10n("choix_raccourci.refus.sans_cmd_ctrl")
        case .unSeulModificateur: return l10n("choix_raccourci.refus.un_seul")
        }
    }
}
