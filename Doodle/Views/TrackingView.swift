import SwiftUI
import CoreLocation

struct TrackingView: View {
    struct Segment: Identifiable { let id = UUID(); var color: Color; var points: [Coordinate] }

    @StateObject private var tracker = LocationManager()
    @StateObject private var illustrationService = ContextualIllustrationService()
    @StateObject private var sceneryService = SceneryService()
    @State private var isCompleted = false
    @State private var completionResult: (Doodle, UIImage)?
    @State private var isCompletingSession = false
    @Environment(\.dismiss) private var dismiss

    @State private var segments: [Segment]
    @State private var currentColor: Color
    @State private var zoomScale: Double = 4.0 // Start at what used to be 4x zoom (good walking view)
    @State private var lastZoomScale: Double = 1.0
    @State private var lastIllustrationScanCount = 0
    @State private var hasRestoredSegments = false
    /// Photos taken during this walk, in the order the shutter was pressed.
    @State private var capturedPhotos: [WalkPhoto] = []
    
    /// An unfinished session recovered from disk, to be continued rather than started fresh.
    private let resuming: SessionJournal.Recovered?
    /// The colours the session was drawn in, in order: the starting colour then each change.
    private let resumedColors: [Color]

    // Callback to dismiss all the way to home
    var onDismissToHome: (() -> Void)?

    init(strokeColor: Color, onDismissToHome: (() -> Void)? = nil) {
        _currentColor = State(initialValue: strokeColor)
        _segments = State(initialValue: [Segment(color: strokeColor, points: [])])
        resuming = nil
        resumedColors = [strokeColor]
        self.onDismissToHome = onDismissToHome
    }

    /// Picks a session back up where a crash, a force-quit or a reboot left it.
    init(resuming session: SessionJournal.Recovered, onDismissToHome: (() -> Void)? = nil) {
        let colors = [Color(hex: session.startColorHex)] + session.colorChanges.map { Color(hex: $0.colorHex) }
        _currentColor = State(initialValue: colors.last ?? .primaryColor)
        // The points are not known until the journalled fixes have been replayed through the
        // filter, so start empty and rebuild the segments once tracking has begun.
        _segments = State(initialValue: [Segment(color: colors.first ?? .primaryColor, points: [])])
        resuming = session
        resumedColors = colors
        self.onDismissToHome = onDismissToHome
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let rect = proxy.frame(in: .local)
                // Base view area: 1/8 mile radius ≈ 0.0002 square degrees (approximate conversion for visualization)
                // Apply zoom scale: smaller values = more zoomed in, larger values = more zoomed out
                let baseViewArea: Double = 0.0002
                let fixedViewArea: Double = baseViewArea * zoomScale
                let allPoints = segments.flatMap { $0.points }
                let currentLocation = allPoints.last // Use the most recent location as the center
                // One frame, built once and shared by every segment, icon and marker on screen.
                if let frame = PathRenderer.frame(for: allPoints, in: rect, fixedViewArea: fixedViewArea, centerLocation: currentLocation) {
                    // Drawn before the route so the line always sits on top of its own scenery.
                    if !sceneryService.scenery.isEmpty {
                        SceneryView(
                            positionedScenery: PathRenderer.positionScenery(sceneryService.scenery, in: frame),
                            itemSize: tracker.distance < 100 ? 22 : 18
                        )
                    }

                    ForEach(segments) { segment in
                        let lineWidth: CGFloat = tracker.distance < 100 ? 16 : 8 // Thicker line for short distances (< 100m)
                        PathRenderer.makePath(from: segment.points, in: frame, smoothness: 1.0)
                            .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    }

                    // Contextual illustrations
                    if !illustrationService.illustrations.isEmpty {
                        ContextualIllustrationView(
                            positionedIllustrations: PathRenderer.positionIllustrations(illustrationService.illustrations, in: frame),
                            iconSize: tracker.distance < 100 ? 20 : 16 // Smaller icons for short distances
                        )
                    }

                    // Start/End markers
                    let markerSize: CGFloat = tracker.distance < 100 ? 16 : 10 // Bigger markers for short distances
                    if let first = allPoints.first {
                        Circle()
                            .fill(Color.black)
                            .frame(width: markerSize, height: markerSize)
                            .position(PathRenderer.point(for: first, in: frame))
                    }
                    if let last = allPoints.last {
                        Circle()
                            .stroke(Color.black, lineWidth: 2)
                            .frame(width: markerSize, height: markerSize)
                            .position(PathRenderer.point(for: last, in: frame))
                    }
                }
            }
            .background(Color.white)
            .onAppear {
                guard !tracker.isTracking else { return }
                // `start` handles the permission prompt itself and begins as soon as it is
                // answered, so there is nothing to do here but ask.
                illustrationService.reset()
                sceneryService.reset()
                // A resumed session keeps the photos it had already taken; a fresh one starts
                // clean, and anything left behind by a walk that was never saved is pruned at
                // launch rather than being adopted by the next walk.
                capturedPhotos = resuming != nil ? PhotoStore.shared.inProgressPhotos : []
                if resuming == nil { PhotoStore.shared.clearInProgressPhotos() }
                tracker.start(startColorHex: Color.hexString(for: currentColor), resuming: resuming)
                restoreSegmentsIfNeeded()
            }
            .ignoresSafeArea()
            .scaleEffect(1.0) // Prevent default zoom behavior
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let delta = value / lastZoomScale
                        lastZoomScale = value
                        
