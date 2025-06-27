import SwiftUI

@main
struct FitnessDoodleApp: App {
    @StateObject private var store = DoodleStore()
    @State private var loggedIn = false

    var body: some Scene {
        WindowGroup {
            Group {
                if loggedIn {
                    ContentView()
                        .environmentObject(store)
                } else {
                    LoginView {
                        loggedIn = true
                    }
                }
            }
        }
    }
} 