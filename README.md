# Copyclipzer

Un gestionnaire de presse-papiers pour macOS, rapide et discret. Il garde l'historique de ce que vous copiez et le remet à portée de main, au clavier comme à la souris.

Écrit en Swift, **sans aucune dépendance externe**.

## Fonctionnalités

- **Historique complet** : texte, texte riche, fichiers et images sont capturés et conservés.
- **Panneau de recherche** : un clic sur l'icône de la barre des menus ouvre une recherche qui filtre l'historique **à la frappe**. Navigation à la souris ou aux flèches, avec un aperçu de l'entrée pointée.
- **Geste Cmd** : maintenez Cmd et appuyez sur V pour parcourir les dernières entrées, relâchez pour coller. Un raccourci global (⌥⌘V) ouvre aussi le panneau depuis n'importe où.
- **Recherche dans les images** : le texte des captures d'écran est reconnu (OCR) et devient cherchable.
- **Épinglez** les entrées importantes pour les garder en tête de liste.
- **Collez en texte brut**, sans la mise en forme d'origine.
- **Chiffré au repos** : le contenu est chiffré sur le disque (AES-GCM), la clé vit dans le Trousseau.
- **Respecte votre confidentialité** : un contenu marqué confidentiel (mots de passe d'un gestionnaire comme 1Password, etc.) n'est jamais enregistré.
- **Tout se règle depuis le menu de l'engrenage** : taille et durée de rétention de l'historique, applications exclues, raccourci, ouverture au démarrage.
- **Français et anglais.**

## Installation

Depuis les sources, rien d'autre à installer :

    git clone https://github.com/charlesDabard/copyclipzer.git
    cd copyclipzer
    ./install.sh

L'application s'installe dans `/Applications` et vit dans la barre des menus (pas d'icône dans le Dock).

## Autorisation

Au premier lancement, macOS demande l'autorisation **Accessibilité**. Elle sert au geste Cmd, au raccourci global et au collage automatique dans l'application active. Le panneau de recherche, lui, fonctionne sans.

---

macOS 13+ · Swift · zéro dépendance externe
