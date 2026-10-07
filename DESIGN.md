# Copyclipzer · design v1

Établi le 2026-08-25, révisé le même jour pour s'aligner sur les conventions de QuickTasks. Justifié par `knowledge-base/clipboard-manager/SYNTHESIS.md`, où chaque choix renvoie à une source mesurée. Statut : **en attente de validation**, aucune ligne de code écrite.

## Décisions prises

| Question        | Réponse                               | Conséquence                                                             |
| --------------- | ------------------------------------- | ----------------------------------------------------------------------- |
| Pour qui        | l'utilisateur seul, sur ses machines        | Pas de sandbox, pas de revue App Store, accès système complet           |
| Plateforme v1   | macOS 13 minimum                      | Aucune branche `#available` à écrire, même socle que QuickTasks         |
| iPhone          | v2                                    | Le schéma est prêt pour la synchro dès la v1, mais rien n'est construit |
| Vues            | SwiftUI                               | Reprend les composants et les mesures de QuickTasks                     |
| Système         | AppKit                                | NSPanel, CGEventTap, menu de barre, raccourci global                    |
| Stockage        | SQLite3 système, `import SQLite3`     | Zéro dépendance externe, FTS5 trigram quand même                        |
| Geste principal | Maintien de Ctrl, navigation visuelle | Zéro délai d'attente, annulable, modèle ClipJump                        |

## Ce que la v1 fait

Capture continue de tout ce qui est copié sur le Mac : texte brut, texte riche, images, fichiers. Recherche plein texte réelle sur l'historique complet. Navigation et collage entièrement au clavier, en maintenant Ctrl. Exclusion sérieuse des contenus sensibles.

## Ce que la v1 ne fait pas, volontairement

iPhone, synchronisation, extraits réutilisables, OCR, serveur MCP. Chacun mérite sa propre spec. Les nommer ici sert à ce qu'ils ne rentrent pas par la fenêtre pendant l'implémentation.

---

## 1. Lignes reprises de QuickTasks

Relevées dans le code, pas déduites. Ce sont des contraintes, pas des suggestions.

### Conventions de projet

- **SwiftPM, sans Xcode.** `swift-tools-version:5.9`, `platforms: [.macOS(.v13)]`. Le projet se construit avec les Command Line Tools seuls.
- **Zéro dépendance externe.** `Package.swift` ne contient aucun `.package(url:)`, et ça reste vrai ici : SQLite arrive par le système.
- **Les tests sont des `.executableTarget`, pas des `.testTarget`.** XCTest exige Xcode, que ce projet n'utilise pas. Les fichiers de logique pure sont symlinkés dans la cible de test, qui se lance par `swift run CopyclipzerTests`.
- **Bundle assemblé à la main.** `build.sh` fait `swift build -c release`, monte l'arborescence `.app`, copie `Resources/Info.plist`, et signe en ad-hoc (`codesign --force --deep --sign -`). Plus `install.sh` et `make-dmg.sh`.
- **Documentation en français**, commentaires `///` en français, doc longue dans `docs/`, captures dans `screenshots/`.

### Arborescence

```
Copyclipzer/
├── Package.swift
├── build.sh · install.sh · make-dmg.sh
├── Resources/Info.plist
├── Sources/
│   ├── Copyclipzer/        AppDelegate, main, menu de barre
│   ├── Capture/ Store/ HotKey/ Overlay/ Paste/
│   └── Shared/             composants de vue communs
├── Tests/CopyclipzerTests/ cible exécutable, fichiers purs symlinkés
├── docs/                   cette spec, le plan, les audits
└── screenshots/            vérifications manuelles
```

### Vocabulaire visuel

Relevé dans `Sources/QuickNotes/SearchPanel.swift`, qui est déjà presque l'overlay dont on a besoin.

