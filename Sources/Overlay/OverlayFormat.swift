import Foundation

/// Plafond du titre affiché. `ClipItem.title` est déjà borné à 200 caractères par la
/// capture ; ce plafond plus bas évite de faire mesurer à SwiftUI une chaîne d'une
/// seule ligne beaucoup plus longue que la largeur du panneau.
let plafondDuTitreAffiche = 120

/// Délai avant que le panneau ne s'affiche, en secondes.
///
/// Depuis que le geste s'arme sur Cmd, l'overlay s'ouvre LOGIQUEMENT à chaque Cmd-V,
/// c'est-à-dire des dizaines de fois par jour. Sans ce report, il clignoterait à
/// chacun. Cmd relâché avant le délai : le panneau n'a jamais été montré et
/// l'utilisateur ne voit strictement rien, son Cmd-V se comporte comme avant
/// l'installation de Copyclipzer.
///
/// Ce délai ne retarde PAS le collage, qui part au relâchement dans tous les cas. Il
/// ne retarde que l'apparition du panneau.
///
/// La valeur vit dans ce fichier pur, symlinké dans la cible de test, et non en dur
/// dans `AppDelegate.swift` : elle y serait le seul nombre de tout le geste à décider
/// du confort d'usage sans qu'aucune vérification puisse le lire.
let delaiAvantAffichage: TimeInterval = 0.15

/// Prépare un titre pour un affichage sur une seule ligne : toute fin de ligne devient
/// un espace, et un titre plus long que le plafond est coupé avec une ellipse.
/// Le couple `\r\n` compte pour une seule fin de ligne, sinon un texte venu de Windows
/// gagnerait un espace double à chaque saut.
///
/// Fichier PUR : aucun import SwiftUI ni AppKit, donc symlinkable dans la cible de test.
func titreAffiche(_ brut: String) -> String {
    var s = brut.replacingOccurrences(of: "\r\n", with: " ")
    s = s.replacingOccurrences(of: "\n", with: " ")
    s = s.replacingOccurrences(of: "\r", with: " ")
    if s.count > plafondDuTitreAffiche {
        return String(s.prefix(plafondDuTitreAffiche)) + "…"
    }
    return s
}

/// Icône SF Symbols associée au type d'une entrée. Quatre types, quatre icônes
/// distinctes : c'est le seul repère visuel qui dit, sans lire le titre, qu'une entrée
/// est une image ou une liste de fichiers.
func icone(_ kind: ClipKind) -> String {
    switch kind {
    case .text: return "textformat.abc"
    case .rtf: return "doc.richtext"
    case .image: return "photo"
    case .files: return "doc.on.doc"
    }
}
