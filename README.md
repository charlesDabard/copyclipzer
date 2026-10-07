# Copyclipzer

Gestionnaire de presse-papiers pour macOS : il garde l'historique de ce que vous copiez et le remet à portée d'un clic ou d'un raccourci. Deux façons d'y revenir : un panneau de recherche ouvert depuis la barre des menus, et un geste rapide en maintenant Cmd. Écrit en Swift, sans dépendance externe, construit avec les seuls Command Line Tools (`swift build`, tests par `swift run CopyclipzerTests`).

## Construire et installer

    ./build.sh          # produit Copyclipzer.app à la racine du projet
    ./install.sh        # construit et installe dans /Applications

L'application n'a pas d'icône dans le Dock (`LSUIElement`) : sa seule surface permanente est l'icône presse-papiers dans la barre des menus. Un clic gauche ouvre le panneau de recherche ; un clic droit (ou Ctrl-clic) ouvre un petit menu de secours : « Réglages… », « Ouvrir au démarrage » et « Quitter ».

L'application s'inscrit aussi comme élément d'ouverture de session : macOS la relancera à chaque connexion. La case « Ouvrir au démarrage » (menu de l'icône ou Réglages) coupe ce comportement, et si vous décochez Copyclipzer dans Réglages Système > Général > Éléments d'ouverture, l'application respecte ce choix au lieu de le réécrire.

## Le panneau de recherche

Un clic sur l'icône ouvre un panneau dont la barre de recherche est toujours en haut. Tapez : l'historique se filtre en direct, lettre après lettre, sans avoir à recliquer dans la barre. Les entrées épinglées passent en tête.

- Flèches haut et bas pour choisir une entrée, Entrée pour la coller dans l'application où vous étiez, Échap ou un clic ailleurs pour fermer.
- Au survol d'une ligne, ou sur la ligne sélectionnée, une punaise l'épingle ou la désépingle, une corbeille la supprime.
- En bas : « Tout supprimer » vide tout l'historique, « Tout sauf épinglés » ne garde que les entrées épinglées. Les deux demandent confirmation. L'engrenage ouvre les Réglages.

Le texte, le texte riche, les fichiers et les images sont gardés ; une image copiée se recolle bien en image, qu'elle vienne au format PNG ou TIFF.

## Réglages

Depuis le menu de l'icône ou l'engrenage du panneau :

- **Taille d'historique** : nombre d'entrées ordinaires conservées (les épinglées le sont toujours, en plus de ce nombre).
- **Applications exclues** : les copies faites depuis les applications choisies ne sont pas enregistrées. Les copies marquées confidentielles (gestionnaires de mots de passe, via `org.nspasteboard.ConcealedType`) sont de toute façon ignorées.
- **Ouverture au démarrage**.

## Le geste Cmd maintenu

Maintenez Cmd et appuyez plusieurs fois sur V pour parcourir les dernières entrées, numérotées de 1 à 9 ; relâchez Cmd pour coller la sélection, ou tapez son numéro. Au survol d'une ligne, une punaise l'épingle, une corbeille la supprime ; X épingle la sélection courante, Z bascule le collage en texte brut.

Au premier lancement, macOS demande l'autorisation Accessibilité. Elle ne sert qu'à ce geste : un tap clavier qui AVALE des touches l'exige, et c'est ce qui empêche le « 2 » de s'écrire dans le document pendant qu'il sélectionne la deuxième entrée. Tant qu'elle n'est pas accordée, l'application tourne, capture l'historique et le panneau de recherche fonctionne, mais ce geste ne répond pas. Il se réarme seul dès que l'autorisation est accordée, sans relancer l'application.

Piège de la signature ad-hoc : `build.sh` signe avec une identité qui change à chaque construction, et macOS cesse alors d'honorer l'autorisation sans jamais décocher la case. Après chaque reconstruction, retirer Copyclipzer de Réglages Système > Confidentialité et sécurité > Accessibilité avec le bouton moins, puis le rajouter.
