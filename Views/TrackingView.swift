import SwiftUI
import CoreLocation

struct TrackingView: View {
    @StateObject private var tracker = LocationManager()
    @State private var isCompleted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let rect = proxy.frame(in: .local)
                let points = tracker.locations.map { Coordinate($0.coordinate) }
                let path = PathRenderer.makePath(from: points, in: rect, addJitter: true)
                path.stroke(Color.black, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 2]))
            }
            .background(Color.white)
            .onAppear { tracker.requestAuthorization(); tracker.start() }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Text(Date(), style: .time)
                        .font(.caption)
                        .padding(6)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(String(format: "%.2f km", tracker.distance / 1000))
                        .font(.headline)
                        .padding(6)
                }
            }
            .padding()

            VStack {
                Spacer()
                Button {
                    // stop tracking
                    isCompleted = true
                } label: {
                    Text("Done")
                        .font(.title2)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.black, lineWidth: 2)
                        )
                        .background(Color.white.opacity(0.8))
                }
                .padding(.bottom, 40)
            }
        }
        .fullScreenCover(isPresented: $isCompleted) {
            if let result = completeSession() {
                CompleteDoodleView(result: result)
            } else {
                EmptyView()
                    .onAppear { dismiss() }
            }
        }
    }

    private func completeSession() -> (Doodle, UIImage)? {
        let summary = tracker.stop()
        // Create doodle
        let doodle = Doodle(points: summary.points, distance: summary.distance, duration: summary.duration)

        // Render image snapshot
        let renderer = ImageRenderer(content: PathSnapshotView(doodle: doodle))
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else { return nil }
        return (doodle, uiImage)
    }
}

private struct PathSnapshotView: View {
    let doodle: Doodle
    var body: some View {
        GeometryReader { proxy in
            let path = PathRenderer.makePath(from: doodle.points, in: proxy.frame(in: .local))
            path.stroke(Color.black, lineWidth: 4)
                .background(Color.white)
        }
    }
}

#Preview {
    TrackingView()
} 