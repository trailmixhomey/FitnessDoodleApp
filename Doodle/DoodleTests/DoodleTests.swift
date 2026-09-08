import Testing
import Foundation
import CoreLocation
@testable import Doodle

/// Deterministic pseudo-random Gaussian noise, so these tests never flake.
private struct SeededNoise {
    private var state: UInt64 = 0x9E3779B97F4A7C15

    private mutating func nextUnit() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000.0
    }

    mutating func gaussian(sigma: Double) -> Double {
        let u1 = max(nextUnit(), 1e-9)
        let u2 = nextUnit()
        return sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// An L-shaped walk: 200 m east then 200 m north, at 1.4 m/s sampled at 1 Hz.
private struct SyntheticWalk {
    static let speed = 1.4
    static let legLength = 200.0
    static let legDuration = legLength / speed
    static let trueDistance = legLength * 2
    static let origin = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    static let projection = LocalProjection(origin: origin)
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    static func truth(at t: Double) -> (east: Double, north: Double) {
        t < legDuration ? (speed * t, 0) : (legLength, speed * (t - legDuration))
    }

    /// - Parameter outage: seconds during which no fix is delivered at all.
    static func fixes(noise: Double, accuracy: Double, outage: ClosedRange<Double>? = nil) -> [GPSFix] {
        var rng = SeededNoise()
        var result: [GPSFix] = []
        for i in 0...Int(legDuration * 2) {
            let t = Double(i)
            if let outage, outage.contains(t) { continue }
            let point = truth(at: t)
            let coordinate = projection.unproject(east: point.east + rng.gaussian(sigma: noise),
                                                 north: point.north + rng.gaussian(sigma: noise))
            let location = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 5,
                course: (t < legDuration ? 90 : 0) + rng.gaussian(sigma: 8),
                courseAccuracy: 10,
                speed: speed + rng.gaussian(sigma: 0.2),
                speedAccuracy: 0.5,
                timestamp: start.addingTimeInterval(t)
            )
            result.append(GPSFix(location))
        }
        return result
    }
}

private func meanError(_ points: [GPSTrackSmoother.Point]) -> Double {
    let errors = points.map { point -> Double in
        let t = point.timestamp.timeIntervalSince(SyntheticWalk.start)
        let truth = SyntheticWalk.truth(at: t)
        let estimate = SyntheticWalk.projection.project(point.coordinate)
        return hypot(estimate.east - truth.east, estimate.north - truth.north)
    }
    return errors.reduce(0, +) / Double(errors.count)
}

private func pathLength(_ points: [GPSTrackSmoother.Point]) -> Double {
    guard points.count > 1 else { return 0 }
    return (1..<points.count).reduce(0.0) { total, i in
        total + SyntheticWalk.projection.distance(points[i - 1].coordinate, points[i].coordinate)
    }
}

/// Mean turn angle between consecutive segments, in degrees. A clean line turns only at corners.
private func roughness(_ points: [GPSTrackSmoother.Point]) -> Double {
    var angles: [Double] = []
    let projected = points.map { SyntheticWalk.projection.project($0.coordinate) }
    for i in 2..<projected.count {
        let a = (projected[i - 1].east - projected[i - 2].east, projected[i - 1].north - projected[i - 2].north)
        let b = (projected[i].east - projected[i - 1].east, projected[i].north - projected[i - 1].north)
        let na = hypot(a.0, a.1), nb = hypot(b.0, b.1)
        guard na > 0.05, nb > 0.05 else { continue }
        let cosine = min(max((a.0 * b.0 + a.1 * b.1) / (na * nb), -1), 1)
        angles.append(acos(cosine) * 180 / .pi)
    }
    return angles.isEmpty ? 0 : angles.reduce(0, +) / Double(angles.count)
}

struct GPSTrackFilterTests {

    @Test func liveFilterTracksAWalkWithinAFewMetres() {
        let fixes = SyntheticWalk.fixes(noise: 5, accuracy: 5)
        let filter = GPSTrackFilter()
        var points: [GPSTrackSmoother.Point] = []
        for fix in fixes {
            guard let output = filter.process(fix) else { continue }
            points.append(.init(coordinate: output.coordinate, speed: output.speed, timestamp: fix.timestamp))
        }
        #expect(points.count > fixes.count - 5)
        #expect(meanError(points) < 5)
    }

