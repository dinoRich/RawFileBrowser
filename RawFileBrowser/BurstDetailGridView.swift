import SwiftUI

/// The grid shown when the user taps a burst stack. Displays only the photos
/// in that stack, with filter pills scoped to those photos. A "All Photos"
/// back button is always visible in the navigation bar.
struct BurstDetailGridView: View {
    let stack: BurstStack
    @ObservedObject var manager: SDCardManager
    @Binding var activeStack: BurstStack?

    /// Called just before activeStack is cleared, so the parent can capture
    /// the stack ID and restore the scroll position.
    var onDismiss: () -> Void = {}

    @State private var selectedFile: RAWFile?
    @State private var filterMode: RAWFileGridView.FilterMode = .all

    // MARK: - Derived data

    /// Live versions of this stack's files, so badges update in real time.
    private var liveFiles: [RAWFile] {
        stack.files.compactMap { file in
            manager.rawFiles.first { $0.id == file.id }
        }
    }

    /// Count of files in this stack matching a given filter mode.
    private func count(for mode: RAWFileGridView.FilterMode) -> Int {
        switch mode {
        case .all:        return liveFiles.count
        case .bursts:     return 0   // not applicable inside a stack
        case .accepted:   return liveFiles.filter { $0.pickStatus == .accepted }.count
        case .rejected:   return liveFiles.filter { $0.pickStatus == .rejected }.count
        case .sharp:      return liveFiles.filter { $0.focusStatus == .sharp }.count
        case .unanalyzed: return liveFiles.filter { $0.focusStatus == .unanalyzed }.count
        }
    }

    /// Files shown after the current filter is applied.
    private var filteredFiles: [RAWFile] {
        switch filterMode {
        case .all, .bursts: return liveFiles
        case .accepted:     return liveFiles.filter { $0.pickStatus == .accepted }
        case .rejected:     return liveFiles.filter { $0.pickStatus == .rejected }
        case .sharp:        return liveFiles.filter { $0.focusStatus == .sharp }
        case .unanalyzed:   return liveFiles.filter { $0.focusStatus == .unanalyzed }
        }
    }

    /// "All" always visible; "Bursts" never visible inside a stack;
    /// others only when at least one photo matches.
    private var visibleFilterModes: [RAWFileGridView.FilterMode] {
        RAWFileGridView.FilterMode.allCases.filter { mode in
            if mode == .bursts { return false }
            return mode == .all || count(for: mode) > 0
        }
    }

    private var columns: [SwiftUI.GridItem] {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12),
                     count: isIPad ? 3 : 2)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Filter pills scoped to this stack
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleFilterModes, id: \.self) { mode in
                        FilterPill(
                            mode: mode,
                            count: count(for: mode),
                            isSelected: filterMode == mode
                        ) {
                            filterMode = mode
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            if filteredFiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredFiles) { file in
                            RAWFileThumbnailCard(file: file, manager: manager)
                                .onTapGesture { selectedFile = file }
                                .id("\(file.id)-\(file.focusStatus.rawValue)-\(file.pickStatus.rawValue)")
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
            }
        }
        .navigationTitle("Burst (\(stack.count) photos)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // Fire the callback first so the parent captures the ID
                    // before activeStack is set to nil.
                    onDismiss()
                    activeStack = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("All Photos")
                    }
                }
            }
        }
        .sheet(item: $selectedFile) { file in
            RAWFileDetailView(fileID: file.id, manager: manager)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No photos match")
                .font(.title2.weight(.semibold))
            Text("Try a different filter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
