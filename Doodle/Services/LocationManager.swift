import Foundation
import CoreLocation
import Combine
import UIKit

/// Turns a stream of filtered positions into the recorded track.
///
/// Both the live track and the final smoothed one are built through this, so the route you
/// watch being drawn and the route you save are assembled by exactly the same rules.
private struct TrackBuilder {

    enum Tuning {
        /// A silence longer than this counts as a signal outage rather than a slow update.
        static let outage: TimeInterval = 6
        /// Spacing of the interpolated points laid down across a bridged outage.
        static let bridgeSpacing: CLLocationDistance = 3
        static let maxBridgePoints = 500
        /// Above this implied speed a "gap" is a GPS jump or a vehicle, not the activity.
        static let maxBridgeSpeed: CLLocationSpeed = 15
        /// Hysteresis on the moving/stationary decision, in m/s.
        static let startMovingSpeed: CLLocationSpeed = 0.55
        static let stopMovingSpeed: CLLocationSpeed = 0.25
        /// Minimum spacing between recorded points.
        static let pointSpacing: CLLocationDistance = 0.6
        /// Even while judged stationary, this much real displacement is recorded anyway.
        static let stationaryDriftLimit: CLLocationDistance = 5
        /// Point spacing is relaxed beyond this count so very long sessions stay bounded
        /// without ever discarding recorded geometry.
        static let spacingRelaxationThreshold = 20000
    }

    private(set) var points: [Coordinate] = []
    /// Timestamp of each entry in `points`, so callers can align other data to the track.
    private(set) var timestamps: [Date] = []
    private(set) var distance: CLLocationDistance = 0
    private(set) var isMoving = false

    private var projection: LocalProjection?
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRecorded: CLLocationCoordinate2D?
    private var lastTimestamp: Date?

    mutating func add(_ coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, timestamp: Date) {
        guard let projection, let previous = lastCoordinate else {
            projection = LocalProjection(origin: coordinate)
            record(coordinate, at: timestamp)
            lastCoordinate = coordinate
            lastTimestamp = timestamp
            return
        }

        let gap = timestamp.timeIntervalSince(lastTimestamp ?? timestamp)
        lastCoordinate = coordinate
        lastTimestamp = timestamp

        if gap > Tuning.outage {
            bridgeOutage(from: previous, to: coordinate, over: gap, in: projection, endingAt: timestamp)
            return
        }

        // The movement decision comes from the estimated velocity, not from a distance floor.
        // A distance floor lets GPS jitter accumulate into phantom mileage while standing still.
        if isMoving {
            if speed < Tuning.stopMovingSpeed { isMoving = false }
        } else if speed > Tuning.startMovingSpeed {
            isMoving = true
        }

        guard isMoving else {
            // Slow but real displacement is still recorded, so a shuffle isn't dropped.
            if let recorded = lastRecorded {
                let drift = projection.distance(recorded, coordinate)
                if drift > Tuning.stationaryDriftLimit {
                    distance += drift
                    record(coordinate, at: timestamp)
                }
            }
            return
        }

        distance += projection.distance(previous, coordinate)

        guard let recorded = lastRecorded else {
            record(coordinate, at: timestamp)
            return
        }
        if projection.distance(recorded, coordinate) >= currentPointSpacing {
            record(coordinate, at: timestamp)
        }
    }

    /// Point spacing grows slowly on very long sessions. This bounds the array without ever
    /// throwing away geometry that has already been recorded.
    private var currentPointSpacing: CLLocationDistance {
        let overage = Double(points.count) / Double(Tuning.spacingRelaxationThreshold)
        return Tuning.pointSpacing * max(1, overage)
    }

    private mutating func record(_ coordinate: CLLocationCoordinate2D, at timestamp: Date) {
        points.append(Coordinate(coordinate))
        timestamps.append(timestamp)
        lastRecorded = coordinate
    }

