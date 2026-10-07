import AppKit
import Vision

/// Le vrai presse-papiers. Seul fichier de la capture qui importe AppKit, donc le
/// seul de ce dossier qui n'est pas symlinké dans la cible de test.
final class SystemPasteboard: PasteboardReading {
    private let pb = NSPasteboard.general

    var changeCount: Int {
        pb.changeCount
    }

    /// Côté maximal d'une vignette, en PIXELS. Le mot compte : voir `vignette(_:)`,
    /// où l'avoir compris en points a produit des vignettes deux fois trop grandes.
    /// Chiffres mesurés et pire cas dans `Schema.v2`.
    static let coteDeLaVignette: CGFloat = 192

    /// Fabrique la vignette d'une image du presse-papiers.
    ///
    /// Elle vit ICI et non dans `CaptureService`, qui est un fichier PUR symlinké dans
    /// la cible de test : y faire entrer AppKit briserait la règle qui garde les tests
    /// libres du presse-papiers. Ce fichier est le seul de `Capture/` qui importe déjà
    /// AppKit, et il tient déjà les octets de l'image. La couture est donc gratuite.
    ///
    /// Le rapport d'aspect est gardé : une capture 16/9 écrasée en carré serait pire
    /// qu'un symbole générique, parce qu'elle aurait l'air juste.
    static func vignette(_ octets: Data) -> Data? {
        // `NSBitmapImageRep` et NON `NSImage`, et c'est une correction, pas un détail
        // de style. `NSImage.size` est en POINTS : sur une capture d'écran Retina, un
        // plafond appliqué aux points produit un bitmap deux fois plus grand en
        // pixels. Mesuré sur cette machine le 2026-09-01, la première version rendait
        // 21 à 43 Ko là où elle promettait 6 à 9, soit 10 à 21 Mo au pire cas du menu
        // au lieu des 3 à 4,5 annoncés. `pixelsWide` ne ment pas.
        guard let source = NSBitmapImageRep(data: octets) else { return nil }
        let largeur = CGFloat(source.pixelsWide)
        let hauteur = CGFloat(source.pixelsHigh)
        guard largeur > 0, hauteur > 0 else { return nil }

        // Le rapport d'aspect est gardé, et l'agrandissement est refusé par le `1` :
        // une capture 16/9 écrasée en carré serait pire qu'un symbole générique, parce
        // qu'elle aurait l'air juste.
        let facteur = min(coteDeLaVignette / largeur, coteDeLaVignette / hauteur, 1)
        let l = max(1, Int((largeur * facteur).rounded()))
        let h = max(1, Int((hauteur * facteur).rounded()))

        guard let cible = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: l, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        cible.size = NSSize(width: l, height: h)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: cible)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Le fond blanc n'est pas décoratif : le JPEG ne porte pas de canal alpha, et
        // une image transparente aplatie sans fond ressort NOIRE. Une icône
        // transparente deviendrait une tache sombre illisible.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: l, height: h).fill()
        source.draw(in: NSRect(x: 0, y: 0, width: l, height: h))
        NSGraphicsContext.restoreGraphicsState()

        // JPEG et non PNG, et c'est la SECONDE correction de la même journée, prise
        // pour la même raison : la mesure. Le PNG est sans perte, donc il ne compresse
        // pas le photographique. Mesuré sur les vingt-trois images de la base réelle,
        // il rendait jusqu'à 61 Ko par vignette. Une vignette de 192 px n'a aucun
        // besoin d'être sans perte.
        return cible.representation(using: .jpeg,
                                    properties: [.compressionFactor: 0.7])
    }

    /// Lit le texte présent dans une image, hors ligne et localement, via Vision.
    ///
    /// Elle vit ici pour la même raison que `vignette(_:)` : AppKit et Vision n'ont
    /// rien à faire dans `CaptureService`, qui est symlinké dans la cible de test, et ce
    /// fichier tient déjà les octets de l'image. Le résultat alimente `searchText`, que
    /// le déclencheur FTS reindexe, ce qui rend l'image cherchable par son contenu.
    ///
    /// Synchrone à dessein : ce n'est jamais la boucle de capture qui l'appelle, mais le
    /// rattrapage du lancement, qui tourne hors du fil principal. `nil` veut dire « aucune
    /// image décodable ou aucun texte » : la distinction « rien trouvé » / « pas encore
    /// passé » est portée par `ocrFait`, pas par cette valeur.
    static func texteOCR(_ octets: Data) -> String? {
        guard let source = NSBitmapImageRep(data: octets), let cgImage = source.cgImage
        else { return nil }

        let requete = VNRecognizeTextRequest()
        // `.accurate` au coût de `.fast` : le rattrapage tourne une fois, en tâche de
        // fond, et la précision est ce qui rend la recherche utile sur du texte fin.
        requete.recognitionLevel = .accurate
        // Le français ET l'anglais, dans cet ordre : on écrit souvent dans les deux, et une
        // image peut mêler les deux. La reconnaissance estime la langue dominante.
        requete.recognitionLanguages = ["fr", "en"]

        let gestionnaire = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try gestionnaire.perform([requete])
        } catch {
            return nil
        }
        guard let observations = requete.results else { return nil }
        let lignes = observations.compactMap { $0.topCandidates(1).first?.string }
        let texte = lignes.joined(separator: "\n")
        return texte.isEmpty ? nil : texte
    }

    func read() -> RawSnapshot? {
        let types = pb.types?.map(\.rawValue) ?? []
        let image = pb.data(forType: .tiff) ?? pb.data(forType: .png)
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter(\.isFileURL).map(\.path)
        return RawSnapshot(
            types: types,
            text: pb.string(forType: .string),
            rtf: pb.data(forType: .rtf),
            image: image,
            fileURLs: urls,
            sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            vignette: image.flatMap(Self.vignette)
        )
    }
}
