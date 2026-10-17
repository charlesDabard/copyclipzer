import Foundation

enum HotKeyKey: Equatable {
    case v, up, down, digit(Int), z, x, escape, other
}

enum HotKeyInput: Equatable {
    case modificateurDown, modificateurUp, key(HotKeyKey)
    /// La souris a BOUGÉ au-dessus du panneau ouvert. Ne vient pas du tap clavier mais
    /// d'un moniteur de mouvement : c'est le seul endroit du produit où la souris parle
    /// à la machine, et c'est ce qui permet de cliquer un bouton sans que relâcher Cmd
    /// colle l'entrée sous les doigts.
    ///
    /// Un MOUVEMENT, et surtout pas un simple survol. Mesuré en usage réel le
    /// 2026-09-01, sur signalement : l'overlay s'ouvre au CENTRE de l'écran, donc très
    /// souvent sous un curseur qui n'a pas bougé, et un `onHover` SwiftUI se déclenche
    /// à l'apparition de la vue. Le panneau se figeait donc tout seul, sans que
    /// personne ait touché la souris, et relâcher Cmd ne collait plus ni ne fermait
    /// plus. Un survol n'est pas une intention, un mouvement en est une.
    case sourisEntree
    /// Le bouton corbeille du panneau. Passe par la machine et non par l'assemblage
    /// parce que supprimer DÉCALE la liste : le recalage de `count` et de `index` est
    /// une règle, pas un détail d'affichage, et une règle se teste.
    case supprimerLaSelection
    /// Une frappe RÉPÉTÉE par le clavier (touche tenue), hors flèches. Ce n'est pas une
    /// intention : maintenir Cmd-V une demi-seconde de trop faisait défiler l'historique
    /// au rythme de la répétition (450 ms puis 75 ms sur ce poste, mesuré le 2026-10-17
    /// dans `InitialKeyRepeat` et `KeyRepeat`), et relâcher collait une AUTRE entrée que
    /// celle du presse-papiers. Les flèches, elles, gardent leur répétition : tenir la
    /// flèche bas pour descendre la liste est un geste voulu.
    case repetition
}

enum HotKeyOutput: Equatable {
    case rien
    case ouvrir
    case deplacer(Int)
    case allerA(Int)
    case basculerTexteBrut
    case basculerEpingle
    case fermer
    case coller(index: Int, texteBrut: Bool)
    /// Reposer le Cmd-V d'origine, sans rien lire ni écrire dans le presse-papiers.
    /// Voir `aNavigue` : c'est la protection de fidélité de tous les collages de la
    /// machine, et non un raccourci d'implémentation.
    case collerNatif
    /// Reposer le Cmd-V d'origine PUIS rejouer la frappe en cours, dans cet ordre. C'est
    /// la sortie d'un raccourci Cmd enchaîné sur un Cmd-V sans relâcher Cmd : Cmd-V puis
    /// Cmd-Entrée pour envoyer, Cmd-V puis Cmd-S pour enregistrer. Voir
    /// `(.ouvert, .key(.other))`.
    case collerNatifPuisRejouer
    /// Retirer l'entrée de ce rang. La machine a déjà recalé `count` et `index` quand
    /// elle le rend : l'assemblage n'a plus qu'à supprimer en base et relire.
    case supprimer(index: Int)
}

enum HotKeyState: Equatable { case inactif, arme, ouvert }

/// Le geste : maintenir Cmd, puis V ouvre la liste, V et les flèches naviguent,
/// 2 à 9 sautent directement au rang, Z bascule le collage en texte brut, X
/// épingle, Échap annule, et relâcher Cmd colle la ligne sélectionnée.
///
/// Cmd et non Ctrl depuis le 2026-08-26. Le plan affirmait « Ctrl-V est libre sur
/// macOS », vrai du système et faux du poste de travail : Claude Code s'en sert pour
/// coller une image, et Copyclipzer l'avalait. La contrepartie de ce déplacement est
/// que Cmd-V est LE collage du système, donc chaque collage de la machine passe
/// désormais par ici, d'où `aNavigue` et `.collerNatif`.
///
/// Fichier PUR : la machine ne connaît ni CGEvent ni AppKit, uniquement des
/// entrées décrites par un type maison. Chaque transition du diagramme de la
/// spec est donc un test, sans interface graphique.
///
/// Le second membre du couple rendu par `recevoir` dit au tap s'il doit AVALER
/// l'événement. C'est ce qui empêche le « 3 » de s'écrire dans le document
/// pendant qu'il sélectionne la troisième entrée. Un simple moniteur NSEvent,
/// comme celui de QuickTasks, ne peut pas faire ça : il observe sans consommer.
struct HotKeyMachine {
    var count: Int
    private(set) var etat: HotKeyState = .inactif
    private(set) var index: Int = 0
    private(set) var texteBrut: Bool = false

