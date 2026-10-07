import Foundation

// Les décisions PURES du menu de barre : quelles entrées apparaissent, dans quel
// ordre, jusqu'où, et avec quel libellé.
//
// Ce fichier est symlinké dans la cible de test, il n'importe donc ni AppKit ni
// SwiftUI. Ce qui reste dans `AppDelegate.swift` est la seule conversation avec
// `NSMenu` et `NSSearchField`, c'est-à-dire ce qu'aucun test ne peut atteindre.

/// Plafond du menu de barre, fixé à l'usage le 2026-08-26.
///
/// Cinq cents lignes tiennent parce que le menu n'affiche que `title`, déjà en base :
/// aucune charge utile n'est lue à l'ouverture. `payload` ne se lit qu'au clic, et
/// pour la seule entrée cliquée. Sans cette règle, ouvrir le menu chargerait cinq
/// cents images.
let plafondDuMenu = 500

/// Nombre de lignes qui portent un raccourci de rang. Neuf et pas dix : le geste Cmd
/// maintenu numérote déjà ses entrées de 1 à 9, et un « 0 » pour la dixième serait un
/// second alphabet à retenir pour la même chose.
let lignesAvecRaccourci = 9

/// Plafonds de l'aperçu montré au survol d'une ligne.
///
/// Sans eux, un fichier de log copié ferait un panneau haut comme trois écrans, et un
/// minifié d'une seule ligne ferait un panneau large comme l'écran. Les deux coupes
/// sont donc nécessaires, et une seule ne suffirait pas : un texte de 40 lignes peut
/// dépasser 2 000 caractères, et un texte de 2 000 caractères peut tenir sur une ligne.
let plafondDeLignesDeLApercu = 40
let plafondDeCaracteresDeLApercu = 2000

/// Une ligne du menu de barre, entièrement décidée hors AppKit.
struct LigneDeMenu: Equatable {
    /// L'identifiant de l'entrée d'origine, et non son rang. C'est lui que le
    /// `NSMenuItem` porte en `representedObject` : la liste se reconstruit à chaque
    /// frappe dans le champ de recherche, donc un rang mémorisé désignerait l'entrée
    /// d'avant la frappe.
    let id: String
    /// Rang affiché, à partir de 1.
    let rang: Int
    /// Nom du SF Symbol, rendu par `icone(_:)` et non recalculé ici.
    let icone: String
    /// Titre déjà ramené sur une seule ligne par `titreAffiche(_:)`.
    let titre: String
    /// Vrai pour une entrée épinglée, qui passe devant les autres.
    let epingle: Bool
    /// Le caractère du raccourci de rang, vide au-delà de la neuvième ligne.
    let raccourci: String
    /// La vignette PNG de l'entrée, quand elle en a une. Décidée ici pour que la vue
    /// n'ait rien à aller chercher : elle est déjà chargée par la requête du menu.
    let vignette: Data?
    /// Ce que montre le panneau d'aperçu au survol : le texte COMPLET, plafonné, suivi
    /// de son pied de métadonnées. Décidé ici, dessiné ailleurs.
    let apercu: String
    /// L'action proposée quand le texte de l'entrée EST en entier une URL, une couleur
    /// hexadécimale ou une adresse e-mail. Décidée par `actionPour`, exécutée par AppKit.
    let action: ActionIntelligente?

    /// Ce que le menu écrit sur la ligne : le rang, puis le titre. L'icône est posée à
    /// côté par AppKit, elle n'entre pas dans le libellé.
    var libelle: String {
        "\(rang). \(titre)"
    }
}

/// Le raccourci de rang d'une ligne : « 1 » à « 9 », rien au-delà.
func raccourciDeRang(_ rang: Int) -> String {
    rang >= 1 && rang <= lignesAvecRaccourci ? String(rang) : ""
}

