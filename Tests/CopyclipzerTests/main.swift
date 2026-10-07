import CryptoKit
import Foundation

// Tests de la logique pure de Copyclipzer. Lancement : swift run CopyclipzerTests
//
// Discipline : chaque garantie a un test de refus ET un test d'acceptation, et chaque
// vérification porte un nom qui dit exactement ce qu'elle mesure. Le sabotage n'est pas
// une section de ce fichier : il se joue tâche par tâche, en neutralisant la ligne visée
// dans les sources et en exigeant que le test nommé tombe. Une garantie dont le sabotage
// laisse le vert est une garantie qui n'existe pas.

var failures = 0
var passed = 0

/// Une section déclare combien de vérifications nommées elle doit exécuter, et le
/// harnais compte celles qui tournent vraiment. Sans ce compte, une vérification
/// sautée (une exception levée juste avant elle) se fait remplacer ligne pour ligne
/// par l'échec du `catch` : le total ne bouge pas, et la sortie ne distingue plus
/// « mesuré et bon » de « pas mesuré du tout ». Mesuré sur la tâche 3.
struct SectionDeTest {
    let titre: String
    let attendu: Int
    var executees: Int
}

var sections: [SectionDeTest] = []

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if !sections.isEmpty {
        sections[sections.count - 1].executees += 1
    }
    if condition {
        passed += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL  \(name)\(extra.isEmpty ? "" : " · \(extra)")")
    }
}

/// Échec hors comptage, pour le `catch` d'un bloc qui a levé. Volontairement séparé
/// de `check` : compté dans la section, il compenserait exactement la vérification
/// qui n'a pas tourné, et masquerait ce qu'il est censé signaler.
func echec(_ nom: String, _ detail: String = "") {
    failures += 1
    print("  FAIL  \(nom)\(detail.isEmpty ? "" : " · \(detail)")")
}

func section(_ titre: String, attendu: Int) {
    sections.append(SectionDeTest(titre: titre, attendu: attendu, executees: 0))
    print("\n\(titre)")
}

/// Passe finale : compare l'exécuté au déclaré, section par section. C'est elle qui
/// transforme une vérification disparue en échec visible. L'égalité est stricte des
/// deux côtés : avec un simple `<`, un `attendu` trop petit ne se voyait jamais, donc
/// ajouter une vérification sans toucher au compteur affaiblissait la garde en
/// silence. Un écart est un écart, qu'il manque des vérifications ou qu'il y en ait
/// de trop.
func verifierLesSections() {
    for s in sections where s.executees != s.attendu {
        failures += 1
        let ecart = abs(s.attendu - s.executees)
        let cause = s.executees < s.attendu
            ? (ecart > 1 ? "\(ecart) n'ont pas tourné" : "1 n'a pas tourné")
            : (ecart > 1 ? "\(ecart) de trop ont tourné" : "1 de trop a tourné")
        print("\n  FAIL  section « \(s.titre) » : \(s.executees) vérifications exécutées pour \(s.attendu) attendues, \(cause)")
    }
}

/// Dossier jetable, pour ne jamais écrire dans le vrai Application Support.
func makeSandbox() -> String {
    let dir = NSTemporaryDirectory() + "copyclipzer-tests-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Clé de test fixe : le chiffrement se mesure avec une clé connue, et le Trousseau
/// n'est jamais touché depuis les tests.
let chiffreDeTest = Chiffre(cle: SymmetricKey(size: .bits256))

section("Harnais", attendu: 1)
check("le harnais compte les succès", true)

section("SQL", attendu: 7)
do {
    let db = try Database(path: ":memory:")
    try db.exec("CREATE TABLE t (a TEXT, b INTEGER)")
    try db.run("INSERT INTO t VALUES (?, ?)", [.text("bonjour"), .int(42)])
    let rows = try db.query("SELECT a, b FROM t", [])
    check("une ligne insérée est relue", rows.count == 1, "obtenu \(rows.count)")
    check("le texte est préservé", rows.first?["a"] == .text("bonjour"))
    check("l'entier est préservé", rows.first?["b"] == .int(42))
    // Le mode WAL ne s'observe que sur une base fichier. Le tester sur ":memory:"
    // ne mesure rien : une base en mémoire ne peut structurellement pas passer en
    // WAL, et le PRAGMA y répond toujours "memory".
    let surDisque = try Database(path: makeSandbox() + "/wal.db")
    let journalFichier = try surDisque.query("PRAGMA journal_mode").first?["journal_mode"]
    check("le mode WAL est actif sur une base fichier", journalFichier == .text("wal"),
          "obtenu \(String(describing: journalFichier))")

    // Documenté volontairement, pour qu'un futur lecteur ne « corrige » pas
    // l'initialiseur en croyant à un bug : sur une base en mémoire, "memory" est
    // la réponse normale, pas un PRAGMA qui aurait échoué.
    let journalMemoire = try db.query("PRAGMA journal_mode").first?["journal_mode"]
    check("une base en mémoire reste en journal memory", journalMemoire == .text("memory"),
          "obtenu \(String(describing: journalMemoire))")

    db.userVersion = 7
    check("user_version se lit et s'écrit", db.userVersion == 7, "obtenu \(db.userVersion)")

    // Piège classique : une chaîne Swift liée sans SQLITE_TRANSIENT peut être
    // libérée avant l'exécution de la requête, et ressortir vide ou tronquée.
    let accents = "éàü chaîne avec espaces"
    try db.run("INSERT INTO t VALUES (?, ?)", [.text(accents), .int(1)])
    let relu = try db.query("SELECT a FROM t WHERE b = ?", [.int(1)])
    check("une chaîne accentuée avec espaces ressort identique",
          relu.first?["a"] == .text(accents), "obtenu \(String(describing: relu.first?["a"]))")
} catch {
    echec("SQL sans erreur", "\(error)")
}

section("Schéma", attendu: 9)
do {
    let db = try Database(path: ":memory:")
    try Schema.migrate(db)
    check("la version passe à la version courante du schéma",
          db.userVersion == Schema.currentVersion,
          "obtenu \(db.userVersion) pour \(Schema.currentVersion) attendus")
    // En clair, et pas seulement comparée à `currentVersion` : une base neuve doit
    // sortir en 3, sinon la v3 n'a pas tourné et `ocrFait` manquerait.
    check("une base neuve est en user_version 3", db.userVersion == 3,
          "obtenu \(db.userVersion)")

    // La v3 pose le suivi de l'OCR. On lit la FORME que SQLite rend, pas l'intention :
    // NOT NULL avec un défaut 0, pour que les entrées d'avant la migration tombent dans
    // la file du rattrapage au lieu de valoir NULL.
    let colonnes = try db.query("PRAGMA table_info(item)")
    let ocr = colonnes.first { $0["name"] == .text("ocrFait") }
    check("la colonne ocrFait existe", ocr != nil)
    check("ocrFait est NOT NULL et vaut 0 par défaut",
          ocr?["notnull"] == .int(1) && ocr?["dflt_value"] == .text("0"),
          "notnull \(String(describing: ocr?["notnull"])), défaut \(String(describing: ocr?["dflt_value"]))")

    let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'")
        .compactMap {
            if case let .text(n)? = $0["name"] {
                return n
            } else {
                return nil as String?
            }
        }
    check("la table item existe", tables.contains("item"))
    check("la table payload existe", tables.contains("payload"))
    check("l'index plein texte existe", tables.contains("item_fts"))

    // Sans les trois déclencheurs, l'index plein texte reste vide en silence : la
    // recherche de la tâche 5 ne rendrait rien, et aucune erreur ne l'expliquerait.
    // On compare aux trois noms exacts, pas à un simple « il y en a ».
    let triggers = try db.query("SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name")
        .compactMap {
            if case let .text(n)? = $0["name"] {
                return n
            } else {
                return nil as String?
            }
        }
    check("les trois déclencheurs existent", triggers == ["item_ad", "item_ai", "item_au"],
          "obtenu \(triggers)")

    try Schema.migrate(db)
    check("migrer deux fois ne casse rien", db.userVersion == Schema.currentVersion)
} catch {
    echec("schéma sans erreur", "\(error)")
}

section("Store · insertion et déduplication", attendu: 6)
do {
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    // Dates explicites et distinctes de bout en bout. Avec le `at: 0` par défaut du
    // brief, les trois lignes partagent le même `createdAt`, `ORDER BY createdAt DESC`
    // ne départage plus rien et le tri se joue au rowid : le test « le plus récent
    // arrive en tête » sortait h1 sans mesurer la moindre notion de récence.
    let a = ClipItem.text("SELECT * FROM users", hash: "h1", device: "macA", at: 10)
    try check("une insertion crée une ligne", store.insert(a, payload: nil, uti: "public.utf8-plain-text"))
    try check("le compte vaut 1", store.count() == 1)

    let doublon = ClipItem.text("SELECT * FROM users", hash: "h1", device: "macA", at: 10)
    try check("un doublon ne crée pas de ligne", !store.insert(doublon, payload: nil, uti: "public.utf8-plain-text"))
    // Le compte est capturé avant l'appel : le détail de `check` est un autoclosure
    // non lançant, un `try` y est refusé à la compilation.
    let apresDoublon = try store.count()
    check("le compte reste à 1", apresDoublon == 1, "obtenu \(apresDoublon)")

    let b = ClipItem.text("autre chose", hash: "h2", device: "macA", at: 20)
    _ = try store.insert(b, payload: nil, uti: "public.utf8-plain-text")
    let plusRecent = try store.recent(limit: 10).first
    check("le plus récent arrive en tête", plusRecent?.contentHash == "h2",
          "obtenu \(String(describing: plusRecent?.contentHash)) createdAt \(String(describing: plusRecent?.createdAt))")

    // Pendant indispensable du test du doublon : sans lui, un `insert` qui rendrait
    // `false` sans rien écrire du tout passerait pour correct. On réinsère h1 avec
    // une date postérieure à celle de h2, et on exige qu'il repasse en tête.
    let reprise = ClipItem.text("SELECT * FROM users", hash: "h1", device: "macA", at: 100)
    _ = try store.insert(reprise, payload: nil, uti: "public.utf8-plain-text")
    let tete = try store.recent(limit: 10).first?.contentHash
    check("un doublon remonte l'entrée en tête", tete == "h1", "obtenu \(String(describing: tete))")
} catch {
    echec("store sans erreur", "\(error)")
}

section("Store · recherche", attendu: 6)
do {
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    // Dates explicites et distinctes : le repli LIKE trie par createdAt DESC, et un
    // tri qui retombe sur le rowid ne mesurerait aucune notion de récence.
    try store.insert(.text("https://github.com/p0deje/Maccy", hash: "h1", device: "m", at: 10),
                     payload: nil, uti: "public.utf8-plain-text")
    try store.insert(.text("SELECT * FROM users WHERE id = 3", hash: "h2", device: "m", at: 20),
                     payload: nil, uti: "public.utf8-plain-text")
    // Entrée dédiée au repli sous 3 caractères : « ab » n'apparaît ni dans h1 ni dans h2,
    // donc la trouver prouve que le repli cherche, au lieu de simplement ne pas lever.
    try store.insert(.text("table basse", hash: "h3", device: "m", at: 30),
                     payload: nil, uti: "public.utf8-plain-text")

    // Le test qui distingue trigram d'un tokenizer par mots : "deje" est AU MILIEU
    // de "p0deje". Un tokenizer classique ne le trouverait jamais.
    let milieu = try store.search("deje", limit: 10).first?.contentHash
    check("trouve une sous-chaîne au milieu d'un mot", milieu == "h1",
          "obtenu \(String(describing: milieu))")

    let suite = try store.search("FROM us", limit: 10).first?.contentHash
    check("trouve une suite de mots", suite == "h2", "obtenu \(String(describing: suite))")

    let absent = try store.search("zzzzz", limit: 10)
    check("ne trouve rien pour un terme absent", absent.isEmpty, "obtenu \(absent.count) ligne(s)")

    // Deux vérifications distinctes, et une seule des deux couvre le repli. La première ne
    // mesure que l'absence de plantage : « ab » part en FTS5 si on neutralise le repli, ne
    // rend rien, et ne lève pas pour autant, donc elle reste verte. C'est la seconde, sur
    // le contenu trouvé, qui porte la garantie du repli. Nommer la première « ne plante
    // pas » laissait croire l'inverse.
    let court = try? store.search("ab", limit: 10)
    check("une requête courte ne lève pas", court != nil)
    check("le repli sous 3 caractères trouve vraiment", court?.first?.contentHash == "h3",
          "obtenu \(String(describing: court?.first?.contentHash))")

    // Un opérateur FTS5 tapé par accident ne doit pas ressortir en erreur : c'est le rôle
    // des guillemets d'échappement. Sans ce test, l'échappement n'est couvert par rien.
    let ou = try? store.search("a OR b", limit: 10)
    let near = try? store.search("NEAR(", limit: 10)
    check("une requête avec des opérateurs FTS5 ne lève pas", ou != nil && near != nil,
          "a OR b \(ou == nil ? "lève" : "ok"), NEAR( \(near == nil ? "lève" : "ok")")
} catch {
    echec("recherche sans erreur", "\(error)")
}

section("Store · blobs et rétention", attendu: 8)
do {
    let sandbox = makeSandbox()
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: dossierBlobs, chiffre: chiffreDeTest), chiffre: chiffreDeTest)

    // Dates explicites et distinctes, toutes sous celles des vingt entrées de rétention
    // qui suivent : les deux charges utiles doivent être condamnées par la purge sans
    // dépendre du départage d'une égalité de `createdAt`.
    let gros = Data(repeating: 0x41, count: 2_000_000)
    let item = ClipItem.text("grosse image", hash: "big", device: "m", at: -2)
    try store.insert(item, payload: gros, uti: "public.png")
    try check("au-delà du seuil, la base ne contient pas le blob",
              store.payloadIsOnDisk(item.id))
    let reluGros = try store.payload(item.id)?.count
    check("le contenu se relit à l'identique", reluGros == 2_000_000,
          "obtenu \(String(describing: reluGros))")

    let petit = Data(repeating: 0x42, count: 10)
    let mini = ClipItem.text("petit", hash: "small", device: "m", at: -1)
    try store.insert(mini, payload: petit, uti: "public.utf8-plain-text")
    try check("en dessous du seuil, le blob reste en base",
              !store.payloadIsOnDisk(mini.id))
    // Pendant du test précédent : sans lui, la branche « lire depuis la colonne BLOB »
    // de `payload` n'est couverte par rien, et seule celle du disque serait mesurée.
    let reluPetit = try store.payload(mini.id)
    check("une charge utile sous le seuil se relit depuis la base", reluPetit == petit,
          "obtenu \(String(describing: reluPetit?.count)) octet(s)")

    for n in 0 ..< 20 {
        try store.insert(.text("entrée \(n)", hash: "r\(n)", device: "m", at: Double(n)),
                         payload: nil, uti: "public.utf8-plain-text")
    }
    var epingle = ClipItem.text("à garder", hash: "pin", device: "m", at: -999)
    epingle.pinned = true
    try store.insert(epingle, payload: nil, uti: "public.utf8-plain-text")

    // Le fichier doit exister AVANT la purge, sinon « il n'existe plus » après serait
    // vrai sans rien mesurer : un blob jamais écrit passerait la vérification suivante.
    let cheminBlob = dossierBlobs + "/" + item.id
    check("le blob condamné existe sur le disque avant la purge",
          FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")

    try store.purge(keeping: 5)
    let restants = try store.recent(limit: 100)
    check("la purge garde le quota", restants.filter { !$0.pinned }.count == 5,
          "obtenu \(restants.filter { !$0.pinned }.count)")
    check("la purge ne touche jamais une entrée épinglée",
          restants.contains { $0.contentHash == "pin" })

    // La garantie que la ligne supprimée emporte son fichier. Une base et un dossier de
    // blobs qui divergent remplissent le disque en silence : rien en base ne pointe plus
    // vers le fichier, donc plus rien ne le supprimera jamais.
    check("la purge efface aussi le blob du disque",
          !FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")
} catch {
    echec("blobs et rétention sans erreur", "\(error)")
}

section("Chiffre · AES-GCM", attendu: 3)
let chiffreEssai = Chiffre(cle: SymmetricKey(size: .bits256))
let clairEssai = Data("secret de test 1234567890".utf8)
let scelleEssai = chiffreEssai.chiffrer(clairEssai)
check("un scellé se rouvre à l'identique", chiffreEssai.dechiffrer(scelleEssai) == clairEssai)
check("le scellé ne contient pas le clair",
      scelleEssai.range(of: Data("secret de test".utf8)) == nil)
check("une autre clé rend nil",
      Chiffre(cle: SymmetricKey(size: .bits256)).dechiffrer(scelleEssai) == nil)

section("BlobStore · chiffrement au repos", attendu: 3)
do {
    let sandbox = makeSandbox()
    let chiffre = Chiffre(cle: SymmetricKey(size: .bits256))
    let blobs = BlobStore(folder: sandbox + "/blobs", chiffre: chiffre)
    let clair = Data("contenu confidentiel unique XYZZY".utf8)
    let chemin = try blobs.write(clair, id: "blob-chiffre")
    check("écrit puis relu à l'identique", blobs.read(chemin) == clair)

    let brut = FileManager.default.contents(atPath: chemin)
    check("le fichier sur disque ne contient pas le clair",
          brut?.range(of: Data("confidentiel".utf8)) == nil,
          "octets \(brut?.count ?? -1)")

    // Rétrocompatibilité : un fichier écrit AVANT le chiffrement est en clair, et le
    // repli doit le rendre tel quel plutôt que de rendre l'historique illisible.
    let cheminClair = sandbox + "/blobs/ecrit-en-clair"
    try clair.write(to: URL(fileURLWithPath: cheminClair))
    check("un fichier en clair se relit par repli", blobs.read(cheminClair) == clair)
} catch {
    echec("BlobStore chiffré sans erreur", "\(error)")
}

section("Store · contenu chiffré au repos", attendu: 5)
do {
    let sandbox = makeSandbox()
    let chiffre = Chiffre(cle: SymmetricKey(size: .bits256))
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite",
                          blobs: BlobStore(folder: dossierBlobs, chiffre: chiffre),
                          chiffre: chiffre)

    // Sous le seuil : la charge vit dans la colonne BLOB.
    let petit = Data("petit secret en base ABCDEF".utf8)
    let mini = ClipItem.text("petit", hash: "cc1", device: "m", at: 1)
    try store.insert(mini, payload: petit, uti: "public.utf8-plain-text")
    try check("une charge sous le seuil se relit", store.payload(mini.id) == petit)

    let inspecteur = try Database(path: sandbox + "/db.sqlite")
    let brutBase = try inspecteur.query("SELECT data FROM payload WHERE itemID = ?",
                                        [.text(mini.id)]).first?["data"]
    var baseContientClair = false
    if case let .blob(d)? = brutBase {
        baseContientClair = d.range(of: Data("secret".utf8)) != nil
    }
    check("le BLOB en base ne contient pas le clair", !baseContientClair)

    // Au-delà du seuil : la charge part sur disque.
    let gros = Data(repeating: 0x41, count: 1_100_000) + Data("gros secret disque GHIJ".utf8)
    let item = ClipItem.text("gros", hash: "cc2", device: "m", at: 2)
    try store.insert(item, payload: gros, uti: "public.png")
    try check("une charge sur disque se relit", store.payload(item.id) == gros)
    let brutFichier = FileManager.default.contents(atPath: dossierBlobs + "/" + item.id)
    check("le fichier sur disque ne contient pas le clair",
          brutFichier?.range(of: Data("gros secret".utf8)) == nil)

    // Rétrocompatibilité : un BLOB écrit en clair AVANT la migration reste lisible.
    let ancien = ClipItem.text("ancien", hash: "cc3", device: "m", at: 3)
    try store.insert(ancien, payload: nil, uti: "public.utf8-plain-text")
    let clairAncien = Data("donnee davant chiffrement KLMNOP".utf8)
    try inspecteur.run("UPDATE payload SET data = ? WHERE itemID = ?",
                       [.blob(clairAncien), .text(ancien.id)])
    try check("un BLOB en clair se relit par repli", store.payload(ancien.id) == clairAncien)
} catch {
    echec("Store chiffré sans erreur", "\(error)")
}

section("tâche 17 : épingler et supprimer une entrée", attendu: 10)
do {
    let sandbox = makeSandbox()
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: dossierBlobs, chiffre: chiffreDeTest), chiffre: chiffreDeTest)

    // --- épinglage ---
    let bascule = ClipItem.text("à épingler", hash: "e1", device: "m", at: 10)
    try store.insert(bascule, payload: nil, uti: "public.utf8-plain-text")

    try store.setPinned(bascule.id, true)
    let epinglee = try store.recent(limit: 100).first { $0.id == bascule.id }
    check("épingler rend l'entrée épinglée", epinglee?.pinned == true,
          "obtenu \(String(describing: epinglee?.pinned))")

    // Le sens contraire, et il n'est pas décoratif : un `pinned = 1` écrit en dur
    // passerait la vérification précédente sans que rien ne le signale.
    try store.setPinned(bascule.id, false)
    let desepinglee = try store.recent(limit: 100).first { $0.id == bascule.id }
    check("désépingler rend l'entrée non épinglée", desepinglee?.pinned == false,
          "obtenu \(String(describing: desepinglee?.pinned))")

    // Épingler n'est pas copier. Toucher `createdAt` ferait remonter l'entrée en tête
    // de l'historique, donc changerait l'ordre du menu à chaque coup de punaise.
    check("épingler ne remonte pas l'entrée dans l'historique",
          desepinglee?.createdAt == 10,
          "obtenu \(String(describing: desepinglee?.createdAt))")

    // --- suppression, charge utile sur disque ---
    let gros = ClipItem.text("grosse image", hash: "s1", device: "m", at: 11)
    try store.insert(gros, payload: Data(repeating: 0x41, count: 2_000_000), uti: "public.png")
    let cheminBlob = dossierBlobs + "/" + gros.id

    // Sans cette ligne, « le fichier n'existe plus » après la suppression serait vrai
    // pour un fichier qui n'a jamais été écrit, donc ne mesurerait rien du tout.
    check("le blob existe sur le disque avant la suppression",
          FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")

    try store.delete(gros.id)
    try check("supprimer retire l'entrée de l'historique",
              !store.recent(limit: 100).contains { $0.id == gros.id })
    try check("supprimer rend la charge utile illisible",
              store.payload(gros.id) == nil)
    check("supprimer efface aussi le blob du disque",
          !FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")

    // --- suppression, charge utile restée en base ---
    // Le pendant du cas précédent : sans lui, la branche « pas de fichier à effacer »
    // n'est couverte par rien, et un `blobs.delete` mal gardé lèverait sans être vu.
    let enBase = ClipItem.text("petit", hash: "s2", device: "m", at: 12)
    try store.insert(enBase, payload: Data(repeating: 0x42, count: 10),
                     uti: "public.utf8-plain-text")
    try store.delete(enBase.id)
    try check("supprimer une entrée dont la charge utile est en base retire bien la ligne",
              !store.recent(limit: 100).contains { $0.id == enBase.id })

    // --- l'épinglage protège de la purge ---
    let vieux = ClipItem.text("vieux", hash: "p1", device: "m", at: 20)
    let garde = ClipItem.text("gardé", hash: "p2", device: "m", at: 21)
    let dernier = ClipItem.text("dernier", hash: "p3", device: "m", at: 22)
    for item in [vieux, garde, dernier] {
        try store.insert(item, payload: nil, uti: "public.utf8-plain-text")
    }
    try store.setPinned(garde.id, true)
    try store.purge(keeping: 1)
    let survivants = try store.recent(limit: 100)

    // Le cas conforme d'abord : sans lui, une purge qui ne supprime RIEN rendrait la
    // vérification suivante vraie, et l'épinglage passerait pour une protection.
    check("une entrée non épinglée du même lot disparaît à la purge",
          !survivants.contains { $0.id == vieux.id })
    check("une entrée épinglée par setPinned survit à la purge",
          survivants.contains { $0.id == garde.id })
} catch {
    echec("épingler et supprimer sans erreur", "\(error)")
}

section("Store · tout supprimer", attendu: 6)
do {
    let sandbox = makeSandbox()
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: dossierBlobs, chiffre: chiffreDeTest), chiffre: chiffreDeTest)

    // Une entrée épinglée, une ordinaire, et une charge utile assez grosse pour partir
    // sur le disque : « tout supprimer » doit toutes les emporter, l'épinglée et le
    // fichier blob compris, et nettoyer l'index plein texte.
    let gros = ClipItem.text("facture 2026", hash: "d1", device: "m", at: 1)
    try store.insert(gros, payload: Data(repeating: 0x41, count: 2_000_000), uti: "public.png")
    var epingle = ClipItem.text("à garder", hash: "d2", device: "m", at: 2)
    epingle.pinned = true
    try store.insert(epingle, payload: nil, uti: "public.utf8-plain-text")
    let cheminBlob = dossierBlobs + "/" + gros.id

    // Les deux baselines AVANT : sans elles, « plus rien ne correspond » et « le fichier
    // n'existe plus » seraient vrais sans avoir jamais été faux, donc sans rien mesurer.
    try check("avant : la recherche trouve l'entrée", !store.search("facture", limit: 50).isEmpty)
    check("avant : le blob est sur le disque",
          FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")

    try store.deleteAll()
    try check("tout supprimer vide l'historique", store.recent(limit: 100).isEmpty)
    try check("tout supprimer emporte aussi les épinglées",
              !store.recent(limit: 100).contains { $0.pinned })
    check("tout supprimer efface le blob du disque",
          !FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")
    try check("après : la recherche ne rend plus rien", store.search("facture", limit: 50).isEmpty)
} catch {
    echec("tout supprimer sans erreur", "\(error)")
}

section("Store · tout sauf les épinglés", attendu: 7)
do {
    let sandbox = makeSandbox()
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: dossierBlobs, chiffre: chiffreDeTest), chiffre: chiffreDeTest)

    // Une épinglée AVEC charge utile sur disque, et deux ordinaires dont une sur disque.
    // Le geste garde l'épinglée ET son fichier, et jette les deux autres avec le leur. Le
    // cas de l'épinglée sur disque est le négatif : il prouve qu'on ne nettoie pas les
    // blobs qu'on est censé conserver.
    var epingle = ClipItem.text("clé licence", hash: "k1", device: "m", at: 1)
    epingle.pinned = true
    try store.insert(epingle, payload: Data(repeating: 0x50, count: 2_000_000), uti: "public.png")
    let brut1 = ClipItem.text("presse-papiers du matin", hash: "k2", device: "m", at: 2)
    try store.insert(brut1, payload: Data(repeating: 0x51, count: 2_000_000), uti: "public.png")
    let brut2 = ClipItem.text("autre texte", hash: "k3", device: "m", at: 3)
    try store.insert(brut2, payload: nil, uti: "public.utf8-plain-text")
    let blobEpingle = dossierBlobs + "/" + epingle.id
    let blobBrut1 = dossierBlobs + "/" + brut1.id

    check("avant : le blob de la non-épinglée est sur le disque",
          FileManager.default.fileExists(atPath: blobBrut1), "chemin \(blobBrut1)")
    check("avant : le blob de l'épinglée est sur le disque",
          FileManager.default.fileExists(atPath: blobEpingle), "chemin \(blobEpingle)")

    try store.deleteAllExceptPinned()
    let restants = try store.recent(limit: 100)
    check("tout sauf épinglés garde l'épinglée", restants.contains { $0.id == epingle.id })
    check("tout sauf épinglés retire la non-épinglée", !restants.contains { $0.id == brut1.id })
    check("tout sauf épinglés retire aussi la seconde non-épinglée",
          !restants.contains { $0.id == brut2.id })
    check("tout sauf épinglés efface le blob de la non-épinglée",
          !FileManager.default.fileExists(atPath: blobBrut1), "chemin \(blobBrut1)")
    check("tout sauf épinglés conserve le blob de l'épinglée",
          FileManager.default.fileExists(atPath: blobEpingle), "chemin \(blobEpingle)")
} catch {
    echec("tout sauf les épinglés sans erreur", "\(error)")
}

