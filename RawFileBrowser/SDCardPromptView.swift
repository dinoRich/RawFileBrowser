import SwiftUI

struct SDCardPromptView: View {
    @ObservedObject var manager: SDCardManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 72))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                Text("No SD Card Detected")
                    .font(.title2.weight(.bold))

                Text("Connect an SD card reader via Lightning or USB-C, then tap Browse to select your card.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                BrowseSDCardButton(manager: manager)

                Label("Supported: ARW, CR2, CR3, NEF, ORF, RAF, DNG + more",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
