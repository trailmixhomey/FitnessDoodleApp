import Foundation
import CoreLocation

/// A local east/north tangent plane anchored at a fixed origin.
///
/// Filtering in degrees is wrong: a degree of longitude is `cos(latitude)` times
/// shorter than a degree of latitude, so identical noise parameters smooth the two
/// axes by different amounts and systematically distort the track. Everything in
/// the filter therefore works in metres on this plane.
struct LocalProjection {
    let origin: CLLocationCoordinate2D
    private let metresPerDegreeLatitude: Double
    private let metresPerDegreeLongitude: Double

    init(origin: CLLocationCoordinate2D) {
        self.origin = origin
        let phi = origin.latitude * .pi / 180
        metresPerDegreeLatitude = 111132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi) - 0.0023 * cos(6 * phi)
        metresPerDegreeLongitude = max(111412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi), 1)
    }

    func project(_ coordinate: CLLocationCoordinate2D) -> (east: Double, north: Double) {
        ((coordinate.longitude - origin.longitude) * metresPerDegreeLongitude,
         (coordinate.latitude - origin.latitude) * metresPerDegreeLatitude)
    }

    func unproject(east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + north / metresPerDegreeLatitude,
                               longitude: origin.longitude + east / metresPerDegreeLongitude)
    }

    /// Straight-line distance in metres between two coordinates on this plane.
    func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let pa = project(a), pb = project(b)
        return hypot(pb.east - pa.east, pb.north - pa.north)
    }
}

/// A GPS fix reduced to the fields the filter uses. Keeping these rather than `CLLocation`
/// objects lets a whole session's raw fixes be retained cheaply for the end-of-session smoother.
struct GPSFix {
    var coordinate: CLLocationCoordinate2D
    var timestamp: Date
    var horizontalAccuracy: CLLocationAccuracy
    var speed: CLLocationSpeed
    var speedAccuracy: CLLocationSpeedAccuracy
    var course: CLLocationDirection
    var courseAccuracy: CLLocationDirectionAccuracy

    init(_ location: CLLocation) {
        coordinate = location.coordinate
        timestamp = location.timestamp
        horizontalAccuracy = location.horizontalAccuracy
        speed = location.speed
        speedAccuracy = location.speedAccuracy
        course = location.course
        courseAccuracy = location.courseAccuracy
    }

    /// Rebuilds a fix from stored values, for replaying a journalled session.
    init(coordinate: CLLocationCoordinate2D,
         timestamp: Date,
         horizontalAccuracy: CLLocationAccuracy,
         speed: CLLocationSpeed,
         speedAccuracy: CLLocationSpeedAccuracy,
         course: CLLocationDirection,
         courseAccuracy: CLLocationDirectionAccuracy) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }
}

/// One axis of a constant-velocity Kalman filter. State is `[position (m), velocity (m/s)]`,
/// covariance is the symmetric matrix `[[c00, c01], [c01, c11]]`.
private struct ConstantVelocityAxis {
    var position: Double
    var velocity: Double
    var c00: Double
    var c01: Double
    var c11: Double

    init(position: Double, positionVariance: Double, velocityVariance: Double) {
        self.position = position
        self.velocity = 0
        self.c00 = positionVariance
        self.c01 = 0
        self.c11 = velocityVariance
    }

    /// Advances the state by `dt` seconds. `accelerationVariance` is the process noise
    /// spectral density (m²/s⁴) that decides how hard the filter is allowed to manoeuvre.
    mutating func predict(dt: Double, accelerationVariance q: Double) {
        position += velocity * dt
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt2 * dt2
        let n00 = c00 + 2 * dt * c01 + dt2 * c11 + q * dt4 / 4
        let n01 = c01 + dt * c11 + q * dt3 / 2
        let n11 = c11 + q * dt2
        c00 = n00; c01 = n01; c11 = n11
    }

    /// Normalised innovation squared for a position measurement — used to gate outliers.
    func positionNIS(_ z: Double, variance r: Double) -> Double {
        let innovation = z - position
        return innovation * innovation / max(c00 + r, 1e-9)
    }

    mutating func updatePosition(_ z: Double, variance r: Double) {
        let s = c00 + r
        guard s > 0 else { return }
        let k0 = c00 / s
        let k1 = c01 / s
        let innovation = z - position
        position += k0 * innovation
        velocity += k1 * innovation
        let n00 = c00 - k0 * c00
        let n01 = c01 - k0 * c01
        let n11 = c11 - k1 * c01
        c00 = n00; c01 = n01; c11 = n11
    }

