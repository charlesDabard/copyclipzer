// swift-tools-version:5.9
import PackageDescription

/// Même convention que QuickTasks : les tests sont des cibles exécutables et non
/// des `.testTarget`, parce que XCTest exige Xcode alors que le projet se construit
/// avec les seuls Command Line Tools. Les fichiers de logique pure sont symlinkés
/// dans la cible de test, qui se lance par `swift run CopyclipzerTests`.
let package = Package(
    name: "Copyclipzer",
    defaultLocalization: "fr",
    platforms: [.macOS(.v13)],
    // Sparkle, la seule dependance : le moteur de mise a jour standard des apps macOS
    // (choisi le 2026-11-08 sur le modele de Vibe Island). Version exacte, jamais une
    // plage : une mise a jour du moteur de mise a jour se decide, elle ne s'herite pas.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Seule la cible applicative embarque les traductions. Les trois autres cibles
        // n'ont AUCUN bundle de ressources : un fichier symlinke qui appellerait
        // `NSLocalizedString(..., bundle: .module)` y casserait la compilation. C'est la
        // raison pour laquelle les chaines purement logiques (MenuFormat, ApercuFormat,
        // ClipItem...) restent en dur pour l'instant.
        //
        // Le rpath pointe vers Contents/Frameworks, ou `build.sh` copie Sparkle.framework.
        // Sans lui, l'app empaquetee meurt au lancement sur « Library not loaded ».
        .executableTarget(name: "Copyclipzer",
                          dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources",
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath",
                                                         "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CopyclipzerTests", path: "Tests/CopyclipzerTests"),
        // Harnais de capture. Une app qui dessine SES PROPRES vues dans une image ne
        // demande AUCUNE permission : c'est du dessin hors écran, pas de la capture
        // d'écran. Posé le 2026-09-01 après que `screencapture` ait refusé quatre fois
        // de suite, `CGPreflightScreenCaptureAccess()` rendant faux même une fois
        // Ghostty coché, et que quatre tâches visuelles se soient accumulées sans que
        // personne ait vu un seul pixel. Ne fait pas partie de l'application livrée :
        // `build.sh` ne copie que `Copyclipzer` dans le bundle.
        .executableTarget(name: "CopyclipzerCaptures", path: "Tools/CopyclipzerCaptures"),
    ]
)
