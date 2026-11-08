# Distribuer Copyclipzer

Copyclipzer est 100% open source et se distribue sans signature Apple payante. Il y a deux publics : l'utilisateur qui installe l'app, et le mainteneur qui publie une version.

## Installer (utilisateur)

Le chemin recommandé est la construction depuis les sources, documentée dans le README : cloner le dépôt puis `./install.sh`. Aucune alerte Gatekeeper n'apparaît, puisque rien n'est téléchargé.

Au premier lancement, une fenêtre fait choisir le raccourci qui ouvre le panneau (fn + ⇧ proposé en premier, quatre combinaisons, ou une combinaison libre enregistrée au clavier). Elle ne se ferme pas sans choix, et un seul raccourci est actif à la fois. Il se change ensuite dans le menu ⚙︎ du panneau.

## Mises à jour (Sparkle)

L'app embarque Sparkle 2 (version figée dans `Package.swift`). Elle vérifie au lancement puis toutes les six heures, télécharge en arrière-plan, vérifie la signature EdDSA de l'archive, et l'installe à la fermeture de l'app, ou tout de suite d'un clic sur la pastille « Installer la X.Y.Z et relancer » du panneau. Le menu ⚙︎ propose trois modes (installer automatiquement, demander avant d'installer, ne pas vérifier) et « Rechercher les mises à jour… ».

Le flux est `https://github.com/charlesDabard/copyclipzer/releases/latest/download/appcast.xml` : l'appcast attaché à la dernière release GitHub. L'archive n'est acceptée que si elle est signée par la clé privée EdDSA du mainteneur, dont la clé publique est figée dans `Resources/Info.plist` (`SUPublicEDKey`). C'est cette clé, et non le certificat de l'app, qui fait foi : quelqu'un qui a construit Copyclipzer avec son propre certificat reçoit quand même les versions publiées.

Limite connue : sans Developer ID, une version publiée est signée par le certificat local du mainteneur. Un utilisateur qui avait construit l'app lui-même doit recocher Copyclipzer dans Réglages Système > Confidentialité et sécurité > Accessibilité après sa première mise à jour ; les suivantes, signées par le même certificat, la gardent.

## Publier une version (mainteneur)

1. Depuis `main` à jour et propre : `./publier-version.sh X.Y.Z`. Le script fixe `CFBundleShortVersionString` et incrémente `CFBundleVersion` (c'est lui que Sparkle compare, il doit grandir à chaque version), construit l'app, refuse une app qui ne serait pas signée « Copyclipzer Local », puis prépare dans `dist/vX.Y.Z/` l'archive, les notes de version (sujets de commit depuis le tag précédent) et `appcast.xml` signé EdDSA.
2. Commiter `Resources/Info.plist` (`chore(release): version X.Y.Z`), ouvrir la PR, la fusionner.
3. Publier la release avec la commande `gh release create` affichée par le script. Elle attache l'archive ET `appcast.xml` : une release sans appcast rend toutes les mises à jour invisibles, puisque « latest » n'en porte plus.

## La clé de signature EdDSA

La clé privée vit dans le trousseau de session du mainteneur, compte `copyclipzer` (créée le 2026-11-08 avec `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account copyclipzer`). Si elle est perdue, plus aucune mise à jour ne peut être publiée vers les installations existantes. En garder une copie hors du Mac : `generate_keys --account copyclipzer -x <fichier>`, fichier à ranger dans un coffre, jamais dans le dépôt.

## Le zip n'est pas notarisé

Sans compte Apple Developer, le `.app` attaché à une release n'est ni signé Developer ID ni notarisé. Une mise à jour installée par Sparkle n'est pas concernée (l'archive téléchargée par l'app ne porte pas l'attribut de quarantaine), mais quiconque télécharge le zip à la main verra l'alerte Gatekeeper et devra la lever : clic droit sur l'app puis Ouvrir, ou `xattr -dr com.apple.quarantine Copyclipzer.app`.

## Signature et autorisation Accessibilité

`build.sh` signe avec le certificat local « Copyclipzer Local » quand il est dans le trousseau, et retombe sur une signature ad-hoc sinon. Une signature ad-hoc change d'empreinte à chaque construction, et macOS cesse alors d'honorer l'autorisation Accessibilité sans décocher la case. Le détail est dans `docs/CERTIFICAT-LOCAL.md`.