| Élément         | Valeur                                                                      |
| --------------- | --------------------------------------------------------------------------- |
| Fond de panneau | `.regularMaterial`, plus `VisualEffectBackground()` pour la fenêtre         |
| Coins           | `RoundedRectangle(cornerRadius: 10)`                                        |
| Bordure         | `.stroke(Color.primary.opacity(0.1))`                                       |
| Ombre           | `.black.opacity(0.2), radius: 12, y: 4`                                     |
| Marges          | 12 en externe, 10 en interne, `spacing: 6` dans une ligne                   |
| Typographie     | `.system(size: 13)` pour le contenu, `.system(size: 12)` pour le secondaire |
| Gris            | `.foregroundColor(.secondary)`                                              |
| Icônes          | SF Symbols                                                                  |
| Langue          | Interface en français                                                       |


### Pourquoi Cmd et non Ctrl · correction du 2026-08-26

Le geste utilisait `Ctrl` maintenu, sur la foi d'une vérification qui portait sur le mauvais périmètre : `Ctrl-V` est libre **pour macOS**, il ne l'est pas **dans les outils de l'utilisateur**. Claude Code s'en sert pour coller une image, et le tap l'avalait dès que l'historique n'était pas vide. Il a dû quitter l'application pour coller. La mesure était juste, son périmètre était faux.

Le geste passe donc sur `Cmd`, et `Ctrl-V` redevient entièrement libre. Ça déplace le risque : `Cmd-V` est **le** collage du système, donc chaque collage de la machine traverse désormais notre tap.

**La règle qui rend ce changement sûr, c'est le relais natif.** Si l'utilisateur relâche `Cmd` sans avoir navigué (aucun `V` supplémentaire, aucune flèche, aucun chiffre, ni `Z` ni `X`), on ne colle pas depuis la base : on **repose l'événement d'origine**, marqué de notre signature pour que le tap l'ignore. Le presse-papiers n'est ni lu ni écrit, et aucune image ni aucun fichier ne fait d'aller-retour par notre stockage. Un `Cmd-V` ordinaire reste donc strictement natif.

**L'affichage du panneau est différé d'environ 150 ms**, pour qu'un `Cmd-V` ordinaire ne fasse pas clignoter l'overlay. L'ouverture logique reste immédiate, seul l'affichage attend ; le collage, lui, part au relâchement dans tous les cas.

**Trois conséquences que `Ctrl` n'avait pas**, toutes traitées et testées :

- `Cmd-Maj-V`, `Cmd-Opt-V` et `Cmd-Ctrl-V` sont relayés nativement, sans ouvrir l'overlay. Beaucoup d'applications s'en servent pour coller sans mise en forme, et les avaler casserait cette fonction partout.
- La capture immédiate sur `Cmd-C` et `Cmd-X` ne se déclenche, et l'événement n'est relayé, **que si l'overlay est fermé**. Ouvert, les touches appartiennent au geste : `X` épingle et est consommée, donc `Cmd-X` n'atteint jamais l'application et ne coupe rien.
- Le nombre d'entrées n'est relu qu'au moment du `V`, pas à chaque appui sur `Cmd`, sinon chaque raccourci de la machine coûterait une requête SQLite.

---

## 2. Architecture · cinq modules isolés

Chaque module a une seule raison d'exister, une interface explicite, et se teste sans les autres. Aucun ne connaît l'interface graphique sauf `Overlay`.

```
        NSPasteboard.general
                 │
        ┌────────▼────────┐
        │    Capture      │  lit, filtre, déduplique
        └────────┬────────┘
                 │  ClipItem
        ┌────────▼────────┐
        │     Store       │  SQLite3, WAL, FTS5 trigram
        └────────┬────────┘
                 │  requêtes
   CGEventTap    │
        │   ┌────▼───────┐
   ┌────▼───┴───┐        │
   │  HotKey    │───────►│  Overlay  │  NSPanel non activant, vues SwiftUI
   │ (états)    │        └─────┬─────┘
   └────────────┘              │
                        ┌──────▼─────┐
                        │   Paste    │  Cmd-V synthétique
                        └────────────┘
```

