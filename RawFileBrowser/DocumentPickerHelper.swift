import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    var onDirectoryPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onDirectoryPicked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Start accessing BEFORE passing to onPick.
            // SDCardManager.loadFilesFromDirectory will call stop when done.
            let ok = url.startAccessingSecurityScopedResource()
            guard ok else {
                print("RAWBrowser: failed to access security scoped resource")
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

struct BrowseSDCardButton: View {
    @ObservedObject var manager: SDCardManager
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("Browse SD Card", systemImage: "sdcard")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
        }
        .sheet(isPresented: $showPicker) {
            DocumentPickerView { directoryURL in
                // Dismiss the sheet first, then load.
                // Without this ordering the NavigationStack can pop before
                // isSDCardMounted flips to true.
                showPicker = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    manager.loadFilesFromDirectory(directoryURL)
                }
            }
        }
    }
}
