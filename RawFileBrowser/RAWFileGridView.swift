import SwiftUI

struct RAWFileGridView: View {
    @ObservedObject var manager: SDCardManager
    @State private var selectedFile: RAWFile?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var filterMode: FilterMode = .all
    @State private var showAnalysisConfirm = false
    @State private var xmpResultMessage: String? = nil

    /// When non-nil, the stack detail view is shown instead of the top-level grid.
    @State private var activeStack: BurstStack? = nil

    /// The ID to scroll to when returning from a stack. Set just before
    /// activeStack is cleared, then consumed by the ScrollViewReader.
    @State private var scrollToID: UUID? = nil

    enum SortOrder: String, CaseIterable {
        case name = "Name"; case date = "Date"; case size = "Size"
        case sharpness = "Sharpness"
    }

    enum FilterMode: String, CaseIterable {
        case all        = "All"
        case bursts     = "Bursts"
        case accepted   = "Accepted"
        case rejected   = "Rejected"
        case sharp      = "Sharp"
        case unanalyzed = "Unanalyzed"
    }

    // MARK: - Pill counts

    private var burstPhotoCount: Int {
        manager.gridItems.reduce(0) { total, item in
            if case .stack(let s) = item { return total + s.count }
            return total
        }
    }

    private func pillCount(for mode: FilterMode) -> Int {
        switch mode {
        case .all:        return manager.rawFiles.count
        case .bursts:     return burstPhotoCount
        case .accepted:   return manager.rawFiles.filter { $0.pickStatus == .accepted }.count
        case .rejected:   return manager.rawFiles.filter { $0.pickStatus == .rejected }.count
        case .sharp:      return manager.rawFiles.filter { $0.focusStatus == .sharp }.count
        case .unanalyzed: return manager.rawFiles.filter { $0.focusStatus == .unanalyzed }.count
        }
    }

    private var visibleFilterModes: [FilterMode] {
        FilterMode.allCases.filter { mode in
            switch mode {
            case .all:    return true
            case .bursts: return burstPhotoCount > 0
            default:      return pillCount(for: mode) > 0
            }
        }
    }

    // MARK: - Top-level grid items

    private var filteredGridItems: [GridItem] {
        let items: [GridItem]

        if filterMode == .all && searchText.isEmpty {
            items = manager.gridItems

        } else if filterMode == .bursts && searchText.isEmpty {
            items = manager.gridItems.filter {
                if case .stack = $0 { return true }
                return false
            }

        } else {
            items = manager.gridItems.compactMap { item -> GridItem? in
                switch item {
                case .single(let file):
                    if filterMode == .bursts { return nil }
                    guard matchesFilter(file) && matchesSearch(file) else { return nil }
                    return .single(file)

                case .stack(let stack):
                    if filterMode == .bursts {
                        if searchText.isEmpty { return item }
                        let matching = stack.files.filter { matchesSearch($0) }
                        if matching.isEmpty { return nil }
                        if matching.count == 1 { return .single(matching[0]) }
                        return .stack(BurstStack(files: matching))
                    } else {
                        let matching = stack.files.filter { matchesFilter($0) && matchesSearch($0) }
                        if matching.isEmpty { return nil }
                        if matching.count == 1 { return .single(matching[0]) }
                        return .stack(BurstStack(files: matching))
                    }
                }
            }
        }

        return items.sorted {
            let lhs = leadingFile($0)
            let rhs = leadingFile($1)
            switch sortOrder {
            case .name:
                return lhs.name < rhs.name
            case .date:
                let d0 = lhs.modificationDate ?? .distantPast
                let d1 = rhs.modificationDate ?? .distantPast
                return d0 > d1
            case .size:
                return lhs.size > rhs.size
            case .sharpness:
                return lhs.focusScore > rhs.focusScore
            }
        }
    }

