import SwiftUI
import CoreLocation

struct PathRenderer {

    /// Maps coordinates onto a rect with a single, isotropic scale.
    ///
    /// Longitude degrees are shorter than latitude degrees by `cos(latitude)`, and the rect is
    /// rarely square. Folding both into the projection is what keeps a drawn route the shape it
    /// was actually walked instead of being stretched east-west.
    fileprivate struct Viewport {
        let centerLatitude: Double
        let centerLongitude: Double
        /// Length of a longitude degree relative to a latitude degree at this latitude.
        let longitudeScale: Double
        /// Latitude degrees covered from top to bottom of the rect.
        let verticalSpan: Double
        /// Latitude-equivalent degrees covered from left to right of the rect.
        let horizontalSpan: Double
        let rect: CGRect

        init(center: Coordinate, verticalSpan: Double, rect: CGRect) {
            centerLatitude = center.latitude
            centerLongitude = center.longitude
            longitudeScale = max(cos(center.latitude * .pi / 180), 0.01)
            self.verticalSpan = max(verticalSpan, 1e-9)
            let aspect = Double(max(rect.width, 1) / max(rect.height, 1))
            horizontalSpan = self.verticalSpan * aspect
            self.rect = rect
        }

        func point(for coordinate: Coordinate) -> CGPoint {
            let dx = (coordinate.longitude - centerLongitude) * longitudeScale / horizontalSpan
            let dy = (coordinate.latitude - centerLatitude) / verticalSpan
            return CGPoint(x: rect.midX + CGFloat(dx) * rect.width,
                           y: rect.midY - CGFloat(dy) * rect.height)
        }
    }

    /// A fixed coordinate-to-rect mapping, built once and shared by everything in one drawing.
    ///
    /// Every path, marker and icon that belongs to the same picture must be placed through the
    /// *same* frame. Letting each call derive its own from whatever points it was handed scales
    /// each colour segment independently to fill the rect, which tears a multi-colour route into
    /// pieces drawn at different sizes in different places.
    struct Frame {
        fileprivate let viewport: Viewport
    }

    /// Builds the frame for a whole drawing. Pass *all* the points that will appear in it.
    static func frame(
        for points: [Coordinate],
        in rect: CGRect,
        minViewArea: Double? = nil,
        fixedViewArea: Double? = nil,
        centerLocation: Coordinate? = nil
    ) -> Frame? {
        viewport(for: points, in: rect, minViewArea: minViewArea, fixedViewArea: fixedViewArea, centerLocation: centerLocation)
            .map(Frame.init(viewport:))
    }

    /// Builds the viewport for a set of points, honouring an explicit fixed zoom when given
    /// and otherwise fitting the points with a margin.
    fileprivate static func viewport(
        for points: [Coordinate],
        in rect: CGRect,
        minViewArea: Double?,
        fixedViewArea: Double?,
        centerLocation: Coordinate?
    ) -> Viewport? {
        if let fixedArea = fixedViewArea, let center = centerLocation {
            return Viewport(center: center, verticalSpan: sqrt(fixedArea), rect: rect)
        }

        guard let minLat = points.map({ $0.latitude }).min(),
              let maxLat = points.map({ $0.latitude }).max(),
              let minLon = points.map({ $0.longitude }).min(),
              let maxLon = points.map({ $0.longitude }).max() else { return nil }

        let center = Coordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let longitudeScale = max(cos(center.latitude * .pi / 180), 0.01)
        let aspect = Double(max(rect.width, 1) / max(rect.height, 1))

        // Vertical span needed to contain the route both ways, in latitude degrees.
        let neededForLatitude = maxLat - minLat
        let neededForLongitude = (maxLon - minLon) * longitudeScale / aspect
        var span = max(neededForLatitude, neededForLongitude) * 1.2 // 20% margin

        if let minArea = minViewArea {
            span = max(span, sqrt(minArea))
        }
        // Floor keeps a single-point or near-stationary route from projecting to infinity.
        span = max(span, 1e-6)

        return Viewport(center: center, verticalSpan: span, rect: rect)
    }