Flux nominal : un timer détecte un changement de `changeCount`, `Capture` lit la représentation la plus riche et la filtre, `Store` la déduplique et l'indexe. Plus tard, `HotKey` détecte Ctrl maintenu et pilote `Overlay`, qui interroge `Store`. Au relâchement de Ctrl, `Paste` écrit l'élément choisi dans le presse-papiers et synthétise un Cmd-V vers l'application qui n'a jamais perdu le focus.

---

## 3. Capture

**Mécanisme.** macOS ne fournit aucune notification de changement du presse-papiers, confirmé par les quatre implémentations lues. Tout le monde interroge `NSPasteboard.general.changeCount` en boucle.

**Cadence, et pourquoi Copyclipzer peut faire mieux que tout le corpus.** Les sources se contredisent : 200 ms pour Pasteboard Viewer, 280 ms pour CrossPaste, 500 ms pour Maccy, et aucune ne mesure le coût réel. Elles sont toutes coincées dans le même arbitrage : interroger souvent coûte du CPU, interroger rarement rate ou retarde une copie. Or elles sont coincées parce qu'aucune d'elles n'a de tap clavier.

**Copyclipzer en a un**, puisque le maintien de Ctrl l'exige de toute façon. Le même `CGEventTap` voit donc passer Cmd-C et Cmd-X, et peut déclencher une lecture **immédiate** du presse-papiers au lieu d'attendre le prochain tour de timer. D'où une capture hybride :

- **Cmd-C ou Cmd-X vus par le tap** : lecture immédiate, latence perçue nulle. C'est l'écrasante majorité des copies.
- **Timer lent, 0,5 seconde, en filet de sécurité** : rattrape tout ce qui ne passe pas par le clavier, c'est-à-dire le menu Édition, le glisser-déposer, les Services, `pbcopy`, et les applications qui écrivent dans le presse-papiers toutes seules, SuperWhisper compris (voir ci-dessous).

Le tap n'est utilisé qu'en **observation** pour Cmd-C : il ne consomme pas l'événement, la copie se fait normalement. Résultat : latence meilleure que Maccy et consommation quatre fois moindre, avec la même exhaustivité. Ces deux chiffres restent à mesurer avant d'être annoncés.

**Dictées SuperWhisper, et pourquoi le filet est passé à 0,5 s.** Mesuré le 2026-09-28 : sur 51 dictées de trois jours, 2 seulement étaient en base. Les logs `CFPasteboard` donnent la cause. SuperWhisper écrit chaque dictée dans le presse-papiers en la marquant `org.nspasteboard.TransientType` tant que son réglage « Clipboard history » est désactivé, puis restaure le contenu précédent 1,01 s plus tard. Le marqueur fait sauter la dictée à la politique d'exclusion, et la restauration la retire avant le prochain tour d'un filet d'une seconde. Réglage activé, le marqueur ne couvre plus la dictée et seule la fenêtre d'une seconde subsiste : avec un filet de même période, le tick pouvait tomber juste avant l'écriture puis juste après la restauration. À 0,5 s, la fenêtre contient deux ticks. Après les deux changements, les deux dictées suivantes sont entrées en base. Coût mesuré du filet à 0,5 s : 0,05 % de CPU en moyenne sur deux minutes.

**Choix de la représentation**, la première trouvée gagne :

1. `.fileURL` (un ou plusieurs fichiers)
2. `.tiff` ou `.png` (image)
3. `.rtf` (texte riche), en conservant la version texte brut pour l'index et pour le mode Z
4. `.string` (texte brut)

**Exclusions, avant toute écriture en base.** C'est l'objection numéro un du corpus, posée trois fois indépendamment dans le seul fil Maccy.

