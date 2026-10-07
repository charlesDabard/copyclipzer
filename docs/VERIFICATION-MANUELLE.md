# Vérification manuelle de Copyclipzer

Ce que le shell ne peut pas mesurer, et qui doit donc passer par l'écran. Chaque point donne le geste exact et le résultat attendu. Un point qui ne rend pas le résultat attendu est un défaut, pas une approximation.

### Avant de commencer

L'application doit être lancée : `open Copyclipzer.app`, ou `open /Applications/Copyclipzer.app` après `./install.sh`.

**Piège de la signature ad-hoc.** `build.sh` signe avec une identité qui change à chaque construction. macOS cesse alors d'honorer l'autorisation Accessibilité **sans décocher la case**, ce qui donne une application muette avec une case cochée. Après chaque reconstruction : Réglages Système, Confidentialité et sécurité, Accessibilité, retirer Copyclipzer avec le bouton moins, puis le rajouter.

### 1. L'icône dans la barre des menus

Geste : regarder la barre des menus, à droite.

Attendu : une icône presse-papiers (`doc.on.clipboard`). Un clic ouvre l'historique cherchable décrit au point 10. Aucune icône dans le Dock, aucun menu d'application en haut à gauche : c'est ce que `LSUIElement` et `.accessory` garantissent.

Si l'icône est absente alors que le processus tourne (`pgrep -x Copyclipzer`), la cause la plus probable sur un Mac à encoche est une barre des menus pleine : les extras en trop passent derrière l'encoche. Quitter une autre application de barre suffit à trancher.

### 2. L'autorisation Accessibilité

Geste : au premier lancement, macOS ouvre une boîte de dialogue. L'accorder, puis cocher Copyclipzer dans Réglages Système, Confidentialité et sécurité, Accessibilité.