    @Test func filterRejectsAWildOutlierWithoutLosingTheTrack() {
        var fixes = SyntheticWalk.fixes(noise: 3, accuracy: 5)
        let filter = GPSTrackFilter()
        for fix in fixes.prefix(30) { _ = filter.process(fix) }

        // A single fix 500 m away with a confident accuracy claim — classic multipath.
        var rogue = fixes[30]
        let displaced = SyntheticWalk.projection.project(rogue.coordinate)
        rogue.coordinate = SyntheticWalk.projection.unproject(east: displaced.east + 500, north: displaced.north)
        #expect(filter.process(rogue) == nil)

        // The next good fix is still tracked accurately.
        fixes = Array(fixes.dropFirst(31))
        guard let recovered = filter.process(fixes[0]) else {
            Issue.record("filter did not recover after an outlier")
            return
        }
        let truth = SyntheticWalk.truth(at: fixes[0].timestamp.timeIntervalSince(SyntheticWalk.start))
        let estimate = SyntheticWalk.projection.project(recovered.coordinate)
        #expect(hypot(estimate.east - truth.east, estimate.north - truth.north) < 10)
    }

    @Test func filterDoesNotStallWhenEveryFixIsPoor() {
        // Under heavy tree cover every fix is bad. The track must still advance, not freeze.
        let fixes = SyntheticWalk.fixes(noise: 40, accuracy: 60)
        let filter = GPSTrackFilter()
        var accepted = 0
        for fix in fixes where filter.process(fix) != nil { accepted += 1 }
        #expect(accepted > fixes.count / 2)
    }
}

struct GPSTrackSmootherTests {

    @Test func smoothingBeatsTheLiveFilterOnAccuracyAndSmoothness() {
        let fixes = SyntheticWalk.fixes(noise: 5, accuracy: 5)

        let filter = GPSTrackFilter()
        var live: [GPSTrackSmoother.Point] = []
        for fix in fixes {
            guard let output = filter.process(fix) else { continue }
            live.append(.init(coordinate: output.coordinate, speed: output.speed, timestamp: fix.timestamp))
        }
        let smoothed = GPSTrackSmoother.smooth(fixes)

        #expect(meanError(smoothed) < meanError(live))
        #expect(roughness(smoothed) < roughness(live) / 4)
    }

    @Test func smoothedDistanceIsCloseToTruthUnderPoorSignal() {
        let smoothed = GPSTrackSmoother.smooth(SyntheticWalk.fixes(noise: 25, accuracy: 30))
        let length = pathLength(smoothed)
        // Raw 25 m noise inflates a 400 m walk to several kilometres; the old position-only
        // filter under-reported it by ~7%. Anything within 5% is good.
        #expect(abs(length - SyntheticWalk.trueDistance) / SyntheticWalk.trueDistance < 0.05)
    }

    @Test func smoothedTrackIsCleanEvenWhenSignalIsPoor() {
        let smoothed = GPSTrackSmoother.smooth(SyntheticWalk.fixes(noise: 25, accuracy: 30))
        #expect(roughness(smoothed) < 5)
        #expect(meanError(smoothed) < 10)
    }

    @Test func smootherSplitsAtOutagesRatherThanBendingAcrossThem() {
        let fixes = SyntheticWalk.fixes(noise: 25, accuracy: 30, outage: 100...160)
        let smoothed = GPSTrackSmoother.smooth(fixes)
        #expect(smoothed.count == fixes.count)
        // Points either side of the gap stay pinned to where the GPS actually was.
        #expect(meanError(smoothed) < 10)
        #expect(roughness(smoothed) < 5)
    }

    @Test func smootherHandlesDegenerateInput() {
        #expect(GPSTrackSmoother.smooth([]).isEmpty)
        let single = Array(SyntheticWalk.fixes(noise: 5, accuracy: 5).prefix(1))
        #expect(GPSTrackSmoother.smooth(single).count == 1)
        let pair = Array(SyntheticWalk.fixes(noise: 5, accuracy: 5).prefix(2))
        #expect(GPSTrackSmoother.smooth(pair).count == 2)
    }
}

struct LocalProjectionTests {

    @Test func projectionRoundTrips() {
        let projection = LocalProjection(origin: SyntheticWalk.origin)
        let target = CLLocationCoordinate2D(latitude: 40.7200, longitude: -74.0100)
        let projected = projection.project(target)
        let restored = projection.unproject(east: projected.east, north: projected.north)
        #expect(abs(restored.latitude - target.latitude) < 1e-9)
        #expect(abs(restored.longitude - target.longitude) < 1e-9)
    }

    @Test func distanceMatchesCoreLocation() {
        let projection = LocalProjection(origin: SyntheticWalk.origin)
        let a = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let b = CLLocationCoordinate2D(latitude: 40.7160, longitude: -74.0020)
        let expected = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        #expect(abs(projection.distance(a, b) - expected) < 1.0)
    }

