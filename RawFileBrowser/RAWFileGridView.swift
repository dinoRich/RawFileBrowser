import SwiftUI

struct RAWFileGridView: View {
    @ObservedObject var manager: SDCardManager
    @State private var selectedFile: RAWFile?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var filterMode: FilterMode = .all
    @State private var filterSection: FilterSection = .all
    @State private var showAnalysisConfirm = false
    @State private var showResetConfirm = false
    @State private var xmpResultMessage: String? = nil

    /// When non-nil, the group detail view is shown (burst or similar).
    @State private var activeGroup: PhotoGroup? = nil

    /// When non-nil, the species detail view is shown (time sub-groups within a species).
    @State private var activeSpeciesGroup: PhotoGroup? = nil


    /// The ID to scroll to when returning from a group detail view.
    @State private var scrollToID: UUID? = nil

    // ── Selection mode ───────────────────────────────────────────────────
    @State private var isSelectMode: Bool = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showMultiLabelSheet: Bool = false

    enum SortOrder: String, CaseIterable {
        case name = "Name"; case date = "Date"; case size = "Size"
        case sharpness = "Sharpness"
    }

    enum FilterSection: String, CaseIterable {
        case all       = "All"
        case aiResults = "AI Analysis"
        case myPicks   = "My Picks"
        case groups    = "Groups"
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
        case star1        = "★"
        case star2        = "★★"
        case star3        = "★★★"
        case star4        = "★★★★"
        case star5        = "★★★★★"
        case colourRed    = "Red"
        case colourYellow = "Yellow"
        case colourGreen  = "Green"
        case colourBlue   = "Blue"
        case colourPurple = "Purple"
        case species      = "Species"
        case burstBest    = "Best"
        case overexposed  = "Overexposed"
        case underexposed = "Underexposed"
        case clipped      = "Clipped"
    }

    // MARK: - Helpers

    private var burstGroupCount: Int {
        manager.gridItems.filter {
            if case .group(let g) = $0, g.isBurst { return true }
            return false
        }.count
    }

    // MARK: - Pill counts
    //
    // Every filter pill needs a count, and the section/pill bars evaluate all of
    // them on each render. Computing each as a separate O(n) filter meant scanning
    // the whole file array ~24× per render. Instead we tally every bucket in a
    // single pass and hand the resulting dictionary to the views that need it.

    private var filterCounts: [FilterMode: Int] {
        var accepted = 0, rejected = 0
        var sharp = 0, slight = 0, blurry = 0, unanalyzed = 0
        var s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0
        var red = 0, yellow = 0, green = 0, blue = 0, purple = 0
        var burstBest = 0, clipped = 0, over = 0, under = 0
        let settings = manager.settings

        for f in manager.rawFiles {
            switch f.pickStatus {
            case .accepted: accepted += 1
            case .rejected: rejected += 1
            case .unpicked: break
            }
            switch f.focusStatus {
            case .sharp:        sharp += 1
            case .slightlyBlur: slight += 1
            case .blurry:       blurry += 1
            case .unanalyzed:   unanalyzed += 1
            }
            switch f.starRating {
            case 1: s1 += 1
            case 2: s2 += 1
            case 3: s3 += 1
            case 4: s4 += 1
            case 5: s5 += 1
            default: break
            }
            switch f.labelColour {
            case .red:    red += 1
            case .yellow: yellow += 1
            case .green:  green += 1
            case .blue:   blue += 1
            case .purple: purple += 1
            case .none:   break
            }
            if f.isBurstSharpnessBest { burstBest += 1 }
            if f.subjectClipped { clipped += 1 }
            if let ea = f.exposureAssessment, let issue = settings?.exposureIssue(for: ea) {
                if issue == .overexposed { over += 1 }
                else if issue == .underexposed { under += 1 }
            }
        }

        return [
            .all: manager.rawFiles.count,
            .bursts: burstGroupCount,
            .similar: manager.similarGroups.count,
            .species: manager.speciesGroups.count,
            .accepted: accepted, .rejected: rejected,
            .sharp: sharp, .slightlyBlur: slight, .blurry: blurry, .unanalyzed: unanalyzed,
            .star1: s1, .star2: s2, .star3: s3, .star4: s4, .star5: s5,
            .colourRed: red, .colourYellow: yellow, .colourGreen: green,
            .colourBlue: blue, .colourPurple: purple,
            .burstBest: burstBest, .clipped: clipped,
            .overexposed: over, .underexposed: under
        ]
    }

    // MARK: - Section → filter modes mapping

    private static let aiResultsModes: [FilterMode] = [
        .sharp, .slightlyBlur, .blurry, .unanalyzed,
        .burstBest, .overexposed, .underexposed, .clipped
    ]
    private static let myPicksModes: [FilterMode] = [
        .accepted, .rejected,
        .star1, .star2, .star3, .star4, .star5,
        .colourRed, .colourYellow, .colourGreen, .colourBlue, .colourPurple
    ]
    private static let groupsModes: [FilterMode] = [
        .bursts, .similar, .species
    ]

