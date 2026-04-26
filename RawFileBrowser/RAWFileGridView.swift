import SwiftUI

struct RAWFileGridView: View {
    @ObservedObject var manager: SDCardManager
    @State private var selectedFile: RAWFile?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var filterMode: FilterMode = .all
    @State private var showAnalysisConfirm = false
    @State private var xmpResultMessage: String? = nil

    enum SortOrder: String, CaseIterable {
        case name = "Name"; case date = "Date"; case size = "Size"
        case sharpness = "Sharpness"
    }

    enum FilterMode: String, CaseIterable {
        case all = "All"
        case sharp = "Sharp"
        case rejected = "Rejected"
        case unanalyzed = "Unanalyzed"
    }

    private var filteredFiles: [RAWFile] {
        var files = manager.rawFiles

        // Search
        if !searchText.isEmpty {
            files = files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // Filter
        switch filterMode {
        case .all: break
        case .sharp:      files = files.filter { $0.focusStatus == .sharp }
        case .rejected:   files = files.filter { $0.isRejected }
        case .unanalyzed: files = files.filter { $0.focusStatus == .unanalyzed }
        }

        // Sort
        return files.sorted {
            switch sortOrder {
            case .name:      return $0.name < $1.name
            case .date:
                let d0 = $0.modificationDate ?? .distantPast
                let d1 = $1.modificationDate ?? .distantPast
                return d0 > d1
            case .size:      return $0.size > $1.size
            case .sharpness: return $0.focusScore > $1.focusScore
            }
        }
    }

    // Fixed 2 columns on iPhone, 3 on iPad — prevents cards growing too wide
    private var columns: [GridItem] {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let count  = isIPad ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Analysis banner
            if manager.isAnalyzing {
                analysisBanner
            } else if manager.rawFiles.contains(where: { $0.focusStatus != .unanalyzed }) {
                analysisSummaryBar
            }

            // Filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        FilterPill(mode: mode, isSelected: filterMode == mode) {
                            filterMode = mode
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // Grid
            if filteredFiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredFiles) { file in
                            RAWFileThumbnailCard(file: file)
                                .onTapGesture { selectedFile = file }
                        }
                    }
                    .padding()
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search files")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                BrowseSDCardButton(manager: manager).labelStyle(.iconOnly)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Analyze button
                if !manager.isAnalyzing {
                    Button {
                        showAnalysisConfirm = true
                    } label: {
                        Label("Analyze Focus", systemImage: "viewfinder.circle")
                    }
                }

                // Write XMP button — only shown when at least one file has a species
                let writeable = manager.rawFiles.filter { $0.detectedAnimalLabel != nil }
                if !writeable.isEmpty {
                    Button {
                        let msg = manager.writeXMPBatch()
                        xmpResultMessage = msg
                    } label: {
                        Label("Write Species XMP", systemImage: "tag")
                    }
                }

                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        // .navigationSubtitle removed — iOS 26+ only
        .sheet(item: $selectedFile) { file in
            RAWFileDetailView(file: file, manager: manager)
        }
        .alert("XMP Written", isPresented: Binding(
            get: { xmpResultMessage != nil },
            set: { if !$0 { xmpResultMessage = nil } }
        )) {
            Button("OK") { xmpResultMessage = nil }
        } message: {
            Text(xmpResultMessage ?? "")
        }
        .confirmationDialog(
            "Analyze \(manager.rawFiles.count) files for sharpness?",
            isPresented: $showAnalysisConfirm,
            titleVisibility: .visible
        ) {
            Button("Analyze All") {
                Task { await manager.analyzeAllFocus() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This may take a moment depending on file count.")
        }
    }

    // MARK: - Subviews

    private var analysisBanner: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "viewfinder.circle")
                Text("Analyzing focus…")
                Spacer()
                Text("\(Int(manager.analysisProgress * 100))%")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))

            ProgressView(value: manager.analysisProgress)
                .tint(.accentColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var analysisSummaryBar: some View {
        HStack(spacing: 16) {
            Label("\(manager.rawFiles.filter { $0.focusStatus == .sharp }.count) sharp",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Label("\(manager.rejectedCount) rejected",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)

            Spacer()

            Button("Re-analyze") {
                Task { await manager.analyzeAllFocus() }
            }
            .font(.caption)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filterMode == .rejected ? "xmark.circle" : "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(filterMode == .rejected ? "No rejected files" : "No files match")
                .font(.title2.weight(.semibold))
            Text(filterMode == .rejected
                 ? "All analyzed photos appear to be in focus."
                 : "Try adjusting your search or filter.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var subtitleText: String {
        let total = filteredFiles.count
        if manager.rejectedCount > 0 {
            return "\(total) files · \(manager.rejectedCount) rejected"
        }
        return "\(total) files"
    }
}

// MARK: - Filter pill

struct FilterPill: View {
    let mode: RAWFileGridView.FilterMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.rawValue)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