section("Store · rétention par le temps", attendu: 6)
do {
    let sandbox = makeSandbox()
    let dossierBlobs = sandbox + "/blobs"
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: dossierBlobs))

    // Seuil explicite, loin des dates posées : un chevauchement rendrait le test
    // dépendant du départage d'une égalité, donc ne mesurerait plus la comparaison.
    let seuil = 1000.0

    // Charge utile > 1 Mo pour qu'elle parte sur le disque : c'est la seule façon
    // d'observer l'effacement du blob par `purgerAvant`.
    let vieilleGrosse = ClipItem.text("vieille et grosse", hash: "t1", device: "m", at: 100)
    try store.insert(vieilleGrosse, payload: Data(repeating: 0x41, count: 2_000_000),
                     uti: "public.png")
    let cheminBlob = dossierBlobs + "/" + vieilleGrosse.id

    let recente = ClipItem.text("récente", hash: "t2", device: "m", at: 2000)
    try store.insert(recente, payload: nil, uti: "public.utf8-plain-text")

    var epinglee = ClipItem.text("épinglée et vieille", hash: "t3", device: "m", at: 50)
    epinglee.pinned = true
    try store.insert(epinglee, payload: nil, uti: "public.utf8-plain-text")

    // Baseline : les trois lignes sont bien là avant la purge. Sans ce compte,
    // « la vieille a disparu » serait vrai même si rien n'avait jamais été inséré.
    let avant = try store.count()
    check("les trois entrées sont en base avant la purge", avant == 3, "obtenu \(avant)")
    // Le blob doit exister AVANT, sinon « il n'existe plus » après ne mesure rien.
    check("le blob condamné existe sur le disque avant la purge",
          FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")

    try store.purgerAvant(seuil)
    let restants = try store.recent(limit: 100)

    // Le cas conforme d'abord : sans lui, une purge qui ne supprime RIEN ferait passer
    // les deux vérifications suivantes pour une protection.
    check("la vieille non épinglée est supprimée",
          !restants.contains { $0.id == vieilleGrosse.id })
    check("la non épinglée sous le seuil survit",
          restants.contains { $0.id == recente.id })
    check("la vieille épinglée survit",
          restants.contains { $0.id == epinglee.id })
    check("le blob de la vieille non épinglée est effacé",
          !FileManager.default.fileExists(atPath: cheminBlob), "chemin \(cheminBlob)")
} catch {
    echec("rétention par le temps sans erreur", "\(error)")
}

section("Réglages · bornage de la taille d'historique", attendu: 5)
// Une valeur aberrante saisie à la main ne doit ni vider l'historique à la purge ni
// faire ramer le SELECT du panneau. Les deux bornes et un cas nominal, plus le plancher
// exact pour que le « >= » ne passe pas pour un « > » par accident.
check("une valeur normale passe telle quelle", tailleHistoriqueBornee(1000) == 1000)
check("zéro est relevé au plancher", tailleHistoriqueBornee(0) == 10)
check("une valeur négative est relevée au plancher", tailleHistoriqueBornee(-5) == 10)
check("une valeur énorme est ramenée au plafond", tailleHistoriqueBornee(1_000_000) == 50000)
check("le plancher exact passe inchangé", tailleHistoriqueBornee(10) == 10)

section("Réglages · bornage de la rétention", attendu: 5)
// Le pendant exact du bornage de la taille, avec une différence de fond : ici 0 est
// une valeur légitime (rétention désactivée), donc le plancher est 0 et non un minimum
// positif. Le plafond exact est mesuré pour que le « <= » ne passe pas pour un « < ».
check("une valeur nominale passe telle quelle", retentionJoursBornee(30) == 30)
check("zéro est autorisé (rétention désactivée)", retentionJoursBornee(0) == 0)
check("une valeur négative est ramenée à zéro", retentionJoursBornee(-5) == 0)
check("une valeur énorme est ramenée au plafond", retentionJoursBornee(100_000) == 3650)
check("le plafond exact passe inchangé", retentionJoursBornee(3650) == 3650)

section("Politique de capture", attendu: 13)
let politique = CapturePolicy(blockedBundleIDs: ["com.1password.1password"], secretPattern: nil)

check("un mot de passe marqué ConcealedType n'entre JAMAIS en base",
      politique.decide(RawSnapshot(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                                   text: "hunter2", rtf: nil, image: nil, fileURLs: [],
                                   sourceBundleID: nil)) == .ignore("confidentiel"))

check("un contenu transitoire est ignoré",
      politique.decide(RawSnapshot(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
                                   text: "temp", rtf: nil, image: nil, fileURLs: [],
                                   sourceBundleID: nil)) == .ignore("transitoire"))

check("un contenu auto-généré est ignoré",
      politique.decide(RawSnapshot(types: ["public.utf8-plain-text", "org.nspasteboard.AutoGeneratedType"],
                                   text: "auto", rtf: nil, image: nil, fileURLs: [],
                                   sourceBundleID: nil)) == .ignore("auto-généré"))

check("une app de la liste noire est ignorée",
      politique.decide(RawSnapshot(types: ["public.utf8-plain-text"], text: "secret", rtf: nil,
                                   image: nil, fileURLs: [],
                                   sourceBundleID: "com.1password.1password")) == .ignore("app exclue"))

// LE TEST QUI DONNE SA VALEUR AUX QUATRE PRÉCÉDENTS : le cas conforme doit PASSER.
// Sans lui, une politique qui refuse tout aurait l'air parfaite.
check("un texte ordinaire est conservé",
      politique.decide(RawSnapshot(types: ["public.utf8-plain-text"], text: "bonjour", rtf: nil,
                                   image: nil, fileURLs: [],
                                   sourceBundleID: "org.mozilla.firefox")) == .keep(.text))

check("des fichiers gagnent sur le texte",
      politique.decide(RawSnapshot(types: ["public.file-url", "public.utf8-plain-text"],
                                   text: "/tmp/a", rtf: nil, image: nil, fileURLs: ["/tmp/a"],
                                   sourceBundleID: nil)) == .keep(.files))

check("une image gagne sur le texte",
      politique.decide(RawSnapshot(types: ["public.png", "public.utf8-plain-text"], text: "x",
                                   rtf: nil, image: Data([1, 2]), fileURLs: [],
                                   sourceBundleID: nil)) == .keep(.image))

check("le texte riche gagne sur le texte brut",
      politique.decide(RawSnapshot(types: ["public.rtf", "public.utf8-plain-text"], text: "x",
                                   rtf: Data([1]), image: nil, fileURLs: [],
                                   sourceBundleID: nil)) == .keep(.rtf))

check("un presse-papiers vide est ignoré",
      politique.decide(RawSnapshot(types: [], text: nil, rtf: nil, image: nil, fileURLs: [],
                                   sourceBundleID: nil)) == .ignore("vide"))

// Hors brief, et c'est la vérification qui porte vraiment la garantie : les exclusions
// doivent passer AVANT le choix du type de contenu. Le brief ne teste ConcealedType que
// sur un instantané purement textuel, donc une implémentation qui déciderait du type en
// premier laisserait entrer un mot de passe copié avec une image, sans qu'aucun test ne
// le voie. Ici, l'instantané confidentiel porte à la fois une image et des fichiers.
check("un contenu confidentiel reste ignoré même avec une image et des fichiers",
      politique.decide(RawSnapshot(types: ["public.png", "public.file-url",
                                           "org.nspasteboard.ConcealedType"],
                                   text: "hunter2", rtf: nil, image: Data([1, 2]),
                                   fileURLs: ["/tmp/a"],
                                   sourceBundleID: nil)) == .ignore("confidentiel"))

let filtree = CapturePolicy(blockedBundleIDs: [], secretPattern: "^sk-[A-Za-z0-9]{8,}$")
check("la règle d'expression régulière optionnelle attrape une clé d'API",
      filtree.decide(RawSnapshot(types: ["public.utf8-plain-text"], text: "sk-abcdefgh12345",
                                 rtf: nil, image: nil, fileURLs: [],
                                 sourceBundleID: nil)) == .ignore("motif secret"))
check("la même règle laisse passer un texte ordinaire",
      filtree.decide(RawSnapshot(types: ["public.utf8-plain-text"], text: "bonjour", rtf: nil,
                                 image: nil, fileURLs: [], sourceBundleID: nil)) == .keep(.text))

// Hors brief : `text` est optionnel, donc une image copiée sans texte traverse la règle
// d'expression régulière avec un `text` nil. Chemin de code réel, jamais couvert par le
// brief, qui ne pose le motif que sur des instantanés textuels.
check("la règle d'expression régulière ne touche pas une image sans texte",
      filtree.decide(RawSnapshot(types: ["public.png"], text: nil, rtf: nil,
                                 image: Data([1, 2]), fileURLs: [],
                                 sourceBundleID: nil)) == .keep(.image))

section("Service de capture", attendu: 16)

/// Presse-papiers de test. `poser` incrémente le compteur comme le fait le vrai
/// `NSPasteboard`, ce qui permet de rejouer un changement sans AppKit.
final class FauxPresse: PasteboardReading {
    var changeCount = 0
    var prochain: RawSnapshot?
    /// Combien de lectures rendent encore le vide avant que `prochain` ne devienne
    /// lisible. C'est l'écriture en cours : types déclarés, contenu pas encore là.
    var lecturesAVide = 0
    /// Nombre total de lectures, pour prouver qu'un refus définitif ne se relit pas
    /// et qu'une relance ne boucle pas.
    private(set) var lectures = 0

    func read() -> RawSnapshot? {
        lectures += 1
        if lecturesAVide > 0 {
            lecturesAVide -= 1
            return RawSnapshot(types: ["public.utf8-plain-text"], text: "", rtf: nil,
                               image: nil, fileURLs: [], sourceBundleID: nil)
        }
        return prochain
    }

    func poser(_ s: RawSnapshot) {
        prochain = s; changeCount += 1
    }
}

do {
    let faux = FauxPresse()
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    let service = CaptureService(pasteboard: faux, store: store,
                                 policy: CapturePolicy(blockedBundleIDs: [], secretPattern: nil),
                                 deviceID: "macA")

    check("sans changement, rien n'est capturé", service.poll() == false)

    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "bonjour", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: "org.mozilla.firefox"))
    check("un changement est capturé", service.poll() == true)
    try check("l'entrée est en base", store.count() == 1)

    check("repasser sans changement ne recapture pas", service.poll() == false)

    faux.poser(RawSnapshot(types: ["public.utf8-plain-text", CapturePolicy.concealed],
                           text: "hunter2", rtf: nil, image: nil, fileURLs: [],
                           sourceBundleID: nil))
    check("un secret change le compteur mais n'entre pas en base", service.poll() == false)
    // Le détail d'un `check` est un @autoclosure non lançant : `try` y est interdit,
    // donc le compte se lit avant et se range dans une variable.
    let apresSecret = try store.count()
    check("le compte reste à 1", apresSecret == 1, "obtenu \(apresSecret)")

    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "bonjour", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: nil))
    _ = service.poll()
    try check("un contenu identique ne crée pas de doublon", store.count() == 1)

    // Hors brief : le marquage `isRemote`, qui en v2 évitera de renvoyer sur l'iPhone
    // ce qui en venait. Les deux moitiés sont obligatoires : sans le cas ordinaire, un
    // code qui marquerait TOUT comme distant passerait la vérification du cas distant.
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "copie locale", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: nil))
    _ = service.poll()
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text", "com.apple.is-remote-clipboard"],
                           text: "copie venue de l'iPhone", rtf: nil, image: nil, fileURLs: [],
                           sourceBundleID: nil))
    _ = service.poll()
    let toutes = try store.recent(limit: 100)
    let locale = toutes.first { $0.searchText == "copie locale" }
    let distante = toutes.first { $0.searchText == "copie venue de l'iPhone" }
    check("une copie ordinaire entre en base avec isRemote à false", locale?.isRemote == false,
          "obtenu \(String(describing: locale?.isRemote))")
    check("une copie marquée presse-papiers distant entre en base avec isRemote à true",
          distante?.isRemote == true, "obtenu \(String(describing: distante?.isRemote))")

    // Hors brief : le plafond de 50 Mo, déclaré à la tâche 6 et appliqué ici pour la
    // première fois. Une seule vérification ne mesurerait rien, un code qui rejetterait
    // TOUT passerait le test du rejet. D'où le couple, à un octet de part et d'autre.
    let avantPlafond = try store.count()
    faux.poser(RawSnapshot(types: ["public.png"], text: "juste sous le plafond", rtf: nil,
                           image: Data(repeating: 0x42, count: BlobStore.plafond - 1),
                           fileURLs: [], sourceBundleID: nil))
    check("une charge utile d'un octet sous le plafond est capturée", service.poll() == true)

    faux.poser(RawSnapshot(types: ["public.png"], text: "juste au-dessus du plafond", rtf: nil,
                           image: Data(repeating: 0x43, count: BlobStore.plafond + 1),
                           fileURLs: [], sourceBundleID: nil))
    check("une charge utile d'un octet au-dessus du plafond est ignorée",
          service.poll() == false)

    // `poll()` rend aussi `false` quand l'insertion lève : sans ce compte, une écriture
    // de blob en échec ferait passer la moitié « ignorée » pour la bonne raison.
    let apresPlafond = try store.count()
    check("le plafond n'a laissé entrer que la charge utile sous la limite",
          apresPlafond == avantPlafond + 1,
          "obtenu \(apresPlafond) pour \(avantPlafond + 1) attendu(s)")
} catch {
    echec("capture sans erreur", "\(error)")
}

// Hors brief : la politique doit être APPELÉE sur le vrai chemin, pas seulement testée
// en isolation. Le cas du secret ci-dessus en donne une preuve, celui-ci en donne une
// seconde par un motif de refus différent, la liste noire d'applications. Deux motifs
// distincts qui traversent le même appel, c'est ce qui prouve le branchement.
do {
    let faux = FauxPresse()
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    let service = CaptureService(
        pasteboard: faux, store: store,
        policy: CapturePolicy(blockedBundleIDs: ["com.apple.keychainaccess"], secretPattern: nil),
        deviceID: "macA"
    )

    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "mot de passe", rtf: nil,
                           image: nil, fileURLs: [],
                           sourceBundleID: "com.apple.keychainaccess"))
    check("une copie venue d'une application de la liste noire n'est pas capturée",
          service.poll() == false)
    let apresExclusion = try store.count()
    check("rien n'entre en base pour une application de la liste noire",
          apresExclusion == 0, "obtenu \(apresExclusion)")

    // Moitié conforme du couple : sans elle, un service dont la base serait cassée
    // rendrait `false` partout et passerait pour un filtre qui fonctionne.
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "texte anodin", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: "org.mozilla.firefox"))
    check("la même politique laisse passer une application hors liste noire",
          service.poll() == true)
    let apresAnodin = try store.count()
    check("l'entrée hors liste noire est bien en base", apresAnodin == 1,
          "obtenu \(apresAnodin)")
} catch {
    echec("capture avec liste noire sans erreur", "\(error)")
}

// Écriture encore en cours. Mesuré le 2026-09-30 : quatre dictées SuperWhisper ont
// été lues 40 ms après leur écriture et n'ont rien laissé en base alors que le texte
// tenait encore une seconde. Le compteur avait été consommé par une lecture vide, et
// le remplissage du type promis ne le fait pas bouger : sans relance, le texte est
// perdu jusqu'à la prochaine écriture. Une seule relance par changement, sinon un
// contenu réellement vide se relirait à chaque tour.
section("Capture : une écriture en cours est relue", attendu: 7)
do {
    let faux = FauxPresse()
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    let service = CaptureService(pasteboard: faux, store: store,
                                 policy: CapturePolicy(blockedBundleIDs: [], secretPattern: nil),
                                 deviceID: "macA")

    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "dictée", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: nil))
    faux.lecturesAVide = 1
    check("la première lecture d'une écriture en cours ne garde rien", service.poll() == false)
    check("la relance du tour suivant récupère la dictée", service.poll() == true)
    let apresRelance = try store.count()
    check("la dictée est en base", apresRelance == 1, "obtenu \(apresRelance)")
    let lecturesApresCapture = faux.lectures
    _ = service.poll()
    check("sans changement ni relance due, plus aucune lecture",
          faux.lectures == lecturesApresCapture,
          "obtenu \(faux.lectures) lectures pour \(lecturesApresCapture) attendues")

    // La lecture qui rend `nil` (et non un texte vide) déclenche la même relance.
    faux.prochain = nil
    faux.changeCount += 1
    check("une lecture nulle ne garde rien", service.poll() == false)
    faux.prochain = RawSnapshot(types: ["public.utf8-plain-text"], text: "après nil", rtf: nil,
                                image: nil, fileURLs: [], sourceBundleID: nil)
    check("la relance récupère aussi après une lecture nulle", service.poll() == true)

    // Le vide qui persiste ne boucle pas : une relance, puis plus rien tant qu'aucun
    // compteur ne change.
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "", rtf: nil,
                           image: nil, fileURLs: [], sourceBundleID: nil))
    faux.lecturesAVide = 2
    _ = service.poll()
    _ = service.poll()
    let lecturesAvantBoucle = faux.lectures
    _ = service.poll()
    check("le vide qui persiste ne se relit pas en boucle",
          faux.lectures == lecturesAvantBoucle,
          "obtenu \(faux.lectures) lectures pour \(lecturesAvantBoucle) attendues")
} catch {
    echec("relance sans erreur", "\(error)")
}

// Notre PROPRE écriture reste vue par la capture, et la restauration désactivée par
// défaut n'y change rien : c'est l'écriture du collage que `poll()` lit, pas la
// restauration. En collage texte brut nous n'écrivons que `searchText` en `.string`,
// `decide` rend `.keep(.text)`, le hash diffère de celui de l'entrée RTF ou image
// d'origine, et `insert` crée une NOUVELLE ligne. Coller une entrée RTF en texte brut
// polluait donc l'historique d'un doublon texte, à chaque collage.
//
// Le couple est obligatoire : un `ignorerJusqua` qui bloquerait TOUT passerait la
// moitié « n'entre pas en base » sans rien prouver.
section("tâche 12 : la capture ignore notre propre écriture", attendu: 4)
do {
    let faux = FauxPresse()
    let store = try Store(path: makeSandbox() + "/db.sqlite", chiffre: chiffreDeTest)
    let service = CaptureService(pasteboard: faux, store: store,
                                 policy: CapturePolicy(blockedBundleIDs: [], secretPattern: nil),
                                 deviceID: "macA")

    // Ce que ferait `coller` : écrire, puis déclarer le compteur obtenu comme nôtre.
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "entrée recollée en texte brut",
                           rtf: nil, image: nil, fileURLs: [], sourceBundleID: nil))
    service.ignorerJusqua(faux.changeCount)
    check("un changeCount déclaré nôtre n'est pas capturé", service.poll() == false,
          "coller une entrée RTF en texte brut ajouterait un doublon texte à chaque fois")
    let apresNotreEcriture = try store.count()
    check("rien n'est entré en base pour notre propre écriture", apresNotreEcriture == 0,
          "obtenu \(apresNotreEcriture)")

    // Moitié conforme : la vraie copie suivante de l'utilisateur doit entrer.
    faux.poser(RawSnapshot(types: ["public.utf8-plain-text"], text: "vraie copie de l'utilisateur",
                           rtf: nil, image: nil, fileURLs: [], sourceBundleID: nil))
    check("un changeCount ultérieur est capturé normalement", service.poll() == true,
          "toute copie suivant un collage serait perdue")
    let apresVraieCopie = try store.count()
    check("la vraie copie est bien en base", apresVraieCopie == 1,
          "obtenu \(apresVraieCopie)")
} catch {
    echec("capture ignorant notre propre écriture sans erreur", "\(error)")
}

section("Machine à états du geste Cmd", attendu: 43)
var m = HotKeyMachine(count: 5)

check("au repos, une touche n'est pas consommée", m.recevoir(.key(.v)).consomme == false)

_ = m.recevoir(.modificateurDown)
check("Cmd seul n'ouvre rien", m.etat == .arme)

let ouverture = m.recevoir(.key(.v))
check("Cmd puis V ouvre l'overlay", ouverture.0 == .ouvrir)
check("l'ouverture consomme le V", ouverture.consomme == true)
check("l'index part à zéro", m.index == 0)

check("V descend d'un cran", m.recevoir(.key(.v)).0 == .deplacer(1))
check("l'index suit", m.index == 1)
check("flèche bas descend aussi", m.recevoir(.key(.down)).0 == .deplacer(1))
check("flèche haut remonte", m.recevoir(.key(.up)).0 == .deplacer(-1))

/// LE CŒUR DE LA DEMANDE : Cmd maintenu puis 3 va directement au 3e élément.
let saut = m.recevoir(.key(.digit(3)))
check("le chiffre 3 va au 3e élément", saut.0 == .allerA(2), "obtenu \(saut.0)")
check("l'index vaut bien 2", m.index == 2)
check("le chiffre est CONSOMMÉ, il ne s'écrit pas dans l'app dessous",
      saut.consomme == true)

check("le chiffre 1 va au premier", m.recevoir(.key(.digit(1))).0 == .allerA(0))
check("un chiffre au-delà du nombre d'entrées ne bouge pas",
      m.recevoir(.key(.digit(9))).0 == .rien)

check("Z bascule le texte brut", m.recevoir(.key(.z)).0 == .basculerTexteBrut)
check("l'état texte brut a changé", m.texteBrut == true)
check("X bascule l'épinglage", m.recevoir(.key(.x)).0 == .basculerEpingle)

let collage = m.recevoir(.modificateurUp)
check("relâcher Cmd colle la sélection", collage.0 == .coller(index: 0, texteBrut: true))
check("après le collage on est au repos", m.etat == .inactif)

var n = HotKeyMachine(count: 5)
_ = n.recevoir(.modificateurDown); _ = n.recevoir(.key(.v))
check("Échap ferme sans coller", n.recevoir(.key(.escape)).0 == .fermer)
check("après Échap, relâcher Cmd ne colle rien", n.recevoir(.modificateurUp).0 == .rien)

var o = HotKeyMachine(count: 5)
_ = o.recevoir(.modificateurDown)
check("Cmd relâché sans V ne fait rien", o.recevoir(.modificateurUp).0 == .rien)
check("et on repart de l'état inactif", o.etat == .inactif)

var p = HotKeyMachine(count: 0)
_ = p.recevoir(.modificateurDown)
check("sans historique, V n'ouvre pas", p.recevoir(.key(.v)).0 == .rien)

/// Hors brief : un modificateur ne doit JAMAIS être avalé, dans aucun état. Un
/// flagsChanged consommé laisserait un Cmd coincé dans toutes les applications de
/// l'utilisateur, bien après la fermeture de l'overlay. Le cas qui compte le plus
/// est le dernier : c'est le Cmd relâché qui déclenche le collage, et il serait
/// tentant de le consommer « puisqu'il sert à quelque chose ».
var mods = HotKeyMachine(count: 5)
check("Cmd enfoncé n'est pas consommé", mods.recevoir(.modificateurDown).consomme == false)
check("Cmd relâché sans overlay n'est pas consommé",
      mods.recevoir(.modificateurUp).consomme == false)
_ = mods.recevoir(.modificateurDown); _ = mods.recevoir(.key(.v))
check("le Cmd qui déclenche le collage n'est pas consommé non plus",
      mods.recevoir(.modificateurUp).consomme == false)

/// Hors brief : le couple de la touche inconnue. Au repos elle file à l'application,
/// overlay ouvert elle est avalée, sinon un caractère parasite s'écrit dans le
/// document caché sous la liste. Sans la moitié « au repos », une machine qui
/// avalerait TOUT passerait la moitié « overlay ouvert » sans rien prouver.
var inconnue = HotKeyMachine(count: 5)
check("au repos, une touche inconnue file à l'application",
      inconnue.recevoir(.key(.other)).consomme == false)
_ = inconnue.recevoir(.modificateurDown); _ = inconnue.recevoir(.key(.v))
let parasite = inconnue.recevoir(.key(.other))
check("overlay ouvert, une touche inconnue ne déclenche rien", parasite.0 == .rien,
      "obtenu \(parasite.0)")
check("overlay ouvert, une touche inconnue est avalée", parasite.consomme == true)

/// Hors brief : les bornes. Le brief teste UN déplacement, jamais la saturation, or
/// un index qui dépasse count - 1 fait sortir la vue du tableau à l'affichage. On
/// pousse cinq fois sur trois entrées, dans les deux sens.
var bornes = HotKeyMachine(count: 3)
_ = bornes.recevoir(.modificateurDown); _ = bornes.recevoir(.key(.v))
for _ in 0 ..< 4 {
    _ = bornes.recevoir(.key(.down))
}

// Quatre descentes sur trois entrees : 0 -> 1 -> 2 -> 0 -> 1. Le cycle est le
// comportement demande le 2026-08-26 : marteler V ne doit jamais
// cesser de repondre.
check("quatre descentes sur trois entrées reviennent à l'index 1", bornes.index == 1,
      "obtenu \(bornes.index)")
let descenteCyclique = bornes.recevoir(.key(.down))
check("la cinquième descente atteint la dernière ligne", bornes.index == 2,
      "obtenu \(bornes.index)")
