import CoreLocation
import Foundation

/// A piece of decorative scenery placed alongside a walked route.
///
/// Scenery is *plausible*, not real. MapKit has no residential or vegetation data — 73 point-of-
/// interest categories and not one of them a house — so there is no way to draw the houses you
/// actually walked past. What Apple will tell us is whether the ground under a stretch of route
/// carries street addresses at all, and that is the difference between a house drawn along a
/// residential street and a house drawn in the middle of an open field.
struct SceneryItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case house
        case shopfront
        case tree
        case bush
        case wave
    }

    var id = UUID()
    let kind: Kind
    let coordinate: Coordinate
    /// Mirrors the icon, so a repeated kind reads as a row of houses rather than a row of stamps.
    let flipped: Bool

    enum CodingKeys: String, CodingKey { case kind, coordinate, flipped }
}

/// What kind of ground a stretch of route runs over.
enum LandClass: String, Codable {
    /// A street with house numbers and few businesses.
    case residential
    /// A street with house numbers and a lot of commerce.
    case commercial
    /// Inside a named park or similar, with no street addresses.
    case openSpace
    case coastal
    /// Not established. Nothing is drawn here — scenery fails quiet rather than guessing.
    case unknown
}

/// Places decorative scenery along a route, constrained by what the ground can plausibly hold.
///
/// Two constraints do the work. Scenery is only ever placed in a narrow band beside the track
/// that was actually walked, so it cannot land in the middle of somewhere nobody went; and the
/// land class of each stretch decides *what* may be drawn there.
@MainActor
final class SceneryService: ObservableObject {
    @Published private(set) var scenery: [SceneryItem] = []

    /// Route distance between land-class samples. Reverse geocoding is rate limited, so this is
    /// far coarser than the point-of-interest search spacing.
    private let classificationSpacing: CLLocationDistance = 250
    /// Reverse geocodes issued per pass. CLGeocoder throttles aggressively and answers a burst
    /// with failures, so a long route is classified over several passes rather than all at once.
    private let maxGeocodesPerPass = 2
    /// Minimum wall-clock gap between geocodes.
    private let minGeocodeInterval: TimeInterval = 3
    /// Above this many nearby places, an addressed street is commercial rather than residential.
    private let commercialDensityThreshold = 12
    /// Scenery further than this from its stretch's classification is not drawn.
    private let maxClassificationReach: CLLocationDistance = 400

    private var classifications: [(centre: Coordinate, klass: LandClass)] = []
    private var lastGeocodeAt: Date?
    private let geocoder = CLGeocoder()

    /// Placement state, so a growing route only places scenery on ground it has not covered.
    /// Rebuilding the whole route on every scan meant a 3 km walk re-deciding placement for
    /// every point three hundred times over, each decision searching every land class.
    private var placedItems: [SceneryItem] = []
    private var placedUpTo = 0
    private var sinceLastItem: CLLocationDistance = 0
    private var classificationCountAtPlacement = 0
    /// Last point of the route as it stood when placement last ran, used to tell a route that
    /// has grown from one that has been replaced wholesale by the end-of-session smoothing.
    private var placedPathTail: Coordinate?

    /// Classifies any newly-walked ground and rebuilds the scenery for the whole route.
    ///
    /// - Parameter placeDensity: how many real places the illustration service found near a
    ///   coordinate. This is what separates a shopping street from a residential one; both carry
    ///   street numbers and reverse geocoding alone cannot tell them apart.
    @discardableResult
    func updateScenery(along path: [Coordinate], placeDensity: (Coordinate) -> Int) async -> [SceneryItem] {
        await classifyNewGround(along: path, placeDensity: placeDensity)
        scenery = placeScenery(along: path)
        return scenery
    }

    func reset() {
        classifications = []
        lastGeocodeAt = nil
        scenery = []
        resetPlacement()
    }

    private func resetPlacement() {
        placedItems = []
        placedUpTo = 0
        sinceLastItem = 0
        placedPathTail = nil
    }

    // MARK: - Classification

    private func classifyNewGround(along path: [Coordinate], placeDensity: (Coordinate) -> Int) async {
        let centres = uncoveredCentres(along: path, spacing: classificationSpacing,
                                       covered: classifications.map(\.centre))
        guard !centres.isEmpty else { return }

        for centre in centres.prefix(maxGeocodesPerPass) {
            if let last = lastGeocodeAt {
                let wait = minGeocodeInterval - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            lastGeocodeAt = Date()

            let klass = await classify(centre, placeDensity: placeDensity(centre))
            classifications.append((centre, klass))
            Log.tracking.notice("Land class at route sample: \(klass.rawValue, privacy: .public)")
        }
    }

    private func classify(_ coordinate: Coordinate, placeDensity: Int) async -> LandClass {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            Log.tracking.info("Reverse geocode gave nothing; leaving stretch unclassified")
            return .unknown
        }

        let areas = placemark.areasOfInterest ?? []

        if placemark.ocean != nil { return .coastal }
        if areas.contains(where: { $0.localizedCaseInsensitiveContains("beach") }) { return .coastal }

        // A street number is the signal that buildings line this stretch. Reverse geocoding
        // returns the segment's address range ("2569-2593 W Townley Ave"), not a pin per house,
        // which is exactly enough to know houses belong here without knowing where they stand.
        if placemark.subThoroughfare != nil {
            return placeDensity >= commercialDensityThreshold ? .commercial : .residential
        }

        // Named somewhere, but with no addresses: a park, a recreation area, open ground.
        if !areas.isEmpty { return .openSpace }

        return .unknown
    }

