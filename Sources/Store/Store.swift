import Foundation

/// Accès à l'historique. Fichier PUR : il ne connaît que `Database`.
final class Store {
    private let db: Database
    private let blobs: BlobStore
    /// Le chiffreur de la colonne BLOB `payload.data`. Le contenu est chiffré au write et
    /// déchiffré au read, avec repli sur les octets bruts pour les données d'avant la
    /// migration. Les métadonnées (`title`, `searchText`) restent en clair : le FTS5 en a besoin.
    private let chiffre: Chiffre

    /// `blobs` a une valeur par défaut : les appelants qui ne se soucient pas des
    /// charges utiles lourdes gardent `Store(path:)`, et le dossier de blobs se pose
    /// à côté du fichier de base.
    init(path: String, blobs: BlobStore? = nil,
         chiffre: Chiffre = Chiffre(cle: TrousseauCle.cle())) throws {
        db = try Database(path: path)
        self.chiffre = chiffre
        self.blobs = blobs ?? BlobStore(folder: (path as NSString).deletingLastPathComponent + "/blobs",
                                        chiffre: chiffre)
        try Schema.migrate(db)
    }

    /// Rend `true` si une ligne a été créée, `false` si l'entrée existait déjà et
    /// n'a été que remontée en date. La déduplication est garantie par l'index
    /// unique sur `contentHash`, pas seulement par ce test : neutraliser l'un ou
    /// l'autre doit faire tomber « un doublon ne crée pas de ligne ».
    @discardableResult
    func insert(_ item: ClipItem, payload: Data?, uti: String) throws -> Bool {
        let existant = try db.query("SELECT id FROM item WHERE contentHash = ?",
                                    [.text(item.contentHash)])
        if let row = existant.first, case let .text(id)? = row["id"] {
            try db.run("UPDATE item SET modifiedAt = ?, createdAt = ? WHERE id = ?",
                       [.double(item.modifiedAt), .double(item.createdAt), .text(id)])
            return false
        }
        try db.transaction {
            try db.run("""
                       INSERT INTO item (id, createdAt, modifiedAt, deviceID, kind, title,
                                         searchText, contentHash, byteSize, sourceBundleID,
                                         pinned, isRemote, thumb)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                       """,
                       [.text(item.id), .double(item.createdAt), .double(item.modifiedAt),
                        .text(item.deviceID), .text(item.kind.rawValue), .text(item.title),
                        .text(item.searchText), .text(item.contentHash), .int(Int64(item.byteSize)),
                        item.sourceBundleID.map { SQLValue.text($0) } ?? .null,
                        .int(item.pinned ? 1 : 0), .int(item.isRemote ? 1 : 0),
                        item.thumb.map { SQLValue.blob($0) } ?? .null])
            var blob: SQLValue = .null
            var chemin: SQLValue = .null
            if let payload {
                if payload.count > BlobStore.seuil {
                    chemin = try .text(blobs.write(payload, id: item.id))
                } else {
                    blob = .blob(chiffre.chiffrer(payload))
                }
            }
            try db.run("INSERT INTO payload (itemID, uti, data, filePath) VALUES (?,?,?,?)",
                       [.text(item.id), .text(uti), blob, chemin])
        }
        return true
    }

    func count() throws -> Int {
        guard case let .int(n)? = try db.query("SELECT count(*) AS n FROM item").first?["n"]
        else { return 0 }
        return Int(n)
    }

    func recent(limit: Int) throws -> [ClipItem] {
        try db.query("SELECT * FROM item ORDER BY createdAt DESC LIMIT ?", [.int(Int64(limit))])
            .compactMap(Store.decode)
    }

