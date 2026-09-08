import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            HomeView()
                .navigationDestination(for: Doodle.self) { doodle in
                    DoodleDetailView(doodle: doodle)
                }
        }
        .background(Color.white)
    }
}

#Preview {
    ContentView()
        .environmentObject(DoodleStore())
} 