check("la descente reste avalée en toutes circonstances", descenteCyclique.consomme == true)
let bouclageBas = bornes.recevoir(.key(.down))
check("depuis la DERNIÈRE ligne, une descente de plus revient à la PREMIÈRE",
      bornes.index == 0, "obtenu \(bornes.index)")
check("le bouclage reste avalé", bouclageBas.consomme == true)

let bouclageHaut = bornes.recevoir(.key(.up))
check("depuis la première ligne, une remontée va à la DERNIÈRE", bornes.index == 2,
      "obtenu \(bornes.index)")
check("la remontée reste avalée", bouclageHaut.consomme == true)

/// Le cas conforme, sans lequel un cycle qui renverrait toujours 0 passerait :
/// une descente ordinaire au milieu de la liste avance bien d'un cran.
var milieu = HotKeyMachine(count: 5)
_ = milieu.recevoir(.modificateurDown)
_ = milieu.recevoir(.key(.v))
_ = milieu.recevoir(.key(.down))
check("au milieu de la liste, une descente avance d'un seul cran", milieu.index == 1,
      "obtenu \(milieu.index)")

/// Hors brief : le rang 0 et un rang négatif. « 0 » vise la cible -1, qui n'existe
/// pas. La machine doit rendre `.rien` SANS bouger la sélection, et avaler tout de
/// même la touche : la laisser filer écrirait un « 0 » dans le document du dessous.
var rangs = HotKeyMachine(count: 5)
_ = rangs.recevoir(.modificateurDown); _ = rangs.recevoir(.key(.v))
_ = rangs.recevoir(.key(.digit(4)))
let zero = rangs.recevoir(.key(.digit(0)))
check("le chiffre 0 ne mène nulle part", zero.0 == .rien, "obtenu \(zero.0)")
check("le chiffre 0 est tout de même avalé", zero.consomme == true)
check("le chiffre 0 ne déplace pas la sélection", rangs.index == 3, "obtenu \(rangs.index)")
let negatif = rangs.recevoir(.key(.digit(-2)))
check("un rang négatif ne mène nulle part", negatif.0 == .rien, "obtenu \(negatif.0)")
check("un rang négatif est tout de même avalé", negatif.consomme == true)

// ---------------------------------------------------------------------------
// Tâche 10 : la table des codes de touches. C'est la SEULE partie pure du tap,
// tout le reste (CGEventTap, permission Accessibilité, réarmement après
// désactivation) parle au système et se vérifie à la main, étape 5 du brief.
// Aucun test creux n'est écrit à leur place.
//
// La table est écrite à la main et s'est DÉJÀ trompée une fois : un premier jet
// bornait la plage à `18...25`, ce qui laissait filer les chiffres 7 et 8 dont
// les codes valent 26 et 28. D'où deux exigences ici : chaque chiffre de 1 à 9 a
// sa propre vérification, et la table est mesurée dans les deux sens, sinon une
// implémentation qui rendrait `.digit(1)` pour tout passerait au vert.
section("Tap clavier · table des codes", attendu: 21)

// Sens 1 : les touches nommées du geste.
check("le code 9 est V", HotKeyKey.traduire(9) == .v,
      "obtenu \(String(describing: HotKeyKey.traduire(9)))")
check("le code 6 est Z", HotKeyKey.traduire(6) == .z,
      "obtenu \(String(describing: HotKeyKey.traduire(6)))")
check("le code 7 est X", HotKeyKey.traduire(7) == .x,
      "obtenu \(String(describing: HotKeyKey.traduire(7)))")
check("le code 53 est Échap", HotKeyKey.traduire(53) == .escape,
      "obtenu \(String(describing: HotKeyKey.traduire(53)))")
check("le code 125 est la flèche bas", HotKeyKey.traduire(125) == .down,
      "obtenu \(String(describing: HotKeyKey.traduire(125)))")
check("le code 126 est la flèche haut", HotKeyKey.traduire(126) == .up,
      "obtenu \(String(describing: HotKeyKey.traduire(126)))")

// Sens 1 bis : les neuf chiffres, un par un. Fastidieux, et c'est exactement la
// raison pour laquelle une valeur se glisse dans ce genre de dictionnaire sans
// que personne ne le voie. Les codes ne suivent pas l'ordre des chiffres : 5 et
// 6 sont inversés (23 et 22), et 7, 8, 9 valent 26, 28, 25.
check("le code 18 est le chiffre 1", HotKeyKey.traduire(18) == .digit(1),
      "obtenu \(String(describing: HotKeyKey.traduire(18)))")
check("le code 19 est le chiffre 2", HotKeyKey.traduire(19) == .digit(2),
      "obtenu \(String(describing: HotKeyKey.traduire(19)))")
check("le code 20 est le chiffre 3", HotKeyKey.traduire(20) == .digit(3),
      "obtenu \(String(describing: HotKeyKey.traduire(20)))")
check("le code 21 est le chiffre 4", HotKeyKey.traduire(21) == .digit(4),
      "obtenu \(String(describing: HotKeyKey.traduire(21)))")
check("le code 23 est le chiffre 5", HotKeyKey.traduire(23) == .digit(5),
      "obtenu \(String(describing: HotKeyKey.traduire(23)))")
check("le code 22 est le chiffre 6", HotKeyKey.traduire(22) == .digit(6),
      "obtenu \(String(describing: HotKeyKey.traduire(22)))")
// Ces deux-là sont HORS de la plage 18...25 qu'un premier jet avait écrite :
// sans eux, les chiffres 7 et 8 seraient silencieusement ignorés.
check("le code 26 est le chiffre 7", HotKeyKey.traduire(26) == .digit(7),
      "obtenu \(String(describing: HotKeyKey.traduire(26)))")
check("le code 28 est le chiffre 8", HotKeyKey.traduire(28) == .digit(8),
      "obtenu \(String(describing: HotKeyKey.traduire(28)))")
check("le code 25 est le chiffre 9", HotKeyKey.traduire(25) == .digit(9),
      "obtenu \(String(describing: HotKeyKey.traduire(25)))")

// Sens 2 : le refus. Sans ces lignes, une table qui rendrait la même touche pour
// tout code passerait les vérifications du dessus sans broncher. Les codes 24 et
// 27 sont le piège précis de la plage élargie : ils tombent dans 18...28 sans
// être des chiffres (ce sont « = » et « - »), le dictionnaire doit rendre nil.
check("le code 24, dans la plage mais pas un chiffre, ne rend rien", HotKeyKey.traduire(24) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(24)))")
check("le code 27, dans la plage mais pas un chiffre, ne rend rien", HotKeyKey.traduire(27) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(27)))")
check("le code 0, la touche A, ne rend rien", HotKeyKey.traduire(0) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(0)))")
check("le code 12, la touche Q, ne rend rien", HotKeyKey.traduire(12) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(12)))")
check("le code 50, la touche accent grave, ne rend rien", HotKeyKey.traduire(50) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(50)))")
check("une touche inconnue ne rend rien", HotKeyKey.traduire(999) == nil,
      "obtenu \(String(describing: HotKeyKey.traduire(999)))")

// Finding 1 : le repli sur `.other` doit être BRANCHÉ, pas seulement disponible.
//
// `EventTap.swift` importe CoreGraphics, et le symlinker dans cette cible lierait
// neuf bibliothèques graphiques au binaire de test (mesuré tâche 10). Son chemin
// réel reste donc hors de portée d'un test d'exécution, et c'est très exactement
// la faille décrite par le finding 1 : la table de traduction était testée, le
// repli du tap ne l'était pas, et un `guard ... else { return event }` renvoyait
// la touche à l'application de devant pendant que l'overlay était ouvert.
//
// À défaut de pouvoir exécuter `traiter`, les trois premières vérifications
// mesurent le TEXTE du call site. C'est la seule chose mécaniquement vérifiable
// ici, et c'est elle qui tombe si le garde-fou se débranche. Les suivantes
// mesurent le contrat que ce call site doit servir.
section("Tap clavier · repli sur .other branché", attendu: 19)

let racineDuPaquet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Tests/CopyclipzerTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // racine du paquet
let cheminDuTap = racineDuPaquet.appendingPathComponent("Sources/HotKey/EventTap.swift")
let sourceDuTap = (try? String(contentsOf: cheminDuTap, encoding: .utf8)) ?? ""

check("la source du tap est lisible", !sourceDuTap.isEmpty,
      "rien lu dans \(cheminDuTap.path)")
check("le tap ne traduit plus les codes lui-même",
      !sourceDuTap.contains("HotKeyKey.traduire"),
      "le tap rappelle la table directement, donc il peut à nouveau abandonner en silence")
check("le tap délègue son aiguillage à la fonction pure `decider`",
      sourceDuTap.contains("decider(type:"),
      "aucun appel à `decider` au call site, le tap décide seul et hors de portée des tests")

/// Les codes du scénario. Chacun est une touche que la machine doit VOIR arriver
/// en `.other`, au lieu de ne pas la voir du tout.
let repli40 = HotKeyKey.traduire(40) ?? .other
check("le code 40, la touche K, arrive en .other", repli40 == .other, "obtenu \(repli40)")
let repli2 = HotKeyKey.traduire(2) ?? .other
check("le code 2, la touche D, arrive en .other", repli2 == .other, "obtenu \(repli2)")
let repli4 = HotKeyKey.traduire(4) ?? .other
check("le code 4, la touche H, arrive en .other", repli4 == .other, "obtenu \(repli4)")
let repli0 = HotKeyKey.traduire(0) ?? .other
check("le code 0, la touche A, arrive en .other", repli0 == .other, "obtenu \(repli0)")
let repli123 = HotKeyKey.traduire(123) ?? .other
check("le code 123, la flèche gauche, arrive en .other", repli123 == .other, "obtenu \(repli123)")
let repli124 = HotKeyKey.traduire(124) ?? .other
check("le code 124, la flèche droite, arrive en .other", repli124 == .other, "obtenu \(repli124)")
let repli36 = HotKeyKey.traduire(36) ?? .other
check("le code 36, Entrée, arrive en .other", repli36 == .other, "obtenu \(repli36)")
let repli48 = HotKeyKey.traduire(48) ?? .other
check("le code 48, Tab, arrive en .other", repli48 == .other, "obtenu \(repli48)")
let repli49 = HotKeyKey.traduire(49) ?? .other
check("le code 49, Espace, arrive en .other", repli49 == .other, "obtenu \(repli49)")
let repli29 = HotKeyKey.traduire(29) ?? .other
check("le code 29, le chiffre 0, arrive en .other", repli29 == .other, "obtenu \(repli29)")
let pavePlieEnAutre = (Int64(82) ... Int64(92)).allSatisfy { (HotKeyKey.traduire($0) ?? .other) == .other }
check("tout le pavé numérique, 82 à 92, arrive en .other", pavePlieEnAutre,
      "au moins un code du pavé se traduit en autre chose que .other")

/// Sens inverse : le repli ne doit pas écraser ce que la table sait traduire.
let repli9 = HotKeyKey.traduire(9) ?? .other
check("le repli ne dénature pas le V", repli9 == .v, "obtenu \(repli9)")
let repli20 = HotKeyKey.traduire(20) ?? .other
check("le repli ne dénature pas le chiffre 3", repli20 == .digit(3), "obtenu \(repli20)")

/// Le contrat servi par ce call site : consommer overlay ouvert, laisser filer sinon.
var machineOuverteAutre = HotKeyMachine(count: 3)
_ = machineOuverteAutre.recevoir(.modificateurDown)
_ = machineOuverteAutre.recevoir(.key(.v))
let consommeOuvertAutre = machineOuverteAutre.recevoir(.key(repli40)).consomme
check("overlay ouvert, une touche non mappée est consommée", consommeOuvertAutre,
      "état \(machineOuverteAutre.etat), donc Cmd-K partirait dans le document")
var machineArmeeAutre = HotKeyMachine(count: 3)
_ = machineArmeeAutre.recevoir(.modificateurDown)
let consommeArmeAutre = machineArmeeAutre.recevoir(.key(repli40)).consomme
check("Cmd armé mais overlay fermé, une touche non mappée n'est pas consommée", !consommeArmeAutre,
      "les raccourcis Cmd normaux doivent continuer de passer")
var machineInactiveAutre = HotKeyMachine(count: 3)
let consommeInactifAutre = machineInactiveAutre.recevoir(.key(repli40)).consomme
check("hors geste, une touche non mappée n'est pas consommée", !consommeInactifAutre,
      "le tap avalerait des touches sans que le geste ait commencé")

// L'aiguillage du tap, extrait en fonction pure. Ce n'est pas un test de plus :
// c'est un chemin qui n'était pas testable et qui le devient. Cette fonction
// aurait attrapé le finding 1, et elle verrouille « jamais un flagsChanged n'est
// consommé », propriété jusqu'ici affirmée en commentaire et jamais mesurée.
//
// Sa signature ne cite ni CGEvent, ni CGEventType, ni CGEventFlags : uniquement
// des booléens, un Int64 et des types maison. C'est cette discipline qui permet
// de la symlinker dans la cible de test sans lier CoreGraphics au binaire.
section("Tap clavier · aiguillage pur", attendu: 15)

/// Rend l'entrée d'une décision `.soumettre`, et nil pour toutes les autres. Une
/// décision qui relaie ne soumet rien à la machine, donc rien n'est consommé.
func entreeSoumise(_ decision: HotKeyDecision) -> HotKeyInput? {
    if case let .soumettre(entree) = decision {
        return entree
    }
    return nil
}

let flagsAvecCmd = decider(type: .flagsChanged, commandEnfonce: true, majEnfonce: false,
                           optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 0, etat: .inactif)
check("un flagsChanged avec Cmd enfoncé annonce .modificateurDown",
      flagsAvecCmd == .relayerApres(.modificateurDown), "obtenu \(flagsAvecCmd)")
let flagsSansCmd = decider(type: .flagsChanged, commandEnfonce: false, majEnfonce: false,
                           optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 0, etat: .inactif)
check("un flagsChanged sans Cmd annonce .modificateurUp",
      flagsSansCmd == .relayerApres(.modificateurUp), "obtenu \(flagsSansCmd)")

/// Le verrou : un modificateur ne doit JAMAIS finir soumis à la machine, sinon
/// elle pourrait demander de l'avaler et Cmd resterait coincé enfoncé pour
/// l'application de devant. `.relayerApres` prévient la machine et relaie quoi
/// qu'elle réponde, c'est structurel et non conditionnel.
///
/// Le balayage couvre les quatre modificateurs depuis la tâche 15, et non plus deux :
/// un flagsChanged de Maj ou d'Option arrive pendant que Cmd est enfoncé, et c'est
/// exactement là qu'une garde mal placée avalerait un modificateur.
var combinaisonsDeFlags: [(Bool, Bool, Bool, Bool, Int64)] = []
for cmd in [true, false] {
    for maj in [true, false] {
        for opt in [true, false] {
            for ctrl in [true, false] {
                for code in [Int64(0), 7, 8, 9, 29, 40, 999] {
                    combinaisonsDeFlags.append((cmd, maj, opt, ctrl, code))
                }
            }
        }
    }
}

let flagsJamaisSoumis = combinaisonsDeFlags.allSatisfy { cmd, maj, opt, ctrl, code in
    if case .relayerApres = decider(type: .flagsChanged, commandEnfonce: cmd, majEnfonce: maj,
                                    optionEnfonce: opt, controlEnfonce: ctrl,
                                    estSynthetique: false, code: code, etat: .inactif)
    {
        return true
    }
    return false
}

check("un flagsChanged n'est jamais soumis à la machine, sur 112 combinaisons",
      flagsJamaisSoumis, "au moins une combinaison rend autre chose que .relayerApres")

let cmdC = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                   optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 8, etat: .inactif)
check("Cmd-C déclenche une capture sans avaler", cmdC == .capturerPuisRelayer, "obtenu \(cmdC)")
let cmdX = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                   optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 7, etat: .inactif)
check("Cmd-X déclenche une capture sans avaler", cmdX == .capturerPuisRelayer, "obtenu \(cmdX)")

/// Sens négatif : sans Cmd, ces deux codes ne sont plus des captures. Sans ces
/// deux lignes, un aiguillage qui capturerait à chaque frappe passerait au vert.
///
/// Depuis la tâche 15, ils ne sont pas non plus soumis à la machine : sans le
/// modificateur du geste, un keyDown est relayé tel quel, ce qui est précisément ce
/// qui rend Ctrl-V à Claude Code. Voir la section « tâche 15 ».
let cSansCmd = decider(type: .keyDown, commandEnfonce: false, majEnfonce: false,
                       optionEnfonce: false, controlEnfonce: true, estSynthetique: false, code: 8, etat: .inactif)
check("le code 8 sans Cmd n'est pas une capture, et n'est plus soumis non plus",
      cSansCmd == .relayer, "obtenu \(cSansCmd)")
let xSansCmd = decider(type: .keyDown, commandEnfonce: false, majEnfonce: false,
                       optionEnfonce: false, controlEnfonce: true, estSynthetique: false, code: 7, etat: .inactif)
check("le code 7 sans Cmd est relayé, la touche X n'existe que sous le geste",
      xSansCmd == .relayer, "obtenu \(xSansCmd)")

/// Le finding 1, mesuré cette fois sur le vrai chemin d'aiguillage. Cmd enfoncé
/// depuis la tâche 15 : c'est le seul état dans lequel l'overlay peut être ouvert,
/// donc le seul où la garantie « une touche non mappée est avalée » a un sens.
let code29 = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                     optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 29, etat: .inactif)
check("le code 29, le chiffre 0, est soumis en .other et non relayé",
      code29 == .soumettre(.key(.other)), "obtenu \(code29)")
let code40 = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                     optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 40, etat: .inactif)
check("le code 40, la touche K, est soumis en .other et non relayé",
      code40 == .soumettre(.key(.other)), "obtenu \(code40)")

let code9 = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                    optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 9, etat: .inactif)
check("le code 9 garde son identité de V", code9 == .soumettre(.key(.v)), "obtenu \(code9)")
let code20 = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                     optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 20, etat: .inactif)
check("le code 20 garde son rang de chiffre 3",
      code20 == .soumettre(.key(.digit(3))), "obtenu \(code20)")

let typeAutre = decider(type: .autre, commandEnfonce: true, majEnfonce: false,
                        optionEnfonce: false, controlEnfonce: true, estSynthetique: false, code: 9, etat: .inactif)
check("un type hors keyDown et flagsChanged est relayé tel quel",
      typeAutre == .relayer, "obtenu \(typeAutre)")

/// Composition avec la machine : c'est elle qui dit s'il faut avaler, mais elle
/// ne peut le dire que si l'aiguillage lui a soumis quelque chose.
var machineOuverteAiguillee = HotKeyMachine(count: 3)
_ = machineOuverteAiguillee.recevoir(.modificateurDown)
_ = machineOuverteAiguillee.recevoir(.key(.v))
let consommeOuvertAiguille = entreeSoumise(code40).map { machineOuverteAiguillee.recevoir($0).consomme } ?? false
check("overlay ouvert, une traduction impossible est consommée", consommeOuvertAiguille,
      "décision \(code40), donc Cmd-K atteindrait le document")
var machineArmeeAiguillee = HotKeyMachine(count: 3)
_ = machineArmeeAiguillee.recevoir(.modificateurDown)
let consommeArmeAiguille = entreeSoumise(code40).map { machineArmeeAiguillee.recevoir($0).consomme } ?? false
check("Cmd armé sans overlay, la même traduction impossible n'est pas consommée",
      !consommeArmeAiguille, "un raccourci Cmd ordinaire serait avalé")

var machineFlecheBas = HotKeyMachine(count: 3)
_ = machineFlecheBas.recevoir(.modificateurDown)
_ = machineFlecheBas.recevoir(.key(.v))
let decisionFlecheBas = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                                optionEnfonce: false, controlEnfonce: false, estSynthetique: false, code: 125, etat: .ouvert)
let resultatFlecheBas = entreeSoumise(decisionFlecheBas).map { machineFlecheBas.recevoir($0) }
check("overlay ouvert, la flèche bas déplace la sélection et est consommée",
      resultatFlecheBas?.0 == .deplacer(1) && resultatFlecheBas?.consomme == true,
      "obtenu \(String(describing: resultatFlecheBas)) pour la décision \(decisionFlecheBas)")

section("tâche 11 : formatage de l'overlay", attendu: 13)

// Le choix de l'icône. Les quatre valeurs attendues diffèrent deux à deux, donc une
// table qui rendrait la même icône pour tout le monde tombe ici, et la vérification
// d'unicité qui suit dit explicitement que c'est cela qui est mesuré.
check("une entrée texte porte l'icône textformat.abc",
      icone(.text) == "textformat.abc", "obtenu \(icone(.text))")
check("une entrée RTF porte l'icône doc.richtext",
      icone(.rtf) == "doc.richtext", "obtenu \(icone(.rtf))")
check("une image porte l'icône photo",
      icone(.image) == "photo", "obtenu \(icone(.image))")
check("une liste de fichiers porte l'icône doc.on.doc",
      icone(.files) == "doc.on.doc", "obtenu \(icone(.files))")
let toutesLesIcones = Set([icone(.text), icone(.rtf), icone(.image), icone(.files)])
check("les quatre types ont quatre icônes distinctes", toutesLesIcones.count == 4,
      "obtenu \(toutesLesIcones.sorted())")

// La préparation du titre. La vérification du titre ordinaire est celle qui donne son
// sens aux autres : sans elle, une fonction qui renverrait la chaîne vide pour tout
// passerait les tests de mise en une ligne et de troncature.
check("un titre ordinaire ressort identique",
      titreAffiche("Bonjour le monde") == "Bonjour le monde",
      "obtenu \(titreAffiche("Bonjour le monde"))")
let multiligne = titreAffiche("a\nb\nc")
check("un titre multiligne ne contient plus de retour à la ligne",
      !multiligne.contains("\n"), "obtenu \(multiligne)")
check("un titre multiligne devient une seule ligne séparée par des espaces",
      multiligne == "a b c", "obtenu \(multiligne)")
check("un titre vide rend une chaîne vide sans planter",
      titreAffiche("") == "", "obtenu \(titreAffiche(""))")
check("un couple retour chariot plus saut de ligne ne compte que pour un espace",
      titreAffiche("a\r\nb") == "a b", "obtenu \(titreAffiche("a\r\nb"))")

let tresLong = String(repeating: "x", count: plafondDuTitreAffiche + 40)
let tronque = titreAffiche(tresLong)
check("un titre plus long que le plafond est coupé et signalé par une ellipse",
      tronque.count == plafondDuTitreAffiche + 1 && tronque.hasSuffix("…"),
      "longueur \(tronque.count) pour un plafond de \(plafondDuTitreAffiche)")
let pileAuPlafond = String(repeating: "y", count: plafondDuTitreAffiche)
check("un titre pile au plafond ressort intact, sans ellipse",
      titreAffiche(pileAuPlafond) == pileAuPlafond,
      "longueur \(titreAffiche(pileAuPlafond).count)")

// La vue identifie ses lignes par `\.element.id` : deux entrées de même identifiant
// feraient protester SwiftUI à l'exécution. Côté base, `id` est PRIMARY KEY ; côté
// fabrique, c'est un UUID, et c'est ce second point qui se mesure ici.
let e1 = ClipItem.text("a", hash: "h1", device: "d")
let e2 = ClipItem.text("a", hash: "h1", device: "d")
check("deux entrées fabriquées portent des identifiants distincts", e1.id != e2.id,
      "les deux valent \(e1.id)")

// ---------------------------------------------------------------------------
// Tâche 12 : le collage.
//
// Ce que ces sections mesurent, et ce qu'elles ne peuvent pas mesurer. Trois
// choses restent hors de portée d'un test : le `CGEvent` réellement posté,
// l'arrivée du collage dans l'application de devant, et le comportement réel de
// la course avec elle. Elles partent en vérification manuelle. Aucun test creux
// n'est écrit à leur place.
//
// Ce qui EST mesurable a donc été extrait en fonctions pures dans
// `Sources/Paste/PastePolicy.swift`, symlinké ici : la reconnaissance de nos
// propres événements, le choix de la représentation écrite dans le presse-papiers
// et la garde de restauration. `Paster.swift` importe AppKit et CoreGraphics, il
// n'est jamais symlinké : le lier à cette cible ajouterait neuf bibliothèques
// graphiques au binaire des tests (mesuré tâche 8, remesuré tâche 10).
//
// Conséquence sur les drapeaux : ils se manipulent ici en `UInt64` brut et jamais
// en `CGEventFlags`, qui viendrait de CoreGraphics. Les valeurs système utilisées
// sont celles de `CGEventFlags` : maskShift 0x00020000, maskControl 0x00040000,
// maskAlternate 0x00080000, maskCommand 0x00100000.

// Le fond de la correction du 2026-08-26 : l'identité ne se lit PAS dans les
// drapeaux. `0x000008` est NX_DEVICELCMDKEYMASK et `0x000010` NX_DEVICERCMDKEYMASK
// (IOLLEvent.h:256), posés par le système sur tout événement matériel selon le côté
// de la touche Commande enfoncée. Un vrai Cmd-C de la main gauche vaut donc
// `0x00100108`, et il était pris pour un des nôtres : la capture instantanée ne
// partait pas et deux copies en moins d'une seconde en perdaient une. Le zéro passé
// en signature est ce que porte réellement un événement matériel dans
// `eventSourceUserData`, mesuré sur cette machine le 2026-08-26.
//
// Correction du 2026-09-30 : l'ancienne reconnaissance ne connaissait que notre
// signature, donc le Cmd-V automatique de SuperWhisper (signature 0, pid 1546,
// drapeaux 0x20100000) était soumis à la machine à gestes. L'utilisateur tenant Cmd
// à cet instant, ce V synthétique ouvrait l'overlay et se faisait avaler, avec les
// touches suivantes. Le prédicat prend maintenant le type, le pid source et les
// drapeaux, et deux clés INDÉPENDANTES arrêtent un tel événement, chacune suffisant
// seule : le pid (`eventSourceUnixProcessID`, non nul pour tout posteur) et, sur une
// frappe portant Cmd, l'absence des deux bits de commande de périphérique.
section("tâche 12 : reconnaissance de nos propres événements", attendu: 15)

check("un Cmd-C réel touche Commande gauche n'est pas synthétique",
      !estSynthetique(type: .keyDown, drapeauxBruts: 0x0010_0108, signatureEvenement: 0, pidSource: 0),
      "la capture instantanée ne partirait pas, une copie sur deux serait perdue")
check("un Cmd-C réel touche Commande droite n'est pas synthétique",
      !estSynthetique(type: .keyDown, drapeauxBruts: 0x0010_0110, signatureEvenement: 0, pidSource: 0),
      "la capture instantanée ne partirait pas, une copie sur deux serait perdue")