- Type `org.nspasteboard.ConcealedType` présent : ignorer. Convention respectée par les gestionnaires de mots de passe.
- Types `org.nspasteboard.TransientType` et `org.nspasteboard.AutoGeneratedType` : ignorer.
- Application source dans une liste noire d'identifiants de bundle, relevée au moment de la capture via `NSWorkspace.shared.frontmostApplication`.
- **Le cas du terminal : le mécanisme reste, l'outil livré a été retiré.** Un secret copié depuis `pass` ou `openssl` n'expose aucun de ces marqueurs, et l'application source (Terminal, iTerm) sert aussi à tout le reste : le corpus entier déclare le cas insoluble. La porte de sortie reste le marqueur `org.nspasteboard.ConcealedType` : vérifié sur la machine le 2026-08-25, un simple binaire en ligne de commande peut l'écrire, et Copyclipzer ignore alors l'entrée. Copyclipzer a un temps livré `ccopy`, un `pbcopy` qui posait ce marqueur ; il a été retiré le 2026-10-06, au profit d'un projet 100% open source sans binaire supplémentaire à distribuer. Pour les commandes qu'on ne contrôle pas, deux filets restent : un raccourci « oublie la dernière entrée », et une règle par expression régulière optionnelle désactivée par défaut.

**Presse-papiers universel, et la moitié du cross-device offerte dès la v1.** Le type `com.apple.is-remote-clipboard` signale un contenu arrivé par Handoff, détail relevé dans CrossPaste. Conséquence qui mérite d'être dite en clair : **ce que l'utilisateur copie sur son iPhone arrive déjà tout seul sur le presse-papiers du Mac**, donc notre capture l'enregistre, l'indexe et le garde. Le sens iPhone vers Mac est donc couvert dès la v1, sans une seule ligne de code iOS, à la condition d'Apple que les deux appareils soient à proximité et Handoff actif. Ce qui reste à la v2 est l'autre sens, Mac vers iPhone avec historique. On marque ces entrées `isRemote` pour, en v2, ne pas renvoyer sur l'iPhone ce qui en venait.

**Déduplication.** Si l'empreinte du contenu égale celle de l'entrée la plus récente, on remonte sa date au lieu d'insérer un doublon. Clipy documente que 1Password et le presse-papiers universel sont les deux sources classiques de doublons.

```swift
/// Source de presse-papiers injectable, pour que la capture se teste sans NSPasteboard.
protocol PasteboardReading {
    var changeCount: Int { get }
    func read() -> RawSnapshot?
}
```

---

## 4. Store · SQLite3 sans dépendance

**Moteur.** `import SQLite3`, l'API C fournie par le système. Mesuré sur la machine le 2026-08-25 : SQLite 3.51.0 avec `ENABLE_FTS5`, et une recherche `trigram` sur sous-chaîne renvoie bien le bon résultat. Une fine couche Swift enveloppe les appels C (ouverture, préparation, liaison, itération, transactions). Compter 200 à 300 lignes, écrites et testées une fois.

WAL activé, une connexion d'écriture et des connexions de lecture, migrations par `PRAGMA user_version` (la convention relevée dans Deck).

```sql
CREATE TABLE item (
  id             TEXT PRIMARY KEY,      -- UUID stable, prêt pour CloudKit
  createdAt      DOUBLE  NOT NULL,
  modifiedAt     DOUBLE  NOT NULL,      -- résolution de conflit en v2
  deviceID       TEXT    NOT NULL,      -- prêt pour la sync
  kind           TEXT    NOT NULL,      -- text | rtf | image | files
  title          TEXT    NOT NULL,      -- extrait lisible, 200 caractères max
  searchText     TEXT,                  -- ce qui part dans l'index
  contentHash    TEXT    NOT NULL,      -- déduplication
  byteSize       INTEGER NOT NULL,
  sourceBundleID TEXT,
  pinned         INTEGER NOT NULL DEFAULT 0,
  isRemote       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE payload (
  itemID   TEXT PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
  uti      TEXT NOT NULL,
  data     BLOB,        -- NULL si le contenu vit sur disque
  filePath TEXT         -- renseigné au-delà de 1 Mo
);

CREATE VIRTUAL TABLE item_fts USING fts5(
  title, searchText,
  content='item', content_rowid='rowid',
  tokenize='trigram'
);
```

`trigram` plutôt que le tokenizer par défaut parce qu'il trouve une sous-chaîne au milieu d'un mot, ce qu'on veut sur des URL, des identifiants et du code. C'est le choix de Clipy et de Deck.

