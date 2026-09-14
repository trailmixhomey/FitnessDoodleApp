import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: DoodleStore
    @State private var isPresentingStart = false
    /// An unfinished walk found on disk at launch — a session the app died in the middle of.
    @State private var recoveredSession: SessionJournal.Recovered?
    @State private var showingRecoveryPrompt = false
    @State private var sessionToResume: SessionJournal.Recovered?
    @State private var hasCheckedForUnfinishedSession = false
    // Fixed 3-column grid layout for doodle thumbnails
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Custom header with more spacing
            Text("Your Doodles")
                .font(.messyLarge(.title2, weight: .bold))
                .foregroundColor(.black)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                .background(Color.white)
            
            ScrollView {
            if store.doodles.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "figure.walk.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    Text("No doodles yet")
                        .font(.messy(.title2, weight: .bold))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                    Text("Start your first fitness doodle!")
                        .font(.messy(.subheadline))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.doodles) { doodle in
                        NavigationLink(value: doodle) {
                            VStack(alignment: .center, spacing: 8) {
                                Text(doodle.date, format: .dateTime.month(.abbreviated).day())
                                    .font(.messy(.title2, weight: .bold))
                                    .foregroundColor(.black)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.center)
                                
                                DoodleThumbnail(doodle: doodle)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .buttonStyle(.plain) // Remove default link styling so thumbnails appear borderless
                    }
                }
                .padding(16)
            }
            }
        }
        .scrollContentBackground(.hidden) // Hide the default scroll background
        .background(Color.white) // This ensures the scroll bounce areas are white instead of grey
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(Color.white, for: .bottomBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbarColorScheme(.light, for: .bottomBar)
        .sheet(isPresented: $isPresentingStart) {
            StartDoodlingView()
        }
        .fullScreenCover(item: $sessionToResume) { session in
            TrackingView(resuming: session) {
                sessionToResume = nil
            }
        }
        .onAppear {
            // Only once per launch: coming back to Home after finishing a walk must not re-offer
            // the session that was just saved.
            guard !hasCheckedForUnfinishedSession else { return }
            hasCheckedForUnfinishedSession = true
            if let pending = SessionJournal.pending() {
                recoveredSession = pending
                showingRecoveryPrompt = true
            }
        }
        .alert("Unfinished Walk", isPresented: $showingRecoveryPrompt, presenting: recoveredSession) { session in
            Button("Resume") {
                sessionToResume = session
                recoveredSession = nil
            }
            Button("Discard", role: .destructive) {
                SessionJournal.discard()
                recoveredSession = nil
            }
        } message: { session in
            Text("A walk you started at \(session.startDate.formatted(date: .omitted, time: .shortened)) was never finished. Pick it back up?")
        }
        // Leave top safe area so content starts below navigation bar; keep bottom safe area too for toolbar
        .toolbar {
            // Bottom navigation bar with central plus icon
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Spacer()
                    Button(action: { isPresentingStart = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityIdentifier("startDoodleButton")
                    Spacer()
                }
            }
        }
    }
}

private struct DoodleThumbnail: View {
    let doodle: Doodle
    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)
            // One frame for the whole thumbnail, shared by every segment and both markers.
            let referencePoints = doodle.renderPoints
            let frame = PathRenderer.frame(for: referencePoints, in: rect)
            
            ZStack {
                if doodle.points.count > 1, let frame {
                    // Path doodles
                    if doodle.segments.isEmpty {
                        PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                            .stroke(Color.primaryColor, lineWidth: 4)
                    } else {
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            PathRenderer.makePath(from: seg.points, in: frame, smoothness: 1.0)
                                .stroke(seg.color, lineWidth: 4)
                        }
                    }

                    // Start/end markers, through the same frame as the path.
                    if let first = referencePoints.first {
                        Circle()
                            .fill(doodle.startColor)
                            .frame(width: 4, height: 4)
                            .position(PathRenderer.point(for: first, in: frame))
                    }
                    if let last = referencePoints.last {
                        Circle()
                            .stroke(Color.black, lineWidth: 1)
                            .frame(width: 4, height: 4)
                            .position(PathRenderer.point(for: last, in: frame))
                    }
                } else if doodle.points.first != nil {
                    // Single point doodle - draw as a marker in the center
                    let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
                    
                    // Outer ring
                    Circle()
                        .stroke(Color.black, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .position(centerPoint)
                    
                    // Inner filled circle
                    Circle()
                        .fill(doodle.startColor)
                        .frame(width: 12, height: 12)
                        .position(centerPoint)
                    
                    // Small center dot
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3, height: 3)
                        .position(centerPoint)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(DoodleStore(preloaded: [
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0.1, longitude: 0.1)], distance: 1234, duration: 1000),
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0.1, longitude: -0.05), Coordinate(latitude: 0.2, longitude: 0.05)], distance: 2150, duration: 1500),
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: -0.1, longitude: 0.1)], distance: 980, duration: 600),
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0.05, longitude: 0.15), Coordinate(latitude: 0.1, longitude: 0.05)], distance: 3000, duration: 2400),
                Doodle(points: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: -0.05, longitude: -0.1)], distance: 450, duration: 300),
                Doodle(points: [Coordinate(latitude: 0.05, longitude: 0.05), Coordinate(latitude: 0.15, longitude: 0.15)], distance: 2890, duration: 2100),
                Doodle(points: [Coordinate(latitude: -0.05, longitude: -0.05), Coordinate(latitude: -0.1, longitude: 0.0), Coordinate(latitude: -0.05, longitude: 0.05)], distance: 1750, duration: 1400),
                Doodle(points: [Coordinate(latitude: 0.0, longitude: 0.0), Coordinate(latitude: 0.0, longitude: 0.2)], distance: 2000, duration: 1600),
                Doodle(points: [Coordinate(latitude: 0.02, longitude: 0.02), Coordinate(latitude: 0.08, longitude: 0.1)], distance: 1275, duration: 900),
                Doodle(points: [Coordinate(latitude: 0.0, longitude: 0.0), Coordinate(latitude: -0.15, longitude: -0.15)], distance: 3250, duration: 2500),
                Doodle(points: [Coordinate(latitude: 0.0, longitude: 0.0), Coordinate(latitude: 0.15, longitude: -0.1)], distance: 1425, duration: 1100)
            ]))
    }
} 
