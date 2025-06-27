import Foundation
import CoreLocation

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
    var id: UUID = UUID()
    var date: Date = Date()
    var points: [Coordinate] = []
    var distance: CLLocationDistance = 0
    var duration: TimeInterval = 0
} 