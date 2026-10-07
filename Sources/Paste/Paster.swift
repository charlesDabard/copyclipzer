import AppKit
import CoreGraphics

/// Écrit l'élément choisi dans le presse-papiers et synthétise un Cmd-V. L'entrée
/// collée RESTE dans le presse-papiers : la restauration de l'ancien contenu est une
/// option explicite depuis le 2026-08-26, jamais le défaut. Motif dans
/// `restaurationParDefaut`.
///
/// Les trois règles de ce collage vivent dans `PastePolicy.swift`, qui n'importe
/// rien de graphique et se symlinke dans la cible de test. Ce fichier-ci importe
/// AppKit et CoreGraphics : il n'est jamais symlinké, et ce qu'il garde est donc,
/// par construction, ce qui n'est pas mesurable. On y laisse le strict minimum,
/// la conversation avec `NSPasteboard` et la pose de l'événement, jamais une règle.
final class Paster {
    /// Traduction du prédicat pur pour `EventTap`, seul endroit du projet qui
    /// manipule de vrais `CGEvent`.
    ///
    /// Les trois champs lus ici sont les paramètres de la fonction pure, et rien de
    /// plus : la décision reste entièrement dans `PastePolicy.swift`, donc mesurée.
    /// `eventSourceUserData` est le champ `Int64` libre d'un `CGEvent`, nul sur tout
    /// événement matériel. `eventSourceUnixProcessID` nomme le processus qui a posté
    /// l'événement, zéro sur tout événement matériel. Le type vient du tap : la
    /// règle du bit périphérique ne s'applique qu'aux frappes.
    ///
    /// Le préfixe `Copyclipzer.` n'est pas décoratif : à l'intérieur de la classe,
    /// `estSynthetique(...)` se résout d'abord sur cette méthode-ci et le
    /// compilateur refuse. Il désigne la fonction pure de `PastePolicy.swift`.
    static func estSynthetique(_ event: CGEvent, type: HotKeyEventType) -> Bool {
        guard recopieDeMaskCommandVerifiee else { return false }
        return Copyclipzer.estSynthetique(type: type,
                                          drapeauxBruts: event.flags.rawValue,
                                          signatureEvenement: event.getIntegerValueField(.eventSourceUserData),
                                          pidSource: event.getIntegerValueField(.eventSourceUnixProcessID))
    }

    /// Contrôle de la recopie de `maskCommand`, fait UNE fois et sur le chemin qui
    /// compte.
    ///
    /// Il vivait dans `init`, en `precondition`, et y était doublement mal placé.
    /// D'abord parce que `precondition` n'est retiré qu'en `-Ounchecked` et que
    /// `swift build -c release` compile en `-O` : il arrêtait donc l'application en
    /// PRODUCTION pour surveiller `CGEventFlags.maskCommand`, une constante publique
    /// gelée qui ne changera jamais. Ensuite parce que `estSynthetique` est `static`
    /// et que le tap l'appelle sans jamais construire de `Paster` : la garde ne
    /// couvrait donc pas le seul chemin où la recopie sert.
    ///
    /// Ce qui casse vraiment, c'est NOTRE copie dans `PastePolicy.swift`, qu'aucun
    /// test ne peut comparer au vrai `CGEventFlags` sans importer CoreGraphics. Un
    /// `static let` s'évalue à la première lecture, donc au premier événement, une
    /// seule fois, et sans arrêt fatal : en production la conséquence est que plus
    /// rien n'est reconnu comme nôtre, ce qui dégrade sans casser.
    private static let recopieDeMaskCommandVerifiee: Bool = {
        let exacte = maskCommandBrut == CGEventFlags.maskCommand.rawValue
        if !exacte {
            NSLog("Copyclipzer : maskCommandBrut vaut %llx et CGEventFlags.maskCommand vaut %llx",
                  maskCommandBrut, CGEventFlags.maskCommand.rawValue)
        }
        assert(exacte, "maskCommandBrut ne vaut plus CGEventFlags.maskCommand")
        return exacte
    }()

