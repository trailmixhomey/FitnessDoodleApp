import SwiftUI

@main
struct FitnessDoodleApp: App {
    @StateObject private var store = DoodleStore()
    /// Persisted: an app tracking a walk in the background can be terminated by iOS at any
    /// time, and a sign-in kept only in memory turned every such termination into a logout
    /// on a screen the user had no reason to expect.
    @AppStorage("isSignedIn") private var loggedIn = false

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
            // Apply custom font globally. Replace "MessyHandwritten" with the exact PostScript name of the font after adding it to the project.
            .environment(\.font, .custom("MessyHandwritten-Regular", size: 17))
            .tint(.primaryColor)
        }
    }
} 