                        // Invert the zoom behavior: pinch out = zoom in (smaller zoomScale = more zoomed in)
                        // Pinch in = zoom out (larger zoomScale = more zoomed out)
                        let invertedDelta = 1.0 / delta
                        let newZoom = zoomScale * invertedDelta
                        
                        // Much larger zoom range like other map apps (0.1x to 50x)
                        zoomScale = max(0.1, min(50.0, newZoom))
                    }
                    .onEnded { value in
                        lastZoomScale = 1.0
                    }
            )

            // update segments with new locations
            .onChange(of: tracker.locations) { old, new in
                // A signal outage is bridged with several interpolated points at once, so take
                // everything that arrived rather than just the newest fix. Once tracking stops
                // the published track is replaced wholesale by the smoothed one, which is
                // re-cut into segments in completeSession() instead of appended here.
                guard tracker.isTracking, new.count > old.count else { return }
                // A resumed session's replayed track can land here rather than being ready by the
                // time `onAppear` ran — when the permission prompt was still open, say. Cut it
                // into its original colours instead of appending it all to the current one.
                if resuming != nil, !hasRestoredSegments {
                    restoreSegmentsIfNeeded()
                    return
                }
                let added = Array(new[old.count...])
                withAnimation(.linear(duration: 1)) {
                    segments[segments.count - 1].points.append(contentsOf: added)
                }
                Log.tracking.debug("Appended \(added.count) point(s) to segment #\(segments.count-1); points in segment: \(segments[segments.count-1].points.count)")

                // Throttle POI detection so it doesn't fire once per fix
                let allPoints = segments.flatMap { $0.points }
                if allPoints.count - lastIllustrationScanCount >= 10 {
                    lastIllustrationScanCount = allPoints.count
                    Task {
                        await illustrationService.detectIllustrationsAlongPath(allPoints)
                        // Scenery runs after the places pass so it can ask how many real places
                        // are nearby, which is what tells a shopping street from a suburb.
                        await sceneryService.updateScenery(along: allPoints) { coordinate in
                            illustrationService.placeDensity(near: coordinate)
                        }
                    }
                }
            }

            VStack {
                HStack {
                    Spacer()

                    Text(Date(), style: .time)
                        .font(.messyLarge(.caption))
                        .padding(6)

                    Spacer()
                    }

                // Only surface GPS state when it is worth knowing about, so a good signal
                // stays out of the way.
                if let signalMessage {
                    Text(signalMessage)
                        .font(.messyLarge(.caption))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.white.opacity(0.85))
                        )
                        .overlay(Capsule().stroke(.black, lineWidth: 1.5))
                        .transition(.opacity)
                }

                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.2f mi", tracker.distance / 1609.34))
                            .font(.messyLarge(.headline))
                            .padding(6)
                        Text("Points: \(segments.flatMap { $0.points }.count)")
                            .font(.messyLarge(.caption))
                            .padding(6)
                    }
                }
            }
            .padding()

            VStack {
                Spacer()

                // Color picker bottom row
                HStack(spacing: 12) {
                    ForEach(palette, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: currentColor == color ? 40 : 32, height: currentColor == color ? 40 : 32)
                            .scaleEffect(currentColor == color ? 1.0 : 0.95)
                            .animation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0), value: currentColor)
                            .onTapGesture {
                                if currentColor != color {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0)) {
                                        currentColor = color
                                    }
                                    // start new segment to draw with new color
                                    // Use the last point from the previous segment as the first point of the new segment for visual continuity
                                    let lastPoint = segments.last?.points.last
                                    let initialPoints: [Coordinate] = lastPoint.map { [$0] } ?? []
                                    segments.append(Segment(color: color, points: initialPoints))
                                    // Record the split so the smoothed track can be re-cut into
                                    // the same colours once the session ends.
                                    tracker.markSegmentBreak(colorHex: Color.hexString(for: color))
                                }
                            }
                    }
                }
                .padding(.bottom, 8)

                // Done stays centred, with the camera beside it, so the button that ends the
                // walk does not move once a photo has been taken.
                ZStack {
                    Button {
                        // stop tracking
                        guard !isCompletingSession else { return }
                        isCompletingSession = true
                        Task {
                            completionResult = await completeSession()
                            isCompleted = true
                        }
                    } label: {
                        Text("Done")
                            .font(.messyLarge(.title2))
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.black, lineWidth: 2)
                            )
                            .background(Color.white.opacity(0.8))
                    }

                    HStack {
                        Spacer()
                        photoButton
                    }
                    .padding(.trailing, 24)
                }
                .padding(.bottom, 20)
            }
        }
        .fullScreenCover(isPresented: $isCompleted) {
            if let result = completionResult {
                CompleteDoodleView(result: result, onSaveAndDismissToHome: onDismissToHome)
            } else {
                // If completion failed, just dismiss back to previous view
                EmptyView()
                    .onAppear { 
                        isCompleted = false
                        isCompletingSession = false
                        dismiss() 
                    }
            }
        }
    }

    private func completeSession() async -> (Doodle, UIImage)? {
        // Ensure we only stop tracking once
        guard tracker.isTracking else { 
            Log.tracking.warning("Attempted to complete session but tracking was already stopped")
            return nil 
        }
        
        let summary = tracker.stop()
        Log.tracking.info("Generating snapshot for doodle with \(summary.points.count) points")
        // From here the photos travel on the doodle. If it is discarded rather than saved,
        // `CompleteDoodleView` deletes the files.
        PhotoStore.shared.clearInProgressPhotos()

        // The saved route comes from the smoothing pass over every fix, not from the live
        // trace, so re-cut it into the colour segments the user drew.
        let smoothedSegments = rebuildSegments(from: summary)
        let nonEmptySegments = smoothedSegments.filter { !$0.points.isEmpty }
        guard !nonEmptySegments.isEmpty else {
            Log.tracking.error("No valid segments to save - all segments are empty")
            return nil
        }
        segments = nonEmptySegments
        
        // Check for minimum meaningful movement
        let totalDistance = summary.distance
        let isMovementDoodle = totalDistance >= 10.0 // 10 meters minimum for path doodle
        
        if isMovementDoodle {
            Log.tracking.info("Creating movement doodle with \(totalDistance)m distance")
            return await createMovementDoodle(summary: summary, segments: nonEmptySegments)
        } else {
            Log.tracking.info("Creating single-point doodle (movement: \(totalDistance)m)")
            return await createSinglePointDoodle(summary: summary, segments: nonEmptySegments)
        }
    }
    
    private func createMovementDoodle(summary: LocationManager.Summary, segments: [Segment]) async -> (Doodle, UIImage)? {
        // Check if we have enough points for a meaningful path
        let totalPoints = segments.flatMap { $0.points }.count
        guard totalPoints >= 2 else {
            Log.tracking.error("Insufficient points to create a path (have \(totalPoints), need at least 2)")
            return nil
        }
        
        // These points are already the finished route: the RTS smoother has run over every
        // fix of the session. Nothing further is done to the geometry here — the shape you
        // walked is the doodle, so snapping it to a road network would be destroying the
        // one thing the app exists to record.
        let doodleSegments = segments.map { seg in
            Doodle.ColorSegment(colorHex: Color.hexString(for: seg.color), points: seg.points)
        }
        
        // Combine points from all segments, avoiding duplication at segment boundaries
        var combinedPoints: [Coordinate] = []
        for (index, segment) in doodleSegments.enumerated() {
            if index == 0 {
                // First segment: include all points
                combinedPoints.append(contentsOf: segment.points)
            } else {
                // Subsequent segments: skip the first point (it's the connection point from the previous segment)
                combinedPoints.append(contentsOf: segment.points.dropFirst())
            }
        }
        
        // Final POI pass over the whole route. Take the returned icons rather than reading the
        // published property: the publish lands on a later main-actor hop, so reading it here
        // captured the *previous* pass's icons — nothing at all, on a first run.
        let illustrations = await illustrationService.detectIllustrationsAlongPath(combinedPoints)
        let scenery = await sceneryService.updateScenery(along: combinedPoints) { coordinate in
            illustrationService.placeDensity(near: coordinate)
        }

        var doodle = Doodle(points: combinedPoints,
                            distance: summary.distance,
                            duration: summary.duration,
                            startColorHex: Color.hexString(for: doodleSegments.first?.color ?? .primaryColor),
                            segments: doodleSegments,
                            illustrations: illustrations)
        doodle.scenery = scenery
        doodle.photos = capturedPhotos

        // Counted at the point it is saved, so a doodle that comes back bare can be told apart
        // from one that was never given any decoration in the first place.
        Log.tracking.notice("Saving doodle with \(scenery.count) scenery items and \(illustrations.count) places")

        // Render image snapshot
        let snapshot = PathSnapshotView(doodle: doodle)
            .frame(width: 512, height: 512)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 3
        
        guard let uiImage = renderer.uiImage else { 
            Log.tracking.error("Failed to render doodle image")
            return nil 
        }
        
        return (doodle, uiImage)
    }
    
    private func createSinglePointDoodle(summary: LocationManager.Summary, segments: [Segment]) async -> (Doodle, UIImage)? {
        // For single point doodles, use the center of all collected points
        let allPoints = segments.flatMap { $0.points }
        guard !allPoints.isEmpty else { return nil }
        
        // Calculate center point
        let avgLat = allPoints.map { $0.latitude }.reduce(0, +) / Double(allPoints.count)
        let avgLon = allPoints.map { $0.longitude }.reduce(0, +) / Double(allPoints.count)
        let centerPoint = Coordinate(latitude: avgLat, longitude: avgLon)
        
        // Perform POI detection at this location
        let illustrations = await illustrationService.detectIllustrationsAlongPath([centerPoint])

        // Create a single-point doodle (no segments, just one point)
        var doodle = Doodle(points: [centerPoint],
                            distance: summary.distance,
                            duration: summary.duration,
                            startColorHex: Color.hexString(for: currentColor),
                            segments: [], // No segments for single point
                            illustrations: illustrations)
        doodle.photos = capturedPhotos

        // Render image snapshot for single point
        let snapshot = SinglePointSnapshotView(doodle: doodle)
            .frame(width: 512, height: 512)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 3
        
        guard let uiImage = renderer.uiImage else { 
            Log.tracking.error("Failed to render single-point doodle image")
            return nil 
        }
        
        return (doodle, uiImage)
    }
    
    private var photoButton: some View {
        AddPhotoButton(maxSelection: 3, identifier: "walkCameraButton", onPicked: addPhotos) {
            Image(systemName: "camera.fill")
                .font(.title3)
                .foregroundStyle(.black)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color.white.opacity(0.85)))
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if !capturedPhotos.isEmpty {
                        Text("\(capturedPhotos.count)")
                            .font(.messyLarge(.caption2))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primaryColor))
                            .overlay(Circle().stroke(.black, lineWidth: 1.5))
                            .offset(x: 6, y: -4)
                    }
                }
        }
    }

    /// Files new photos against the spot on the route where they were taken.
    private func addPhotos(_ images: [UIImage]) {
        let coordinate = segments.last(where: { !$0.points.isEmpty })?.points.last
        for image in images {
            capturedPhotos.append(PhotoStore.shared.save(image, at: coordinate))
        }
        // The pixels are already on disk, but nothing yet says which walk they belong to. Writing
        // the list out on every capture is what lets a session recovered after a crash or a
        // force-quit come back with its photos instead of leaving them orphaned.
        PhotoStore.shared.inProgressPhotos = capturedPhotos
        Log.tracking.notice("Added \(images.count) photo(s); \(self.capturedPhotos.count) on this walk")
    }

    private var palette: [Color] {
        [.fern, .coral, .cantaloupe, .cerulean, .primaryColor]
    }

    /// Re-cuts the smoothed track into the colour segments the user drew during the session.
    /// The colours live here in the view; the tracker only records *where* each split happened.
    private func rebuildSegments(from summary: LocationManager.Summary) -> [Segment] {
        let colors = segments.map { $0.color }
        guard let fallbackColor = colors.first else { return [] }
        return summary.pointsPerSegment().enumerated().map { index, points in
            Segment(color: index < colors.count ? colors[index] : fallbackColor, points: points)
        }
    }

    private var signalMessage: String? {
        if tracker.accessDenied {
            return "Location access is off — enable it in Settings"
        }
        switch tracker.signalQuality {
        case .searching: return "Finding GPS…"
        case .poor: return "Weak GPS — smoothing"
        case .fair, .good: return nil
        }
    }

    /// Puts a recovered session back on screen in the colours it was drawn in, once its track
    /// has been replayed. Does nothing until there is something to restore.
    private func restoreSegmentsIfNeeded() {
        guard resuming != nil, !hasRestoredSegments, !tracker.locations.isEmpty else { return }
        hasRestoredSegments = true
        segments = rebuildLiveSegments()
        lastIllustrationScanCount = tracker.locations.count
    }

    /// Cuts the live track into the colour segments a resumed session was drawn in.
    private func rebuildLiveSegments() -> [Segment] {
        let summary = LocationManager.Summary(points: tracker.locations,
                                              segmentStarts: tracker.liveSegmentStarts(),
                                              distance: tracker.distance,
                                              duration: 0)
        let runs = summary.pointsPerSegment()
        guard !runs.isEmpty else {
            return [Segment(color: currentColor, points: [])]
        }
        return runs.enumerated().map { index, points in
            Segment(color: index < resumedColors.count ? resumedColors[index] : currentColor, points: points)
        }
    }
    
}

