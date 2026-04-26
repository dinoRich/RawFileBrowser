import SwiftUI
struct ContentView: View {
    @StateObject private var sdCardManager = SDCardManager()
    var body: some View {
        NavigationStack {
            Group {
                if sdCardManager.isSDCardMounted { RAWFileGridView(manager: sdCardManager) }
                else { SDCardPromptView(manager: sdCardManager) }
            }
            .navigationTitle("RAW Browser")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sdCardManager.forceRefresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .onAppear { sdCardManager.refresh() }
    }
}