    /// Lays interpolated points across a signal outage so the path stays continuous instead of
    /// jumping in a single long edge that the spline then has to bend around.
    private mutating func bridgeOutage(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        over duration: TimeInterval,
        in projection: LocalProjection,
        endingAt timestamp: Date
    ) {
        let span = projection.distance(from, to)
        guard span > Tuning.pointSpacing else {
            record(to, at: timestamp)
            return
        }

        let impliedSpeed = span / max(duration, 1)
        guard impliedSpeed <= Tuning.maxBridgeSpeed else {
            // Too fast to be the activity being recorded — a GPS jump or a vehicle. Continue the
            // track from here without inventing points or crediting the displacement.
            Log.location.warning("Discontinuity of \(span)m over \(duration)s (\(impliedSpeed) m/s); not bridging")
            record(to, at: timestamp)
            return
        }

        let steps = min(max(Int(span / Tuning.bridgeSpacing), 1), Tuning.maxBridgePoints)
        if steps > 1 {
            for i in 1..<steps {
                let t = Double(i) / Double(steps)
                let interpolated = CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * t,
                    longitude: from.longitude + (to.longitude - from.longitude) * t
                )
                record(interpolated, at: timestamp.addingTimeInterval(-duration * (1 - t)))
            }
        }
        distance += span
        record(to, at: timestamp)
        // We were clearly travelling to have covered this ground.
        isMoving = true
        Log.location.notice("Bridged \(span)m outage with \(steps) points")
    }
}

@MainActor
final class LocationManager: NSObject, ObservableObject {

    /// Coarse description of how much we currently trust the GPS, for the tracking UI.
    enum SignalQuality {
        case searching
        case poor
        case fair
        case good
    }

    /// The finished session, rebuilt from the smoothed track.
    struct Summary {
        var points: [Coordinate]
        /// Index into `points` at which each colour change after the first begins.
        var segmentStarts: [Int]
        var distance: CLLocationDistance
        var duration: TimeInterval

        /// Splits `points` into one run per colour the user drew with.
        ///
        /// Each run after the first is seeded with the previous run's last point so the colours
        /// meet without a visible gap, and out-of-range or out-of-order split indices are
        /// clamped rather than trusted — the track they index into was rebuilt by the smoother,
        /// not the live pass that produced them.
        func pointsPerSegment() -> [[Coordinate]] {
            guard !points.isEmpty else { return [] }

            var bounds: [Int] = [0]
            for start in segmentStarts {
                bounds.append(min(max(start, bounds[bounds.count - 1]), points.count))
            }
            bounds.append(points.count)

            var runs: [[Coordinate]] = []
            var lastPointOfPreviousRun: Coordinate?
            for i in 0..<(bounds.count - 1) {
                let lower = bounds[i]
                let upper = bounds[i + 1]
                guard upper > lower else {
                    runs.append([])
                    continue
                }
                var run = Array(points[lower..<upper])
                if let seed = lastPointOfPreviousRun {
                    run.insert(seed, at: 0)
                }
                lastPointOfPreviousRun = run.last
                runs.append(run)
            }
            return runs
        }
    }

    @Published private(set) var locations: [Coordinate] = []
    @Published private(set) var distance: CLLocationDistance = 0
    @Published private(set) var isTracking: Bool = false
    /// True while the filtered speed says we are actually travelling. Points and distance
    /// are only recorded while moving, which is what stops a stationary GPS from scribbling.
    @Published private(set) var isMoving: Bool = false
    @Published private(set) var signalQuality: SignalQuality = .searching
    /// True when location access has been refused, so the UI can say so instead of showing a
    /// tracking screen that will never record anything.
    @Published private(set) var accessDenied: Bool = false

    private let manager = CLLocationManager()
    private var filter = GPSTrackFilter()
    private var builder = TrackBuilder()
    private let journal = SessionJournal()

    private enum Tuning {
        /// Cold-start fixes are routinely 50–100 m out; ignore them briefly unless one is already good.
        static let warmUp: TimeInterval = 3
        static let warmUpAccuracy: CLLocationAccuracy = 25
        /// Hard rejection threshold. Deliberately generous — a poor fix still carries information,
        /// and the filter already weights it by its own accuracy. Dropping every fix under a
        /// bridge is what creates straight-line teleports.
        static let maxAccuracy: CLLocationAccuracy = 100
        /// Fixes older than this are stale replays, not the current position.
        static let maxFixAge: TimeInterval = 10
        /// How long a session runs before the Always upgrade is offered. iOS silently drops a
        /// request made in the same run loop as the When-In-Use answer, and the upgrade only
        /// means anything once background updates have actually been running.
        static let alwaysUpgradeDelay: TimeInterval = 20
    }

    /// Every accepted fix, kept so the whole track can be re-smoothed once the session ends.
    /// ~40 bytes each: a four-hour walk at 1 Hz costs well under a megabyte.
    private var rawFixes: [GPSFix] = []
    /// Timestamps at which the user switched colour, used to re-cut the smoothed track.
    private var segmentBreaks: [Date] = []

    private var startTime: Date?
    /// When `startUpdatingLocation` was last called. Warm-up is measured from here rather than
    /// from `startTime`, which on a resumed session is hours old.
    private var updatesStartedAt: Date?
    private var lastFixTime: Date?