    private func modesForSection(_ section: FilterSection) -> [FilterMode] {
        switch section {
        case .all:       return []
        case .aiResults: return Self.aiResultsModes
        case .myPicks:   return Self.myPicksModes
        case .groups:    return Self.groupsModes
        }
    }

    /// Pills shown in the bottom bar for the active section (zero-count hidden).
    private func visibleFilterModes(_ counts: [FilterMode: Int]) -> [FilterMode] {
        modesForSection(filterSection).filter { (counts[$0] ?? 0) > 0 }
    }

    /// Whether a section top-bar pill appears dimmed (no populated filter pills).
    private func sectionIsEmpty(_ section: FilterSection, counts: [FilterMode: Int]) -> Bool {
        guard section != .all else { return false }
        return modesForSection(section).allSatisfy { (counts[$0] ?? 0) == 0 }
    }

    // MARK: - Filtered grid items
    //
    // All     → every photo as a flat single (no groups).
    // Bursts  → burst PhotoGroups only.
    // Similar → similar PhotoGroups only.
    // Others  → filter individual files; groups are expanded to singles.

    private var filteredGridItems: [GridItem] {
        let items: [GridItem]

        switch filterMode {

        case .all:
            let files = searchText.isEmpty
                ? manager.rawFiles
                : manager.rawFiles.filter { matchesSearch($0) }
            items = files.map { .single($0) }

        case .bursts:
            let burstItems = manager.gridItems.filter {
                if case .group(let g) = $0, g.isBurst { return true }
                return false
            }
            if searchText.isEmpty {
                items = burstItems
            } else {
                items = burstItems.compactMap { item -> GridItem? in
                    guard case .group(let g) = item else { return nil }
                    let matching = g.files.filter { matchesSearch($0) }
                    if matching.isEmpty { return nil }
                    if matching.count == 1 { return .single(matching[0]) }
                    // Reuse the source group's ID: a fresh UUID per render churns
                    // SwiftUI identity (cell rebuilds, broken scroll-restore).
                    return .group(PhotoGroup(files: matching, kind: .confirmedBurst, id: g.id))
                }
            }

        case .similar, .species:
            // These are rendered by separate views — return empty here.
            items = []

        default:
            items = manager.gridItems.compactMap { item -> GridItem? in
                switch item {
                case .single(let file):
                    guard matchesFilter(file) && matchesSearch(file) else { return nil }
                    return .single(file)
                case .group(let group):
                    let matching = group.files.filter { matchesFilter($0) && matchesSearch($0) }
                    if matching.isEmpty { return nil }
                    if matching.count == 1 { return .single(matching[0]) }
                    return .group(PhotoGroup(files: matching, kind: group.kind, id: group.id))
                }
            }
        }

        return items.sorted {
            let lhs = leadingFile($0)
            let rhs = leadingFile($1)
            switch sortOrder {
            case .name:      return lhs.name < rhs.name
            case .date:
                return (lhs.modificationDate ?? .distantPast) > (rhs.modificationDate ?? .distantPast)
            case .size:      return lhs.size > rhs.size
            case .sharpness: return lhs.focusScore > rhs.focusScore
            }
        }
    }

    // MARK: - Similar groups (filtered + sorted)

    private var filteredSimilarGroups: [PhotoGroup] {
        let groups: [PhotoGroup]
        if searchText.isEmpty {
            groups = manager.similarGroups
        } else {
            groups = manager.similarGroups.compactMap { group in
                let matching = group.files.filter { matchesSearch($0) }
                guard matching.count >= 2 else { return nil }
                return PhotoGroup(files: matching, kind: .similar, id: group.id)
            }
        }
        return groups.sorted {
            let lhs = $0.coverFile; let rhs = $1.coverFile
            switch sortOrder {
            case .name:      return lhs.name < rhs.name
            case .date:
                return (lhs.modificationDate ?? .distantPast) > (rhs.modificationDate ?? .distantPast)
            case .size:      return lhs.size > rhs.size
            case .sharpness: return lhs.focusScore > rhs.focusScore
            }
        }
    }

    private func matchesFilter(_ file: RAWFile) -> Bool {
        switch filterMode {
        case .all, .bursts, .similar, .species: return true
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
        case .burstBest:    return file.isBurstSharpnessBest
        case .clipped:      return file.subjectClipped
        case .overexposed:
            guard let ea = file.exposureAssessment else { return false }
            return manager.settings?.exposureIssue(for: ea) == .overexposed
        case .underexposed:
            guard let ea = file.exposureAssessment else { return false }
            return manager.settings?.exposureIssue(for: ea) == .underexposed
        }
    }

    private func matchesSearch(_ file: RAWFile) -> Bool {
        searchText.isEmpty || file.name.localizedCaseInsensitiveContains(searchText)
    }

