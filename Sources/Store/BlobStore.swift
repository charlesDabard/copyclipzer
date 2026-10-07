import Foundation

/// Au-delà du seuil, la charge utile sort de la base et va sur disque. Motif
/// mesuré dans la veille : un utilisateur a quitté Maccy pour des problèmes de
/// mémoire, et rater une copie parce qu'on est lent est le pire défaut de ce
/// produit. Fichier PUR : Foundation seulement.
struct BlobStore {
    static let seuil = 1_048_576 // 1 Mo
    static let plafond = 52_428_800 // 50 Mo, au-delà on ignore l'entrée

    let folder: String

    func ensureFolder() throws {
        try FileManager.default.createDirectory(atPath: folder,
                                                withIntermediateDirectories: true)
    }

    func write(_ data: Data, id: String) throws -> String {
        try ensureFolder()
        let path = folder + "/" + id
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    func delete(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