    @Test func eastAndNorthUseTheSameScale() {
        // 100 m east and 100 m north must project back to the same ground distance. The old
        // degree-space filter got this wrong by a factor of cos(latitude).
        let projection = LocalProjection(origin: SyntheticWalk.origin)
        let east = projection.unproject(east: 100, north: 0)
        let north = projection.unproject(east: 0, north: 100)
        let eastMetres = CLLocation(latitude: SyntheticWalk.origin.latitude, longitude: SyntheticWalk.origin.longitude)
            .distance(from: CLLocation(latitude: east.latitude, longitude: east.longitude))
        let northMetres = CLLocation(latitude: SyntheticWalk.origin.latitude, longitude: SyntheticWalk.origin.longitude)
            .distance(from: CLLocation(latitude: north.latitude, longitude: north.longitude))
        #expect(abs(eastMetres - 100) < 0.5)
        #expect(abs(northMetres - 100) < 0.5)
    }
}

struct PathRendererTests {

    private var square: [Coordinate] {
        // A 90° corner is where an over-tensioned spline visibly loops.
        [Coordinate(latitude: 40.0000, longitude: -74.0000),
         Coordinate(latitude: 40.0000, longitude: -73.9990),
         Coordinate(latitude: 40.0010, longitude: -73.9990),
         Coordinate(latitude: 40.0010, longitude: -74.0000)]
    }

    @Test func splineStaysWithinTheFrame() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let bounds = PathRenderer.makePath(from: square, in: rect).boundingRect
        // 20% margin means a well-behaved curve cannot reach the edges of the rect.
        #expect(rect.insetBy(dx: -1, dy: -1).contains(bounds))
    }

    @Test func aspectRatioIsPreservedInATallRect() {
        // Two legs of equal ground length must render as two strokes of equal pixel length.
        let projection = LocalProjection(origin: CLLocationCoordinate2D(latitude: 40, longitude: -74))
        let origin = Coordinate(latitude: 40, longitude: -74)
        let east = Coordinate(projection.unproject(east: 100, north: 0))
        let north = Coordinate(projection.unproject(east: 0, north: 100))

        let rect = CGRect(x: 0, y: 0, width: 390, height: 844) // an iPhone screen
        let o = PathRenderer.point(for: origin, relativeTo: [origin, east, north], in: rect)
        let e = PathRenderer.point(for: east, relativeTo: [origin, east, north], in: rect)
        let n = PathRenderer.point(for: north, relativeTo: [origin, east, north], in: rect)

        let eastPixels = hypot(e.x - o.x, e.y - o.y)
        let northPixels = hypot(n.x - o.x, n.y - o.y)
        #expect(abs(eastPixels - northPixels) / northPixels < 0.02)
    }

    @Test func markersLandOnThePathTheyAnnotate() {
        let rect = CGRect(x: 0, y: 0, width: 390, height: 844)
        let path = PathRenderer.makePath(from: square, in: rect)
        for coordinate in square {
            let point = PathRenderer.point(for: coordinate, relativeTo: square, in: rect)
            #expect(path.boundingRect.insetBy(dx: -1, dy: -1).contains(point))
        }
    }

    /// The bug this guards: `makePath` derives its frame from the points it is given, so drawing
    /// each colour segment with its own call scaled every colour independently to fill the rect.
    /// A two-colour walk came apart into pieces drawn at different sizes in different places.
    @Test func colourSegmentsShareOneFrame() throws {
        let projection = LocalProjection(origin: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278))
        // An L: 200 m east, then 200 m north. The corner is the last point of one segment and
        // the first of the next, so it must land in exactly one place.
        let east = stride(from: 0.0, through: 200.0, by: 5).map { Coordinate(projection.unproject(east: $0, north: 0)) }
        let north = stride(from: 0.0, through: 200.0, by: 5).map { Coordinate(projection.unproject(east: 200, north: $0)) }
        let all = east + north
        let rect = CGRect(x: 0, y: 0, width: 300, height: 300)

        let frame = try #require(PathRenderer.frame(for: all, in: rect))
        let cornerFromEast = PathRenderer.makePath(from: east, in: frame).currentPoint
        let cornerFromNorth = PathRenderer.makePath(from: north, in: frame).boundingRect

        let corner = PathRenderer.point(for: east.last!, in: frame)
        #expect(abs((cornerFromEast?.x ?? .infinity) - corner.x) < 0.5)
        #expect(abs((cornerFromEast?.y ?? .infinity) - corner.y) < 0.5)
        // The north leg starts at the same corner, so its bounds must reach it too.
        #expect(cornerFromNorth.insetBy(dx: -1, dy: -1).contains(corner))

        // And the whole route still fits the rect it was framed for.
        #expect(rect.insetBy(dx: -1, dy: -1).contains(PathRenderer.makePath(from: all, in: frame).boundingRect))
    }

    @Test func markersUseTheSameFrameAsTheSegments() throws {
        let projection = LocalProjection(origin: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278))
        let east = stride(from: 0.0, through: 200.0, by: 5).map { Coordinate(projection.unproject(east: $0, north: 0)) }
        let north = stride(from: 0.0, through: 200.0, by: 5).map { Coordinate(projection.unproject(east: 200, north: $0)) }
        let rect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frame = try #require(PathRenderer.frame(for: east + north, in: rect))

        // Start and end markers must sit on the ends of the strokes they annotate.
        let startMarker = PathRenderer.point(for: east.first!, in: frame)
        let endMarker = PathRenderer.point(for: north.last!, in: frame)
        #expect(PathRenderer.makePath(from: east, in: frame).boundingRect.insetBy(dx: -1, dy: -1).contains(startMarker))
        #expect(PathRenderer.makePath(from: north, in: frame).boundingRect.insetBy(dx: -1, dy: -1).contains(endMarker))
    }

    @Test func simplificationToleranceIsInMetres() {
        // A straight run with one 5 m detour: a 1 m tolerance keeps the detour, 20 m drops it.
        let projection = LocalProjection(origin: CLLocationCoordinate2D(latitude: 40, longitude: -74))
        var points: [Coordinate] = []
        for i in 0...20 {
            let offset: Double = (i == 10) ? 5 : 0
            points.append(Coordinate(projection.unproject(east: Double(i) * 10, north: offset)))
        }
        #expect(PathRenderer.simplifyPath(points, tolerance: 1).count > 2)
        #expect(PathRenderer.simplifyPath(points, tolerance: 20).count == 2)
    }
}

