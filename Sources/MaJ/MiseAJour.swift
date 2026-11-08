import AppKit
import Sparkle

/// Les mises à jour, confiées à Sparkle 2 (choisi le 2026-11-08, sur le modèle de Vibe
/// Island) : vérification périodique, téléchargement en arrière-plan, archive vérifiée
/// par sa signature EdDSA AVANT toute installation, remplacement du bundle et relance.
///
/// Le flux est l'appcast attaché à la dernière release GitHub (`SUFeedURL` dans
/// Info.plist), produit et signé par `scripts/publier-version.sh`. La clé publique
/// (`SUPublicEDKey`) est figée dans Info.plist : une archive qui n'est pas signée par la
/// clé privée du mainteneur est refusée, quel que soit le certificat qui a signé l'app.
/// C'est aussi ce qui permet à quelqu'un qui a construit Copyclipzer avec son propre
/// certificat de recevoir les versions publiées (voir `SUUpdateValidator.m`, Sparkle
/// 2.10.1, lignes 296 à 303).
///
/// Glu sans règle propre : Sparkle décide, ce type relaie son état vers la pastille du
/// panneau. Non testé unitairement, comme toute la glu AppKit du projet.
final class MiseAJour: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Trois modes, façon OpenCode. `automatique` est le défaut (arbitré le 2026-11-08) :
    /// téléchargée en fond, la version s'installe à la fermeture de l'app ou d'un clic sur
    /// la pastille.
    enum Mode: Int, CaseIterable {
        case automatique, demander, desactive
    }

    /// La version annoncée par la pastille, et si elle est déjà prête à installer.
    var onEtat: ((_ version: String?, _ prete: Bool) -> Void)?

    private var controleur: SPUStandardUpdaterController!
    /// Fourni par Sparkle quand une version téléchargée attend la fermeture de l'app.
    /// L'appeler installe et relance tout de suite.
    private var installerMaintenant: (() -> Void)?

    override init() {
        super.init()
        controleur = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    private var updater: SPUUpdater {
        controleur.updater
    }

    var mode: Mode {
        get {
            guard updater.automaticallyChecksForUpdates else { return .desactive }
            return updater.automaticallyDownloadsUpdates ? .automatique : .demander
        }
        set {
            updater.automaticallyChecksForUpdates = newValue != .desactive
            updater.automaticallyDownloadsUpdates = newValue == .automatique
            journal.info("maj", "mode de mise à jour : \(newValue)")
        }
    }

    /// Le clic sur la pastille : installe la version prête, sinon ouvre la fenêtre
    /// standard de Sparkle (notes de version, Installer, Plus tard, Ignorer cette version).
    func agir() {
        if let installerMaintenant {
            journal.info("maj", "installation immédiate demandée depuis la pastille")
            installerMaintenant()
        } else {
            verifierMaintenant()
        }
    }

    /// « Rechercher les mises à jour… » : toujours une réponse visible, même « à jour ».
    func verifierMaintenant() {
        NSApp.activate(ignoringOtherApps: true)
        controleur.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        journal.info("maj", "version \(item.displayVersionString) trouvée")
    }

    func updater(_: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool
    {
        journal.info("maj", "version \(item.displayVersionString) téléchargée, installée à la fermeture")
        installerMaintenant = immediateInstallationBlock
        onEtat?(item.displayVersionString, true)
        return true
    }

    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        // « Aucune mise à jour » passe aussi par ici : ce n'est pas une panne.
        guard code != Int(SUError.noUpdateError.rawValue) else { return }
        journal.alerte("maj", "mise à jour interrompue : \(MiseAJour.chaine(error))")
    }

    /// Le message de Sparkle seul (« An error occurred in retrieving update information »)
    /// ne dit jamais POURQUOI : la cause vit dans les erreurs sous-jacentes. On déroule
    /// donc la chaîne, domaine et code compris.
    private static func chaine(_ error: Error) -> String {
        var maillons: [String] = []
        var courante: NSError? = error as NSError
        while let e = courante, maillons.count < 4 {
            maillons.append("\(e.domain) \(e.code) : \(e.localizedDescription)")
            courante = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return maillons.joined(separator: " ← ")
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Une app de barre des menus ne doit pas jeter une fenêtre au visage de l'utilisateur
    /// au milieu de sa frappe. Les rappels « doux » laissent la main : la pastille du
    /// panneau annonce la version, et Sparkle ne montre sa fenêtre que si l'app a déjà
    /// le focus. Sans cette déclaration, Sparkle journalise un avertissement pour les
    /// apps sans icône de Dock.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool
    {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state _: SPUUserUpdateState)
    {
        if !handleShowingUpdate {
            onEtat?(update.displayVersionString, installerMaintenant != nil)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // La session se termine (installée, ignorée, reportée) : la pastille ne reste
        // allumée que si une version attend encore la fermeture.
        if installerMaintenant == nil {
            onEtat?(nil, false)
        }
    }
}