    /// Creates a smooth path through `points` using a Catmull-Rom spline expressed as cubic Béziers.
    /// Guarantees C1 continuity (matching tangent direction at every join).
    /// - Parameter smoothness: 1.0 is a standard uniform Catmull-Rom; 0 degenerates to straight
    ///   segments. Values above ~1.2 start to overshoot at sharp turns.
    private static func createSmoothPath(from points: [CGPoint], smoothness: CGFloat = 1.0) -> Path {
        guard points.count > 1 else { return Path() }

        var path = Path()
        path.move(to: points[0])

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        // Catmull-Rom's control points sit one sixth of the way along the neighbouring chord.
        // Scaling that offset is what `smoothness` means — dividing by it instead inflates the
        // control points and makes the curve loop out past its own points at every sharp turn.
        let offset = max(smoothness, 0) / 6.0

        for i in 0..<points.count - 1 {
            let p0 = (i > 0) ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = (i + 2 < points.count) ? points[i + 2] : points[i + 1]

            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * offset,
                y: p1.y + (p2.y - p0.y) * offset
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * offset,
                y: p2.y - (p3.y - p1.y) * offset
            )

            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }

        return path
    }

    /// Returns a SwiftUI Path for the provided GPS points, scaled to fit inside `rect`.
    ///
    /// - Parameters:
    ///   - points: GPS coordinates to render as a path
    ///   - rect: The rectangle to fit the path within
    ///   - addJitter: Whether to add small random variations to points
    ///   - minViewArea: Minimum area to show in square degrees (for zoom control)
    ///   - fixedViewArea: Fixed area to show in square degrees (for map-like behavior)
    ///   - centerLocation: Location to center the view on (used with fixedViewArea)
    ///   - smoothness: Curve tightness; 1.0 is a standard Catmull-Rom spline
    static func makePath(from points: [Coordinate], in rect: CGRect, addJitter: Bool = false, minViewArea: Double? = nil, fixedViewArea: Double? = nil, centerLocation: Coordinate? = nil, smoothness: CGFloat = 1.0) -> Path {
        guard let frame = frame(for: points, in: rect, minViewArea: minViewArea, fixedViewArea: fixedViewArea, centerLocation: centerLocation) else {
            return Path()
        }
        return makePath(from: points, in: frame, addJitter: addJitter, smoothness: smoothness)
    }

    /// Returns a SwiftUI Path for `points`, placed through an existing frame.
    ///
    /// This is the overload to use when a drawing has more than one path in it — one frame built
    /// from every point in the picture, then each segment drawn through it.
    static func makePath(from points: [Coordinate], in frame: Frame, addJitter: Bool = false, smoothness: CGFloat = 1.0) -> Path {
        guard points.count > 1 else { return Path() }

        let rect = frame.viewport.rect
        // Display-time simplification for performance (does not modify source data)
        let displayPoints = points.count > 2000 ? simplifyPath(points, tolerance: 0.3) : points

        var scaledPoints: [CGPoint] = []
        scaledPoints.reserveCapacity(displayPoints.count)
        for coordinate in displayPoints {
            var scaled = frame.viewport.point(for: coordinate)
            if addJitter {
                scaled.x += CGFloat.random(in: -0.005...0.005) * rect.width
                scaled.y += CGFloat.random(in: -0.005...0.005) * rect.height
            }
            scaledPoints.append(scaled)
        }

        return createSmoothPath(from: scaledPoints, smoothness: smoothness)
    }

    /// Positions a single coordinate through an existing frame.
    static func point(for target: Coordinate, in frame: Frame) -> CGPoint {
        frame.viewport.point(for: target)
    }

    static func point(for target: Coordinate, in rect: CGRect, fixedViewArea: Double? = nil, centerLocation: Coordinate? = nil, minViewArea: Double? = nil) -> CGPoint {
        guard let viewport = viewport(for: [target], in: rect, minViewArea: minViewArea, fixedViewArea: fixedViewArea, centerLocation: centerLocation) else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return viewport.point(for: target)
    }

    /// Positions `target` in the same frame `makePath(from: points, ...)` would use.
    static func point(for target: Coordinate, relativeTo points: [Coordinate], in rect: CGRect, minViewArea: Double? = nil) -> CGPoint {
        guard let viewport = viewport(for: points, in: rect, minViewArea: minViewArea, fixedViewArea: nil, centerLocation: nil) else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return viewport.point(for: target)
    }

    // MARK: - Contextual Illustrations Support

    /// Converts contextual illustrations to positioned icons for rendering
    /// - Parameters:
    ///   - illustrations: The illustrations to position
    ///   - points: The path points (used for coordinate system calculation)
    ///   - rect: The rendering rectangle
    ///   - fixedViewArea: Optional fixed view area for map-like behavior
    ///   - centerLocation: Optional center location for fixed view
    ///   - minViewArea: Optional minimum view area
    /// - Returns: Array of positioned illustrations ready for rendering
    static func positionIllustrations(
        _ illustrations: [ContextualIllustration],
        relativeTo points: [Coordinate],
        in rect: CGRect,
        fixedViewArea: Double? = nil,
        centerLocation: Coordinate? = nil,
        minViewArea: Double? = nil
    ) -> [PositionedIllustration] {

        guard let frame = frame(for: points, in: rect, minViewArea: minViewArea, fixedViewArea: fixedViewArea, centerLocation: centerLocation) else {
            return []
        }
        return positionIllustrations(illustrations, in: frame)
    }

    /// Positions illustrations through an existing frame, so icons land on the route they
    /// were detected along rather than in a frame of their own.
    static func positionIllustrations(_ illustrations: [ContextualIllustration], in frame: Frame) -> [PositionedIllustration] {
        // More lenient bounds checking - include icons near the edges
        let expandedRect = frame.viewport.rect.insetBy(dx: -50, dy: -50) // 50pt margin
        return illustrations.compactMap { illustration in
            let position = frame.viewport.point(for: illustration.coordinate)
            guard expandedRect.contains(position) else { return nil }
            return PositionedIllustration(illustration: illustration, position: position)
        }
    }

    /// Positions scenery against a route, building the frame the same way the path does.
    static func positionScenery(
        _ scenery: [SceneryItem],
        relativeTo points: [Coordinate],
        in rect: CGRect,
        fixedViewArea: Double? = nil,
        centerLocation: Coordinate? = nil,
        minViewArea: Double? = nil
    ) -> [PositionedScenery] {
        guard let frame = frame(for: points, in: rect, minViewArea: minViewArea, fixedViewArea: fixedViewArea, centerLocation: centerLocation) else {
            return []
        }
        return positionScenery(scenery, in: frame)
    }

    /// Positions scenery through an existing frame, exactly as illustrations are positioned, so
    /// decoration and real places land in the same drawing rather than in frames of their own.
    static func positionScenery(_ scenery: [SceneryItem], in frame: Frame) -> [PositionedScenery] {
        let expandedRect = frame.viewport.rect.insetBy(dx: -50, dy: -50)
        return scenery.compactMap { item in
            let position = frame.viewport.point(for: item.coordinate)
            guard expandedRect.contains(position) else { return nil }
            return PositionedScenery(item: item, position: position)
        }
    }

    // MARK: - Douglas-Peucker Path Simplification

    /// Simplifies a path, with `tolerance` expressed in metres.
    static func simplifyPath(_ points: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard points.count > 2 else { return points }

        let metresPerDegreeLatitude = 111_320.0
        let longitudeScale = max(cos(points[0].latitude * .pi / 180), 0.01)

        /// Distance in metres from `point` to the segment `lineStart`–`lineEnd`.
        func perpendicularDistance(_ point: Coordinate, lineStart: Coordinate, lineEnd: Coordinate) -> Double {
            let px = (point.longitude - lineStart.longitude) * longitudeScale * metresPerDegreeLatitude
            let py = (point.latitude - lineStart.latitude) * metresPerDegreeLatitude
            let bx = (lineEnd.longitude - lineStart.longitude) * longitudeScale * metresPerDegreeLatitude
            let by = (lineEnd.latitude - lineStart.latitude) * metresPerDegreeLatitude

            let lengthSquared = bx * bx + by * by
            guard lengthSquared > 0 else { return hypot(px, py) }
            let t = min(max((px * bx + py * by) / lengthSquared, 0), 1)
            return hypot(px - t * bx, py - t * by)
        }

        func douglasPeucker(_ points: [Coordinate], start: Int, end: Int, tolerance: Double) -> [Coordinate] {
            guard end > start + 1 else { return [points[start], points[end]] }

            var maxDistance = 0.0
            var maxIndex = start

            for i in (start + 1)..<end {
                let distance = perpendicularDistance(points[i], lineStart: points[start], lineEnd: points[end])
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = i
                }
            }

            if maxDistance > tolerance {
                let left = douglasPeucker(points, start: start, end: maxIndex, tolerance: tolerance)
                let right = douglasPeucker(points, start: maxIndex, end: end, tolerance: tolerance)
                return left + Array(right.dropFirst())
            } else {
                return [points[start], points[end]]
            }
        }

        return douglasPeucker(points, start: 0, end: points.count - 1, tolerance: tolerance)
    }
}

/// A contextual illustration with its calculated screen position
struct PositionedIllustration: Identifiable {
    let id = UUID()
    let illustration: ContextualIllustration
    let position: CGPoint
}

/// A piece of scenery with its calculated screen position
struct PositionedScenery: Identifiable {
    let id = UUID()
    let item: SceneryItem
    let position: CGPoint
}
