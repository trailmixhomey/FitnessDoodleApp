import MapKit
import SwiftUI

struct ContextualIllustration: Identifiable, Codable, Hashable {
    let id = UUID()
    let type: IllustrationType
    let coordinate: Coordinate
    let name: String?
    let iconName: String // Placeholder for custom image names
    
    enum CodingKeys: String, CodingKey {
        case type, coordinate, name, iconName
    }
    
    enum IllustrationType: String, CaseIterable, Codable, Hashable {
        case park = "park"
        case cafe = "cafe"
        case restaurant = "restaurant"
        case hotel = "hotel"
        case hospital = "hospital"
        case school = "school"
        case beach = "beach"
        case gasStation = "gas_station"
        case store = "store"
        case museum = "museum"
        case library = "library"
        case bank = "bank"
        case pharmacy = "pharmacy"
        case theater = "theater"
        case airport = "airport"
        case zoo = "zoo"
        case amusementPark = "amusement_park"
        case aquarium = "aquarium"
        case bakery = "bakery"
        case gym = "gym"
        case generic = "generic"
        
        var displayName: String {
            switch self {
            case .park: return "Park"
            case .cafe: return "Cafe"
            case .restaurant: return "Restaurant"
            case .hotel: return "Hotel"
            case .hospital: return "Hospital"
            case .school: return "School"
            case .beach: return "Beach"
            case .gasStation: return "Gas Station"
            case .store: return "Store"
            case .museum: return "Museum"
            case .library: return "Library"
            case .bank: return "Bank"
            case .pharmacy: return "Pharmacy"
            case .theater: return "Theater"
            case .airport: return "Airport"
            case .zoo: return "Zoo"
            case .amusementPark: return "Amusement Park"
            case .aquarium: return "Aquarium"
            case .bakery: return "Bakery"
            case .gym: return "Gym"
            case .generic: return "Point of Interest"
            }
        }
    }
}

/// Finds the real, named places a route passed, so a doodle can show the cafe you actually
/// walked by rather than generic scenery.
///
/// Searching is incremental: each stretch of new ground is searched once and the results kept.
/// The previous implementation re-searched the whole route from scratch every ten fixes, which
/// on a normal walk is thousands of redundant requests and is answered with throttling.
@MainActor
final class ContextualIllustrationService: ObservableObject {
    @Published private(set) var illustrations: [ContextualIllustration] = []

    /// Radius of a single search around one point of the route.
    private let detectionRadius: CLLocationDistance = 150
    /// Two icons of the same kind closer than this are the same place seen twice.
    private let minDistanceBetweenIcons: CLLocationDistance = 100
    private let maxIconsPerDoodle = 15
    /// Route distance between search centres. Slightly under `detectionRadius` so consecutive
    /// searches overlap and no ground between them is missed.
    private let searchSpacing: CLLocationDistance = 120
    /// Ceiling on searches per call, so a long recovered route does not issue them in one burst.
    /// Anything not reached stays unsearched and is picked up by the next call.
    private let maxSearchesPerPass = 8

    /// Centres already searched. This is what makes a growing route cheap: ground covered by an
    /// earlier pass is never searched again.
    private var searchedCentres: [Coordinate] = []
    /// Everything found so far across all passes, before clustering.
    private var found: [ContextualIllustration] = []

    /// Searches any stretch of `path` not already covered, and returns the current icon set.
    ///
    /// The return value matters: callers build the saved doodle from it. Publishing to
    /// `illustrations` alone used to leave `await` returning before the assignment landed, so a
    /// finished doodle was saved with the *previous* pass's icons — empty, on a first run.
    @discardableResult
    func detectIllustrationsAlongPath(_ path: [Coordinate]) async -> [ContextualIllustration] {
        let centres = uncoveredCentres(along: path).prefix(maxSearchesPerPass)
        guard !centres.isEmpty else { return illustrations }

        Log.tracking.notice("POI scan: \(centres.count) new centre(s) over \(path.count) route points")

        for centre in centres {
            found.append(contentsOf: await searchForPOIs(near: centre))
            searchedCentres.append(centre)
        }

        illustrations = Array(clusterAndFilterIllustrations(found).prefix(maxIconsPerDoodle))
        Log.tracking.notice("POI scan: \(self.illustrations.count) illustration(s) after clustering")
        return illustrations
    }

    /// Clears state so a new session does not inherit the last one's places.
    func reset() {
        searchedCentres = []
        found = []
        illustrations = []
    }

