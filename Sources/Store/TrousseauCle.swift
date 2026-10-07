import Foundation
import Security
import CryptoKit

/// La clé symétrique de production, rangée dans le Trousseau macOS.
///
/// C'est de la glue non testée : le Trousseau ne s'ouvre pas proprement depuis un
/// binaire de test en ligne de commande (l'accès à un élément créé par un binaire
/// reconstruit peut déclencher une invite graphique). Les tests injectent donc une clé
/// connue dans `Chiffre` et n'appellent jamais ce type.
///
/// Crée-ou-récupère un élément `kSecClassGenericPassword` de 256 bits. `SecItemAdd`
/// échoue si l'élément existe déjà, c'est pourquoi on lit d'abord ; si la lecture
/// rate, on tente la création. L'accessibilité `AfterFirstUnlock` laisse le démon lire
/// la clé tant que l'utilisateur a déverrouillé sa session une fois.
enum TrousseauCle {
    private static let service = "io.github.copyclipzer"
    private static let compte = "chiffre-contenu"

    /// Rend la clé du Trousseau, en la créant au premier lancement.
    static func cle() -> SymmetricKey {
        if let existante = lire() { return existante }
        let nouvelle = SymmetricKey(size: .bits256)
        ecrire(nouvelle)
        return nouvelle
    }

    private static func requete(returnData: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compte,
        ]
        if returnData {
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return q
    }

    private static func lire() -> SymmetricKey? {
        var resultat: CFTypeRef?
        let statut = SecItemCopyMatching(requete(returnData: true) as CFDictionary, &resultat)
        guard statut == errSecSuccess, let donnees = resultat as? Data else { return nil }
        return SymmetricKey(data: donnees)
    }

    private static func ecrire(_ cle: SymmetricKey) {
        let donnees = cle.withUnsafeBytes { Data($0) }
        var attributs = requete(returnData: false)
        attributs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributs[kSecValueData as String] = donnees
        SecItemAdd(attributs as CFDictionary, nil)
    }
}
