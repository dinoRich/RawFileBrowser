import SwiftUI

struct RAWFileGridView: View {
    @ObservedObject var manager: SDCardManager
    @State private var selectedFile: RAWFile?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var filterMode: FilterMode = .all
    @State private var showAnalysisConfirm = false
    @State private var showResetConfirm = false
    @State private var xmpResultMessage: String? = nil

    /// When non-nil, the stack detail view is shown instead of the top-level grid.
    @State private var activeStack: BurstStack? = nil

    /// The ID to scroll to when returning from a stack. Set just before
    /// activeStack is cleared, then consumed by the ScrollViewReader.
    @State private var scrollToID: UUID? = nil

    // ── Selection mode ───────────────────────────────────────────────────
    /// true = the grid is in multi-select mode
    @State private var isSelectMode: Bool = false
    /// IDs of selected grid items (file IDs for singles, stack IDs for stacks)
    @State private var selectedItemIDs: Set<UUID> = []
    /// Show the multi-selection label sheet when the user long-presses a selected card
    @State private var showMultiLabelSheet: Bool = false

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

    // MARK: - Navigation helpers

    /// Flat ordered list of every file ID in the current filtered grid,
    /// with stacks expanded. Passed to detail view so the user can swipe
    /// through all photos in grid order.
    private var flatFileIDs: [UUID] {
        filteredGridItems.flatMap { item -> [UUID] in
            switch item {
            case .single(let f): return [f.id]
            case .stack(let s):  return s.files.map { $0.id }
            }
        }
    }

    /// Returns the BurstStack containing `fileID`, or nil if it is a standalone single.
    private func stackContaining(fileID: UUID) -> BurstStack? {
        for item in filteredGridItems {
            if case .stack(let s) = item, s.files.contains(where: { $0.id == fileID }) {
                return s
            }
        }
        return nil
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

            // ── Selection mode count bar ─────────────────────────────────
            if isSelectMode {
                HStack {
                    Text(selectedItemIDs.isEmpty
                         ? "Tap photos to select"
                         : "\(selectedItemIDs.count) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                Divider()
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

                // 1 ── Analyze Focus / Cancel
                if !isSelectMode {
                    Button {
                        if manager.isAnalyzing {
                            manager.cancelAnalysis()
                        } else {
                            showAnalysisConfirm = true
                        }
                    } label: {
                        Label(
                            manager.isAnalyzing ? "Cancel Analysis" : "Analyze Focus",
                            systemImage: manager.isAnalyzing ? "xmark.circle" : "circle.dashed"
                        )
                    }
                }

                // 2 ── Reset flags / stars / colours ─────────────────────
                if !isSelectMode {
                    Button {
                        showResetConfirm = true
                    } label: {
                        Label("Reset All Labels", systemImage: "arrow.counterclockwise.circle")
                    }
                }

                // 3 ── Select / Done ──────────────────────────────────────
                Button {
                    if isSelectMode {
                        isSelectMode = false
                        selectedItemIDs = []
                    } else {
                        isSelectMode = true
                    }
                } label: {
                    Image(systemName: isSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
                }

                // 4 ── Save XMP (floppy disk) ─────────────────────────────
                if !isSelectMode {
                    Button {
                        let msg = manager.writeXMPBatch()
                        xmpResultMessage = msg
                    } label: {
                        Label("Save XMP", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .sheet(item: $selectedFile) { file in
            let ids = flatFileIDs
            let idx = ids.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(
                fileIDs:    ids,
                startIndex: idx,
                manager:    manager,
                onDismiss: { lastViewedID in
                    if let stack = stackContaining(fileID: lastViewedID) {
                        activeStack = stack
                        scrollToID  = stack.id
                    } else {
                        scrollToID = lastViewedID
                    }
                }
            )
        }
        // Multi-selection label sheet — shown when user long-presses any selected card
        .sheet(isPresented: $showMultiLabelSheet) {
            let liveSelected: [RAWFile] = {
                let ids = selectedItemIDs
                // Collect the actual RAWFile objects for every selected item.
                // For stacks, include all files in the stack.
                var files: [RAWFile] = []
                for item in filteredGridItems {
                    guard ids.contains(item.id) else { continue }
                    switch item {
                    case .single(let f):
                        if let live = manager.rawFiles.first(where: { $0.id == f.id }) {
                            files.append(live)
                        }
                    case .stack(let s):
                        for f in s.files {
                            if let live = manager.rawFiles.first(where: { $0.id == f.id }) {
                                files.append(live)
                            }
                        }
                    }
                }
                return files
            }()
            MultiSelectionLabelPickerSheet(selectedFiles: liveSelected, manager: manager)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
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
        .confirmationDialog(
            "Reset all flags, stars and colours?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) {
                manager.resetAllLabels()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear every flag, star rating and colour label on all \(manager.rawFiles.count) photos. This cannot be undone.")
        }
    }

    // MARK: - Grid cell builder

    @ViewBuilder
    private func gridCell(for item: GridItem) -> some View {
        switch item {
        case .single(let file):
            RAWFileThumbnailCard(
                file: file,
                manager: manager,
                isSelectMode: isSelectMode,
                isSelected: selectedItemIDs.contains(file.id),
                onToggleSelect: { toggleSelection(of: item) }
            )
            .onTapGesture {
                if isSelectMode {
                    toggleSelection(of: item)
                } else {
                    selectedFile = file
                }
            }
            .onLongPressGesture {
                if isSelectMode {
                    // If this card isn't already selected, select it too
                    if !selectedItemIDs.contains(file.id) {
                        selectedItemIDs.insert(file.id)
                    }
                    showMultiLabelSheet = true
                }
                // (If NOT in select mode, the card itself handles the long-press)
            }
            .id("\(file.id)-\(file.focusStatus.rawValue)-\(file.pickStatus.rawValue)")

        case .stack(let stack):
            BurstStackCard(
                stack: stack,
                manager: manager,
                visibleCount: stack.files.count,
                isSelectMode: isSelectMode,
                isSelected: selectedItemIDs.contains(stack.id),
                onToggleSelect: { toggleSelection(of: item) }
            )
            .onTapGesture {
                if isSelectMode {
                    toggleSelection(of: item)
                } else {
                    activeStack = stack
                }
            }
            .onLongPressGesture {
                if isSelectMode {
                    if !selectedItemIDs.contains(stack.id) {
                        selectedItemIDs.insert(stack.id)
                    }
                    showMultiLabelSheet = true
                }
                // (If NOT in select mode, the card itself handles the long-press)
            }
            .id(stack.id)
        }
    }

    // MARK: - Selection helpers

    private func toggleSelection(of item: GridItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    // MARK: - Subviews

    private var analysisBanner: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "circle.dashed")
                Text("Analyzing focus…")
                Spacer()
                Text("\(Int(manager.analysisProgress * 100))%")
                    .monospacedDigit()
                Button {
                    manager.cancelAnalysis()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
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
