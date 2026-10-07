import Foundation

/// Une action proposée pour le TEXTE d'une entrée, quand ce texte est en entier
/// une URL, une couleur hexadécimale ou une adresse e-mail.
///
/// Le type vit dans un fichier PUR, sans AppKit : la décision se teste, l'exécution
/// (ouvrir un navigateur, écrire dans le presse-papiers, composer un e-mail) reste
/// dans l'assemblage, où aucun test ne peut l'atteindre.
enum ActionIntelligente: Equatable {
    /// Ouvrir l'URL dans le navigateur par défaut.
    case ouvrirURL(URL)
    /// Copier la couleur telle quelle, dièse compris.
    case copierCouleur(String)
    /// Composer un e-mail vers cette adresse.
    case ecrireEmail(String)
}

/// L'action correspondant à un texte, ou `nil` quand aucune ne s'applique.
///
/// Le test porte sur le texte ROGNÉ (espaces et sauts de ligne en tête et en queue).
/// Une action n'est rendue que si le texte rogné EST en entier la chose reconnue, et
/// non s'il la contient : « vois https://x.fr ce soir » ne propose rien.
/// L'ordre est couleur, puis e-mail, puis URL http(s) ; le premier qui matche gagne.
func actionPour(_ texte: String) -> ActionIntelligente? {
    let rogne = texte.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rogne.isEmpty else { return nil }
    if estCouleurHexadecimale(rogne) {
        return .copierCouleur(rogne)
    }
    if estAdresseEmail(rogne) {
        return .ecrireEmail(rogne)
    }
    if let url = urlHTTP(rogne) {
        return .ouvrirURL(url)
    }
    return nil
}

/// Le nom du SF Symbol qui représente une action, décidé hors AppKit pour être testé.
func iconeDeLAction(_ action: ActionIntelligente) -> String {
    switch action {
    case .ouvrirURL: return "globe"
    case .copierCouleur: return "eyedropper"
    case .ecrireEmail: return "envelope"
    }
}

/// Vrai pour `#RGB` ou `#RRGGBB`, et pour rien d'autre.
///
/// La longueur est vérifiée avant les chiffres : `#1234567` et `#12` sont refusés
/// sans même regarder leur contenu.
func estCouleurHexadecimale(_ texte: String) -> Bool {
    guard texte.hasPrefix("#") else { return false }
    let chiffres = texte.dropFirst()
    guard chiffres.count == 3 || chiffres.count == 6 else { return false }
    return chiffres.allSatisfy { $0.isHexDigit }
}

/// Vrai pour une adresse e-mail simple : un seul `@`, des deux côtés non vides, un
/// domaine qui contient un point, et aucun espace.
///
/// Le refus du schema (`://`) est explicite : sans lui, une URL construite autour
/// d'un `@` pourrait passer pour une adresse.
func estAdresseEmail(_ texte: String) -> Bool {
    guard !texte.contains("://") else { return false }
    guard !texte.contains(where: { $0.isWhitespace }) else { return false }
    let parties = texte.split(separator: "@", omittingEmptySubsequences: false)
    guard parties.count == 2 else { return false }
    let locale = parties[0]
    let domaine = parties[1]
    guard !locale.isEmpty, !domaine.isEmpty else { return false }
    return domaine.contains(".")
        && !domaine.hasPrefix(".")
        && !domaine.hasSuffix(".")
        && !domaine.contains("..")
}

/// L'URL quand le texte EST une URL http(s) valide, avec un hôte non vide.
///
/// `URL(string: "http://")` réussit en Swift et rend un hôte vide : sans la garde
/// sur l'hôte, cette chaîne serait acceptée comme une URL ouvrable.
func urlHTTP(_ texte: String) -> URL? {
    guard let url = URL(string: texte) else { return nil }
    guard let schema = url.scheme?.lowercased(), schema == "http" || schema == "https" else {
        return nil
    }
    guard let hote = url.host, !hote.isEmpty else { return nil }
    return url
}