    /// Repose le Cmd-V d'origine, marqué de notre signature pour que le tap l'ignore,
    /// et SANS toucher au presse-papiers.
    ///
    /// C'est la protection de fidélité de la tâche 15, et le prix à payer du passage de
    /// Ctrl à Cmd. Cmd-V est LE collage du système : chaque collage de la machine
    /// traverse désormais notre tap, et une image ou une liste de fichiers qui ferait
    /// un aller-retour par notre base pourrait y perdre des types. Quand l'utilisateur
    /// relâche Cmd sans avoir navigué, il n'a pas choisi une entrée, il a fait un
    /// Cmd-V : on lui rend le sien, à l'identique.
    ///
    /// Ce chemin ne lit ni n'écrit `NSPasteboard`, et c'est la seule chose qui compte
    /// ici. Un `clearContents` glissé dans ce corps annulerait la protection sans faire
    /// tomber un seul test de la machine, d'où la vérification qui lit ce corps.
    ///
    /// Renvoi sur la boucle principale pour la même raison que `coller` : `.collerNatif`
    /// sort de `decider` par `.relayerApres`, donc l'appel arrive SYNCHRONIQUEMENT dans
    /// le callback du tap, que macOS désactive s'il tarde.
    static func reposerCollageNatif() {
        DispatchQueue.main.async { poserCmdV() }
    }

