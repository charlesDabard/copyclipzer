/// Quand l'application doit-elle s'inscrire comme élément d'ouverture de session ?
/// Fichier PUR, sans AppKit ni ServiceManagement : la décision est ici, l'appel
/// système est dans `LoginItem.swift`.
///
/// Le défaut est ON, mais il n'écrase personne : un refus explicite, qu'il vienne
/// de la case du menu ou d'un décochage dans Réglages Système, reste un refus, et
/// le lancement suivant ne réinscrit pas l'application contre ce choix.

/// L'état du réglage système, réduit aux cas qui changent une décision.
enum EtatDuLoginItem: Equatable {
    /// Rien d'inscrit, ou désinscrit par nous-mêmes. C'est l'état d'une
    /// installation neuve.
    case jamaisEnregistre
    /// Inscrit et actif : l'application se lancera à la connexion.
    case actif
    /// Inscrit, mais décoché dans Réglages Système. Ce geste-là est le plus récent
    /// de l'utilisateur, et il prime sur notre préférence.
    case refuseParLUtilisateur
}

/// Le choix explicite de l'utilisateur dans notre menu. `jamaisExprime` n'est pas
/// `non` : c'est ce qui permet au défaut d'être ON sans écraser un refus venu de
/// Réglages Système.
enum ChoixDOuverture: Equatable {
    case jamaisExprime
    case oui
    case non
}

/// Faut-il (re)inscrire l'application au lancement ? Vrai seulement quand il reste
/// quelque chose à faire : un état déjà actif ne se réinscrit pas, car `register`
/// rendrait `kSMErrorAlreadyRegistered` à chaque lancement.
///
/// `dansUnBundle` est faux quand l'application tourne en binaire nu (`swift run`,
/// `.build/debug/Copyclipzer`). Mesuré le 2026-09-28 : dans ce cas `register`
/// N'ÉCHOUE PAS, il inscrit le binaire de `.build` comme élément d'ouverture à part
/// entière (`Copyclipzer-5555...`), avec sa propre identité, hors de portée de la
/// case du menu de l'application installée. La garde est donc ici, et pas dans le
/// commentaire qui pariait sur un échec.
func doitEnregistrerAuLancement(choix: ChoixDOuverture, etat: EtatDuLoginItem,
                                dansUnBundle: Bool) -> Bool {
    guard dansUnBundle else { return false }
    switch (choix, etat) {
    case (.non, _), (_, .actif), (_, .refuseParLUtilisateur):
        return false
    case (.jamaisExprime, .jamaisEnregistre), (.oui, .jamaisEnregistre):
        return true
    }
}
