import SwiftUI
import MapKit

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            alpha: Double(a) / 255
        )
    }
}



struct DoodleDetailView: View {
    let doodle: Doodle
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DoodleStore
    @State private var selectedTab = 0
    @State private var currentDoodle: Doodle
    @State private var showingDeleteAlert = false
    
    init(doodle: Doodle) {
        self.doodle = doodle
        self._currentDoodle = State(initialValue: doodle)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Swipeable doodle visualization
                TabView(selection: $selectedTab) {
                    // Blank Doodle View (WHITE BACKGROUND FIRST)
                    BlankDoodleView(doodle: doodle)
                        .tag(0)
                    
                    // Map Overlap View (MAP SECOND)
                    MapOverlapView(doodle: doodle)
                        .tag(1)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 20)
                
                // View indicator
                HStack {
                    Text(getViewTitle())
                        .font(.messyLarge(.caption))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(selectedTab + 1) of 2")
                        .font(.messyLarge(.caption))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 20)
                
                // Doodle details
                VStack(spacing: 16) {
                    // Date
                    VStack(spacing: 4) {
                        Text("Date")
                            .font(.messyLarge(.caption))
                            .foregroundColor(.primary)
                        Text(doodle.date, style: .date)
                            .font(.messyLarge(.title2, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    
                    // Time of day
                    VStack(spacing: 4) {
                        Text("Time Started")
                            .font(.messyLarge(.caption))
                            .foregroundColor(.primary)
                        Text(doodle.date, style: .time)
                            .font(.messyLarge(.title3))
                            .foregroundColor(.primary)
                    }
                    
                    HStack(spacing: 40) {
                        // Distance
                        VStack(spacing: 4) {
                            Text("Distance")
                                .font(.messyLarge(.caption))
                                .foregroundColor(.primary)
                            Text(String(format: "%.2f mi", doodle.distance/1609.34))
                                .font(.messyLarge(.title3, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        
                        // Duration
                        VStack(spacing: 4) {
                            Text("Duration")
                                .font(.messyLarge(.caption))
                                .foregroundColor(.primary)
                            Text(formatDuration(doodle.duration))
                                .font(.messyLarge(.title3, weight: .medium))
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 24) {
                    HStack {
                        Spacer()
                        Button(action: shareDoodle) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                                    .font(.messyLarge(.subheadline))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                        }
                        Spacer()
                    }
                    
                    // Delete button
                    Button(action: { showingDeleteAlert = true }) {
                        Text("Delete Doodle")
                            .font(.messyLarge(.subheadline))
                            .foregroundColor(Color(red: 0.6, green: 0.0, blue: 0.0)) // Dark red
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.white)
            .alert("Delete Doodle", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    deleteDoodle()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete this doodle? This action cannot be undone.")
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func getViewTitle() -> String {
        switch selectedTab {
        case 0: return "Doodle View"
        case 1: return "Map View"
        default: return ""
        }
    }
    
    private func calculateMapRegion(from points: [Coordinate]) -> MKCoordinateRegion {
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
        
        let latitudes = points.map { $0.latitude }
        let longitudes = points.map { $0.longitude }
        
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        
        let latDelta = max(maxLat - minLat, 0.005) * 1.1 // Reduce padding to match PathRenderer bounds  
        let lonDelta = max(maxLon - minLon, 0.005) * 1.1 // Reduce padding to match PathRenderer bounds
        
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
    
    private func shareDoodle() {
        let shareImage = generateShareImageForCurrentView()
        showActivityView(with: shareImage)
    }
    
    private func deleteDoodle() {
        store.delete(doodle)
        dismiss()
    }
    
    private func showActivityView(with image: UIImage) {
        let activityController = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityController, animated: true)
        }
    }
    
    private func generateShareImageForCurrentView() -> UIImage {
        // Social media optimized dimensions: 1080x1920 (9:16 aspect ratio)
        let shareSize = CGSize(width: 1080, height: 1920)
        
        // ALWAYS share the blank doodle (white background) with time elapsed
        return generateBlankDoodleShareImageWithTime(size: shareSize)
    }
    
    private func generateMapShareImage(size: CGSize) -> UIImage {
        // Use MKMapSnapshotter for proper map rendering with map-matched coordinates
        let mapRegion = calculateMapRegion(from: doodle.renderPoints)
        let options = MKMapSnapshotter.Options()
        options.region = mapRegion
        options.size = size
        options.scale = UIScreen.main.scale
        
        let snapshotter = MKMapSnapshotter(options: options)
        let semaphore = DispatchSemaphore(value: 0)
        var snapshotImage: UIImage?
        
        snapshotter.start { snapshot, error in
            defer { semaphore.signal() }
            
            guard let snapshot = snapshot, error == nil else {
                Log.general.error("Map snapshot failed: \(error?.localizedDescription ?? "Unknown error", privacy: .public)")
                return
            }
            
            // Create a composite image with the map and doodle overlay
            let renderer = UIGraphicsImageRenderer(size: size)
            snapshotImage = renderer.image { context in
                // Draw the map snapshot
                snapshot.image.draw(at: .zero)
                
                // Add semi-transparent white overlay for better doodle visibility
                UIColor.white.withAlphaComponent(0.3).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                
                // Draw the doodle path on top using map-matched coordinates
                let rect = CGRect(origin: .zero, size: size)
                context.cgContext.setLineWidth(8.0)
                
                let referencePoints = doodle.renderPoints
                if let frame = PathRenderer.frame(for: referencePoints, in: rect) {
                    if doodle.segments.isEmpty {
                        // Draw single path with original points
                        let path = PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                        context.cgContext.addPath(path.cgPath)
                        UIColor.systemBlue.setStroke()
                        context.cgContext.strokePath()
                    } else {
                        // Every colour segment through the one frame, so they stay a single route.
                        for segment in doodle.segments {
                            let path = PathRenderer.makePath(from: segment.points, in: frame, smoothness: 1.0)
                            context.cgContext.addPath(path.cgPath)
                            UIColor(hex: segment.colorHex).setStroke()
                            context.cgContext.strokePath()
                        }
                    }

                    // Draw start/end markers
                    if let first = referencePoints.first {
                        let cgPoint = PathRenderer.point(for: first, in: frame)
                        let startRect = CGRect(x: cgPoint.x - 8, y: cgPoint.y - 8, width: 16, height: 16)
                        UIColor(doodle.startColor).setFill()
                        context.cgContext.fillEllipse(in: startRect)
                    }
                    if let last = referencePoints.last {
                        let cgPoint = PathRenderer.point(for: last, in: frame)
                        let endRect = CGRect(x: cgPoint.x - 8, y: cgPoint.y - 8, width: 16, height: 16)
                        UIColor.black.setStroke()
                        context.cgContext.setLineWidth(3.0)
                        context.cgContext.strokeEllipse(in: endRect)
                    }
                }
            }
        }
        
        // Wait for snapshot to complete (with timeout)
        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            Log.general.error("Map snapshot timed out")
            return generateFallbackShareImage(size: size)
        }
        
        return snapshotImage ?? generateFallbackShareImage(size: size)
    }
    
    private func generateBlankDoodleShareImage(size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: ShareBlankDoodleView(doodle: doodle)
            .frame(width: size.width, height: size.height))
        renderer.scale = 3.0
        
        if let uiImage = renderer.uiImage {
            return uiImage
        } else {
            // Fallback to basic doodle view
            return generateFallbackShareImage(size: size)
        }
    }
    
    private func generateBlankDoodleShareImageWithTime(size: CGSize) -> UIImage {
        // First generate the base doodle image
        let baseImage = generateBlankDoodleShareImage(size: size)
        
        // Create a new image with the time elapsed overlay
        let finalImage = UIGraphicsImageRenderer(size: size).image { context in
            // Draw the base doodle image
            baseImage.draw(at: .zero)
            
            let timeText = formatDuration(doodle.duration)

            let fontSize: CGFloat = 120
            let font = UIFont(name: "MessyHandwritten-Bold", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)

            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]

            let textSize = timeText.size(withAttributes: textAttributes)

            let textOrigin = CGPoint(
                x: size.width * 0.65 - textSize.width / 2,
                y: size.height * 0.25
            )

            timeText.draw(at: textOrigin, withAttributes: textAttributes)
            
        }
        
        return finalImage
    }
    
    private func generateFallbackShareImage(size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: ShareDoodleView(doodle: doodle)
            .frame(width: size.width, height: size.height))
        renderer.scale = 3.0
        
        return renderer.uiImage ?? UIImage()
    }
}

private struct ShareDoodleView: View {
    let doodle: Doodle
    private let shareLineWidthMultiplier: CGFloat = 3.0 // 3x thicker lines for shares
    
    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)
            // One frame for the whole share image: path, icons and markers all placed through it.
            let referencePoints = doodle.renderPoints
            let frame = PathRenderer.frame(for: referencePoints, in: rect)
            
            ZStack {
                if let frame {
                    // Scenery first, so the route is drawn over its own decoration.
                    if !doodle.scenery.isEmpty {
                        SceneryView(
                            positionedScenery: PathRenderer.positionScenery(doodle.scenery, in: frame),
                            itemSize: 22 * shareLineWidthMultiplier
                        )
                    }

                    if doodle.segments.isEmpty {
                        PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                            .stroke(Color.primaryColor, lineWidth: 8 * shareLineWidthMultiplier) // 24pt
                    } else {
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            PathRenderer.makePath(from: seg.points, in: frame, smoothness: 1.0)
                                .stroke(Color(hex: seg.colorHex), lineWidth: 8 * shareLineWidthMultiplier) // 24pt
                        }
                    }
                    
                    // Contextual illustrations
                    if !doodle.illustrations.isEmpty {
                        ContextualIllustrationView(
                            positionedIllustrations: PathRenderer.positionIllustrations(doodle.illustrations, in: frame),
                            iconSize: 20
                        )
                    }
                    
                    // Start/End markers
                    if let first = referencePoints.first {
                        HandDrawnCircle(isFilled: true, color: doodle.startColor)
                            .frame(width: 28, height: 28)
                            .position(PathRenderer.point(for: first, in: frame))
                    }
                    if let last = referencePoints.last {
                        HandDrawnCircle(isFilled: false, color: .black, strokeWidth: 4)
                            .frame(width: 28, height: 28)
                            .position(PathRenderer.point(for: last, in: frame))
                    }
                }
            }
            .background(Color.white)
        }
    }
}

private struct ShareBlankDoodleView: View {
    let doodle: Doodle
    private let shareLineWidthMultiplier: CGFloat = 3.0 // 3x thicker lines for shares
    