    mutating func updateVelocity(_ z: Double, variance r: Double) {
        let s = c11 + r
        guard s > 0 else { return }
        let k0 = c01 / s
        let k1 = c11 / s
        let innovation = z - velocity
        position += k0 * innovation
        velocity += k1 * innovation
        let n00 = c00 - k0 * c01
        let n01 = c01 - k0 * c11
        let n11 = c11 - k1 * c11
        c00 = n00; c01 = n01; c11 = n11
    }

    /// One step of the Rauch–Tung–Striebel backward recursion.
    ///
    /// `self` is the forward posterior at step k; `prior` is the prediction into step k+1 and
    /// `smoothed` the already-smoothed estimate at k+1. Returns the smoothed estimate at k.
    func smoothed(towards smoothed: ConstantVelocityAxis, prior: ConstantVelocityAxis, dt: Double) -> ConstantVelocityAxis {
        // C = P_post · Fᵀ · P_prior⁻¹, with F = [[1, dt], [0, 1]].
        let determinant = prior.c00 * prior.c11 - prior.c01 * prior.c01
        guard abs(determinant) > 1e-12 else { return self }

        // M = P_post · Fᵀ
        let m00 = c00 + c01 * dt
        let m01 = c01
        let m10 = c01 + c11 * dt
        let m11 = c11

        let inv00 = prior.c11 / determinant
        let inv01 = -prior.c01 / determinant
        let inv11 = prior.c00 / determinant

        let g00 = m00 * inv00 + m01 * inv01
        let g01 = m00 * inv01 + m01 * inv11
        let g10 = m10 * inv00 + m11 * inv01
        let g11 = m10 * inv01 + m11 * inv11

        var result = self
        let dPosition = smoothed.position - prior.position
        let dVelocity = smoothed.velocity - prior.velocity
        result.position = position + g00 * dPosition + g01 * dVelocity
        result.velocity = velocity + g10 * dPosition + g11 * dVelocity

        // P_smooth = P_post + G (P_smooth' - P_prior) Gᵀ
        let d00 = smoothed.c00 - prior.c00
        let d01 = smoothed.c01 - prior.c01
        let d11 = smoothed.c11 - prior.c11
        let t00 = g00 * d00 + g01 * d01
        let t01 = g00 * d01 + g01 * d11
        let t10 = g10 * d00 + g11 * d01
        let t11 = g10 * d01 + g11 * d11
        result.c00 = c00 + t00 * g00 + t01 * g01
        result.c01 = c01 + t00 * g10 + t01 * g11
        result.c11 = c11 + t10 * g10 + t11 * g11
        return result
    }
}

/// One accepted fix's forward-pass state, kept so the backward smoother can revisit it.
private struct FilterStep {
    var timestamp: Date
    /// Seconds elapsed from the previous step into this one.
    var dt: Double
    var priorEast: ConstantVelocityAxis
    var priorNorth: ConstantVelocityAxis
    var posteriorEast: ConstantVelocityAxis
    var posteriorNorth: ConstantVelocityAxis
}

/// Constant-velocity Kalman filter over GPS fixes, working in metres on a local tangent plane.
///
/// Three things make this behave like a fitness tracker rather than a moving average:
///  - it estimates velocity, so it predicts through noise and gaps instead of lagging behind;
///  - it weights every fix by its own reported `horizontalAccuracy`, so a 40 m fix nudges the
///    track instead of yanking it — this is what keeps the line smooth when signal is poor;
///  - it consumes the Doppler velocity (`speed`/`course`) Core Location reports, which is far
///    more accurate than differencing positions.
///
/// Used live for the track you watch being drawn. For the finished route, run the fixes through
/// `GPSTrackSmoother` instead: a forward-only filter has to choose between lag and jitter, while
/// a smoother that can see the whole track has to do neither.
final class GPSTrackFilter {

    struct Output {
        /// Filtered position.
        var coordinate: CLLocationCoordinate2D
        /// Filtered ground speed in m/s.
        var speed: Double
        /// Filtered course in degrees clockwise from north.
        var course: Double
        /// 1σ position uncertainty in metres.
        var uncertainty: Double
    }

    // MARK: Tuning

    /// Pedestrian manoeuvring noise (m/s²). Larger tracks sharp turns faster but keeps more jitter.
    private let accelerationVariance: Double
    /// Core Location is often optimistic about `horizontalAccuracy`; never trust a fix more than this.
    private let bestCredibleAccuracy: Double = 5
    /// Chi-square gate on 2 degrees of freedom (~99.97%). Beyond this a fix is treated as an outlier.
    private let outlierGate: Double = 16
    /// After this many consecutive rejections the filter is assumed lost and re-anchors.
    private let maxConsecutiveRejections = 3
    /// Predict is integrated in steps no longer than this, keeping covariance growth sane.
    private let maxPredictStep: Double = 1.0

    // MARK: State