check("un événement portant notre signature est reconnu comme synthétique",
      estSynthetique(type: .keyDown, drapeauxBruts: drapeauxDuCollage,
                     signatureEvenement: signatureDuCollage, pidSource: 0),
      "notre propre Cmd-V repasserait par le tap")

// Les deux clés qui arrêtent les synthétiques des autres, chacune seule. La ligne de
// SuperWhisper relevée au journal le 2026-09-30 est `pid=1546`,
// `drapeaux=0x20100000`, `signature=0` : neutraliser une clé ne suffit pas à la
// laisser passer, et c'est écrit pour que le sabotage se mesure.
check("un Cmd-V de SuperWhisper (pid 1546) est filtré",
      estSynthetique(type: .keyDown, drapeauxBruts: 0x2010_0000, signatureEvenement: 0, pidSource: 1546),
      "le V automatique reviendrait ouvrir le geste et se ferait avaler")
check("le même sans pid reste filtré par l'absence de bit périphérique",
      estSynthetique(type: .keyDown, drapeauxBruts: 0x2010_0000, signatureEvenement: 0, pidSource: 0),
      "la clé du pid désactivée, rien ne l'arrêterait plus")
check("un posteur qui imite le bit périphérique reste filtré par son pid",
      estSynthetique(type: .keyDown, drapeauxBruts: 0x2010_0008, signatureEvenement: 0, pidSource: 1546),
      "la clé du bit désactivée, rien ne l'arrêterait plus")
check("un flagsChanged posté par un processus est filtré aussi",
      estSynthetique(type: .flagsChanged, drapeauxBruts: 0x2010_0000, signatureEvenement: 0, pidSource: 1546),
      "un modificateur synthétique armerait la machine à la place de la main")
check("un vrai changement de modificateur reste lu",
      !estSynthetique(type: .flagsChanged, drapeauxBruts: 0x0010_0108, signatureEvenement: 0, pidSource: 0),
      "le geste ne s'armerait plus jamais")
// Trou assumé et écrit : le bit de périphérique n'a jamais été mesuré sur les
// flagsChanged, donc on ne l'exige pas d'eux. Si ce test tombe un jour, c'est que
// quelqu'un a durci la règle sans la mesure qui le justifie.
check("le bit de périphérique n'est pas exigé des flagsChanged",
      !estSynthetique(type: .flagsChanged, drapeauxBruts: maskCommandBrut, signatureEvenement: 0, pidSource: 0),
      "exiger le bit sur les flagsChanged désarmerait le geste si le clavier ne le pose pas")

// Le couple ci-dessus ne suffit pas : une fonction qui rendrait `true` pour toute
// signature non nulle le passerait, et une fonction qui lirait encore les drapeaux
// aussi. Les trois suivantes ferment ces trous.
check("une signature qui n'est pas la nôtre n'est pas reconnue",
      !estSynthetique(type: .keyDown, drapeauxBruts: drapeauxDuCollage, signatureEvenement: 1, pidSource: 0),
      "n'importe quel outil tiers qui signe ses événements serait pris pour nous")
check("des drapeaux voisins sans signature ne sont pas reconnus",
      !estSynthetique(type: .keyDown, drapeauxBruts: 0x0002_0000 | 0x0004_0000 | 0x0008_0000, signatureEvenement: 0, pidSource: 0),
      "Maj, Ctrl et Option passeraient pour notre marque, tout le geste serait ignoré")
check("aucun drapeau ni signature n'est pas synthétique",
      !estSynthetique(type: .keyDown, drapeauxBruts: 0, signatureEvenement: 0, pidSource: 0),
      "une frappe nue serait ignorée par le tap")

// La signature elle-même. Nulle, elle vaudrait celle de tout événement matériel et
// le prédicat rendrait `true` partout : c'est le mode d'échec exact que la ligne
// suivante garde.
check("notre signature est non nulle",
      signatureDuCollage != 0,
      "un événement matériel porte zéro, tout deviendrait synthétique")

// Les drapeaux réellement posés sur les deux moitiés du Cmd-V synthétique. Ils
// n'identifient plus rien, ils imitent un vrai clavier : Cmd sans quoi le collage
// n'en serait plus un, et le bit Commande gauche pour les applications qui refusent
// un collage dont aucun bit dépendant du périphérique n'est posé.
check("les drapeaux de notre Cmd-V synthétique portent la touche Commande",
      drapeauxDuCollage & maskCommandBrut != 0,
      "obtenu \(String(drapeauxDuCollage, radix: 16)), le V partirait sans Cmd")
check("les drapeaux de notre Cmd-V synthétique portent le bit Commande gauche",
      drapeauxDuCollage & bitCommandeGauche != 0,
      "obtenu \(String(drapeauxDuCollage, radix: 16)), les applications qui lisent les bits périphérique refuseraient le collage")

// L'aiguillage. La règle « un événement marqué ne va jamais à la machine » est un
// PARAMÈTRE de `decider`, et non un `return` anticipé dans `EventTap.traiter` :
// posée dans le tap, elle vivrait dans le seul fichier du projet que les tests ne
// peuvent pas atteindre. Ici, elle se mesure.
section("tâche 12 : l'aiguillage relaie nos propres événements", attendu: 11)

let vSynthetique = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                           optionEnfonce: false, controlEnfonce: false,
                           estSynthetique: true, code: 9, etat: .inactif)
check("notre propre Cmd-V est relayé sans passer par la machine",
      vSynthetique == .relayer, "obtenu \(vSynthetique)")
let vOrdinaire = decider(type: .keyDown, commandEnfonce: true, majEnfonce: false,
                         optionEnfonce: false, controlEnfonce: false,
                         estSynthetique: false, code: 9, etat: .inactif)
check("le même V non marqué est bien soumis à la machine",
      vOrdinaire == .soumettre(.key(.v)), "obtenu \(vOrdinaire)")

/// Le filtre s'applique aussi à `flagsChanged`, et pas seulement à la branche
/// `keyDown` : c'est ce qui dit qu'il est bien la PREMIÈRE ligne de `decider`.
///
/// Le motif écrit ici jusqu'au 2026-08-26 était faux et disait « notre Cmd-V émet
/// aussi un changement de modificateurs ». Poser un `CGEvent` clavier avec des
/// `flags` ne génère AUCUN `flagsChanged` distinct, ce cas ne se produit donc jamais.
/// Le vrai motif est plus bas, sur le keyDown.
let flagsSynthetique = decider(type: .flagsChanged, commandEnfonce: false, majEnfonce: false,
                               optionEnfonce: false, controlEnfonce: false,
                               estSynthetique: true, code: 0, etat: .inactif)
check("un flagsChanged marqué est relayé, pas lu comme un relâchement de Cmd",
      flagsSynthetique == .relayer, "obtenu \(flagsSynthetique)")
let flagsOrdinaire = decider(type: .flagsChanged, commandEnfonce: false, majEnfonce: false,
                             optionEnfonce: false, controlEnfonce: false,
                             estSynthetique: false, code: 0, etat: .inactif)
check("le même flagsChanged non marqué reste un relâchement de Cmd",
      flagsOrdinaire == .relayerApres(.modificateurUp), "obtenu \(flagsOrdinaire)")

/// Balayage : quel que soit le type, l'état des modificateurs et le code, un
/// événement marqué est relayé. C'est ce qui dit que la règle passe AVANT tout le
/// reste de l'aiguillage, et pas seulement avant la branche keyDown.
var combinaisonsMarquees: [(HotKeyEventType, Bool, Bool, Int64)] = []
for type in [HotKeyEventType.keyDown, .flagsChanged, .autre] {
    for ctrl in [true, false] {
        for cmd in [true, false] {
            for code in [Int64(0), 7, 8, 9, 20, 29, 40, 125, 999] {
                combinaisonsMarquees.append((type, ctrl, cmd, code))
            }
        }
    }
}

let toujoursRelaye = combinaisonsMarquees.allSatisfy { type, ctrl, cmd, code in
    decider(type: type, commandEnfonce: cmd, majEnfonce: false, optionEnfonce: false,
            controlEnfonce: ctrl, estSynthetique: true, code: code,
            etat: .inactif) == .relayer
}

check("sur 108 combinaisons, un événement marqué est toujours relayé", toujoursRelaye,
      "au moins une combinaison marquée rend autre chose que .relayer")

/// Rend l'entrée qu'une décision fait parvenir à la machine, quelle que soit la
/// forme de la décision. `entreeSoumise` ne regarde que `.soumettre` : ici il faut
/// aussi voir passer les modificateurs, qui arrivent par `.relayerApres`.
func entreeVersLaMachine(_ decision: HotKeyDecision) -> HotKeyInput? {
    switch decision {
    case .relayer, .capturerPuisRelayer: return nil
    case let .relayerApres(entree): return entree
    case let .soumettre(entree): return entree
    }
}

/// Composition avec la machine, overlay ouvert. C'est la formulation exacte du
/// risque : notre propre collage ne doit pas refermer l'overlay qui l'a demandé.
var machineCollageSynthetique = HotKeyMachine(count: 3)
_ = machineCollageSynthetique.recevoir(.modificateurDown)
_ = machineCollageSynthetique.recevoir(.key(.v))
let sortieSynthetique = entreeVersLaMachine(flagsSynthetique).map { machineCollageSynthetique.recevoir($0) }
check("overlay ouvert, notre Cmd-V synthétique ne dit rien à la machine",
      sortieSynthetique == nil, "obtenu \(String(describing: sortieSynthetique))")
check("overlay ouvert, notre Cmd-V synthétique laisse l'overlay ouvert",
      machineCollageSynthetique.etat == .ouvert,
      "état \(machineCollageSynthetique.etat), l'overlay se refermerait pendant son propre collage")

/// Cas conforme : un vrai relâchement du modificateur, lui, doit toujours coller et
/// refermer. Sans cette ligne, un filtre qui avalerait tout passerait au vert.
///
/// La flèche bas n'est pas décorative depuis la tâche 15 : sans navigation, le
/// relâchement rend `.collerNatif` et non `.coller`, ce qui est le comportement
/// voulu. C'est bien un collage depuis la base qui est mesuré ici, donc il faut
/// avoir navigué.
var machineCollageReel = HotKeyMachine(count: 3)
_ = machineCollageReel.recevoir(.modificateurDown)
_ = machineCollageReel.recevoir(.key(.v))
_ = machineCollageReel.recevoir(.key(.down))
let sortieReelle = entreeVersLaMachine(flagsOrdinaire).map { machineCollageReel.recevoir($0) }
check("overlay ouvert, un vrai relâchement de Cmd colle et referme",
      sortieReelle?.0 == .coller(index: 1, texteBrut: false) && machineCollageReel.etat == .inactif,
      "obtenu \(String(describing: sortieReelle)) et l'état \(machineCollageReel.etat)")

/// LE VRAI MOTIF du filtre, celui que ce projet a écrit faux à trois endroits jusqu'au
/// 2026-08-26. Ce n'est pas un changement de modificateurs, il n'y en a pas. C'est que
/// notre keyDown V (code 9), non filtré, serait soumis à la machine : si l'utilisateur
/// ré-enfonce Cmd avant que l'événement posté ne soit traité, la machine est en
/// `.arme`, `(.arme, .key(.v))` rend `(.ouvrir, consomme: true)`, et NOTRE PROPRE Cmd-V
/// est avalé. L'overlay se rouvre et rien n'est collé.
var machineCmdRepris = HotKeyMachine(count: 3)
_ = machineCmdRepris.recevoir(.modificateurDown)
let sortieVSynthetique = entreeVersLaMachine(vSynthetique).map { machineCmdRepris.recevoir($0) }
check("Cmd ré-enfoncé, notre Cmd-V synthétique ne dit rien à la machine",
      sortieVSynthetique == nil, "obtenu \(String(describing: sortieVSynthetique))")
check("Cmd ré-enfoncé, notre Cmd-V synthétique ne rouvre pas l'overlay",
      machineCmdRepris.etat == .arme,
      "état \(machineCmdRepris.etat), notre propre collage serait avalé et rien ne serait collé")

/// Moitié conforme, sans laquelle la précédente ne mesure rien : le MÊME V, dans le
/// MÊME état, mais non filtré, est bien avalé et rouvre l'overlay. C'est exactement ce
/// qui arriverait à notre collage sans le filtre.
var machineSansFiltre = HotKeyMachine(count: 3)
_ = machineSansFiltre.recevoir(.modificateurDown)
let sortieSansFiltre = entreeVersLaMachine(vOrdinaire).map { machineSansFiltre.recevoir($0) }
check("le même V non filtré est avalé et rouvre l'overlay",
      sortieSansFiltre?.consomme == true && sortieSansFiltre?.0 == .ouvrir
          && machineSansFiltre.etat == .ouvert,
      "obtenu \(String(describing: sortieSansFiltre)) et l'état \(machineSansFiltre.etat)")

// Le choix de ce qui part dans le presse-papiers. Extrait en fonction pure : sinon
// il ne vivrait que dans une méthode qui parle à NSPasteboard, donc mesuré par rien.
section("tâche 12 : représentation écrite dans le presse-papiers", attendu: 8)

check("une entrée texte donne du texte",
      representationAEcrire(kind: .text, texteBrut: false, aPayload: true) == .texte,
      "obtenu \(representationAEcrire(kind: .text, texteBrut: false, aPayload: true))")
check("une entrée RTF avec sa charge utile donne du RTF",
      representationAEcrire(kind: .rtf, texteBrut: false, aPayload: true) == .rtf,
      "obtenu \(representationAEcrire(kind: .rtf, texteBrut: false, aPayload: true))")
check("texte brut demandé sur une entrée RTF donne du texte",
      representationAEcrire(kind: .rtf, texteBrut: true, aPayload: true) == .texte,
      "obtenu \(representationAEcrire(kind: .rtf, texteBrut: true, aPayload: true))")
check("une entrée RTF sans charge utile retombe sur le texte",
      representationAEcrire(kind: .rtf, texteBrut: false, aPayload: false) == .texte,
      "obtenu \(representationAEcrire(kind: .rtf, texteBrut: false, aPayload: false))")
check("une image avec sa charge utile donne l'image",
      representationAEcrire(kind: .image, texteBrut: false, aPayload: true) == .image,
      "obtenu \(representationAEcrire(kind: .image, texteBrut: false, aPayload: true))")
check("une image sans charge utile retombe sur le texte",
      representationAEcrire(kind: .image, texteBrut: false, aPayload: false) == .texte,
      "obtenu \(representationAEcrire(kind: .image, texteBrut: false, aPayload: false))")
check("texte brut demandé sur une image donne du texte",
      representationAEcrire(kind: .image, texteBrut: true, aPayload: true) == .texte,
      "obtenu \(representationAEcrire(kind: .image, texteBrut: true, aPayload: true))")
check("une liste de fichiers retombe sur le texte en v1",
      representationAEcrire(kind: .files, texteBrut: false, aPayload: true) == .texte,
      "obtenu \(representationAEcrire(kind: .files, texteBrut: false, aPayload: true))")

// La restauration. Correction du 2026-08-26 : elle n'est PLUS le comportement par
// défaut. Le commentaire précédent affirmait ici que le prédicat, et non un délai
// deviné, supprimait la course avec l'application cible. C'est faux. Il ne voit que
// la cible qui ÉCRIT, jamais celle qui LIT tard, et lire ne fait pas bouger
// `changeCount` : une cible occupée qui interroge le presse-papiers 300 ms après le
// Cmd-V obtenait l'ancien contenu, sans qu'aucun compteur ne l'annonce. Le prédicat
// reste juste pour ce qu'il mesure, et ses quatre cas restent, mais c'est la valeur
// par défaut qui supprime la course.
section("tâche 12 : garde de restauration du presse-papiers", attendu: 5)

check("la restauration du presse-papiers est désactivée par défaut",
      restaurationParDefaut == false,
      "une cible qui lit tard obtiendrait l'ancien contenu au lieu de l'entrée choisie, en silence")

check("compteur inchangé et sauvegarde non vide : on restaure",
      doitRestaurer(sauvegardeVide: false, changeCountApresEcriture: 12, changeCountActuel: 12),
      "sans ce cas conforme, une garde qui refuse toujours passerait les trois autres")
check("compteur modifié : on ne restaure pas",
      !doitRestaurer(sauvegardeVide: false, changeCountApresEcriture: 12, changeCountActuel: 13),
      "on écraserait ce que l'application cible vient d'écrire")
check("sauvegarde vide et compteur inchangé : on ne restaure pas",
      !doitRestaurer(sauvegardeVide: true, changeCountApresEcriture: 12, changeCountActuel: 12),
      "on viderait le presse-papiers au lieu de laisser l'élément collé")
check("sauvegarde vide et compteur modifié : on ne restaure pas",
      !doitRestaurer(sauvegardeVide: true, changeCountApresEcriture: 12, changeCountActuel: 40),
      "les deux refus doivent tenir ensemble")

// Câblage. Ni `Paster.coller` ni `EventTap.traiter` ne sont exécutables ici : les
// deux fichiers importent AppKit ou CoreGraphics. Ce qui reste mécaniquement
// vérifiable, c'est le TEXTE de leurs call sites, comme pour le finding 1 de la
// tâche 10. C'est ce qui tombe si le marquage ou le filtre se débranchent.
section("tâche 12 : câblage du collage", attendu: 13)

let cheminDuColleur = racineDuPaquet.appendingPathComponent("Sources/Paste/Paster.swift")
let sourceDuColleur = (try? String(contentsOf: cheminDuColleur, encoding: .utf8)) ?? ""
check("la source du colleur est lisible", !sourceDuColleur.isEmpty,
      "rien lu dans \(cheminDuColleur.path)")
check("le Cmd-V synthétique est construit avec les drapeaux du collage",
      sourceDuColleur.contains("CGEventFlags(rawValue: drapeauxDuCollage)"),
      "le Cmd-V partirait sans Cmd, ou sans le bit périphérique que lisent certaines applications")
check("l'appui et le relâchement portent tous deux ces drapeaux",
      sourceDuColleur.contains("bas?.flags = drapeaux") && sourceDuColleur.contains("haut?.flags = drapeaux"),
      "une moitié sans Cmd ne serait plus un collage")
check("l'appui et le relâchement portent tous deux notre signature",
      sourceDuColleur.contains("bas?.setIntegerValueField(.eventSourceUserData, value: signatureDuCollage)")
          && sourceDuColleur.contains("haut?.setIntegerValueField(.eventSourceUserData, value: signatureDuCollage)"),
      "une moitié non signée suffit à refermer l'overlay pendant son propre collage")
check("le colleur délègue le choix de la représentation à la fonction pure",
      sourceDuColleur.contains("representationAEcrire(kind:"),
      "le choix serait revenu dans la méthode qui parle à NSPasteboard, hors de portée des tests")
check("le colleur délègue la garde de restauration à la fonction pure",
      sourceDuColleur.contains("doitRestaurer(sauvegardeVide:"),
      "la garde serait revenue dans le bloc différé, hors de portée des tests")
// La valeur par défaut vit dans le fichier pur exprès : posée en dur dans la
// signature de `coller`, elle aurait été le seul octet de tout le collage à décider
// du comportement sans qu'aucune vérification puisse le lire. Les deux lignes vont
// ensemble, la valeur ET son branchement : une constante juste que `coller` n'utilise
// pas est un garde-fou débranché.
check("le colleur prend la restauration par défaut dans la fonction pure",
      sourceDuColleur.contains("restaurer: Bool = restaurationParDefaut"),
      "la valeur par défaut serait posée en dur dans Paster, hors de portée des tests")
check("le tap passe la signature de nos propres événements à l'aiguillage",
      sourceDuTap.contains("estSynthetique: Paster.estSynthetique(event, type: typePur)"),
      "l'aiguillage ne verrait jamais la signature, le filtre serait débranché")
// `coller` s'exécuterait dans le callback du tap : `.coller` sort de `decider` par
// `.relayerApres`, donc `onInput` est appelé synchroniquement dans `traiter`. Avec une
// capture de 20 Mo dans le presse-papiers, la lecture de tous les types, la lecture
// SQLite, l'écriture et deux `CGEvent.post` dépassent le délai du tap, macOS envoie
// `tapDisabledByTimeout` et les frappes de la fenêtre de rattrapage sont perdues. Le
// renvoi doit être INTERNE : à la charge de l'appelant, le site d'appel de la tâche 14
// pourrait l'oublier.
check("le colleur renvoie son travail sur la boucle principale, en interne",
      sourceDuColleur.contains("func coller(")
          && sourceDuColleur.contains("DispatchQueue.main.async { [weak self] in")
          && sourceDuColleur.contains("self?.collerMaintenant(item, texteBrut: texteBrut, restaurer: restaurer)"),
      "le callback du tap dépasserait son délai et macOS le désactiverait")
check("le colleur prévient la capture après son écriture",
      sourceDuColleur.contains("capture.ignorerJusqua(apresEcriture)"),
      "chaque collage en texte brut ajouterait un doublon à l'historique")
// La contre-épreuve du CRITICAL 1 : l'identité doit se lire dans le champ libre de
// l'événement, jamais dans ses drapeaux. Si quelqu'un la remet dans les drapeaux,
// cette ligne tombe avant que la main gauche de l'utilisateur ne le découvre.
check("le colleur lit l'identité dans eventSourceUserData et non dans les drapeaux",
      sourceDuColleur.contains("signatureEvenement: event.getIntegerValueField(.eventSourceUserData)"),
      "l'identification serait revenue dans les drapeaux, où le bit Commande gauche la fausse")
// La recopie de `maskCommand` ne peut être comparée à la vraie constante que dans un
// fichier qui importe CoreGraphics, donc jamais par un test. La garde était en
// `precondition` dans `init`, deux fois mal placée : `precondition` n'est retiré qu'en
// `-Ounchecked` et `swift build -c release` compile en `-O`, elle arrêtait donc
// l'application en production, et `estSynthetique` étant `static`, le tap l'appelle
// sans jamais construire de `Paster`. Le couple ci-dessous mesure les deux moitiés du
// déplacement, le départ et l'arrivée.
check("la garde de la recopie a quitté le chemin d'instanciation",
      !sourceDuColleur.contains("precondition(maskCommandBrut"),
      "un arrêt fatal en production resterait, pour une constante système gelée")
check("la garde de la recopie est sur le chemin statique, celui que le tap emprunte",
      sourceDuColleur.contains("guard recopieDeMaskCommandVerifiee else"),
      "la recopie ne serait vérifiée que si un Paster est construit, or le tap n'en construit aucun")

// La taille du panneau n'était accordée qu'à l'ouverture. Or la touche Z bascule
// `texteBrut` sur un panneau DÉJÀ affiché, et `OverlayView` ajoute alors un `Divider`
// et une ligne : 276 points sans la mention, 312 avec, mesuré à la tâche 11. Les 36
// points de « collage en texte brut » se dessinaient hors du `contentView` et étaient
// rognés, donc l'utilisateur appuyait sur Z et n'obtenait aucun retour visuel, ce qui
// est exactement la fonction que cette mention existe pour rendre.
//
// `OverlayPanel` importe AppKit et SwiftUI, il n'est jamais symlinké : symlinker un
// fichier graphique dans cette cible lui lie neuf bibliothèques (mesuré tâche 8,
// remesuré tâche 10). Ce qui se mesure ici est donc le câblage, pas le rendu. La
// hauteur réelle, elle, part en vérification manuelle.
section("tâche 12 : la taille du panneau suit le contenu", attendu: 5)

let cheminDuPanneau = racineDuPaquet.appendingPathComponent("Sources/Overlay/OverlayPanel.swift")
let sourceDuPanneau = (try? String(contentsOf: cheminDuPanneau, encoding: .utf8)) ?? ""
check("la source du panneau est lisible", !sourceDuPanneau.isEmpty,
      "rien lu dans \(cheminDuPanneau.path)")
check("le panneau expose un rafraichir() qui réaccorde la taille au contenu",
      sourceDuPanneau.contains("func rafraichir() {")
          && sourceDuPanneau.contains("accorderLaTailleAuContenu()"),
      "la taille resterait celle du contentRect de départ après un basculement Z")
check("l'ouverture passe elle aussi par rafraichir()",
      sourceDuPanneau.contains("func afficher() {\n        rafraichir()"),
      "l'ouverture et le rafraîchissement divergeraient, l'un des deux finirait faux")
// Disponible ne suffit pas : un garde-fou non branché est un garde-fou absent. Sans
// cet abonnement, l'appel serait à la charge de la tâche 14, qui peut l'oublier sur
// `.basculerTexteBrut` sans que rien ne le signale.
check("le rafraîchissement est branché sur le modèle, pas laissé au site d'appel",
      sourceDuPanneau.contains("model.objectWillChange.sink")
          && sourceDuPanneau.contains("self?.rafraichir()"),
      "la tâche 14 pourrait oublier l'appel, et Z n'afficherait toujours rien")
// `isReleasedWhenClosed` vaut `true` par défaut alors qu'`OverlayPanel` garde une
// référence forte. `masquer()` fait `orderOut`, donc rien ne casse aujourd'hui, mais
// le premier `close()` ajouté serait une sur-libération.
check("le panneau n'est pas libéré à la fermeture",
      sourceDuPanneau.contains("panel.isReleasedWhenClosed = false"),
      "un close() ajouté plus tard libérerait un panneau encore référencé")

// ---------------------------------------------------------------------------
// Tâche 15 : le geste passe de Ctrl à Cmd, et gagne un relais natif.
//
// Motif, relevé à l'usage le 2026-08-26 : Ctrl-V n'est PAS libre. Le plan affirmait
// « Ctrl-V est libre sur macOS », ce qui est vrai du système et faux du poste de
// travail, où Claude Code s'en sert pour coller une image. Copyclipzer l'avalait, et
// il a fallu quitter l'application pour coller. Erreur de périmètre de mesure, pas
// d'implémentation : la vérification portait sur macOS et non sur les outils utilisés.
//
// Le changement porte le risque exactement inverse. Cmd-V est LE collage du système,
// donc chaque collage de la machine traverse désormais le tap, et une image ou une
// liste de fichiers qui ferait un aller-retour par notre base pourrait perdre des
// types. D'où le relais natif, garantie centrale de cette tâche : Cmd relâché sans
// aucune navigation ne colle pas depuis la base, il repose le Cmd-V d'origine. Le
// presse-papiers n'est alors ni lu ni écrit, aucune fidélité n'est en jeu.
section("tâche 15 : la machine s'arme sur Cmd et sait relayer nativement", attendu: 14)

