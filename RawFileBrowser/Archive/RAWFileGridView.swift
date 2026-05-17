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

    /// When non-nil, the similar group detail view is shown.
    @State private var activeSimilarGroup: SimilarGroup? = nil

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
        case all          = "All"
        case bursts       = "Bursts"
        case similar      = "Similar"
        case accepted     = "Accepted"
        case rejected     = "Rejected"
        case sharp        = "Sharp"
        case slightlyBlur = "Slightly Blurry"
        case blurry       = "Blurry"
        case unanalyzed   = "Unanalyzed"
        case star1        = "★ 1"
        case star2        = "★★ 2"
        case star3        = "★★★ 3"
        case star4        = "★★★★ 4"
        case star5        = "★★★★★ 5"
        case colourRed    = "Red"
        case colourYellow = "Yellow"
        case colourGreen  = "Green"
        case colourBlue   = "Blue"
        case colourPurple = "Purple"
    }

    // MARK: - Pill counts

    /// Number of burst stacks (used for Bursts pill label).
    private var burstStackCount: Int {
        manager.gridItems.filter { if case .stack = $0 { return true }; return false }.count
    }

    /// Total photos inside burst stacks (shown on the Bursts pill).
    private var burstPhotoCount: Int {
        manager.gridItems.reduce(0) { total, item in
            if case .stack(let s) = item { return total + s.count }
            return total
        }
    }

    private func pillCount(for mode: FilterMode) -> Int {
        switch mode {
        case .all:          return manager.rawFiles.count
        case .bursts:       return burstPhotoCount          // total photos in bursts
        case .similar:      return manager.similarPhotoCount
        case .accepted:     return manager.rawFiles.filter { $0.pickStatus == .accepted }.count
        case .rejected:     return manager.rawFiles.filter { $0.pickStatus == .rejected }.count
        case .sharp:        return manager.rawFiles.filter { $0.focusStatus == .sharp }.count
        case .slightlyBlur: return manager.rawFiles.filter { $0.focusStatus == .slightlyBlur }.count
        case .blurry:       return manager.rawFiles.filter { $0.focusStatus == .blurry }.count
        case .unanalyzed:   return manager.rawFiles.filter { $0.focusStatus == .unanalyzed }.count
        case .star1:        return manager.rawFiles.filter { $0.starRating == 1 }.count
        case .star2:        return manager.rawFiles.filter { $0.starRating == 2 }.count
        case .star3:        return manager.rawFiles.filter { $0.starRating == 3 }.count
        case .star4:        return manager.rawFiles.filter { $0.starRating == 4 }.count
        case .star5:        return manager.rawFiles.filter { $0.starRating == 5 }.count
        case .colourRed:    return manager.rawFiles.filter { $0.labelColour == .red }.count
        case .colourYellow: return manager.rawFiles.filter { $0.labelColour == .yellow }.count
        case .colourGreen:  return manager.rawFiles.filter { $0.labelColour == .green }.count
        case .colourBlue:   return manager.rawFiles.filter { $0.labelColour == .blue }.count
        case .colourPurple: return manager.rawFiles.filter { $0.labelColour == .purple }.count
        }
    }

    private var visibleFilterModes: [FilterMode] {
        FilterMode.allCases.filter { mode in
            switch mode {
            case .all:     return true
            case .bursts:  return burstStackCount > 0
            case .similar: return manager.similarPhotoCount > 0 || manager.isComputingSimilar
            default:       return pillCount(for: mode) > 0
            }
        }
    }

    // MARK: - Top-level grid items
    //
    // "All"     → flat list of every individual photo (no stacks).
    // "Bursts"  → burst stacks only (same as before).
    // "Similar" → handled separately: shows similar groups, not GridItems.
    // All other filters → filter individual files, expanding stacks as needed.

    private var filteredGridItems: [GridItem] {
        let items: [GridItem]

        switch filterMode {

        // ── All: every photo as a flat single — no stacks ────────────────────
        case .all:
            let files: [RAWFile]
            if searchText.isEmpty {
                files = manager.rawFiles
            } else {
                files = manager.rawFiles.filter { matchesSearch($0) }
            }
            items = files.map { .single($0) }

        // ── Bursts: stacks only, with optional search ────────────────────────
        case .bursts:
            let stacks = manager.gridItems.filter {
                if case .stack = $0 { return true }
                return false
            }
            if searchText.isEmpty {
                items = stacks
            } else {
                items = stacks.compactMap { item -> GridItem? in
                    guard case .stack(let s) = item else { return nil }
                    let matching = s.files.filter { matchesSearch($0) }
                    if matching.isEmpty { return nil }
                    if matching.count == 1 { return .single(matching[0]) }
                    return .stack(BurstStack(files: matching))
                }
            }

        // ── Similar: this mode is rendered by a separate view (see body) ─────
        case .similar:
            items = []

        // ── All other filters: expand stacks, filter individual files ────────
        default:
            items = manager.gridItems.compactMap { item -> GridItem? in
                switch item {
                case .single(let file):
                    guard matchesFilter(file) && matchesSearch(file) else { return nil }
                    return .single(file)
                case .stack(let stack):
                    let matching = stack.files.filter { matchesFilter($0) && matchesSearch($0) }
                    if matching.isEmpty { return nil }
                    if matching.count == 1 { return .single(matching[0]) }
                    return .stack(BurstStack(files: matching))
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

    // MARK: - Similar groups filtered by search

    private var filteredSimilarGroups: [SimilarGroup] {
        guard searchText.isEmpty else {
            return manager.similarGroups.compactMap { group in
                let matching = group.files.filter { matchesSearch($0) }
                guard matching.count >= 2 else { return nil }
                return SimilarGroup(files: matching)
            }
        }
        return manager.similarGroups
    }

    private func matchesFilter(_ file: RAWFile) -> Bool {
        switch filterMode {
        case .all, .bursts, .similar: return true
        case .accepted:     return file.pickStatus == .accepted
        case .rejected:     return file.pickStatus == .rejected
        case .sharp:        return file.focusStatus == .sharp
        case .slightlyBlur: return file.focusStatus == .slightlyBlur
        case .blurry:       return file.focusStatus == .blurry
        case .unanalyzed:   return file.focusStatus == .unanalyzed
        case .star1:        return file.starRating == 1
        case .star2:        return file.starRating == 2
        case .star3:        return file.starRating == 3
        case .star4:        return file.starRating == 4
        case .star5:        return file.starRating == 5
        case .colourRed:    return file.labelColour == .red
        case .colourYellow: return file.labelColour == .yellow
        case .colourGreen:  return file.labelColour == .green
        case .colourBlue:   return file.labelColour == .blue
        case .colourPurple: return file.labelColour == .purple
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
        if filterMode == .similar {
            return filteredSimilarGroups.flatMap { $0.files.map { $0.id } }
        }
        return filteredGridItems.flatMap { item -> [UUID] in
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
    // All three views (top-level grid, burst detail, similar group detail) stay in
    // the hierarchy at all times. Visibility is toggled with opacity and
    // allowsHitTesting rather than swapping views in/out.
    // This preserves scroll position when returning from a child view.

    var body: some View {
        ZStack {
            // ── Top-level grid (always in hierarchy) ──────────────────
            topLevelGrid
                .opacity(activeStack == nil && activeSimilarGroup == nil ? 1 : 0)
                .allowsHitTesting(activeStack == nil && activeSimilarGroup == nil)

            // ── Burst stack detail view ────────────────────────────────
            if let stack = activeStack {
                BurstDetailGridView(
                    stack: stack,
                    manager: manager,
                    activeStack: $activeStack,
                    onDismiss: {
                        scrollToID = stack.id
                    }
                )
                .transition(.identity)
            }

            // ── Similar group detail view ──────────────────────────────
            if let group = activeSimilarGroup {
                SimilarGroupDetailView(
                    group: group,
                    manager: manager,
                    onDismiss: {
                        activeSimilarGroup = nil
                        scrollToID = group.id
                    }
                )
                .transition(.identity)
            }
        }
    }

    // MARK: - Top-level grid

    private var topLevelGrid: some View {
        VStack(spacing: 0) {
            if manager.isAnalyzing {
                analysisBanner
            }

            if manager.isComputingSimilar {
                similarBanner
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

            // ── Main content area ────────────────────────────────────────
            if filterMode == .similar {
                similarContent
            } else if filteredGridItems.isEmpty {
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

                // 2 ── Find Similar (only when not in select mode)
                if !isSelectMode {
                    Button {
                        Task { await manager.computeSimilarGroups() }
                    } label: {
                        Label("Find Similar", systemImage: "square.on.square.dashed")
                    }
                    .disabled(manager.isComputingSimilar || manager.rawFiles.isEmpty)
                }

                // 3 ── Reset flags / stars / colours
                if !isSelectMode {
                    Button {
                        showResetConfirm = true
                    } label: {
                        Label("Reset All Labels", systemImage: "arrow.counterclockwise.circle")
                    }
                }

                // 4 ── Select All / Deselect All (only in select mode)
                if isSelectMode {
                    let allIDs = Set(filteredGridItems.map { $0.id })
                    let allSelected = allIDs == selectedItemIDs
                    Button {
                        if allSelected {
                            selectedItemIDs = []
                        } else {
                            selectedItemIDs = allIDs
                        }
                    } label: {
                        Text("All")
                    }
                }

                // 5 ── Enter / Exit select mode
                Button {
                    if isSelectMode {
                        isSelectMode = false
                        selectedItemIDs = []
                    } else {
                        isSelectMode = true
                    }
                } label: {
                    Text(isSelectMode ? "Done" : "Select")
                        .font(.body)
                }

                // 6 ── Save XMP
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
        // Multi-selection label sheet
        .sheet(isPresented: $showMultiLabelSheet) {
            let liveSelected: [RAWFile] = {
                let ids = selectedItemIDs
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

    // MARK: - Similar content view
    //
    // Shown when filterMode == .similar.
    // Displays similar groups as stacked cards. Tapping a group opens
    // SimilarGroupDetailView showing all photos in that group flat.

    @ViewBuilder
    private var similarContent: some View {
        if manager.isComputingSimilar {
            // Already shown in banner — show placeholder
            Spacer()
        } else if filteredSimilarGroups.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("No similar photos found")
                    .font(.title2.weight(.semibold))
                Text("Tap the \(Image(systemName: "square.on.square.dashed")) button in the toolbar to scan for near-duplicates.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredSimilarGroups) { group in
                            // Reuse BurstStackCard visual — a similar group is displayed
                            // identically to a burst stack (stacked card, count badge).
                            // We wrap the group in a temporary BurstStack for the card.
                            let stack = BurstStack(files: group.files)
                            BurstStackCard(
                                stack: stack,
                                manager: manager,
                                visibleCount: group.count
                            )
                            .onTapGesture {
                                activeSimilarGroup = group
                            }
                            .id(group.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
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
                    if !selectedItemIDs.contains(file.id) {
                        selectedItemIDs.insert(file.id)
                    }
                    showMultiLabelSheet = true
                }
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

    private var similarBanner: some View {
        HStack {
            ProgressView()
                .padding(.trailing, 4)
            Text("Finding similar photos…")
                .font(.subheadline.weight(.medium))
            Spacer()
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

// MARK: - SimilarGroupDetailView
//
// Shows all photos in a single similar group as a flat grid.
// Identical in structure to BurstDetailGridView, but driven by a SimilarGroup.

struct SimilarGroupDetailView: View {
    let group: SimilarGroup
    @ObservedObject var manager: SDCardManager
    let onDismiss: () -> Void

    @State private var selectedFile: RAWFile?

    private var columns: [SwiftUI.GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12), count: count)
    }

    /// Live copies of the files from manager.rawFiles so badge updates are reflected.
    private var liveFiles: [RAWFile] {
        let ids = Set(group.files.map { $0.id })
        let live = manager.rawFiles.filter { ids.contains($0.id) }
        return live.isEmpty ? group.files : live
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Back / header bar ────────────────────────────────────────
            HStack {
                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Similar")
                    }
                    .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text("\(group.count) similar photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(liveFiles) { file in
                        RAWFileThumbnailCard(
                            file: file,
                            manager: manager,
                            isSelectMode: false,
                            isSelected: false,
                            onToggleSelect: {}
                        )
                        .onTapGesture {
                            selectedFile = file
                        }
                        .id(file.id)
                    }
                }
                .padding()
            }
            .background(Color(.systemGray6))
        }
        .sheet(item: $selectedFile) { file in
            let ids = liveFiles.map { $0.id }
            let idx = ids.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(
                fileIDs:    ids,
                startIndex: idx,
                manager:    manager,
                onDismiss:  { _ in }
            )
        }
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
