import AppKit
import ApplicationServices

/// L'autorisation Accessibilité est la SEULE permission système du projet, et
/// l'application est inutilisable sans elle. Un tap qui consomme des événements
/// l'exige ; un simple moniteur NSEvent ne l'exigerait pas, mais il ne consomme rien.
enum Permissions {
    static var accessibiliteAccordee: Bool { AXIsProcessTrusted() }

    /// Ouvre la boîte de dialogue système. Ne rend pas la main sur le résultat :
    /// l'utilisateur peut mettre du temps, d'où `surveiller`.
    static func demander() {
        let cle = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([cle: true] as CFDictionary)
    }

    /// Interroge toutes les 2 secondes jusqu'à ce que l'autorisation arrive, puis
    /// appelle le callback une fois. C'est ce qui permet de réarmer le tap sans
    /// demander à l'utilisateur de relancer l'application.
    ///
    /// À APPELER DEPUIS LE THREAD PRINCIPAL, ET APRÈS LE DÉMARRAGE DE LA BOUCLE
    /// D'EXÉCUTION. `Timer.scheduledTimer` s'inscrit sur la boucle du thread
    /// appelant : avant `NSApplication.run()` ou depuis une queue de fond, la
    /// surveillance ne se déclenche jamais, et l'utilisateur doit relancer
    /// l'application, ce que cette fonction existe justement pour éviter. Deux
    /// autres limites assumées : le callback ne rend jamais `false` alors que sa
    /// signature le promet, et le sondage ne s'arrête pas de lui-même si
    /// l'autorisation n'arrive pas.
    static func surveiller(_ callback: @escaping (Bool) -> Void) {
        if accessibiliteAccordee { callback(true); return }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            if accessibiliteAccordee { timer.invalidate(); callback(true) }
        }
    }
}
