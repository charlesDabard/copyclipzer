import Foundation

/// Le bundle qui porte `Localizable.strings`.
///
/// On ne peut PAS écrire `Bundle.module` ici. Ce membre n'est généré que pour la cible
/// qui DÉCLARE des ressources, à savoir `Copyclipzer`. Or les vues qui lisent ces chaînes
/// sont symlinkées dans `Tools/CopyclipzerCaptures/`, un harnais qui n'a aucun bundle :
/// `.module` y est introuvable et la compilation casse (`type 'Bundle' has no member
/// 'module'`). Le bundle est donc résolu par son nom, ce qui marche partout :
///
/// - lancé par `swift run`, SwiftPM pose `Copyclipzer_Copyclipzer.bundle` juste à côté
///   des exécutables, donc dans `Bundle.main.bundleURL` ;
/// - l'application empaquetée par `build.sh` copie ce même bundle dans
///   `Contents/Resources`, donc dans `Bundle.main.resourceURL` ;
/// - le harnais de captures, lancé depuis le même dossier produits, le retrouve aussi,
///   et continue d'afficher le français au lieu des clés.
///
/// À défaut de bundle, on retombe sur `Bundle.main` : `NSLocalizedString` rend alors la
/// clé telle quelle, ce qui reste préférable à un plantage.
let bundleDeLangue: Bundle = {
    let nom = "Copyclipzer_Copyclipzer.bundle"
    let dossiers = [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        Bundle(for: TrouveurDeBundle.self).resourceURL,
    ].compactMap { $0 }
    for dossier in dossiers {
        if let bundle = Bundle(url: dossier.appendingPathComponent(nom)) {
            return bundle
        }
    }
    return .main
}()

/// Lit une chaîne de l'interface dans le bundle des traductions. Le commentaire sert aux
/// outils d'extraction ; la langue par défaut reste le français (`fr`).
func l10n(_ cle: String, _ commentaire: String = "") -> String {
    NSLocalizedString(cle, bundle: bundleDeLangue, comment: commentaire)
}

private final class TrouveurDeBundle {}
