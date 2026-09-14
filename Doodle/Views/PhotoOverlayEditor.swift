import SwiftUI

/// Where the route sits on the photo.
///
/// Every value is a fraction of the photo rather than a number of points, which is what lets the
/// same placement be drawn onto the 300pt preview the user is dragging and the 2048px image that
/// gets exported and have the two match. Storing points would have made the exported route a
/// seventh of the size it looked on screen.
struct RouteOverlayPlacement: Equatable {
    /// Centre of the route, in unit coordinates within the photo.
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Side of the square the route is drawn into, as a fraction of the photo's shorter edge.
    var size: CGFloat = 0.6
    var rotation: Angle = .zero
    /// Stroke width, as a fraction of the photo's shorter edge.
    var lineWidth: CGFloat = 0.014
    /// A single colour for the whole route, or nil to keep the colours it was walked in.
    var colorHex: String?

    static let sizeRange: ClosedRange<CGFloat> = 0.15...1.6
    static let lineWidthRange: ClosedRange<CGFloat> = 0.004...0.045
}

/// Draws a doodle's route over a photo at whatever size the photo is being shown.
struct RouteOverlay: View {
    let doodle: Doodle
    let placement: RouteOverlayPlacement
    /// The size the photo occupies — screen points while editing, pixels when exporting.
    let photoSize: CGSize