    /// Search centres spaced along the route, minus any ground an earlier pass already covered.
    ///
    /// The old `samplePath` divided the point count by a maximum and strided by the result, so
    /// integer division gave a step of 1 for any route of 21-39 points — returning every point
    /// rather than capping them. Spacing by real distance makes the cost proportional to ground
    /// covered instead of to fix count.
    private func uncoveredCentres(along path: [Coordinate]) -> [Coordinate] {
        guard let first = path.first else { return [] }

        var centres: [Coordinate] = []
        var candidates: [Coordinate] = [first]
        var travelled: CLLocationDistance = 0

        for (previous, current) in zip(path, path.dropFirst()) {
            travelled += distanceBetween(previous, current)
            if travelled >= searchSpacing {
                candidates.append(current)
                travelled = 0
            }
        }
        if let last = path.last, candidates.last.map({ distanceBetween($0, last) > searchSpacing / 2 }) ?? true {
            candidates.append(last)
        }

        for candidate in candidates {
            let alreadyCovered = (searchedCentres + centres).contains {
                distanceBetween($0, candidate) < searchSpacing
            }
            if !alreadyCovered { centres.append(candidate) }
        }
        return centres
    }

    private func searchForPOIs(near coordinate: Coordinate) async -> [ContextualIllustration] {
        // `MKLocalSearch.Request` is a *text* search and fails outright without a
        // `naturalLanguageQuery`. Every search this service ever made errored on that, which is
        // why no illustration has ever appeared. `MKLocalPointsOfInterestRequest` is the
        // region-based API this code always wanted.
        let request = MKLocalPointsOfInterestRequest(
            center: coordinate.clLocation,
            radius: min(detectionRadius, MKLocalPointsOfInterestRequest.maxRadius)
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { item in
                guard let category = item.pointOfInterestCategory else { return nil }
                return mapPOIToIllustration(item, category: category)
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            // Genuinely nothing here — a quiet residential street or open ground. MapKit reports
            // an empty region as an error rather than an empty result, so this must be told apart
            // from a real failure or the next broken request will hide the same way this one did.
            Log.tracking.info("No POIs within \(self.detectionRadius)m of search centre")
            return []
        } catch {
            Log.tracking.error("POI search failed: \(error.localizedDescription)")
            return []
        }
    }

    private func mapPOIToIllustration(_ mapItem: MKMapItem, category: MKPointOfInterestCategory) -> ContextualIllustration? {
        let coordinate = Coordinate(
            latitude: mapItem.placemark.coordinate.latitude,
            longitude: mapItem.placemark.coordinate.longitude
        )
        
        let type: ContextualIllustration.IllustrationType
        let iconName: String
        
        switch category {
        case .park, .nationalPark:
            type = .park
            iconName = "icon_park" // Placeholder for your custom park icon
            
        case .cafe:
            type = .cafe
            iconName = "icon_restaurant" // Use restaurant icon as fallback
            
        case .restaurant:
            type = .restaurant
            iconName = "icon_restaurant"
            
        case .hotel:
            type = .hotel
            iconName = "icon_hotel"
            
        case .hospital:
            type = .hospital
            iconName = "icon_hospital"
            
        case .school, .university:
            type = .school
            iconName = "icon_school"
            
        case .beach:
            type = .beach
            iconName = "icon_beach"
            
        case .gasStation:
            type = .gasStation
            iconName = "icon_gas_station"
            
        case .store:
            type = .store
            iconName = "icon_store"
            
        case .museum:
            type = .museum
            iconName = "icon_museum"
            
        case .library:
            type = .library
            iconName = "icon_school" // Use school icon as fallback
            
        case .bank:
            type = .bank
            iconName = "icon_bank"
            
        case .pharmacy:
            type = .pharmacy
            iconName = "icon_hospital" // Use hospital icon as fallback
            
        case .theater:
            type = .theater
            iconName = "icon_amusement_park" // Use amusement park icon as fallback
            
        case .airport:
            type = .airport
            iconName = "icon_store" // Use store icon as fallback
            
        case .zoo:
            type = .zoo
            iconName = "icon_park" // Use park icon as fallback
            
        case .amusementPark:
            type = .amusementPark
            iconName = "icon_amusement_park"
            
        case .aquarium:
            type = .aquarium
            iconName = "icon_beach" // Use beach icon as fallback
            
        case .bakery:
            type = .bakery
            iconName = "icon_restaurant" // Use restaurant icon as fallback
            
        case .fitnessCenter:
            type = .gym
            iconName = "icon_hospital" // Use hospital icon as fallback
            
        default:
            // Skip less relevant POIs for fitness activities
            return nil
        }
        
        return ContextualIllustration(
            type: type,
            coordinate: coordinate,
            name: mapItem.name,
            iconName: iconName
        )
    }
    
    private func clusterAndFilterIllustrations(_ illustrations: [ContextualIllustration]) -> [ContextualIllustration] {
        var clustered: [ContextualIllustration] = []

        for illustration in illustrations {
            let isTooClose = clustered.contains { existing in
                let distance = distanceBetween(existing.coordinate, illustration.coordinate)
                return distance < minDistanceBetweenIcons && existing.type == illustration.type
            }

            if !isTooClose {
                clustered.append(illustration)
            }
        }

        return clustered
    }
    
    private func distanceBetween(_ coord1: Coordinate, _ coord2: Coordinate) -> Double {
        let location1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let location2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return location1.distance(from: location2)
    }
    

} 