@MainActor
struct SessionSummarySegmentTests {

    private func summary(pointCount: Int, starts: [Int]) -> LocationManager.Summary {
        let points = (0..<pointCount).map {
            Coordinate(latitude: 40 + Double($0) * 1e-4, longitude: -74)
        }
        return LocationManager.Summary(points: points, segmentStarts: starts, distance: 0, duration: 0)
    }

    @Test func aSingleColourKeepsTheWholeTrack() {
        let runs = summary(pointCount: 10, starts: []).pointsPerSegment()
        #expect(runs.count == 1)
        #expect(runs[0].count == 10)
    }

    @Test func coloursSplitTheTrackAndMeetWithoutAGap() {
        let all = summary(pointCount: 10, starts: [4, 7])
        let runs = all.pointsPerSegment()
        #expect(runs.count == 3)
        // Each later run repeats the previous run's last point so the strokes join up.
        #expect(runs[0].count == 4)
        #expect(runs[1].count == 4) // seed + points 4...6
        #expect(runs[2].count == 4) // seed + points 7...9
        #expect(runs[1].first == runs[0].last)
        #expect(runs[2].first == runs[1].last)
        // Every original point still appears exactly once beyond the seeds.
        let recovered = runs.enumerated().flatMap { index, run in index == 0 ? run : Array(run.dropFirst()) }
        #expect(recovered == all.points)
    }

    @Test func outOfRangeOrUnorderedSplitsAreClamped() {
        // The smoothed track is shorter than the live one, so a split index can overrun it.
        let runs = summary(pointCount: 5, starts: [3, 99, 1]).pointsPerSegment()
        #expect(runs.count == 4)
        // One run per colour is preserved even when a split collapses to nothing.
        let recovered = runs.enumerated().flatMap { index, run in index == 0 ? run : Array(run.dropFirst()) }
        #expect(recovered.count == 5)
    }

    @Test func anEmptyTrackYieldsNoSegments() {
        #expect(summary(pointCount: 0, starts: [2]).pointsPerSegment().isEmpty)
    }
}


// MARK: - Crash recovery

@MainActor
struct SessionJournalTests {

    private func makeFix(_ index: Int, start: Date) -> GPSFix {
        GPSFix(coordinate: CLLocationCoordinate2D(latitude: 51.5074 + Double(index) * 1e-5, longitude: -0.1278),
               timestamp: start.addingTimeInterval(Double(index)),
               horizontalAccuracy: 8,
               speed: 1.4,
               speedAccuracy: 1,
               course: 0,
               courseAccuracy: 10)
    }

