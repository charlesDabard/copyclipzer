import Foundation

/// Le moyen d'ouvrir le panneau de recherche, choisi par l'utilisateur.
///
/// Un SEUL moyen à la fois (arbitré le 2026-11-08) : choisir fn+Maj coupe ⌥⌘V, et
/// inversement. Avant, les deux cohabitaient et l'utilisateur ne savait pas qu'une
/// combinaison lui était prise. Le choix est imposé au premier lancement : tant qu'il
/// vaut nil, AUCUN raccourci n'est actif, et la fenêtre de choix ne se ferme pas sans lui.
///
/// Pur, comme `RaccourciGlobal` : symlinké dans la cible de test et dans le harnais de
/// capture, il ne lit ni `UserDefaults` ni `CGEventFlags`.
enum RaccourciDOuverture: Equatable {
    /// fn puis Maj tenus seuls et relâchés, voir `AccordFnMaj`. Proposé en premier : c'est
    /// l'accord le plus naturel sur un clavier Mac, et il ne prend aucune combinaison.
    case accordFnMaj
    /// Une touche plus des modificateurs. `touche` est le caractère lu au moment de
    /// l'enregistrement, dans la disposition de l'utilisateur : le keycode 12 est Q en
    /// QWERTY et A en AZERTY, donc un libellé recalculé depuis le seul keycode mentirait.
    case combinaison(RaccourciGlobal, touche: String)

    /// Ce que le tap compare à chaque frappe. nil pour l'accord, qui n'a pas de touche.
    var combinaison: RaccourciGlobal? {
        if case let .combinaison(r, _) = self {
            return r
        }
        return nil
    }

    var estAccordFnMaj: Bool {
        self == .accordFnMaj
    }

    /// L'égalité porte sur la combinaison et non sur le libellé : ⌥⌘V enregistré à la main
    /// est le même raccourci que ⌥⌘V proposé, même si la touche a été lue « v ».
    static func == (a: RaccourciDOuverture, b: RaccourciDOuverture) -> Bool {
        switch (a, b) {
        case (.accordFnMaj, .accordFnMaj): return true
        case let (.combinaison(x, _), .combinaison(y, _)): return x == y
        default: return false
        }
    }

    /// Le libellé affiché, dans l'ordre canonique des menus macOS : ⌃⌥⇧⌘ puis la touche.
    var libelle: String {
        switch self {
        case .accordFnMaj:
            return "fn + ⇧"
        case let .combinaison(r, touche):
            return libelleDesModificateurs(option: r.option, commande: r.commande,
                                           majuscule: r.majuscule, controle: r.controle)
                + nomDeTouche(keycode: r.keycode, lue: touche)
        }
    }

    /// Les choix proposés, dans l'ordre de la fenêtre et du menu. fn+Maj en tête, puis
    /// les quatre combinaisons qui existaient déjà dans le menu de l'engrenage.
    static let proposes: [RaccourciDOuverture] = [
        .accordFnMaj,
        .combinaison(.defaut, touche: "V"),
        .combinaison(RaccourciGlobal(keycode: 49, option: false, commande: true,
                                     majuscule: false, controle: true), touche: " "),
        .combinaison(RaccourciGlobal(keycode: 8, option: true, commande: true,
                                     majuscule: false, controle: false), touche: "C"),
        .combinaison(RaccourciGlobal(keycode: 9, option: true, commande: true,
                                     majuscule: false, controle: true), touche: "V"),
    ]
}

/// Les modificateurs dans l'ordre canonique des menus macOS : ⌃⌥⇧⌘. Sert au libellé d'un
/// raccourci, et à l'enregistreur qui affiche en direct ce que les doigts tiennent.
func libelleDesModificateurs(option: Bool, commande: Bool, majuscule: Bool, controle: Bool) -> String {
    (controle ? "⌃" : "") + (option ? "⌥" : "") + (majuscule ? "⇧" : "") + (commande ? "⌘" : "")
}

/// Le nom affiché d'une touche. Les touches qui n'impriment rien ont un nom fixe (leur
/// keycode ne dépend pas de la disposition) ; les autres prennent le caractère lu, en
/// majuscule comme sur les menus macOS.
func nomDeTouche(keycode: Int, lue: String, langue: LangueDAffichage = langueDAffichage) -> String {
    switch keycode {
    case 49: return langue == .francais ? "Espace" : "Space"
    case 36: return "↩"
    case 48: return "⇥"
    case 51: return "⌫"
    case 53: return "⎋"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default:
        let propre = lue.trimmingCharacters(in: .whitespacesAndNewlines)
        return propre.isEmpty ? "#\(keycode)" : propre.uppercased()
    }
}

/// Pourquoi une combinaison enregistrée à la main est refusée.
enum RefusDeRaccourci: Equatable {
    /// La frappe est un modificateur seul (Maj, Cmd...) : il n'y a pas de touche.
    case toucheModificatrice
    /// Ni Cmd ni Ctrl. Sans eux, la combinaison TAPE un caractère : Maj+A écrit « A »,
    /// et Option+lettre écrit un symbole sur un clavier Mac (⌥E donne « € » en AZERTY).
    /// L'avaler en ferait disparaître un de toutes les applications.
    case sansCmdNiCtrl
    /// Cmd ou Ctrl SEUL plus une touche : c'est le territoire des applications (⌘C, ⌘V,
    /// ⌃C dans un terminal), et ⌘V est en plus le geste historique de Copyclipzer.
    case unSeulModificateur
}

