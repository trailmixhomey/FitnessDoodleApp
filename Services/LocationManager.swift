import Foundation
import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var locations: [CLLocation] = []
    @Published private(set) var distance: CLLocationDistance = 0
    @Published private(set) var isTracking: Bool = false

    private let manager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()
    private var startTime: Date?

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.delegate = self
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isTracking else { return }
        distance = 0
        locations = []
        startTime = Date()
        isTracking = true
        manager.startUpdatingLocation()
    }

    func stop() -> (points: [Coordinate], distance: CLLocationDistance, duration: TimeInterval) {
        manager.stopUpdatingLocation()
        isTracking = false
        let duration = Date().timeIntervalSince(startTime ?? Date())
        let points = locations.map { Coordinate($0.coordinate) }
        return (points, distance, duration)
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations new: [CLLocation]) {
        guard isTracking else { return }
        for loc in new where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 20 {
            if let last = locations.last {
                distance += last.distance(from: loc)
            }
            locations.append(loc)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            // automatically start? no-op
        }
    }
} 