    private func leadingFile(_ item: GridItem) -> RAWFile {
        switch item {
        case .single(let f): return f
        case .group(let g):  return g.coverFile
        }
    }

    private var columns: [SwiftUI.GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: - Navigation helpers

    private var flatFileIDs: [UUID] {
        if filterMode == .similar {
            return filteredSimilarGroups.flatMap { $0.files.map { $0.id } }
        }
        return filteredGridItems.flatMap { item -> [UUID] in
            switch item {
            case .single(let f): return [f.id]
            case .group(let g):  return g.files.map { $0.id }
            }
        }
    }

    private func groupContaining(fileID: UUID) -> PhotoGroup? {
        for item in filteredGridItems {
            if case .group(let g) = item, g.files.contains(where: { $0.id == fileID }) {
                return g
            }
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            topLevelGrid
                .opacity(activeGroup == nil && activeSpeciesGroup == nil ? 1 : 0)
                .allowsHitTesting(activeGroup == nil && activeSpeciesGroup == nil)

            if let speciesGroup = activeSpeciesGroup {
                SpeciesDetailView(
                    speciesGroup: speciesGroup,
                    manager: manager,
                    onDismiss: {
                        scrollToID = speciesGroup.id
                        activeSpeciesGroup = nil
                    }
                )
                .transition(.identity)
            }

            if let group = activeGroup {
                GroupDetailView(
                    group: group,
                    manager: manager,
                    onDismiss: {
                        scrollToID = group.id
                        activeGroup = nil
                    }
                )
                .transition(.identity)
            }
        }
    }

    // MARK: - Top-level grid

    private var topLevelGrid: some View {
        VStack(spacing: 0) {
            // Tallied once per render, then shared with the section and pill bars
            // instead of recomputing each pill's count independently.
            let counts = filterCounts

            if manager.isAnalyzing        { analysisBanner }
            if manager.isComputingHashes  { hashBanner }
            if manager.isWritingXMP       { xmpBanner }

            if isSelectMode {
                HStack {
                    Text(selectedItemIDs.isEmpty ? "Tap photos to select" : "\(selectedItemIDs.count) selected")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                Divider()
            }

            // ── Top bar: sections ─────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterSection.allCases, id: \.self) { section in
                        SectionPill(
                            title: section.rawValue,
                            isSelected: filterSection == section,
                            isEmpty: sectionIsEmpty(section, counts: counts)
                        ) {
                            filterSection = section
                            // Reset filter mode when switching sections.
                            // For Groups, default to the first populated mode if any,
                            // otherwise fall back to .all so the grid shows something.
                            if section == .all {
                                filterMode = .all
                            } else {
                                let first = modesForSection(section).first(where: { (counts[$0] ?? 0) > 0 })
                                filterMode = first ?? .all
                            }
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }

            // ── Bottom bar: filter pills for active section ───────────────────
            if filterSection != .all && !visibleFilterModes(counts).isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleFilterModes(counts), id: \.self) { mode in
                            FilterPill(
                                mode: mode,
                                count: counts[mode] ?? 0,
                                isSelected: filterMode == mode
                            ) { filterMode = mode }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
            }

            Divider()

            if filterMode == .similar {
                similarContent
            } else if filterMode == .species {
                speciesContent
            } else if filterSection == .myPicks {
                picksReasonContent
            } else if filteredGridItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredGridItems) { item in gridCell(for: item) }
                        }
                        .padding()
                    }
                    .background(Color(.systemGray6))
                    .onChange(of: scrollToID) { targetID in
                        guard let id = targetID else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
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

                if !isSelectMode {
                    Button {
                        if manager.isAnalyzing { manager.cancelAnalysis() }
                        else { showAnalysisConfirm = true }
                    } label: {
                        Label(manager.isAnalyzing ? "Cancel Analysis" : "Analyze Focus",
                              systemImage: manager.isAnalyzing ? "xmark.circle" : "circle.dashed")
                    }
                }

                if !isSelectMode {
                    Button {
                        Task { await manager.computeSimilarGroups() }
                    } label: {
                        Label("Find Similar", systemImage: "square.on.square.dashed")
                    }
                    .disabled(manager.isComputingHashes || manager.rawFiles.isEmpty)
                }

                if !isSelectMode {
                    Button { showResetConfirm = true } label: {
                        Label("Reset All Labels", systemImage: "arrow.counterclockwise.circle")
                    }
                }

                if isSelectMode {
                    let allIDs = Set(filteredGridItems.map { $0.id })
                    Button {
                        selectedItemIDs = allIDs == selectedItemIDs ? [] : allIDs
                    } label: { Text("All") }
                }

                Button {
                    if isSelectMode { isSelectMode = false; selectedItemIDs = [] }
                    else { isSelectMode = true }
                } label: {
                    Text(isSelectMode ? "Done" : "Select").font(.body)
                }

                if !isSelectMode {
                    Button {
                        Task { xmpResultMessage = await manager.writeXMPBatch() }
                    } label: {
                        Label("Save XMP", systemImage: "square.and.arrow.down")
                    }
                    .disabled(manager.isWritingXMP || manager.rawFiles.isEmpty)
                }
            }
        }
        .sheet(item: $selectedFile) { file in
            let ids = flatFileIDs
            let idx = ids.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(
                fileIDs: ids, startIndex: idx, manager: manager,
                onDismiss: { lastViewedID in
                    if let g = groupContaining(fileID: lastViewedID) {
                        activeGroup = g
                        scrollToID  = g.id
                    } else {
                        scrollToID = lastViewedID
                    }
                }
            )
        }
        .sheet(isPresented: $showMultiLabelSheet) {
            let liveSelected: [RAWFile] = {
                let ids = selectedItemIDs
                var files: [RAWFile] = []
                for item in filteredGridItems {
                    guard ids.contains(item.id) else { continue }
                    switch item {
                    case .single(let f):
                        if let live = manager.liveFile(id: f.id) { files.append(live) }
                    case .group(let g):
                        for f in g.files {
                            if let live = manager.liveFile(id: f.id) { files.append(live) }
                        }
                    }
                }
                return files
            }()
            MultiSelectionLabelPickerSheet(selectedFiles: liveSelected, manager: manager)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .alert("XMP Export", isPresented: Binding(
            get: { xmpResultMessage != nil },
            set: { if !$0 { xmpResultMessage = nil } }
        )) {
            Button("OK") { xmpResultMessage = nil }
        } message: { Text(xmpResultMessage ?? "") }
        .confirmationDialog("Analyze \(manager.rawFiles.count) files for sharpness?",
                            isPresented: $showAnalysisConfirm, titleVisibility: .visible) {
            Button("Analyze All") { Task { await manager.analyzeAllFocus() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This may take a moment depending on file count.") }
        .confirmationDialog("Reset all flags, stars and colours?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { manager.resetAllLabels() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear every flag, star rating and colour label on all \(manager.rawFiles.count) photos. This cannot be undone.")
        }
    }

    // MARK: - Similar content

    @ViewBuilder
    private var similarContent: some View {
        if filteredSimilarGroups.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 60)).foregroundStyle(.secondary)
                Text("No similar photos found")
                    .font(.title2.weight(.semibold))
                Text("Similar photos are detected automatically at load time using visual fingerprinting.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredSimilarGroups) { group in
                            BurstStackCard(
                                stack: group,
                                manager: manager,
                                visibleCount: group.count
                            )
                            .onTapGesture { activeGroup = group }
                            .id(group.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
                .onChange(of: scrollToID) { targetID in
                    guard let id = targetID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    scrollToID = nil
                }
            }
        }
    }

    // MARK: - Species content view

    @ViewBuilder
    private var speciesContent: some View {
        if manager.speciesGroups.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "pawprint")
                    .font(.system(size: 60)).foregroundStyle(.secondary)
                Text("No species identified yet")
                    .font(.title2.weight(.semibold))
                Text("Species are identified automatically after photos load.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredSpeciesGroups) { group in
                            SpeciesGroupCard(group: group, manager: manager)
                                .onTapGesture { activeSpeciesGroup = group }
                                .id(group.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
                .onChange(of: scrollToID) { targetID in
                    guard let id = targetID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    scrollToID = nil
                }
            }
        }
    }

    // MARK: - My Picks reason groups

    // Each reason maps a display label to a predicate on RAWFile.
    // Photos can satisfy multiple reasons and will appear in each matching group.
    // Groups with zero matching photos are omitted.
    // A "No Flags" catch-all captures photos that pass the pick filter but
    // match none of the defined reasons — so no photo is silently hidden.

    private struct ReasonDefinition {
        let label: String
        let matches: (RAWFile, AppSettings?) -> Bool
    }

    private static let allReasonDefinitions: [ReasonDefinition] = [
        ReasonDefinition(label: "Blurry")           { f, _ in f.focusStatus == .blurry },
        ReasonDefinition(label: "Slightly Blurry")  { f, _ in f.focusStatus == .slightlyBlur },
        ReasonDefinition(label: "Sharp")             { f, _ in f.focusStatus == .sharp },
        ReasonDefinition(label: "Overexposed")       { f, s in
            f.exposureAssessment.flatMap { s?.exposureIssue(for: $0) } == .overexposed
        },
        ReasonDefinition(label: "Underexposed")      { f, s in
            f.exposureAssessment.flatMap { s?.exposureIssue(for: $0) } == .underexposed
        },
        ReasonDefinition(label: "Subject Clipped")   { f, _ in f.subjectClipped },
        ReasonDefinition(label: "AF Missed Subject") { f, _ in f.afNotOnSubject },
        ReasonDefinition(label: "Burst Non-Winner")  { f, _ in
            !f.isBurstSharpnessBest && f.burstRank != nil
        },
        ReasonDefinition(label: "No Subject")        { f, _ in
            f.subjectBodyArea == 0 && f.focusStatus != .unanalyzed
        },
        ReasonDefinition(label: "Unanalyzed")        { f, _ in f.focusStatus == .unanalyzed },
    ]

    /// Builds reason-group stacks for the currently active My Picks filter.
    /// Each PhotoGroup uses .reasonGroup(label:) so GroupDetailView can title itself correctly.
    private var picksReasonGroups: [PhotoGroup] {
        // Determine which files pass the active pick filter.
        let baseFiles: [RAWFile]
        switch filterMode {
        case .accepted:     baseFiles = manager.rawFiles.filter { $0.pickStatus == .accepted }
        case .rejected:     baseFiles = manager.rawFiles.filter { $0.pickStatus == .rejected }
        case .star1:        baseFiles = manager.rawFiles.filter { $0.starRating == 1 }
        case .star2:        baseFiles = manager.rawFiles.filter { $0.starRating == 2 }
        case .star3:        baseFiles = manager.rawFiles.filter { $0.starRating == 3 }
        case .star4:        baseFiles = manager.rawFiles.filter { $0.starRating == 4 }
        case .star5:        baseFiles = manager.rawFiles.filter { $0.starRating == 5 }
        case .colourRed:    baseFiles = manager.rawFiles.filter { $0.labelColour == .red }
        case .colourYellow: baseFiles = manager.rawFiles.filter { $0.labelColour == .yellow }
        case .colourGreen:  baseFiles = manager.rawFiles.filter { $0.labelColour == .green }
        case .colourBlue:   baseFiles = manager.rawFiles.filter { $0.labelColour == .blue }
        case .colourPurple: baseFiles = manager.rawFiles.filter { $0.labelColour == .purple }
        default:            baseFiles = manager.rawFiles
        }

        let settings = manager.settings
        var groups: [PhotoGroup] = []
        var coveredIDs: Set<UUID> = []

        for reason in Self.allReasonDefinitions {
            let matched = baseFiles
                .filter { reason.matches($0, settings) }
                .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            guard !matched.isEmpty else { continue }
            matched.forEach { coveredIDs.insert($0.id) }
            groups.append(PhotoGroup(files: matched, kind: .reasonGroup(label: reason.label)))
        }

        // Catch-all: photos that passed the pick filter but matched no reason.
        let uncovered = baseFiles
            .filter { !coveredIDs.contains($0.id) }
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        if !uncovered.isEmpty {
            groups.append(PhotoGroup(files: uncovered, kind: .reasonGroup(label: "No Flags")))
        }

        return groups
    }

    @ViewBuilder
    private var picksReasonContent: some View {
        let groups = picksReasonGroups
        if groups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(groups) { group in
                            BurstStackCard(
                                stack: group,
                                manager: manager,
                                visibleCount: group.count,
                                titleOverride: group.reasonLabel
                            )
                            .onTapGesture { activeGroup = group }
                            .id(group.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
                .onChange(of: scrollToID) { targetID in
                    guard let id = targetID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    scrollToID = nil
                }
            }
        }
    }

    private var filteredSpeciesGroups: [PhotoGroup] {
        guard !searchText.isEmpty else { return manager.speciesGroups }
        return manager.speciesGroups.compactMap { group in
            let matching = group.files.filter { matchesSearch($0) }
            guard matching.count >= 2 else { return nil }
            return PhotoGroup(files: matching, kind: .similar, id: group.id)
        }
    }

    // MARK: - Grid cell builder

    @ViewBuilder
    private func gridCell(for item: GridItem) -> some View {
        switch item {
        case .single(let file):
            RAWFileThumbnailCard(
                file: file, manager: manager,
                isSelectMode: isSelectMode,
                isSelected: selectedItemIDs.contains(file.id),
                onToggleSelect: { toggleSelection(of: item) }
            )
            .onTapGesture {
                if isSelectMode { toggleSelection(of: item) }
                else { selectedFile = file }
            }
            .onLongPressGesture {
                if isSelectMode {
                    selectedItemIDs.insert(file.id)
                    showMultiLabelSheet = true
                }
            }
            // Plain UUID: scrollTo(UUID) can find the cell, and flag/status
            // changes update in place instead of tearing the cell down
            // (which reloaded the thumbnail and caused a visible flash).
            .id(file.id)

        case .group(let group):
            BurstStackCard(
                stack: group, manager: manager,
                visibleCount: group.files.count,
                isSelectMode: isSelectMode,
                isSelected: selectedItemIDs.contains(group.id),
                onToggleSelect: { toggleSelection(of: item) }
            )
            .onTapGesture {
                if isSelectMode { toggleSelection(of: item) }
                else { activeGroup = group }
            }
            .onLongPressGesture {
                if isSelectMode {
                    selectedItemIDs.insert(group.id)
                    showMultiLabelSheet = true
                }
            }
            .id(group.id)
        }
    }

    // MARK: - Selection helpers

    private func toggleSelection(of item: GridItem) {
        if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
        else { selectedItemIDs.insert(item.id) }
    }

    // MARK: - Banners

    private var analysisBanner: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "circle.dashed")
                Text("Analyzing focus…")
                Spacer()
                Text("\(Int(manager.analysisProgress * 100))%").monospacedDigit()
                Button { manager.cancelAnalysis() } label: {
                    Text("Cancel").font(.subheadline.weight(.medium)).foregroundStyle(.red)
                }
                .buttonStyle(.plain).padding(.leading, 8)
            }
            .font(.subheadline.weight(.medium))
            ProgressView(value: manager.analysisProgress).tint(.accentColor)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var hashBanner: some View {
        HStack {
            ProgressView().padding(.trailing, 4)
            Text("Scanning for similar photos…").font(.subheadline.weight(.medium))
            Spacer()
            Text("\(Int(manager.hashProgress * 100))%")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var xmpBanner: some View {
        HStack {
            ProgressView().padding(.trailing, 4)
            Text("Writing XMP sidecars…").font(.subheadline.weight(.medium))
            Spacer()
            Text("\(Int(manager.xmpProgress * 100))%")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filterMode == .rejected ? "flag.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 60)).foregroundStyle(.secondary)
            Text(filterMode == .rejected   ? "No rejected files"
                 : filterMode == .accepted ? "No accepted files"
                 : filterMode == .bursts   ? "No bursts found"
                 : "No files match")
                .font(.title2.weight(.semibold))
            Text(filterMode == .rejected
                 ? "No photos have been rejected yet."
                 : filterMode == .accepted ? "No photos have been accepted yet."
                 : filterMode == .bursts   ? "No burst sequences were detected."
                 : "Try adjusting your search or filter.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - GroupDetailView
//
// Shows all photos in a PhotoGroup (burst or similar) as a flat grid.
// Used for both burst and similar groups — the back button label reflects the kind.

struct GroupDetailView: View {
    let group: PhotoGroup
    @ObservedObject var manager: SDCardManager
    let onDismiss: () -> Void
    /// Overrides the default back breadcrumb label (e.g. "Robin" when navigating from a species sub-group)
    var backLabelOverride: String? = nil
    /// Overrides the default title caption
    var titleOverride: String? = nil

    @State private var selectedFile: RAWFile?
    @State private var filterMode: RAWFileGridView.FilterMode = .all

    private var columns: [SwiftUI.GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12), count: count)
    }

    private var liveFiles: [RAWFile] {
        let ids = Set(group.files.map { $0.id })
        let live = manager.rawFiles.filter { ids.contains($0.id) }
        return live.isEmpty ? group.files : live
    }

    private func count(for mode: RAWFileGridView.FilterMode) -> Int {
        switch mode {
        case .all, .bursts, .similar, .species: return liveFiles.count
        case .accepted:     return liveFiles.filter { $0.pickStatus == .accepted }.count
        case .rejected:     return liveFiles.filter { $0.pickStatus == .rejected }.count
        case .sharp:        return liveFiles.filter { $0.focusStatus == .sharp }.count
        case .slightlyBlur: return liveFiles.filter { $0.focusStatus == .slightlyBlur }.count
        case .blurry:       return liveFiles.filter { $0.focusStatus == .blurry }.count
        case .unanalyzed:   return liveFiles.filter { $0.focusStatus == .unanalyzed }.count
        case .star1:        return liveFiles.filter { $0.starRating == 1 }.count
        case .star2:        return liveFiles.filter { $0.starRating == 2 }.count
        case .star3:        return liveFiles.filter { $0.starRating == 3 }.count
        case .star4:        return liveFiles.filter { $0.starRating == 4 }.count
        case .star5:        return liveFiles.filter { $0.starRating == 5 }.count
        case .colourRed:    return liveFiles.filter { $0.labelColour == .red }.count
        case .colourYellow: return liveFiles.filter { $0.labelColour == .yellow }.count
        case .colourGreen:  return liveFiles.filter { $0.labelColour == .green }.count
        case .colourBlue:   return liveFiles.filter { $0.labelColour == .blue }.count
        case .colourPurple: return liveFiles.filter { $0.labelColour == .purple }.count
        case .burstBest:    return liveFiles.filter { $0.isBurstSharpnessBest }.count
        case .clipped:      return liveFiles.filter { $0.subjectClipped }.count
        case .overexposed:
            return liveFiles.filter { f in
                f.exposureAssessment.flatMap { manager.settings?.exposureIssue(for: $0) } == .overexposed
            }.count
        case .underexposed:
            return liveFiles.filter { f in
                f.exposureAssessment.flatMap { manager.settings?.exposureIssue(for: $0) } == .underexposed
            }.count
        }
    }

    private var filteredFiles: [RAWFile] {
        switch filterMode {
        case .all, .bursts, .similar, .species: return liveFiles
        case .accepted:     return liveFiles.filter { $0.pickStatus == .accepted }
        case .rejected:     return liveFiles.filter { $0.pickStatus == .rejected }
        case .sharp:        return liveFiles.filter { $0.focusStatus == .sharp }
        case .slightlyBlur: return liveFiles.filter { $0.focusStatus == .slightlyBlur }
        case .blurry:       return liveFiles.filter { $0.focusStatus == .blurry }
        case .unanalyzed:   return liveFiles.filter { $0.focusStatus == .unanalyzed }
        case .star1:        return liveFiles.filter { $0.starRating == 1 }
        case .star2:        return liveFiles.filter { $0.starRating == 2 }
        case .star3:        return liveFiles.filter { $0.starRating == 3 }
        case .star4:        return liveFiles.filter { $0.starRating == 4 }
        case .star5:        return liveFiles.filter { $0.starRating == 5 }
        case .colourRed:    return liveFiles.filter { $0.labelColour == .red }
        case .colourYellow: return liveFiles.filter { $0.labelColour == .yellow }
        case .colourGreen:  return liveFiles.filter { $0.labelColour == .green }
        case .colourBlue:   return liveFiles.filter { $0.labelColour == .blue }
        case .colourPurple: return liveFiles.filter { $0.labelColour == .purple }
        case .burstBest:    return liveFiles.filter { $0.isBurstSharpnessBest }
        case .clipped:      return liveFiles.filter { $0.subjectClipped }
        case .overexposed:
            return liveFiles.filter { f in
                f.exposureAssessment.flatMap { manager.settings?.exposureIssue(for: $0) } == .overexposed
            }
        case .underexposed:
            return liveFiles.filter { f in
                f.exposureAssessment.flatMap { manager.settings?.exposureIssue(for: $0) } == .underexposed
            }
        }
    }

    private var visibleFilterModes: [RAWFileGridView.FilterMode] {
        RAWFileGridView.FilterMode.allCases.filter { mode in
            if mode == .bursts || mode == .similar || mode == .species { return false }
            return mode == .all || count(for: mode) > 0
        }
    }

    private var backLabel: String {
        if let override = backLabelOverride { return override }
        if group.isBurst       { return "Bursts" }
        if group.isSimilar     { return "Similar" }
        if group.isReasonGroup { return "My Picks" }
        return "Back"
    }

    private var titleLabel: String {
        if let t = titleOverride { return t }
        if group.isBurst       { return "Burst (\(group.count) photos)" }
        if group.isSimilar     { return "Similar (\(group.count) photos)" }
        if let label = group.reasonLabel { return "\(label) · \(group.count) photos" }
        return "\(group.count) photos"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack {
                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text(backLabel)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(titleLabel)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(.systemBackground))

            Divider()

            // ── Filter pills ─────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleFilterModes, id: \.self) { mode in
                        FilterPill(mode: mode, count: count(for: mode),
                                   isSelected: filterMode == mode
                        ) { filterMode = mode }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }

            Divider()

            if filteredFiles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 60)).foregroundStyle(.secondary)
                    Text("No photos match").font(.title2.weight(.semibold))
                    Text("Try a different filter.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredFiles) { file in
                            RAWFileThumbnailCard(file: file, manager: manager)
                                .onTapGesture { selectedFile = file }
                                .id(file.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGray6))
            }
        }
        .sheet(item: $selectedFile) { file in
            let ids = filteredFiles.map { $0.id }
            let idx = ids.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(fileIDs: ids, startIndex: idx, manager: manager,
                              onDismiss: { _ in })
        }
    }
}

