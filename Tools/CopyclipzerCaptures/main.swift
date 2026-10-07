import AppKit
import SwiftUI

// Harnais de capture des surfaces de Copyclipzer, en clair ET en sombre.
//
// Lancement : swift run CopyclipzerCaptures [dossier]
//
// Pourquoi il existe. `screencapture` a refusé quatre fois de suite sur cette
// machine, `CGPreflightScreenCaptureAccess()` rendant faux même une fois Ghostty
// coché dans Enregistrement d'écran, et quatre tâches visuelles se sont accumulées
// sans que personne ait vu un seul pixel. Or une application qui dessine SES PROPRES
// vues dans un bitmap ne demande AUCUNE permission : c'est du dessin hors écran, pas
// de la capture d'écran. Le besoin de permission disparaît donc au lieu d'être
// contourné.
//
// Ce qu'il prouve : les PIXELS, c'est-à-dire la mise en page, les couleurs, la
// surbrillance redessinée à la main, le rendu des vignettes, la troncature.
// Ce qu'il ne prouve PAS : le comportement, c'est-à-dire le survol, le gel, le
// placement à l'écran. Ceux-là restent à regarder en vrai, ou sont couverts par les
// tests purs quand ils peuvent l'être.

// Deux modes. Par défaut, le harnais dessine ses surfaces hors écran dans un dossier.
// Avec « focus-demo », il ouvre une vraie fenêtre clé et prouve que le champ garde le
// focus d'une frappe à l'autre : cette démo n'écrit aucun fichier, donc l'argument
// « focus-demo » ne doit pas être pris pour un dossier de sortie.
let modeFocusDemo = CommandLine.arguments.contains("focus-demo")
let dossier = CommandLine.arguments.dropFirst().first { $0 != "focus-demo" }
    ?? FileManager.default.currentDirectoryPath + "/screenshots"
if !modeFocusDemo {
    try? FileManager.default.createDirectory(atPath: dossier, withIntermediateDirectories: true)
}

/// `.accessory` et non `.regular` : le harnais ne doit ni voler le premier plan ni
/// poser une icône dans le Dock pendant qu'il dessine.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Une vignette JPEG fabriquée sur place, pour que le harnais ne dépende ni de la
/// base ni du presse-papiers. Un dégradé, donc quelque chose qu'on reconnaît tout de
/// suite comme une vraie image et non comme un carré de couleur.
func vignetteDeDemonstration(largeur: Int = 192, hauteur: Int = 120) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: largeur, pixelsHigh: hauteur,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [.systemTeal, .systemIndigo, .systemPink])?
        .draw(in: NSRect(x: 0, y: 0, width: largeur, height: hauteur), angle: 35)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!
}

let vignette = vignetteDeDemonstration()

func entree(kind: ClipKind, titre: String, texte: String, taille: Int,
            epinglee: Bool = false, avecVignette: Bool = false,
            source: String? = "com.apple.Safari") -> ClipItem
{
    var item = ClipItem(id: UUID().uuidString, createdAt: 1_756_700_000,
                        modifiedAt: 1_756_700_000, deviceID: "mac", kind: kind,
                        title: titre, searchText: texte, contentHash: UUID().uuidString,
                        byteSize: taille, sourceBundleID: source, pinned: epinglee,
                        isRemote: false)
    if avecVignette {
        item.thumb = vignette
    }
    return item
}

let texteLong = """
func placementDuPanneau(ancre: CGRect, taille: CGSize, ecran: CGRect) -> CGPoint {
    var x = ancre.maxX + marge
    if x + taille.width > ecran.maxX - marge { x = ancre.minX - marge - taille.width }
    return CGPoint(x: x, y: ancre.maxY - taille.height)
}
"""

let entrees = [
    entree(kind: .text, titre: "https://github.com/example/project/pull/42",
           texte: "https://github.com/example/project/pull/42", taille: 51),
    entree(kind: .image, titre: "", texte: "", taille: 85424, avecVignette: true,
           source: "com.apple.screencaptureui"),
    entree(kind: .text, titre: texteLong, texte: texteLong, taille: 268, epinglee: true,
           source: "com.microsoft.VSCode"),
    entree(kind: .files, titre: "/Users/vous/Documents/rapport.md",
           texte: "/Users/vous/Documents/rapport.md",
           taille: 88, source: "com.apple.finder"),
]