    /// Vrai dès que l'utilisateur a touché à quoi que ce soit depuis l'ouverture.
    /// Remis à `false` à chaque ouverture. Voir `(.ouvert, .modificateurUp)` pour ce
    /// qu'il commande.
    private(set) var aNavigue: Bool = false

    /// Vrai dès que la souris est entrée dans le panneau ouvert.
    ///
    /// Tant qu'il est vrai, relâcher Cmd ne colle plus et ne ferme plus. Sans lui,
    /// cliquer un bouton du panneau exigerait de tenir Cmd d'une main et la souris de
    /// l'autre, et le moindre relâchement collerait l'entrée au lieu de la supprimer,
    /// c'est-à-dire l'inverse exact de l'intention.
    ///
    /// Il ne se lève PAS quand la souris ressort : le trajet du curseur entre deux
    /// lignes passe par des pixels qui n'appartiennent à aucune, et rendre le collage
    /// accidentel à ce moment-là serait pire que ne pas figer du tout.
    private(set) var fige: Bool = false

    mutating func recevoir(_ input: HotKeyInput) -> (HotKeyOutput, consomme: Bool) {
        switch (etat, input) {
        case (.inactif, .modificateurDown):
            etat = .arme
            return (.rien, false)

        case (.arme, .modificateurUp):
            etat = .inactif
            return (.rien, false)

        case (.arme, .key(.v)):
            guard count > 0 else { return (.rien, false) }
            etat = .ouvert
            index = 0
            texteBrut = false
            // Remise à zéro OBLIGATOIRE, et pas seulement à l'initialisation : la
            // machine survit à tout le geste suivant. Un `aNavigue` resté vrai depuis
            // le geste d'avant enverrait le prochain Cmd-V ordinaire dans notre base.
            aNavigue = false
            // Remise à zéro pour la même raison qu'`aNavigue` : la machine survit au
            // geste. Un `fige` resté vrai figerait le geste SUIVANT dès son ouverture,
            // et le collage ne partirait plus jamais au relâchement.
            fige = false
            return (.ouvrir, true)

        case (.ouvert, .key(.v)), (.ouvert, .key(.down)):
            // CYCLE et non saturation. Demande le 2026-08-26, apres usage :
            // maintenir Cmd et marteler V doit revenir en tete une fois la derniere
            // ligne atteinte, sinon la touche cesse de repondre et l'utilisateur croit
            // que le geste est casse. Le comportement d'un anneau, pas d'une butee.
            index = count > 0 ? (index + 1) % count : 0
            aNavigue = true
            return (.deplacer(1), true)

        case (.ouvert, .key(.up)):
            index = count > 0 ? (index - 1 + count) % count : 0
            aNavigue = true
            return (.deplacer(-1), true)

        case let (.ouvert, .key(.digit(n))):
            let cible = n - 1
            // Un rang hors liste ne change pas l'index, donc il ne compte pas comme
            // une navigation : le collage natif reste légitime après un « 0 » tapé
            // par erreur, et il vaut de toute façon l'entrée de rang 1.
            guard cible >= 0, cible < count else { return (.rien, true) }
            index = cible
            aNavigue = true
            return (.allerA(cible), true)

        case (.ouvert, .key(.z)):
            texteBrut.toggle()
            aNavigue = true
            return (.basculerTexteBrut, true)

        case (.ouvert, .key(.x)):
            aNavigue = true
            return (.basculerEpingle, true)

        case (.ouvert, .key(.escape)):
            etat = .arme
            fige = false
            return (.fermer, true)

        case (.ouvert, .sourisEntree):
            fige = true
            return (.rien, false)

        case (.ouvert, .supprimerLaSelection):
            guard count > 0, index < count else { return (.rien, false) }
            let cible = index
            count -= 1
            // La liste vidée, il n'y a plus rien à montrer ni à coller : le panneau se
            // referme de lui-même, sinon il resterait ouvert sur zéro ligne, ce qui ne
            // se distingue pas d'un panneau bloqué.
            if count == 0 {
                etat = .arme
                fige = false
                index = 0
                return (.supprimer(index: cible), false)
            }
            // L'index recule quand c'était la dernière ligne, sinon il désignerait un
            // rang qui n'existe plus et le collage suivant sortirait de la liste.
            index = min(index, count - 1)
            aNavigue = true
            return (.supprimer(index: cible), false)

        case (.ouvert, .modificateurUp):
            // Figé : le relâchement de Cmd ne veut plus rien dire. L'utilisateur est
            // passé à la souris, il sortira par Échap ou par un clic ailleurs.
            guard !fige else { return (.rien, false) }
            etat = .inactif
            // LA protection de fidélité de la tâche 15. Sans navigation, l'utilisateur
            // a simplement fait un Cmd-V : on ne colle pas depuis la base, on repose
            // son événement d'origine. Le presse-papiers n'est ni lu ni écrit, donc
            // une image ou une liste de fichiers ne peut pas y perdre de types.
            //
            // Le contraire, `.coller` d'office, ferait passer TOUS les collages de la
            // machine par notre aller-retour SQLite : c'est le sabotage 1 du brief.
            guard aNavigue else { return (.collerNatif, false) }
            return (.coller(index: index, texteBrut: texteBrut), false)

        case (.ouvert, .key(.other)):
            // Une touche qui n'appartient pas au geste, alors que l'utilisateur n'a rien
            // fait d'autre que Cmd-V : il ne naviguait pas, il enchaînait un raccourci.
            // L'avaler, c'était perdre son Cmd-S, son Cmd-Entrée, son Cmd-A, et ne coller
            // qu'au relâchement de Cmd, APRÈS la touche qu'il croyait avoir tapée. Signalé
            // le 2026-10-17 sous la forme « les Cmd ne marchent pas ». On rend donc son
            // collage natif tout de suite, puis sa frappe, dans l'ordre. La machine revient
            // à `.arme` : Cmd est toujours tenu, un V suivant rouvrira un geste neuf.
            //
            // Une fois la navigation commencée, ou le panneau figé à la souris, la touche
            // reste avalée : l'utilisateur est DANS le geste, et un caractère parasite ne
            // doit pas s'écrire dans le document caché sous la liste.
            guard !aNavigue, !fige else { return (.rien, true) }
            etat = .arme
            return (.collerNatifPuisRejouer, true)

        case (.ouvert, .repetition):
            return (.rien, true)

        default:
            return (.rien, false)
        }
    }
}

