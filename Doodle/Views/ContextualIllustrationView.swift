import SwiftUI

/// SwiftUI view for rendering contextual illustrations on doodles
struct ContextualIllustrationView: View {
    let positionedIllustrations: [PositionedIllustration]
    let iconSize: CGFloat
    
    init(positionedIllustrations: [PositionedIllustration], iconSize: CGFloat = 24) {
        self.positionedIllustrations = positionedIllustrations
        self.iconSize = iconSize
    }
    
    var body: some View {
        ForEach(positionedIllustrations) { positioned in
            IllustrationIcon(
                illustration: positioned.illustration,
                size: iconSize
            )
            .position(positioned.position)
        }
    }
}

/// Individual illustration icon view
struct IllustrationIcon: View {
    let illustration: ContextualIllustration
    let size: CGFloat
    
    var body: some View {
        ZStack {
            // Background circle for better visibility - more prominent
            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: size + 12, height: size + 12)
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
            
            // Border ring for better contrast
            Circle()
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
                .frame(width: size + 12, height: size + 12)
            
            // Icon image - try multiple bundle paths
            if let image = loadIconImage(named: illustration.iconName) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                // Fallback to SF Symbol with better visibility
                fallbackIcon
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundColor(illustration.type.themeColor)
            }
        }
    }
    
    @ViewBuilder
    private var fallbackIcon: some View {
        switch illustration.type {
        case .park:
            Image(systemName: "tree.fill")
        case .cafe:
            Image(systemName: "cup.and.saucer.fill")
        case .restaurant:
            Image(systemName: "fork.knife")
        case .hotel:
            Image(systemName: "bed.double.fill")
        case .hospital:
            Image(systemName: "cross.fill")
        case .school:
            Image(systemName: "graduationcap.fill")
        case .beach:
            Image(systemName: "sun.max.fill")
        case .gasStation:
            Image(systemName: "fuelpump.fill")
        case .store:
            Image(systemName: "bag.fill")
        case .museum:
            Image(systemName: "building.columns.fill")
        case .library:
            Image(systemName: "books.vertical.fill")
        case .bank:
            Image(systemName: "banknote.fill")
        case .pharmacy:
            Image(systemName: "cross.case.fill")
        case .theater:
            Image(systemName: "theatermasks.fill")
        case .airport:
            Image(systemName: "airplane")
        case .zoo:
            Image(systemName: "pawprint.fill")
        case .amusementPark:
            Image(systemName: "ferriswheel")
        case .aquarium:
            Image(systemName: "fish.fill")
        case .bakery:
            Image(systemName: "birthday.cake.fill")
        case .gym:
            Image(systemName: "dumbbell.fill")
        case .generic:
            Image(systemName: "mappin.circle.fill")
        }
    }
}

// MARK: - Theme Colors for POI Types

extension ContextualIllustration.IllustrationType {
    var themeColor: Color {
        switch self {
        case .park:
            return .green
        case .cafe:
            return .brown
        case .restaurant:
            return .orange
        case .hotel:
            return .blue
        case .hospital:
            return .red
        case .school:
            return .purple
        case .beach:
            return .yellow
        case .gasStation:
            return .gray
        case .store:
            return .cyan
        case .museum:
            return .indigo
        case .library:
            return .teal
        case .bank:
            return .mint
        case .pharmacy:
            return .pink
        case .theater:
            return .purple
        case .airport:
            return .blue
        case .zoo:
            return .green
        case .amusementPark:
            return .pink
        case .aquarium:
            return .blue
        case .bakery:
            return .orange
        case .gym:
            return .red
        case .generic:
            return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    let sampleIllustrations = [
        ContextualIllustration(
            type: .park,
            coordinate: Coordinate(latitude: 37.7749, longitude: -122.4194),
            name: "Golden Gate Park",
            iconName: "icon_park"
        ),
        ContextualIllustration(
            type: .cafe,
            coordinate: Coordinate(latitude: 37.7849, longitude: -122.4094),
            name: "Blue Bottle Coffee",
            iconName: "icon_cafe"
        )
    ]
    
    let positionedIllustrations = [
        PositionedIllustration(
            illustration: sampleIllustrations[0],
            position: CGPoint(x: 100, y: 100)
        ),
        PositionedIllustration(
            illustration: sampleIllustrations[1],
            position: CGPoint(x: 200, y: 150)
        )
    ]
    
    ZStack {
        Rectangle()
            .fill(Color.gray.opacity(0.1))
            .frame(width: 300, height: 300)
        
        ContextualIllustrationView(positionedIllustrations: positionedIllustrations)
    }
}

// MARK: - Helper Extensions

extension IllustrationIcon {
    // Helper function to load icon images from different bundle locations
    private func loadIconImage(named iconName: String) -> UIImage? {
        print("🖼️ Attempting to load icon: \(iconName)")
        
        // Try loading from Icons folder first
        if let image = UIImage(named: "Icons/\(iconName)") {
            print("✅ Loaded icon from Icons/\(iconName)")
            return image
        }
        
        // Try direct name
        if let image = UIImage(named: iconName) {
            print("✅ Loaded icon from \(iconName)")
            return image
        }
        
        // Try with .png extension
        if let image = UIImage(named: "\(iconName).png") {
            print("✅ Loaded icon from \(iconName).png")
            return image
        }
        
        // Try Icons folder with .png
        if let image = UIImage(named: "Icons/\(iconName).png") {
            print("✅ Loaded icon from Icons/\(iconName).png")
            return image
        }
        
        // Try without Icons/ prefix but with full path
        if let image = UIImage(named: iconName.replacingOccurrences(of: "Icons/", with: "")) {
            print("✅ Loaded icon from \(iconName.replacingOccurrences(of: "Icons/", with: ""))")
            return image
        }
        
        print("❌ Failed to load icon: \(iconName) - will use SF Symbol fallback")
        return nil
    }
} 