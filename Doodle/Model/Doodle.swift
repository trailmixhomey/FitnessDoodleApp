import Foundation
import CoreLocation
import SwiftUI

struct Coordinate: Hashable, Codable {
    var latitude: CLLocationDegrees
    var longitude: CLLocationDegrees

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    /// Allows creating a Coordinate directly from numeric latitude/longitude values.
    init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct Doodle: Identifiable, Hashable, Codable {
    struct ColorSegment: Hashable, Codable {
        var colorHex: String
        var points: [Coordinate]

        var color: Color { Color(hex: colorHex) }
    }

    var id: UUID = UUID()
    var date: Date = Date()
    // Combined list of points for quick access (legacy support)
    var points: [Coordinate] = []
    var distance: CLLocationDistance = 0
    var duration: TimeInterval = 0
    var startColorHex: String = "#006693" // default primary

    var startColor: Color {
        Color(hex: startColorHex)
    }

    // Multi-colour segments (optional)
    var segments: [ColorSegment] = []
    
    // Contextual illustrations (optional)
    var illustrations: [ContextualIllustration] = []
    
    // Photo features
    var photos: [Data] = [] // Store UIImage as Data for Codable
    var savedPhotoOverlay: Data? // Final composed photo
    
    var hasPhotoOverlay: Bool {
        return savedPhotoOverlay != nil
    }

    /// Every point that appears when this doodle is drawn: the colour segments when it has them,
    /// and the flat point list otherwise.
    ///
    /// Build one `PathRenderer.Frame` from this and place the whole drawing through it. Deriving a
    /// frame per segment scales each colour to fill the rect on its own and pulls the route apart.
    var renderPoints: [Coordinate] {
        let segmentPoints = segments.flatMap { $0.points }
        return segmentPoints.isEmpty ? points : segmentPoints
    }
}
