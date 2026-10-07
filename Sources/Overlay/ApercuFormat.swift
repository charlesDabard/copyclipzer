import CoreGraphics
import Foundation

/// Marge entre l'ancre et le panneau d'aperçu, et entre le panneau et le bord de
/// l'écran. Une seule valeur pour les deux : un panneau collé à sa ligne et un
/// panneau collé au bord de l'écran ont l'air aussi mal posés l'un que l'autre.
let margeDeLApercu: CGFloat = 8

/// Largeur figée du panneau d'aperçu. Même raison que pour l'overlay : laisser la
/// largeur suivre le contenu ferait sauter le panneau de taille à chaque entrée
/// survolée, puisque la plus longue la dicterait.
let largeurDeLApercu: CGFloat = 320

/// Bornes de la hauteur. Le plancher évite un panneau si plat qu'il ne se distingue
/// pas d'une ombre ; le plafond évite qu'un texte de quarante lignes ne fasse un
/// panneau plus haut que l'écran, où le début serait hors champ.
let hauteurMinimaleDeLApercu: CGFloat = 90
let hauteurMaximaleDeLApercu: CGFloat = 420

/// Délai avant que le panneau d'aperçu n'apparaisse, en secondes.
///
/// Sans lui, balayer la souris du haut en bas du menu construisait un panneau SwiftUI
/// complet par ligne traversée, chacun sur le thread principal : c'est le suivi du
/// menu lui-même qui ralentissait, donc la SÉLECTION qui devenait poussive. Signalé en
/// usage réel le 2026-09-01, sous la forme « c'est lent la sélection par survol ».
///
/// Même patron et même raison que `delaiAvantAffichage` pour l'overlay, en plus court :
/// ici il n'y a rien à protéger d'un clignotement, seulement un travail à ne pas faire
/// pour une ligne qu'on ne fait que traverser.
let delaiAvantLApercu: TimeInterval = 0.12

/// Un report annulable, réduit à son seul invariant : un travail programmé pour plus
/// tard ne doit PAS s'exécuter si quelqu'un l'a annulé entre-temps.
///
/// Existe comme type à part, et pur, parce que l'invariant a déjà été enfreint. Le
/// compteur vivait dans `AppDelegate`, que rien ne teste, et seul le chemin « masquer
/// par le report » l'incrémentait : les deux autres chemins de fermeture, celui du menu
/// et celui du geste, masquaient sans annuler. L'affichage en attente se posait donc
/// APRÈS la fermeture, et le panneau devenait orphelin, au-dessus de tout, sur tous les
/// bureaux, insensible aux clics. Signalé le 2026-09-02 : « des fois la preview reste
/// affichée alors que je clique en dehors, écris, change d'app, de bureau ».
///
/// Le propriétaire du report est désormais celui qui affiche, pas l'appelant : il n'y a
/// plus de chemin où l'on masque en oubliant d'annuler.
struct ReportAnnulable {
    private(set) var generation = 0

    /// Programme un travail et rend son jeton.
    mutating func programmer() -> Int {
        generation += 1
        return generation
    }

    /// Annule tout travail en attente. Aucun jeton déjà rendu ne sera plus valide.
    mutating func annuler() {
        generation += 1
    }

    func estValide(_ jeton: Int) -> Bool {
        jeton == generation
    }
}

/// Où poser le panneau d'aperçu, en coordonnées d'écran macOS, donc origine en bas
/// à gauche.
///
/// L'ancre est un RECTANGLE et non un point, et c'est ce qui permet aux deux surfaces
/// d'appeler la même fonction : le menu de barre passe le rectangle de sa ligne
/// survolée, le geste maintenu passe celui de son overlay. Deux calculs jumeaux
/// divergeraient au premier réglage.
///
/// Fichier PUR : aucun AppKit, donc symlinkable dans la cible de test. C'est le seul
/// morceau de cette tâche qui puisse être faux SANS que ça se voie, parce qu'un
/// panneau posé hors de l'écran est simplement invisible et que rien ne le signale.
func placementDuPanneau(ancre: CGRect, taille: CGSize, ecran: CGRect,
                        marge: CGFloat = margeDeLApercu) -> CGPoint
{
    // À droite par défaut. À gauche seulement si la place manque : basculer dès qu'on
    // s'approche du bord ferait sauter le panneau d'un côté à l'autre pendant qu'on
    // descend une liste, ce qui est plus désagréable qu'un panneau un peu serré.
    var x = ancre.maxX + marge
    if x + taille.width > ecran.maxX - marge {
        x = ancre.minX - marge - taille.width
    }
    // Dernier filet : sur un écran plus étroit que le panneau, les deux côtés
    // débordent, et il vaut mieux un panneau collé au bord qu'un panneau hors champ.
    x = min(max(x, ecran.minX + marge), max(ecran.minX + marge, ecran.maxX - marge - taille.width))

    // Haut du panneau aligné sur le haut de l'ancre : c'est la ligne survolée que
    // l'œil suit, pas son milieu.
    var y = ancre.maxY - taille.height
    if y < ecran.minY + marge {
        y = ecran.minY + marge
    }
    if y + taille.height > ecran.maxY - marge {
        y = ecran.maxY - marge - taille.height
    }
    return CGPoint(x: x, y: y)
}
