import SwiftUI

struct ContentView: View {
    @StateObject private var sdCardManager = SDCardManager()
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if sdCardManager.isSDCardMounted {
                    RAWFileGridView(manager: sdCardManager)
                } else {
                    SDCardPromptView(manager: sdCardManager)
                }
            }
            .navigationTitle("RAW Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sdCardManager.forceRefresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
            }
        }
        .onAppear {
            // Wire the live settings object into the manager once at startup.
            // From this point on, the manager always reads current values directly
            // from settings whenever analysis runs — no need to pass it as an argument.
            sdCardManager.settings = settings
            sdCardManager.refresh()
        }
    }
}