/// Codes de touches virtuelles macOS, disposition indépendante.
///
/// La table vit ici et non dans `EventTap.swift`, comme le prévoit le repli du
/// brief : EventTap importe AppKit, or symlinker un fichier AppKit dans la cible
/// de test lie tout CoreGraphics au binaire des tests (mesuré tâche 8, remesuré
/// tâche 10 : 9 bibliothèques ajoutées, dont Metal et QuartzCore). La traduction
/// est le seul morceau pur du tap, elle reste donc du côté pur pour être testée
/// sans traîner l'interface graphique derrière elle.
extension HotKeyKey {
    /// Traduit une frappe en touche du geste.
    ///
    /// `caractere` est ce que la disposition ACTIVE produit pour cette touche, Cmd ignoré.
    /// Z et X se reconnaissent par lui, et plus par leur position. Correction du
    /// 2026-10-17 : la table ne connaissait que la position QWERTY, or sur la disposition
    /// française de ce poste le code 6 rend « w » et le code 13 rend « z » (mesuré par
    /// `CGEvent.keyboardGetUnicodeString`). La touche marquée Z ne faisait donc rien et
    /// était avalée, pendant que Cmd-W, fermer la fenêtre, basculait le texte brut.
    ///
    /// Le reste garde la POSITION, exprès. Échap et les flèches n'ont pas de caractère
    /// imprimable. Les chiffres non plus sur AZERTY, où la rangée du haut rend « & é " ' »
    /// sans Maj, alors que Cmd-1 y reste la même touche physique. Et V reste le code 9
    /// parce que c'est ce code que `Paster.poserCmdV` repose : reconnaître V au caractère
    /// sur une disposition où il vit ailleurs (Dvorak) ferait ouvrir le geste sur un
    /// Cmd-V puis reposer une autre touche.
    ///
    /// Sans caractère (nil ou vide), repli sur la position QWERTY d'avant, pour qu'une
    /// frappe sans texte reste traduite comme elle l'a toujours été.
    static func traduire(_ code: Int64, caractere: String? = nil) -> HotKeyKey? {
        switch code {
        case 9: return .v
        case 53: return .escape
        case 125: return .down
        case 126: return .up
        default: break
        }
        if let chiffre = chiffreDeLaTouche(code) {
            return .digit(chiffre)
        }
        if let lettre = caractere?.lowercased(), !lettre.isEmpty {
            switch lettre {
            case "z": return .z
            case "x": return .x
            default: return nil
            }
        }
        switch code {
        case 6: return .z
        case 7: return .x
        default: return nil
        }
    }
}