    private var projection: LocalProjection?
    private var east: ConstantVelocityAxis?
    private var north: ConstantVelocityAxis?
    private var lastTimestamp: Date?
    private var consecutiveRejections = 0

    /// Forward-pass history, populated only while recording for the smoother.
    private var isRecording = false
    fileprivate private(set) var steps: [FilterStep] = []

    init(accelerationNoise: Double = 0.25) {
        accelerationVariance = accelerationNoise * accelerationNoise
    }

    /// The tangent plane in use, once the first fix has arrived.
    var currentProjection: LocalProjection? { projection }

    fileprivate func beginRecording() {
        isRecording = true
        steps.removeAll()
    }

    /// Drops the motion estimate and re-anchors on `fix`. Used at session start and after an
    /// outage long enough that the previous velocity estimate is worthless.
    ///
    /// The tangent-plane origin deliberately survives a reset: it is only a coordinate frame,
    /// and keeping it fixed means every state in a session is directly comparable.
    func reset(to fix: GPSFix) {
        if projection == nil {
            projection = LocalProjection(origin: fix.coordinate)
        }
        guard let projection else { return }
        let measured = projection.project(fix.coordinate)
        let accuracy = max(fix.horizontalAccuracy, bestCredibleAccuracy)
        let positionVariance = accuracy * accuracy
        // We know nothing about heading yet, so start velocity wide open.
        let velocityVariance = 4.0 * 4.0
        east = ConstantVelocityAxis(position: measured.east, positionVariance: positionVariance, velocityVariance: velocityVariance)
        north = ConstantVelocityAxis(position: measured.north, positionVariance: positionVariance, velocityVariance: velocityVariance)
        lastTimestamp = fix.timestamp
        consecutiveRejections = 0
        if isRecording, let e = east, let n = north {
            steps.append(FilterStep(timestamp: fix.timestamp, dt: 0,
                                    priorEast: e, priorNorth: n,
                                    posteriorEast: e, posteriorNorth: n))
        }
    }

    /// Folds a fix into the estimate. Returns `nil` when the fix was gated out as an outlier,
    /// in which case the caller should keep the previous estimate.
    func process(_ fix: GPSFix) -> Output? {
        guard var e = east, var n = north, let projection else {
            reset(to: fix)
            return currentOutput()
        }

        // Advance to the fix's timestamp. Out-of-order fixes are folded in without predicting.
        let dt = max(fix.timestamp.timeIntervalSince(lastTimestamp ?? fix.timestamp), 0)
        var remaining = dt
        while remaining > 0 {
            let step = min(remaining, maxPredictStep)
            e.predict(dt: step, accelerationVariance: accelerationVariance)
            n.predict(dt: step, accelerationVariance: accelerationVariance)
            remaining -= step
        }
        let priorEast = e
        let priorNorth = n

        let measured = projection.project(fix.coordinate)
        let accuracy = max(fix.horizontalAccuracy, bestCredibleAccuracy)
        let positionVariance = accuracy * accuracy

        // Statistical outlier gate: how surprising is this fix given our own uncertainty?
        // Because the gate scales with both the fix's accuracy and our covariance, it opens
        // up automatically after a gap instead of locking the track in place.
        let nis = e.positionNIS(measured.east, variance: positionVariance)
            + n.positionNIS(measured.north, variance: positionVariance)
        if nis > outlierGate {
            consecutiveRejections += 1
            if consecutiveRejections <= maxConsecutiveRejections {
                // Keep the prediction (and its inflated covariance) so the next fix is easier to accept.
                east = e; north = n; lastTimestamp = fix.timestamp
                return nil
            }
            // Repeatedly surprised: our estimate is wrong, not the GPS. Start over here.
            reset(to: fix)
            return currentOutput()
        }
        consecutiveRejections = 0

        e.updatePosition(measured.east, variance: positionVariance)
        n.updatePosition(measured.north, variance: positionVariance)

        // Doppler velocity, when Core Location vouches for it, tightens the track considerably.
        // Course is meaningless when standing still, so require real movement first.
        if fix.speed >= 0.5, fix.speedAccuracy >= 0, fix.course >= 0, fix.courseAccuracy >= 0 {
            let courseRadians = fix.course * .pi / 180
            let measuredEastVelocity = fix.speed * sin(courseRadians)
            let measuredNorthVelocity = fix.speed * cos(courseRadians)
            // Along-track error comes from speed accuracy, across-track from course accuracy.
            // Take the larger of the two as an isotropic approximation.
            let alongTrackSigma = max(fix.speedAccuracy, 0.5)
            let acrossTrackSigma = max(fix.speed * fix.courseAccuracy * .pi / 180, 0.5)
            let velocityVariance = pow(max(alongTrackSigma, acrossTrackSigma), 2)
            e.updateVelocity(measuredEastVelocity, variance: velocityVariance)
            n.updateVelocity(measuredNorthVelocity, variance: velocityVariance)
        }

        east = e
        north = n
        lastTimestamp = fix.timestamp
        if isRecording {
            steps.append(FilterStep(timestamp: fix.timestamp, dt: dt,
                                    priorEast: priorEast, priorNorth: priorNorth,
                                    posteriorEast: e, posteriorNorth: n))
        }
        return currentOutput()
    }

