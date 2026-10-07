import Foundation
import CryptoKit

/// Chiffre les charges utiles au repos (contenu réel des entrées), en AES-GCM.
///
/// La clé est INJECTÉE, jamais lue ici : c'est ce qui rend le type testable avec une
/// clé connue, sans toucher au Trousseau. La récupération de la clé de production vit
/// dans `TrousseauCle`.
///
/// Limite assumée : seules les charges utiles sont chiffrées. Les métadonnées
/// (`title`, `searchText`) restent en clair dans SQLite, parce que l'index plein texte
/// FTS5 a besoin de les lire pour indexer et chercher. Un titre et un aperçu restent
/// donc lisibles à plat ; le contenu complet (RTF, images, gros textes) ne l'est pas.
/// SQLCipher, qui chiffrerait toute la base, est écarté : c'est une dépendance externe.
///
/// Le repli sur des données écrites EN CLAIR avant cette migration n'est PAS géré ici :
/// `dechiffrer` rend `nil` dès que l'ouverture échoue, et c'est la couche appelante
/// (BlobStore, Store) qui retombe alors sur les octets bruts.
struct Chiffre {
    let cle: SymmetricKey

    /// Scelle `clair` et rend la représentation combinée nonce + ciphertext + tag.
    /// La clé est toujours valide (256 bits), donc `seal` ne peut pas lever en pratique.
    func chiffrer(_ clair: Data) -> Data {
        let boite = try! AES.GCM.seal(clair, using: cle)
        return boite.combined!
    }

    /// Ouvre une charge scellée par `chiffrer`. Rend `nil` si l'ouverture échoue :
    /// mauvaise clé ou données altérées. Ne lève jamais, pour que l'appelant puisse
    /// retomber sur les octets bruts sans envelopper l'appel.
    func dechiffrer(_ chiffre: Data) -> Data? {
        guard let boite = try? AES.GCM.SealedBox(combined: chiffre) else { return nil }
        return try? AES.GCM.open(boite, using: cle)
    }
}
