import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var index: Int = 0
    @Published var texteBrut: Bool = false

    /// Ce que la vue renvoie à l'assemblage. Des fermetures et non des `@Published` :
    /// ce sont des ÉVÉNEMENTS, et les publier ferait redessiner le panneau à chaque
    /// mouvement de souris sans rien changer à l'écran.
    var onEpingler: ((Int) -> Void)?
    var onSupprimer: ((Int) -> Void)?
}

/// Mesures reprises telles quelles de `SearchPanel.swift` de QuickTasks, pour que
/// les deux applications se ressemblent : matériau translucide, coins à 10,
/// bordure discrète, ombre portée, marge externe de 12.
///
/// Les deux morceaux de logique pure, le choix de l'icône et la mise en une ligne du
/// titre, vivent dans `OverlayFormat.swift` : ce fichier-ci importe SwiftUI, donc il
/// ne peut pas être symlinké dans la cible de test.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// Le rang survolé, ou rien. `@State` et non modèle : c'est de l'état de vue pure,
    /// l'assemblage n'a rien à en savoir.
    @State private var survolee: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.prefix(9).enumerated()), id: \.element.id) { rang, item in
                ligne(rang: rang, item: item)
            }
            // Sans cette mention, une liste vide donnerait un panneau sans aucun pixel
            // dessiné, indiscernable d'un panneau qui ne s'affiche pas.
            //
            // Branche INATTEIGNABLE par le geste Cmd : `HotKeyMachine` garde
            // `(.arme, .key(.v))` par un `guard count > 0`, donc le panneau ne s'ouvre
            // jamais sur une liste vide. Elle est gardée quand même, car elle
            // redeviendra atteignable dès qu'un autre point d'ouverture existera, et
            // la tâche 14 pose un menu de barre, qui est exactement ce genre de point
            // d'entrée. La supprimer aujourd'hui pour la réécrire demain n'a pas de
            // sens.
            if model.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 12))
                    Text(l10n("overlay.aucune_entree")).font(.system(size: 12))
                }
                .foregroundColor(.secondary)
                .padding(10)
            }
            if model.texteBrut {
                Divider().opacity(0.4)
                HStack(spacing: 6) {
                    Image(systemName: "textformat").font(.system(size: 12))
                    Text(l10n("overlay.collage_texte_brut")).font(.system(size: 12))
                }
                .foregroundColor(.secondary)
                .padding(10)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(12)
        // N'oublie plus que la ligne survolée en sortant. Ce n'est PLUS lui qui fige
        // le geste : un `onHover` se déclenche à l'apparition de la vue sous un curseur
        // immobile, et le panneau se figeait donc tout seul en s'ouvrant au centre de
        // l'écran. Voir `HotKeyInput.sourisEntree`.
        .onHover { dedans in
            if !dedans { survolee = nil }
        }
    }

    private func ligne(rang: Int, item: ClipItem) -> some View {
        HStack(spacing: 6) {
            Text("\(rang + 1)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)
            // Même règle que dans le menu de barre : la vraie image gagne sur le
            // symbole. La vignette est déjà en mémoire, elle vient de `item.thumb`,
            // aucune charge utile n'est lue ici non plus.
            if let octets = item.thumb, let vignette = NSImage(data: octets) {
                Image(nsImage: vignette)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .cornerRadius(2)
            } else {
                Image(systemName: icone(item.kind)).font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            // `titreOuSecours` et non `item.title` : une image copiée n'a aucun texte,
            // donc aucun titre, et sa ligne était littéralement vide dans l'overlay.
            Text(titreAffiche(titreOuSecours(item)))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            // Mêmes deux cibles que dans le menu de barre, au même endroit, avec les
            // mêmes icônes. Deux gestes différents pour la même action selon la
            // surface, ce serait deux choses à apprendre au lieu d'une.
            if survolee == rang {
                Button {
                    model.onEpingler?(rang)
                } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(item.pinned ? l10n("action.deseingler") : l10n("action.epingler"))
                Button {
                    model.onSupprimer?(rang)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(l10n("action.supprimer"))
            } else if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rang == model.index ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onHover { dedans in survolee = dedans ? rang : (survolee == rang ? nil : survolee) }
    }
}
