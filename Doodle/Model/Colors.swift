import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    // Palette
    static let fernLight    = Color(hex: "#85D89B")
    static let fern         = Color(hex: "#4CAF50")
    static let fernDark     = Color(hex: "#2E6D31")

    static let coralLight   = Color(hex: "#FF9E9E")
    static let coral        = Color(hex: "#FF6B6B")
    static let coralDark    = Color(hex: "#993F3F")

    static let cantaloupeLight = Color(hex: "#FFE9B2")
    static let cantaloupe      = Color(hex: "#FFD27F")
    static let cantaloupeDark  = Color(hex: "#998048")

    static let ceruleanLight = Color(hex: "#66CBF6")
    static let cerulean      = Color(hex: "#00A6ED")
    static let ceruleanDark  = Color(hex: "#006693")

    static let ivoryLight = Color.white
    static let ivory      = Color(hex: "#FFF9F0")
    static let ivoryDark  = Color(hex: "#99968F")

    // Primary app color
    static let primaryColor = Color.ceruleanDark

    static func hexString(for color: Color) -> String {
        let mapping: [(Color, String)] = [
            (.fern, "#4CAF50"), (.fernLight, "#85D89B"), (.fernDark, "#2E6D31"),
            (.coral, "#FF6B6B"), (.coralLight, "#FF9E9E"), (.coralDark, "#993F3F"),
            (.cantaloupe, "#FFD27F"), (.cantaloupeLight, "#FFE9B2"), (.cantaloupeDark, "#998048"),
            (.cerulean, "#00A6ED"), (.ceruleanLight, "#66CBF6"), (.ceruleanDark, "#006693"),
            (.ivory, "#FFF9F0"), (.ivoryLight, "#FFFFFF"), (.ivoryDark, "#99968F"),
            (.primaryColor, "#006693")
        ]
        return mapping.first(where: { $0.0 == color })?.1 ?? "#000000"
    }
} 