/// Le cœur de la protection de fidélité, dans les deux sens. Sans la seconde moitié,
/// une machine qui rendrait TOUJOURS `.collerNatif` passerait la première sans rien
/// prouver, et le produit ne collerait plus jamais l'entrée choisie.
var natif = HotKeyMachine(count: 5)
_ = natif.recevoir(.modificateurDown)
_ = natif.recevoir(.key(.v))
check("à l'ouverture, rien n'a encore été navigué", natif.aNavigue == false,
      "la machine partirait convaincue d'une navigation, tout collage passerait par la base")
let relacheSansNavigation = natif.recevoir(.modificateurUp)
check("Cmd relâché sans navigation repose le collage natif",
      relacheSansNavigation.0 == .collerNatif, "obtenu \(relacheSansNavigation.0)")
check("le relais natif n'avale pas le relâchement de Cmd",
      relacheSansNavigation.consomme == false,
      "Cmd resterait coincé enfoncé pour l'application de devant")
check("après le relais natif, la machine repart au repos", natif.etat == .inactif,
      "état \(natif.etat)")

var apresNavigation = HotKeyMachine(count: 5)
_ = apresNavigation.recevoir(.modificateurDown)
_ = apresNavigation.recevoir(.key(.v))
_ = apresNavigation.recevoir(.key(.down))
let collageChoisi = apresNavigation.recevoir(.modificateurUp)
check("Cmd relâché APRÈS navigation colle l'entrée choisie depuis la base",
      collageChoisi.0 == .coller(index: 1, texteBrut: false), "obtenu \(collageChoisi.0)")
check("le collage choisi n'avale pas non plus le relâchement de Cmd",
      collageChoisi.consomme == false,
      "Cmd resterait coincé enfoncé pour l'application de devant")

/// Les cinq touches que le brief nomme, une vérification chacune, plus la flèche haut
/// que le brief range avec la flèche bas. « Avoir navigué » veut dire : depuis
/// l'ouverture, aucun V supplémentaire, aucune flèche, aucun chiffre. Z et X comptent
/// aussi : qui a basculé le texte brut ou épinglé ne veut plus d'un collage natif.
func aNavigueApres(_ touche: HotKeyKey) -> Bool {
    var machine = HotKeyMachine(count: 5)
    _ = machine.recevoir(.modificateurDown)
    _ = machine.recevoir(.key(.v))
    _ = machine.recevoir(.key(touche))
    return machine.aNavigue
}

check("un V supplémentaire compte comme une navigation", aNavigueApres(.v),
      "le second V descendrait d'un cran et le collage repartirait quand même en natif")
check("la flèche bas compte comme une navigation", aNavigueApres(.down),
      "la sélection descendrait et le collage repartirait quand même en natif")
check("la flèche haut compte comme une navigation", aNavigueApres(.up),
      "la sélection remonterait et le collage repartirait quand même en natif")
check("un chiffre compte comme une navigation", aNavigueApres(.digit(3)),
      "le rang choisi serait ignoré et le collage repartirait en natif")
check("Z compte comme une navigation", aNavigueApres(.z),
      "le texte brut serait demandé puis perdu, le collage repartirait en natif")
check("X compte comme une navigation", aNavigueApres(.x),
      "l'épinglage serait demandé puis perdu, le collage repartirait en natif")

// Moitié de refus : une touche que l'overlay avale sans rien en faire n'est pas une
// navigation. Sans elle, un `aNavigue = true` posé sur TOUTE touche passerait les six
// lignes ci-dessus, et le relais natif ne se déclencherait plus jamais.
check("une touche non mappée ne compte pas comme une navigation", !aNavigueApres(.other),
      "toute frappe parasite ferait passer un Cmd-V ordinaire par notre base")

/// Échap doit rester une annulation FRANCHE. Le piège est direct : une lecture naïve
/// de « pas de navigation, donc collage natif » collerait quand même après Échap, et
/// la seule façon d'annuler un Cmd-V disparaîtrait du produit.
var apresEchap = HotKeyMachine(count: 5)
_ = apresEchap.recevoir(.modificateurDown)
_ = apresEchap.recevoir(.key(.v))
_ = apresEchap.recevoir(.key(.escape))
let apresAnnulation = apresEchap.recevoir(.modificateurUp)
check("après Échap, relâcher Cmd ne colle rien, ni depuis la base ni en natif",
      apresAnnulation.0 == .rien, "obtenu \(apresAnnulation.0)")

// Le point de vigilance de la tâche 15, et sa raison d'être. Cmd est enfoncé pour des
// dizaines de raccourcis (Cmd-C, Cmd-S, Cmd-Q, Cmd-Tab, Cmd-Maj-V), donc la machine
// s'arme désormais à CHAQUE appui. Rien de ce que l'utilisateur fait tous les jours ne
// doit changer de comportement, et c'est ici que ça se mesure.
//
// Le cas le plus dangereux est nouveau et n'existait pas avec Ctrl : Cmd-Maj-V sert
// dans beaucoup d'applications à coller sans mise en forme. L'avaler casserait cette
// fonction partout, dans toutes les applications de la machine à la fois.
section("tâche 15 : l'aiguillage suit Cmd et protège les raccourcis", attendu: 16)

/// Fabrique une décision de keyDown, pour ne pas réécrire sept étiquettes à chaque
/// ligne. Les quatre modificateurs restent NOMMÉS à l'appel : c'est le sujet même de
/// cette section, les confondre reviendrait à ne plus rien mesurer.
func keyDownDecide(code: Int64, cmd: Bool = true, maj: Bool = false,
                   opt: Bool = false, ctrl: Bool = false,
                   etat: HotKeyState = .inactif) -> HotKeyDecision
{
    decider(type: .keyDown, commandEnfonce: cmd, majEnfonce: maj, optionEnfonce: opt,
            controlEnfonce: ctrl, estSynthetique: false, code: code, etat: etat)
}

/// Coller sans mise en forme, la fonction que ce changement pourrait casser partout.
let cmdMajV = keyDownDecide(code: 9, maj: true)
check("Cmd-Maj-V est relayé nativement, coller sans mise en forme continue de marcher",
      cmdMajV == .relayer, "obtenu \(cmdMajV), coller sans mise en forme serait avalé partout")
let cmdOptV = keyDownDecide(code: 9, opt: true)
check("Cmd-Opt-V est relayé nativement", cmdOptV == .relayer, "obtenu \(cmdOptV)")
let cmdCtrlV = keyDownDecide(code: 9, ctrl: true)
check("Cmd-Ctrl-V est relayé nativement", cmdCtrlV == .relayer, "obtenu \(cmdCtrlV)")

/// Moitié conforme, sans laquelle les trois précédentes ne mesurent rien : le MÊME V,
/// Cmd seul, doit bien arriver jusqu'à la machine. Un aiguillage qui relaierait tout
/// passerait les trois lignes ci-dessus et le produit n'ouvrirait plus jamais.
let cmdVNu = keyDownDecide(code: 9)
check("le même V, Cmd seul, est bien soumis à la machine",
      cmdVNu == .soumettre(.key(.v)), "obtenu \(cmdVNu), l'overlay ne s'ouvrirait plus jamais")

/// Composition : ce n'est pas seulement la décision qui compte, c'est que l'overlay
/// ne s'ouvre pas. Un garde-fou non branché est un garde-fou absent.
var machineMajV = HotKeyMachine(count: 5)
_ = machineMajV.recevoir(.modificateurDown)
let sortieMajV = entreeSoumise(cmdMajV).map { machineMajV.recevoir($0) }
check("Cmd-Maj-V ne dit rien à la machine", sortieMajV == nil,
      "obtenu \(String(describing: sortieMajV))")
check("Cmd-Maj-V n'ouvre pas l'overlay", machineMajV.etat == .arme,
      "état \(machineMajV.etat), le panneau s'ouvrirait sur un coller sans mise en forme")

/// LA VÉRIFICATION QUI ATTESTE QUE LE BUG EST CORRIGÉ, et le brief la donne
/// pour obligatoire. Ctrl-V doit redevenir entièrement libre : c'est le raccourci avec
/// lequel Claude Code colle une image, et Copyclipzer l'avalait au point qu'il a fallu
/// quitter l'application pour coller.
let ctrlV = keyDownDecide(code: 9, cmd: false, ctrl: true)
check("Ctrl-V est relayé et n'est plus jamais soumis à la machine",
      ctrlV == .relayer, "obtenu \(ctrlV), Claude Code ne pourrait toujours pas coller d'image")

/// « Dans aucun état » se mesure, il ne se déduit pas. On monte la machine dans les
/// trois états du geste et on lui fait traverser le même Ctrl-V : rien ne doit être
/// consommé nulle part. Le premier check atteste que les trois états ont VRAIMENT été
/// montés, sinon trois machines restées inactives passeraient le second sans rien dire.
var etatsMontes: [HotKeyState] = []
var consommationsDuCtrlV: [Bool] = []
for montage in 0 ... 2 {
    var machine = HotKeyMachine(count: 5)
    if montage >= 1 {
        _ = machine.recevoir(.modificateurDown)
    }
    if montage == 2 {
        _ = machine.recevoir(.key(.v))
    }
    etatsMontes.append(machine.etat)
    consommationsDuCtrlV.append(entreeSoumise(ctrlV).map { machine.recevoir($0).consomme } ?? false)
}

check("les trois états du geste ont bien été montés",
      etatsMontes == [.inactif, .arme, .ouvert], "obtenu \(etatsMontes)")
check("Ctrl-V n'est consommé dans AUCUN des trois états",
      consommationsDuCtrlV.allSatisfy { $0 == false }, "obtenu \(consommationsDuCtrlV)")

/// Les raccourcis du quotidien, maintenant que la machine s'arme à chaque Cmd. Trois
/// touches choisies parce qu'elles appartiennent AUSSI au geste ou à ses voisines :
/// Z est la bascule du texte brut, 1 est un rang de la liste, S ne l'est pas et sert
/// de témoin. Aucune ne doit être avalée tant que l'overlay n'est pas ouvert.
func consommeCmdArme(code: Int64) -> (consomme: Bool, etat: HotKeyState) {
    var machine = HotKeyMachine(count: 5)
    _ = machine.recevoir(.modificateurDown)
    let consomme = entreeSoumise(keyDownDecide(code: code)).map { machine.recevoir($0).consomme } ?? false
    return (consomme, machine.etat)
}

let cmdS = consommeCmdArme(code: 1)
check("Cmd armé sans overlay, Cmd-S enregistre normalement", !cmdS.consomme,
      "l'enregistrement serait avalé dans toutes les applications")
check("Cmd-S n'ouvre pas l'overlay non plus", cmdS.etat == .arme, "état \(cmdS.etat)")
let cmdZ = consommeCmdArme(code: 6)
check("Cmd armé sans overlay, Cmd-Z annule normalement", !cmdZ.consomme,
      "l'annulation serait avalée dans toutes les applications")
let cmd1 = consommeCmdArme(code: 18)
check("Cmd armé sans overlay, Cmd-1 change d'onglet normalement", !cmd1.consomme,
      "le premier onglet deviendrait inatteignable partout")

/// Moitié conforme du trio ci-dessus : overlay OUVERT, ces mêmes touches sont bien
/// avalées. Sans elle, une machine qui ne consommerait plus rien passerait les trois
/// lignes précédentes et le « 3 » se réécrirait dans le document.
var machineZOuverte = HotKeyMachine(count: 5)
_ = machineZOuverte.recevoir(.modificateurDown)
_ = machineZOuverte.recevoir(.key(.v))
let zOuvert = entreeSoumise(keyDownDecide(code: 6)).map { machineZOuverte.recevoir($0) }
check("overlay ouvert, en revanche, Z bascule le texte brut et est avalé",
      zOuvert?.0 == .basculerTexteBrut && zOuvert?.consomme == true,
      "obtenu \(String(describing: zOuvert))")

// Le branchement, sans lequel tout ce qui précède ne mesurerait qu'une fonction que
// personne n'appelle avec les bons drapeaux. `EventTap` importe CoreGraphics et n'est
// jamais symlinké ici : ce qui se mesure est donc le TEXTE du site d'appel, comme
// pour le panneau.
check("le tap suit la touche Commande comme modificateur du geste",
      sourceDuTap.contains("commandEnfonce: flags.contains(.maskCommand)"),
      "le geste s'armerait sur autre chose que Cmd, ou sur rien du tout")
check("le tap passe aussi Maj, Option et Contrôle à l'aiguillage",
      sourceDuTap.contains("majEnfonce: flags.contains(.maskShift)")
          && sourceDuTap.contains("optionEnfonce: flags.contains(.maskAlternate)")
          && sourceDuTap.contains("controlEnfonce: flags.contains(.maskControl)"),
      "l'aiguillage les verrait toujours à false, Cmd-Maj-V serait avalé malgré la règle")

// Le relais natif, côté colleur. `Paster` importe AppKit et CoreGraphics, il n'est
// jamais symlinké ici : symlinker un fichier graphique dans cette cible lui lie neuf
// bibliothèques (mesuré tâche 8, remesuré tâche 10). Ce qui se mesure est donc le
// TEXTE de la source, comme pour le tap et le panneau.
//
// Ce que ces lignes gardent : le relais natif ne doit RIEN faire du presse-papiers.
// C'est toute sa raison d'être. Une image ou une liste de fichiers qui ferait un
// aller-retour par notre base pourrait perdre des types, et le collage sortirait
// dégradé sans que rien ne l'annonce. Un `pb.clearContents()` glissé dans ce chemin
// annulerait la protection tout en gardant les tests de la machine au vert.
section("tâche 15 : le colleur sait reposer un Cmd-V natif", attendu: 5)

check("le colleur expose une repose de collage natif",
      sourceDuColleur.contains("static func reposerCollageNatif()"),
      "l'assemblage n'aurait rien à appeler sur .collerNatif, et un Cmd-V ordinaire ne collerait plus rien")
check("la repose native passe par la même synthèse de Cmd-V que le collage choisi",
      sourceDuColleur.contains("poserCmdV()"),
      "deux synthèses divergentes, dont une seule serait signée et mesurée")
check("la repose native renvoie son travail sur la boucle principale",
      sourceDuColleur.contains("DispatchQueue.main.async { poserCmdV() }"),
      "le callback du tap poserait l'événement en son sein et dépasserait son délai")

// La synthèse partagée doit rester signée des DEUX côtés, sinon notre propre Cmd-V
// repasse par la machine. Les deux vérifications de la tâche 12 mesurent déjà les
// lignes elles-mêmes, celle-ci mesure qu'elles ont bien suivi dans l'extraction.
check("la synthèse partagée pose toujours la signature et les drapeaux",
      sourceDuColleur.contains("private static func poserCmdV() {")
          && sourceDuColleur.contains("bas?.setIntegerValueField(.eventSourceUserData, value: signatureDuCollage)"),
      "l'extraction aurait laissé la signature derrière elle, l'overlay se rouvrirait sur son propre collage")

/// Le refus, et c'est la vérification qui porte la protection de fidélité. Le corps de
/// `reposerCollageNatif` ne doit contenir aucun contact avec `NSPasteboard`.
let debutDeLaRepose = sourceDuColleur.range(of: "static func reposerCollageNatif()")
let finDeLaRepose = sourceDuColleur.range(of: "private static func poserCmdV()")
if let debutDeLaRepose, let finDeLaRepose, debutDeLaRepose.upperBound <= finDeLaRepose.lowerBound {
    let corpsDeLaRepose = String(sourceDuColleur[debutDeLaRepose.upperBound ..< finDeLaRepose.lowerBound])
    check("la repose native ne touche jamais au presse-papiers",
          !corpsDeLaRepose.contains("NSPasteboard") && !corpsDeLaRepose.contains("pb."),
          "le collage cesserait d'être natif et une image pourrait perdre des types")
} else {
    echec("la repose native ne touche jamais au presse-papiers",
          "les deux fonctions ne se suivent plus dans le fichier, le corps n'est pas isolable")
}

// L'affichage différé, raffinement relevé à l'usage : sans lui, l'overlay
// clignoterait à CHAQUE Cmd-V ordinaire, c'est-à-dire des dizaines de fois par jour.
//
// L'ouverture logique reste immédiate, seul l'affichage attend. Si Cmd est relâché
// avant le délai, le panneau n'a jamais été montré et l'utilisateur ne voit strictement
// rien : son Cmd-V se comporte comme avant l'installation de Copyclipzer. Le délai ne
// retarde PAS le collage, qui part au relâchement dans tous les cas.
//
// La valeur vit dans un fichier pur, symlinké ici, et non en dur dans l'assemblage :
// posée dans `AppDelegate.swift`, elle serait le seul nombre de tout le geste à
// décider du confort d'usage sans qu'aucune vérification puisse le lire. Le reste,
// `NSPanel` et `DispatchQueue`, n'est pas mesurable ici et se lit donc en TEXTE.
section("tâche 15 : affichage différé et relais natif câblés", attendu: 9)

check("le délai avant affichage vaut les 150 ms du brief",
      delaiAvantAffichage == 0.15, "obtenu \(delaiAvantAffichage)")
check("le délai n'est pas nul",
      delaiAvantAffichage > 0,
      "l'overlay clignoterait à chaque Cmd-V, des dizaines de fois par jour")

let cheminDuDelegue = racineDuPaquet.appendingPathComponent("Sources/Copyclipzer/AppDelegate.swift")
let sourceDuDelegue = (try? String(contentsOf: cheminDuDelegue, encoding: .utf8)) ?? ""
check("la source de l'assemblage est lisible", !sourceDuDelegue.isEmpty,
      "rien lu dans \(cheminDuDelegue.path)")

check("l'assemblage prend le délai dans le fichier pur, et non en dur",
      sourceDuDelegue.contains("delaiAvantAffichage"),
      "la valeur serait posée en dur dans l'assemblage, hors de portée des tests")
check("l'affichage du panneau est bien différé, et non immédiat",
      sourceDuDelegue.contains("asyncAfter(deadline: .now() + delaiAvantAffichage)"),
      "le panneau s'afficherait aussitôt et clignoterait à chaque Cmd-V ordinaire")

// Un affichage différé sans annulation est pire que pas d'affichage différé : le
// panneau apparaîtrait APRÈS le collage, sur un geste déjà terminé, et resterait à
// l'écran. C'est le mode d'échec propre à tout report, il se garde explicitement.
check("l'affichage différé est annulable, par une génération de geste",
      sourceDuDelegue.contains("generationDuGeste += 1")
          && sourceDuDelegue.contains("self.generationDuGeste == generation"),
      "le panneau apparaîtrait après coup, sur un geste déjà refermé")

// Le branchement du relais natif. Un garde-fou non branché est un garde-fou absent :
// `.collerNatif` rendu par la machine et ignoré par l'assemblage, c'est un Cmd-V
// ordinaire qui ne colle plus rien du tout.
check("l'assemblage branche le collage natif sur la repose d'un Cmd-V",
      sourceDuDelegue.contains("case .collerNatif:")
          && sourceDuDelegue.contains("Paster.reposerCollageNatif()"),
      "un Cmd-V ordinaire serait avalé et ne collerait rien")
/// Mesurer la BRANCHE entière plutôt qu'une indentation exacte : un littéral
/// multiligne recopié depuis la source se casse au premier reformatage et ne mesure
/// alors plus que la mise en page. La branche va du `case` à celui qui le suit, sans
/// fenêtre de taille arbitraire qu'un commentaire ajouté ferait déborder.
let brancheDuCollageNatif: String = {
    guard let debut = sourceDuDelegue.range(of: "case .collerNatif:") else { return "" }
    let reste = sourceDuDelegue[debut.upperBound...]
    guard let fin = reste.range(of: "\n        case ") else { return String(reste) }
    return String(reste[..<fin.lowerBound])
}()

check("la branche du collage natif est isolable dans l'assemblage",
      !brancheDuCollageNatif.isEmpty && brancheDuCollageNatif.count < 900,
      "obtenu \(brancheDuCollageNatif.count) caractères, le `case .collerNatif:` a disparu ou la branche déborde")
check("le collage natif referme aussi le panneau, et périme le report",
      brancheDuCollageNatif.contains("fermerLePanneau()")
          && sourceDuDelegue.contains("private func fermerLePanneau() {\n        generationDuGeste += 1\n        overlay.masquer()"),
      "le panneau resterait à l'écran après un collage natif, ou réapparaîtrait après coup")

// Arbitrage du 2026-08-26, premier des deux. Le brief de la tâche 15 exigeait la
// capture inconditionnelle de Cmd-C et Cmd-X, et testait X comme touche d'épinglage.
// Appliqués tels quels, les deux se contredisent : X pendant que l'overlay est ouvert
// épingle ET coupe la sélection dans l'application de dessous, sans que rien ne le
// signale. Tranché : la capture ne vaut que dans `.inactif` et `.arme`. Ouvert, les
// touches appartiennent au geste, la machine les avale, et Cmd-X n'atteint jamais
// l'application. C'est déjà la règle de `.other`, ce cas ne fait que la rejoindre.
section("tâche 15 · arbitrage : la capture s'efface quand l'overlay est ouvert", attendu: 12)

/// Moitié conforme, dans les deux états où l'overlay est fermé. Sans elle, un
/// aiguillage qui ne capturerait plus JAMAIS rien passerait la moitié de refus
/// ci-dessous sans rien dire, et l'historique cesserait de se remplir.
let cmdCInactif = keyDownDecide(code: 8, etat: .inactif)
check("overlay fermé, au repos, Cmd-C déclenche la capture et laisse filer",
      cmdCInactif == .capturerPuisRelayer,
      "obtenu \(cmdCInactif), une copie ne rentrerait plus dans l'historique")
let cmdCArme = keyDownDecide(code: 8, etat: .arme)
check("overlay fermé, Cmd déjà enfoncé, Cmd-C déclenche la capture et laisse filer",
      cmdCArme == .capturerPuisRelayer,
      "obtenu \(cmdCArme), c'est pourtant l'état réel d'un Cmd-C, Cmd est enfoncé")
check("overlay fermé, Cmd-C n'est soumis à personne, donc rien ne peut l'avaler",
      entreeSoumise(cmdCArme) == nil,
      "la machine pourrait demander de consommer la copie de toutes les applications")

let cmdXInactif = keyDownDecide(code: 7, etat: .inactif)
check("overlay fermé, au repos, Cmd-X déclenche la capture et laisse filer",
      cmdXInactif == .capturerPuisRelayer,
      "obtenu \(cmdXInactif), une coupe ne rentrerait plus dans l'historique")
let cmdXArme = keyDownDecide(code: 7, etat: .arme)
check("overlay fermé, Cmd déjà enfoncé, Cmd-X déclenche la capture et laisse filer",
      cmdXArme == .capturerPuisRelayer,
      "obtenu \(cmdXArme), c'est pourtant l'état réel d'un Cmd-X, Cmd est enfoncé")
check("overlay fermé, Cmd-X n'est soumis à personne, donc rien ne peut l'avaler",
      entreeSoumise(cmdXArme) == nil,
      "la machine pourrait demander de consommer la coupe de toutes les applications")

/// LA vérification de l'arbitrage. Overlay ouvert, X appartient au geste : aucune
/// capture ne part, donc aucune coupe ne se produit dans l'application de dessous.
let xOuvert = keyDownDecide(code: 7, etat: .ouvert)
check("overlay ouvert, X ne déclenche AUCUNE capture",
      xOuvert != .capturerPuisRelayer,
      "obtenu \(xOuvert), l'épinglage couperait aussi la sélection du document de dessous")

var machineXOuverte = HotKeyMachine(count: 5)
_ = machineXOuverte.recevoir(.modificateurDown)
_ = machineXOuverte.recevoir(.key(.v))
let sortieXOuvert = entreeSoumise(xOuvert).map { machineXOuverte.recevoir($0) }
check("overlay ouvert, X épingle et est AVALÉE, donc Cmd-X n'atteint pas l'application",
      sortieXOuvert?.0 == .basculerEpingle && sortieXOuvert?.consomme == true,
      "obtenu \(String(describing: sortieXOuvert)) pour la décision \(xOuvert)")

/// Le pendant pour C, qui n'a aucun sens dans le geste : elle doit malgré tout être
/// avalée, sinon un Cmd-C partirait vers l'application pendant que l'overlay est
/// ouvert et remplacerait le presse-papiers au milieu du geste.
let cOuvert = keyDownDecide(code: 8, etat: .ouvert)
check("overlay ouvert, C ne déclenche AUCUNE capture",
      cOuvert != .capturerPuisRelayer,
      "obtenu \(cOuvert), le presse-papiers changerait au milieu du geste")

var machineCOuverte = HotKeyMachine(count: 5)
_ = machineCOuverte.recevoir(.modificateurDown)
_ = machineCOuverte.recevoir(.key(.v))
let sortieCOuvert = entreeSoumise(cOuvert).map { machineCOuverte.recevoir($0) }
check("overlay ouvert, C est AVALÉE sans rien faire",
      sortieCOuvert?.0 == .rien && sortieCOuvert?.consomme == true,
      "obtenu \(String(describing: sortieCOuvert)) pour la décision \(cOuvert)")

// Le branchement. Un garde-fou non branché est un garde-fou absent : un `decider`
// qui recevrait un état figé rendrait la règle inopérante sans qu'un seul des dix
// checks ci-dessus ne bouge. `EventTap` et `AppDelegate` importent CoreGraphics et
// AppKit, ils ne sont jamais symlinkés ici : ce qui se mesure est le TEXTE.
check("le tap relit l'état du geste et le passe à l'aiguillage",
      sourceDuTap.contains("etat: etatDuGeste()"),
      "l'aiguillage déciderait sur un état figé, et Cmd-X couperait pendant l'épinglage")
check("l'assemblage donne au tap l'état VIVANT de sa machine",
      sourceDuDelegue.contains("etatDuGeste: { [weak self] in self?.machine.etat ?? .inactif }"),
      "le tap lirait un état mort ou une copie, et la règle ne verrait jamais l'overlay ouvert")

// Arbitrage du 2026-08-26, second des deux. Le compte était relu à chaque
// `.modificateurDown`, ce qui allait de soi tant que le geste s'armait sur Ctrl. Le
// geste s'arme sur Cmd depuis la tâche 15 : ce chemin est devenu une requête SQLite
// à chaque Cmd-C, Cmd-S, Cmd-Tab, Cmd-Q, pour une valeur dont aucun de ces raccourcis
// ne fait quoi que ce soit. Tranché : une lecture au V qui ouvre, et à lui seul.
//
// Ce qui ne doit PAS bouger en échange, et c'est la garantie de la tâche 9 : la
// machine borne toujours sur un compte à jour, et n'ouvre jamais sur un historique
// vide. Les deux se remesurent ici, sur le nouveau moment de lecture.
section("tâche 15 · arbitrage : le compte ne se relit qu'au V qui ouvre", attendu: 12)