    private func matchesFilter(_ file: RAWFile) -> Bool {
        switch filterMode {
        case .all, .bursts: return true
        case .accepted:     return file.pickStatus == .accepted
        case .rejected:     return file.pickStatus == .rejected
        case .sharp:        return file.focusStatus == .sharp
        case .unanalyzed:   return file.focusStatus == .unanalyzed
        }
    }

    private func matchesSearch(_ file: RAWFile) -> Bool {
        searchText.isEmpty || file.name.localizedCaseInsensitiveContains(searchText)
    }

    private func leadingFile(_ item: GridItem) -> RAWFile {
        switch item {
        case .single(let f): return f
        case .stack(let s):  return s.coverFile
        }
    }

    private var columns: [SwiftUI.GridItem] {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let count  = isIPad ? 3 : 2
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: - Body
    //
    // Both the top-level grid and the stack detail view stay in the view
    // hierarchy at all times. Visibility is toggled with opacity and
    // allowsHitTesting rather than swapping views in/out.
    //
    // This is the key fix for scroll position restoration: LazyVGrid is
    // never torn down, so its items always exist when scrollTo is called.

    var body: some View {
        ZStack {
            // ── Top-level grid (always in hierarchy) ──────────────────
            topLevelGrid
                .opacity(activeStack == nil ? 1 : 0)
                .allowsHitTesting(activeStack == nil)

            // ── Stack detail view (only constructed when needed) ──────
            if let stack = activeStack {
                BurstDetailGridView(
                    stack: stack,
                    manager: manager,
                    activeStack: $activeStack,
                    onDismiss: {
                        scrollToID = stack.id
                    }
                )
                .transition(.identity)  // no animation — instant swap
            }
        }
    }

    // MARK: - Top-level grid

    private var topLevelGrid: some View {
        VStack(spacing: 0) {
            if manager.isAnalyzing {
                analysisBanner
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleFilterModes, id: \.self) { mode in
                        FilterPill(
                            mode: mode,
                            count: pillCount(for: mode),
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

            if filteredGridItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredGridItems) { item in
                                gridCell(for: item)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemGray6))
                    // Fires when scrollToID is set after returning from a stack.
                    // Because LazyVGrid is never torn down, its items already
                    // exist and scrollTo finds them immediately.
                    .onChange(of: scrollToID) { targetID in
                        guard let id = targetID else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        scrollToID = nil
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search files")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                BrowseSDCardButton(manager: manager).labelStyle(.iconOnly)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !manager.isAnalyzing {
                    Button {
                        showAnalysisConfirm = true
                    } label: {
                        Label("Analyze Focus", systemImage: "viewfinder.circle")
                    }
                }

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
        .sheet(item: $selectedFile) { file in
            RAWFileDetailView(fileID: file.id, manager: manager)
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

    // MARK: - Grid cell builder

    @ViewBuilder
    private func gridCell(for item: GridItem) -> some View {
        switch item {
        case .single(let file):
            RAWFileThumbnailCard(file: file, manager: manager)
                .onTapGesture { selectedFile = file }
                .id("\(file.id)-\(file.focusStatus.rawValue)-\(file.pickStatus.rawValue)")

        case .stack(let stack):
            BurstStackCard(stack: stack, manager: manager, visibleCount: stack.files.count)
                .onTapGesture { activeStack = stack }
                .id(stack.id)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filterMode == .rejected ? "flag.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(filterMode == .rejected   ? "No rejected files"
                 : filterMode == .accepted ? "No accepted files"
                 : filterMode == .bursts   ? "No bursts found"
                 : "No files match")
                .font(.title2.weight(.semibold))
            Text(filterMode == .rejected
                 ? "No photos have been rejected yet."
                 : filterMode == .accepted
                 ? "No photos have been accepted yet."
                 : filterMode == .bursts
                 ? "No burst sequences were detected in this folder."
                 : "Try adjusting your search or filter.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Filter pill

struct FilterPill: View {
    let mode: RAWFileGridView.FilterMode
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(mode.rawValue) \(count)")
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
