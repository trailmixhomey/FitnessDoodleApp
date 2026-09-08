import SwiftUI

extension Font {
    static func messy(_ style: TextStyle) -> Font {
        // Try custom font first, fallback to system font if it fails
        let customFont: Font
        switch style {
        case .largeTitle:   customFont = .custom("Messy Handwritten", size: 34, relativeTo: .largeTitle)
        case .title:        customFont = .custom("Messy Handwritten", size: 28, relativeTo: .title)
        case .title2:       customFont = .custom("Messy Handwritten", size: 22, relativeTo: .title2)
        case .title3:       customFont = .custom("Messy Handwritten", size: 20, relativeTo: .title3)
        case .headline:     customFont = .custom("Messy Handwritten", size: 17, relativeTo: .headline)
        case .subheadline:  customFont = .custom("Messy Handwritten", size: 15, relativeTo: .subheadline)
        case .body:         customFont = .custom("Messy Handwritten", size: 17, relativeTo: .body)
        case .callout:      customFont = .custom("Messy Handwritten", size: 16, relativeTo: .callout)
        case .footnote:     customFont = .custom("Messy Handwritten", size: 13, relativeTo: .footnote)
        case .caption:      customFont = .custom("Messy Handwritten", size: 12, relativeTo: .caption)
        case .caption2:     customFont = .custom("Messy Handwritten", size: 11, relativeTo: .caption2)
        @unknown default:   customFont = .custom("Messy Handwritten", size: 17, relativeTo: style)
        }
        
        return customFont
    }
    
    // Larger version for non-home screens (50% increase)
    static func messyLarge(_ style: TextStyle) -> Font {
        let customFont: Font
        switch style {
        case .largeTitle:   customFont = .custom("Messy Handwritten", size: 51, relativeTo: .largeTitle)    // 34 * 1.5
        case .title:        customFont = .custom("Messy Handwritten", size: 42, relativeTo: .title)        // 28 * 1.5
        case .title2:       customFont = .custom("Messy Handwritten", size: 33, relativeTo: .title2)       // 22 * 1.5
        case .title3:       customFont = .custom("Messy Handwritten", size: 30, relativeTo: .title3)       // 20 * 1.5
        case .headline:     customFont = .custom("Messy Handwritten", size: 26, relativeTo: .headline)     // 17 * 1.5
        case .subheadline:  customFont = .custom("Messy Handwritten", size: 23, relativeTo: .subheadline)  // 15 * 1.5
        case .body:         customFont = .custom("Messy Handwritten", size: 26, relativeTo: .body)         // 17 * 1.5
        case .callout:      customFont = .custom("Messy Handwritten", size: 24, relativeTo: .callout)      // 16 * 1.5
        case .footnote:     customFont = .custom("Messy Handwritten", size: 20, relativeTo: .footnote)     // 13 * 1.5
        case .caption:      customFont = .custom("Messy Handwritten", size: 18, relativeTo: .caption)      // 12 * 1.5
        case .caption2:     customFont = .custom("Messy Handwritten", size: 17, relativeTo: .caption2)     // 11 * 1.5
        @unknown default:   customFont = .custom("Messy Handwritten", size: 26, relativeTo: style)         // 17 * 1.5
        }
        
        return customFont
    }
    
    // Enhanced messy font with weight support
    static func messy(_ style: TextStyle, weight: Font.Weight) -> Font {
        // Use actual bold font file for bold and heavier weights
        switch weight {
        case .bold, .heavy, .black:
            // Use the actual bold font file
            let customFont: Font
            switch style {
            case .largeTitle:   customFont = .custom("MessyHandwritten-Bold", size: 34, relativeTo: .largeTitle)
            case .title:        customFont = .custom("MessyHandwritten-Bold", size: 28, relativeTo: .title)
            case .title2:       customFont = .custom("MessyHandwritten-Bold", size: 22, relativeTo: .title2)
            case .title3:       customFont = .custom("MessyHandwritten-Bold", size: 20, relativeTo: .title3)
            case .headline:     customFont = .custom("MessyHandwritten-Bold", size: 17, relativeTo: .headline)
            case .subheadline:  customFont = .custom("MessyHandwritten-Bold", size: 15, relativeTo: .subheadline)
            case .body:         customFont = .custom("MessyHandwritten-Bold", size: 17, relativeTo: .body)
            case .callout:      customFont = .custom("MessyHandwritten-Bold", size: 16, relativeTo: .callout)
            case .footnote:     customFont = .custom("MessyHandwritten-Bold", size: 13, relativeTo: .footnote)
            case .caption:      customFont = .custom("MessyHandwritten-Bold", size: 12, relativeTo: .caption)
            case .caption2:     customFont = .custom("MessyHandwritten-Bold", size: 11, relativeTo: .caption2)
            @unknown default:   customFont = .custom("MessyHandwritten-Bold", size: 17, relativeTo: style)
            }
            return customFont
        default:
            // Use regular font with weight modifier for other weights
            return messy(style).weight(weight)
        }
    }
    
    // Enhanced messy large font with weight support
    static func messyLarge(_ style: TextStyle, weight: Font.Weight) -> Font {
        // Use actual bold font file for bold and heavier weights
        switch weight {
        case .bold, .heavy, .black:
            // Use the actual bold font file with large sizes
            let customFont: Font
            switch style {
            case .largeTitle:   customFont = .custom("MessyHandwritten-Bold", size: 51, relativeTo: .largeTitle)    // 34 * 1.5
            case .title:        customFont = .custom("MessyHandwritten-Bold", size: 42, relativeTo: .title)        // 28 * 1.5
            case .title2:       customFont = .custom("MessyHandwritten-Bold", size: 33, relativeTo: .title2)       // 22 * 1.5
            case .title3:       customFont = .custom("MessyHandwritten-Bold", size: 30, relativeTo: .title3)       // 20 * 1.5
            case .headline:     customFont = .custom("MessyHandwritten-Bold", size: 26, relativeTo: .headline)     // 17 * 1.5
            case .subheadline:  customFont = .custom("MessyHandwritten-Bold", size: 23, relativeTo: .subheadline)  // 15 * 1.5
            case .body:         customFont = .custom("MessyHandwritten-Bold", size: 26, relativeTo: .body)         // 17 * 1.5
            case .callout:      customFont = .custom("MessyHandwritten-Bold", size: 24, relativeTo: .callout)      // 16 * 1.5
            case .footnote:     customFont = .custom("MessyHandwritten-Bold", size: 20, relativeTo: .footnote)     // 13 * 1.5
            case .caption:      customFont = .custom("MessyHandwritten-Bold", size: 18, relativeTo: .caption)      // 12 * 1.5
            case .caption2:     customFont = .custom("MessyHandwritten-Bold", size: 17, relativeTo: .caption2)     // 11 * 1.5
            @unknown default:   customFont = .custom("MessyHandwritten-Bold", size: 26, relativeTo: style)         // 17 * 1.5
            }
            return customFont
        default:
            // Use regular font with weight modifier for other weights
            return messyLarge(style).weight(weight)
        }
    }
}