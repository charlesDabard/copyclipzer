import Foundation
import os

/// Le journal de diagnostic, écrit dans `~/Library/Logs/Copyclipzer/copyclipzer.log`.
///
/// Il existe parce que les pannes de ce produit sont SILENCIEUSES par construction : un tap
/// que macOS désactive, un relâchement de Cmd manqué, une permission Accessibilité perdue
/// après une reconstruction, une écriture SQLite refusée sous un `try?`. Aucune ne lève
/// d'alerte, et le constat de l'utilisateur se résume à « Cmd ne marche plus ». Le 2026-10-17,
/// l'audit a recensé plus de trente `try?` sans trace et un `_ = tap.start()` dont l'échec
/// ne se voyait nulle part. Chaque ligne d'ici répond à une question qu'on se posait sans
/// pouvoir y répondre.
///
/// Règle de confidentialité, non négociable : le journal ne contient JAMAIS le contenu du
/// presse-papiers ni ce qui est tapé. Types, tailles, identifiants de bundle, décisions,
/// codes de raccourcis Cmd : oui. Texte copié, titre d'entrée, requête de recherche : non.
/// Un test lit les sources pour le vérifier, voir la section « Journal » des tests.
///
/// Fichier PUR (Foundation et os) : il est symlinké dans la cible de test, et tant que
/// `configurer` n'a pas été appelé il n'écrit rien sur disque, ce qui garde les tests hors
/// du vrai dossier de journaux.
final class Journal {
    static let partage = Journal()

    /// Au-delà, le fichier courant devient `copyclipzer.1.log` et repart de zéro. Deux Mo
    /// tiennent des semaines d'usage normal (une à trois lignes par copie ou par collage).
    static let plafondDOctets = 2_000_000
    /// Nombre d'archives gardées en plus du fichier courant : `.1.log` et `.2.log`.
    static let nombreDArchives = 2
    static let nomDuFichier = "copyclipzer.log"

    /// Toutes les écritures passent par cette file série : le journal est appelé depuis le
    /// fil principal, le callback du tap, et les tâches de fond de l'OCR. L'écriture ne
    /// doit jamais retenir le callback du tap, d'où l'asynchronisme.
    private let file = DispatchQueue(label: "io.github.copyclipzer.journal", qos: .utility)
    private var dossier: URL?
    private var poignee: FileHandle?
    private var tailleCourante = 0
    private let plafond: Int
    private let logger = Logger(subsystem: "io.github.copyclipzer", category: "journal")

    /// Le mode détaillé ajoute la trace de chaque entrée du geste (raccourcis Cmd
    /// seulement, jamais de frappe ordinaire, voir `AppDelegate.traiter`). Désactivé par
    /// défaut, piloté par le menu de l'icône.
    var detaille = false

    /// `plafond` n'a d'autre usage que les tests, qui vérifient la rotation sans écrire
    /// deux Mo.
    init(plafond: Int = Journal.plafondDOctets) {
        self.plafond = plafond
    }

    /// Le chemin du fichier courant, nil tant que le journal n'est pas configuré.
    var fichier: URL? {
        file.sync { dossier?.appendingPathComponent(Journal.nomDuFichier) }
    }

