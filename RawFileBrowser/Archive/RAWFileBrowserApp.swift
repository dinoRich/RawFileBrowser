import SwiftUI

@main
struct RAWFileBrowserApp: App {

    // Create ONE AppSettings instance here at the app root.
    // It is injected into every view through the SwiftUI environment.
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