    /// The land class governing a coordinate: the nearest sample, if one is close enough to speak
    /// for it.
    private func klass(at coordinate: Coordinate) -> LandClass {
        let nearest = classifications.min {
            distance($0.centre, coordinate) < distance($1.centre, coordinate)
        }
        guard let nearest, distance(nearest.centre, coordinate) <= maxClassificationReach else {
            return .unknown
        }
        return nearest.klass
    }

    // MARK: - Placement

    /// Rules for one land class: what may be drawn, how often, and how far off the path.
    private struct Recipe {
        let kinds: [SceneryItem.Kind]
        let spacing: CLLocationDistance
        let minOffset: CLLocationDistance
        let maxOffset: CLLocationDistance
    }

    private func recipe(for klass: LandClass) -> Recipe? {
        switch klass {
        case .residential:
            return Recipe(kinds: [.house, .house, .house, .tree], spacing: 32, minOffset: 12, maxOffset: 22)
        case .commercial:
            return Recipe(kinds: [.shopfront, .shopfront, .tree], spacing: 26, minOffset: 10, maxOffset: 18)
        case .openSpace:
            return Recipe(kinds: [.tree, .tree, .bush], spacing: 22, minOffset: 8, maxOffset: 26)
        case .coastal:
            return Recipe(kinds: [.wave, .wave, .bush], spacing: 34, minOffset: 16, maxOffset: 30)
        case .unknown:
            // Nothing is known about this ground, so nothing is drawn on it.
            return nil
        }
    }

    private func placeScenery(along path: [Coordinate]) -> [SceneryItem] {
        guard path.count > 1 else { return placedItems }

        // A newly-arrived land class can change what belongs on ground already walked, and the
        // end of a session replaces the live track wholesale with the smoothed one. Either means
        // the existing placement no longer describes this route, so start it over.
        let isExtension = placedUpTo > 0
            && path.count >= placedUpTo
            && placedPathTail == path[placedUpTo - 1]
        if !isExtension || classifications.count != classificationCountAtPlacement {
            resetPlacement()
            classificationCountAtPlacement = classifications.count
        }

        var items = placedItems
        var sinceLast = sinceLastItem

        for index in max(placedUpTo, 1)..<path.count {
            let previous = path[index - 1]
            let current = path[index]
            sinceLast += distance(previous, current)

            guard let recipe = recipe(for: klass(at: current)) else {
                // Reset the accumulator so a stretch of unknown ground does not immediately
                // deposit an item the moment the route becomes classifiable again.
                sinceLast = 0
                continue
            }
            guard sinceLast >= recipe.spacing else { continue }
            sinceLast = 0

            // Seeded from the anchor point itself, so an item stays put across redraws and
            // survives the route being re-smoothed when the session ends.
            var rng = SeededGenerator(seed: seed(for: current))

            let kind = recipe.kinds[Int(rng.next() % UInt64(recipe.kinds.count))]
            let span = recipe.maxOffset - recipe.minOffset
            let offset = recipe.minOffset + Double(rng.next() % 1000) / 1000 * span
            let side: Double = rng.next() % 2 == 0 ? 1 : -1
            let flipped = rng.next() % 2 == 0

            let anchor = offsetPerpendicular(to: previous, and: current, from: current,
                                             by: offset * side)
            items.append(SceneryItem(kind: kind, coordinate: anchor, flipped: flipped))
        }

        placedItems = items
        sinceLastItem = sinceLast
        placedUpTo = path.count
        placedPathTail = path.last
        return items
    }

    /// Moves `point` sideways off the line `from`->`to` by `metres` (signed: which side).
    private func offsetPerpendicular(to from: Coordinate, and to: Coordinate,
                                     from point: Coordinate,
                                     by metres: CLLocationDistance) -> Coordinate {
        let metresPerDegreeLatitude = 111_320.0
        let longitudeScale = max(cos(point.latitude * .pi / 180), 0.01)

        let dx = (to.longitude - from.longitude) * longitudeScale * metresPerDegreeLatitude
        let dy = (to.latitude - from.latitude) * metresPerDegreeLatitude
        let length = hypot(dx, dy)
        guard length > 0.01 else { return point }

        // Perpendicular to the direction of travel.
        let px = -dy / length
        let py = dx / length

        return Coordinate(
            latitude: point.latitude + (py * metres) / metresPerDegreeLatitude,
            longitude: point.longitude + (px * metres) / (metresPerDegreeLatitude * longitudeScale)
        )
    }

    // MARK: - Helpers

    /// Sample centres spaced by ground covered, minus anything already covered.
    private func uncoveredCentres(along path: [Coordinate],
                                  spacing: CLLocationDistance,
                                  covered: [Coordinate]) -> [Coordinate] {
        guard let first = path.first else { return [] }

        var candidates: [Coordinate] = [first]
        var travelled: CLLocationDistance = 0
        for (previous, current) in zip(path, path.dropFirst()) {
            travelled += distance(previous, current)
            if travelled >= spacing {
                candidates.append(current)
                travelled = 0
            }
        }

        var centres: [Coordinate] = []
        for candidate in candidates {
            let alreadyCovered = (covered + centres).contains { distance($0, candidate) < spacing }
            if !alreadyCovered { centres.append(candidate) }
        }
        return centres
    }

    private func distance(_ a: Coordinate, _ b: Coordinate) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// A stable seed for a coordinate, quantised to roughly a metre so that tiny changes in the
    /// smoothed track do not reshuffle the scenery.
    private func seed(for coordinate: Coordinate) -> UInt64 {
        let lat = UInt64(bitPattern: Int64((coordinate.latitude * 100_000).rounded()))
        let lon = UInt64(bitPattern: Int64((coordinate.longitude * 100_000).rounded()))
        return lat &* 0x9E3779B97F4A7C15 ^ lon &* 0xC2B2AE3D27D4EB4F
    }
}

/// Deterministic splitmix64. Scenery must land in the same place every time a doodle is drawn.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