    /// Recherche plein texte via FTS5 en tokenizer `trigram`, qui trouve une
    /// sous-chaîne au milieu d'un mot. C'est ce qu'on veut sur des URL, des
    /// identifiants et du code, et c'est ce que Maccy ne sait pas faire.
    /// Le tokenizer trigram exige au moins 3 caractères : en dessous, on retombe
    /// sur un LIKE, plutôt que de rendre une erreur à l'utilisateur.
    func search(_ query: String, limit: Int) throws -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try recent(limit: limit) }

        if q.count < 3 {
            return try db.query("""
            SELECT * FROM item WHERE title LIKE ? ORDER BY createdAt DESC LIMIT ?
            """, [.text("%\(q)%"), .int(Int64(limit))]).compactMap(Store.decode)
        }

        // Les guillemets neutralisent les opérateurs FTS5 saisis par accident.
        let escaped = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try db.query("""
        SELECT i.* FROM item_fts f
        JOIN item i ON i.rowid = f.rowid
        WHERE item_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        """, [.text(escaped), .int(Int64(limit))]).compactMap(Store.decode)
    }

    func payloadIsOnDisk(_ id: String) throws -> Bool {
        if case .text? = try db.query("SELECT filePath FROM payload WHERE itemID = ?",
                                      [.text(id)]).first?["filePath"]
        {
            return true
        }
        return false
    }

    func payload(_ id: String) throws -> Data? {
        guard let row = try db.query("SELECT data, filePath FROM payload WHERE itemID = ?",
                                     [.text(id)]).first else { return nil }
        if case let .text(path)? = row["filePath"] {
            return blobs.read(path)
        }
        if case let .blob(d)? = row["data"] {
            return chiffre.dechiffrer(d) ?? d
        }
        return nil
    }

    /// Épingle ou désépingle une entrée. `modifiedAt` bouge, `createdAt` NON :
    /// épingler doit sortir l'entrée de la portée de `purge` et la faire passer
    /// devant au tri, jamais la faire remonter en tête de l'historique comme si
    /// elle venait d'être copiée.
    func setPinned(_ id: String, _ pinned: Bool) throws {
        try db.run("UPDATE item SET pinned = ?, modifiedAt = ? WHERE id = ?",
                   [.int(pinned ? 1 : 0),
                    .double(Date().timeIntervalSince1970),
                    .text(id)])
    }

    /// Supprime UNE entrée, son enregistrement et son blob sur disque.
    ///
    /// Le `ON DELETE CASCADE` de `payload` emporte la ligne, pas le fichier : il ne
    /// connaît pas le disque. Sans l'effacement explicite ci-dessous, le blob resterait
    /// dans `blobs/` sans que plus rien en base ne pointe vers lui, donc sans que plus
    /// rien ne puisse jamais le supprimer. C'est la même garantie que `purge`, et elle
    /// se redit ici parce qu'un seul des deux chemins la porterait sinon.
    func delete(_ id: String) throws {
        let ligne = try db.query("SELECT filePath FROM payload WHERE itemID = ?",
                                 [.text(id)]).first
        try db.transaction {
            if case let .text(path)? = ligne?["filePath"] {
                blobs.delete(path)
            }
            try db.run("DELETE FROM item WHERE id = ?", [.text(id)])
        }
    }

    /// Pose la vignette d'une entrée déjà en base. Sert au rattrapage du lancement,
    /// jamais à la capture, qui l'écrit dès l'insertion.
    func setThumb(_ id: String, _ thumb: Data) throws {
        try db.run("UPDATE item SET thumb = ? WHERE id = ?", [.blob(thumb), .text(id)])
    }

    /// Les entrées image qui n'ont pas encore de vignette.
    ///
    /// Une migration ajoute une colonne, elle ne remplit pas le passé : sans ce
    /// rattrapage, tout l'historique déjà capturé resterait sans vignette jusqu'à ce
    /// que chaque image soit recopiée une par une. Le filtre porte sur le type ET sur
    /// l'absence de vignette : sans le premier, le rattrapage relirait la charge utile
    /// de chaque texte de l'historique pour n'en rien faire.
    func imagesSansVignette(limit: Int) throws -> [String] {
        try db.query("""
        SELECT id FROM item WHERE kind = 'image' AND thumb IS NULL
        ORDER BY createdAt DESC LIMIT ?
        """, [.int(Int64(limit))]).compactMap {
            if case let .text(id)? = $0["id"] {
                return id
            }
            return nil
        }
    }

    /// Écrit le texte reconnu par OCR sur une entrée et la marque comme traitée.
    ///
    /// Le `searchText` suffit à rendre l'image cherchable : le déclencheur `item_au`
    /// reindexe le FTS5 à chaque `UPDATE` de `item`, sans qu'on ait rien à toucher à la
    /// table virtuelle. `ocrFait` passe à 1 même quand `texte` est vide, précisément
    /// pour que le rattrapage ne revienne pas sur une image où l'OCR n'a rien trouvé.
    func definirTexteRecherche(_ id: String, _ texte: String) throws {
        try db.run("UPDATE item SET searchText = ?, ocrFait = 1 WHERE id = ?",
                   [.text(texte), .text(id)])
    }

    /// Les entrées image qui ne sont pas encore passées à l'OCR.
    ///
    /// Le filtre porte sur le type ET sur `ocrFait`, comme `imagesSansVignette` : sans
    /// le premier, le rattrapage relirait la charge utile de chaque texte ; sans le
    /// second, il repasserait l'OCR sur toute image déjà traitée à chaque lancement.
    func imagesSansTexteOCR(limit: Int) throws -> [String] {
        try db.query("""
        SELECT id FROM item WHERE kind = 'image' AND ocrFait = 0
        ORDER BY createdAt DESC LIMIT ?
        """, [.int(Int64(limit))]).compactMap {
            if case let .text(id)? = $0["id"] {
                return id
            }
            return nil
        }
    }

    /// Garde les `keeping` entrées les plus récentes, plus TOUTES les épinglées.
    /// Les blobs des entrées supprimées partent avec elles : une base et un
    /// dossier de blobs qui divergent finissent par remplir le disque.
    func purge(keeping: Int) throws {
        let condamnes = try db.query("""
        SELECT i.id, p.filePath FROM item i
        LEFT JOIN payload p ON p.itemID = i.id
        WHERE i.pinned = 0 AND i.id NOT IN (
          SELECT id FROM item WHERE pinned = 0 ORDER BY createdAt DESC LIMIT ?
        )
        """, [.int(Int64(keeping))])

        try db.transaction {
            for row in condamnes {
                if case let .text(path)? = row["filePath"] {
                    blobs.delete(path)
                }
                if case let .text(id)? = row["id"] {
                    try db.run("DELETE FROM item WHERE id = ?", [.text(id)])
                }
            }
        }
    }

    /// Rétention par le TEMPS, en plus de la purge par nombre. Supprime toutes les
    /// entrées NON épinglées dont `createdAt < horodatage` (epoch). Les épinglées sont
    /// hors de portée quel que soit leur âge : c'est le sens même de l'épingle, et
    /// l'appelant ne doit pas appeler cette fonction quand la rétention est désactivée
    /// (voir `Reglages.retentionJours`).
    ///
    /// Les blobs partent explicitement, pour la même raison que `purge`, `delete` et
    /// `deleteAllExceptPinned` : le `ON DELETE CASCADE` emporte la ligne `payload`,
    /// jamais le fichier disque, qu'il ne connaît pas.
    func purgerAvant(_ horodatage: Double) throws {
        let condamnes = try db.query("""
        SELECT i.id, p.filePath FROM item i
        LEFT JOIN payload p ON p.itemID = i.id
        WHERE i.pinned = 0 AND i.createdAt < ?
        """, [.double(horodatage)])

        try db.transaction {
            for row in condamnes {
                if case let .text(path)? = row["filePath"] {
                    blobs.delete(path)
                }
                if case let .text(id)? = row["id"] {
                    try db.run("DELETE FROM item WHERE id = ?", [.text(id)])
                }
            }
        }
    }

    /// Vide TOUT l'historique, épinglés compris, et efface tous les blobs du disque.
    /// C'est le seul geste du produit qui ne garde rien : il sert au bouton « Tout
    /// supprimer » du panneau. Les blobs partent explicitement, pour la même raison que
    /// `delete` et `purge` : le `ON DELETE CASCADE` emporte la ligne `payload`, jamais
    /// le fichier, qu'il ne connaît pas.
    func deleteAll() throws {
        let chemins = try db.query("SELECT filePath FROM payload").compactMap { row -> String? in
            if case let .text(path)? = row["filePath"] {
                return path
            }
            return nil
        }
        try db.transaction {
            for chemin in chemins {
                blobs.delete(chemin)
            }
            try db.run("DELETE FROM item")
        }
    }

    /// Vide l'historique SAUF les entrées épinglées, blobs des supprimées compris.
    /// C'est le bouton « Tout sauf les épinglés » : on jette le bruit et on garde ce
    /// qu'on a mis de côté. Le blob d'une entrée épinglée n'est JAMAIS touché, c'est le
    /// sens même du geste ; `purge(keeping:)` partage la garantie de nettoyage disque.
    func deleteAllExceptPinned() throws {
        let condamnes = try db.query("""
        SELECT i.id, p.filePath FROM item i
        LEFT JOIN payload p ON p.itemID = i.id
        WHERE i.pinned = 0
        """)
        try db.transaction {
            for row in condamnes {
                if case let .text(path)? = row["filePath"] {
                    blobs.delete(path)
                }
                if case let .text(id)? = row["id"] {
                    try db.run("DELETE FROM item WHERE id = ?", [.text(id)])
                }
            }
        }
    }

    static func decode(_ row: [String: SQLValue]) -> ClipItem? {
        func s(_ k: String) -> String? {
            if case let .text(v)? = row[k] {
                return v
            }; return nil
        }
        func d(_ k: String) -> Double {
            if case let .double(v)? = row[k] {
                return v
            }; return 0
        }
        func i(_ k: String) -> Int64 {
            if case let .int(v)? = row[k] {
                return v
            }; return 0
        }
        /// Un BLOB vide et un BLOB absent se lisent tous les deux comme « pas de
        /// vignette » : `Data()` dessiné donnerait un carré vide à la place du symbole,
        /// ce qui est pire que le symbole.
        func b(_ k: String) -> Data? {
            if case let .blob(v)? = row[k] {
                return v.isEmpty ? nil : v
            }; return nil
        }
        guard let id = s("id"), let device = s("deviceID"),
              let kindRaw = s("kind"), let kind = ClipKind(rawValue: kindRaw),
              let title = s("title"), let hash = s("contentHash") else { return nil }
        return ClipItem(id: id, createdAt: d("createdAt"), modifiedAt: d("modifiedAt"),
                        deviceID: device, kind: kind, title: title,
                        searchText: s("searchText") ?? "", contentHash: hash,
                        byteSize: Int(i("byteSize")), sourceBundleID: s("sourceBundleID"),
                        pinned: i("pinned") == 1, isRemote: i("isRemote") == 1,
                        thumb: b("thumb"))
    }
}