**Gros contenus.** Au-delà de 1 Mo, la charge utile part dans `~/Library/Application Support/Copyclipzer/blobs/<id>` et seule la référence reste en base. Motif mesuré : un utilisateur a quitté Maccy pour des problèmes de mémoire, et la lenteur à attraper une copie est le pire défaut possible de ce produit.

**Rétention.** 1000 entrées par défaut plus toutes les épinglées, purge à l'ouverture et une fois par heure. Réglable.

**Prêt pour la synchro sans la construire.** `id`, `modifiedAt` et `deviceID` existent dès la v1. Le patron `userModificationDate` de l'échantillon officiel Apple résout l'ordre réel des copies. Coût aujourd'hui : trois colonnes. Coût si on ne le fait pas : une migration de toute la base.

---

## 5. HotKey · la machine à états

Le module le plus délicat, et celui qui porte tout le confort du produit.

**Pourquoi pas le patron de QuickTasks.** `GlobalHotKey.swift` utilise `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`. Ce moniteur **observe** mais ne **consomme** pas : les touches atteignent quand même l'application dessous. Ici, V, les chiffres, Z et X doivent être avalés pendant que l'overlay est ouvert, donc il faut un `CGEvent.tapCreate` sur `.cgSessionEventTap` qui retourne `nil` sur les événements traités. Le patron de suivi des modificateurs de QuickTasks (armement, `intersection`, désarmement) est repris tel quel, seul le transport change.

**Permission.** Le tap consommateur exige **Accessibilité**, seule permission système du projet. Écran d'accueil explicite, `AXIsProcessTrusted()` interrogé périodiquement, réarmement dès que l'autorisation arrive.

**États.**

```
inactif
   │  flagsChanged, Ctrl enfoncé
   ▼
armé  ────────────────────────────► inactif   (Ctrl relâché sans V)
   │  keyDown V   (événement consommé)
   ▼
ouvert   l'overlay est affiché, index = 0
   │
   │  V ou flèche bas   index + 1
   │  flèche haut       index - 1
   │  2 à 9             index = chiffre - 1
   │  Z                 bascule collage en texte brut
   │  X                 épingle ou supprime l'entrée courante
   │  Échap             ferme, ne colle rien
   │  flagsChanged, Ctrl relâché
   ▼
collage  ──► inactif
```

La machine à états est **pure** : elle reçoit des événements décrits par un type maison et rend des actions. Elle ne connaît ni CGEvent ni AppKit, donc elle se teste intégralement sans interface graphique, et c'est un des fichiers symlinkés dans la cible de test.

**Le piège à traiter d'emblée.** Le système désactive un tap trop lent, avec `.tapDisabledByTimeout`. Sans surveillance, les raccourcis cessent silencieusement de fonctionner au bout de quelques jours. Le module réactive le tap et journalise l'incident.

---

## 6. Overlay

**Une seule propriété compte** : le panneau ne doit **jamais** prendre le focus, sinon l'application cible le perd et le collage part au mauvais endroit.

```swift
let panel = NSPanel(contentRect: …,
                    styleMask: [.nonactivatingPanel, .borderless],
                    backing: .buffered, defer: false)
panel.level = .popUpMenu
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.hidesOnDeactivate = false
panel.contentView = NSHostingView(rootView: OverlayView(...))
// canBecomeKey reste false : les touches viennent du CGEventTap, pas du panneau
```

Le contenu est une vue SwiftUI dans un `NSHostingView`, exactement comme QuickTasks héberge ses vues. Les touches ne sont pas lues par le panneau mais par le tap du module `HotKey`, précisément parce que le panneau n'est jamais clé.

**Rendu.** Reprend les mesures de `SearchPanel.swift` : fond `.regularMaterial`, coins à 10, bordure `primary.opacity(0.1)`, ombre `radius: 12, y: 4`, marge externe 12. Une ligne par entrée : rang, icône SF Symbol du type, et un aperçu réel. Le reproche adressé à Maccy sur Hacker News est nommément l'absence d'aperçu visuel des images et du texte riche, donc la vignette et l'icône de fichier ne sont pas un ornement, ce sont les fonctions demandées.