    /// A session written to the journal comes back whole — fixes, clock and colour splits — so a
    /// walk survives the process that recorded it.
    @Test func aJournalledSessionIsRecovered() throws {
        SessionJournal.discard()
        defer { SessionJournal.discard() }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = SessionJournal()
        journal.begin(startDate: start, startColorHex: "#4CAF50")
        for i in 0..<30 { journal.record(makeFix(i, start: start)) }
        journal.recordColorChange(at: start.addingTimeInterval(15), colorHex: "#FF6B6B")
        for i in 30..<60 { journal.record(makeFix(i, start: start)) }
        journal.flush()

        let session = try #require(SessionJournal.pending())
        #expect(session.startDate.timeIntervalSince1970 == start.timeIntervalSince1970)
        #expect(session.startColorHex == "#4CAF50")
        #expect(session.fixes.count == 60)
        #expect(session.colorChanges.count == 1)
        #expect(session.colorChanges.first?.colorHex == "#FF6B6B")
        // Coordinates survive the round trip, not just the count.
        #expect(abs(session.fixes[10].coordinate.latitude - (51.5074 + 10e-5)) < 1e-9)
    }

    /// The write that was in flight when the process died leaves a half-written last line.
    /// It must cost that one fix, not the whole walk.
    @Test func aTornFinalLineCostsOneFix() throws {
        SessionJournal.discard()
        defer { SessionJournal.discard() }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = SessionJournal()
        journal.begin(startDate: start, startColorHex: "#4CAF50")
        for i in 0..<20 { journal.record(makeFix(i, start: start)) }
        journal.flush()

        let url = try #require(FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("session-journal.ndjson"))
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw += "{\"k\":\"f\",\"t\":170000"  // cut off mid-record
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let session = try #require(SessionJournal.pending())
        #expect(session.fixes.count == 20)
    }

    /// A screen opened and abandoned is not a walk; it must not be offered back on every launch.
    @Test func aTrivialJournalIsNotOffered() {
        SessionJournal.discard()
        defer { SessionJournal.discard() }

        let start = Date()
        let journal = SessionJournal()
        journal.begin(startDate: start, startColorHex: "#4CAF50")
        journal.record(makeFix(0, start: start))
        journal.flush()

        #expect(SessionJournal.pending() == nil)
    }

    @Test func finishingRemovesTheJournal() {
        SessionJournal.discard()
        let start = Date()
        let journal = SessionJournal()
        journal.begin(startDate: start, startColorHex: "#4CAF50")
        for i in 0..<10 { journal.record(makeFix(i, start: start)) }
        journal.finish()
        journal.flush()

        #expect(SessionJournal.pending() == nil)
    }
}

// MARK: - Saved doodles

@MainActor
struct DoodleStoreTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var sampleDoodle: Doodle {
        Doodle(points: [Coordinate(latitude: 51.5, longitude: -0.12), Coordinate(latitude: 51.51, longitude: -0.12)],
               distance: 1000,
               duration: 600)
    }

    @Test func doodlesSurviveAReload() {
        let dir = temporaryDirectory()
        let store = DoodleStore(directory: dir)
        store.add(sampleDoodle)
        store.waitForPendingWrites()

        let reloaded = DoodleStore(directory: dir)
        #expect(reloaded.doodles.count == 1)
        #expect(reloaded.isReadOnly == false)
    }

    /// The bug this guards: a decode failure left the store empty, and the next save wrote that
    /// empty list back over the file. One bad byte silently destroyed every saved doodle.
    @Test func anUnreadableFileIsSetAsideRatherThanOverwritten() throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("doodles.json")
        try "this is not json".write(to: url, atomically: true, encoding: .utf8)

        let store = DoodleStore(directory: dir)
        #expect(store.doodles.isEmpty)

        store.add(sampleDoodle)
        store.waitForPendingWrites()

        // The original bytes are still on disk under a quarantine name.
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("doodles-unreadable-") }
        #expect(quarantined.count == 1)
        let salvaged = try String(contentsOf: dir.appendingPathComponent(quarantined[0]), encoding: .utf8)
        #expect(salvaged == "this is not json")

        // And the store is usable again, rather than permanently stuck.
        #expect(DoodleStore(directory: dir).doodles.count == 1)
    }

    @Test func aMissingFileIsJustAnEmptyStore() {
        let store = DoodleStore(directory: temporaryDirectory())
        #expect(store.doodles.isEmpty)
        #expect(store.isReadOnly == false)
    }
}