    /// Les deux moitiés du Cmd-V synthétique, partagées par le collage choisi et par le
    /// relais natif. Les drapeaux imitent un vrai clavier, ils n'identifient personne :
    /// c'est `eventSourceUserData` qui porte la signature, et les DEUX moitiés la
    /// portent. Une moitié non signée suffirait à refermer l'overlay au milieu de son
    /// propre collage.
    ///
    /// Partagée et non recopiée : deux synthèses divergeraient, et une seule des deux
    /// serait mesurée.
    private static func poserCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let bas = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let haut = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        let drapeaux = CGEventFlags(rawValue: drapeauxDuCollage)
        bas?.flags = drapeaux
        haut?.flags = drapeaux
        bas?.setIntegerValueField(.eventSourceUserData, value: signatureDuCollage)
        haut?.setIntegerValueField(.eventSourceUserData, value: signatureDuCollage)
        bas?.post(tap: .cghidEventTap)
        haut?.post(tap: .cghidEventTap)
    }

    private let store: Store
    private let capture: CaptureService

    /// `capture` n'a pas de valeur par défaut, volontairement : sans elle, chaque
    /// collage en texte brut ajoute un doublon à l'historique, et un paramètre
    /// facultatif serait exactement le genre de branchement qu'un site d'appel oublie.
    init(store: Store, capture: CaptureService) {
        self.store = store
        self.capture = capture
    }

    /// Renvoie le travail sur la boucle principale et rend IMMÉDIATEMENT.
    ///
    /// `.coller` sort de `decider` par `.relayerApres`, donc `onInput` est appelé
    /// SYNCHRONIQUEMENT dans `EventTap.traiter`. Sans ce renvoi, le callback du tap
    /// enchaînerait la lecture de tous les types du presse-papiers, la lecture SQLite
    /// de la charge utile, l'écriture, puis deux `CGEvent.post`. Avec une capture de
    /// 20 Mo dans le presse-papiers, le callback dépasse le délai du tap, macOS envoie
    /// `tapDisabledByTimeout`, et les frappes de la fenêtre de rattrapage sont perdues.
    ///
    /// Le renvoi est INTERNE et non à la charge de l'appelant : le site d'appel ne
    /// doit pas pouvoir se tromper. Bénéfice secondaire, le `orderOut` du panneau est
    /// alors garanti traité avant que le Cmd-V ne parte.
    func coller(_ item: ClipItem, texteBrut: Bool, restaurer: Bool = restaurationParDefaut) {
        DispatchQueue.main.async { [weak self] in
            self?.collerMaintenant(item, texteBrut: texteBrut, restaurer: restaurer)
        }
    }

    /// L'écriture elle-même, qui rend le `changeCount` obtenu. Seul le collage l'appelle
    /// désormais, mais elle reste une fonction à part pour que le QUOI (décidé par
    /// `representationAEcrire`) et le COMMENT (cette conversation avec `NSPasteboard`) ne
    /// se mélangent pas.
    @discardableResult
    private func ecrireDansLePressePapiers(_ item: ClipItem, texteBrut: Bool) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let payload = try? store.payload(item.id)
        switch representationAEcrire(kind: item.kind, texteBrut: texteBrut,
                                     aPayload: payload != nil)
        {
        case .texte:
            pb.setString(item.searchText, forType: .string)
        case .rtf:
            if let payload {
                pb.setData(payload, forType: .rtf)
            }
            pb.setString(item.searchText, forType: .string)
        case .image:
            if let payload {
                // L'entrée a été capturée en TIFF OU en PNG (`SystemPasteboard.read` prend
                // le premier type disponible), mais la réécrire en dur sous `.tiff` donnait
                // une image illisible quand les octets étaient du PNG : l'app réceptrice
                // décodait du TIFF sur des octets PNG. On reconstruit un `NSImage`, qui
                // décode l'un comme l'autre, et `writeObjects` redéclare les bons types.
                // Repli sur les octets bruts si le décodage échoue, pour ne jamais laisser
                // le presse-papiers vide. Vaut aussi pour les images déjà en base.
                if let image = NSImage(data: payload) {
                    pb.writeObjects([image])
                } else {
                    pb.setData(payload, forType: .tiff)
                }
            }
        }
        return pb.changeCount
    }

    private func collerMaintenant(_ item: ClipItem, texteBrut: Bool, restaurer: Bool) {
        let pb = NSPasteboard.general

        // 1. Sauvegarder l'existant, patron relevé dans Copi.
        //
        // Limitation connue et assumée : `pb.types` ne décrit que le PREMIER
        // `NSPasteboardItem`. Copier trois fichiers depuis le Finder puis coller une
        // entrée ancienne restaurerait une sélection réduite à un fichier. La portée
        // reste étroite depuis que la restauration n'est plus le défaut
        // (`restaurationParDefaut`), donc ce trou est documenté et non rebouché : le
        // reboucher demanderait de parcourir `pb.pasteboardItems` et de recréer
        // chaque item, pour un chemin que personne n'emprunte par défaut.
        let sauvegarde = pb.types?.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
            pb.data(forType: type).map { (type, $0) }
        } ?? []

        // 2. Écrire l'élément choisi. Le QUOI est décidé par la fonction pure, il
        // ne reste ici que le COMMENT, c'est-à-dire les appels à NSPasteboard, et il
        // est partagé avec la copie du menu de barre : voir `ecrireDansLePressePapiers`.
        let apresEcriture = ecrireDansLePressePapiers(item, texteBrut: texteBrut)

        // 2 bis. Prévenir la capture que ce compteur vient de NOUS. Sans cette ligne,
        // notre propre écriture revient en base : coller une entrée RTF en texte brut
        // n'écrit que `searchText` en `.string`, le hash diffère de l'entrée d'origine
        // et `Store.insert` crée un doublon texte, à chaque collage.
        capture.ignorerJusqua(apresEcriture)

        // 3. Synthétiser le Cmd-V, signé comme venant de nous. La synthèse est partagée
        // avec le relais natif, voir `poserCmdV`.
        Paster.poserCmdV()

        // 4. Restaurer, et par défaut NON. La garde pure ne couvre que la moitié de
        // la course, celle d'une application qui écrit : une cible qui se contente de
        // LIRE tard obtiendrait l'ancien contenu sans que rien ne l'annonce. L'entrée
        // collée reste donc dans le presse-papiers. Voir `restaurationParDefaut`.
        guard restaurer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard doitRestaurer(sauvegardeVide: sauvegarde.isEmpty,
                                changeCountApresEcriture: apresEcriture,
                                changeCountActuel: pb.changeCount) else { return }
            pb.clearContents()
            for (type, data) in sauvegarde {
                pb.setData(data, forType: type)
            }
        }
    }
}
