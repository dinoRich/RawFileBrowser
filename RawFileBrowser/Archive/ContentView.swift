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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Settings gear — leading side
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                // Refresh — trailing side (unchanged)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sdCardManager.forceRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            // Settings sheet
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
            }
        }
        .onAppear { sdCardManager.refresh() }
    }
}
