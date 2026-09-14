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

    /// Decorative scenery placed alongside the route.
    ///
    /// Stored optional on purpose. A synthesized decoder throws `keyNotFound` for a missing
    /// non-optional key even when the property has a default, and `DoodleStore` answers a decode
    /// failure by setting the whole file aside — so adding a plain `var scenery: [SceneryItem]
    /// = []` here would have shown every existing user an empty gallery.
    /// Not `private`: a private stored property makes the synthesized memberwise initializer
    /// private too, which would put `Doodle(points:...)` out of reach of every other file.
    /// Being optional, it defaults to nil in that initializer, so existing call sites are
    /// unaffected. Read and write it through `scenery`.
    var sceneryItems: [SceneryItem]?

    var scenery: [SceneryItem] {
        get { sceneryItems ?? [] }
        set { sceneryItems = newValue }
    }
    
    // MARK: - Photos

    /// The photos taken on this walk, by identifier. Optional for the same reason
    /// `sceneryItems` is: a synthesized decoder throws `keyNotFound` for a missing non-optional
    /// key, and `DoodleStore` answers a decode failure by setting the whole file aside.
    /// Read and write it through `photos`.
    var photoRecords: [WalkPhoto]?

    var photos: [WalkPhoto] {
        get { photoRecords ?? [] }
        set { photoRecords = newValue }
    }

    /// The composed route-over-photo image, if one was made. Stored by identifier in
    /// `PhotoStore`, like every other photo.
    var overlayPhotoID: String?

    var hasPhotoOverlay: Bool { overlayPhotoID != nil }

    /// Photos the June 2025 build stored inline, as JPEG bytes inside the doodle itself.
    ///
    /// Kept only so `PhotoStore.migrateInlinePhotos` can move them into their own files on the
    /// first launch after the change; cleared once it has, and never written again. Dropping the
    /// property instead would have silently thrown away any photo taken with that build.
    var legacyPhotoData: [Data]?
    var legacyOverlayData: Data?

    /// Spelled out rather than synthesized so `legacyPhotoData` can keep reading the `photos` key
    /// the old format wrote, which a property of that name can no longer claim.
    ///
    /// The cost of being explicit is that a new stored property needs a case here too — without
    /// one it silently stops being saved.
    enum CodingKeys: String, CodingKey {
        case id, date, points, distance, duration, startColorHex, segments, illustrations
        case sceneryItems
        case photoRecords
        case overlayPhotoID
        case legacyPhotoData = "photos"
        case legacyOverlayData = "savedPhotoOverlay"
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
