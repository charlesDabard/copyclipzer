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

    /// Le raccourci global qui ouvre le panneau de recherche. Persisté champ par champ
    /// dans `UserDefaults`, ce qui évite tout encodage et tout décodeur faillible : si
    /// une clé manque, c'est que rien n'a jamais été enregistré, et le défaut ⌥⌘V
    /// s'applique. Le tap le relit à chaque frappe via une closure, donc un changement
    /// ici prend effet immédiatement, sans relancer quoi que ce soit.
    @Published var raccourciOuverture: RaccourciGlobal {
        didSet { persisterRaccourci() }
    }

    private init() {
        let brut = defaults.object(forKey: Cle.taille) as? Int ?? 1000
        tailleHistorique = tailleHistoriqueBornee(brut)
        let brutRetention = defaults.object(forKey: Cle.retention) as? Int ?? 0
        retentionJours = retentionJoursBornee(brutRetention)
        appsExclues = defaults.stringArray(forKey: Cle.appsExclues) ?? []
        raccourciOuverture = Reglages.lireRaccourci(defaults)
    }

    /// Aucune clé présente signifie « jamais réglé », donc défaut. On teste la touche
    /// seule : c'est le seul champ dont l'absence est univoque, les booléens pouvant
    /// légitimement valoir `false` une fois le réglage écrit.
    private static func lireRaccourci(_ defaults: UserDefaults) -> RaccourciGlobal {
        guard defaults.object(forKey: Cle.raccourciKeycode) != nil else { return .defaut }
        return RaccourciGlobal(
            keycode: defaults.integer(forKey: Cle.raccourciKeycode),
            option: defaults.bool(forKey: Cle.raccourciOption),
            commande: defaults.bool(forKey: Cle.raccourciCommande),
            majuscule: defaults.bool(forKey: Cle.raccourciMajuscule),
            controle: defaults.bool(forKey: Cle.raccourciControle))
    }

    private func persisterRaccourci() {
        defaults.set(raccourciOuverture.keycode, forKey: Cle.raccourciKeycode)
        defaults.set(raccourciOuverture.option, forKey: Cle.raccourciOption)
        defaults.set(raccourciOuverture.commande, forKey: Cle.raccourciCommande)
        defaults.set(raccourciOuverture.majuscule, forKey: Cle.raccourciMajuscule)
        defaults.set(raccourciOuverture.controle, forKey: Cle.raccourciControle)
    }
}