Attendu : **l'application n'a pas besoin d'être relancée.** `Permissions.surveiller` interroge toutes les deux secondes et arme le tap dès que la case est cochée. Si le raccourci ne répond toujours pas dix secondes après, c'est un défaut : le tap n'a pas démarré, et `log stream --predicate 'process == "Copyclipzer"'` doit alors montrer `Copyclipzer : le tap clavier n'a pas démarré`.

### 3. Le geste complet, dans TextEdit

Le geste s'arme sur **Cmd** depuis le 2026-08-26, et non plus sur Ctrl : voir la section 3 bis, qui est la contrepartie directe de ce déplacement et le point le plus important de toute cette page.

1. Copier trois textes différents avec Cmd-C. Attendu : rien de visible, la capture est silencieuse.
2. Maintenir Cmd, appuyer sur V, **et garder Cmd enfoncé**. Attendu : l'overlay s'affiche au centre avec les trois entrées après un délai d'environ 150 ms, et **aucun `v` ne s'écrit dans le document**.
3. Sans relâcher Cmd, regarder le document. Attendu : **le curseur clignote toujours dans TextEdit.** C'est le point qui prouve que le panneau ne vole pas le focus, cf. le point 6 plus bas.
4. Appuyer sur 2. Attendu : la sélection descend sur la deuxième ligne, et **aucun `2` ne s'écrit**.
5. Relâcher Cmd. Attendu : le deuxième texte est collé dans TextEdit, à l'endroit du curseur.
6. Recommencer, et appuyer sur Z avant de relâcher Cmd. Attendu : la mention « collage en texte brut » apparaît en bas de l'overlay, **et le panneau grandit pour la contenir**, sans que la mention soit rognée. Relâcher : le collage arrive sans mise en forme.
7. Recommencer, et appuyer sur Échap. Attendu : l'overlay se ferme, **rien n'est collé**, et Cmd relâché ensuite ne colle rien non plus.
8. Ouvrir l'overlay et appuyer sur une touche non prévue, par exemple Q. Attendu : rien ne se passe, et **aucun `q` ne s'écrit dans le document**.
9. Overlay fermé, essayer un raccourci Cmd ordinaire dans TextEdit, par exemple Cmd-S ou Cmd-Z. Attendu : il fonctionne normalement. Le tap ne doit avaler que ce que la machine consomme.

### 3 bis. Ce que le passage à Cmd ne doit RIEN changer

Cmd-V est le collage du système, donc chaque collage de la machine traverse désormais le tap. Ces six points sont la contrepartie du déplacement, et aucun n'est facultatif : ils portent sur des gestes faits des dizaines de fois par jour, et un seul d'entre eux qui échoue rend l'application inutilisable dans un usage réel.

1. **Le Cmd-V ordinaire.** Cmd-V rapide, comme d'habitude, sans jamais maintenir Cmd. Attendu : le collage arrive normalement, **et l'overlay n'apparaît jamais, pas même un clignotement**. C'est ce que l'affichage différé de 150 ms garantit.
2. **La fidélité d'une image.** Copier une image (capture d'écran avec Cmd-Maj-4), puis Cmd-V rapide dans Aperçu ou Mail. Attendu : l'image arrive intacte. Le relais natif ne touche pas au presse-papiers, donc rien ne peut y perdre de types.
3. **La fidélité de fichiers.** Copier trois fichiers dans le Finder, puis Cmd-V rapide dans un autre dossier. Attendu : les trois fichiers arrivent, pas un seul, pas un chemin en texte.
4. **Ctrl-V rendu à ses outils.** Dans Claude Code, coller une image avec Ctrl-V. Attendu : **ça marche**, sans quitter Copyclipzer. C'est le défaut d'usage qui a motivé toute cette tâche.
5. **Coller sans mise en forme.** Cmd-Maj-V dans une application qui le prend en charge. Attendu : le collage arrive sans mise en forme, **et l'overlay ne s'ouvre pas**. Idem Cmd-Opt-V.
6. **Les raccourcis du quotidien.** Cmd-C, Cmd-X, Cmd-S, Cmd-Z, Cmd-Q, Cmd-Tab, Cmd-1. Attendu : tous se comportent exactement comme avant l'installation.

**Un cas connu, à constater et non à corriger.** Overlay ouvert, la touche X n'épingle plus : Cmd étant enfoncé, la frappe est un Cmd-X, donc une coupe. L'aiguillage la traite en capture puis la relaie, et **elle coupe la sélection dans l'application de dessous**. L'épinglage n'a aucun effet en v1 (`Store` n'expose pas la bascule), donc la fonction perdue est nulle, mais la coupe, elle, est bien réelle. Ne pas appuyer sur X pendant l'overlay tant que ce point n'est pas tranché.

### 4. La signature de nos événements synthétiques (mesure bloquante)

C'est la seule mesure du projet qui n'a jamais pu être faite, ni en test ni au banc d'essai : le shell n'a pas l'autorisation Accessibilité, donc `CGEvent.post` y est rejeté en silence, et le seul substitut testable, l'aller-retour par `CGEventCreateData`, perd le champ.

Geste : dans un terminal, application lancée,

    log stream --predicate 'process == "Copyclipzer"'

puis faire un Cmd-C à la main, puis faire un collage complet par le geste (Cmd maintenu, V, un chiffre, relâcher). Chercher les lignes `Copyclipzer MESURE :`.

Attendu :

- sur le Cmd-C tapé à la main : `signature=0`. Un événement matériel ne porte rien dans `eventSourceUserData` ;
- sur le Cmd-V que Copyclipzer synthétise : `signature=434c5a5031`.

Si le second ressort à `0`, la signature ne survit pas au passage par le tap. Conséquence : `estSynthetique` rend toujours `false`, notre propre Cmd-V est soumis à la machine, et si Cmd est ré-enfoncé au mauvais moment l'overlay se rouvre en avalant son propre collage, donc rien n'est collé. Le repli documenté est `eventSourceUnixProcessID`, journalisé sur la même ligne. **Ne basculer que sur cette mesure.**

Le `NSLog` est temporaire : le retirer de `EventTap.traiter` une fois la mesure faite, le commentaire qui l'entoure dit où.

### 5. Le tap survit à une désactivation par le système

macOS désactive un tap qui répond trop lentement, et sans rattrapage les raccourcis cessent **silencieusement** de marcher au bout de quelques jours. C'est le piège classique de `CGEventTap`, et le rattrapage est écrit mais n'a jamais été vu s'exécuter.

Geste : provoquer une désactivation en chargeant lourdement la machine pendant une frappe, ou plus simplement laisser l'application tourner plusieurs jours et réessayer le geste. Surveiller le journal.

Attendu : à chaque désactivation, la ligne `Copyclipzer : tap réactivé après désactivation par le système` apparaît, **et le geste refonctionne aussitôt**. Un geste qui ne répond plus sans cette ligne dans le journal est un défaut grave.

### 6. Le panneau ne vole pas le focus

Geste : ouvrir l'overlay par-dessus TextEdit, puis par-dessus une autre application, par exemple Firefox ou Mail.

Attendu : dans les deux cas, la barre de titre de l'application de devant **reste active** (pas grisée), le curseur continue de clignoter dans son champ de saisie, et l'overlay se dessine par-dessus sans jamais devenir la fenêtre clé. C'est ce qui rend le maintien de Cmd possible : les touches n'arrivent pas par le panneau mais par le tap.

Mesuré une fois au banc d'essai le 2026-08-25, sur Firefox, preuve dans `screenshots/2026-08-25-spike-panneau-non-activant.png`. À reconfirmer sur l'application assemblée, parce que le panneau y est désormais retenu par le délégué et non plus par un banc d'essai.

### 7. Le collage arrive dans la BONNE application

Geste : ouvrir TextEdit et une seconde application avec un champ de saisie, par exemple Notes. Cliquer dans TextEdit, faire le geste complet, vérifier. Recommencer depuis Notes.

Attendu : le texte arrive **dans l'application où le curseur était avant l'ouverture de l'overlay**, jamais dans l'autre, jamais nulle part. Le Cmd-V synthétique part vers l'application de devant : si le panneau avait volé le focus, il partirait dans le vide, et c'est le mode d'échec que le point 6 prévient.

À vérifier aussi : **l'entrée collée reste dans le presse-papiers.** Un Cmd-V ordinaire juste après doit recoller la même chose. La restauration de l'ancien contenu n'est plus le défaut depuis le 2026-08-26, précisément parce qu'elle rendait le résultat faux et silencieux avec les applications qui lisent le presse-papiers tard.

### 8. Pas de doublon dans l'historique

Geste : coller une entrée RTF en texte brut (touche Z), puis rouvrir l'overlay.

Attendu : **aucune nouvelle entrée** n'est apparue en tête de liste. Notre propre écriture dans le presse-papiers ne doit pas revenir en base, c'est ce que `capture.ignorerJusqua` empêche. Un doublon texte en tête de liste après chaque collage en texte brut est le symptôme exact d'un `Paster` construit sans son `capture:`.

### 9. Capture d'écran à ranger

Geste : overlay ouvert par-dessus TextEdit, `screencapture -i` ou Cmd-Maj-4.

Attendu : le fichier va dans `screenshots/` du projet, nommé avec la date, par exemple `screenshots/2026-08-26-overlay-sur-textedit.png`.

### 10. Le menu de barre est un historique cherchable (tâche 16)

Trois choses ne se testent pas et n'ont donc AUCUN test : le rendu réel du `NSMenu`, le focus du champ de recherche à l'ouverture, et le fait qu'un clic écrive vraiment dans `NSPasteboard`. Ce point est leur seule mesure. Ce qui est mesuré par les tests, en revanche, c'est l'ordre, le plafond de 500 et le filtrage, tous trois dans `Sources/Overlay/MenuFormat.swift`.

Préalable : avoir copié une dizaine de textes différents, dont un texte de plus de trois lignes et une image (Cmd-Maj-4 puis Cmd-C, ou une capture dans le presse-papiers).

1. **La liste s'ouvre.** Cliquer sur l'icône de la barre. Attendu : un champ « Rechercher » en tête, puis les entrées de l'historique, la plus récente en premier, numérotées à partir de 1, chacune avec l'icône SF Symbol de son type (`textformat.abc` pour du texte, `photo` pour une image). En bas : un séparateur, puis « Quitter ».
2. **Le champ prend le focus tout seul.** Sans cliquer dans le champ, taper directement. Attendu : **les lettres s'écrivent dans le champ de recherche**, pas dans l'application de dessous, et rien ne se déclenche dans le menu. Si les lettres n'apparaissent pas, le `makeFirstResponder` différé n'a pas pris et c'est un défaut.
3. **Le filtrage est en direct.** Taper trois lettres présentes dans une seule entrée. Attendu : la liste se réduit **à la frappe**, sans qu'il faille appuyer sur Entrée. Effacer : la liste complète revient.
4. **La recherche en dessous de trois caractères marche aussi.** Taper une ou deux lettres. Attendu : la liste se réduit quand même. C'est le repli `LIKE` de `Store.search` : le tokenizer trigram exige trois caractères, en dessous la requête change de chemin, et l'utilisateur ne doit rien voir de cette bascule.
5. **Un clic COPIE, il ne colle pas.** Cliquer sur une entrée ancienne. Attendu : le menu se ferme, **rien n'est collé nulle part**, et un Cmd-V ordinaire dans TextEdit pose ensuite cette entrée-là. C'est la différence exacte avec le geste Cmd maintenu, qui colle.
6. **L'entrée cliquée remonte en tête.** Rouvrir le menu juste après le point 5. Attendu : l'entrée sur laquelle on vient de cliquer est **la première de la liste**, et **aucun doublon n'est apparu**. C'est l'inverse du collage : ici notre écriture doit être vue par la capture, qui la reconnaît par son `contentHash` et remonte sa date.
7. **Une image se copie comme une image.** Cliquer sur une entrée image, puis Cmd-V dans Aperçu. Attendu : l'image arrive, pas son nom en texte. Même règle de représentation que le collage, `representationAEcrire`.
8. **Le menu s'ouvre vite, même plein.** Après plusieurs jours d'usage, avec quelques centaines d'entrées. Attendu : l'ouverture reste instantanée. Le menu n'affiche que `title`, déjà en base : aucune charge utile n'est lue à l'ouverture, seulement au clic et pour la seule entrée cliquée. Une ouverture qui rame veut dire qu'une lecture de `payload` s'est glissée dans la boucle de construction.
9. **Cmd et un chiffre choisissent une ligne.** Menu ouvert, faire Cmd-3. Attendu : la troisième entrée est copiée. Le modificateur Commande est délibéré : un « 3 » nu serait avalé par le menu au lieu de s'écrire dans le champ de recherche.
10. **Un historique vide le dit.** Sur une base neuve (`~/Library/Application Support/Copyclipzer/history.sqlite` supprimé, application relancée), ouvrir le menu. Attendu : une ligne grisée « Aucune entrée », le champ de recherche, le séparateur et « Quitter ». Jamais un menu qui ne contient que « Quitter » sans explication.