check("armé, le V qui va ouvrir relit le compte",
      doitRelireLeCompte(etat: .arme, input: .key(.v)),
      "l'overlay s'ouvrirait sur le compte du geste précédent, ou sur zéro la première fois")

// Les quatre refus. Le premier est le chemin RETIRÉ, et c'est lui qui porte
// l'arbitrage : sans lui, remettre la lecture sur chaque appui sur Cmd repasserait
// au vert. Les trois autres bornent la règle par le haut.
check("un appui sur Cmd ne relit plus l'historique",
      !doitRelireLeCompte(etat: .inactif, input: .modificateurDown),
      "chaque Cmd-C, Cmd-S et Cmd-Tab de la journée déclencherait une requête SQLite")
check("armé, une touche qui n'ouvre pas ne relit rien",
      !doitRelireLeCompte(etat: .arme, input: .key(.z)),
      "Cmd-Z déclencherait une requête pour une valeur dont il ne fait rien")
check("overlay ouvert, le V de navigation ne relit rien",
      !doitRelireLeCompte(etat: .ouvert, input: .key(.v)),
      "chaque cran de navigation relirait la base, et le bornage bougerait en cours de geste")
check("au repos, un V ne relit rien non plus",
      !doitRelireLeCompte(etat: .inactif, input: .key(.v)),
      "un V sans Cmd, qui ne peut rien ouvrir, déclencherait quand même une requête")

/// Rejoue le pilotage de l'assemblage, avec la MÊME règle et le même ordre : relire
/// si la règle le dit, puis soumettre. `compte` est l'historique tel que la base le
/// rendrait, et il est appelé une fois par lecture, ce qui permet de les compter.
func rejouer(_ entrees: [HotKeyInput],
             compte: () -> Int) -> (machine: HotKeyMachine, sorties: [HotKeyOutput])
{
    var machine = HotKeyMachine(count: 0)
    var sorties: [HotKeyOutput] = []
    for entree in entrees {
        if doitRelireLeCompte(etat: machine.etat, input: entree) {
            machine.count = compte()
        }
        sorties.append(machine.recevoir(entree).0)
    }
    return (machine, sorties)
}

/// Le sens qui mesure l'économie : un Cmd tenu pour autre chose ne touche pas la base.
var lecturesSansV = 0
_ = rejouer([.modificateurDown, .key(.z), .key(.other), .modificateurUp]) {
    lecturesSansV += 1
    return 5
}

check("un Cmd tenu sans V ne fait AUCUNE lecture de l'historique", lecturesSansV == 0,
      "obtenu \(lecturesSansV) lecture(s), c'est le coût que l'arbitrage supprime")

/// Deux gestes de suite, sur un historique qui passe de vide à peuplé. Une seule
/// fonction mesure trois choses : le nombre de lectures, le refus d'ouvrir sur du
/// vide, et le fait que la seconde ouverture voit bien la NOUVELLE valeur.
var lecturesDeuxGestes = 0
let historique = [0, 3]
let deuxGestes = rejouer([
    .modificateurDown, .key(.v), .modificateurUp,
    .modificateurDown, .key(.v),
]) {
    defer { lecturesDeuxGestes += 1 }
    return historique[min(lecturesDeuxGestes, historique.count - 1)]
}

check("un geste réel fait EXACTEMENT une lecture, pas plus", lecturesDeuxGestes == 2,
      "obtenu \(lecturesDeuxGestes) lecture(s) pour deux gestes")
check("l'overlay refuse toujours de s'ouvrir sur un historique vide",
      deuxGestes.sorties[1] == .rien,
      "obtenu \(deuxGestes.sorties[1]), un panneau vide s'ouvrirait au premier Cmd-V")
check("le geste suivant ouvre sur l'historique RELU, et non sur le compte périmé",
      deuxGestes.sorties[4] == .ouvrir && deuxGestes.machine.etat == .ouvert,
      "obtenu \(deuxGestes.sorties[4]) et l'état \(deuxGestes.machine.etat)")

/// La seconde moitié de la garantie de la tâche 9 : le bornage porte sur le compte
/// relu. Cinq flèches bas sur deux entrées doivent s'arrêter au rang 1.
let bornage = rejouer([.modificateurDown, .key(.v),
                       .key(.down), .key(.down), .key(.down), .key(.down), .key(.down)]) { 2 }
check("la navigation borne toujours sur le compte relu", bornage.machine.index == 1,
      "obtenu l'index \(bornage.machine.index) pour 2 entrées en base")

// Le branchement, et son refus. La première ligne atteste que l'assemblage passe bien
// par la règle pure, la seconde que l'ancien chemin par `.modificateurDown` a
// VRAIMENT disparu : gardé à côté, il annulerait l'arbitrage tout en laissant les
// onze vérifications ci-dessus au vert.
check("l'assemblage relit le compte en suivant la règle pure",
      sourceDuDelegue.contains("if doitRelireLeCompte(etat: machine.etat, input: input) {")
          && sourceDuDelegue.contains("machine.count = (try? store.recent(limit: 9).count) ?? 0"),
      "la règle du QUAND vivrait dans le seul fichier que les tests ne peuvent pas atteindre")
check("l'assemblage ne relit plus le compte à chaque appui sur Cmd",
      !sourceDuDelegue.contains("if case .modificateurDown = input {"),
      "l'ancien chemin serait resté, une requête SQLite par appui sur Cmd avec lui")

// ---------------------------------------------------------------------------
// Tâche 16 : le menu de barre devient un historique cherchable.
//
// Ce qui se mesure ici est la RÈGLE, sortie dans `Sources/Overlay/MenuFormat.swift`
// et symlinkée dans cette cible : quelles entrées apparaissent, dans quel ordre,
// jusqu'où, et avec quel libellé.
//
// Trois choses restent hors de portée d'un test et partent en vérification manuelle,
// sans qu'aucun test creux ne soit écrit à leur place : le rendu réel du `NSMenu`, le
// focus du champ de recherche à l'ouverture, et le fait qu'un clic écrive vraiment
// dans `NSPasteboard`.
section("tâche 16 : les lignes du menu de barre", attendu: 20)

/// Fabrique locale. Les seules variables qui comptent ici sont la date, l'épinglage
/// et le type : le reste est du remplissage, et `ClipItem.text` ne sait pas poser un
/// autre `kind` que `.text`.
func entreeDeMenu(_ texte: String, at: Double, epinglee: Bool = false,
                  kind: ClipKind = .text) -> ClipItem
{
    ClipItem(id: "id-\(texte)-\(at)", createdAt: at, modifiedAt: at, deviceID: "test",
             kind: kind, title: texte, searchText: texte, contentHash: "h-\(texte)-\(at)",
             byteSize: texte.utf8.count, sourceBundleID: nil, pinned: epinglee,
             isRemote: false)
}

let menuVide = elementsDuMenu(entrees: [], recherche: "")
check("une liste vide ne rend aucune ligne", menuVide.isEmpty,
      "obtenu \(menuVide.count) ligne(s)")

/// Le sens conforme, et il n'est pas décoratif : sans lui, un `elementsDuMenu` qui
/// rendrait TOUJOURS une liste vide passerait la vérification ci-dessus sans un mot,
/// et le menu serait vide en permanence.
let troisEntrees = [entreeDeMenu("un", at: 3), entreeDeMenu("deux", at: 2),
                    entreeDeMenu("trois", at: 1)]
let menuDeTrois = elementsDuMenu(entrees: troisEntrees, recherche: "")
check("trois entrées rendent exactement trois lignes", menuDeTrois.count == 3,
      "obtenu \(menuDeTrois.count) ligne(s)")

/// Le plafond, dans ses deux sens. Seul, le cas des 600 serait passé par une fonction
/// qui ne rendrait jamais plus de dix lignes ; seul, le cas des 400 serait passé par
/// une fonction sans aucun plafond.
let sixCentsEntrees = (0 ..< 600).map { entreeDeMenu("e\($0)", at: Double($0)) }
let menuPlafonne = elementsDuMenu(entrees: sixCentsEntrees, recherche: "")
check("600 entrées sont plafonnées à 500 lignes", menuPlafonne.count == plafondDuMenu,
      "obtenu \(menuPlafonne.count) ligne(s) pour un plafond de \(plafondDuMenu)")

let quatreCentsEntrees = (0 ..< 400).map { entreeDeMenu("e\($0)", at: Double($0)) }
let menuSousLePlafond = elementsDuMenu(entrees: quatreCentsEntrees, recherche: "")
check("400 entrées rendent 400 lignes, le plafond ne coupe pas ce qui tient",
      menuSousLePlafond.count == 400,
      "obtenu \(menuSousLePlafond.count) ligne(s)")

/// L'épinglée est la PLUS ANCIENNE des trois. C'est le seul agencement où le tri par
/// date et le tri par épinglage ne disent pas la même chose, donc le seul qui mesure
/// quelque chose : avec une épinglée déjà récente, un tri par date seul passerait.
let avecEpinglee = [entreeDeMenu("recent", at: 30),
                    entreeDeMenu("moyen", at: 20),
                    entreeDeMenu("ancien mais epingle", at: 10, epinglee: true)]
let menuEpingle = elementsDuMenu(entrees: avecEpinglee, recherche: "")
check("une entrée épinglée passe devant une entrée plus récente",
      menuEpingle.first?.titre == "ancien mais epingle",
      "obtenu « \(menuEpingle.first?.titre ?? "rien") » en tête")
check("derrière l'épinglée, les autres restent triées par date",
      menuEpingle.dropFirst().map(\.titre) == ["recent", "moyen"],
      "obtenu \(menuEpingle.dropFirst().map(\.titre))")

/// L'autre sens du même couple : sans aucune épinglée, l'ordre par date est
/// exactement celui qu'on attend. Un tri qui renverserait tout tomberait ici et pas
/// au-dessus, et c'est ce qui distingue « les épinglées passent devant » de « l'ordre
/// est n'importe lequel ».
let sansEpinglee = [entreeDeMenu("vieux", at: 10), entreeDeMenu("neuf", at: 30),
                    entreeDeMenu("median", at: 20)]
let menuSansEpingle = elementsDuMenu(entrees: sansEpinglee, recherche: "")
check("sans aucune épinglée, l'ordre par date décroissante est conservé",
      menuSansEpingle.map(\.titre) == ["neuf", "median", "vieux"],
      "obtenu \(menuSansEpingle.map(\.titre))")

/// Entre deux épinglées, la date tranche encore. Sinon l'épinglage serait un tri qui
/// écrase le second critère au lieu de passer devant lui.
let deuxEpinglees = [entreeDeMenu("epingle ancien", at: 5, epinglee: true),
                     entreeDeMenu("epingle recent", at: 25, epinglee: true),
                     entreeDeMenu("libre", at: 40)]
let menuDeuxEpinglees = elementsDuMenu(entrees: deuxEpinglees, recherche: "")
check("entre deux épinglées, la plus récente passe devant",
      menuDeuxEpinglees.map(\.titre) == ["epingle recent", "epingle ancien", "libre"],
      "obtenu \(menuDeuxEpinglees.map(\.titre))")

/// Le filtrage, dans ses deux sens. `Store.search` filtre déjà en SQL, mais le menu
/// se reconstruit à chaque frappe et la règle d'affichage doit tenir seule : une
/// entrée qui ne correspond pas ne doit jamais atteindre l'écran, quel que soit ce
/// que la base a rendu.
let aFiltrer = [entreeDeMenu("facture Orange", at: 30),
                entreeDeMenu("mot de passe wifi", at: 20),
                entreeDeMenu("facture EDF", at: 10)]
let menuFiltre = elementsDuMenu(entrees: aFiltrer, recherche: "facture")
check("une recherche non vide filtre la liste",
      menuFiltre.map(\.titre) == ["facture Orange", "facture EDF"],
      "obtenu \(menuFiltre.map(\.titre))")

/// Le sens conforme. Sans lui, un filtre qui ne laisserait JAMAIS rien passer serait
/// vert au-dessus dès qu'on relâcherait l'égalité, et le menu serait vide.
let menuNonFiltre = elementsDuMenu(entrees: aFiltrer, recherche: "")
check("une recherche vide ne filtre rien", menuNonFiltre.count == 3,
      "obtenu \(menuNonFiltre.count) ligne(s) pour 3 entrées")

let menuEspaces = elementsDuMenu(entrees: aFiltrer, recherche: "   ")
check("une recherche faite d'espaces ne filtre rien non plus", menuEspaces.count == 3,
      "obtenu \(menuEspaces.count) ligne(s), un espace resté dans le champ viderait le menu")

let menuCasse = elementsDuMenu(entrees: aFiltrer, recherche: "FACTURE")
check("la recherche ignore la casse", menuCasse.count == 2,
      "obtenu \(menuCasse.count) ligne(s), chercher « URL » ne trouverait pas « url »")

/// Réutilisation de `titreAffiche`, déjà mesurée à la tâche 11 : la règle du titre sur
/// une seule ligne ne se réimplémente pas ici, elle se rebranche.
let entreeMultiligne = entreeDeMenu("première ligne\nseconde ligne", at: 1)
let menuMultiligne = elementsDuMenu(entrees: [entreeMultiligne], recherche: "")
check("le titre affiché d'une entrée multiligne tient sur une seule ligne",
      menuMultiligne.first?.titre == "première ligne seconde ligne",
      "obtenu « \(menuMultiligne.first?.titre ?? "rien") »")
check("le titre affiché ne contient plus aucune fin de ligne",
      menuMultiligne.first.map { !$0.titre.contains("\n") } == true,
      "une ligne de menu sur deux lignes en rognerait une des deux")

let entreeTresLongue = entreeDeMenu(String(repeating: "z", count: plafondDuTitreAffiche + 50), at: 1)
let menuTresLong = elementsDuMenu(entrees: [entreeTresLongue], recherche: "")
check("un titre plus long que le plafond ressort coupé avec une ellipse",
      menuTresLong.first?.titre.count == plafondDuTitreAffiche + 1
          && menuTresLong.first?.titre.hasSuffix("…") == true,
      "obtenu \(menuTresLong.first?.titre.count ?? -1) caractères pour un plafond de \(plafondDuTitreAffiche)")

/// L'icône vient de `icone(_:)`, testée elle aussi à la tâche 11. Deux types
/// différents, deux icônes différentes : une ligne qui porterait toujours la même
/// icône tombe ici.
let deuxTypes = [entreeDeMenu("une image", at: 20, kind: .image),
                 entreeDeMenu("du texte", at: 10, kind: .text)]
let menuDeuxTypes = elementsDuMenu(entrees: deuxTypes, recherche: "")
check("l'icône d'une ligne vient de la règle déjà testée",
      menuDeuxTypes.map(\.icone) == ["photo", "textformat.abc"],
      "obtenu \(menuDeuxTypes.map(\.icone))")

check("la première ligne porte le rang 1, et non le rang 0",
      menuDeuxTypes.first?.rang == 1,
      "obtenu le rang \(menuDeuxTypes.first?.rang ?? -1)")
check("le libellé d'une ligne montre son rang devant son titre",
      menuDeuxTypes.first?.libelle == "1. une image",
      "obtenu « \(menuDeuxTypes.first?.libelle ?? "rien") »")

/// Le raccourci de rang, et son refus au-delà de la neuvième ligne. Les deux sens
/// comptent : un raccourci rendu pour tout le monde poserait un « Cmd-10 » qui
/// n'existe pas, et un raccourci rendu pour personne retirerait le seul moyen de
/// choisir une entrée sans la souris. La ligne de refus vérifie AUSSI le compte, sinon
/// une liste vide la rendrait vraie par vacuité.
let douzeEntrees = (0 ..< 12).map { entreeDeMenu("e\($0)", at: Double(12 - $0)) }
let menuDouze = elementsDuMenu(entrees: douzeEntrees, recherche: "")
check("les neuf premières lignes portent un raccourci de rang",
      menuDouze.prefix(lignesAvecRaccourci).map(\.raccourci)
          == ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
      "obtenu \(menuDouze.prefix(lignesAvecRaccourci).map(\.raccourci))")
check("la dixième ligne et les suivantes n'en portent aucun",
      menuDouze.count == 12
          && menuDouze.dropFirst(lignesAvecRaccourci).allSatisfy { $0.raccourci.isEmpty },
      "obtenu \(menuDouze.count) ligne(s) et \(menuDouze.dropFirst(lignesAvecRaccourci).map(\.raccourci))")

section("Panneau · sélection par chiffre", attendu: 6)

// La touche de chiffre du panneau désigne la Nième ligne VISIBLE. Le Cmd+chiffre est
// intercepté par AppKit, donc non mesurable ; ce qu'il décide, « ce chiffre vise quel
// index », est pur et se mesure ici.
check("le chiffre 1 désigne la première ligne",
      indexPourTouche("1", nombreDeLignes: 5) == 0,
      "obtenu \(String(describing: indexPourTouche("1", nombreDeLignes: 5)))")
check("le chiffre 3 désigne la troisième ligne",
      indexPourTouche("3", nombreDeLignes: 5) == 2,
      "obtenu \(String(describing: indexPourTouche("3", nombreDeLignes: 5)))")

// Les refus, chacun pour une raison différente : « 0 » n'est pas un rang, « 3 » sur
// deux lignes viserait une ligne qui n'existe pas, et le reste n'est pas un chiffre.
check("le chiffre 0 ne désigne aucune ligne",
      indexPourTouche("0", nombreDeLignes: 5) == nil)
check("un chiffre au-delà du nombre de lignes ne désigne rien",
      indexPourTouche("3", nombreDeLignes: 2) == nil,
      "obtenu \(String(describing: indexPourTouche("3", nombreDeLignes: 2)))")
check("une touche qui n'est pas un chiffre ne désigne rien",
      indexPourTouche("a", nombreDeLignes: 5) == nil)
check("une touche vide ne désigne rien",
      indexPourTouche("", nombreDeLignes: 5) == nil)

// Le câblage du menu, lu en TEXTE. `AppDelegate` et `Paster` importent AppKit, ils ne
// sont jamais symlinkés ici : symlinker un fichier graphique dans cette cible lui lie
// neuf bibliothèques (mesuré tâche 8, remesuré tâche 10). Ce qui se mesure dans cette
// section est donc qu'une règle pure est BRANCHÉE, jamais ce qu'elle produit à
// l'écran. Un garde-fou non branché est un garde-fou absent.
section("tâche 16 : câblage du panneau de recherche", attendu: 12)

/// La branche entière plutôt qu'une indentation exacte, même patron qu'à la tâche 15 :
/// un littéral multiligne recopié depuis la source se casse au premier reformatage et
/// ne mesure alors plus que la mise en page. Partagée par toutes les sections qui lisent
/// `AppDelegate` en texte.
func corpsDeMethode(_ source: String, apres entete: String) -> String {
    guard let debut = source.range(of: entete) else { return "" }
    let reste = source[debut.upperBound...]
    guard let fin = reste.range(of: "\n    }") else { return String(reste) }
    return String(reste[..<fin.lowerBound])
}

/// Les sources des deux fichiers du panneau, lues en TEXTE : ni le panneau ni la vue ne
/// sont symlinkés ici (ils importent SwiftUI), donc ce qui se mesure est le BRANCHEMENT,
/// pas le dessin.
let sourceDeLaRecherche = (try? String(contentsOf: racineDuPaquet
        .appendingPathComponent("Sources/Overlay/RechercheView.swift"), encoding: .utf8)) ?? ""
let sourceDuPanneauRecherche = (try? String(contentsOf: racineDuPaquet
        .appendingPathComponent("Sources/Overlay/RecherchePanel.swift"), encoding: .utf8)) ?? ""
check("les sources du panneau sont lisibles",
      !sourceDeLaRecherche.isEmpty && !sourceDuPanneauRecherche.isEmpty,
      "rien lu dans RechercheView.swift ou RecherchePanel.swift")

let corpsDeFiltrer = corpsDeMethode(sourceDuDelegue, apres: "private func filtrer(_ requete: String) {")
check("le corps de filtrer est isolable dans l'assemblage",
      !corpsDeFiltrer.isEmpty && corpsDeFiltrer.count < 600,
      "obtenu \(corpsDeFiltrer.count) caractères, la méthode a disparu ou son corps déborde")

// L'ordre, le plafond et le filtrage viennent de la règle pure, pas d'un tri écrit sur
// place dans le seul fichier hors de portée des tests.
check("le panneau prend ses lignes dans la règle pure",
      corpsDeFiltrer.contains("elementsDuMenu(entrees: entrees, recherche: requete)"),
      "l'ordre et le filtrage seraient revenus dans l'assemblage")
check("le panneau demande le plafond du fichier pur, et non un nombre écrit en dur",
      corpsDeFiltrer.contains("store.search(requete, limit: plafondDuMenu)") && plafondDuMenu == 500,
      "obtenu un plafond de \(plafondDuMenu), la valeur vivrait dans l'assemblage")

// Le clic sur l'icône de barre ouvre le panneau ; c'est la seule surface permanente.
check("le clic sur l'icône bascule le panneau de recherche",
      sourceDuDelegue.contains("recherchePanel.basculer()"),
      "l'icône n'ouvrirait plus rien")
check("le menu de secours garde une ligne Quitter",
      sourceDuDelegue.contains("l10n(\"menu.quitter\")")
          && sourceDuDelegue.contains("NSApplication.terminate(_:)"),
      "LSUIElement retire l'icône du Dock, sans cette ligne l'application ne se quitte plus")

// La saisie filtre à chaque frappe, sans qu'il faille appuyer sur Entrée. Vit désormais
// dans le champ du panneau, pas dans l'assemblage.
check("le champ de recherche filtre à chaque frappe",
      sourceDeLaRecherche.contains("func controlTextDidChange(")
          && sourceDeLaRecherche.contains("parent.surChangement(champ.stringValue)"),
      "il faudrait appuyer sur Entrée pour filtrer, ce qui n'est pas ce qui a été demandé")
check("les flèches et Entrée pilotent la liste depuis le champ",
      sourceDeLaRecherche.contains("#selector(NSResponder.moveDown(_:))")
          && sourceDeLaRecherche.contains("#selector(NSResponder.insertNewline(_:))"),
      "la sélection ne bougerait pas au clavier")

// LE correctif du bug de focus : le panneau peut devenir clé, donc le champ garde le
// focus d'une frappe à l'autre. C'est ce que le NSMenu ne permettait pas.
check("le panneau de recherche peut devenir clé",
      sourceDuPanneauRecherche.replacingOccurrences(of: " ", with: "")
          .replacingOccurrences(of: "\n", with: "")
          .contains("overridevarcanBecomeKey:Bool{true"),
      "le champ perdrait le focus, et le bug d'origine reviendrait")
check("ouvrir le panneau lui donne le focus du champ",
      sourceDuPanneauRecherche.contains("makeFirstResponder"),
      "il faudrait cliquer dans la barre avant de pouvoir taper")

// Le collage reste inchangé : il masque son écriture à la capture, par la fonction
// partagée. Le chemin copie-sans-coller du menu a disparu avec le menu.
check("le collage masque toujours son écriture à la capture",
      sourceDuColleur.contains("capture.ignorerJusqua(apresEcriture)"),
      "chaque collage en texte brut ajouterait de nouveau un doublon à l'historique")
check("le collage écrit par la fonction partagée",
      sourceDuColleur.contains("ecrireDansLePressePapiers(item, texteBrut: texteBrut)"),
      "l'écriture divergerait du reste du collage")

section("tâche 18 : l'aperçu au survol et le titre de secours", attendu: 12)
do {
    func entree(kind: ClipKind = .text, titre: String, texte: String,
                taille: Int = 0, source: String? = nil, at: Double = 1_756_600_000) -> ClipItem
    {
        ClipItem(id: "id-\(titre.hashValue)", createdAt: at, modifiedAt: at, deviceID: "m",
                 kind: kind, title: titre, searchText: texte, contentHash: "h\(titre.hashValue)",
                 byteSize: taille == 0 ? texte.utf8.count : taille,
                 sourceBundleID: source, pinned: false, isRemote: false)
    }

    // --- le corps vient de searchText, pas du titre ---
    // La raison d'être de toute la fonction. Si l'aperçu partait de `title`, il
    // montrerait exactement ce que la ligne montre déjà, et ne servirait à rien.
    let longTexte = String(repeating: "a", count: 400) + "FIN-DU-TEXTE"
    let tronquee = entree(titre: String(longTexte.prefix(200)), texte: longTexte)
    check("l'aperçu montre ce que le titre a coupé",
          apercuDeLaLigne(tronquee).contains("FIN-DU-TEXTE"))

    // --- les deux plafonds ---
    let enorme = entree(titre: "log", texte: String(repeating: "b", count: 5000))
    check("un texte plus long que le plafond de caractères est coupé, avec ellipse",
          corpsDeLApercu(enorme).count == plafondDeCaracteresDeLApercu + 1
              && corpsDeLApercu(enorme).hasSuffix("…"),
          "obtenu \(corpsDeLApercu(enorme).count) caractères")

    // Le cas conforme du précédent : sans lui, une coupe systématique à zéro
    // caractère passerait la vérification ci-dessus sans que rien ne le dise.
    let court = entree(titre: "court", texte: "trois mots ici")
    check("un texte plus court que le plafond ressort intact, sans ellipse",
          corpsDeLApercu(court) == "trois mots ici")

    let hautain = entree(titre: "many", texte: (1 ... 200).map { "ligne \($0)" }
        .joined(separator: "\n"))
    check("un texte de deux cents lignes est ramené au plafond de lignes",
          corpsDeLApercu(hautain).components(separatedBy: "\n").count
              == plafondDeLignesDeLApercu,
          "obtenu \(corpsDeLApercu(hautain).components(separatedBy: "\n").count) lignes")

    // --- le titre de secours ---
    // Une image copiée n'a aucun texte, donc aucun titre. Sans repli, sa ligne de
    // menu est vide et son aperçu aussi : le défaut est visible à l'écran.
    let image = entree(kind: .image, titre: "", texte: "", taille: 348)
    check("une entrée image sans texte reçoit un titre de secours",
          titreOuSecours(image) == "Image · 348 o",
          "obtenu « \(titreOuSecours(image)) »")
    check("l'aperçu d'une entrée sans texte retombe lui aussi sur le secours",
          corpsDeLApercu(image) == "Image · 348 o",
          "obtenu « \(corpsDeLApercu(image)) »")

    // Le sens conforme : le repli ne doit s'appliquer QU'au titre vide, sinon il
    // écraserait le titre de toutes les entrées texte.
    let nommee = entree(titre: "bonjour", texte: "bonjour")
    check("une entrée qui a un titre garde le sien",
          titreOuSecours(nommee) == "bonjour")

    // Un titre fait d'espaces est aussi illisible qu'un titre absent.
    let blanche = entree(kind: .files, titre: "   \n  ", texte: "", taille: 2048)
    check("un titre fait uniquement d'espaces bascule sur le secours",
          titreOuSecours(blanche) == "Fichiers · 2 Ko",
          "obtenu « \(titreOuSecours(blanche)) »")

    // --- le pied ---
    let sourcee = entree(titre: "copié", texte: "copié", taille: 1_500_000,
                         source: "com.apple.Safari")
    let pied = piedDeLApercu(sourcee)
    check("le pied porte le type, la taille et la date",
          pied.contains("Texte") && pied.contains("1.4 Mo") && pied.contains("/"),
          "obtenu « \(pied) »")
    check("le pied porte l'application source quand elle est connue",
          pied.contains("com.apple.Safari"))

    // Une source concaténée avec son séparateur laisserait un « · » orphelin.
    let sansSource = piedDeLApercu(entree(titre: "anonyme", texte: "anonyme"))
    check("le pied ne laisse aucun séparateur orphelin sans application source",
          !sansSource.hasSuffix("·") && !sansSource.contains("· ·"),
          "obtenu « \(sansSource) »")

    // --- le câblage vers la ligne de menu ---
    // Une règle non branchée est une règle absente : `apercuDeLaLigne` testée mais
    // jamais posée sur la ligne laisserait le panneau vide sans qu'un test bouge.
    let ligne = elementsDuMenu(entrees: [tronquee], recherche: "").first
    check("la ligne du menu porte l'aperçu de son entrée",
          ligne?.apercu == apercuDeLaLigne(tronquee))
}