/// L'index de ligne visé par une touche de chiffre, ou `nil` si elle ne désigne rien.
///
/// « 1 » à « 9 » désignent la même chose que le raccourci de rang déjà affiché sur la
/// ligne : « 1 » est la première. Le chiffre est ramené en base zéro (`chiffre - 1`),
/// puis refusé dès qu'il dépasse le nombre de lignes visibles : sur une liste de trois
/// éléments, « 5 » ne doit rien sélectionner du tout, et pas la cinquième ligne d'un
/// autre écran.
///
/// Le passage par `raccourciDeRang` refuse d'un coup « 0 », les chaînes non numériques
/// et les formes calculées comme « +1 » ou « 01 », sans coder un second alphabet de
/// raccourcis qui finirait par diverger du premier.
func indexPourTouche(_ touche: String, nombreDeLignes: Int) -> Int? {
    guard let chiffre = Int(touche), raccourciDeRang(chiffre) == touche else { return nil }
    let index = chiffre - 1
    return index < nombreDeLignes ? index : nil
}

/// Le nom lisible d'un type d'entrée, pour le titre de secours et le pied d'aperçu.
func nomDuType(_ kind: ClipKind) -> String {
    switch kind {
    case .text: return "Texte"
    case .rtf: return "Texte enrichi"
    case .image: return "Image"
    case .files: return "Fichiers"
    }
}

/// Une taille en octets, écrite pour être lue. Fait à la main plutôt qu'avec
/// `ByteCountFormatter`, dont la sortie dépend de la langue du système : un test qui
/// attend « 340 o » tomberait sur une machine anglophone, et ce serait le test qui
/// aurait tort, pas le code.
func tailleLisible(_ octets: Int) -> String {
    if octets < 1024 {
        return "\(octets) o"
    }
    if octets < 1024 * 1024 {
        return String(format: "%.0f Ko", Double(octets) / 1024)
    }
    return String(format: "%.1f Mo", Double(octets) / (1024 * 1024))
}

/// La date d'une entrée, au format court français, fuseau de la machine.
private let formatDeLApercu: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.dateFormat = "dd/MM/yyyy HH:mm"
    return f
}()

func dateLisible(_ horodatage: Double) -> String {
    formatDeLApercu.string(from: Date(timeIntervalSince1970: horodatage))
}

/// Le titre de repli d'une entrée qui n'en a pas.
///
/// Une image copiée depuis Aperçu ou une capture d'écran ne porte AUCUN texte, donc
/// `CaptureService` lui donne un `title` vide, donc sa ligne de menu est vide et son
/// aperçu le serait aussi. Défaut vu à l'écran, pas déduit. Le repli est bâti sur les
/// deux seules métadonnées qui existent toujours : le type et la taille.
func titreDeSecours(_ item: ClipItem) -> String {
    "\(nomDuType(item.kind)) · \(tailleLisible(item.byteSize))"
}

/// Le titre montré sur la ligne : le sien, ou son repli s'il est vide.
///
/// Le test porte sur le titre ROGNÉ : une entrée dont le titre n'est qu'une suite
/// d'espaces ou de sauts de ligne est aussi illisible qu'une entrée sans titre.
func titreOuSecours(_ item: ClipItem) -> String {
    item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? titreDeSecours(item)
        : item.title
}

/// Le corps de l'aperçu : le texte COMPLET de l'entrée, plafonné.
///
/// La source est `searchText`, jamais `title`. `CaptureService` écrit
/// `title: String(texte.prefix(200))` mais `searchText: texte`, sans troncature : le
/// texte entier est donc déjà en base et déjà chargé par la requête du menu. Partir de
/// `title` rendrait l'aperçu strictement inutile, puisqu'il montrerait exactement ce
/// que la ligne montre déjà. Et aucune charge utile n'est lue : la règle du plafond du
/// menu, « ouvrir le menu ne charge pas cinq cents images », survit intacte.
func corpsDeLApercu(_ item: ClipItem) -> String {
    let brut = item.searchText.isEmpty ? titreDeSecours(item) : item.searchText
    var coupe = false

    var lignes = brut.components(separatedBy: "\n")
    if lignes.count > plafondDeLignesDeLApercu {
        lignes = Array(lignes.prefix(plafondDeLignesDeLApercu))
        coupe = true
    }

    var texte = lignes.joined(separator: "\n")
    if texte.count > plafondDeCaracteresDeLApercu {
        texte = String(texte.prefix(plafondDeCaracteresDeLApercu))
        coupe = true
    }

    return coupe ? texte + "…" : texte
}

