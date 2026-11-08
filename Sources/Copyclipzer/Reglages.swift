import Combine
import Foundation

/// Les préférences de l'utilisateur, persistées dans `UserDefaults`. Glue mince et non
/// testée, comme l'assemblage : la seule vraie règle, le bornage de la taille, vit dans
/// `tailleHistoriqueBornee` (fichier pur, testé). Ici, rien que la lecture, l'écriture
/// et la diffusion aux vues via `@Published`.
final class Reglages: ObservableObject {
    static let shared = Reglages()

    private let defaults = UserDefaults.standard
    private enum Cle {
        static let taille = "tailleHistorique"
        static let retention = "retentionJours"
        static let appsExclues = "appsExclues"
        static let raccourciKeycode = "raccourciKeycode"
        static let raccourciOption = "raccourciOption"
        static let raccourciCommande = "raccourciCommande"
        static let raccourciMajuscule = "raccourciMajuscule"
        static let raccourciControle = "raccourciControle"
        static let raccourciMode = "raccourciMode"
        static let raccourciTouche = "raccourciTouche"
    }

    @Published var tailleHistorique: Int {
        didSet { defaults.set(tailleHistorique, forKey: Cle.taille) }
    }

    /// La rétention par le temps, en jours. 0 (défaut) désactive la purge des vieilles
    /// entrées. Bornée à la lecture par `retentionJoursBornee`, comme la taille.
    @Published var retentionJours: Int {
        didSet { defaults.set(retentionJours, forKey: Cle.retention) }
    }

    /// Les bundle IDs dont les copies ne sont pas enregistrées. Transmis à
    /// `CapturePolicy.blockedBundleIDs`, qui porte déjà le refus des types confidentiels
    /// (1Password et compagnie marquent `org.nspasteboard.ConcealedType`, déjà ignoré).
    @Published var appsExclues: [String] {
        didSet { defaults.set(appsExclues, forKey: Cle.appsExclues) }
    }

    /// Le moyen d'ouvrir le panneau, ou nil tant que l'utilisateur n'a pas choisi. nil
    /// n'est pas un défaut silencieux : c'est ce qui fait apparaître la fenêtre de choix au
    /// lancement, et aucun raccourci n'est actif tant qu'elle n'a pas été validée (voir
    /// `RaccourciDOuverture`). Une installation antérieure au 2026-11-08 n'a pas la clé
    /// `raccourciMode` : elle repasse donc par le choix une fois, comme demandé.
    ///
    /// Persisté champ par champ dans `UserDefaults`, sans encodage ni décodeur faillible.
    /// Le tap le relit à chaque frappe via une closure, donc un changement prend effet
    /// immédiatement, sans relancer quoi que ce soit.
    @Published var raccourci: RaccourciDOuverture? {
        didSet { persisterRaccourci() }
    }

    private init() {
        let brut = defaults.object(forKey: Cle.taille) as? Int ?? 1000
        tailleHistorique = tailleHistoriqueBornee(brut)
        let brutRetention = defaults.object(forKey: Cle.retention) as? Int ?? 0
        retentionJours = retentionJoursBornee(brutRetention)
        appsExclues = defaults.stringArray(forKey: Cle.appsExclues) ?? []
        raccourci = Reglages.lireRaccourci(defaults)
    }

    private static func lireRaccourci(_ defaults: UserDefaults) -> RaccourciDOuverture? {
        switch defaults.string(forKey: Cle.raccourciMode) {
        case "fnMaj":
            return .accordFnMaj
        case "combinaison":
            guard defaults.object(forKey: Cle.raccourciKeycode) != nil else { return nil }
            let combinaison = RaccourciGlobal(
                keycode: defaults.integer(forKey: Cle.raccourciKeycode),
                option: defaults.bool(forKey: Cle.raccourciOption),
                commande: defaults.bool(forKey: Cle.raccourciCommande),
                majuscule: defaults.bool(forKey: Cle.raccourciMajuscule),
                controle: defaults.bool(forKey: Cle.raccourciControle))
            return .combinaison(combinaison, touche: defaults.string(forKey: Cle.raccourciTouche) ?? "")
        default:
            return nil
        }
    }

    private func persisterRaccourci() {
        switch raccourci {
        case nil:
            defaults.removeObject(forKey: Cle.raccourciMode)
        case .accordFnMaj:
            defaults.set("fnMaj", forKey: Cle.raccourciMode)
        case let .combinaison(r, touche):
            defaults.set("combinaison", forKey: Cle.raccourciMode)
            defaults.set(r.keycode, forKey: Cle.raccourciKeycode)
            defaults.set(r.option, forKey: Cle.raccourciOption)
            defaults.set(r.commande, forKey: Cle.raccourciCommande)
            defaults.set(r.majuscule, forKey: Cle.raccourciMajuscule)
            defaults.set(r.controle, forKey: Cle.raccourciControle)
            defaults.set(touche, forKey: Cle.raccourciTouche)
        }
    }
}