/// Les keycodes des touches de modificateur elles-mêmes (Cmd, Maj, Option, Ctrl et leurs
/// jumelles de droite, Verr. Maj, fn).
private let keycodesModificateurs: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

/// Valide une combinaison avant de l'adopter. nil = acceptée. Règle PURE et testée : c'est
/// la seule barrière entre un enregistrement maladroit et une touche avalée partout.
func refusDuRaccourci(_ r: RaccourciGlobal) -> RefusDeRaccourci? {
    if keycodesModificateurs.contains(r.keycode) {
        return .toucheModificatrice
    }
    guard r.commande || r.controle else { return .sansCmdNiCtrl }
    let nombre = [r.commande, r.controle, r.option, r.majuscule].filter { $0 }.count
    if nombre < 2 {
        return .unSeulModificateur
    }
    return nil
}

/// Le raccourci qui agit vraiment. RIEN tant que la fenêtre de choix est ouverte : on y
/// enregistre une combinaison au clavier, et l'ancien raccourci l'avalerait (enregistrer
/// ⌥⌘V alors que ⌥⌘V est actif n'atteindrait jamais la fenêtre), ou fn+Maj ouvrirait le
/// panneau par-dessus. Et rien non plus tant que le choix n'a jamais été fait.
func raccourciEnVigueur(choix: RaccourciDOuverture?, choixEnCours: Bool) -> RaccourciDOuverture? {
    choixEnCours ? nil : choix
}

/// Les entrées du sous-menu de l'engrenage : les propositions, plus le raccourci actuel
/// s'il a été enregistré à la main. Sans cet ajout, un raccourci personnalisé n'aurait
/// aucune coche, et l'utilisateur ne verrait plus lequel est actif.
func optionsDuMenu(choix: RaccourciDOuverture?) -> [RaccourciDOuverture] {
    guard let choix, !RaccourciDOuverture.proposes.contains(choix) else {
        return RaccourciDOuverture.proposes
    }
    return RaccourciDOuverture.proposes + [choix]
}

/// Les modificateurs tenus à un instant, fn compris. `RaccourciGlobal` n'a pas de fn (une
/// combinaison à touche n'en a pas besoin), mais l'enregistreur, lui, doit le voir : sans
/// lui, fn+Maj s'affichait « ⇧ » et ne pouvait pas s'enregistrer (signalé le 2026-11-08).
struct Modificateurs: Equatable {
    var fn = false
    var option = false
    var commande = false
    var majuscule = false
    var controle = false

    static let aucun = Modificateurs()
    var vide: Bool { self == .aucun }

    func union(_ autre: Modificateurs) -> Modificateurs {
        Modificateurs(fn: fn || autre.fn, option: option || autre.option,
                      commande: commande || autre.commande, majuscule: majuscule || autre.majuscule,
                      controle: controle || autre.controle)
    }

    /// « fn + ⇧ » comme le libellé de l'accord, sinon les symboles seuls : « ⌃⇧ ».
    var libelle: String {
        let symboles = libelleDesModificateurs(option: option, commande: commande,
                                               majuscule: majuscule, controle: controle)
        guard fn else { return symboles }
        return symboles.isEmpty ? "fn" : "fn + " + symboles
    }
}

/// L'enregistreur d'un accord de modificateurs SEULS, comme fn+Maj. Il retient le maximum
/// de ce qui a été tenu (on relâche rarement deux touches dans la même milliseconde) et le
/// rend au relâchement complet, à condition qu'aucune touche ordinaire n'ait été frappée
/// entre-temps : dans ce cas, c'est une combinaison à touche, que `enregistrer` traite.
///
/// Pur et testé, sur le modèle d'`AccordFnMaj`.
struct EnregistreurDAccord {
    /// Le maximum tenu depuis le dernier relâchement complet. C'est aussi ce que la
    /// fenêtre affiche : il reste à l'écran après le relâchement.
    private(set) var pic = Modificateurs.aucun
    /// Une touche ordinaire a été frappée depuis le dernier relâchement complet. La
    /// fenêtre affiche alors la combinaison, et non plus le pic des modificateurs.
    private(set) var touchee = false

    /// À chaque changement de modificateurs. Rend l'accord complet quand tout est relâché.
    mutating func modificateurs(_ tenus: Modificateurs) -> Modificateurs? {
        if tenus.vide {
            defer { pic = .aucun; touchee = false }
            return touchee || pic.vide ? nil : pic
        }
        pic = pic.union(tenus)
        return nil
    }

    /// Une touche ordinaire a été frappée : l'accord en cours n'en est plus un.
    mutating func frappe() { touchee = true }
}

/// Le choix qui correspond à un accord de modificateurs seuls, ou nil. Seul fn+Maj est
/// détecté par le tap (`AccordFnMaj`) : un autre accord serait enregistré sans jamais
/// pouvoir ouvrir le panneau.
func choixPourAccord(_ accord: Modificateurs) -> RaccourciDOuverture? {
    accord == Modificateurs(fn: true, majuscule: true) ? .accordFnMaj : nil
}
