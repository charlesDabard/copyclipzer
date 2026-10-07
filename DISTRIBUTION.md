# Distribuer Copyclipzer

Copyclipzer est 100% open source et se distribue sans signature Apple payante. Il y a deux publics : l'utilisateur qui installe l'app, et le mainteneur qui publie une version.

## Installer (utilisateur)

Le chemin recommandé est la construction depuis les sources, documentée dans le README : cloner le dépôt puis `./install.sh`. La signature produite par `build.sh` est ad-hoc et locale à la machine qui compile, donc aucune alerte Gatekeeper n'apparaît et aucun binaire signé n'a besoin d'être distribué.

## Publier une version (mainteneur)

1. Mettre à jour `CFBundleShortVersionString` dans `Resources/Info.plist` (c'est le numéro que le check de mise à jour intégré compare à la dernière release publiée).
2. Poser un tag git : `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. Construire et empaqueter : `./build.sh` produit `Copyclipzer.app` à la racine, puis `ditto -c -k --keepParent Copyclipzer.app Copyclipzer.app.zip`.
4. Créer une release GitHub sur ce tag et y attacher `Copyclipzer.app.zip`. Le check de mise à jour de l'app lit la dernière release via l'API GitHub (`/repos/charlesDabard/copyclipzer/releases/latest`) et affiche une pastille quand une version plus récente existe ; il ne télécharge rien tout seul.

## Le zip n'est pas notarisé

Sans compte Apple Developer, le `.app` attaché à une release n'est ni signé Developer ID ni notarisé. Quiconque le télécharge verra l'alerte Gatekeeper et devra la lever à la main : clic droit sur l'app puis Ouvrir, ou `xattr -dr com.apple.quarantine Copyclipzer.app`. C'est la raison pour laquelle le build depuis les sources reste le chemin recommandé : il évite complètement cette friction.

## Signature ad-hoc et autorisation Accessibilité

`build.sh` signe en ad-hoc. L'empreinte de cette signature change à chaque construction, et macOS cesse alors d'honorer l'autorisation Accessibilité sans décocher la case. Après une reconstruction, il faut retirer puis rajouter Copyclipzer dans Réglages Système > Confidentialité et sécurité > Accessibilité. Le détail est dans `docs/CERTIFICAT-LOCAL.md`.