/// Le type d'un événement clavier, vu du côté pur. `EventTap` traduit son
/// `CGEventType` en ceci et rien de plus : c'est la seule ligne de CoreGraphics
/// qu'il garde pour lui.
enum HotKeyEventType: Equatable { case keyDown, flagsChanged, autre }

/// Ce que le tap doit faire d'un événement.
enum HotKeyDecision: Equatable {
    /// Laisser filer, sans rien dire à la machine.
    case relayer
    /// Prévenir la machine, puis laisser filer QUOI QU'ELLE RÉPONDE. C'est le cas
    /// des modificateurs : les avaler laisserait Cmd coincé enfoncé pour
    /// l'application de devant.
    case relayerApres(HotKeyInput)
    /// Déclencher une capture immédiate, puis laisser filer. Cmd-C et Cmd-X sont
    /// observés, jamais consommés : c'est ce qui remplace un polling rapide.
    ///
    /// Seulement tant que l'overlay est FERMÉ. Ouvert, X épingle et C ne veut rien
    /// dire : ces deux touches appartiennent alors au geste, pas au système.
    case capturerPuisRelayer
    /// Soumettre l'entrée à la machine, qui dira seule s'il faut avaler.
    case soumettre(HotKeyInput)
}

/// Aiguillage du tap, en fonction PURE.
///
/// Elle vit ici et non dans `EventTap.swift` parce que ce fichier importe
/// CoreGraphics et ne peut pas être symlinké dans la cible de test sans lier neuf
/// bibliothèques graphiques au binaire (mesuré tâche 8, remesuré tâche 10). Sa
/// signature ne cite donc ni `CGEvent`, ni `CGEventType`, ni `CGEventFlags` :
/// uniquement des booléens, un code brut et des types maison. Toute entorse à
/// cette règle ramènerait CoreGraphics et annulerait le bénéfice de l'extraction.
///
/// Ce n'est pas un test de plus, c'est un chemin qui n'était pas testable et qui
/// le devient : le finding 1, une touche non mappée relayée à l'application de
/// devant pendant que l'overlay est ouvert, se mesure ici.
///
/// `estSynthetique` est un PARAMÈTRE, et non un `return` anticipé dans
/// `EventTap.traiter` : posée dans le tap, la règle vivrait dans le seul fichier
/// du projet que les tests ne peuvent pas atteindre. Le tap se contente de lire
/// les champs et de les passer, la décision reste ici.
///
/// Ce que le filtre évite, corrigé le 2026-08-26. Le motif écrit jusque-là, « notre
/// Cmd-V émet aussi un changement de modificateurs qui serait lu comme un
/// relâchement du modificateur », ne se produit PAS : poser un `CGEvent` clavier avec des
/// `flags` ne génère aucun `flagsChanged` distinct. Le vrai cas est celui-ci : notre
/// keyDown V (code 9), non filtré, serait soumis à la machine, et si l'utilisateur
/// ré-enfonce Cmd avant que l'événement posté ne soit traité, la machine est en
/// `.arme`, `(.arme, .key(.v))` rend `(.ouvrir, consomme: true)` et notre propre
/// Cmd-V est avalé : l'overlay se rouvre et rien n'est collé.
///
/// Les quatre modificateurs sont NOMMÉS séparément depuis la tâche 15, et ce n'est
/// pas de la verbosité : trois d'entre eux servent à décider de ne RIEN faire. La
/// distinction porte tout le comportement, la fondre en un seul booléen l'effacerait.
///
/// `etat` est l'état VIVANT du geste, lu au moment de la décision, et il n'a qu'un
/// seul usage : effacer la capture de Cmd-C et Cmd-X pendant que l'overlay est
/// ouvert. Sans lui, un X d'épinglage couperait aussi la sélection de l'application
/// de dessous. Il est passé sans valeur par défaut, exprès : un défaut ferait passer
/// pour « overlay fermé » tout site d'appel qui l'aurait oublié, y compris le tap.
///
/// `caractere` et `estRepetition` ont une valeur par défaut, contrairement à `etat`, parce
/// qu'une omission n'y fabrique pas un faux « overlay fermé » : sans caractère, Z et X
/// retombent sur leur position QWERTY d'avant, et sans le drapeau la répétition navigue
/// comme avant. Le tap les passe tous les deux, et un test lit sa source pour le vérifier.
func decider(type: HotKeyEventType, commandEnfonce: Bool, majEnfonce: Bool,
             optionEnfonce: Bool, controlEnfonce: Bool,
             estSynthetique: Bool, code: Int64,
             etat: HotKeyState,
             caractere: String? = nil, estRepetition: Bool = false) -> HotKeyDecision
{
    if estSynthetique {
        return .relayer
    }

    // LE modificateur du geste, et le seul endroit du projet qui le nomme. Ctrl
    // jusqu'au 2026-08-26, Cmd depuis : « Ctrl-V est libre sur macOS » était vrai du
    // système et faux du poste de travail, où Claude Code s'en sert pour coller une
    // image. Ces deux lignes sont le point de bascule complet, c'est aussi par elles
    // que passe le sabotage 3 du brief.
    let modificateurDuGeste = commandEnfonce
    let autresModificateurs = majEnfonce || optionEnfonce || controlEnfonce

    switch type {
    case .flagsChanged:
        return .relayerApres(modificateurDuGeste ? .modificateurDown : .modificateurUp)

    case .keyDown:
        // La capture ne vaut QUE tant que l'overlay est fermé, donc dans `.inactif`
        // et `.arme`. Le brief la demandait inconditionnelle, mais il a été écrit
        // avant que Cmd ne devienne le modificateur du geste, et les deux se
        // contredisaient : X épingle, donc overlay ouvert, un Cmd-X aurait épinglé
        // ET coupé la sélection dans l'application de dessous. Arbitré le
        // 2026-08-26 : ouvert, on consomme ce qui appartient au geste et on ne
        // laisse filer que le reste. C'est déjà la règle de `.other`.
        if commandEnfonce, etat != .ouvert, code == 8 || code == 7 {
            return .capturerPuisRelayer
        }

        // Sans le modificateur du geste, rien ne va à la machine. C'est ce qui rend
        // Ctrl-V, Ctrl-K et tout le reste à leur application : depuis que le geste
        // s'arme sur Cmd, la machine ne peut être ouverte QUE si Cmd est enfoncé, donc
        // soumettre une frappe nue ne servirait plus rien et pourrait l'avaler.
        guard modificateurDuGeste else { return .relayer }

        // Cmd plus un autre modificateur n'appartient jamais au geste, et c'est le cas
        // le plus dangereux du déplacement vers Cmd : Cmd-Maj-V colle sans mise en
        // forme dans beaucoup d'applications, l'avaler casserait cette fonction partout
        // à la fois. Cmd-Opt-V, Cmd-Ctrl-V et Cmd-Maj-3 sont dans le même cas. Ce cas
        // n'existait pas avec Ctrl.
        if autresModificateurs {
            return .relayer
        }

        // Repli sur `.other`, et surtout PAS abandon. Une touche non traduite qui
        // repart vers l'application de devant y arrive avec Cmd toujours enfoncé :
        // Cmd-K ouvre une recherche, Cmd-Entrée valide, Cmd-Espace ouvre Spotlight.
        // La machine ne consomme `.other` qu'en état ouvert, donc les raccourcis Cmd
        // ordinaires continuent de passer tant que l'overlay est fermé.
        let touche = HotKeyKey.traduire(code, caractere: caractere) ?? .other
        // La répétition automatique ne navigue plus, sauf aux flèches : voir
        // `HotKeyInput.repetition`. La machine ne l'avale qu'overlay ouvert, donc une
        // touche tenue hors du geste se répète normalement dans l'application.
        if estRepetition, touche != .up, touche != .down {
            return .soumettre(.repetition)
        }
        return .soumettre(.key(touche))

    case .autre:
        return .relayer
    }
}