private struct PathSnapshotView: View {
    let doodle: Doodle
    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)
            // One frame for the whole snapshot, shared by the path and the icons drawn on it.
            let referencePoints = doodle.renderPoints
            let frame = PathRenderer.frame(for: referencePoints, in: rect)
            
            ZStack {
                // Scenery first, so the route is drawn over its own decoration.
                if !doodle.scenery.isEmpty, let frame {
                    SceneryView(
                        positionedScenery: PathRenderer.positionScenery(doodle.scenery, in: frame),
                        itemSize: 20
                    )
                }

                // Draw the path only if we have multiple points
                if doodle.points.count > 1, let frame {
                    if doodle.segments.isEmpty {
                        PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                            .stroke(Color.primaryColor, lineWidth: 8)
                    } else {
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            PathRenderer.makePath(from: seg.points, in: frame, smoothness: 1.0)
                                .stroke(Color(hex: seg.colorHex), lineWidth: 8)
                        }
                    }
                } else if doodle.points.first != nil {
                    // Single point: draw as a marker
                    let cgPoint = CGPoint(x: rect.midX, y: rect.midY)
                    Circle()
                        .fill(doodle.startColor)
                        .frame(width: 24, height: 24)
                        .position(cgPoint)
                    Circle()
                        .stroke(Color.black, lineWidth: 3)
                        .frame(width: 24, height: 24)
                        .position(cgPoint)
                }
                
                // Contextual illustrations, through the same frame as the path.
                if !doodle.illustrations.isEmpty, let frame {
                    ContextualIllustrationView(
                        positionedIllustrations: PathRenderer.positionIllustrations(doodle.illustrations, in: frame),
                        iconSize: 20
                    )
                }
            }
            .background(Color.white)
        }
    }
}

// MARK: - Single Point Snapshot View
private struct SinglePointSnapshotView: View {
    let doodle: Doodle
    
    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)
            let frame = PathRenderer.frame(for: doodle.renderPoints, in: rect)
            
            ZStack {
                // Draw a prominent marker for the single point
                let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
                
                // Outer ring
                Circle()
                    .stroke(Color.black, lineWidth: 4)
                    .frame(width: 60, height: 60)
                    .position(centerPoint)
                
                // Inner filled circle
                Circle()
                    .fill(doodle.startColor)
                    .frame(width: 48, height: 48)
                    .position(centerPoint)
                
                // Small center dot
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(centerPoint)
                
                // Draw contextual illustrations around the point
                if !doodle.illustrations.isEmpty, let frame {
                    ContextualIllustrationView(
                        positionedIllustrations: PathRenderer.positionIllustrations(doodle.illustrations, in: frame),
                        iconSize: 24
                    )
                }
            }
            .background(Color.white)
        }
    }
}

#Preview {
    TrackingView(strokeColor: .primaryColor)
} 
