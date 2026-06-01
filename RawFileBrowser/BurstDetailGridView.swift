import SwiftUI

/// The grid shown when the user taps a burst stack. Displays only the photos
/// in that stack, with filter pills scoped to those photos. A "All Photos"
/// back button is always visible in the navigation bar.
struct BurstDetailGridView: View {
    let group: PhotoGroup
    @ObservedObject var manager: SDCardManager
    @Binding var activeGroup: PhotoGroup?

    /// Called just before activeStack is cleared, so the parent can capture
    /// the stack ID and restore the scroll position.
    var onDismiss: () -> Void = {}

    @State private var selectedFile: RAWFile?
    @State private var filterMode: RAWFileGridView.FilterMode = .all

    /// ID of the thumbnail to scroll to after returning from detail view.
    @State private var scrollToID: String? = nil

    // MARK: - Derived data

    /// Live versions of this stack's files, so badges update in real time.
    private var liveFiles: [RAWFile] {
        group.files.compactMap { file in
            manager.rawFiles.first { $0.id == file.id }
        }
    }

    /// Count of files in this stack matching a given filter mode.
    private func count(for mode: RAWFileGridView.FilterMode) -> Int {
        switch mode {
        case .all:          return liveFiles.count
        case .bursts:       return 0   // not applicable inside a stack
        case .similar:      return 0   // not applicable inside a stack
        case .species:      return 0   // not applicable inside a stack
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

    /// Files shown after the current filter is applied.
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

    /// "All" always visible; "Bursts" never visible inside a stack;
    /// others only when at least one photo matches.
    private var visibleFilterModes: [RAWFileGridView.FilterMode] {
        RAWFileGridView.FilterMode.allCases.filter { mode in
            if mode == .bursts || mode == .similar || mode == .species { return false }
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
                            isSelected: filterMode == mode,
                            systemImage: mode == .burstBest ? "crown.fill" : nil
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
                ScrollViewReader { proxy in
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
                    // Scroll to the last-viewed photo when returning from detail view.
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
        .navigationTitle("Burst (\(group.count) photos)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // Fire the callback first so the parent captures the ID
                    // before activeStack is set to nil.
                    onDismiss()
                    activeGroup = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("All Photos")
                    }
                }
            }
        }
        // ── Detail view sheet ────────────────────────────────────────────
        // Passes the full filtered list so the user can swipe through all
        // photos in this stack. On dismiss, scroll to the last-viewed photo.
        .sheet(item: $selectedFile) { file in
            let ids = filteredFiles.map { $0.id }
            let idx = ids.firstIndex(of: file.id) ?? 0
            RAWFileDetailView(
                fileIDs:    ids,
                startIndex: idx,
                manager:    manager,
                onDismiss: { lastViewedID in
                    // Build the scroll ID to match the .id() modifier on the card.
                    // We need the live file to get its current focusStatus / pickStatus.
                    if let liveFile = manager.rawFiles.first(where: { $0.id == lastViewedID }) {
                        scrollToID = "\(liveFile.id)-\(liveFile.focusStatus.rawValue)-\(liveFile.pickStatus.rawValue)"
                    }
                }
            )
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
