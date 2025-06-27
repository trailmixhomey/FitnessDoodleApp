import SwiftUI

struct StartDoodlingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showTracking = false

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                GoButton {
                    showTracking = true
                }
                Spacer()
            }
            .navigationTitle("Start Doodling")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showTracking) {
                TrackingView()
            }
            .background(Color.white)
            .ignoresSafeArea()
        }
    }

    private struct GoButton: View {
        var action: () -> Void
        var body: some View {
            Button(action: action) {
                Text("GO")
                    .font(.custom("Noteworthy", size: 60))
                    .frame(width: 200, height: 200)
                    .background(Circle().stroke(Color.black, lineWidth: 4))
            }
        }
    }
}

#Preview {
    NavigationStack {
        StartDoodlingView()
    }
} 