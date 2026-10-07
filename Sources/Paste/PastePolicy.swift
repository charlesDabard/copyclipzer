import Foundation

// Les décisions PURES du collage : reconnaître nos propres événements, choisir
// ce qui part dans le presse-papiers, et dire s'il faut restaurer l'existant.
//
// Ce fichier est symlinké dans la cible de test, il n'importe donc ni AppKit ni
// CoreGraphics : lier un fichier graphique au binaire des tests y ajoute neuf
// bibliothèques (mesuré tâche 8, remesuré tâche 10). Les drapeaux d'événement
// s'y manipulent en `UInt64` brut, et `Paster` fait seul la traduction vers
// `CGEventFlags`. Sans cette séparation, les trois règles ci-dessous vivraient
// dans une méthode qui parle à `NSPasteboard` et ne seraient mesurées par rien.

/// Les deux bits « touche Commande » DÉPENDANTS DU PÉRIPHÉRIQUE, gauche et droite,
/// que le système pose lui-même sur tout événement matériel : `NX_DEVICELCMDKEYMASK`
/// et `NX_DEVICERCMDKEYMASK`, `IOLLEvent.h:256`. C'est exactement la raison d'être
/// de `NSEvent.deviceIndependentFlagsMask`, qui existe pour les effacer.
///
/// Correction du 2026-08-26. `0x000008` servait ici de marque de nos propres
/// événements, repris de Flycut en inversant sa raison d'être : Flycut le pose sur
/// son Cmd-V synthétique pour que les applications qui lisent les bits dépendants
/// du périphérique ACCEPTENT le collage, jamais pour se reconnaître lui-même. Un
/// vrai Cmd-C fait de la main GAUCHE présente des drapeaux `0x00100108`, il était
/// donc pris pour un des nôtres, `decider` le relayait, `onCopyShortcut` n'était
/// jamais appelé et la capture instantanée retombait sur le timer d'une seconde :
/// copier X puis Y en moins d'une seconde perdait X définitivement. De la main
/// droite (`0x000010`) rien ne cassait, une vérification manuelle faite de ce
/// côté-là passait au vert sans rien voir.
let bitCommandeGauche: UInt64 = 0x000008
let bitCommandeDroite: UInt64 = 0x000010

/// Valeur brute de `CGEventFlags.maskCommand`, recopiée ici parce que ce fichier
/// ne peut pas importer CoreGraphics. La recopie n'est pas laissée en confiance :
/// un `precondition` la compare à la vraie constante système.
let maskCommandBrut: UInt64 = 0x0010_0000

/// Les drapeaux exacts posés sur les deux moitiés de notre Cmd-V synthétique :
/// Commande pour que ce soit un collage, plus le bit Commande gauche pour les
/// applications qui refusent un collage dont aucun bit dépendant du périphérique
/// n'est posé. Ces drapeaux ne nous IDENTIFIENT pas, ils imitent un vrai clavier.
let drapeauxDuCollage: UInt64 = maskCommandBrut | bitCommandeGauche

/// Signature déposée dans `eventSourceUserData`, le champ `Int64` libre d'un
/// `CGEvent`, sur les DEUX moitiés de notre Cmd-V. C'est elle, et non plus les
/// drapeaux, qui dit qu'un événement vient de nous. Valeur non nulle et improbable,
/// « CLZP1 » en ASCII : un événement matériel porte zéro dans ce champ.
let signatureDuCollage: Int64 = 0x43_4C5A_5031

/// Vrai si cet événement ne doit JAMAIS être soumis à la machine à gestes : il est
/// relayé brut, comme s'il n'existait pas pour le geste.
///
/// Trois clés, et la première qui parle tranche. Deux clés suffisent à tout
/// événement synthétique, et elles sont INDÉPENDANTES exprès : un posteur qui
/// n'aurait pas de pid n'a pas de bit périphérique, et réciproquement.
///
/// 1. La signature. C'est la nôtre, `CLZP1`, déposée par `poserCmdV`.
/// 2. Le pid source. Un événement matériel porte zéro dans
///    `eventSourceUnixProcessID` ; tout ce qui est posté par un processus porte le
///    pid de ce processus. Mesuré le 2026-09-30 dans le journal de diagnostic :
///    SuperWhisper arrive en `pid=1546`, nos collages en `pid=1557`, le clavier en
///    `pid=0`.
/// 3. Sur une frappe portant Commande : un bit de commande DÉPENDANT DU
///    PÉRIPHÉRIQUE (`NX_DEVICELCMDKEYMASK` ou `NX_DEVICERCMDKEYMASK`) est
///    toujours posé par le système sur un vrai clavier, `0x00100108` et
///    `0x00100110` pour un vrai Cmd-C. Le Cmd-V automatique de SuperWhisper, lui,
///    arrive en `0x20100000`, sans aucun des deux. Cette clé ne s'applique qu'aux
///    `keyDown` : le bit n'a pas été mesuré sur les `flagsChanged`, donc on ne
///    l'exige pas d'eux, sous peine de désarmer le geste si le clavier ne le pose
///    pas là.
///
/// Correction du 2026-09-30, incident de 13:34:30 mesuré au journal : l'ancienne
/// règle ne connaissait que la clé 1, donc le Cmd-V automatique de SuperWhisper
/// était soumis à la machine. L'utilisateur tenait Cmd (il commençait une série de
/// Cmd+Retour arrière), la machine était donc `.arme` : le V synthétique a OUVERT
/// l'overlay et a été avalé, puis les premières touches de l'utilisateur ont été
/// mangées, et le collage n'est reparti qu'au relâchement de Cmd, au milieu de la
/// suppression. Une touche qui n'est pas de la main de l'utilisateur ne doit pas
/// pouvoir ouvrir le geste.
func estSynthetique(type: HotKeyEventType, drapeauxBruts: UInt64,
                    signatureEvenement: Int64, pidSource: Int64) -> Bool
{
    if signatureEvenement == signatureDuCollage {
        return true
    }
    if pidSource != 0 {
        return true
    }
    if type == .keyDown, drapeauxBruts & maskCommandBrut != 0,
       drapeauxBruts & (bitCommandeGauche | bitCommandeDroite) == 0
    {
        return true
    }
    return false
}

