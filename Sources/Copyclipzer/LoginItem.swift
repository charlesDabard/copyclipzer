import Foundation
import ServiceManagement

/// Inscription de l'application dans les éléments d'ouverture de session.
///
/// `SMAppService.mainApp` (macOS 13, le minimum du projet) remplace les plists
/// LaunchAgent : la liste appartient au système, se voit dans Réglages Système >
/// Général > Éléments d'ouverture, et l'utilisateur peut y décocher l'application.
///
/// Ce fichier est la frontière système, donc non testé : il lit `SMAppService`,
/// retient le choix de l'utilisateur et journalise. La RÈGLE qui décide quand
/// inscrire vit dans `LoginItemPolicy.swift`, pure et testée.
enum LoginItem {
    /// Le choix EXPLICITE de l'utilisateur, absent tant qu'il n'a rien touché.
    /// Absent n'est pas « non » : c'est ce qui permet au défaut d'être ON sans
    /// réécrire un refus venu de Réglages Système.
    private static let cle = "ouvertureAuDemarrage"

    static var choix: ChoixDOuverture {
        guard let brut = UserDefaults.standard.object(forKey: cle) as? Bool else {
            return .jamaisExprime
        }
        return brut ? .oui : .non
    }

    static var etat: EtatDuLoginItem {
        switch SMAppService.mainApp.status {
        case .enabled: return .actif
        // `requiresApproval` est exactement « l'utilisateur a décoché la case dans
        // Réglages Système », pas « il n'a jamais rien fait ».
        case .requiresApproval: return .refuseParLUtilisateur
        default: return .jamaisEnregistre
        }
    }

    /// Faux quand l'application tourne en binaire nu, par `swift run` ou depuis
    /// `.build`. Ce n'est PAS un cas d'échec à journaliser : sans identifiant de
    /// bundle, `SMAppService` invente une identité (`Copyclipzer-5555...`) et
    /// inscrirait le binaire de développement comme un élément d'ouverture à part
    /// entière, que la case du menu de l'application installée ne pourrait même pas
    /// retirer. Mesuré le 2026-09-28, après avoir cru le contraire.
    private static var dansUnBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static var actif: Bool { etat == .actif && dansUnBundle }

    /// Au lancement : inscrit l'application si le défaut n'a jamais été touché,
    /// ne touche à rien sinon. Aucune erreur n'est fatale ici, l'échec part au
    /// journal.
    static func assurerAuLancement() {
        guard doitEnregistrerAuLancement(choix: choix, etat: etat,
                                         dansUnBundle: dansUnBundle) else { return }
        inscrire()
    }

    /// Le clic sur la case du menu. Décocher désinscrit et RETIENT le refus, sans
    /// quoi le lancement suivant réinscrirait l'application. Pour un refus venu des
    /// Réglages, `register` rendrait `kSMErrorAlreadyRegistered` : on ouvre les
    /// Réglages, seul endroit où la case peut être recochée.
    static func basculer() {
        // Sans cette garde, un clic sur la case en binaire nu tomberait dans la
        // branche `.jamaisEnregistre` et inscrirait le binaire de `.build`.
        guard dansUnBundle else {
            NSLog("Copyclipzer : binaire nu, la case d'ouverture reste sans effet")
            return
        }
        switch etat {
        case .actif:
            UserDefaults.standard.set(false, forKey: cle)
            do { try SMAppService.mainApp.unregister() }
            catch { NSLog("Copyclipzer : desinscription au demarrage refusee : \(error)") }
        case .refuseParLUtilisateur:
            UserDefaults.standard.set(true, forKey: cle)
            SMAppService.openSystemSettingsLoginItems()
        case .jamaisEnregistre:
            UserDefaults.standard.set(true, forKey: cle)
            inscrire()
        }
    }

    private static func inscrire() {
        do { try SMAppService.mainApp.register() }
        catch { NSLog("Copyclipzer : inscription au demarrage refusee : \(error)") }
    }
}