**Position.** Sous le curseur de texte si l'API d'accessibilité le donne, sinon au centre de l'écran actif.

---

## 7. Paste

1. Sauvegarder le contenu courant du presse-papiers (patron save/restore relevé dans Copi).
2. Écrire l'élément choisi dans `NSPasteboard.general`, en texte brut si le mode Z est actif.
3. Synthétiser Cmd-V : un `CGEvent` clavier avec `flags = .maskCommand`, posté sur `.cghidEventTap`.
4. Marquer l'événement synthétique d'un bit dédié pour que `Capture` reconnaisse sa propre écriture et ne la réenregistre pas. **Correction du 2026-08-26, vérifiée dans le SDK** : `0x000008` est `NX_DEVICELCMDKEYMASK`, le bit « Commande gauche » que le système pose sur tout événement matériel. L'utiliser comme marqueur ferait passer un vrai Cmd-C de la main gauche pour un événement synthétique, ce qui tuerait la capture instantanée. Flycut le pose sur son Cmd-V pour que les applications récalcitrantes acceptent le collage, pas pour se reconnaître : le plan avait inversé sa raison d'être. L'identification passe par `event.setIntegerValueField(.eventSourceUserData, value:)`.
5. **Ne pas restaurer le presse-papiers, par défaut.** Correction du 2026-08-26 : la garde sur `changeCount` couvre le cas où l'application cible ÉCRIT, mais pas celui où elle LIT tard. Une application dont le thread principal est occupé lit le presse-papiers 300 ms après avoir reçu le Cmd-V, alors que nous avons restauré à 120 ms : elle colle l'ancien contenu, silencieusement. Maccy et Pastebot laissent l'entrée choisie dans le presse-papiers, et c'est ce que l'utilisateur attend d'un gestionnaire d'historique. La restauration reste disponible en option explicite, avec sa garde, qui reste correcte pour ce qu'elle mesure.

⚠ Contradiction non tranchée dans la veille : Maccy prouve que CGEvent passe le sandbox du Mac App Store, l'issue #171 de PastePal dit que l'entitlement casse le collage synthétique. Sans objet ici puisque l'application n'est pas sandbox, mais à retenir si la distribution change.

---

## 8. Gestion des erreurs

| Situation                          | Comportement                                                                                                                                  |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Autorisation Accessibilité absente | L'application est inutilisable sans elle. Écran d'accueil explicite, `AXIsProcessTrusted()` interrogé périodiquement, réarmement automatique. |
| Tap désactivé par le système       | Réactivation automatique, incident journalisé. Sans ça, panne silencieuse.                                                                    |
| Lecture du presse-papiers en échec | Une autre application le détient. Repli exponentiel et nouvelle tentative, patron relevé dans CrossPaste. Jamais d'écriture partielle.        |
| Contenu démesuré                   | Plafond à 50 Mo. Au-delà, l'entrée est ignorée et journalisée, pas tronquée.                                                                  |
| Migration de base en échec         | La base est sauvegardée à côté, une base neuve est créée. Jamais de boucle de plantage au démarrage.                                          |
| Blob manquant sur disque           | L'entrée s'affiche en grisé et se supprime proprement. Base et dossier de blobs peuvent diverger.                                             |

---

## 9. Tests

Convention QuickTasks : cible `.executableTarget` nommée `CopyclipzerTests`, lancée par `swift run CopyclipzerTests`, avec les fichiers de logique pure symlinkés depuis `Sources/`. Pas de XCTest, donc pas d'Xcode.

Ce qui se teste sans interface graphique :

- **Store** : migrations, déduplication, requêtes FTS, purge de rétention, bascule blob vers disque au-delà du seuil. Base en mémoire.
- **Capture** : injection d'un faux presse-papiers via `PasteboardReading`. Tous les cas d'exclusion, le choix de la représentation la plus riche, la déduplication.
- **Machine à états HotKey** : entièrement pure, donc chaque transition du diagramme est un test.

**Tests par sabotage, obligatoires.** Pour chaque garantie, neutraliser la garde et vérifier que le test tombe :