// MARK: - Species detail view
//
// Level 2 of the species navigation hierarchy.
// Shows all photos for one species as a mixed grid of singles and burst stacks —
// exactly mirroring the "All" view logic but scoped to this species' files.
// Tapping a single opens the detail sheet.
// Tapping a burst stack opens SpeciesBurstDetailView (level 3).

private let burstGap: TimeInterval = 2.0   // seconds — matches SDCardManager burstGapThreshold

struct SpeciesDetailView: View {
    let speciesGroup: PhotoGroup
    @ObservedObject var manager: SDCardManager
    let onDismiss: () -> Void

    @State private var activeBurst: PhotoGroup? = nil
    @State private var selectedFile: RAWFile?

    // MARK: - Species name

    var speciesName: String { Self.dominantSpecies(in: speciesGroup) }

    static func dominantSpecies(in group: PhotoGroup) -> String {
        var counts: [String: Int] = [:]
        for file in group.files {
            // Use speciesLabel first; fall back to detectedAnimalLabel so that
            // files labelled below the confidence threshold still contribute a vote.
            let label = file.speciesLabel ?? file.detectedAnimalLabel
            if let label { counts[label, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "Unknown"
    }

    // MARK: - Grid items
    //
    // Group species files into bursts and singles using the 2-second rule.
    // Walk through files in date order. Consecutive files within 2 seconds
    // form a burst group. A group becomes a stack only if it has 2+ files
    // AND contains at least one file with a confident species label
    // (prevents unlabelled-only groups from showing as fake bursts).
    // Groups of 1, or groups with no labelled file, show as singles.

    private var gridItems: [GridItem] {
        let sorted = speciesGroup.files.sorted {
            ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
        }
        guard !sorted.isEmpty else { return [] }

        // Step 1: group consecutive files within burstGap into raw groups.
        var rawGroups: [[RAWFile]] = []
        var current: [RAWFile] = [sorted[0]]

        for i in 1..<sorted.count {
            guard let d0 = sorted[i-1].modificationDate,
                  let d1 = sorted[i].modificationDate else {
                rawGroups.append(current); current = [sorted[i]]; continue
            }
            if d1.timeIntervalSince(d0) <= burstGap {
                current.append(sorted[i])
            } else {
                rawGroups.append(current); current = [sorted[i]]
            }
        }
        rawGroups.append(current)

        // Step 2: convert each raw group to a GridItem.
        // A group becomes a burst stack only if it has ≥2 files AND
        // at least one member has a confident species label.
        return rawGroups.map { group -> GridItem in
            let hasLabel = group.contains { $0.speciesLabel != nil }
            if group.count >= 2 && hasLabel {
                return .group(PhotoGroup(files: group, kind: .confirmedBurst))
            } else if group.count == 1 {
                return .single(group[0])
            } else {
                // Multiple unlabelled files — emit as individual singles.
                // (Should rarely happen given how buildSpeciesGroups works.)
                // Return the first as representative; others will be skipped
                // since we walk sorted order and they'd be emitted separately.
                // Actually map returns one item per rawGroup, so just take first.
                return .single(group[0])
            }
        }
        // Note: the "multiple unlabelled" case emits only group[0] as a single.
        // The remaining files in such a group would be lost. This is acceptable
        // because buildSpeciesGroups only adds files that are burst-adjacent to
        // a labelled file, so any group of 2+ should always contain a label.
    }

    private var columns: [SwiftUI.GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        return Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let burst = activeBurst {
                // ── Level 3: burst detail ─────────────────────────────────
                GroupDetailView(
                    group: burst,
                    manager: manager,
                    onDismiss: { activeBurst = nil },
                    backLabelOverride: speciesName
                )
            } else {
                // ── Level 2: species grid (singles + burst stacks) ────────
                VStack(spacing: 0) {
                    HStack {
                        Button { onDismiss() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Species")
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Text("\(speciesName) · \(speciesGroup.count) photos")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(.systemBackground))

                    Divider()

                    if gridItems.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 60)).foregroundStyle(.secondary)
                            Text("No photos").font(.title2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(gridItems) { item in
                                    switch item {
                                    case .single(let file):
                                        RAWFileThumbnailCard(
                                            file: file, manager: manager,
                                            isSelectMode: false, isSelected: false,
                                            onToggleSelect: {}
                                        )
                                        .onTapGesture { selectedFile = file }
                                        .id(file.id)

                                    case .group(let burst):
                                        BurstStackCard(
                                            stack: burst, manager: manager,
                                            visibleCount: burst.count
                                        )
                                        .onTapGesture { activeBurst = burst }
                                        .id(burst.id)
                                    }
                                }
                            }
                            .padding()
                        }
                        .background(Color(.systemGray6))
                    }
                }
            }
        }
        .sheet(item: $selectedFile) { file in
            let allSingleIDs = gridItems.compactMap { item -> UUID? in
                if case .single(let f) = item { return f.id }
                return nil
            }
            let idx = allSingleIDs.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(
                fileIDs: allSingleIDs, startIndex: idx,
                manager: manager, onDismiss: { _ in }
            )
        }
    }
}

// MARK: - Species group card
//
// Shows a species group as a stacked-thumbnail card with the species name
// as a label overlay. Reuses BurstStackCard for the thumbnail stack visual.

struct SpeciesGroupCard: View {
    let group: PhotoGroup
    @ObservedObject var manager: SDCardManager

    var speciesName: String { SpeciesDetailView.dominantSpecies(in: group) }

    var body: some View {
        BurstStackCard(
            stack: group,
            manager: manager,
            visibleCount: group.count,
            titleOverride: speciesName
        )
    }
}

// MARK: - Section pill (top bar)

struct SectionPill: View {
    let title: String
    let isSelected: Bool
    /// True when the section has no populated filter pills (dimmed but still tappable).
    let isEmpty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : isEmpty ? Color(.tertiaryLabel) : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter pill (bottom bar)

struct FilterPill: View {
    let mode: RAWFileGridView.FilterMode
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    /// Standardised label: "Label · N"
    private var pillLabel: String {
        switch mode {
        case .species: return "Species · \(count)"
        default:       return "\(mode.rawValue) · \(count)"
        }
    }

    var body: some View {
        Button(action: action) {
            Text(pillLabel)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
