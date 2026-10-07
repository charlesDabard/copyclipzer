import AppKit

/// Point d'entrée. `LSUIElement` dans l'Info.plist et `.accessory` ici disent la
/// même chose de deux façons, pas d'icône dans le Dock et pas de menu
/// d'application, et les deux sont gardés : la clé du plist ne vaut que dans un
/// bundle, alors que `swift run Copyclipzer` lance le binaire nu, sans plist.
///
/// `delegate` est une constante de premier niveau, donc une globale qui vit aussi
/// longtemps que le processus. Ce n'est pas un détail de style : `NSApplication`
/// ne retient PAS son délégué, et un délégué relâché emporterait avec lui le tap,
/// le panneau, la capture et le colleur.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