    private func currentOutput() -> Output? {
        guard let e = east, let n = north, let projection else { return nil }
        return Output(
            coordinate: projection.unproject(east: e.position, north: n.position),
            speed: hypot(e.velocity, n.velocity),
            course: Self.course(east: e.velocity, north: n.velocity),
            uncertainty: sqrt(max(e.c00 + n.c00, 0) / 2)
        )
    }

    fileprivate static func course(east: Double, north: Double) -> Double {
        var course = atan2(east, north) * 180 / .pi
        if course < 0 { course += 360 }
        return course
    }
}

/// Fixed-interval (Rauch–Tung–Striebel) smoother over a whole session's fixes.
///
/// A live filter only knows the past, so it must trade lag against jitter. Once the walk is
/// over every fix is available, and each point can be estimated from the track on both sides
/// of it — which removes the lag and the jitter at the same time. This is the difference
/// between a live trace and a finished route.
enum GPSTrackSmoother {

    struct Point {
        var coordinate: CLLocationCoordinate2D
        var speed: CLLocationSpeed
        var timestamp: Date
    }

    /// - Parameters:
    ///   - fixes: every accepted fix of the session, in time order.
    ///   - outageThreshold: gaps longer than this split the track into independent runs —
    ///     velocity does not carry across a signal outage, so neither should the smoother.
    static func smooth(
        _ fixes: [GPSFix],
        accelerationNoise: Double = 0.25,
        outageThreshold: TimeInterval = 6
    ) -> [Point] {
        guard fixes.count > 1 else {
            return fixes.map { Point(coordinate: $0.coordinate, speed: max($0.speed, 0), timestamp: $0.timestamp) }
        }

        var result: [Point] = []
        var run: [GPSFix] = []

        func flush() {
            guard !run.isEmpty else { return }
            result.append(contentsOf: smoothRun(run, accelerationNoise: accelerationNoise))
            run.removeAll(keepingCapacity: true)
        }

        for fix in fixes {
            if let previous = run.last, fix.timestamp.timeIntervalSince(previous.timestamp) > outageThreshold {
                flush()
            }
            run.append(fix)
        }
        flush()
        return result
    }

    private static func smoothRun(_ fixes: [GPSFix], accelerationNoise: Double) -> [Point] {
        guard let first = fixes.first else { return [] }
        guard fixes.count > 2 else {
            return fixes.map { Point(coordinate: $0.coordinate, speed: max($0.speed, 0), timestamp: $0.timestamp) }
        }

        // Forward pass, recording every step.
        let filter = GPSTrackFilter(accelerationNoise: accelerationNoise)
        filter.beginRecording()
        filter.reset(to: first)
        for fix in fixes.dropFirst() {
            _ = filter.process(fix)
        }

        var steps = filter.steps
        guard steps.count > 1, let projection = filter.currentProjection else {
            return fixes.map { Point(coordinate: $0.coordinate, speed: max($0.speed, 0), timestamp: $0.timestamp) }
        }

        // Backward RTS recursion. The last step's posterior is already the smoothed estimate.
        var smoothedEast = steps[steps.count - 1].posteriorEast
        var smoothedNorth = steps[steps.count - 1].posteriorNorth
        var output = [Point](repeating: Point(coordinate: first.coordinate, speed: 0, timestamp: first.timestamp),
                             count: steps.count)
        output[steps.count - 1] = Point(
            coordinate: projection.unproject(east: smoothedEast.position, north: smoothedNorth.position),
            speed: hypot(smoothedEast.velocity, smoothedNorth.velocity),
            timestamp: steps[steps.count - 1].timestamp
        )

        for k in stride(from: steps.count - 2, through: 0, by: -1) {
            let next = steps[k + 1]
            smoothedEast = steps[k].posteriorEast.smoothed(towards: smoothedEast, prior: next.priorEast, dt: next.dt)
            smoothedNorth = steps[k].posteriorNorth.smoothed(towards: smoothedNorth, prior: next.priorNorth, dt: next.dt)
            output[k] = Point(
                coordinate: projection.unproject(east: smoothedEast.position, north: smoothedNorth.position),
                speed: hypot(smoothedEast.velocity, smoothedNorth.velocity),
                timestamp: steps[k].timestamp
            )
        }

        steps.removeAll()
        return output
    }
}
