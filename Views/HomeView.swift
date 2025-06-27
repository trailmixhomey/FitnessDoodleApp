import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: DoodleStore
    @State private var isPresentingStart = false
    // Adaptive grid layout for doodle thumbnails
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 100), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(store.doodles) { doodle in
                    NavigationLink(value: doodle) {
                        VStack(alignment: .center, spacing: 6) {
                            DoodleThumbnail(doodle: doodle)
                                .frame(width: 100, height: 100)
                            Text(doodle.date, style: .date)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text(String(format: "%.2f km", doodle.distance/1000))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain) // Remove default link styling so thumbnails appear borderless
                }
            }
            .padding(20)
        }
        .navigationTitle("Your Doodles")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { isPresentingStart = true }) {
                    Label("Start Doodling", systemImage: "figure.walk")
                }
            }
        }
        .sheet(isPresented: $isPresentingStart) {
            StartDoodlingView()
        }
        // Pure white background on entire screen
        .background(Color.white)
        .ignoresSafeArea()
    }
}

private struct DoodleThumbnail: View {
    let doodle: Doodle
    var body: some View {
        GeometryReader { proxy in
            let path = PathRenderer.makePath(from: doodle.points, in: proxy.frame(in: .local))
            path.stroke(Color.black, lineWidth: 3)
        }
        .frame(width: 60, height: 60)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(DoodleStore(preloaded: [
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0.1, longitude: 0.1)], distance: 1234, duration: 1000)
            ]))
    }
} 