/// Un raccourci clavier global, décrit par sa touche et ses quatre modificateurs.
///
/// C'est un type PUR, volontairement séparé de `CGEventFlags` comme de tout AppKit : il
/// est symlinké dans la cible de test avec le reste de ce fichier, donc la comparaison
/// d'un raccourci se mesure sans lier CoreGraphics. Le raccourci par défaut est ⌥⌘V, et
/// non le geste Cmd seul : c'est justement l'Option ajoutée qui le DÉSAMBUIGUË du geste
/// historique (Cmd maintenu plus V), et qui permet au raccourci d'être détecté puis
/// consommé AVANT que la machine à états ne le voie.
struct RaccourciGlobal: Equatable {
    let keycode: Int
    let option: Bool
    let commande: Bool
    let majuscule: Bool
    let controle: Bool

    /// ⌥⌘V. Le code 9 est celui de V, voir `HotKeyKey.traduire`.
    static let defaut = RaccourciGlobal(keycode: 9, option: true, commande: true,
                                        majuscule: false, controle: false)
}

/// Vrai seulement si la touche ET les quatre modificateurs correspondent EXACTEMENT au
/// raccourci configuré. L'exactitude est la garantie tout entière : une comparaison qui
/// ignorerait un modificateur confondrait Cmd+V, le collage ordinaire du système, avec
/// ⌥⌘V, et avalerait chaque Cmd-V de toutes les applications. Chaque modificateur qui
/// diverge est donc un refus, et c'est précisément ce que le sabotage de l'Option mesure.
func correspondAuRaccourci(keycode: Int, option: Bool, commande: Bool,
                           majuscule: Bool, controle: Bool,
                           raccourci: RaccourciGlobal) -> Bool
{
    keycode == raccourci.keycode
        && option == raccourci.option
        && commande == raccourci.commande
        && majuscule == raccourci.majuscule
        && controle == raccourci.controle
}

