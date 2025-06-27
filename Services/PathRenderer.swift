import SwiftUI
import CoreLocation

struct PathRenderer {
    /// Returns a SwiftUI Path that represents the provided gps points scaled to fit inside `rect` (preserving aspect ratio).
    static func makePath(from points: [Coordinate], in rect: CGRect, addJitter: Bool = false) -> Path {
        guard points.count > 1 else { return Path() }

        // Convert to CLLocationCoordinate2D for min/max calculations.
        let coords = points.map { $0.clLocation }

        guard let minLat = coords.map({ $0.latitude }).min(),
              let maxLat = coords.map({ $0.latitude }).max(),
              let minLon = coords.map({ $0.longitude }).min(),
              let maxLon = coords.map({ $0.longitude }).max() else {
            return Path()
        }

        let latRange = maxLat - minLat
        let lonRange = maxLon - minLon
        let scale = max(latRange, lonRange)

        func convert(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let x = (coord.longitude - minLon) / scale
            let y = (coord.latitude - minLat) / scale
            // Flip y so north is up
            return CGPoint(x: x, y: 1 - y)
        }

        var path = Path()
        for (index, coord) in coords.enumerated() {
            var point = convert(coord)
            if addJitter {
                point.x += CGFloat.random(in: -0.005...0.005)
                point.y += CGFloat.random(in: -0.005...0.005)
            }
            let scaled = CGPoint(x: rect.minX + point.x * rect.width,
                                  y: rect.minY + point.y * rect.height)
            if index == 0 {
                path.move(to: scaled)
            } else {
                path.addLine(to: scaled)
            }
        }
        return path
    }
} 