    var body: some View {
        GeometryReader { geometry in
            let rect = geometry.frame(in: .local)
            // One frame for the whole drawing, shared by every segment and both markers.
            let referencePoints = doodle.renderPoints
            let frame = PathRenderer.frame(for: referencePoints, in: rect)
            
            ZStack {
                // Pure white background
                Color.white
                
                // Handle single point vs path doodles
                if doodle.points.count > 1, let frame {
                    if doodle.segments.isEmpty {
                        PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                            .stroke(Color.primaryColor, lineWidth: 8 * shareLineWidthMultiplier) // 24pt
                    } else {
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            PathRenderer.makePath(from: seg.points, in: frame, smoothness: 1.0)
                                .stroke(Color(hex: seg.colorHex), lineWidth: 8 * shareLineWidthMultiplier) // 24pt
                        }
                    }
                    
                    // Start/End markers, through the same frame as the path.
                    if let first = referencePoints.first {
                        HandDrawnCircle(isFilled: true, color: doodle.startColor)
                            .frame(width: 24, height: 24)
                            .position(PathRenderer.point(for: first, in: frame))
                    }
                    if let last = referencePoints.last {
                        HandDrawnCircle(isFilled: false, color: .black, strokeWidth: 3)
                            .frame(width: 24, height: 24)
                            .position(PathRenderer.point(for: last, in: frame))
                    }
                } else if doodle.points.first != nil {
                    // Single point doodle - draw as a prominent marker
                    let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
                    
                    // Outer ring
                    HandDrawnCircle(isFilled: false, color: .black, strokeWidth: 6)
                        .frame(width: 72, height: 72)
                        .position(centerPoint)
                    
                    // Inner filled circle
                    HandDrawnCircle(isFilled: true, color: doodle.startColor)
                        .frame(width: 54, height: 54)
                        .position(centerPoint)
                    
                    // Small center dot
                    HandDrawnCircle(isFilled: true, color: .white)
                        .frame(width: 12, height: 12)
                        .position(centerPoint)
                }
            }
        }
        .background(Color.white)
        .colorScheme(.light)
        .preferredColorScheme(.light)
    }
}

