import Foundation

enum ClipKind: String {
    case text, rtf, image, files
}

/// Une entrée d'historique. Fichier PUR : aucun import AppKit, donc testable.
/// `id`, `modifiedAt` et `deviceID` existent dès la v1 pour que la synchro de la
/// v2 n'impose pas de migration. Coût aujourd'hui : trois colonnes.
struct ClipItem: Equatable {
    let id: String
    let createdAt: Double
    var modifiedAt: Double
    let deviceID: String
    let kind: ClipKind
    let title: String
    let searchText: String
    let contentHash: String
    let byteSize: Int
    let sourceBundleID: String?
    var pinned: Bool
    var isRemote: Bool
    /// La vignette PNG d'une entrée image, quand elle en a une. Sur `item` et non sur
    /// `payload` : voir `Schema.v2`. Nulle pour tout le reste, et nulle aussi pour les
    /// images entrées avant la migration, jusqu'au rattrapage du lancement.
    var thumb: Data?

    /// Fabrique de confort pour les tests et pour la capture de texte simple.
    static func text(_ s: String, hash: String, device: String,
                     source: String? = nil, at: Double = 0) -> ClipItem {
        ClipItem(id: UUID().uuidString, createdAt: at, modifiedAt: at, deviceID: device,
                 kind: .text, title: String(s.prefix(200)), searchText: s,
                 contentHash: hash, byteSize: s.utf8.count, sourceBundleID: source,
                 pinned: false, isRemote: false)
    }
}