/// Dessine une vue dans un PNG, sous une apparence donnée.
///
/// Le fond est peint AVANT la vue, et ce n'est pas cosmétique : les matériaux
/// translucides de SwiftUI (`.regularMaterial`) n'ont rien derrière quoi se composer
/// hors écran, et sortiraient transparents, donc noirs dans un visualiseur. Un fond
/// neutre rend le résultat lisible et honnête, en montrant la translucidité telle
/// qu'elle sera par-dessus une fenêtre quelconque.
func rendre(_ vue: NSView, vers nom: String, apparence: NSAppearance, fond: NSColor) {
    vue.appearance = apparence
    vue.layoutSubtreeIfNeeded()

    let taille = vue.frame.size
    guard taille.width > 0, taille.height > 0 else {
        print("  ÉCHEC \(nom) : vue de taille nulle")
        return
    }

    // Rendu en 2×, comme un écran Retina. Ce n'est pas du confort : une ligne de menu
    // fait 24 points de haut, et à 1× une planche de quatre lignes tient dans 96
    // pixels, où l'œil ne distingue plus un raccourci absent d'un raccourci pâle. Le
    // 2026-09-01, une lecture à 1× a bien failli faire corriger un défaut inexistant.
    let echelle = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(taille.width) * echelle, pixelsHigh: Int(taille.height) * echelle,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        print("  ÉCHEC \(nom) : bitmap")
        return
    }
    // La taille en POINTS diffère de la taille en PIXELS : c'est cette différence qui
    // fait que le contexte dessine à l'échelle 2 tout seul.
    rep.size = taille

    apparence.performAsCurrentDrawingAppearance {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // Le fond est peint AVANT la vue, et ce n'est pas cosmétique : les matériaux
        // translucides de SwiftUI n'ont rien derrière quoi se composer hors écran, et
        // sortiraient transparents, donc noirs dans un visualiseur.
        fond.setFill()
        vue.bounds.fill()
        vue.displayIgnoringOpacity(vue.bounds, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("  ÉCHEC \(nom) : encodage PNG")
        return
    }
    try? png.write(to: URL(fileURLWithPath: dossier + "/" + nom + ".png"))
    print("  \(nom).png · \(Int(taille.width))×\(Int(taille.height)) points en \(echelle)× · "
        + "\(png.count) octets")
}

/// Le panneau de recherche, peuplé d'un échantillon, pour vérifier à l'œil la barre
/// toujours en haut, la liste filtrée, la ligne sélectionnée et le pied d'actions, en
/// clair comme en sombre. Le panneau réel prend le focus ; ici on ne rend que sa vue,
/// hors écran, sans aucune permission.
func hoteRecherche() -> NSView {
    let modele = RechercheModel()
    modele.lignes = elementsDuMenu(entrees: entrees, recherche: "")
    modele.index = 1
    let hote = NSHostingView(rootView: RechercheView(model: modele))
    hote.frame = NSRect(origin: .zero, size: hote.fittingSize)
    return hote
}

func hoteOverlay() -> NSView {
    let modele = OverlayModel()
    modele.items = entrees
    modele.index = 1
    modele.texteBrut = true
    let hote = NSHostingView(rootView: OverlayView(model: modele))
    hote.frame = NSRect(origin: .zero,
                        size: NSSize(width: 460, height: hote.fittingSize.height))
    return hote
}

func hoteApercu(_ item: ClipItem) -> NSView {
    let modele = ApercuModel()
    modele.item = item
    let hote = NSHostingView(rootView: ApercuView(model: modele))
    hote.frame = NSRect(origin: .zero,
                        size: NSSize(width: largeurDeLApercu, height: hote.fittingSize.height))
    return hote
}

// Contrôle en clair de ce que la règle pure produit, pour ne pas déduire d'un PNG
// de 320 pixels ce qu'une ligne de texte dit sans ambiguïté. Sans objet en mode démo.
if !modeFocusDemo {
    for l in elementsDuMenu(entrees: entrees, recherche: "") {
        print("rang \(l.rang) · raccourci « \(l.raccourci) » · épinglé \(l.epingle) "
            + "· vignette \(l.vignette != nil) · \(l.titre.prefix(40))")
    }
}

