import CryptoKit
import Foundation

/// Capture hybride. macOS ne fournit aucune notification de changement du
/// presse-papiers, donc tout le corpus interroge `changeCount` en boucle et
/// arbitre entre latence et CPU. Copyclipzer échappe à cet arbitrage parce que le
/// tap clavier exigé par le geste Cmd voit aussi passer Cmd-C : `captureNow()`
/// est appelée immédiatement à la copie, et le timer lent ne sert plus que de
/// filet pour le menu Édition, le glisser-déposer, les Services et `pbcopy`.
final class CaptureService {
    private let pasteboard: PasteboardReading
    private let store: Store
    private var policy: CapturePolicy
    private let deviceID: String
    private var lastCount: Int
    private var timer: Timer?

    /// Une relance est due au tour suivant : la dernière lecture a rendu `nil` ou un
    /// contenu VIDE, ce qui arrive quand l'écriture est encore en cours, types
    /// déclarés mais type promis pas encore matérialisé. Mesuré le 2026-09-30 :
    /// quatre dictées SuperWhisper ont été lues 40 ms après leur écriture et n'ont
    /// rien laissé en base alors que le texte tenait encore une seconde. Le
    /// remplissage d'un type promis ne fait pas bouger `changeCount` : sans relance,
    /// le compteur est consommé pour rien et le texte est perdu. Une seule relance,
    /// jamais deux, sinon un contenu réellement vide se relirait à chaque tour.
    private var relance = false

    init(pasteboard: PasteboardReading, store: Store, policy: CapturePolicy, deviceID: String) {
        self.pasteboard = pasteboard
        self.store = store
        self.policy = policy
        self.deviceID = deviceID
        lastCount = pasteboard.changeCount
    }

    /// Rend `true` si une nouvelle entrée a été enregistrée.
    @discardableResult
    func poll() -> Bool {
        let count = pasteboard.changeCount
        let dueAUneRelance = relance
        relance = false
        if !dueAUneRelance, count == lastCount {
            return false
        }
        lastCount = count

        guard let snapshot = pasteboard.read() else {
            if !dueAUneRelance {
                relance = true
            }
            return false
        }
        let decision = policy.decide(snapshot)
        guard case let .keep(kind) = decision else {
            // Le vide seul se relit. Un marqueur, une application exclue ou un motif
            // secret sont des refus définitifs : les relire ne changerait rien.
            if case .ignore("vide") = decision, !dueAUneRelance {
                relance = true
            }
            return false
        }

        let payload = snapshot.image ?? snapshot.rtf
        let texte = snapshot.fileURLs.isEmpty
            ? (snapshot.text ?? "")
            : snapshot.fileURLs.joined(separator: "\n")
        let brut = payload ?? Data(texte.utf8)
        guard brut.count <= BlobStore.plafond else { return false }

        let hash = SHA256.hash(data: brut).map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        let item = ClipItem(
            id: UUID().uuidString, createdAt: now, modifiedAt: now, deviceID: deviceID,
            kind: kind, title: String(texte.prefix(200)), searchText: texte,
            contentHash: hash, byteSize: brut.count,
            sourceBundleID: snapshot.sourceBundleID, pinned: false,
            isRemote: snapshot.types.contains("com.apple.is-remote-clipboard"),
            // Transportée, jamais fabriquée ici : ce fichier est PUR et symlinké dans
            // la cible de test, et une vignette a besoin d'AppKit. Elle vient de
            // `SystemPasteboard`, le seul fichier de ce dossier qui l'importe déjà.
            thumb: snapshot.vignette
        )

        return (try? store.insert(item, payload: payload,
                                  uti: snapshot.types.first ?? "public.utf8-plain-text")) ?? false
    }

    /// Déclare qu'un `changeCount` vient de NOUS et ne doit pas être capturé.
    ///
    /// Appelée par `Paster` juste après son écriture. Sans elle, notre propre collage
    /// revient en base : en collage texte brut nous n'écrivons que `searchText` en
    /// `.string`, `poll()` le lit, `CapturePolicy.decide` rend `.keep(.text)`, le hash
    /// diffère de celui de l'entrée RTF ou image d'origine, et `Store.insert` crée une
    /// NOUVELLE ligne. Coller une entrée RTF en texte brut polluait l'historique d'un
    /// doublon texte, à chaque fois. La restauration désactivée par défaut n'y change
    /// rien : c'est notre ÉCRITURE que la capture voit, pas la restauration.
    ///
    /// Seul le compteur exact est sauté. Un compteur ultérieur, donc une vraie copie
    /// de l'utilisateur, entre normalement.
    func ignorerJusqua(_ changeCount: Int) {
        lastCount = changeCount
    }

    /// Appelée par le tap clavier dès qu'un Cmd-C ou un Cmd-X passe. Un court
    /// délai laisse l'application source finir d'écrire dans le presse-papiers.
    func captureNow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.poll() }
    }

    /// 0,5 s et non 1,0 : SuperWhisper n'expose chaque dictée qu'une seconde dans le
    /// presse-papiers avant de restaurer le contenu précédent (mesuré le 2026-09-28),
    /// et un filet de même période pouvait tomber juste avant l'écriture puis juste
    /// après la restauration. À 0,5 s, la fenêtre d'une seconde contient deux ticks.
    func start(interval: TimeInterval = 0.5) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Remplace à chaud la liste des bundles exclus de la capture. Les Réglages
    /// l'appellent quand l'utilisateur modifie la liste, sans relancer l'application.
    /// Le motif secret éventuel est conservé tel quel.
    func definirBundlesExclus(_ ids: Set<String>) {
        policy = CapturePolicy(blockedBundleIDs: ids, secretPattern: policy.secretPattern)
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }
}
