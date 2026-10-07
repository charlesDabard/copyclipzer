import Foundation

/// Borne la taille d'historique demandée dans les Réglages. Fonction PURE et testée :
/// une valeur aberrante saisie à la main (zéro, négative, un million) ne doit ni vider
/// l'historique à la première purge ni faire ramer le `SELECT` du panneau. Plancher à
/// 10, plafond à 50 000. Les entrées épinglées échappent de toute façon à la purge,
/// donc ce nombre ne concerne que l'historique ordinaire.
func tailleHistoriqueBornee(_ n: Int) -> Int {
    min(max(n, 10), 50000)
}

/// Borne la rétention par le temps demandée dans les Réglages, en jours. Fonction PURE
/// et testée, sur le modèle de `tailleHistoriqueBornee`. Ici 0 est une valeur LÉGITIME :
/// elle désactive la rétention par le temps. Une valeur négative se relève donc à 0, et
/// le plafond de 3650 jours (dix ans) évite qu'une faute de frappe ne fixe un seuil
/// absurde. Les entrées épinglées échappent de toute façon à la purge.
func retentionJoursBornee(_ n: Int) -> Int {
    min(max(n, 0), 3650)
}