- Retirer l'exclusion `ConcealedType` : le test « un mot de passe n'entre jamais en base » DOIT échouer.
- Retirer le marquage de l'événement synthétique : le test « un collage ne se réenregistre pas » DOIT échouer.
- Retirer la déduplication : le test « deux copies identiques ne font qu'une entrée » DOIT échouer.

Une garantie dont le sabotage laisse les tests verts n'est pas testée, et le code correspondant doit être supprimé plutôt que gardé.

**Ce qui ne se teste pas automatiquement**, et fait l'objet d'une liste de vérification manuelle avec captures dans `screenshots/` : le CGEventTap réel, le panneau non activant qui ne vole pas le focus, et le collage qui arrive dans la bonne application. Ce sont les trois endroits où le produit peut être vert en tests et cassé à l'écran.

---

## 10. Limitations levées, mesurées le 2026-08-25

Quatre points étaient annoncés comme des limites. Chacun a été repris, et trois sont tombés par la mesure plutôt que par l'argument.

| Limite annoncée                                                      | Verdict                           | Solution retenue                                                                                                                                                                    |
| -------------------------------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pas de notification système, donc arbitrage entre latence et CPU     | **Levée**                         | Le tap clavier requis par le geste Ctrl voit aussi Cmd-C : lecture immédiate, plus un timer lent en filet. Aucun projet du corpus ne peut le faire, faute de tap. Voir §3.          |
| Secrets copiés en ligne de commande, insolubles selon tout le corpus | **Mécanisme connu, outil retiré** | Le marqueur `org.nspasteboard.ConcealedType` est respecté : une entrée qui le porte est ignorée. Le binaire `ccopy` qui le posait a été retiré le 2026-10-06 (projet open source, aucun binaire à distribuer). Voir §3.                       |
| `NSHostingView` dans un panneau non activant, risque inconnu         | **Levée, mesuré**                 | Spike exécuté : Firefox reste au premier plan, `isKeyWindow` à `false`, `canBecomeKey` à `false`, et la vue SwiftUI se dessine correctement au style QuickTasks. Capture à l'appui. |
| Course à la restauration du presse-papiers après collage             | **Levée**                         | Garde exacte sur `changeCount` au lieu d'un délai deviné. Restauration redevient le comportement par défaut. Voir §7.                                                               |

## 11. Ce qui reste vraiment ouvert

1. **Les deux chiffres de la capture hybride.** Latence réelle sur Cmd-C et consommation du timer de secours : annoncés comme meilleurs que le corpus, donc à mesurer avant d'être affirmés. Premier banc à écrire.
2. **La capture automatique sur iPhone.** Toujours sans solution propre, et ce n'est pas faute d'avoir cherché : `rileytestut/Clip` cumule mode `location`, API privée et distribution hors App Store, et exige quand même un geste par copie. Le moins mauvais chemin reste le Picture-in-Picture, qui garde l'app active. Sujet de v2, pas de v1.
3. **La rétention native de Spotlight sur macOS 26.1.** Chiffre périmé dans la veille. Sans effet sur l'architecture, utile au positionnement.

---

## 12. v1.1 · agir sur une entrée, et voir ce qu'elle contient

Décidé le 2026-08-31, après lecture de la v1 en état de marche. Trois manques constatés à l'écran, pas déduits du code : le menu ne montre qu'un titre coupé à 120 caractères sans moyen de voir la suite, une entrée capturée par erreur ne peut pas être supprimée, et l'épinglage est câblé de bout en bout sauf l'appel qui l'exécute.

### 12.1 Ce qui coûte cher, et pourquoi on le paie quand même

Le geste retenu est celui que tout le monde connaît : les actions apparaissent **à droite de la ligne au survol**, et on clique dessus. `NSMenu` ne sait pas le faire. Une ligne de menu native est une chaîne, une image et un raccourci, rien d'autre. Chaque ligne doit donc devenir une **vue personnalisée** (`NSMenuItem.view`), et tout ce que macOS dessinait gratuitement passe à notre charge : la surbrillance de la ligne survolée, l'alignement du raccourci ⌘1 à ⌘9, l'état désactivé, les marges exactes du menu, et le survol lui-même via une `NSTrackingArea` dans la boucle d'événements modale du menu.

