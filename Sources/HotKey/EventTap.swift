import CoreGraphics
import Foundation

/// Adaptateur entre CoreGraphics et la machine à états. Il ne décide rien : il
/// traduit des CGEvent en `HotKeyInput`, et avale l'événement quand la machine
/// le demande.
final class EventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onInput: (HotKeyInput) -> Bool
    private let onCopyShortcut: () -> Void
    /// Appelé quand la frappe correspond au raccourci global configuré. L'événement est
    /// alors CONSOMMÉ par le tap, donc il n'atteint ni l'application de devant ni la
    /// logique du geste. Optionnel, comme le sont les autres gestes secondaires.
    private let onRaccourciGlobal: (() -> Void)?
    /// L'état VIVANT du geste, relu à chaque événement. Une fermeture et non une
    /// copie : le tap ne détient aucun état, il va le lire là où il vit, dans la
    /// machine de l'assemblage. Un miroir tenu ici dériverait au premier oubli.
    private let etatDuGeste: () -> HotKeyState
    /// Le raccourci VIVANT, relu à chaque événement pour la même raison que
    /// `etatDuGeste` : changer le réglage doit prendre effet sans relancer le tap.
    private let raccourciGlobal: () -> RaccourciGlobal

    init(onInput: @escaping (HotKeyInput) -> Bool, onCopyShortcut: @escaping () -> Void,
         onRaccourciGlobal: (() -> Void)?,
         etatDuGeste: @escaping () -> HotKeyState,
         raccourciGlobal: @escaping () -> RaccourciGlobal)
    {
        self.onInput = onInput
        self.onCopyShortcut = onCopyShortcut
        self.onRaccourciGlobal = onRaccourciGlobal
        self.etatDuGeste = etatDuGeste
        self.raccourciGlobal = raccourciGlobal
    }

    /// Idempotent. Sans la garde, un second appel écrase `tap` et `source` sans
    /// retirer les premiers : deux taps actifs, chaque frappe traversée deux fois
    /// (une flèche bas descend de deux rangs, V ouvre l'overlay puis déplace
    /// aussitôt la sélection), et le premier tap n'est plus référencé donc plus
    /// jamais arrêtable. Le cas n'a rien de théorique : `Permissions.surveiller`
    /// rappelle IMMÉDIATEMENT son callback quand l'autorisation est déjà accordée,
    /// donc `start()` puis `surveiller { start() }` suffit à le produire.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let masque = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let moi = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return moi.traiter(type: type, event: event)
        }

        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: CGEventMask(masque),
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // `GetMain` et non `GetCurrent` : un `start()` appelé depuis une queue de
        // fond ajouterait la source à une boucle qui ne tourne jamais. Le tap est
        // alors créé, activé, `start()` rend `true`, aucun événement n'arrive et
        // aucune erreur n'est signalée nulle part. Échec strictement silencieux.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// L'ordre des quatre gestes n'est pas décoratif : désactiver, retirer de la
    /// boucle, INVALIDER le port, puis relâcher.
    ///
    /// `CFRunLoopGetMain` et non `GetCurrent` : `deinit` s'exécute sur le thread
    /// qui relâche la dernière référence, et ce thread n'est pas choisi (une
    /// fermeture capturant le tap et libérée sur une queue globale suffit).
    /// Retirer la source d'une boucle qui ne la contient pas ne retire rien, et
    /// la boucle principale garderait la source et le port Mach vivants avec un
    /// refcon qui pointe sur un objet libéré.
    ///
    /// `CFMachPortInvalidate` : sans lui, chaque cycle arrêt puis relance (la
    /// tâche 12 en fera un autour de chaque collage synthétique) laisse en l'air
    /// un port et sa source, et c'est précisément l'objet qui porte encore le
    /// pointeur brut vers `self`. C'est ce geste qui ferme la fenêtre d'usage
    /// après libération que le `deinit` ne fait que réduire.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil; source = nil
    }

    /// Filet de sécurité contre un usage après libération. `userInfo` reçoit un
    /// `passUnretained(self)` : CoreGraphics ne retient PAS l'instance, alors que
    /// la boucle d'exécution, elle, retient la source et le port. Sans ce `deinit`,
    /// un `EventTap` relâché pendant que son tap tourne laisserait le callback
    /// déréférencer un pointeur mort à la frappe suivante. Le propriétaire doit
    /// malgré tout garder une référence forte pour toute la durée de vie de
    /// l'application : ce `deinit` limite les dégâts, il ne dispense de rien.
    deinit {
        stop()
    }

    private func traiter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Le système désactive un tap qui répond trop lentement. Sans ce
        // rattrapage, les raccourcis cessent SILENCIEUSEMENT de marcher au bout
        // de quelques jours : c'est le piège classique de CGEventTap.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("Copyclipzer : tap réactivé après désactivation par le système")
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        // Le tri « cet événement n'est pas de la main de l'utilisateur » vit dans
        // `Paster.estSynthetique`, qui lit les champs du `CGEvent` et appelle le
        // prédicat pur de `PastePolicy.swift`. Il ne s'arrête plus à notre signature :
        // le Cmd-V automatique d'une autre application doit être relayé lui aussi,
        // sinon il peut ouvrir le geste et se faire avaler (incident SuperWhisper du
        // 2026-09-30, mesuré au journal). Le filtre n'est PAS un `return` anticipé
        // posé ici : ce serait mettre la règle dans le seul fichier du projet que les
        // tests ne peuvent pas atteindre. Le tap lit les champs, `decider` décide, et
        // il le fait avant toute autre branche.

        // Tout l'aiguillage vit dans `decider`, du côté pur de `HotKeyMachine.swift`.
        // Ce fichier importe CoreGraphics et ne peut pas être symlinké dans la
        // cible de test : ce qui reste ici est donc, par construction, ce qui n'est
        // pas mesurable. On y laisse le strict minimum, la lecture des champs et
        // l'exécution de la décision, et jamais une règle.
        let typePur = EventTap.typePur(type)

        // Le raccourci global, AVANT l'aiguillage du geste et avant toute autre branche :
        // c'est la détection PRIORITAIRE demandée. La comparaison est exacte sur la touche
        // et les quatre modificateurs, donc ⌥⌘V ne peut pas être confondu avec le Cmd-V du
        // geste (qui n'a pas d'Option). Quand il correspond, l'événement est CONSOMMÉ : le
        // tap rend `nil`, ce qui empêche à la fois la frappe d'atteindre l'application de
        // devant et la machine à états de la voir. Quand il ne correspond pas, on ne fait
        // RIEN ici et le chemin existant du geste reste strictement inchangé.
        if typePur == .keyDown,
           correspondAuRaccourci(keycode: Int(code),
                                 option: flags.contains(.maskAlternate),
                                 commande: flags.contains(.maskCommand),
                                 majuscule: flags.contains(.maskShift),
                                 controle: flags.contains(.maskControl),
                                 raccourci: raccourciGlobal())
        {
            onRaccourciGlobal?()
            return nil
        }

        let decision = decider(type: typePur,
                               commandEnfonce: flags.contains(.maskCommand),
                               majEnfonce: flags.contains(.maskShift),
                               optionEnfonce: flags.contains(.maskAlternate),
                               controlEnfonce: flags.contains(.maskControl),
                               estSynthetique: Paster.estSynthetique(event, type: typePur),
                               code: code,
                               etat: etatDuGeste())

        switch decision {
        case .relayer:
            return Unmanaged.passUnretained(event)

        case let .relayerApres(entree):
            _ = onInput(entree)
            return Unmanaged.passUnretained(event) // jamais avaler un modificateur

        case .capturerPuisRelayer:
            onCopyShortcut()
            return Unmanaged.passUnretained(event)

        case let .soumettre(entree):
            return onInput(entree) ? nil : Unmanaged.passUnretained(event)
        }
    }

    /// La seule traduction que le tap garde pour lui. Les types de désactivation
    /// sont interceptés plus haut, et le masque ne demande que `keyDown` et
    /// `flagsChanged` : `.autre` n'est donc atteint que par surprise, et se relaie.
    private static func typePur(_ type: CGEventType) -> HotKeyEventType {
        switch type {
        case .keyDown: return .keyDown
        case .flagsChanged: return .flagsChanged
        default: return .autre
        }
    }
}
