import AppKit
import Combine

/// Assemble les modules du projet, et c'est le seul fichier qui les connaît tous. Il ne
/// décide rien : chaque règle vit dans le module pur qui la porte, ce qui est la raison
/// pour laquelle ce fichier n'est couvert par aucun test et doit donc rester aussi mince
/// que possible.
///
/// Toutes les dépendances sont des PROPRIÉTÉS, jamais des variables locales de
/// `applicationDidFinishLaunching`. Plusieurs ne sont retenues par personne d'autre.
/// `NSApp` retient bien le `NSPanel`, mais rien ne retient l'enveloppe `OverlayPanel`,
/// qui porte le `NSHostingView`, le modèle et l'abonnement à `objectWillChange` : en
/// variable locale, le panneau resterait affiché et figé sur son premier contenu, sans
/// que rien ne le signale. `EventTap` est pire : CoreGraphics reçoit un
/// `passUnretained(self)`, donc la boucle d'exécution garde la source et le port Mach
/// alors que plus rien ne garde l'objet, et le callback déréférence un pointeur mort à la
/// frappe suivante.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Références fortes tenues pour toute la durée de vie de l'application. Voir le
    /// commentaire de la classe : ce n'est pas de la prudence de principe, plusieurs de
    /// ces objets échouent en silence sans elles.
    private var store: Store!
    private var capture: CaptureService!
    private var tap: EventTap!
    private var paster: Paster!
    private var overlay: OverlayPanel!
    private var statusItem: NSStatusItem!

    /// Le panneau de recherche et son modèle, qui remplacent le menu de barre. C'est lui
    /// qui corrige le bug de focus : le champ vit dans un panneau clavier ordinaire, donc
    /// rien ne le retire entre deux frappes. Voir `RecherchePanel`.
    private var recherchePanel: RecherchePanel!
    private let rechercheModel = RechercheModel()
    /// Les entrées actuellement affichées dans le panneau, par identifiant. Le modèle ne
    /// porte que `LigneDeMenu`, de quoi dessiner ; l'entrée complète se relit ici au
    /// moment de coller, d'épingler ou de supprimer.
    private var entreesDuPanneau: [String: ClipItem] = [:]
    /// Abonnement à la sélection du panneau de recherche. Gardé vivant par l'assemblage,
    /// comme celui d'`OverlayPanel` : sans cette référence, l'abonnement serait libéré à
    /// la sortie de la portée et l'aperçu ne suivrait plus jamais les flèches.
    private var abonnementApercuRecherche: AnyCancellable?

    /// Les préférences, pilotées depuis le menu de l'engrenage du panneau.
    private let reglages = Reglages.shared
    /// Applique les réglages (exclusions, taille, rétention) dès qu'une préférence change.
    /// Remplace la closure que portait l'ancienne fenêtre de réglages.
    private var abonnementReglages: AnyCancellable?

    /// Les valeurs proposées dans les sous-menus de réglages. Des préréglages, parce qu'un
    /// menu ne peut pas accueillir un stepper ni un enregistreur de raccourci.
    private let taillesProposees = [100, 250, 500, 1000, 2000, 5000]
    private let retentionsProposees = [0, 7, 14, 30, 90]
    private let raccourcisProposes: [(libelle: String, raccourci: RaccourciGlobal)] = [
        ("⌥⌘V", RaccourciGlobal(keycode: 9, option: true, commande: true, majuscule: false, controle: false)),
        ("⌃⌘Espace", RaccourciGlobal(keycode: 49, option: false, commande: true, majuscule: false, controle: true)),
        ("⌥⌘C", RaccourciGlobal(keycode: 8, option: true, commande: true, majuscule: false, controle: false)),
        ("⌃⌥⌘V", RaccourciGlobal(keycode: 9, option: true, commande: true, majuscule: false, controle: true)),
    ]

    /// UN seul panneau d'aperçu pour le geste Cmd maintenu. Voir `ApercuPanel`.
    private let apercu = ApercuPanel()
    /// Le moniteur de clic extérieur, vivant seulement pendant que le geste est figé.
    private var moniteurDeClic: Any?
    /// Le moniteur de mouvement, vivant seulement tant que le panneau est affiché et pas
    /// encore figé. Voir `surveillerLeMouvement()`.
    private var moniteurDeMouvement: Any?

    /// L'état du geste. `count` est relu au V qui ouvre, et à lui seul, voir `traiter`.
    private var machine = HotKeyMachine(count: 0)

    /// Numéro du geste en cours, pour que l'affichage différé sache s'il est périmé.
    ///
    /// Incrémenté à chaque ouverture ET à chaque fermeture, quelle qu'en soit la cause.
    /// Sans lui, le report serait pire que pas de report du tout : le panneau apparaîtrait
    /// APRÈS le collage, sur un geste déjà refermé, et resterait à l'écran jusqu'au geste
    /// suivant. C'est le mode d'échec propre à tout affichage différé.
    private var generationDuGeste = 0

    /// Le seul objet partagé entre l'assemblage et l'overlay du geste. `OverlayPanel` s'y
    /// abonne dans son `init`, donc toute mutation faite ici se voit à l'écran.
    private let model = OverlayModel()

    func applicationDidFinishLaunching(_: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Copyclipzer")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        // `try!` assumé, et c'est le seul du projet. Une application dont la base refuse
        // de s'ouvrir n'a rien à offrir : tout le reste du montage en dépend et échouerait
        // de toute façon, plus tard et plus obscurément.
        store = try! Store(path: support.appendingPathComponent("history.sqlite").path)
        capture = CaptureService(pasteboard: SystemPasteboard(), store: store,
                                 policy: CapturePolicy(blockedBundleIDs: Set(reglages.appsExclues),
                                                       secretPattern: nil),
                                 deviceID: Host.current().localizedName ?? "mac")
        // `capture:` n'a volontairement pas de valeur par défaut. Sans lui, notre propre
        // écriture dans le presse-papiers revient en base : coller une entrée RTF en texte
        // brut n'écrit que `searchText`, le hash diffère de l'original, et l'historique
        // gagne un doublon à chaque collage.
        paster = Paster(store: store, capture: capture)
        overlay = OverlayPanel(model: model)
        recherchePanel = RecherchePanel(model: rechercheModel)
        // Les réglages vivent dans le menu de l'engrenage du panneau, plus dans une fenêtre.
        // Ce qui déclenchait `appliquerReglages` depuis la fenêtre devient un abonnement aux
        // changements de préférences. `DispatchQueue.main.async` pour lire la valeur APRÈS
        // qu'elle soit appliquée (`objectWillChange` précède la mutation).
        abonnementReglages = reglages.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.appliquerReglages() }
        }
        brancherLePanneauDeRecherche()
        brancherLApercuDuPanneauDeRecherche()
        brancherLaSourisDuGeste()

        capture.start(interval: 0.5)
        installerLIconeDeBarre()
        LoginItem.assurerAuLancement()

        // Deux contrats se croisent dans ces lignes, et cet ordre est le seul qui les
        // respecte tous les deux.
        //
        // 1. `Permissions.surveiller` exige le thread principal ET une boucle d'exécution
        //    démarrée, parce qu'elle pose un `Timer.scheduledTimer` qui s'inscrit sur la
        //    boucle du thread appelant. `applicationDidFinishLaunching` part de
        //    `NSApplication.run()`, sur le thread principal, et la boucle principale
        //    tourne dès que cette méthode rend la main : le timer se déclenchera.
        //
        // 2. `demarrerTap()` n'a QU'UN seul site d'appel, celui-ci. `surveiller` rappelle
        //    IMMÉDIATEMENT son callback quand l'autorisation est déjà accordée, donc
        //    démarrer le tap ici puis le confier à `surveiller` l'ouvrirait deux fois sur
        //    le cas le plus courant, celui du deuxième lancement.
        Permissions.surveiller { [weak self] _ in
            self?.demarrerTap()
        }
        if !Permissions.accessibiliteAccordee {
            Permissions.demander()
        }

        appliquerReglages()
        rattraperLesVignettes()
        rattraperLOCR()
        verifierLesMisesAJour()
    }

    /// Au lancement, demande à GitHub s'il existe une version plus récente et, le cas
    /// échéant, allume la pastille du panneau. Silencieux en cas d'absence de réseau ou de
    /// release : le check ne doit jamais déranger ni bloquer. Ne télécharge aucun binaire.
    private func verifierLesMisesAJour() {
        VerificateurMaJ.verifier { [weak self] version in
            self?.rechercheModel.majDisponible = version
        }
    }

    /// Unique site d'appel de `EventTap.start()`, voir le point 2 ci-dessus.
    private func demarrerTap() {
        // `[weak self]` sur les TROIS fermetures. Le délégué retient le tap et le tap
        // retient ses fermetures : les capturer fortement fermerait le cycle, le `deinit`
        // d'`EventTap` ne s'exécuterait jamais, et les quatre gestes qu'il porte
        // (désactiver, retirer de la boucle, invalider le port, relâcher) ne se feraient
        // jamais non plus. Le filet de sécurité serait présent dans le code et absent à
        // l'exécution.
        tap = EventTap(
            onInput: { [weak self] input in self?.traiter(input) ?? false },
            onCopyShortcut: { [weak self] in self?.capture.captureNow() },
            // Le raccourci global ouvre le panneau de recherche. `afficher()` fait déjà
            // `NSApp.activate(ignoringOtherApps: true)`, donc le panneau devient clavier :
            // c'est l'avantage mesuré sur le clic d'icône, qui pouvait le laisser non clé.
            onRaccourciGlobal: { [weak self] in self?.recherchePanel.afficher() },
            // L'état vivant, relu par le tap à chaque événement. Il n'a qu'un usage :
            // effacer la capture de Cmd-C et Cmd-X pendant que l'overlay est ouvert, où X
            // épingle. Le repli `.inactif` couvre le seul cas où `self` est parti.
            etatDuGeste: { [weak self] in self?.machine.etat ?? .inactif },
            // Le raccourci vivant, relu comme l'état : changer le réglage prend effet sans
            // relancer le tap. Le repli `.defaut` (⌥⌘V) couvre le seul cas où `self` est parti.
            raccourciGlobal: { [weak self] in self?.reglages.raccourciOuverture ?? .defaut }
        )
        // `EventTap.start()` échoue si l'accessibilité n'est pas accordée : le geste Cmd ne
        // marche alors pas, mais le reste de l'application (capture, panneau) tourne.
        _ = tap.start()
    }

    /// Traduit une sortie de la machine en gestes sur l'interface, et rend `true` quand
    /// l'événement doit être AVALÉ. Le tap applique cette réponse telle quelle, c'est elle
    /// qui empêche le « 3 » de s'écrire dans le document pendant qu'il sélectionne la
    /// troisième entrée.
    private func traiter(_ input: HotKeyInput) -> Bool {
        // Réaccord AVANT de soumettre l'entrée. Tout le bornage de la machine
        // (`min(index + 1, count - 1)`, `cible < count`, le `guard count > 0` qui refuse
        // d'ouvrir sur une liste vide) porte sur `count` : le mettre à jour après
        // `recevoir` bornerait sur l'historique tel qu'il était au geste précédent, et la
        // toute première ouverture bornerait sur zéro.
        //
        // Le QUAND est une règle pure, pas un `if` posé ici : ce fichier n'est couvert par
        // aucun test. Depuis le 2026-08-26, c'est le V qui ouvre, et lui seul, au lieu de
        // chaque `.modificateurDown` devenu chaque appui sur Cmd.
        if doitRelireLeCompte(etat: machine.etat, input: input) {
            machine.count = (try? store.recent(limit: 9).count) ?? 0
        }
        let (sortie, consomme) = machine.recevoir(input)

        // Aucun `overlay.rafraichir()` dans ce `switch`, et ce n'est pas un oubli :
        // `OverlayPanel` s'abonne à `model.objectWillChange` dans son `init` et se
        // réaccorde seul au tour de boucle suivant. Toute mutation de `model` ci-dessous
        // déclenche donc le réaccord.
        switch sortie {
        case .ouvrir:
            model.items = (try? store.recent(limit: 9)) ?? []
            model.index = 0
            model.texteBrut = false
            // L'ouverture LOGIQUE est immédiate, l'affichage attend. Depuis que le geste
            // s'arme sur Cmd, l'overlay s'ouvre à chaque Cmd-V, donc des dizaines de fois
            // par jour : sans ce report il clignoterait à chacun. Cmd relâché avant le
            // délai, le panneau n'a jamais été montré et l'utilisateur ne voit rien. Le
            // collage, lui, n'est pas retardé : il part au relâchement dans tous les cas.
            generationDuGeste += 1
            let generation = generationDuGeste
            DispatchQueue.main.asyncAfter(deadline: .now() + delaiAvantAffichage) { [weak self] in
                guard let self, self.generationDuGeste == generation else { return }
                self.overlay.afficher()
                self.rafraichirLApercuDuGeste()
                self.surveillerLeMouvement()
            }
        case .deplacer, .allerA:
            model.index = machine.index
            // L'aperçu suit la sélection au CLAVIER, pas la souris : maintenir Cmd et
            // appuyer V plusieurs fois fait défiler l'aperçu à droite du panneau.
            rafraichirLApercuDuGeste()
        case .basculerTexteBrut:
            model.texteBrut = machine.texteBrut
        case .basculerEpingle:
            // X épingle ou désépingle la sélection du geste maintenu. `Store.setPinned`
            // existe désormais : l'ancien no-op devenait un vrai manque alors que la
            // colonne `pinned` et la vue étaient prêtes. Même chemin que l'épingle à la
            // souris et que le panneau de recherche.
            if model.index < model.items.count {
                let entree = model.items[model.index]
                try? store.setPinned(entree.id, !entree.pinned)
                model.items = (try? store.recent(limit: 9)) ?? []
                rafraichirLApercuDuGeste()
            }
        case .fermer:
            fermerLePanneau()
        case let .coller(index, brut):
            fermerLePanneau()
            // Pas de `DispatchQueue.main.async` ici. `Paster.coller` renvoie déjà le
            // travail sur la boucle principale, de l'intérieur, précisément pour que le
            // site d'appel ne puisse pas oublier de le faire.
            if index < model.items.count {
                paster.coller(model.items[index], texteBrut: brut)
            }
        case .collerNatif:
            // L'utilisateur a relâché Cmd sans rien choisir : ce n'était pas un geste
            // Copyclipzer, c'était un Cmd-V. On lui rend le sien, à l'identique, et le
            // presse-papiers n'est ni lu ni écrit. Voir `Paster.reposerCollageNatif`.
            fermerLePanneau()
            Paster.reposerCollageNatif()
        case let .supprimer(index):
            // La machine a DÉJÀ recalé `count` et `index` : il ne reste qu'à supprimer en
            // base et à relire.
            if index < model.items.count {
                try? store.delete(model.items[index].id)
            }
            model.items = (try? store.recent(limit: 9)) ?? []
            model.index = min(machine.index, max(0, model.items.count - 1))
            if model.items.isEmpty {
                fermerLePanneau()
            } else {
                rafraichirLApercuDuGeste()
            }
        case .rien:
            break
        }
        return consomme
    }

    /// Referme l'overlay du geste ET périme l'affichage différé qui pourrait encore être
    /// en vol. Les deux gestes vont ensemble : `masquer()` seul laisserait le report
    /// s'exécuter juste après, sur un geste déjà terminé.
    private func fermerLePanneau() {
        generationDuGeste += 1
        overlay.masquer()
        apercu.masquer()
        arreterLaSurveillanceDuClic()
        arreterLaSurveillanceDuMouvement()
    }

    /// Le trombone de SF Symbols est dessiné EN DIAGONALE, et il n'existe aucune variante
    /// droite dans le jeu de symboles. On le redresse donc à la main, à 45 degrés (valeur
    /// choisie en rendant les angles puis en les regardant). `isTemplate` est
    /// indispensable : sans lui l'icône reste noire sur une barre de menus sombre.
    private func trombonneDroit(taille: CGFloat = 18) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: taille, weight: .regular)
        guard let base = NSImage(systemSymbolName: "paperclip",
                                 accessibilityDescription: "Copyclipzer")?
            .withSymbolConfiguration(config) else { return nil }

        let cote = max(base.size.width, base.size.height)
        let redresse = NSImage(size: NSSize(width: cote, height: cote))
        redresse.lockFocus()
        let pivot = NSAffineTransform()
        pivot.translateX(by: cote / 2, yBy: cote / 2)
        pivot.rotate(byDegrees: 45)
        pivot.translateX(by: -cote / 2, yBy: -cote / 2)
        pivot.concat()
        base.draw(in: NSRect(x: (cote - base.size.width) / 2,
                             y: (cote - base.size.height) / 2,
                             width: base.size.width,
                             height: base.size.height))
        redresse.unlockFocus()
        redresse.isTemplate = true
        return redresse
    }

    /// L'icône de la barre des menus. `LSUIElement` retire l'icône du Dock, donc c'est la
    /// seule surface visible en permanence : sans elle, pas moyen de rouvrir le panneau ni
    /// de quitter l'application autrement qu'au Moniteur d'activité.
    private func installerLIconeDeBarre() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = trombonneDroit()
        statusItem.button?.toolTip = "Copyclipzer"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(iconeCliquee)
        // Clic gauche ET clic droit passent par la même action : le gauche ouvre le
        // panneau de recherche, le droit (ou Ctrl-clic) ouvre un petit menu de secours.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func iconeCliquee() {
        let event = NSApp.currentEvent
        let droit = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if droit {
            afficherLeMenuDeLIcone()
        } else {
            recherchePanel.basculer()
        }
    }

    /// Le menu de secours de l'icône : ouverture au démarrage, Quitter. Les réglages
    /// complets vivent désormais dans le menu de l'engrenage du panneau. Posé puis retiré
    /// aussitôt, pour que le clic gauche garde son action à lui plutôt que d'ouvrir ce menu.
    private func afficherLeMenuDeLIcone() {
        let menu = NSMenu()
        let demarrage = NSMenuItem(title: l10n("menu.ouvrir_demarrage"),
                                   action: #selector(basculerOuvertureAuDemarrage), keyEquivalent: "")
        demarrage.target = self
        demarrage.state = LoginItem.actif ? .on : .off
        menu.addItem(demarrage)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: l10n("menu.quitter"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Bascule l'ouverture au démarrage. La case reflète l'état RÉEL au prochain affichage
    /// du menu : si l'utilisateur a décoché dans Réglages Système, c'est ce geste-là qui
    /// s'affichera.
    @objc private func basculerOuvertureAuDemarrage() {
        LoginItem.basculer()
    }

    /// Branche les gestes du panneau de recherche sur le stockage. Le panneau ne connaît
    /// que des identifiants et des `LigneDeMenu` ; tout ce qui touche la base passe ici.
    private func brancherLePanneauDeRecherche() {
        rechercheModel.onRequete = { [weak self] requete in self?.filtrer(requete) }
        rechercheModel.onValider = { [weak self] id, texteBrut in
            guard let self, let entree = entreesDuPanneau[id] else { return }
            // Coller rend le focus à l'application d'avant PUIS colle, voir
            // `RecherchePanel.collerDans`. Un clic, Entrée ou Cmd+chiffre sur une ligne
            // colle donc dans le document où l'on était, ce qu'on attend d'un panneau de
            // recherche. `texteBrut` vient d'Option+Entrée, et de lui seul.
            recherchePanel.collerDans { [weak self] in
                self?.paster.coller(entree, texteBrut: texteBrut)
            }
        }
        rechercheModel.onEpingler = { [weak self] id in
            guard let self, let entree = entreesDuPanneau[id] else { return }
            try? store.setPinned(id, !entree.pinned)
            filtrer(rechercheModel.requete)
        }
        rechercheModel.onSupprimer = { [weak self] id in
            guard let self else { return }
            try? store.delete(id)
            filtrer(rechercheModel.requete)
        }
        // L'action intelligente du bouton d'une ligne : la reconnaissance vit dans la
        // règle pure testée, l'exécution AppKit dans son propre geste, plus bas.
        rechercheModel.onAction = { [weak self] id in
            guard let self, let entree = entreesDuPanneau[id],
                  let action = actionPour(entree.searchText) else { return }
            executerLActionIntelligente(action)
        }
        rechercheModel.onToutSupprimer = { [weak self] in
            self?.recherchePanel.confirmer(
                l10n("confirmation.vider_tout.titre"),
                l10n("confirmation.vider_tout.info"),
                l10n("action.tout_supprimer")
            ) { [weak self] in
                try? self?.store.deleteAll()
                self?.filtrer(self?.rechercheModel.requete ?? "")
            }
        }
        rechercheModel.onSupprimerSaufEpingles = { [weak self] in
            self?.recherchePanel.confirmer(
                l10n("confirmation.vider_sauf_epingles.titre"),
                l10n("confirmation.vider_sauf_epingles.info"),
                l10n("action.supprimer")
            ) { [weak self] in
                try? self?.store.deleteAllExceptPinned()
                self?.filtrer(self?.rechercheModel.requete ?? "")
            }
        }
        rechercheModel.onOuvrirMaj = {
            if let url = URL(string: "https://github.com/charlesDabard/copyclipzer/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }
        rechercheModel.onBasculerDemarrage = { [weak self] in
            LoginItem.basculer()
            self?.rechercheModel.ouvertureAuDemarrage = LoginItem.actif
        }
        brancherLesReglagesDuMenu()
    }

    /// Exécute l'action reconnue sur le texte d'une entrée. AppKit pur, hors de la règle
    /// testable : ouvrir l'URL, copier la couleur, composer l'e-mail.
    private func executerLActionIntelligente(_ action: ActionIntelligente) {
        switch action {
        case let .ouvrirURL(url):
            NSWorkspace.shared.open(url)
        case let .copierCouleur(couleur):
            let pressePapiers = NSPasteboard.general
            pressePapiers.clearContents()
            pressePapiers.setString(couleur, forType: .string)
        case let .ecrireEmail(adresse):
            // Le schéma `mailto:` est toujours une URL valide pour une adresse déjà
            // reconnue (aucun espace), mais la construction reste sûre : ce fichier
            // ne porte aucun déréférencement forcé.
            if let url = URL(string: "mailto:" + adresse) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Branche l'aperçu du panneau de recherche, à côté du panneau et sur la ligne
    /// sélectionnée. Séparé de `brancherLePanneauDeRecherche` pour que cette méthode
    /// reste le seul inventaire des actions d'une ligne, court et lisible.
    ///
    /// L'abonnement porte sur `index` ET `lignes` : `index` suit les flèches, et `lignes`
    /// couvre la frappe, qui réécrit la liste et remet l'index à zéro. `receive(on:)`
    /// renvoie au tour de boucle suivant, pour lire un modèle déjà à jour et non la valeur
    /// d'avant la mutation, exactement comme `OverlayPanel` le fait sur `objectWillChange`.
    /// Le masquage passe par `recherchePanel.onMasquer`, seul point de sortie du panneau,
    /// donc aucun chemin de fermeture n'oublie de ranger l'aperçu.
    private func brancherLApercuDuPanneauDeRecherche() {
        recherchePanel.onMasquer = { [weak self] in self?.apercu.masquer() }
        recherchePanel.onAffiche = { [weak self] in
            self?.rafraichirLApercuDeLaRecherche()
            self?.rechercheModel.ouvertureAuDemarrage = LoginItem.actif
            self?.rafraichirLesReglagesDuMenu()
        }
        abonnementApercuRecherche = rechercheModel.$index
            .combineLatest(rechercheModel.$lignes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.rafraichirLApercuDeLaRecherche() }
    }

    /// Filtrage à chaque frappe. `Store.search` rend les entrées qui correspondent,
    /// `elementsDuMenu` les ordonne (épinglées d'abord), les plafonne et les numérote.
    /// Aucune charge utile n'est lue : seul `title`, déjà en base, s'affiche. C'est le même
    /// chemin pur et testé que l'ancien menu de barre.
    private func filtrer(_ requete: String) {
        let entrees = (try? store.search(requete, limit: plafondDuMenu)) ?? []
        rechercheModel.lignes = elementsDuMenu(entrees: entrees, recherche: requete)
        entreesDuPanneau = Dictionary(entrees.map { ($0.id, $0) },
                                      uniquingKeysWith: { premier, _ in premier })
        rechercheModel.index = 0
    }

    /// Applique les Réglages à chaud : exclusions de capture et taille d'historique. Appelé
    /// au lancement et à chaque modification depuis la fenêtre de réglages.
    /// Prépare le menu des réglages : les listes de valeurs proposées (fixes) et les actions
    /// qui écrivent dans `Reglages`. Les valeurs cochées, elles, sont rafraîchies à chaque
    /// ouverture du panneau par `rafraichirLesReglagesDuMenu`.
    private func brancherLesReglagesDuMenu() {
        rechercheModel.taillesPossibles = taillesProposees
        rechercheModel.retentionsPossibles = retentionsProposees
        rechercheModel.raccourcisLibelles = raccourcisProposes.map(\.libelle)

        // Chaque action écrit dans `Reglages` ET reflète aussitôt la valeur dans le modèle,
        // pour que la coche du menu bouge tout de suite et non seulement à la réouverture.
        rechercheModel.onChoisirTaille = { [weak self] n in
            let valeur = tailleHistoriqueBornee(n)
            self?.reglages.tailleHistorique = valeur
            self?.rechercheModel.tailleHistorique = valeur
        }
        rechercheModel.onChoisirRetention = { [weak self] jours in
            let valeur = retentionJoursBornee(jours)
            self?.reglages.retentionJours = valeur
            self?.rechercheModel.retentionJours = valeur
        }
        rechercheModel.onChoisirRaccourci = { [weak self] index in
            guard let self, self.raccourcisProposes.indices.contains(index) else { return }
            self.reglages.raccourciOuverture = self.raccourcisProposes[index].raccourci
            self.rechercheModel.raccourciActif = index
        }
        rechercheModel.onBasculerApp = { [weak self] identifiant in
            guard let self else { return }
            if self.reglages.appsExclues.contains(identifiant) {
                self.reglages.appsExclues.removeAll { $0 == identifiant }
            } else {
                self.reglages.appsExclues.append(identifiant)
            }
            self.rechercheModel.appsExclues = Set(self.reglages.appsExclues)
        }
    }

    /// Reflète l'état réel des préférences dans le modèle, à chaque ouverture du panneau :
    /// valeurs cochées, et la liste des apps proposées à l'exclusion (celles en cours
    /// d'exécution plus celles déjà exclues même si fermées). L'app elle-même est écartée.
    private func rafraichirLesReglagesDuMenu() {
        rechercheModel.tailleHistorique = reglages.tailleHistorique
        rechercheModel.retentionJours = reglages.retentionJours
        rechercheModel.raccourciActif =
            raccourcisProposes.firstIndex { $0.raccourci == reglages.raccourciOuverture } ?? -1
        rechercheModel.appsExclues = Set(reglages.appsExclues)

        var vus = Set<String>()
        var apps: [AppExcluable] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  vus.insert(id).inserted else { continue }
            apps.append(AppExcluable(id: id, nom: app.localizedName ?? id))
        }
        for id in reglages.appsExclues where !vus.contains(id) {
            apps.append(AppExcluable(id: id, nom: id))
        }
        rechercheModel.appsExcluables = apps.sorted {
            $0.nom.localizedCaseInsensitiveCompare($1.nom) == .orderedAscending
        }
    }

    private func appliquerReglages() {
        capture.definirBundlesExclus(Set(reglages.appsExclues))
        try? store.purge(keeping: reglages.tailleHistorique)
        // Rétention par le temps. 0 désactive : on n'appelle pas `purgerAvant` du tout,
        // sinon un seuil calculé sur 0 jour emporterait tout l'historique non épinglé.
        if reglages.retentionJours > 0 {
            let seuil = Date().timeIntervalSince1970 - Double(reglages.retentionJours) * 86400
            try? store.purgerAvant(seuil)
        }
    }

    /// Branche les deux gestes souris de l'overlay du geste Cmd sur la machine.
    ///
    /// La souris est le SEUL point d'entrée du produit qui ne passe pas par le tap
    /// clavier. Elle passe quand même par la machine, et non par des `if` posés ici : figer
    /// le geste et recaler l'index après une suppression sont des règles, et ce fichier
    /// n'est couvert par aucun test.
    private func brancherLaSourisDuGeste() {
        model.onEpingler = { [weak self] rang in
            guard let self, rang < model.items.count else { return }
            let entree = model.items[rang]
            try? store.setPinned(entree.id, !entree.pinned)
            model.items = (try? store.recent(limit: 9)) ?? []
            rafraichirLApercuDuGeste()
        }
        model.onSupprimer = { [weak self] rang in
            guard let self else { return }
            // Par la machine, qui recale `count` et `index`, et non par un `store.delete`
            // direct : voir le commentaire de `.supprimerLaSelection`.
            if rang != machine.index {
                _ = traiter(.key(.digit(rang + 1)))
            }
            _ = traiter(.supprimerLaSelection)
        }
    }

    /// Fige le geste au premier MOUVEMENT de souris au-dessus du panneau ouvert.
    ///
    /// Remplace le `onHover` de la vue, qui était faux. L'overlay s'ouvre au CENTRE de
    /// l'écran, donc très souvent sous un curseur immobile, et un `onHover` SwiftUI se
    /// déclenche à l'apparition de la vue : le panneau se figeait tout seul, dès son
    /// ouverture, et relâcher Cmd ne collait plus ni ne fermait plus. Signalé en usage réel
    /// le 2026-09-01, sous la forme « la fenêtre de maintien est bloquée ».
    ///
    /// Un survol n'est pas une intention, un MOUVEMENT en est une. Le moniteur ne vit que
    /// le temps de l'affichage, et il s'arrête dès que le gel est acquis.
    private func surveillerLeMouvement() {
        guard moniteurDeMouvement == nil else { return }
        moniteurDeMouvement = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self, overlay.estVisible, !machine.fige,
                  overlay.cadre.contains(NSEvent.mouseLocation) else { return }
            _ = traiter(.sourisEntree)
            arreterLaSurveillanceDuMouvement()
            surveillerLeClicExterieur()
        }
    }

    private func arreterLaSurveillanceDuMouvement() {
        if let moniteurDeMouvement {
            NSEvent.removeMonitor(moniteurDeMouvement)
        }
        moniteurDeMouvement = nil
    }

    /// Referme un overlay FIGÉ sur un clic ailleurs.
    ///
    /// Sans lui, un panneau figé dont l'utilisateur s'éloigne resterait à l'écran jusqu'à
    /// un Échap : `fige` ne se lève pas quand la souris ressort, et c'est voulu. Le moniteur
    /// ne vit que le temps du gel, et il est GLOBAL parce que le panneau n'est jamais clé.
    private func surveillerLeClicExterieur() {
        guard moniteurDeClic == nil else { return }
        moniteurDeClic = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,
                                                                      .rightMouseDown])
        { [weak self] _ in
            self?.fermerLePanneau()
        }
    }

    private func arreterLaSurveillanceDuClic() {
        if let moniteurDeClic {
            NSEvent.removeMonitor(moniteurDeClic)
        }
        moniteurDeClic = nil
    }

    /// Repose l'aperçu sur la ligne SÉLECTIONNÉE du panneau de recherche, à côté du
    /// panneau. Même rôle que `rafraichirLApercuDuGeste`, même panneau : le contenu
    /// affiché est la règle pure et testée `LigneDeMenu.apercu`, ce fichier ne fait que
    /// la brancher. Un index hors bornes, ou un panneau fermé, range l'aperçu au lieu de
    /// le laisser orphelin.
    private func rafraichirLApercuDeLaRecherche() {
        guard recherchePanel.estVisible,
              rechercheModel.lignes.indices.contains(rechercheModel.index),
              let entree = entreesDuPanneau[rechercheModel.lignes[rechercheModel.index].id]
        else {
            apercu.masquer()
            return
        }
        apercu.afficher(entree, pres: recherchePanel.cadre)
    }

    /// Repose l'aperçu sur la ligne SÉLECTIONNÉE du geste maintenu.
    ///
    /// Appelée après l'affichage de l'overlay et à chaque déplacement. Elle ne fait rien
    /// tant que l'overlay n'est pas visible : pendant les 150 ms d'attente, le geste peut
    /// encore se terminer en Cmd-V ordinaire, et un aperçu qui clignoterait là serait
    /// exactement ce que le report de l'affichage cherche à éviter.
    private func rafraichirLApercuDuGeste() {
        guard overlay.estVisible, model.index < model.items.count else { return }
        apercu.afficher(model.items[model.index], pres: overlay.cadre)
    }

    /// Fabrique après coup la vignette des images entrées avant la migration v2.
    ///
    /// Une migration ajoute une colonne, elle ne remplit pas le passé : sans ce rattrapage,
    /// tout l'historique déjà capturé resterait au symbole générique jusqu'à ce que chaque
    /// image soit recopiée une par une.
    ///
    /// Hors de la boucle principale, parce qu'il RELIT les charges utiles, ce qui est
    /// exactement ce que le reste du produit s'interdit de faire au premier plan. Fait une
    /// fois, borné par le nombre d'images en base.
    private func rattraperLesVignettes() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let ids = try? store.imagesSansVignette(limit: 500) else { return }
            for id in ids {
                guard let octets = try? store.payload(id),
                      let vignette = SystemPasteboard.vignette(octets) else { continue }
                try? store.setThumb(id, vignette)
            }
        }
    }

    /// Lit le texte des images entrées sans OCR et le pose dans `searchText`.
    ///
    /// Clone exact de `rattraperLesVignettes()` : même file d'attente de fond, même
    /// bornage, même relecture de la charge utile. C'est le seul moment où l'OCR tourne,
    /// jamais dans la boucle de capture, qui doit rester rapide. On écrit
    /// `definirTexteRecherche` MÊME quand l'OCR ne rend rien, pour marquer `ocrFait = 1`
    /// et ne pas relire cette image à chaque lancement.
    private func rattraperLOCR() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let ids = try? store.imagesSansTexteOCR(limit: 500) else { return }
            for id in ids {
                guard let octets = try? store.payload(id) else { continue }
                let texte = SystemPasteboard.texteOCR(octets)
                try? store.definirTexteRecherche(id, texte ?? "")
            }
        }
    }
}
