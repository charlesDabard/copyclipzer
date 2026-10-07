import Foundation

/// Au-delà du seuil, la charge utile sort de la base et va sur disque. Motif
/// mesuré dans la veille : un utilisateur a quitté Maccy pour des problèmes de
/// mémoire, et rater une copie parce qu'on est lent est le pire défaut de ce
/// produit. Fichier PUR : Foundation seulement.
struct BlobStore {
    static let seuil = 1_048_576   // 1 Mo
    static let plafond = 52_428_800 // 50 Mo, au-delà on ignore l'entrée

    let folder: String
    /// Le chiffreur des charges écrites sur disque. Injecté au constructeur, avec pour
    /// défaut la clé de production du Trousseau : les tests passent une clé connue.
    let chiffre: Chiffre

    init(folder: String, chiffre: Chiffre = Chiffre(cle: TrousseauCle.cle())) {
        self.folder = folder
        self.chiffre = chiffre
    }

    func ensureFolder() throws {
        try FileManager.default.createDirectory(atPath: folder,
                                                withIntermediateDirectories: true)
    }

    func write(_ data: Data, id: String) throws -> String {
        try ensureFolder()
        let path = folder + "/" + id
        try chiffre.chiffrer(data).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Relit une charge du disque. Un fichier écrit AVANT le chiffrement est en clair :
    /// l'ouverture échoue, et on retombe alors sur les octets bruts pour ne pas rendre
    /// illisible l'historique existant.
    func read(_ path: String) -> Data? {
        guard let brut = FileManager.default.contents(atPath: path) else { return nil }
        return chiffre.dechiffrer(brut) ?? brut
    }

    func delete(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