section("tâche 19 : câblage des actions du panneau", attendu: 12)
do {
    let corpsDuBranchement = corpsDeMethode(
        sourceDuDelegue, apres: "private func brancherLePanneauDeRecherche() {"
    )
    check("le corps du branchement du panneau est isolable dans l'assemblage",
          !corpsDuBranchement.isEmpty && corpsDuBranchement.count < 3000,
          "obtenu \(corpsDuBranchement.count) caractères")

    // Les actions d'une ligne atteignent bien le store.
    check("valider une entrée la COLLE dans l'application précédente",
          corpsDuBranchement.contains("recherchePanel.collerDans")
              && corpsDuBranchement.contains("paster.coller(entree, texteBrut: texteBrut)"),
          "valider ne collerait rien, ou passerait par un chemin non mesuré")
    check("épingler bascule l'épinglage en base",
          corpsDuBranchement.contains("store.setPinned(id, !entree.pinned)"),
          "le bouton ne ferait rien, ou épinglerait sans jamais désépingler")
    check("supprimer une entrée la retire en base",
          corpsDuBranchement.contains("store.delete(id)"))

    // Les deux gestes de vidage, chacun par sa méthode de store, et sous confirmation.
    check("tout supprimer passe par deleteAll, sous confirmation",
          corpsDuBranchement.contains("store.deleteAll()")
              && corpsDuBranchement.contains("recherchePanel.confirmer("),
          "un vidage total sans garde-fou effacerait l'historique au premier clic")
    check("tout sauf les épinglés passe par deleteAllExceptPinned",
          corpsDuBranchement.contains("store.deleteAllExceptPinned()"))

    // Le correctif de la copie d'image : on reconstruit un NSImage et on laisse
    // writeObjects redéclarer les bons types, au lieu de forcer .tiff sur des octets PNG.
    check("la copie d'image se reconstruit en NSImage avant d'écrire",
          sourceDuColleur.contains("NSImage(data: payload)")
              && sourceDuColleur.contains("pb.writeObjects([image])"),
          "une image PNG réécrite en dur sous .tiff ressortirait illisible")

    // X épingle la sélection du geste maintenu : l'ancien no-op est devenu un vrai appel.
    let debutEpingle = sourceDuDelegue.range(of: "case .basculerEpingle:")
    let finEpingle = sourceDuDelegue.range(of: "case .fermer:")
    let brancheEpingle = (debutEpingle != nil && finEpingle != nil)
        ? String(sourceDuDelegue[debutEpingle!.upperBound ..< finEpingle!.lowerBound]) : ""
    check("X épingle la sélection du geste maintenu",
          brancheEpingle.contains("store.setPinned(entree.id, !entree.pinned)"),
          "la touche X resterait sans effet, comme avant")

    // Épingler et supprimer refiltrent pour que le panneau reflète la base aussitôt.
    check("les actions du panneau refiltrent après coup",
          corpsDuBranchement.contains("filtrer(rechercheModel.requete)"),
          "le panneau afficherait encore l'entrée épinglée ou supprimée")

    // Option+Entrée et Cmd+chiffre, lus en TEXTE : le champ et le panneau importent
    // AppKit, leur interception n'est pas symlinkable ici. Ce qui se mesure est que le
    // geste est BRANCHÉ : Option sur Entrée, Cmd routé par la fenêtre, et la décision
    // de rang confiée à la règle pure testée plus haut.
    check("Option+Entrée est lu sur l'événement pour coller en texte brut",
          sourceDeLaRecherche.contains("modifierFlags.contains(.option)")
              && sourceDeLaRecherche.contains("parent.surValider(option)"),
          "Option+Entrée ne serait qu'Entrée, le texte brut jamais atteint")
    check("Cmd+chiffre est routé par la fenêtre du panneau",
          sourceDuPanneauRecherche.contains("performKeyEquivalent(with event: NSEvent)")
              && sourceDuPanneauRecherche.contains("charactersIgnoringModifiers"),
          "un Cmd+chiffre n'atteint pas doCommandBy, l'y attendre ne ferait rien")
    check("Cmd+chiffre confie le rang à la règle pure",
          sourceDuPanneauRecherche.contains("indexPourTouche(touche, nombreDeLignes: model.lignes.count)"),
          "le rang serait recalculé à la main, à côté de la règle testée")
}

section("tâche 22 : la vignette des entrées image", attendu: 12)
do {
    let sandbox = makeSandbox()
    let store = try Store(path: sandbox + "/db.sqlite", blobs: BlobStore(folder: sandbox + "/blobs", chiffre: chiffreDeTest), chiffre: chiffreDeTest)

    // Des octets qui ne sont PAS une image : la fabrication vit dans
    // `SystemPasteboard`, qui importe AppKit et n'est jamais symlinké ici. Ce qui se
    // mesure de ce côté est le transport et le stockage, pas le redimensionnement.
    let faussVignette = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42])

    var avecVignette = ClipItem.text("capture", hash: "v1", device: "m", at: 1)
    avecVignette.thumb = faussVignette
    try store.insert(avecVignette, payload: nil, uti: "public.png")
    let relue = try store.recent(limit: 10).first { $0.id == avecVignette.id }
    check("une vignette écrite à l'insertion se relit à l'identique",
          relue?.thumb == faussVignette,
          "obtenu \(String(describing: relue?.thumb?.count)) octets")

    // Le cas conforme : sans lui, un `thumb` écrit en dur passerait la vérification
    // précédente, et toutes les entrées texte porteraient une vignette fantôme.
    let sansVignette = ClipItem.text("du texte", hash: "v2", device: "m", at: 2)
    try store.insert(sansVignette, payload: nil, uti: "public.utf8-plain-text")
    let nue = try store.recent(limit: 10).first { $0.id == sansVignette.id }
    check("une entrée sans vignette rend nil, et non des octets vides",
          nue?.thumb == nil, "obtenu \(String(describing: nue?.thumb))")

    // --- le rattrapage ---
    // Le filtre porte sur DEUX conditions, et les deux se mesurent séparément :
    // sans le type, le rattrapage relirait la charge utile de chaque texte de
    // l'historique ; sans l'absence de vignette, il referait le travail à chaque
    // lancement, pour toujours.
    var imageNue = ClipItem.text("", hash: "v3", device: "m", at: 3)
    imageNue = ClipItem(id: imageNue.id, createdAt: 3, modifiedAt: 3, deviceID: "m",
                        kind: .image, title: "", searchText: "", contentHash: "v3",
                        byteSize: 10, sourceBundleID: nil, pinned: false, isRemote: false)
    try store.insert(imageNue, payload: Data([1, 2, 3]), uti: "public.png")
    var imageVetue = ClipItem(id: UUID().uuidString, createdAt: 4, modifiedAt: 4, deviceID: "m",
                              kind: .image, title: "", searchText: "", contentHash: "v4",
                              byteSize: 10, sourceBundleID: nil, pinned: false, isRemote: false)
    imageVetue.thumb = faussVignette
    try store.insert(imageVetue, payload: Data([4, 5, 6]), uti: "public.png")

    let aRattraper = try store.imagesSansVignette(limit: 100)
    check("le rattrapage retient l'image qui n'a pas de vignette",
          aRattraper.contains(imageNue.id))
    check("le rattrapage laisse l'image qui en a déjà une",
          !aRattraper.contains(imageVetue.id))
    check("le rattrapage ne touche à aucune entrée texte",
          !aRattraper.contains(sansVignette.id) && !aRattraper.contains(avecVignette.id),
          "il relirait la charge utile de tout l'historique pour rien")

    try store.setThumb(imageNue.id, faussVignette)
    try check("poser une vignette après coup la rend visible en relecture",
              store.recent(limit: 10).first { $0.id == imageNue.id }?.thumb == faussVignette)
    try check("une image rattrapée sort de la liste du rattrapage",
              !store.imagesSansVignette(limit: 100).contains(imageNue.id),
              "le rattrapage refarait le même travail à chaque lancement, pour toujours")

    // --- la migration d'une base v1 déjà remplie ---
    // Le vrai cas : la vraie base existe et contient un historique. Une
    // migration qui perdrait une entrée serait invisible tant qu'on ne migre que des
    // bases vides, c'est-à-dire dans tous les tests écrits jusqu'ici.
    // La base est ramenée à la FORME v1 en retirant la colonne, plutôt qu'en
    // appelant `Schema.v1` : la garder `private` est ce qui empêche un appelant de
    // sauter une version. Le test passe par la porte, comme le vrai code.
    let ancienne = try Database(path: sandbox + "/v1.sqlite")
    try Schema.migrate(ancienne)
    try ancienne.exec("ALTER TABLE item DROP COLUMN thumb")
    // `ocrFait` est retiré lui aussi, sans quoi la base ne serait pas vraiment de FORME
    // v1 : le `v3` rejouerait son `ALTER TABLE ADD COLUMN` sur une colonne déjà là et
    // lèverait « duplicate column name ». Depuis la v3, la forme v1 n'a ni l'une ni
    // l'autre de ces deux colonnes ajoutées après coup.
    try ancienne.exec("ALTER TABLE item DROP COLUMN ocrFait")
    ancienne.userVersion = 1
    try ancienne.run("""
    INSERT INTO item (id, createdAt, modifiedAt, deviceID, kind, title, searchText,
                      contentHash, byteSize, sourceBundleID, pinned, isRemote)
    VALUES ('vieux', 1, 1, 'm', 'text', 'avant migration', 'avant migration', 'h', 5, NULL, 0, 0)
    """, [])
    try Schema.migrate(ancienne)
    check("une base v1 déjà remplie passe en version courante",
          ancienne.userVersion == Schema.currentVersion,
          "obtenu \(ancienne.userVersion)")
    let restantes = try ancienne.query("SELECT id, thumb FROM item")
    check("la migration ne perd aucune entrée", restantes.count == 1,
          "obtenu \(restantes.count) entrées")
    check("les entrées d'avant la migration ont une vignette nulle",
          restantes.first?["thumb"] == SQLValue.null,
          "obtenu \(String(describing: restantes.first?["thumb"]))")
    try Schema.migrate(ancienne)
    check("migrer une seconde fois ne rejoue pas l'ajout de colonne",
          ancienne.userVersion == Schema.currentVersion,
          "un ALTER TABLE rejoué lèverait « duplicate column name »")

    // La vignette doit atteindre la LIGNE, sinon tout ce qui précède ne remplit qu'une
    // colonne que personne ne dessine.
    let ligne = elementsDuMenu(entrees: [avecVignette], recherche: "").first
    check("la ligne du menu porte la vignette de son entrée",
          ligne?.vignette == faussVignette)
} catch {
    echec("vignettes sans erreur", "\(error)")
}

section("tâche 24 : OCR des images cherchables", attendu: 7)
do {
    let sandbox = makeSandbox()
    let store = try Store(path: sandbox + "/db.sqlite",
                          blobs: BlobStore(folder: sandbox + "/blobs"))

    /// Une image fraîche : `kind .image`, `searchText` vide, `ocrFait` à 0 par défaut. La
    /// fabrique `ClipItem.text` ne connaît que le texte, on la recompose donc à la main,
    /// comme la section vignette.
    func image(_ hash: String, at: Double) -> ClipItem {
        ClipItem(id: UUID().uuidString, createdAt: at, modifiedAt: at, deviceID: "m",
                 kind: .image, title: "", searchText: "", contentHash: hash,
                 byteSize: 10, sourceBundleID: nil, pinned: false, isRemote: false)
    }

    let facture = image("o1", at: 1)
    try store.insert(facture, payload: Data([1, 2, 3]), uti: "public.png")

    // REFUS : avant OCR, le mot de sa future reconnaissance ne la trouve pas. C'est
    // l'état d'aujourd'hui, celui que la tâche corrige.
    let avant = try store.search("facture", limit: 50)
    check("avant OCR, l'image est introuvable par un mot de son contenu",
          !avant.contains { $0.id == facture.id },
          "une image a un searchText vide, donc rien à indexer")

    // ACCEPTATION : la file du rattrapage contient l'image fraîche…
    let fileAvant = try store.imagesSansTexteOCR(limit: 100)
    check("imagesSansTexteOCR rend l'image fraîche", fileAvant.contains(facture.id))

    try store.definirTexteRecherche(facture.id, "facture 2026")

    // ACCEPTATION : l'UPDATE a alimenté `searchText`, le déclencheur `item_au` a reindexé
    // le FTS, et la recherche trouve l'image par un mot de son contenu.
    let apres = try store.search("facture", limit: 50)
    check("après OCR, l'image est trouvée par la recherche",
          apres.contains { $0.id == facture.id },
          "searchText non écrit, ou FTS non reindexé")

    // Pendant du test précédent : un mot absent ne doit jamais la trouver, sinon le test
    // ci-dessus passerait avec un index qui rend tout.
    let absent = try store.search("zzzzzintrouvable", limit: 50)
    check("un terme absent ne trouve jamais l'image",
          !absent.contains { $0.id == facture.id })

    // …et ne la contient plus une fois l'OCR marqué.
    let fileApres = try store.imagesSansTexteOCR(limit: 100)
    check("après OCR, elle sort de la file du rattrapage",
          !fileApres.contains(facture.id),
          "le rattrapage la repasserait à l'OCR à chaque lancement")

    // REFUS : le filtre porte sur `kind = 'image'`. Sans cette condition, le rattrapage
    // relirait la charge utile de toute entrée texte de l'historique.
    let texte = ClipItem.text("du texte sans OCR", hash: "o2", device: "m", at: 2)
    try store.insert(texte, payload: nil, uti: "public.utf8-plain-text")
    let file = try store.imagesSansTexteOCR(limit: 100)
    check("imagesSansTexteOCR ne rend aucune entrée texte", !file.contains(texte.id))

    // REFUS : une image dont l'OCR n'a rien trouvé est quand même marquée faite. C'est
    // tout l'intérêt d'`ocrFait` face à un `searchText` vide : ne pas y revenir.
    let vide = image("o3", at: 3)
    try store.insert(vide, payload: Data([4, 5, 6]), uti: "public.png")
    try store.definirTexteRecherche(vide.id, "")
    let file2 = try store.imagesSansTexteOCR(limit: 100)
    check("une image OCR-ée sans texte trouvé ne revient pas dans la file",
          !file2.contains(vide.id),
          "ocrFait doit passer à 1 même quand l'OCR ne rend rien")
} catch {
    echec("OCR sans erreur", "\(error)")
}

section("tâche 20 : le panneau d'aperçu", attendu: 20)
do {
    // Un écran de 1440 × 900, origine en bas à gauche comme macOS, et un panneau de
    // 320 × 200. Les chiffres attendus sont posés à la main : un test qui recalculerait
    // la formule ne mesurerait que lui-même.
    let ecran = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let taille = CGSize(width: 320, height: 200)

    // Le cas nominal EN PREMIER. Sans lui, un placement toujours à gauche et toujours
    // en bas passerait les trois cas limites qui suivent.
    let nominal = placementDuPanneau(ancre: CGRect(x: 300, y: 400, width: 320, height: 24),
                                     taille: taille, ecran: ecran)
    check("le panneau se pose à droite de l'ancre quand la place existe",
          nominal.x == 628, "obtenu \(nominal.x)")
    check("le haut du panneau s'aligne sur le haut de l'ancre",
          nominal.y == 224, "obtenu \(nominal.y)")

    // Un panneau posé hors de l'écran est simplement invisible, et rien ne le
    // signale : ces trois cas sont exactement ceux qu'un coup d'œil manque.
    let aDroite = placementDuPanneau(ancre: CGRect(x: 1100, y: 400, width: 320, height: 24),
                                     taille: taille, ecran: ecran)
    check("une ancre collée au bord droit fait basculer le panneau à gauche",
          aDroite.x == 772, "obtenu \(aDroite.x)")

    let enBas = placementDuPanneau(ancre: CGRect(x: 300, y: 10, width: 320, height: 24),
                                   taille: taille, ecran: ecran)
    check("une ancre près du bas fait remonter le panneau au lieu de le faire déborder",
          enBas.y == 8, "obtenu \(enBas.y)")

    let enHaut = placementDuPanneau(ancre: CGRect(x: 300, y: 870, width: 320, height: 24),
                                    taille: taille, ecran: ecran)
    check("une ancre près du haut fait redescendre le panneau",
          enHaut.y == 692, "obtenu \(enHaut.y)")

    // --- le câblage, mesuré sur le texte comme pour tout ce qui importe AppKit ---
    let cheminDuPanneau = racineDuPaquet
        .appendingPathComponent("Sources/Overlay/ApercuPanel.swift")
    let sourceDuPanneau = (try? String(contentsOf: cheminDuPanneau, encoding: .utf8)) ?? ""
    check("la source du panneau d'aperçu est lisible", !sourceDuPanneau.isEmpty,
          "rien lu dans \(cheminDuPanneau.path)")

    // La même contrainte que l'overlay, pour la même raison : prendre le focus ferait
    // perdre à l'application cible son premier plan, donc enverrait le collage
    // ailleurs. Un panneau d'aperçu qui casserait le collage serait un comble.
    check("le panneau d'aperçu ne prend jamais le focus",
          sourceDuPanneau.contains(".nonactivatingPanel"))
    // Il se pose PAR-DESSUS le menu ouvert : un clic qui l'atteindrait au lieu
    // d'atteindre la ligne en dessous annulerait le geste qu'il accompagne.
    check("le panneau d'aperçu n'intercepte aucun clic",
          sourceDuPanneau.contains("panel.ignoresMouseEvents = true"))
    // Défaut vu sur une capture rendue, pas déduit : le panneau affichait
    // « Image · 83 Ko » en corps ET dans le pied, deux fois de suite.
    let imageMuette = ClipItem(id: "i", createdAt: 1, modifiedAt: 1, deviceID: "m",
                               kind: .image, title: "", searchText: "", contentHash: "h",
                               byteSize: 348, sourceBundleID: nil, pinned: false,
                               isRemote: false)
    check("le corps d'une entrée sans texte est déclaré redondant avec le pied",
          corpsRedondantAvecLePied(imageMuette))
    // Le cas conforme : sans lui, déclarer TOUT redondant viderait le panneau.
    let texteVrai = ClipItem.text("du vrai texte", hash: "h2", device: "m")
    check("le corps d'une entrée qui a du texte n'est pas redondant",
          !corpsRedondantAvecLePied(texteVrai))
    check("le panneau saute le corps quand il répéterait le pied",
          sourceDuPanneau.contains("if !corpsRedondantAvecLePied(item)"))

    // Le garde-fou qui manquait. Trois chemins ferment l'aperçu : le menu, le geste,
    // et le survol qui sort. Tant que l'annulation vivait chez l'appelant, deux des
    // trois l'oubliaient. Elle vit maintenant chez celui qui affiche.
    check("masquer l'aperçu ANNULE tout affichage en attente",
          corpsDeMethode(sourceDuPanneau, apres: "func masquer() {").contains("report.annuler()"),
          "l'affichage reporté se poserait après la fermeture, et le panneau serait orphelin")
    check("le report vit dans le panneau, pas chez l'appelant",
          sourceDuPanneau.contains("private var report = ReportAnnulable()")
              && !sourceDuDelegue.contains("generationDeLApercu"),
          "un appelant pourrait à nouveau masquer sans annuler")
    check("l'affichage de l'aperçu est bien reporté",
          sourceDuPanneau.contains("delaiAvantLApercu"),
          "balayer le menu construirait un panneau par ligne traversée")
    // Un aperçu est transitoire : le faire voyager de bureau en bureau est
    // précisément ce qui le rendait impossible à semer.
    // Assertion POSITIVE et non « ne contient pas .canJoinAllSpaces » : la première
    // version de ce test tombait sur le commentaire qui explique justement pourquoi
    // ce drapeau est absent. Un test qui lit les commentaires ne mesure rien.
    check("l'aperçu ne suit pas l'utilisateur d'un bureau à l'autre",
          sourceDuPanneau.contains("panel.collectionBehavior = [.fullScreenAuxiliary]"))
    check("changer de bureau ou d'application ferme l'aperçu",
          sourceDuPanneau.contains("activeSpaceDidChangeNotification")
              && sourceDuPanneau.contains("didActivateApplicationNotification"))

    check("le panneau lit le corps ET le pied de la règle pure",
          sourceDuPanneau.contains("corpsDeLApercu(item)")
              && sourceDuPanneau.contains("piedDeLApercu(item)"),
          "un aperçu recopié sur place divergerait des plafonds testés")

    // Demandé le 2026-09-01 : dans le geste maintenu, l'aperçu suit la ligne
    // SÉLECTIONNÉE, donc le clavier, et pas seulement la souris.
    let debutDeplacer = sourceDuDelegue.range(of: "case .deplacer, .allerA:")
    let finDeplacer = sourceDuDelegue.range(of: "case .basculerTexteBrut:")
    let brancheDeplacer = (debutDeplacer != nil && finDeplacer != nil)
        ? String(sourceDuDelegue[debutDeplacer!.upperBound ..< finDeplacer!.lowerBound]) : ""
    check("l'aperçu suit la sélection au clavier du geste maintenu",
          brancheDeplacer.contains("rafraichirLApercuDuGeste()"),
          "l'aperçu resterait figé sur la première entrée pendant tout le geste")
    check("la fermeture du geste masque l'aperçu",
          corpsDeMethode(sourceDuDelegue, apres: "private func fermerLePanneau() {")
              .contains("apercu.masquer()"))

    // Le geste ouvre LOGIQUEMENT à chaque Cmd-V mais n'affiche qu'après 150 ms : sans
    // cette garde, l'aperçu se poserait à côté d'un overlay invisible, et clignoterait
    // à chaque Cmd-V ordinaire, ce que le report de l'affichage existe pour éviter.
    check("l'aperçu du geste attend que l'overlay soit réellement visible",
          corpsDeMethode(sourceDuDelegue, apres: "private func rafraichirLApercuDuGeste() {")
              .contains("overlay.estVisible"))
}

section("report annulable de l'aperçu", attendu: 8)
do {
    // L'invariant a DÉJÀ été enfreint en production : le compteur vivait dans
    // l'assemblage, que rien ne teste, et deux des trois chemins de fermeture
    // masquaient sans annuler. L'affichage en attente se posait donc après la
    // fermeture. Ce type existe pour que l'invariant soit mesurable, pas seulement
    // écrit.
    var report = ReportAnnulable()

    // Le cas conforme d'abord : sans lui, un `estValide` qui rendrait TOUJOURS faux
    // passerait toutes les vérifications d'annulation, et l'aperçu ne s'afficherait
    // simplement jamais.
    let jeton = report.programmer()
    check("un travail programmé et non annulé reste valide", report.estValide(jeton))

    report.annuler()
    check("annuler périme le travail en attente", !report.estValide(jeton),
          "l'affichage se poserait APRÈS la fermeture, et le panneau serait orphelin")

    // Reprogrammer après annulation doit remarcher, sinon un aperçu annulé une fois
    // ne se rouvrirait plus jamais de la session.
    let apres = report.programmer()
    check("reprogrammer après une annulation rend un jeton valide", report.estValide(apres))

    // Deux survols coup sur coup : seul le dernier doit se poser.
    let premier = report.programmer()
    let second = report.programmer()
    check("programmer à nouveau périme le jeton précédent", !report.estValide(premier),
          "balayer le menu poserait un panneau par ligne traversée")
    check("le dernier jeton programmé est celui qui vaut", report.estValide(second))

    // Annuler deux fois de suite, ou annuler sans rien en attente, est un cas réel :
    // le menu se ferme alors que le survol venait déjà de sortir.
    report.annuler()
    report.annuler()
    check("annuler deux fois de suite ne ressuscite rien", !report.estValide(second))

    var vierge = ReportAnnulable()
    vierge.annuler()
    check("annuler sans rien en attente ne casse rien", !vierge.estValide(0))

    // Le jeton n'est jamais zéro : un `Int` par défaut vaut zéro, et un jeton oublié
    // vaudrait donc « valide » sur un report vierge.
    var neuf = ReportAnnulable()
    check("le premier jeton rendu n'est pas la valeur par défaut d'un Int",
          neuf.programmer() != 0,
          "un jeton jamais initialisé passerait pour valide")
}

