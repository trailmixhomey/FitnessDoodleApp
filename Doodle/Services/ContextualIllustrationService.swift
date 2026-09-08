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

class ContextualIllustrationService: ObservableObject {
    @Published var illustrations: [ContextualIllustration] = []
    
    // Configuration
    private let detectionRadius: Double = 100 // meters
    private let minDistanceBetweenIcons: Double = 100 // meters
    private let maxIconsPerDoodle: Int = 15
    
    func detectIllustrationsAlongPath(_ path: [Coordinate]) async {
        Log.tracking.info("Starting POI detection along path with \(path.count) points")

        // Sample points along the path to avoid too many API calls
        let sampledPath = samplePath(path, maxPoints: 20)

        var allIllustrations: [ContextualIllustration] = []

        for (_, coordinate) in sampledPath.enumerated() {
            let nearbyIllustrations = await searchForPOIs(near: coordinate)
            allIllustrations.append(contentsOf: nearbyIllustrations)
        }

        // Remove duplicates and cluster nearby POIs
        let clusteredIllustrations = clusterAndFilterIllustrations(allIllustrations)

        // Limit total number of icons
        let finalIllustrations = Array(clusteredIllustrations.prefix(maxIconsPerDoodle))
        
        DispatchQueue.main.async { [weak self] in
            self?.illustrations = finalIllustrations
            Log.tracking.info("Found \(finalIllustrations.count) contextual illustrations")
        }
    }
    
    private func samplePath(_ path: [Coordinate], maxPoints: Int) -> [Coordinate] {
        guard path.count > maxPoints else { return path }
        
        let step = path.count / maxPoints
        var sampledPath: [Coordinate] = []
        
        for i in stride(from: 0, to: path.count, by: step) {
            sampledPath.append(path[i])
        }
        
        // Always include the last point
        if let last = path.last, sampledPath.last != last {
            sampledPath.append(last)
        }
        
        return sampledPath
    }
    
    private func searchForPOIs(near coordinate: Coordinate) async -> [ContextualIllustration] {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: detectionRadius / 111000, // Rough conversion to degrees
                longitudeDelta: detectionRadius / 111000
            )
        )
        request.resultTypes = .pointOfInterest
        
        let search = MKLocalSearch(request: request)
        
        do {
            let response = try await search.start()

            var illustrations: [ContextualIllustration] = []

            for item in response.mapItems {
                if let category = item.pointOfInterestCategory,
                   let illustration = mapPOIToIllustration(item, category: category) {
                    illustrations.append(illustration)
                }
            }

            return illustrations
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