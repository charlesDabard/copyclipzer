import Foundation

/// Migrations par `PRAGMA user_version`, la convention relevée dans Deck.
/// Chaque version est une fonction qui ne s'applique qu'une fois, dans l'ordre.
enum Schema {
    static let currentVersion: Int32 = 3

    static func migrate(_ db: Database) throws {
        if db.userVersion < 1 {
            try db.transaction { try v1(db) }
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            try db.transaction { try v2(db) }
            db.userVersion = 2
        }
        if db.userVersion < 3 {
            try db.transaction { try v3(db) }
            db.userVersion = 3
        }
    }

    /// Le marqueur du passage à l'OCR, pour les entrées image.
    ///
    /// Il distingue DEUX états qu'un `searchText` vide confondrait : « image pas encore
    /// passée à l'OCR » (0) et « OCR fait, même s'il n'a rien trouvé » (1). Sans lui, le
    /// rattrapage du lancement relirait indéfiniment la charge utile de toute image dont
    /// l'OCR n'a rien tiré, à chaque démarrage, pour toujours. Le défaut vaut 0 sur les
    /// entrées déjà en base, ce qui les met naturellement dans la file du rattrapage.
    private static func v3(_ db: Database) throws {
        try db.exec("ALTER TABLE item ADD COLUMN ocrFait INTEGER NOT NULL DEFAULT 0")
    }

    /// La vignette d'une entrée image, en JPEG, 192 px de côté au plus.
    ///
    /// Elle vit sur `item`, avec les métadonnées, et NON sur `payload`. C'est
    /// délibérément l'inverse de la séparation de la v1, et pour la même raison : le
    /// menu fait un `SELECT *` sur cinq cents lignes, et il doit pouvoir dessiner les
    /// images sans jamais lire une charge utile.
    ///
    /// Le format et le seuil sont MESURÉS, et deux prévisions ont été fausses avant
    /// d'y arriver, ce qui est la raison d'écrire les chiffres ici plutôt qu'une
    /// intention. Mesure du 2026-09-01 sur les vingt-trois images de la base réelle :
    ///
    /// - PNG, plafond appliqué aux POINTS : 21 à 43 Ko la vignette. `NSImage.size` est
    ///   en points, donc sur un écran Retina le bitmap sortait deux fois trop grand.
    /// - PNG, plafond appliqué aux PIXELS : 483 Ko au total, jusqu'à 61 Ko l'unité. Le
    ///   PNG est sans perte, il ne compresse donc pas le photographique.
    /// - JPEG 0,7, plafond en pixels : 202 Ko au total, 8,8 Ko en moyenne, 15 Ko au
    ///   pire. C'est ce qui est livré.
    ///
    /// Pire cas assumé et chiffré : cinq cents entrées TOUTES images, soit environ
    /// 4,4 Mo au `SELECT` du menu, et il faut cinq cents copies d'images d'affilée
    /// pour l'atteindre.
    private static func v2(_ db: Database) throws {
        try db.exec("ALTER TABLE item ADD COLUMN thumb BLOB")
    }

    /// Deux tables plus un index plein texte. La séparation métadonnées / charge
    /// utile est délibérée : afficher dix lignes ne doit jamais charger dix images.
    private static func v1(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE item (
          id             TEXT PRIMARY KEY,
          createdAt      DOUBLE  NOT NULL,
          modifiedAt     DOUBLE  NOT NULL,
          deviceID       TEXT    NOT NULL,
          kind           TEXT    NOT NULL,
          title          TEXT    NOT NULL,
          searchText     TEXT,
          contentHash    TEXT    NOT NULL,
          byteSize       INTEGER NOT NULL,
          sourceBundleID TEXT,
          pinned         INTEGER NOT NULL DEFAULT 0,
          isRemote       INTEGER NOT NULL DEFAULT 0
        );

        CREATE UNIQUE INDEX item_hash ON item(contentHash);
        CREATE INDEX item_recent ON item(createdAt DESC);

        CREATE TABLE payload (
          itemID   TEXT PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
          uti      TEXT NOT NULL,
          data     BLOB,
          filePath TEXT
        );

        CREATE VIRTUAL TABLE item_fts USING fts5(
          title, searchText,
          content='item', content_rowid='rowid',
          tokenize='trigram'
        );

        CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN
          INSERT INTO item_fts(rowid, title, searchText)
          VALUES (new.rowid, new.title, new.searchText);
        END;

        CREATE TRIGGER item_ad AFTER DELETE ON item BEGIN
          INSERT INTO item_fts(item_fts, rowid, title, searchText)
          VALUES('delete', old.rowid, old.title, old.searchText);
        END;

        CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN
          INSERT INTO item_fts(item_fts, rowid, title, searchText)
          VALUES('delete', old.rowid, old.title, old.searchText);
          INSERT INTO item_fts(rowid, title, searchText)
          VALUES (new.rowid, new.title, new.searchText);
        END;
        """)
    }
}
