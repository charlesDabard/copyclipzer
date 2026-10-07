import Foundation

/// Source de presse-papiers injectable, pour que la capture se teste sans NSPasteboard.
/// Fichier PUR, séparé de `SystemPasteboard` : symlinké dans la cible de test, il y
/// ferait entrer AppKit s'il portait aussi l'implémentation système. Mesuré : la cible
/// de test compile quand même, mais `otool -L` montre alors AppKit lié au binaire des
/// tests, ce que la règle des fichiers purs cherche précisément à éviter.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    func read() -> RawSnapshot?
}