    /// Set when `start` is called before the user has answered the permission prompt, so the
    /// session can begin the moment the answer arrives.
    private var startRequested = false
    private var pendingResume: SessionJournal.Recovered?
    private var startColorHex = "#006693"

    /// iOS only offers the Always upgrade once, and only in the right context. Remember that we
    /// have asked so a declined prompt is never put back in front of the user every session.
    ///
    /// Versioned: installs that ran the old code recorded an ask that iOS never actually raised,
    /// and would otherwise be locked out of the prompt forever. The new key gives them one.
    private static let alwaysRequestedKey = "hasRequestedAlwaysLocationAuthorization.v2"
    private var alwaysUpgradeWork: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    override init() {
        super.init()
        manager.delegate = self
        configureForTracking()
        Log.general.notice("LocationManager initialized")
    }

    private func configureForTracking() {
        // `.fitness` + `Best` is Apple's pedestrian configuration. `BestForNavigation` is tuned
        // for in-vehicle turn-by-turn and is documented as plugged-in-only.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // Filter in software, not in Core Location: a distance filter breaks the steady 1 Hz
        // cadence the velocity estimate depends on, and passes jitter through while stationary.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Since iOS 13 the first prompt only ever offers "While Using the App" whichever
            // method you call, so ask for what it can actually grant. Asking for Always here
            // spends the one prompt and lands on when-in-use anyway.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            scheduleAlwaysUpgrade()
        default:
            break
        }
    }

    /// Queues the Always upgrade for a moment iOS will actually act on.
    ///
    /// Asking the instant the When-In-Use prompt is answered — which is where this used to be
    /// called from — is dropped on the floor: iOS will not raise a second authorization prompt
    /// while it is still settling the first. The old code burned its "asked once" flag on that
    /// dropped call, so the upgrade was never offered again on any later session either.
    private func scheduleAlwaysUpgrade() {
        guard !UserDefaults.standard.bool(forKey: Self.alwaysRequestedKey) else { return }

        alwaysUpgradeWork?.cancel()
        alwaysUpgradeWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Tuning.alwaysUpgradeDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.requestAlwaysUpgradeOnce()
        }

        // If the phone went into a pocket before that timer fired, the attempt was skipped
        // rather than spent. Take the next return to the foreground instead.
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isTracking else { return }
                self.requestAlwaysUpgradeOnce()
            }
        }
    }

    /// Asks once, ever, for the Always upgrade. Tracking works without it — see
    /// `enableBackgroundUpdates` — so this only buys losing the blue status indicator.
    private func requestAlwaysUpgradeOnce() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        guard !UserDefaults.standard.bool(forKey: Self.alwaysRequestedKey) else { return }
        // A prompt raised while the app is backgrounded is never seen. Leave the flag alone and
        // try again next time the app is on screen rather than spending the one ask on nothing.
        guard UIApplication.shared.applicationState == .active else {
            Log.general.notice("Deferring Always upgrade request; app is not active")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.alwaysRequestedKey)
        manager.requestAlwaysAuthorization()
        Log.general.notice("Requested Always location authorization upgrade")
    }

    /// Drops the pending upgrade attempt and its foreground observer.
    private func cancelAlwaysUpgrade() {
        alwaysUpgradeWork?.cancel()
        alwaysUpgradeWork = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    /// Keeps location updates coming while the app is backgrounded or the screen is locked.
    ///
    /// This is legal with When-In-Use as long as the app declares the `location` background mode,
    /// which it does. Gating it on Always was a deadlock: iOS only offers Always as an upgrade to
    /// an app already using location in the background, so the app could never reach the state it
    /// was insisting on — and every walk silently stopped recording the moment the phone went
    /// into a pocket.
    private func enableBackgroundUpdates() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            Log.general.notice("Background location updates enabled")
        default:
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    /// Begins a session, or resumes one recovered from disk.
    ///
    /// If the permission prompt has not been answered yet this waits for it and begins as soon as
    /// the answer arrives. The prompt is shown *after* the tracking screen appears, so giving up
    /// here left first-run users on a screen that recorded nothing until they backed out and came
    /// in again.
    ///
    /// - Parameter startColorHex: the colour the user is drawing with. The tracker never
    ///   interprets it; it is journalled so a recovered session can be put back on screen in the
    ///   colours it was drawn in.
    func start(startColorHex: String, resuming recovered: SessionJournal.Recovered? = nil) {
        guard !isTracking else { return }

        self.startColorHex = startColorHex
        pendingResume = recovered
        startRequested = true

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginTracking()
        case .notDetermined:
            Log.general.notice("Awaiting location authorization before tracking")
            requestAuthorization()
        case .denied, .restricted:
            Log.general.error("Location authorization refused; cannot track")
            accessDenied = true
            startRequested = false
            pendingResume = nil
        @unknown default:
            startRequested = false
            pendingResume = nil
        }
    }

    private func beginTracking() {
        startRequested = false
        accessDenied = false

        let recovered = pendingResume
        pendingResume = nil

        filter = GPSTrackFilter()
        builder = TrackBuilder()
        rawFixes = []
        segmentBreaks = []
        locations = []
        distance = 0
        isMoving = false
        signalQuality = .searching
        startTime = recovered?.startDate ?? Date()
        lastFixTime = nil
        isTracking = true

        if let recovered {
            replay(recovered)
            journal.resume()
            Log.general.notice("Resumed session with \(recovered.fixes.count) recovered fixes")
        } else {
            journal.begin(startDate: startTime ?? Date(), startColorHex: startColorHex)
        }

        configureForTracking()
        enableBackgroundUpdates()
        updatesStartedAt = Date()
        manager.startUpdatingLocation()
        scheduleAlwaysUpgrade()
        Log.general.notice("Started fitness tracking")
    }

    /// Rebuilds the in-memory session from journalled fixes, running them through exactly the
    /// filter and builder a live session would have used, so a resumed track is identical to one
    /// that was never interrupted.
    private func replay(_ recovered: SessionJournal.Recovered) {
        for fix in recovered.fixes {
            ingest(fix, journaling: false)
        }
        segmentBreaks = recovered.colorChanges.map { $0.date }
        publishTrack()
    }

    /// Records that a new colour segment starts at the current point in the track.
    /// - Parameter colorHex: journalled so a recovered session comes back in the right colours.
    func markSegmentBreak(colorHex: String) {
        let now = Date()
        segmentBreaks.append(now)
        journal.recordColorChange(at: now, colorHex: colorHex)
    }

    /// Colour splits in the live track, as indices into `locations`. Used to put a resumed
    /// session back on screen in the segments it was drawn in.
    func liveSegmentStarts() -> [Int] {
        segmentStarts(for: builder.timestamps)
    }

    /// Ends the session and returns the track rebuilt from a smoothing pass over every fix.
    func stop() -> Summary {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        cancelAlwaysUpgrade()
        // The journal exists to survive a crash mid-walk. The walk is over, so it has done its
        // job; leaving it would offer this finished session back on the next launch.
        journal.finish()
        // Make sure the file is actually gone before the finished doodle goes on screen, so a
        // relaunch can never offer back the walk that was just saved.
        journal.flush()

        startRequested = false
        pendingResume = nil
        isTracking = false
        isMoving = false
        let duration = Date().timeIntervalSince(startTime ?? Date())

        let summary = buildSmoothedSummary(duration: duration)
        // Leave the published track showing the finished route rather than the live trace.
        locations = summary.points
        distance = summary.distance
        Log.general.notice("Stopped tracking; \(self.rawFixes.count) fixes smoothed into \(summary.points.count) points, \(summary.distance) m")
        return summary
    }

    private func buildSmoothedSummary(duration: TimeInterval) -> Summary {
        guard rawFixes.count > 2 else {
            return Summary(points: builder.points,
                           segmentStarts: segmentStarts(for: builder.timestamps),
                           distance: builder.distance,
                           duration: duration)
        }

        let smoothed = GPSTrackSmoother.smooth(rawFixes, outageThreshold: TrackBuilder.Tuning.outage)
        guard !smoothed.isEmpty else {
            return Summary(points: builder.points,
                           segmentStarts: segmentStarts(for: builder.timestamps),
                           distance: builder.distance,
                           duration: duration)
        }

        var finalBuilder = TrackBuilder()
        for point in smoothed {
            finalBuilder.add(point.coordinate, speed: point.speed, timestamp: point.timestamp)
        }

        // A smoothing pass should never leave us with less of a route than the live trace did.
        guard finalBuilder.points.count > 1 else {
            return Summary(points: builder.points,
                           segmentStarts: segmentStarts(for: builder.timestamps),
                           distance: builder.distance,
                           duration: duration)
        }

        return Summary(points: finalBuilder.points,
                       segmentStarts: segmentStarts(for: finalBuilder.timestamps),
                       distance: finalBuilder.distance,
                       duration: duration)
    }

    /// Maps each colour-change time onto an index in a track with the given point timestamps.
    private func segmentStarts(for timestamps: [Date]) -> [Int] {
        segmentBreaks.map { breakTime in
            timestamps.firstIndex { $0 >= breakTime } ?? timestamps.count
        }
    }

    // MARK: - Fix handling

    private func handle(_ location: CLLocation) {
        guard let startTime else { return }

        // Cached fixes from before the session describe where we were, not where we are.
        guard location.timestamp >= startTime.addingTimeInterval(-1) else {
            Log.location.debug("Rejected pre-session cached fix")
            return
        }
        guard abs(location.timestamp.timeIntervalSinceNow) < Tuning.maxFixAge else {
            Log.location.debug("Rejected stale fix, age \(abs(location.timestamp.timeIntervalSinceNow))s")
            return
        }
        guard location.horizontalAccuracy >= 0 else { return }

        updateSignalQuality(for: location.horizontalAccuracy)

        guard location.horizontalAccuracy < Tuning.maxAccuracy else {
            Log.location.debug("Rejected fix, accuracy \(location.horizontalAccuracy)m")
            return
        }

        // Warm-up: the first fixes after startUpdatingLocation are the worst of the session
        // and would otherwise anchor the whole track with a spur.
        if location.timestamp.timeIntervalSince(updatesStartedAt ?? startTime) < Tuning.warmUp,
           location.horizontalAccuracy > Tuning.warmUpAccuracy {
            Log.location.debug("Warming up, holding fix with accuracy \(location.horizontalAccuracy)m")
            return
        }

        ingest(GPSFix(location), journaling: true)
    }

    /// Feeds one already-validated fix through the filter and into the track.
    ///
    /// Live fixes and journalled ones replayed on resume both come through here, so a recovered
    /// session is assembled by exactly the same rules as the session it is continuing.
    ///
    /// - Parameter journaling: false when replaying fixes that are already on disk.
    private func ingest(_ fix: GPSFix, journaling: Bool) {
        if let lastFixTime, fix.timestamp.timeIntervalSince(lastFixTime) > TrackBuilder.Tuning.outage {
            // We have no idea what happened during the silence, so the velocity estimate is
            // worthless. Re-anchor rather than dead-reckoning off a stale heading.
            Log.location.notice("Signal outage of \(fix.timestamp.timeIntervalSince(lastFixTime))s; re-anchoring filter")
            filter.reset(to: fix)
        }

        guard let output = filter.process(fix) else {
            Log.location.debug("Fix gated as outlier")
            lastFixTime = fix.timestamp
            return
        }
        lastFixTime = fix.timestamp
        rawFixes.append(fix)
        // Written before the track is updated: a fix that reached the track but not the disk is
        // exactly what a crash would lose.
        if journaling { journal.record(fix) }

        builder.add(output.coordinate, speed: output.speed, timestamp: fix.timestamp)
        publishTrack()
    }

    private func publishTrack() {
        if isMoving != builder.isMoving { isMoving = builder.isMoving }
        if distance != builder.distance { distance = builder.distance }
        if locations.count != builder.points.count { locations = builder.points }
    }

    private func updateSignalQuality(for accuracy: CLLocationAccuracy) {
        let quality: SignalQuality
        switch accuracy {
        case ..<0: quality = .searching
        case ..<12: quality = .good
        case ..<30: quality = .fair
        default: quality = .poor
        }
        if quality != signalQuality { signalQuality = quality }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations new: [CLLocation]) {
        guard isTracking else { return }
        // Core Location can deliver a burst out of order; the filter assumes monotonic time.
        for location in new.sorted(by: { $0.timestamp < $1.timestamp }) {
            handle(location)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Log.general.notice("Location authorization changed to: \(status.rawValue)")

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            accessDenied = false
            if isTracking {
                enableBackgroundUpdates()
            } else if startRequested {
                // The user was already on the tracking screen when they answered the prompt.
                beginTracking()
            }
        case .denied, .restricted:
            Log.general.error("Location authorization refused: \(status.rawValue)")
            accessDenied = true
            startRequested = false
            pendingResume = nil
        case .notDetermined:
            Log.general.info("Location authorization not determined")
        @unknown default:
            Log.general.warning("Unknown location authorization status: \(status.rawValue)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError else {
            Log.location.error("Location manager failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch clError.code {
        case .denied:
            Log.location.error("Location access denied; stopping updates")
            accessDenied = true
            manager.stopUpdatingLocation()
        case .locationUnknown:
            // Transient — Core Location keeps trying on its own. Reflect it in the UI only.
            signalQuality = .searching
            Log.location.warning("Location temporarily unavailable")
        default:
            Log.location.error("Core Location error: \(clError.localizedDescription, privacy: .public)")
        }
    }
}