    /// Le dossier standard des journaux utilisateur, que Console.app liste tout seul sous
    /// « Rapports de journal ».
    static var dossierParDefaut: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Copyclipzer")
    }

    /// Active l'écriture sur disque. Sans cet appel, `info`, `alerte` et `erreur` ne vont
    /// que vers le journal unifié de macOS.
    func configurer(dossier: URL) {
        file.sync {
            try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
            self.dossier = dossier
            self.ouvrir()
        }
    }

    func info(_ categorie: String, _ message: String) {
        ecrire(.info, categorie, message)
    }

    func alerte(_ categorie: String, _ message: String) {
        ecrire(.alerte, categorie, message)
    }

    func erreur(_ categorie: String, _ message: String) {
        ecrire(.erreur, categorie, message)
    }

    /// N'écrit que si le mode détaillé est actif. Le message est une fermeture pour ne pas
    /// fabriquer la chaîne quand personne ne la lira : c'est appelé à chaque raccourci Cmd.
    func detail(_ categorie: String, _ message: @autoclosure () -> String) {
        guard detaille else { return }
        ecrire(.detail, categorie, message())
    }

    /// Remplace `try?` sur les chemins où une erreur doit laisser une trace. Rend la valeur,
    /// ou nil après avoir journalisé l'erreur avec son contexte. Le contexte ne doit jamais
    /// contenir de contenu copié (voir la règle de confidentialité plus haut).
    @discardableResult
    func essayer<T>(_ categorie: String, _ contexte: String, _ corps: () throws -> T) -> T? {
        do {
            return try corps()
        } catch {
            erreur(categorie, "\(contexte) : \(error)")
            return nil
        }
    }

    /// Attend que toutes les lignes en file soient écrites. Pour les tests, et pour la
    /// dernière ligne avant de quitter.
    func vider() {
        file.sync { try? poignee?.synchronize() }
    }

    private func ecrire(_ niveau: NiveauDeJournal, _ categorie: String, _ message: String) {
        let date = Date()
        file.async { [self] in
            let ligne = ligneDeJournal(date: date, niveau: niveau, categorie: categorie,
                                       message: message)
            switch niveau {
            case .erreur: logger.error("\(ligne, privacy: .public)")
            case .alerte: logger.warning("\(ligne, privacy: .public)")
            case .info, .detail: logger.info("\(ligne, privacy: .public)")
            }
            let octets = Data((ligne + "\n").utf8)
            if doitTourner(tailleActuelle: tailleCourante, ajout: octets.count, plafond: plafond) {
                tourner()
            }
            // `write(contentsOf:)` qui LÈVE, et non `write(_:)` qui jette une exception
            // Objective-C sur un disque plein et arrêterait l'application pour une ligne de journal.
            try? poignee?.write(contentsOf: octets)
            tailleCourante += octets.count
        }
    }

    /// Ouvre (ou crée) le fichier courant en ajout. Appelé sur `file` uniquement.
    private func ouvrir() {
        guard let dossier else { return }
        let chemin = dossier.appendingPathComponent(Journal.nomDuFichier)
        if !FileManager.default.fileExists(atPath: chemin.path) {
            FileManager.default.createFile(atPath: chemin.path, contents: nil)
        }
        poignee = try? FileHandle(forWritingTo: chemin)
        tailleCourante = Int((try? poignee?.seekToEnd()) ?? 0)
    }

    /// Décale `.1` en `.2`, le courant en `.1`, et repart d'un fichier vide. La plus vieille
    /// archive disparaît : le journal ne grossit jamais au-delà de trois plafonds.
    private func tourner() {
        guard let dossier else { return }
        try? poignee?.close()
        poignee = nil
        let fm = FileManager.default
        func archive(_ n: Int) -> URL {
            dossier.appendingPathComponent(nomDArchive(Journal.nomDuFichier, rang: n))
        }
        try? fm.removeItem(at: archive(Journal.nombreDArchives))
        for n in stride(from: Journal.nombreDArchives - 1, through: 1, by: -1) {
            try? fm.moveItem(at: archive(n), to: archive(n + 1))
        }
        try? fm.moveItem(at: dossier.appendingPathComponent(Journal.nomDuFichier), to: archive(1))
        ouvrir()
    }
}

/// Le journal global. Une seule instance pour tout le processus : deux instances
/// écriraient le même fichier depuis deux files et entrelaceraient leurs lignes.
let journal = Journal.partage

enum NiveauDeJournal: String {
    case info = "INFO"
    case alerte = "ALERTE"
    case erreur = "ERREUR"
    case detail = "DETAIL"
}

/// Une ligne : `2026-10-17 22:15:03.123 INFO   [geste] ouvrir, 9 entrées`. Le niveau est
/// calé sur six caractères pour que les catégories s'alignent en colonne à la lecture.
/// Fonction PURE, testée. Les sauts de ligne du message sont aplatis : une ligne de
/// journal ne doit jamais en devenir deux, sinon `grep` sur une date rate la suite.
func ligneDeJournal(date: Date, niveau: NiveauDeJournal, categorie: String,
                    message: String) -> String
{
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let aplati = message.replacingOccurrences(of: "\r\n", with: " ⏎ ")
        .replacingOccurrences(of: "\n", with: " ⏎ ")
        .replacingOccurrences(of: "\r", with: " ⏎ ")
    let niveauCale = niveau.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
    return "\(format.string(from: date)) \(niveauCale) [\(categorie)] \(aplati)"
}

/// Faut-il archiver le fichier courant avant d'y ajouter `ajout` octets ? Jamais sur un
/// fichier vide : une ligne plus grosse que le plafond s'écrit quand même, au lieu de
/// faire tourner en boucle sur un fichier qui ne peut pas la contenir.
func doitTourner(tailleActuelle: Int, ajout: Int, plafond: Int) -> Bool {
    tailleActuelle > 0 && tailleActuelle + ajout > plafond
}

/// `copyclipzer.log` rang 1 donne `copyclipzer.1.log`. L'extension reste `.log` pour que
/// Console.app ouvre aussi les archives d'un double clic.
func nomDArchive(_ nom: String, rang: Int) -> String {
    let base = (nom as NSString).deletingPathExtension
    let ext = (nom as NSString).pathExtension
    return ext.isEmpty ? "\(base).\(rang)" : "\(base).\(rang).\(ext)"
}

/// Durée écoulée depuis `debut`, en millisecondes entières, pour les lignes du journal.
func millisecondesDepuis(_ debut: Date) -> Int {
    Int((Date().timeIntervalSince(debut) * 1000).rounded())
}