private struct HandDrawnCircle: View {
    let isFilled: Bool
    let color: Color
    let strokeWidth: CGFloat
    
    init(isFilled: Bool, color: Color, strokeWidth: CGFloat = 2) {
        self.isFilled = isFilled
        self.color = color
        self.strokeWidth = strokeWidth
    }
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2
            
            // Create hand-drawn circle path once
            let handDrawnPath = createHandDrawnCirclePath(center: center, radius: radius)
            
            ZStack {
                if isFilled {
                    handDrawnPath
                        .fill(color)
                } else {
                    handDrawnPath
                        .stroke(color, lineWidth: strokeWidth)
                }
            }
        }
    }
    
    private func createHandDrawnCirclePath(center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            let points = 16 // Number of points around the circle
            let angleStep = 2 * Double.pi / Double(points)
            var pathPoints: [CGPoint] = []
            
            // Generate all points first
            for i in 0..<points {
                let angle = Double(i) * angleStep
                // Add small random variation to radius (±5% of radius)
                let variation = Double.random(in: -0.05...0.05) * Double(radius)
                let adjustedRadius = Double(radius) + variation
                
                let x = center.x + CGFloat(cos(angle) * adjustedRadius)
                let y = center.y + CGFloat(sin(angle) * adjustedRadius)
                pathPoints.append(CGPoint(x: x, y: y))
            }
            
            // Create path with curves
            path.move(to: pathPoints[0])
            
            for i in 1..<pathPoints.count {
                let currentPoint = pathPoints[i]
                let prevPoint = pathPoints[i - 1]
                
                // Add slight variation to control points for more organic curves
                let controlPoint = CGPoint(
                    x: (prevPoint.x + currentPoint.x) / 2 + CGFloat.random(in: -1...1),
                    y: (prevPoint.y + currentPoint.y) / 2 + CGFloat.random(in: -1...1)
                )
                
                path.addQuadCurve(to: currentPoint, control: controlPoint)
            }
            
            // Close the path back to start
            if let lastPoint = pathPoints.last {
                let controlPoint = CGPoint(
                    x: (lastPoint.x + pathPoints[0].x) / 2 + CGFloat.random(in: -1...1),
                    y: (lastPoint.y + pathPoints[0].y) / 2 + CGFloat.random(in: -1...1)
                )
                path.addQuadCurve(to: pathPoints[0], control: controlPoint)
            }
            path.closeSubpath()
        }
    }
}