    var body: some View {
        let shortEdge = min(photoSize.width, photoSize.height)
        let box = shortEdge * placement.size
        let rect = CGRect(x: 0, y: 0, width: box, height: box)
        let lineWidth = shortEdge * placement.lineWidth

        ZStack {
            if doodle.points.count > 1, let frame = PathRenderer.frame(for: doodle.renderPoints, in: rect) {
                // A pale casing under the line, so the route stays readable over a photo that
                // happens to be the same colour as it. Drawn as a single wider stroke of the
                // whole route rather than per segment, or the segments outline each other.
                ForEach(strokes.indices, id: \.self) { index in
                    PathRenderer.makePath(from: strokes[index].points, in: frame, smoothness: 1.0)
                        .stroke(Color.white.opacity(0.9),
                                style: StrokeStyle(lineWidth: lineWidth * 2.1, lineCap: .round, lineJoin: .round))
                }
                ForEach(strokes.indices, id: \.self) { index in
                    PathRenderer.makePath(from: strokes[index].points, in: frame, smoothness: 1.0)
                        .stroke(strokes[index].color,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            } else if let only = doodle.points.first {
                let point = PathRenderer.frame(for: [only], in: rect)
                    .map { PathRenderer.point(for: only, in: $0) } ?? CGPoint(x: box / 2, y: box / 2)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: lineWidth * 5, height: lineWidth * 5)
                    .position(point)
                Circle()
                    .fill(strokes.first?.color ?? doodle.startColor)
                    .frame(width: lineWidth * 3.4, height: lineWidth * 3.4)
                    .position(point)
            }
        }
        .frame(width: box, height: box)
        .rotationEffect(placement.rotation)
        .position(x: placement.center.x * photoSize.width,
                  y: placement.center.y * photoSize.height)
    }

    /// The route as a list of coloured runs: the segments it was walked in, or one run when the
    /// user has picked a single colour for the overlay.
    private var strokes: [(points: [Coordinate], color: Color)] {
        if let colorHex = placement.colorHex {
            let color = Color(hex: colorHex)
            let runs = doodle.segments.isEmpty ? [doodle.points] : doodle.segments.map(\.points)
            return runs.map { ($0, color) }
        }
        if doodle.segments.isEmpty {
            return [(doodle.points, doodle.startColor)]
        }
        return doodle.segments.map { ($0.points, Color(hex: $0.colorHex)) }
    }
}

/// Places a walk's route onto a photo taken during it, and composes the two into one image.
struct PhotoOverlayEditor: View {
    let photo: UIImage
    let doodle: Doodle
    /// The composed image, at the photo's full resolution.
    let onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var placement = RouteOverlayPlacement()
    /// The rect the photo actually occupies on screen, which is what gesture distances have to be
    /// measured against — not the view's bounds, which include the letterboxing around it.
    @State private var photoRect: CGRect = .zero
    @State private var isSharing = false
    @State private var shareImage: UIImage?

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var twist: Angle = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editingSurface
                controls
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Place Your Route").font(.messyLarge(.headline))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(compose())
                        dismiss()
                    }
                    .font(.messyLarge(.headline))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $isSharing) {
                if let shareImage {
                    ActivityView(activityItems: [shareImage])
                }
            }
        }
    }

    // MARK: - The photo and the route on top of it

    private var editingSurface: some View {
        GeometryReader { proxy in
            let rect = fittedPhotoRect(in: proxy.size)
            ZStack {
                Color.black
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                RouteOverlay(doodle: doodle, placement: livePlacement, photoSize: rect.size)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(placementGesture)
            .onAppear { photoRect = rect }
            .onChange(of: proxy.size) { _, _ in photoRect = fittedPhotoRect(in: proxy.size) }
        }
    }

    /// Where an aspect-fitted photo lands inside `container`.
    private func fittedPhotoRect(in container: CGSize) -> CGRect {
        guard photo.size.width > 0, photo.size.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / photo.size.width, container.height / photo.size.height)
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// `placement` with whatever gesture is in flight applied, so the route follows the finger
    /// without each frame committing a value the gesture might still take back.
    private var livePlacement: RouteOverlayPlacement {
        var live = placement
        if photoRect.width > 0, photoRect.height > 0 {
            live.center.x += dragTranslation.width / photoRect.width
            live.center.y += dragTranslation.height / photoRect.height
        }
        live.size = clampedSize(placement.size * pinch)
        live.rotation += twist
        return live
    }

    private var placementGesture: some Gesture {
        let drag = DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard photoRect.width > 0, photoRect.height > 0 else { return }
                // Kept inside the photo: a route dragged off the edge is invisible in the export
                // and there is nothing on screen to tell the user where it went.
                placement.center.x = min(max(placement.center.x + value.translation.width / photoRect.width, 0), 1)
                placement.center.y = min(max(placement.center.y + value.translation.height / photoRect.height, 0), 1)
            }

        let magnify = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in placement.size = clampedSize(placement.size * value) }

        let rotate = RotationGesture()
            .updating($twist) { value, state, _ in state = value }
            .onEnded { value in placement.rotation += value }

        return drag.simultaneously(with: magnify.simultaneously(with: rotate))
    }

    private func clampedSize(_ size: CGFloat) -> CGFloat {
        min(max(size, RouteOverlayPlacement.sizeRange.lowerBound), RouteOverlayPlacement.sizeRange.upperBound)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                colorSwatch(hex: nil)
                ForEach(paletteHexes, id: \.self) { hex in
                    colorSwatch(hex: hex)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "scribble").foregroundStyle(.white.opacity(0.7))
                Slider(value: $placement.lineWidth, in: RouteOverlayPlacement.lineWidthRange)
                    .tint(.white)
            }

            HStack {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        placement = RouteOverlayPlacement()
                    }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.messyLarge(.subheadline))
                }
                Spacer()
                Button {
                    shareImage = compose()
                    isSharing = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.messyLarge(.subheadline))
                }
            }
            .foregroundStyle(.white)

            Text("Drag to move · pinch to resize · twist to rotate")
                .font(.messyLarge(.caption))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(Color.black)
    }

    private var paletteHexes: [String] {
        [Color.fern, .coral, .cantaloupe, .cerulean, .primaryColor, .white, .black]
            .map { Color.hexString(for: $0) }
    }

    /// A swatch. `nil` is the "as walked" option, which keeps the route's own segment colours.
    @ViewBuilder
    private func colorSwatch(hex: String?) -> some View {
        let isSelected = placement.colorHex == hex
        Circle()
            .fill(swatchFill(hex: hex))
            .frame(width: isSelected ? 34 : 28, height: isSelected ? 34 : 28)
            .overlay(Circle().stroke(.white.opacity(isSelected ? 1 : 0.35), lineWidth: isSelected ? 3 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            .onTapGesture { placement.colorHex = hex }
    }

    private func swatchFill(hex: String?) -> AnyShapeStyle {
        guard let hex else {
            // The multi-colour option shows the colours it would keep.
            let colors = doodle.segments.isEmpty
                ? [doodle.startColor, doodle.startColor]
                : doodle.segments.map { Color(hex: $0.colorHex) }
            return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
        }
        return AnyShapeStyle(Color(hex: hex))
    }

    // MARK: - Export

    private func compose() -> UIImage {
        RouteOverlay.compose(photo: photo, doodle: doodle, placement: placement)
    }
}

extension RouteOverlay {
    /// Draws the photo and the route together at the photo's own resolution.
    ///
    /// The placement is in fractions of the photo, so handing `RouteOverlay` the pixel size here
    /// rather than the on-screen size is the whole of what makes the export match the preview.
    @MainActor
    static func compose(photo: UIImage, doodle: Doodle, placement: RouteOverlayPlacement) -> UIImage {
        let size = photo.size
        let content = ZStack {
            Image(uiImage: photo)
                .resizable()
                .frame(width: size.width, height: size.height)
            RouteOverlay(doodle: doodle, placement: placement, photoSize: size)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        // `photo` comes back from `PhotoStore` at scale 1, so its size is already in pixels and
        // scaling again here would render a multiple of the intended resolution.
        renderer.scale = 1
        guard let image = renderer.uiImage else {
            Log.general.error("Could not compose the photo overlay; falling back to the photo")
            return photo
        }
        return image
    }
}

/// Loads a stored photo off the main thread, then hands it to the editor.
///
/// The editor needs the photo at full resolution to compose against, and reading a couple of
/// megabytes off disk is not something to do while a sheet is animating in.
struct PhotoOverlayEditorSheet: View {
    let photoID: String
    let doodle: Doodle
    let onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?

    var body: some View {
        Group {
            if let photo {
                PhotoOverlayEditor(photo: photo, doodle: doodle, onSave: onSave)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        }
        .task {
            let id = photoID
            photo = await Task.detached(priority: .userInitiated) {
                PhotoStore.shared.image(for: id)
            }.value
            if photo == nil {
                Log.general.error("Photo file is missing; cannot open the overlay editor")
                dismiss()
            }
        }
    }
}