/// Le pied de l'aperçu : type, taille, date, et l'application source quand elle est
/// connue. Pour une image, c'est la SEULE information lisible de tout le panneau.
///
/// L'application source est ajoutée à la liste plutôt que concaténée avec son
/// séparateur : une source absente laisserait sinon un « · » orphelin en fin de ligne.
func piedDeLApercu(_ item: ClipItem) -> String {
    var morceaux = [nomDuType(item.kind), tailleLisible(item.byteSize), dateLisible(item.createdAt)]
    if let source = item.sourceBundleID, !source.isEmpty {
        morceaux.append(source)
    }
    return morceaux.joined(separator: " · ")
}

/// Vrai quand le corps de l'aperçu ne dirait rien de plus que son pied.
///
/// Une entrée sans texte, donc une image ou un fichier muet, retombe sur
/// `titreDeSecours` dans les deux : le panneau affichait « Image · 83 Ko » en corps ET
/// « Image · 83 Ko · date · app » en pied, deux fois la même chose l'une au-dessus de
/// l'autre. Défaut vu sur une capture rendue le 2026-09-01, invisible au raisonnement.
///
/// Ne concerne QUE le panneau, qui a un pied. Le corps seul, lui, doit continuer à
/// rendre le secours, sinon il serait vide.
func corpsRedondantAvecLePied(_ item: ClipItem) -> Bool {
    item.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// L'aperçu complet montré au survol : le corps, une ligne vide, puis le pied.
func apercuDeLaLigne(_ item: ClipItem) -> String {
    corpsDeLApercu(item) + "\n\n" + piedDeLApercu(item)
}

/// Vrai si l'entrée répond au texte cherché. Une recherche vide, ou faite de seuls
/// espaces, accepte tout le monde : c'est l'état du champ à l'ouverture du menu.
///
/// Le titre ET le `searchText` sont regardés, dans cet ordre, exactement comme l'index
/// FTS5 qui porte les deux colonnes. Le titre est tronqué à 200 caractères par la
/// capture, donc une correspondance trouvée par la base au milieu d'un texte long
/// n'apparaîtrait nulle part dans le titre : filtrer sur le seul titre effacerait
/// silencieusement une partie des résultats rendus par `Store.search`.
///
/// Casse et accents ignorés : chercher « url » doit trouver « URL », et « reference »
/// doit trouver « référence ».
func correspondALaRecherche(_ item: ClipItem, recherche: String) -> Bool {
    let q = recherche.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return true }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return item.title.range(of: q, options: options) != nil
        || item.searchText.range(of: q, options: options) != nil
}

/// Les lignes du menu de barre : filtrées, ordonnées, plafonnées, numérotées.
///
/// L'ordre est celui de Maccy et de Pastebot : les épinglées d'abord, puis la date
/// décroissante. Entre deux épinglées, la date tranche encore, donc l'épinglage passe
/// devant le second critère au lieu de l'écraser.
///
/// Limitation assumée, et elle est dans le plafond de l'appelant, pas ici :
/// `Store.search` coupe déjà à `plafondDuMenu` par `ORDER BY createdAt DESC`, donc une
/// entrée épinglée plus ancienne que les cinq cents dernières n'arrive jamais jusqu'à
/// cette fonction. Le cas demande une seconde requête sur `pinned = 1`, ce que la v1
/// ne fait toujours pas. Il devient atteignable depuis la tâche 17, qui a posé
/// `Store.setPinned` : une entrée peut désormais être épinglée puis sortir des cinq
/// cents dernières, et disparaître du menu alors qu'elle est censée y rester.
func elementsDuMenu(entrees: [ClipItem], recherche: String) -> [LigneDeMenu] {
    let retenues = entrees.filter { correspondALaRecherche($0, recherche: recherche) }
    let ordonnees = retenues.sorted { gauche, droite in
        if gauche.pinned != droite.pinned {
            return gauche.pinned
        }
        return gauche.createdAt > droite.createdAt
    }
    return ordonnees.prefix(plafondDuMenu).enumerated().map { position, item in
        let rang = position + 1
        return LigneDeMenu(id: item.id, rang: rang, icone: icone(item.kind),
                           titre: titreAffiche(titreOuSecours(item)), epingle: item.pinned,
                           raccourci: raccourciDeRang(rang), vignette: item.thumb,
                           apercu: apercuDeLaLigne(item),
                           action: actionPour(item.searchText))
    }
}