// Garde-fou de non-régression du panneau, à CODE DE SORTIE (0 si tout tient, 1 dès
// qu'un invariant casse). Il prouvait à l'origine un seul point, le focus ; il en
// couvre désormais trois : la fenêtre est réellement visible, le filtrage réduit la
// liste par le vrai chemin (frappe -> controlTextDidChange -> onRequete -> elementsDuMenu),
// et le champ garde le focus d'une lettre à l'autre.
//
// ATTENTION : ce mode exige une SESSION GRAPHIQUE (un serveur de fenêtres). Il ouvre une
// vraie fenêtre clé (`PanneauClavier`) et vérifie qu'elle est visible, donc il ne peut
// PAS tourner en CI headless : un runner GitHub macOS sans session GUI n'a aucune fenêtre
// clé à garantir, et le garde-fou y échouerait pour une raison étrangère au produit. Il
// est fait pour tourner en PRE-PR LOCAL : `swift run CopyclipzerCaptures focus-demo`.
if modeFocusDemo {
    var echecs = 0
    let invariants = 3

    let echantillon = [
        entree(kind: .text, titre: "https://github.com/example/project/pull/42",
               texte: "https://github.com/example/project/pull/42", taille: 51),
        entree(kind: .text, titre: "git commit -m \"feat: panneau de recherche\"",
               texte: "git commit -m feat panneau de recherche", taille: 40,
               source: "com.apple.Terminal"),
        entree(kind: .image, titre: "", texte: "", taille: 85424, avecVignette: true,
               source: "com.apple.screencaptureui"),
        entree(kind: .text, titre: "git rebase --interactive main",
               texte: "git rebase --interactive main", taille: 30, source: "com.apple.Terminal"),
        entree(kind: .files, titre: "/Users/vous/notes.md", texte: "", taille: 88,
               source: "com.apple.finder"),
    ]
    let modele = RechercheModel()
    modele.onRequete = { requete in
        modele.lignes = elementsDuMenu(entrees: echantillon, recherche: requete)
        modele.index = 0
    }
    let panneau = RecherchePanel(model: modele)
    panneau.afficher()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        func champ(_ v: NSView?) -> NSSearchField? {
            guard let v else { return nil }
            if let s = v as? NSSearchField {
                return s
            }
            for s in v.subviews {
                if let f = champ(s) {
                    return f
                }
            }
            return nil
        }
        let fenetre = NSApp.windows.first { $0 is PanneauClavier }

        // Invariant VISIBLE : `afficher()` a réellement posé une fenêtre à l'écran.
        if fenetre?.isVisible == true {
            print("invariant VISIBLE  : OK · la fenêtre du panneau est visible")
        } else {
            echecs += 1
            let detail = fenetre == nil ? "fenêtre PanneauClavier introuvable" : "isVisible vaut faux"
            print("invariant VISIBLE  : KO · \(detail)")
        }

        guard let sf = champ(fenetre?.contentView) else {
            // Sans champ on ne peut ni filtrer ni taper : les deux invariants tombent.
            echecs += 2
            print("invariant FILTRAGE : KO · champ de recherche introuvable, impossible de taper")
            print("invariant FOCUS    : KO · champ de recherche introuvable, impossible de taper")
            print("\nRésumé : \(invariants - min(echecs, invariants))/\(invariants) invariant(s) OK · \(min(echecs, invariants)) KO")
            fflush(stdout)
            exit(1)
        }

        // Invariant FILTRAGE, étape 1 : la liste part de l'échantillon complet.
        let avant = modele.lignes.count
        let attenduAvant = echantillon.count

        // Invariant FOCUS, cumulé sur toute la frappe : un champ qui a le focus possède
        // un « field editor » ; dès qu'il le perd, `currentEditor()` rend nil.
        let cible = "git"
        var focusTenu = true
        print("avant frappe : \(avant) entrée(s) affichée(s)")
        for (i, c) in cible.enumerated() {
            guard let editor = sf.currentEditor() else {
                focusTenu = false
                print("  lettre \(i + 1) « \(c) » : le champ a PERDU le focus (currentEditor nil), c'est le bug d'origine")
                break
            }
            editor.insertText(String(c))
            print("  lettre \(i + 1) « \(c) » tapée · focus tenu · champ = « \(sf.stringValue) » · \(modele.lignes.count) résultat(s)")
        }

        // Invariant FILTRAGE, étape 2 : taper a DIMINUÉ la liste (le filtre vit).
        let apres = modele.lignes.count
        if avant == attenduAvant, apres < avant {
            print("invariant FILTRAGE : OK · \(avant) entrée(s) avant, \(apres) après « \(cible) »")
        } else {
            echecs += 1
            print("invariant FILTRAGE : KO · avant = \(avant) (attendu \(attenduAvant)), après = \(apres) (attendu < \(avant))")
        }

        // Invariant FOCUS : le champ a tenu le focus ET la saisie est allée au bout.
        if focusTenu, sf.stringValue == cible {
            print("invariant FOCUS    : OK · « \(cible) » entré d'affilée sans un seul reclic")
        } else {
            echecs += 1
            print("invariant FOCUS    : KO · champ = « \(sf.stringValue) », focus tenu = \(focusTenu)")
        }

        print("\nRésumé : \(invariants - echecs)/\(invariants) invariant(s) OK · \(echecs) KO")
        // `fflush` avant `exit` : sous un pipe, la sortie de `print` est bufferisée, et
        // un `exit` sec la perdrait. On veut que le code de sortie ET le résumé arrivent.
        fflush(stdout)
        exit(echecs == 0 ? 0 : 1)
    }
    NSApp.run()
}

let apparences: [(String, NSAppearance, NSColor)] = [
    ("clair", NSAppearance(named: .aqua)!, NSColor(white: 0.92, alpha: 1)),
    ("sombre", NSAppearance(named: .darkAqua)!, NSColor(white: 0.14, alpha: 1)),
]

for (nom, apparence, fond) in apparences {
    print("\(nom) :")
    rendre(hoteRecherche(), vers: "2026-10-05-recherche-\(nom)",
           apparence: apparence, fond: fond)
    rendre(hoteOverlay(), vers: "2026-09-01-overlay-\(nom)", apparence: apparence, fond: fond)
    rendre(hoteApercu(entrees[1]), vers: "2026-09-01-apercu-image-\(nom)",
           apparence: apparence, fond: fond)
    rendre(hoteApercu(entrees[2]), vers: "2026-09-01-apercu-texte-\(nom)",
           apparence: apparence, fond: fond)
}

print("\nÉcrit dans \(dossier)")