#Preview {
    DoodleDetailView(doodle: Doodle(
        points: [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.1, longitude: 0.1),
            Coordinate(latitude: 0.2, longitude: 0.05)
        ],
        distance: 1234,
        duration: 1800
    ))
}


// MARK: - Map Overlap View
private struct MapOverlapView: View {
    let doodle: Doodle
    
    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)
            // Calculate reference points once for the entire view
            let referencePoints = doodle.renderPoints
            
            
            
            ZStack {
                // Pure white background
                Color.white
                    .cornerRadius(12)
                
                // Map background - use reference points (map-matched if available) for consistent bounds  
                if !referencePoints.isEmpty {
                    let mapRegion = calculateMapRegion(from: referencePoints)
                    ZStack {
                        // Force white background behind map
                        Rectangle()
                            .fill(Color.white)
                        
                        Map(coordinateRegion: .constant(mapRegion))
                            .allowsHitTesting(false)
                            .opacity(0.15)
                            .background(Color.white)
                            .colorScheme(.light)
                            .preferredColorScheme(.light)
                    }
                    .cornerRadius(12)
                }
                
                // Route overlay - use the SAME coordinate system as the background map  
                if !referencePoints.isEmpty {
                    let mapRegion = calculateMapRegion(from: referencePoints) // Use same bounds as background map
                    
                    if doodle.segments.isEmpty {
                        // Fallback to raw GPS points
                        let path = createMapAlignedPath(from: doodle.points, mapRegion: mapRegion, rect: rect)
                        path.stroke(Color.primaryColor, lineWidth: 8)
                    } else {
                        // Use map-matched segment data with proper map alignment
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            let path = createMapAlignedPath(from: seg.points, mapRegion: mapRegion, rect: rect)
                            path.stroke(Color(hex: seg.colorHex), lineWidth: 8)
                        }
                    }
                }
                
                // Scenery, positioned through the same route-relative frame as the icons.
                if !doodle.scenery.isEmpty {
                    SceneryView(
                        positionedScenery: PathRenderer.positionScenery(
                            doodle.scenery,
                            relativeTo: referencePoints,
                            in: rect
                        ),
                        itemSize: 18
                    )
                }

                // Contextual illustrations - use map-matched coordinates for positioning
                if !doodle.illustrations.isEmpty {
                    let positionedIllustrations = PathRenderer.positionIllustrations(
                        doodle.illustrations,
                        relativeTo: referencePoints,
                        in: rect
                    )
                    ContextualIllustrationView(
                        positionedIllustrations: positionedIllustrations,
                        iconSize: 16
                    )
                }
                
                // Start/End markers - use map-aligned coordinates
                if !referencePoints.isEmpty {
                    let mapRegion = calculateMapRegion(from: referencePoints) // Use same bounds as background map
                    
                    if let first = referencePoints.first {
                        let cgPoint = convertCoordinateToMapRect(first, mapRegion: mapRegion, rect: rect)
                        Circle()
                            .fill(doodle.startColor)
                            .frame(width: 12, height: 12)
                            .position(cgPoint)
                    }
                    if let last = referencePoints.last {
                        let cgPoint = convertCoordinateToMapRect(last, mapRegion: mapRegion, rect: rect)
                        Circle()
                            .stroke(Color.black, lineWidth: 2)
                            .frame(width: 12, height: 12)
                            .position(cgPoint)
                    }
                }
            }
            .cornerRadius(12)
        }
    }
    
    private func calculateMapRegion(from points: [Coordinate]) -> MKCoordinateRegion {
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
        
        let latitudes = points.map { $0.latitude }
        let longitudes = points.map { $0.longitude }
        
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        
        let latDelta = max(maxLat - minLat, 0.005) * 1.1 // Reduce padding to match PathRenderer bounds  
        let lonDelta = max(maxLon - minLon, 0.005) * 1.1 // Reduce padding to match PathRenderer bounds
        
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
    
    /// Create a path that's aligned with the map coordinate system
    private func createMapAlignedPath(from points: [Coordinate], mapRegion: MKCoordinateRegion, rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        
        var path = Path()
        
        // Convert first point
        if let firstPoint = points.first {
            let cgPoint = convertCoordinateToMapRect(firstPoint, mapRegion: mapRegion, rect: rect)
            path.move(to: cgPoint)
        }
        
        // Convert remaining points and create smooth path
        var cgPoints: [CGPoint] = []
        for point in points {
            let cgPoint = convertCoordinateToMapRect(point, mapRegion: mapRegion, rect: rect)
            cgPoints.append(cgPoint)
        }
        
        // Create smooth curves between points
        for i in 1..<cgPoints.count {
            let currentPoint = cgPoints[i]
            
            if i == 1 || i == cgPoints.count - 1 {
                // First and last segments - straight lines
                path.addLine(to: currentPoint)
            } else {
                // Middle segments - smooth curves
                let previousPoint = cgPoints[i-1]
                let nextPoint = cgPoints[i+1]
                
                let controlPoint1 = CGPoint(
                    x: previousPoint.x + (currentPoint.x - previousPoint.x) * 0.5,
                    y: previousPoint.y + (currentPoint.y - previousPoint.y) * 0.5
                )
                let controlPoint2 = CGPoint(
                    x: currentPoint.x - (nextPoint.x - currentPoint.x) * 0.3,
                    y: currentPoint.y - (nextPoint.y - currentPoint.y) * 0.3
                )
                
                path.addCurve(to: currentPoint, control1: controlPoint1, control2: controlPoint2)
            }
        }
        
        return path
    }
    
    /// Convert a coordinate to a CGPoint within the map rect using the same coordinate system as the background map
    private func convertCoordinateToMapRect(_ coordinate: Coordinate, mapRegion: MKCoordinateRegion, rect: CGRect) -> CGPoint {
        let center = mapRegion.center
        let span = mapRegion.span
        
        // Calculate the coordinate's position relative to the map region
        let latRange = span.latitudeDelta
        let lonRange = span.longitudeDelta
        
        let minLat = center.latitude - latRange / 2
        let minLon = center.longitude - lonRange / 2
        
        // Convert to normalized coordinates (0-1)
        let normalizedX = (coordinate.longitude - minLon) / lonRange
        let normalizedY = 1 - (coordinate.latitude - minLat) / latRange // Flip Y so north is up
        
        // Convert to rect coordinates
        return CGPoint(
            x: rect.minX + normalizedX * rect.width,
            y: rect.minY + normalizedY * rect.height
        )
    }
} 