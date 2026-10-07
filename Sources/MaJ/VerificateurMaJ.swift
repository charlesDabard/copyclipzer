import Foundation

/// Interroge l'API GitHub Releases pour savoir si une version plus récente existe.
///
/// Glu réseau, non testée unitairement (le réseau n'a pas sa place dans la suite) : toute
/// la décision vit dans `VersionSemantique`, elle testée. Ce type ne fait que chercher le
/// tag de la dernière release et appliquer cette décision. Il ne télécharge AUCUN binaire.
enum VerificateurMaJ {
    static let urlDerniereRelease =
        URL(string: "https://api.github.com/repos/charlesDabard/copyclipzer/releases/latest")!

    /// La version installée, lue dans Info.plist (`CFBundleShortVersionString`).
    static var versionInstallee: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Récupère le tag de la dernière release et, s'il est plus récent que `versionInstallee`,
    /// rend ce tag sur la file principale. Rend nil en cas d'erreur réseau, d'absence de
    /// release, ou si l'installée est déjà à jour.
    static func verifier(versionInstallee: String = VerificateurMaJ.versionInstallee,
                         _ termine: @escaping (String?) -> Void)
    {
        var requete = URLRequest(url: urlDerniereRelease)
        requete.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        requete.timeoutInterval = 10
        URLSession.shared.dataTask(with: requete) { data, _, _ in
            let resultat: String?
            if let data,
               let tag = VersionSemantique.tagDepuisJSON(data),
               VersionSemantique.miseAJourDisponible(installee: versionInstallee, derniere: tag)
            {
                resultat = tag
            } else {
                resultat = nil
            }
            DispatchQueue.main.async { termine(resultat) }
        }.resume()
    }
}
