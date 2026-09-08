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
            // Apply custom font globally. Replace "MessyHandwritten" with the exact PostScript name of the font after adding it to the project.
            .environment(\.font, .custom("MessyHandwritten-Regular", size: 17))
            .tint(.primaryColor)
        }
    }
} 
