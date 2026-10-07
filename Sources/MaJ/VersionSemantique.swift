import Foundation

/// Comparaison de versions et lecture du tag d'une release GitHub, en logique PURE.
///
/// Le check de mise à jour lit la dernière release publiée sur GitHub et compare son
/// numéro à la version installée. Toute la décision « faut-il proposer une mise à jour »
/// tient dans `miseAJourDisponible`, testable sans réseau. Le transport (URLSession) est
/// une glu à part, dans `VerificateurMaJ`.
enum VersionSemantique {
    /// Découpe une version en composantes entières, en tolérant un préfixe `v` (les tags
    /// GitHub s'écrivent `v1.2.0`) et un suffixe de pré-version (`1.2.0-beta` -> 1.2.0).
    /// Rend nil s'il n'y a rien d'exploitable (chaîne vide, non numérique).
    static func composantes(_ brut: String) -> [Int]? {
        var s = brut.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" {
            s.removeFirst()
        }
        s = String(s.split(separator: "-").first ?? "")
        let nombres = s.split(separator: ".").compactMap { Int($0) }
        return nombres.isEmpty ? nil : nombres
    }

    /// Rend true si `derniere` est STRICTEMENT plus récente que `installee`. La comparaison
    /// est NUMÉRIQUE composante par composante : 1.10.0 est donc plus récente que 1.2.0, ce
    /// qu'une comparaison de chaînes raterait (« 1.10.0 » < « 1.2.0 » lexicographiquement).
    /// Une version illisible d'un côté ou de l'autre rend false : on ne propose jamais de
    /// mise à jour sur un doute.
    static func miseAJourDisponible(installee: String, derniere: String) -> Bool {
        guard let a = composantes(installee), let b = composantes(derniere) else { return false }
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if y != x {
                return y > x
            }
        }
        return false
    }

    /// Extrait `tag_name` d'une réponse JSON de l'API GitHub Releases. Rend nil si le JSON
    /// est invalide ou si le champ manque.
    static func tagDepuisJSON(_ data: Data) -> String? {
        guard let objet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = objet["tag_name"] as? String else { return nil }
        return tag
    }
}
