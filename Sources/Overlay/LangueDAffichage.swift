import Foundation

/// La langue des libellés calculés par la couche pure : type d'entrée, unité de taille,
/// date, nom de touche. Ces fichiers sont symlinkés dans des cibles sans bundle de
/// ressources, donc ils ne peuvent pas appeler `l10n`. Ils lisent cette valeur, que
/// l'assemblage règle au lancement sur la langue que `l10n` utilise réellement : les deux
/// moitiés de l'interface parlent alors la même langue. Avant (jusqu'au 2026-11-08),
/// l'interface anglaise affichait « Image · 83 Ko » et « ⌃⌘Espace ».
enum LangueDAffichage: Equatable {
    case francais, anglais

    /// Depuis un code de langue (« fr », « fr-FR », « en »...). Seul le français a sa
    /// traduction : toute autre langue retombe sur l'anglais, comme le fait le bundle.
    init(code: String) {
        self = code.lowercased().hasPrefix("fr") ? .francais : .anglais
    }
}

/// La langue en vigueur. Français par défaut, celle des tests historiques et du journal.
var langueDAffichage: LangueDAffichage = .francais