/// Ce que le colleur doit écrire dans le presse-papiers.
enum RepresentationDeCollage: Equatable {
    /// Le `searchText` en `.string`, et rien d'autre.
    case texte
    /// La charge utile en `.rtf`, doublée du `searchText` en `.string` pour les
    /// applications qui ne lisent pas le RTF.
    case rtf
    /// La charge utile en `.tiff`.
    case image
}

/// Choix de la représentation à écrire, en fonction PURE.
///
/// Deux motifs de repli sur le texte, et ils ne se recouvrent pas : le texte brut
/// demandé par l'utilisateur (touche Z du geste), et l'absence de charge utile,
/// qui arrive quand le blob a été purgé sous l'entrée. Les listes de fichiers
/// repartent en texte en v1, faute de représentation dédiée.
func representationAEcrire(kind: ClipKind, texteBrut: Bool, aPayload: Bool) -> RepresentationDeCollage {
    guard !texteBrut, aPayload else { return .texte }
    switch kind {
    case .rtf: return .rtf
    case .image: return .image
    case .text, .files: return .texte
    }
}

/// Restaure-t-on le presse-papiers d'origine après un collage ? Non, par défaut.
///
/// Correction du 2026-08-26. La restauration était le comportement par défaut, gardée
/// par `doitRestaurer`. Cette garde ne couvre que la MOITIÉ de la course : elle voit
/// une application qui ÉCRIT dans le presse-papiers, jamais une application qui se
/// contente de le LIRE. Slack, Teams, IntelliJ, ou n'importe quelle cible dont le
/// thread principal est occupé, reçoit le Cmd-V et n'interroge `NSPasteboard` que
/// 300 ms plus tard : à 120 ms nous avons déjà remis l'ancien contenu, `changeCount`
/// a bien bougé mais c'est NOUS qui l'avons bougé, donc rien n'alerte. L'utilisateur
/// obtient l'ancien contenu au lieu de l'entrée qu'il vient de choisir, sans aucun
/// message. Silencieux et faux, le pire mode d'échec possible pour ce produit.
///
/// Ne pas restaurer laisse l'entrée collée dans le presse-papiers, ce que font Maccy
/// et Pastebot, et ce que l'utilisateur attend d'un gestionnaire d'historique : ce
/// qu'il vient de choisir est ce qu'il pourra recoller.
let restaurationParDefaut = false

/// Faut-il remettre en place le presse-papiers d'origine, quand la restauration a
/// été demandée explicitement ?
///
/// Ce que cette garde couvre : l'application cible a ÉCRIT dans le presse-papiers
/// entre notre écriture et l'échéance, son compteur a bougé, et nous nous abstenons
/// d'écraser son travail. Une sauvegarde vide ne se restaure pas non plus, cela
/// reviendrait à vider le presse-papiers au lieu d'y laisser l'élément collé.
///
/// Ce qu'elle NE couvre PAS, et il faut le dire ici parce que le commentaire
/// précédent affirmait le contraire : le délai de 120 ms reste un délai DEVINÉ, et
/// rien dans ce prédicat ne voit une application qui LIT tard, puisque lire ne fait
/// pas bouger `changeCount`. La garde est correcte pour ce qu'elle mesure, elle ne
/// supprime pas la course. C'est `restaurationParDefaut` qui la supprime, en ne
/// restaurant pas.
func doitRestaurer(sauvegardeVide: Bool, changeCountApresEcriture: Int, changeCountActuel: Int) -> Bool {
    !sauvegardeVide && changeCountActuel == changeCountApresEcriture
}