Deux conséquences suivent, et elles sont dans le plan avant d'être dans le code.

**Le coût de reconstruction.** Le menu se refabrique à chaque frappe dans le champ de recherche. Cinq cents `NSMenuItem` nus, c'est instantané ; cinq cents vues personnalisées avec leurs zones de suivi, non. La parade est un **pool de vues réutilisées** : au lieu de `removeAllItems()` suivi d'une refabrication complète, les vues survivent et seul leur contenu se rebranche. Le plafond de cinq cents lignes demandé le 2026-08-26 reste intact, c'est la façon de le servir qui change.

**Le trou de test.** `AppDelegate.swift` n'est couvert par aucun test, par construction assumée : c'est le seul fichier qui connaît tous les modules, et rien de ce qui s'y décide ne serait mesurable. La règle des fichiers purs tient donc ici aussi. Ce qui se DÉCIDE, à savoir quels boutons existent, avec quel libellé, dans quel état, pour quel rang, et ce que montre l'aperçu, vit dans `MenuFormat.swift`, pur et testé. Ce qui se DESSINE reste dans AppKit, mince, et se vérifie en regardant l'écran avec une capture à l'appui.

### 12.2 L'aperçu ne lit aucune charge utile

`CaptureService` écrit `title: String(texte.prefix(200))` mais `searchText: texte`, **sans troncature**. Le texte complet est donc déjà en base, déjà rendu par la requête du menu, déjà en mémoire au moment du survol. L'aperçu s'en sert et ne touche jamais à `payload`. La règle de `MenuFormat.swift`, « aucune charge utile n'est lue à l'ouverture », survit intacte : ouvrir le menu ne charge toujours pas cinq cents images.

Le rendu est un **panneau flottant à droite du menu**, et non l'infobulle système. L'infobulle coûtait dix minutes, mais impose un délai d'environ une seconde, ne rend que du texte brut et ne montrera jamais une image. Une fois la vue personnalisée payée par les boutons, le panneau devient une rallonge, et c'est lui qui accueillera la vignette le jour où elle existera.

Plafonds de l'aperçu : quarante lignes et deux mille caractères, ellipse au-delà. Sans eux, un fichier de log copié ferait un panneau haut comme trois écrans. Pied de panneau : type, taille, date, application source. Pour une image, ce pied est la **seule** information lisible, parce qu'une image copiée n'a pas de texte, donc son `title` est la chaîne vide et sa ligne de menu est aujourd'hui vide. D'où le titre de secours synthétique, dans le même fichier pur.

### 12.3 L'overlay se fige quand la souris entre

L'overlay Cmd-V n'existe que tant que Cmd est enfoncé : le relâchement colle et ferme. Y poser des boutons cliquables sans rien changer d'autre obligerait à tenir Cmd d'une main et la souris de l'autre, et le moindre relâchement collerait l'entrée au lieu de la supprimer, c'est-à-dire l'inverse exact de l'intention.

`HotKeyMachine` gagne donc un **état figé** : dès que la souris entre dans le panneau, `modificateurUp` ne colle plus et ne ferme plus, et la sortie se fait par Échap ou par un clic hors du panneau. C'est le seul endroit du projet où la machine à états s'étend, et c'est le fichier le plus testé : l'extension arrive avec ses tests et son sabotage, à savoir que neutraliser le figé doit faire tomber « relâcher Cmd pendant le survol ne colle pas ».

La touche X, déjà traduite et déjà avalée par la machine depuis la v1, est enfin branchée sur `Store.setPinned`. Le clavier reste le chemin principal pendant un geste clavier ; les boutons sont le chemin de la souris.

### 12.4 Hors de ce lot, volontairement

Les vignettes d'images réelles, l'icône de l'application source sur chaque ligne, l'écran de préférences (liste noire d'applications, rétention, délai d'affichage) et les transformations au collage. Tous documentés, aucun engagé.