section("tâche 21 : l'overlay se fige quand la souris y entre", attendu: 15)
do {
    func ouverte(_ count: Int = 5) -> HotKeyMachine {
        var m = HotKeyMachine(count: count)
        _ = m.recevoir(.modificateurDown)
        _ = m.recevoir(.key(.v))
        return m
    }

    // LE cas conforme, et il vient en premier. Sans lui, une machine qui ne collerait
    // JAMAIS au relâchement passerait toutes les vérifications du gel qui suivent, et
    // le geste principal du produit serait cassé sans qu'un seul test bouge.
    var libre = ouverte()
    _ = libre.recevoir(.key(.v))
    let (sortieLibre, _) = libre.recevoir(.modificateurUp)
    check("sans souris, relâcher Cmd colle toujours",
          sortieLibre == .coller(index: 1, texteBrut: false),
          "obtenu \(sortieLibre)")
    check("sans souris, relâcher Cmd referme toujours le geste",
          libre.etat == .inactif, "obtenu \(libre.etat)")

    // Le gel. Sans lui, cliquer un bouton du panneau exigerait de tenir Cmd d'une main
    // et la souris de l'autre, et le moindre relâchement collerait l'entrée au lieu de
    // la supprimer, c'est-à-dire l'inverse exact de l'intention.
    var figee = ouverte()
    _ = figee.recevoir(.key(.v))
    _ = figee.recevoir(.sourisEntree)
    check("la souris entrée dans le panneau fige le geste", figee.fige)
    let (sortieFigee, _) = figee.recevoir(.modificateurUp)
    check("figé, relâcher Cmd ne colle rien", sortieFigee == .rien, "obtenu \(sortieFigee)")
    check("figé, relâcher Cmd ne ferme pas le panneau", figee.etat == .ouvert,
          "obtenu \(figee.etat)")

    // Le gel ne se lève pas tout seul : le trajet du curseur entre deux lignes passe
    // par des pixels qui n'appartiennent à aucune, et rendre le collage accidentel à
    // ce moment-là serait pire que ne pas figer du tout.
    _ = figee.recevoir(.key(.v))
    check("naviguer au clavier ne dégèle PAS le geste", figee.fige)

    // La sortie du gel, sans laquelle le panneau resterait à l'écran pour toujours.
    let (sortieEchap, _) = figee.recevoir(.key(.escape))
    check("figé, Échap ferme quand même", sortieEchap == .fermer)
    check("Échap dégèle en même temps qu'il ferme", !figee.fige)

    // La machine SURVIT au geste : un `fige` resté vrai figerait le geste suivant dès
    // son ouverture, et le collage ne partirait plus jamais au relâchement.
    var recyclee = ouverte()
    _ = recyclee.recevoir(.sourisEntree)
    _ = recyclee.recevoir(.key(.escape))
    _ = recyclee.recevoir(.key(.v))
    check("l'ouverture suivante repart dégelée", !recyclee.fige,
          "le geste d'après ne collerait plus jamais au relâchement")

    // --- la suppression, et son recalage ---
    var aSupprimer = ouverte(3)
    let (sortieSuppr, _) = aSupprimer.recevoir(.supprimerLaSelection)
    check("supprimer rend le rang sélectionné", sortieSuppr == .supprimer(index: 0),
          "obtenu \(sortieSuppr)")
    check("supprimer décrémente le compte", aSupprimer.count == 2,
          "obtenu \(aSupprimer.count)")

    // Le cas qui casse tout si on l'oublie : supprimer la DERNIÈRE ligne laisserait
    // l'index sur un rang qui n'existe plus, et le collage suivant sortirait de la
    // liste.
    var surLaDerniere = ouverte(2)
    _ = surLaDerniere.recevoir(.key(.digit(2)))
    _ = surLaDerniere.recevoir(.supprimerLaSelection)
    check("supprimer la dernière ligne fait reculer l'index",
          surLaDerniere.index == 0, "obtenu \(surLaDerniere.index) pour 1 entrée restante")

    // Un panneau ouvert sur zéro ligne ne se distingue pas d'un panneau bloqué.
    var derniere = ouverte(1)
    _ = derniere.recevoir(.supprimerLaSelection)
    check("supprimer la seule entrée referme le panneau", derniere.etat == .arme,
          "obtenu \(derniere.etat)")
    check("supprimer la seule entrée dégèle aussi", !derniere.fige)

    // Hors de l'état ouvert, la souris n'a rien à dire.
    var armee = HotKeyMachine(count: 5)
    _ = armee.recevoir(.modificateurDown)
    _ = armee.recevoir(.sourisEntree)
    check("la souris ne fige rien tant que le panneau n'est pas ouvert", !armee.fige)
}

section("tâche 21 : câblage de la souris du geste", attendu: 10)
do {
    // Tout le gel testé au-dessus ne vaut rien si la vue ne prévient personne : un
    // garde-fou non branché est un garde-fou absent. `OverlayView` importe SwiftUI et
    // `AppDelegate` n'est couvert par aucun test, donc c'est le TEXTE des deux sites
    // d'appel qui se mesure, comme pour le panneau.
    let cheminDeLaVue = racineDuPaquet.appendingPathComponent("Sources/Overlay/OverlayView.swift")
    let sourceDeLaVue = (try? String(contentsOf: cheminDeLaVue, encoding: .utf8)) ?? ""
    check("la source de l'overlay est lisible", !sourceDeLaVue.isEmpty)

    check("l'overlay oublie la ligne survolée quand la souris sort",
          sourceDeLaVue.contains("if !dedans { survolee = nil }"),
          "les boutons resteraient affichés sur une ligne que la souris a quittée")
    check("l'overlay porte les mêmes deux boutons que le menu de barre",
          sourceDeLaVue.contains("model.onEpingler?(rang)")
              && sourceDeLaVue.contains("model.onSupprimer?(rang)"))

    let corpsDuCablage = corpsDeMethode(sourceDuDelegue,
                                        apres: "private func brancherLaSourisDuGeste() {")
    // Le gel part d'un MOUVEMENT et non d'un survol : un `onHover` se déclenche à
    // l'apparition de la vue sous un curseur immobile, et l'overlay s'ouvrant au centre
    // de l'écran, le panneau se figeait tout seul dès son ouverture.
    let corpsDuMouvement = corpsDeMethode(sourceDuDelegue,
                                          apres: "private func surveillerLeMouvement() {")
    check("le gel part d'un mouvement de souris, pas d'un survol",
          corpsDuMouvement.contains(".mouseMoved") && corpsDuMouvement.contains(".sourisEntree"),
          "le panneau se figerait tout seul en s'ouvrant sous le curseur")
    check("le gel exige que le curseur soit VRAIMENT sur le panneau",
          corpsDuMouvement.contains("overlay.cadre.contains(NSEvent.mouseLocation)"),
          "un mouvement n'importe où sur l'écran figerait le geste")
    check("la vue ne fige plus rien elle-même",
          !sourceDeLaVue.contains("onSurvolPanneau"),
          "deux chemins vers le gel, dont un faux")
    check("la suppression passe par la machine, qui recale l'index",
          corpsDuCablage.contains("traiter(.supprimerLaSelection)")
              && !corpsDuCablage.contains("store.delete("),
          "un delete direct laisserait l'index sur un rang qui n'existe plus")

    // Le panneau figé ne se lève pas quand la souris ressort, et c'est voulu : sans
    // une porte de sortie, il resterait à l'écran jusqu'à un Échap que rien n'annonce.
    // Ce test-ci mesurait la DÉCLARATION, et il est passé au vert pendant que la
    // fonction n'était appelée nulle part : la seule sortie d'un panneau figé était
    // Échap, et « la fenêtre de maintien est bloquée » a été signalé en usage réel le
    // 2026-09-01. Un garde-fou non branché est un garde-fou absent, et un test qui
    // vérifie qu'il EXISTE au lieu de vérifier qu'il est APPELÉ n'en est pas un.
    check("le moniteur de clic extérieur est vraiment ARMÉ quand le gel arrive",
          corpsDeMethode(sourceDuDelegue, apres: "private func surveillerLeMouvement() {")
              .contains("surveillerLeClicExterieur()"),
          "seul Échap sortirait d'un panneau figé, et rien ne l'annonce")
    check("le moniteur de clic existe et écoute les deux boutons",
          corpsDeMethode(sourceDuDelegue, apres: "private func surveillerLeClicExterieur() {")
              .contains("addGlobalMonitorForEvents"))
    check("le moniteur de clic ne survit pas à la fermeture",
          corpsDeMethode(sourceDuDelegue, apres: "private func fermerLePanneau() {")
              .contains("arreterLaSurveillanceDuClic()"),
          "un moniteur global laissé vivant intercepterait tous les clics du système")
}

section("tâche 23 : le lancement à l'ouverture de session", attendu: 14)
do {
    // La décision, en pur. Le monde système se réduit à deux entrées : ce que
    // l'utilisateur a dit dans NOTRE menu, et ce que dit `SMAppService.status`.
    check("un défaut jamais touché inscrit l'application au premier lancement",
          doitEnregistrerAuLancement(choix: .jamaisExprime, etat: .jamaisEnregistre,
                                     dansUnBundle: true),
          "l'application ne se lancerait pas au démarrage sans que personne l'ait refusé")
    check("un oui explicite réinscrit quand l'inscription a disparu",
          doitEnregistrerAuLancement(choix: .oui, etat: .jamaisEnregistre,
                                     dansUnBundle: true),
          "un rebuild qui perd l'inscription ne se rattraperait jamais")
    check("un refus explicite ne se réinscrit jamais",
          !doitEnregistrerAuLancement(choix: .non, etat: .jamaisEnregistre,
                                      dansUnBundle: true),
          "décocher la case du menu serait défait au lancement suivant")

    // Le cas conforme des vérifications précédentes : une politique qui enregistre
    // à tous les coups passerait le défaut et le oui sans que ni l'un ni l'autre ne
    // le voie, et c'est celle-ci qui la démasque.
    check("un état déjà actif ne se réinscrit pas",
          !doitEnregistrerAuLancement(choix: .jamaisExprime, etat: .actif,
                                      dansUnBundle: true),
          "register rendrait kSMErrorAlreadyRegistered à chaque lancement")

    // Le geste le plus récent de l'utilisateur est celui fait dans Réglages Système.
    check("un refus venu de Réglages Système prime sur notre oui",
          !doitEnregistrerAuLancement(choix: .oui, etat: .refuseParLUtilisateur,
                                      dansUnBundle: true),
          "l'application se réinscrirait contre le choix fait dans les Réglages")

    // Mesuré le 2026-09-28, après avoir cru le contraire : un binaire nu
    // (`swift run`, `.build/debug/Copyclipzer`) N'échoue pas à `register`, il
    // s'inscrit avec une identité inventée, hors de portée de la case du menu.
    check("un binaire nu ne s'inscrit jamais, même par défaut",
          !doitEnregistrerAuLancement(choix: .jamaisExprime, etat: .jamaisEnregistre,
                                      dansUnBundle: false),
          "le binaire de .build serait inscrit au démarrage de session")

    /// Le câblage, lu en TEXTE : `AppDelegate` n'est couvert par aucun test. Les
    /// commentaires sont retirés AVANT la mesure : une ligne commentée n'est pas un
    /// appel branché, et la chercher telle quelle laisserait passer exactement ce
    /// que ces vérifications surveillent (mesuré par sabotage le 2026-09-28).
    func sansCommentaires(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
    check("le lancement est assuré au démarrage de l'application",
          sansCommentaires(corpsDeMethode(sourceDuDelegue,
                                          apres: "func applicationDidFinishLaunching(_: Notification) {"))
              .contains("LoginItem.assurerAuLancement()"),
          "la politique serait testée mais jamais appelée")
    check("la case du menu lit l'état réel du système",
          sansCommentaires(corpsDeMethode(sourceDuDelegue,
                                          apres: "private func afficherLeMenuDeLIcone() {"))
              .contains("LoginItem.actif ? .on : .off"),
          "la case afficherait notre préférence au lieu du réglage système")
    check("le clic sur la case passe par la bascule",
          sansCommentaires(corpsDeMethode(sourceDuDelegue,
                                          apres: "private func basculerOuvertureAuDemarrage("))
              .contains("LoginItem.basculer()"),
          "la case ne ferait rien, ou par un chemin non mesuré")

    // L'enveloppe système, lue en TEXTE elle aussi : la garde du binaire nu n'existe
    // que si elle est branchée des trois côtés (décision, affichage, clic).
    let cheminDeLOuverture = racineDuPaquet
        .appendingPathComponent("Sources/Copyclipzer/LoginItem.swift")
    let sourceDeLOuverture = (try? String(contentsOf: cheminDeLOuverture, encoding: .utf8)) ?? ""
    check("la source de l'inscription est lisible", !sourceDeLOuverture.isEmpty,
          "rien lu dans \(cheminDeLOuverture.path)")
    check("le binaire nu est reconnu à l'absence d'identifiant de bundle",
          sourceDeLOuverture.contains("Bundle.main.bundleIdentifier != nil"),
          "la garde porterait sur autre chose que le bundle réellement exécuté")
    check("la politique d'inscription reçoit l'état réel du bundle",
          sourceDeLOuverture.contains("dansUnBundle: dansUnBundle"),
          "la décision resterait vraie en binaire nu et l'inscrirait")
    check("l'état affiché ne ment pas hors bundle",
          sourceDeLOuverture.contains("etat == .actif && dansUnBundle"),
          "la case afficherait coché pour une inscription qui n'est pas la nôtre")
    check("la case ne bascule rien hors bundle",
          sourceDeLOuverture.contains("guard dansUnBundle else"),
          "un clic en binaire nu inscrirait le binaire de .build")
}

section("internationalisation : les chaines d'interface vivent dans les .strings", attendu: 10)
do {
    // Pas de test runtime par `NSLocalizedString(..., bundle: .module) == fr` : le harnais
    // de test n'a AUCUN bundle de ressources (et forcer la langue serait fragile). On
    // mesure donc ce qui est stable : les deux fichiers existent, leurs clefs coincident,
    // les valeurs sont reelles, et les vues les lisent au lieu de garder un litteral.
    let dossierRessources = racineDuPaquet.appendingPathComponent("Sources/Resources")
    let frTexte = (try? String(contentsOf: dossierRessources
            .appendingPathComponent("fr.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    let enTexte = (try? String(contentsOf: dossierRessources
            .appendingPathComponent("en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    check("les deux fichiers de traduction sont lisibles",
          !frTexte.isEmpty && !enTexte.isEmpty,
          "rien lu dans fr.lproj ou en.lproj")

    func cles(_ texte: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"([^"]*)"\s*;"#,
                                                   options: [.anchorsMatchLines]) else { return [:] }
        var table: [String: String] = [:]
        let plage = NSRange(texte.startIndex..., in: texte)
        for m in regex.matches(in: texte, range: plage) {
            guard let k = Range(m.range(at: 1), in: texte),
                  let v = Range(m.range(at: 2), in: texte) else { continue }
            table[String(texte[k])] = String(texte[v])
        }
        return table
    }
    let fr = cles(frTexte)
    let en = cles(enTexte)
    check("le fichier francais defini un nombre utile de cles", fr.count >= 25,
          "obtenu \(fr.count) cles")
    check("les clefs des deux langues coincident exactement",
          Set(fr.keys) == Set(en.keys),
          "FR \(fr.count) cles, EN \(en.count), manquantes EN : \(Set(fr.keys).subtracting(en.keys).sorted())")
    check("le francais est la langue par defaut attendue",
          fr["action.supprimer"] == "Supprimer" && fr["recherche.historique_vide"] == "Historique vide",
          "obtenu \(String(describing: fr["action.supprimer"]))")
    check("l'anglais donne une traduction reelle et non la cle",
          en["action.supprimer"] == "Delete" && en["action.tout_supprimer"] == "Delete all",
          "obtenu \(String(describing: en["action.supprimer"]))")

    func source(_ nom: String) -> String {
        (try? String(contentsOf: racineDuPaquet.appendingPathComponent(nom), encoding: .utf8)) ?? ""
    }
    let vueRecherche = source("Sources/Overlay/RechercheView.swift")
    let vueOverlay = source("Sources/Overlay/OverlayView.swift")
    let panneau = source("Sources/Overlay/RecherchePanel.swift")

    check("la vue de recherche lit ses libelles dans les traductions",
          vueRecherche.contains("l10n(\"recherche.historique_vide\")")
              && vueRecherche.contains("l10n(\"action.tout_supprimer\")")
              && !vueRecherche.contains("\"Historique vide\""),
          "un libelle serait reste en dur")
    check("l'overlay lit ses libelles dans les traductions",
          vueOverlay.contains("l10n(\"overlay.aucune_entree\")")
              && vueOverlay.contains("l10n(\"overlay.collage_texte_brut\")")
              && !vueOverlay.contains("\"aucune entrée\""),
          "un libelle serait reste en dur")
    check("le panneau lit le bouton d'annulation dans les traductions",
          panneau.contains("l10n(\"commun.annuler\")") && !panneau.contains("\"Annuler\""),
          "le bouton serait reste en dur")
    check("le menu des reglages lit ses libelles dans les traductions",
          vueRecherche.contains("l10n(\"reglages.section.retention\")")
              && vueRecherche.contains("l10n(\"reglages.section.raccourci\")"),
          "un libelle du menu de reglages serait reste en dur")

    // La regle qui protege les cibles sans ressources : un fichier symlinke dans
    // CopyclipzerTests ou CopyclipzerCaptures ne doit JAMAIS tirer un bundle de
    // ressources, sinon `.module` y est introuvable et la compilation casse.
    let menuFormat = source("Sources/Overlay/MenuFormat.swift")
    check("aucun fichier de logique pure ne touche au bundle de ressources",
          !menuFormat.contains("bundle:") && !menuFormat.contains("bundleDeLangue"),
          "un fichier symlinke dans les cibles sans ressources casserait leur build")
}

section("Actions intelligentes par type", attendu: 9)
do {
    // --- acceptation : chaque type reconnu rend l'action attendue ---
    check("https est reconnu comme URL",
          actionPour("https://exemple.fr") == .ouvrirURL(URL(string: "https://exemple.fr")!),
          "obtenu \(String(describing: actionPour("https://exemple.fr")))")

    check("une couleur hexadécimale à six chiffres est reconnue",
          actionPour("#1a2b3c") == .copierCouleur("#1a2b3c"))

    // Le cas court du même type : sans lui, une règle qui n'accepterait que six
    // chiffres passerait la vérification ci-dessus sans que rien ne le dise.
    check("une couleur hexadécimale à trois chiffres est reconnue",
          actionPour("#abc") == .copierCouleur("#abc"))

    check("une adresse e-mail est reconnue",
          actionPour("contact@exemple.fr") == .ecrireEmail("contact@exemple.fr"))

    // Le texte est rogné avant reconnaissance : un copier-coller ramène souvent des
    // espaces ou un saut de ligne de trop.
    check("une URL entourée d'espaces est reconnue malgré le rognage",
          actionPour("  https://x.fr  ") == .ouvrirURL(URL(string: "https://x.fr")!))

    // --- refus : ce qui ressemble sans être ne doit rien proposer ---
    check("du texte ordinaire ne propose aucune action",
          actionPour("juste du texte") == nil)
    check("un dièse suivi de lettres n'est pas une couleur",
          actionPour("#zzz") == nil)
    check("une URL sans hôte n'est pas ouvrable",
          actionPour("http://") == nil)

    // Le câblage, lu en TEXTE : `AppDelegate` n'est couvert par aucun test. Une
    // reconnaissance testée mais jamais branchée laisserait le bouton sans effet.
    check("le bouton d'action est branché sur l'assemblage",
          sourceDuDelegue.contains("rechercheModel.onAction = {"),
          "la règle serait testée mais jamais appelée, le bouton ne ferait rien")
}

section("Raccourci global", attendu: 14)

// Le matcher PUR, puis son branchement. Le raccourci ⌥⌘V ouvre le panneau de recherche
// depuis n'importe quelle application. L'Option ajoutée le DÉSAMBUIGUË du geste Cmd
// maintenu plus V : sans elle, les deux se confondraient et chaque Cmd-V du système
// serait avalé. C'est cette exactitude que le sabotage de l'Option doit faire tomber.

// Le défaut épinglé champ par champ. Sans cette vérification, une valeur par défaut
// fausse passerait les cas suivants tant qu'ils compareraient la même constante fausse
// des deux côtés.
check("le raccourci par défaut est ⌥⌘V",
      RaccourciGlobal.defaut.keycode == 9 && RaccourciGlobal.defaut.option
          && RaccourciGlobal.defaut.commande && !RaccourciGlobal.defaut.majuscule
          && !RaccourciGlobal.defaut.controle,
      "obtenu \(RaccourciGlobal.defaut)")

// ACCEPTATION : la frappe exacte du défaut.
check("⌥⌘V correspond au raccourci par défaut",
      correspondAuRaccourci(keycode: 9, option: true, commande: true,
                            majuscule: false, controle: false, raccourci: .defaut),
      "le raccourci n'ouvrirait jamais le panneau")

// REFUS, un par modificateur qui diverge, plus la touche. Chacun de ces cas est un
// vrai raccourci système qui serait avalé si la comparaison était laxiste.
check("Cmd+V sans Option n'est pas le raccourci, c'est le geste",
      !correspondAuRaccourci(keycode: 9, option: false, commande: true,
                             majuscule: false, controle: false, raccourci: .defaut),
      "chaque Cmd-V de toutes les applications serait avalé et ouvrirait le panneau")
check("⌥V sans Commande n'est pas le raccourci",
      !correspondAuRaccourci(keycode: 9, option: true, commande: false,
                             majuscule: false, controle: false, raccourci: .defaut),
      "une frappe sans Cmd ouvrirait le panneau")
check("⌥⌘X, une autre touche, n'est pas le raccourci",
      !correspondAuRaccourci(keycode: 7, option: true, commande: true,
                             majuscule: false, controle: false, raccourci: .defaut),
      "une touche différente du V déclencherait le panneau")
check("⌥⌘⇧V, Maj en plus, n'est pas le raccourci",
      !correspondAuRaccourci(keycode: 9, option: true, commande: true,
                             majuscule: true, controle: false, raccourci: .defaut),
      "un Cmd-Maj-Opt-V d'application serait avalé")
check("⌥⌘⌃V, Contrôle en plus, n'est pas le raccourci",
      !correspondAuRaccourci(keycode: 9, option: true, commande: true,
                             majuscule: false, controle: true, raccourci: .defaut),
      "un raccourci voisin serait avalé")

/// CONFIG : un raccourci différent, ⌃⌘Espace. La même entrée ⌥⌘V doit alors être
/// refusée, et c'est l'entrée configurée qui doit être acceptée. Sans ce second volet,
/// un matcher qui comparerait toujours au défaut passerait tout ce qui précède.
let raccourciEspace = RaccourciGlobal(keycode: 49, option: false, commande: true,
                                      majuscule: false, controle: true)
check("avec un autre raccourci configuré, ⌥⌘V est refusé",
      !correspondAuRaccourci(keycode: 9, option: true, commande: true,
                             majuscule: false, controle: false, raccourci: raccourciEspace),
      "le panneau s'ouvrirait sur l'ancien raccourci au lieu du nouveau")
check("avec ⌃⌘Espace configuré, ⌃⌘Espace est accepté",
      correspondAuRaccourci(keycode: 49, option: false, commande: true,
                            majuscule: false, controle: true, raccourci: raccourciEspace),
      "le raccourci configuré n'ouvrirait pas le panneau")

// Le branchement. Un garde-fou non branché est un garde-fou absent : un matcher juste
// que personne n'appelle laisserait le raccourci sans effet, et un tap qui le détecterait
// APRÈS l'aiguillage du geste laisserait la machine le voir. `EventTap` et `AppDelegate`
// importent CoreGraphics et AppKit, ils ne sont jamais symlinkés : ce qui se mesure est
// le TEXTE, comme pour le reste du tap et de l'assemblage.
check("le tap appelle le matcher pur pour le raccourci",
      sourceDuTap.contains("correspondAuRaccourci(keycode: Int(code)"),
      "la détection serait revenue dans le tap, hors de portée des tests")
check("le tap déclenche le callback du raccourci et consomme la frappe",
      sourceDuTap.contains("onRaccourciGlobal?()") && sourceDuTap.contains("return nil"),
      "le raccourci n'ouvrirait rien, ou laisserait la frappe filer")

let positionDuRaccourci = sourceDuTap.range(of: "correspondAuRaccourci(keycode:")?.lowerBound
let positionDeLAiguillage = sourceDuTap.range(of: "let decision = decider(type:")?.lowerBound
check("la détection du raccourci précède l'aiguillage du geste",
      positionDuRaccourci != nil && positionDeLAiguillage != nil
          && positionDuRaccourci! < positionDeLAiguillage!,
      "la machine verrait d'abord la frappe, et le geste pourrait l'avaler ou s'ouvrir dessus")

check("l'assemblage branche le raccourci sur l'ouverture du panneau",
      sourceDuDelegue.contains("onRaccourciGlobal: { [weak self] in self?.recherchePanel.afficher() }"),
      "le panneau ne s'ouvrirait jamais par le raccourci")
check("l'assemblage donne au tap le raccourci vivant des réglages",
      sourceDuDelegue.contains("raccourciGlobal: { [weak self] in self?.reglages.raccourciOuverture ?? .defaut }"),
      "un changement de réglage ne serait pas vu avant un relancement")

section("Mise à jour · comparaison de versions", attendu: 9)
do {
    // --- acceptation : une version publiée plus grande est proposée ---
    check("une version plus récente est détectée",
          VersionSemantique.miseAJourDisponible(installee: "1.0.0", derniere: "1.1.0"),
          "la mise à jour ne serait pas proposée")
    check("le préfixe v des tags GitHub est toléré",
          VersionSemantique.miseAJourDisponible(installee: "1.0.0", derniere: "v1.0.1"),
          "un tag vX.Y.Z ne serait jamais reconnu comme plus récent")
    check("la comparaison est numérique, pas lexicographique : 1.10.0 > 1.2.0",
          VersionSemantique.miseAJourDisponible(installee: "1.2.0", derniere: "1.10.0"),
          "une comparaison de chaînes classerait 1.10.0 avant 1.2.0 et raterait la mise à jour")
    // --- refus : ni égalité, ni régression, ni version illisible ---
    check("une version identique ne propose rien",
          !VersionSemantique.miseAJourDisponible(installee: "1.1.0", derniere: "1.1.0"),
          "proposer une mise à jour vers la même version")
    check("une version publiée plus ancienne ne propose rien",
          !VersionSemantique.miseAJourDisponible(installee: "1.2.0", derniere: "1.1.0"),
          "proposer une mise à jour vers une version plus vieille")
    check("une version illisible ne propose rien (pas de mise à jour sur un doute)",
          !VersionSemantique.miseAJourDisponible(installee: "1.0.0", derniere: "inconnu"),
          "un tag illisible déclencherait une fausse mise à jour")
    // --- lecture du tag_name dans la réponse de l'API GitHub ---
    check("le tag_name est extrait de la réponse JSON",
          VersionSemantique.tagDepuisJSON(Data(#"{"tag_name":"v2.0.0"}"#.utf8)) == "v2.0.0",
          "le tag de la release ne serait pas lu")
    check("un JSON sans tag_name rend nil",
          VersionSemantique.tagDepuisJSON(Data("{}".utf8)) == nil,
          "un objet sans tag serait pris pour une version valide")
    check("un corps non-JSON rend nil",
          VersionSemantique.tagDepuisJSON(Data("pas du json".utf8)) == nil,
          "une réponse d'erreur serait prise pour un tag")
}

verifierLesSections()
print("\nrésultat : \(passed) ok, \(failures) échec(s)")
exit(failures == 0 ? 0 : 1)
