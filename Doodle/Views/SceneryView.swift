import SwiftUI

/// Draws the decorative scenery alongside a route.
///
/// Deliberately quieter than `ContextualIllustrationView`: scenery is texture, not information.
/// A real place gets a white badge and a name because it is a fact about the walk; a house is
/// set dressing and should never compete with the route line for attention.
struct SceneryView: View {
    let positionedScenery: [PositionedScenery]
    let itemSize: CGFloat

    init(positionedScenery: [PositionedScenery], itemSize: CGFloat = 18) {
        self.positionedScenery = positionedScenery
        self.itemSize = itemSize
    }

    var body: some View {
        ForEach(positionedScenery) { positioned in
            SceneryIcon(item: positioned.item, size: itemSize)
                .position(positioned.position)
        }
    }
}

struct SceneryIcon: View {
    let item: SceneryItem
    let size: CGFloat

    var body: some View {
        symbol
            .font(.system(size: size, weight: .light))
            .foregroundStyle(item.kind.tint)
            .scaleEffect(x: item.flipped ? -1 : 1, y: 1)
            .opacity(0.55)
    }

    @ViewBuilder
    private var symbol: some View {
        // The asset catalogue carries a hand-drawn house and park icon; everything else falls
        // back to a system symbol so a missing asset degrades to something rather than nothing.
        switch item.kind {
        case .house:
            if let image = UIImage(named: "icon_home") {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "house.fill")
            }
        case .shopfront:
            Image(systemName: "building.2.fill")
        case .tree:
            Image(systemName: "tree.fill")
        case .bush:
            Image(systemName: "leaf.fill")
        case .wave:
            Image(systemName: "water.waves")
        }
    }
}

private extension SceneryItem.Kind {
    var tint: Color {
        switch self {
        case .house:     return Color(red: 0.55, green: 0.42, blue: 0.32)
        case .shopfront: return Color(red: 0.45, green: 0.45, blue: 0.50)
        case .tree:      return Color(red: 0.28, green: 0.52, blue: 0.30)
        case .bush:      return Color(red: 0.38, green: 0.58, blue: 0.36)
        case .wave:      return Color(red: 0.32, green: 0.55, blue: 0.72)
        }
    }
}
