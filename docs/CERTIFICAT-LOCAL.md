# Le certificat local, et l'autorisation Accessibilité

Copyclipzer exige l'autorisation **Accessibilité** pour son tap clavier : sans elle, le geste Cmd est inutilisable. `build.sh` signe le bundle avec un certificat auto-signé local, `Copyclipzer Local`, dont l'exigence désignée ne cite aucun binaire :

```
designated => identifier "io.github.copyclipzer" and certificate leaf = H"26b239c07f23c24385da3184e31cc7a0f08eefa1"
```

Conséquence voulue : une autorisation accordée une fois survit aux reconstructions. Mesuré le 2026-09-28 : rebuild, remplacement dans /Applications et relance, le journal affiche `accessibilité accordée` et `tap clavier démarré` (`~/Library/Logs/Copyclipzer/copyclipzer.log`, ouvrable depuis le menu de l'icône : « Afficher le journal »).

## Le piège du doublon de bundle

`build.sh` monte le bundle **dans le dossier du projet** (`./Copyclipzer.app`), puis `install.sh` le copie vers `/Applications/Copyclipzer.app`. Les deux copies portent le même identifiant `io.github.copyclipzer`. Si une coche Accessibilité vise la copie du projet, l'app lancée depuis /Applications n'est pas autorisée, et le symptôme est trompeur : le geste Cmd ne marche « que de temps en temps », c'est-à-dire quand la coche et le binaire lancé tombent sur la même copie.

Règle : **ne jamais ajouter le bundle du dossier projet dans Accessibilité**. L'app canonique est `/Applications/Copyclipzer.app`, et c'est la seule à cocher. Le bundle du projet peut rester sur le disque (il est gitignore) ou être supprimé, `build.sh` le recrée.

## Réparer une autorisation perdue

1. `tccutil reset Accessibility io.github.copyclipzer`
2. Relancer l'app : `open /Applications/Copyclipzer.app`. Le dialogue système propose d'ouvrir les Réglages.
3. Réglages Système > Confidentialité et sécurité > Accessibilité : ajouter `/Applications/Copyclipzer.app` (bouton plus) puis cocher.
4. Vérifier : le tap redémarre seul en deux secondes, `[permission] accessibilité accordée, démarrage du tap` puis `[tap] tap clavier démarré` apparaissent dans `copyclipzer.log`, sans relance. Un refus du système s'y lit en `ERREUR [tap] création du tap clavier REFUSÉE`, retenté toutes les cinq secondes. Procédure exécutée le 2026-09-28.

## Recréer le certificat s'il disparaît du trousseau

Le certificat actuel : `CN=Copyclipzer Local`, auto-signé, EKU Code Signing, émis le 26/08/2026, expire le 23/08/2036, SHA-1 `26B239C07F23C24385DA3184E31CC7A0F08EEFA1`. Il vit dans le trousseau de session, utilisable par `codesign` (il peut apparaître `CSSMERR_TP_NOT_TRUSTED` dans `find-identity -v`, ce que la signature et TCC tolèrent : ce qui compte est le leaf, pas la chaîne).

Toute recréation change le leaf : l'exigence désignée change aussi, et l'autorisation TCC devra être redonnée (section précédente). La recette de recréation n'a pas été rejouée depuis le 26/08/2026 : la consigner ici quand elle le sera, plutôt que de la deviner maintenant.