/// Faut-il relire l'historique AVANT de soumettre cette entrée à la machine ?
///
/// Le compte borne tout le geste : le cycle `(index + 1) % count`, `cible < count`, et
/// le `guard count > 0` qui refuse d'ouvrir sur une liste vide. Il doit donc être à
/// jour à l'instant précis où l'overlay s'ouvre, c'est-à-dire quand V arrive alors
/// que Cmd est déjà maintenu.
///
/// À cet instant, et à cet instant seulement. Le relire à chaque `.modificateurDown`
/// marchait tant que le geste s'armait sur Ctrl, qui ne servait à rien d'autre. Le
/// geste s'arme sur Cmd depuis le 2026-08-26, donc ce chemin passait par une requête
/// SQLite à CHAQUE Cmd-C, Cmd-S, Cmd-Tab, Cmd-Q, pour une valeur dont aucun de ces
/// raccourcis ne fait quoi que ce soit. Arbitré le 2026-08-26 : une lecture par geste
/// réel, au lieu d'une par appui sur Cmd.
///
/// Fonction PURE, et c'est tout l'intérêt : posée en `if` dans `AppDelegate.swift`,
/// la règle vivrait dans le seul fichier du projet que les tests ne peuvent pas
/// atteindre. La machine, elle, reste sans dépendance : elle ne va rien chercher,
/// c'est l'assemblage qui la nourrit avant de lui parler.
func doitRelireLeCompte(etat: HotKeyState, input: HotKeyInput) -> Bool {
    guard case .key(.v) = input else { return false }
    return etat == .arme
}

/// Le relâchement de Cmd a-t-il été MANQUÉ ? Vrai quand la machine attend encore un
/// relâchement alors que le clavier dit que Cmd n'est plus tenu.
///
/// Le cas n'a rien de théorique. macOS coupe un tap qui répond trop lentement
/// (`tapDisabledByTimeout`), et les événements de cette fenêtre passent sans nous : si le
/// relâchement de Cmd y tombe, la machine reste `.ouvert`. Le geste bloqué avalait alors
/// le raccourci Cmd suivant, et le prochain modificateur relâché, Maj seul par exemple,
/// déclenchait un collage fantôme au milieu d'une autre frappe. Le chien de garde de
/// l'assemblage relit l'état matériel de Cmd et soumet ce relâchement lui-même.
///
/// `.arme` compte aussi : le rattrapage y est sans effet visible (retour au repos), mais
/// laisser la machine armée sans Cmd fausserait le geste suivant.
func relachementManque(etat: HotKeyState, commandeTenue: Bool) -> Bool {
    etat != .inactif && !commandeTenue
}
