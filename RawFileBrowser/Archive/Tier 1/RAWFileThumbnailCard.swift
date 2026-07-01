import SwiftUI
import ImageIO

struct RAWFileThumbnailCard: View {
    let file: RAWFile
    @ObservedObject var manager: SDCardManager

    // ── Selection mode support ──────────────────────────────────────────
    // These are passed in from RAWFileGridView when selection mode is active.
    // Default values (false / constant binding) mean the card behaves exactly
    // as before when not in selection mode.
    var isSelectMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil

    @State private var thumbnail: UIImage?
    @State private var isLoading = true
    @State private var showLabelSheet = false

    /// Always read live state from the manager so the UI stays in sync.
    private var liveFile: RAWFile? {
        manager.liveFile(id: file.id)
    }

    var body: some View {
        let live = liveFile ?? file   // fallback to snapshot if not found

        VStack(alignment: .leading, spacing: 6) {
            // ── Image area ──────────────────────────────────────────────
            GeometryReader { geo in
                let imgHeight = geo.size.width * 3 / 4   // 4:3 ratio
                ZStack(alignment: .bottomLeading) {

                    // Base thumbnail
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.secondarySystemBackground))

                        if let thumb = thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: imgHeight)
                                .clipped()
                        } else if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: geo.size.width, height: imgHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    // Blue border when selected
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }

                    // ── Top-right: star rating badge ─────────────────────
                    if live.starRating > 0 {
                        StarRatingBadge(rating: live.starRating)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                            .padding(6)
                    }

                    // ── Top-left: colour label swatch ────────────────────
                    if let swatchColor = live.labelColour.swiftUIColor {
                        Circle()
                            .fill(swatchColor)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.regularMaterial).padding(-3))
                            .shadow(radius: 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .padding(6)
                    }

                    // ── Bottom-left: quality badge ───────────────────────
                    if live.focusStatus != .unanalyzed,
                       let badge = QualityBadgeInfo(status: live.focusStatus) {
                        QualityBadge(info: badge)
                            .padding(6)
                    }

                    // ── Top-centre: burst rank badge ─────────────────────
                    if let rank = live.burstRank {
                        HStack(spacing: 3) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(
                                    rank == 1 ? Color.yellow :
                                    rank == 2 ? Color(white: 0.75) :
                                                Color(red: 0.72, green: 0.45, blue: 0.20)
                                )
                            Text("\(rank)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .top)
                        .padding(.top, 6)
                    }

                    // ── Bottom-right: pick/flag badge ────────────────────
                    if live.pickStatus != .unpicked {
                        PickFlagBadge(status: live.pickStatus)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(6)
                    }
                }  // end ZStack(alignment: .bottomLeading)
                // Dim when in selection mode but not selected
                .opacity(isSelectMode && !isSelected ? 0.55 : 1.0)
            }      // end GeometryReader
            .aspectRatio(4/3, contentMode: .fit)
            // Long-press opens the single-file label sheet, but only when NOT in
            // selection mode. In selection mode, RAWFileGridView owns the long-press.
            // We attach NO gesture in select mode so the parent gesture can fire.
            .if(!isSelectMode) { view in
                view.onLongPressGesture {
                    showLabelSheet = true
                }
            }
            // Edit sheet (single-file, used outside selection mode)
            .sheet(isPresented: $showLabelSheet) {
                LabelPickerSheet(file: file, manager: manager)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
            }

            // ── Filename / metadata row ──────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                // ZStack forces exactly 2-line height at all times.
                // The invisible placeholder always occupies 2 lines so
                // short filenames don't collapse the row and throw off
                // grid alignment.
                ZStack(alignment: .topLeading) {
                    Text("A\nA")
                        .font(.caption.weight(.medium))
                        .opacity(0)
                    Text(live.url.deletingPathExtension().lastPathComponent)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(live.pickStatus == .rejected ? .secondary : .primary)
                }

                HStack {
                    Text(live.fileExtension)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                    Spacer()
                    Text(live.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .task { loadThumbnail() }
    }

    private func loadThumbnail() {
        isLoading = true
        let url = file.url
        DispatchQueue.global(qos: .background).async {
            let thumb = RAWImageLoader.thumbnail(from: url)
            DispatchQueue.main.async {
                withAnimation(.easeIn(duration: 0.2)) {
                    thumbnail = thumb
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Label picker sheet
// Opens directly on long-press. Reads live state from the manager.
// Pick status uses a local @State so flag taps never dismiss the sheet.

struct LabelPickerSheet: View {
    let file: RAWFile
    @ObservedObject var manager: SDCardManager

    // Local pick state so flag taps never cause the sheet to dismiss/re-present.
    // Initialised from the file snapshot; kept in sync with manager on each tap.
    @State private var pickStatus: PickStatus

    init(file: RAWFile, manager: SDCardManager) {
        self.file = file
        self.manager = manager
        _pickStatus = State(initialValue: file.pickStatus)
    }

    private var liveFile: RAWFile? {
        manager.liveFile(id: file.id)
    }

    var body: some View {
        let live = liveFile ?? file

        VStack(spacing: 24) {

            // ── Pick row: thumbnail-style flags, no X ─────────────────────
            HStack(spacing: 32) {
                Spacer()

                // Accept flag: white fill, black outline
                Button {
                    let next: PickStatus = pickStatus == .accepted ? .unpicked : .accepted
                    pickStatus = next
                    manager.setPickStatus(next, for: file)
                } label: {
                    ZStack {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Color.black)
                        Image(systemName: "flag.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                    .opacity(pickStatus == .accepted ? 1.0 : 0.25)
                }
                .buttonStyle(.plain)

                // Reject flag: black fill, white outline
                Button {
                    let next: PickStatus = pickStatus == .rejected ? .unpicked : .rejected
                    pickStatus = next
                    manager.setPickStatus(next, for: file)
                } label: {
                    ZStack {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Color.white)
                        Image(systemName: "flag.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.black)
                    }
                    .opacity(pickStatus == .rejected ? 1.0 : 0.25)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // ── Stars only ───────────────────────────────────────────────
            HStack(spacing: 12) {
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    Button {
                        manager.setStarRating(live.starRating == n ? 0 : n, for: file)
                    } label: {
                        Image(systemName: n <= live.starRating ? "star.fill" : "star")
                            .font(.system(size: 32))
                            .foregroundStyle(n <= live.starRating ? Color.yellow : Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            // ── Colour swatches only ──────────────────────────────────────
            HStack(spacing: 14) {
                Spacer()

                // None swatch
                Button {
                    manager.setLabelColour(.none, for: file)
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .rotationEffect(.degrees(90))
                    }
                    .overlay {
                        if live.labelColour == .none {
                            Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(LabelColour.allCases.filter { $0 != .none }, id: \.self) { colour in
                    Button {
                        manager.setLabelColour(colour, for: file)
                    } label: {
                        Circle()
                            .fill(colour.swiftUIColor ?? .clear)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if live.labelColour == colour {
                                    Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - LabelColour → SwiftUI Color
// Kept in the view layer so SDCardManager stays free of SwiftUI imports.

extension LabelColour {
    var swiftUIColor: Color? {
        switch self {
        case .none:   return nil
        case .red:    return .red
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        }
    }
}

// MARK: - Quality badge

struct QualityBadgeInfo {
    let systemImage: String
    let color: Color
    let label: String

    init?(status: FocusStatus) {
        switch status {
        case .sharp:
            systemImage = "circle.dashed"; color = .green;  label = "Sharp"
        case .slightlyBlur:
            systemImage = "circle.dashed"; color = .orange; label = "Slightly Blurry"
        case .blurry:
            systemImage = "circle.dashed"; color = .red;    label = "Blurry"
        default:
            return nil
        }
    }
}

struct QualityBadge: View {
    let info: QualityBadgeInfo

    var body: some View {
        Image(systemName: info.systemImage)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(info.color)
            .background(Circle().fill(.regularMaterial).padding(-3))
            .shadow(radius: 1)
            .help(info.label)
    }
}

// MARK: - Pick flag badge

struct PickFlagBadge: View {
    let status: PickStatus

    var body: some View {
        ZStack {
            Image(systemName: "flag.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(status == .accepted ? Color.black : Color.white)
            Image(systemName: "flag.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(status == .accepted ? Color.white : Color.black)
        }
        .shadow(radius: 1)
        .help(status == .accepted ? "Accepted" : "Rejected")
    }
}

// MARK: - Star rating badge

struct StarRatingBadge: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            Text("\(rating)")
                .font(.system(size: 11, weight: .bold))
            Image(systemName: "star.fill")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Color.yellow)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black, in: Capsule())
        .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Legacy FocusBadge (kept for use in detail / diagnostic views)

struct FocusBadge: View {
    let status: FocusStatus
    let region: FocusResult.AnalysisRegion

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color(status.color))
            .background(Circle().fill(.regularMaterial).padding(-3))
            .shadow(radius: 2)
            .help("\(status.rawValue) · \(region.rawValue)")
    }
}

// MARK: - Multi-selection label picker sheet
//
// Shown when the user long-presses any card while selection mode is active.
// Every change is applied to ALL selected files at once.

struct MultiSelectionLabelPickerSheet: View {
    /// All files currently selected (resolved to live copies inside the sheet).
    let selectedFiles: [RAWFile]
    @ObservedObject var manager: SDCardManager
    @Environment(\.dismiss) private var dismiss

    // Local pick-state so tapping flags never dismisses the sheet.
    // We show "mixed" state visually when the selection isn't uniform.
    @State private var localPick: PickStatus? = nil  // nil = mixed

    init(selectedFiles: [RAWFile], manager: SDCardManager) {
        self.selectedFiles = selectedFiles
        self.manager = manager
        // Determine initial local pick state from the selection
        let statuses = Set(selectedFiles.map { $0.pickStatus })
        _localPick = State(initialValue: statuses.count == 1 ? statuses.first : nil)
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────────
            Text("Apply to \(selectedFiles.count) selected item\(selectedFiles.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            VStack(spacing: 24) {

                // ── Pick flags ───────────────────────────────────────────
                HStack(spacing: 32) {
                    Spacer()

                    // Accept flag
                    Button {
                        let next: PickStatus = localPick == .accepted ? .unpicked : .accepted
                        localPick = next
                        manager.setPickStatus(next, forFiles: allLiveFiles)
                    } label: {
                        ZStack {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(Color.black)
                            Image(systemName: "flag.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Color.white)
                        }
                        .opacity(localPick == .accepted ? 1.0 : 0.25)
                    }
                    .buttonStyle(.plain)

                    // Reject flag
                    Button {
                        let next: PickStatus = localPick == .rejected ? .unpicked : .rejected
                        localPick = next
                        manager.setPickStatus(next, forFiles: allLiveFiles)
                    } label: {
                        ZStack {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(Color.white)
                            Image(systemName: "flag.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Color.black)
                        }
                        .opacity(localPick == .rejected ? 1.0 : 0.25)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                // ── Stars ────────────────────────────────────────────────
                // We read the first selected file's star rating as a visual
                // reference, but setting any star applies to all selected files.
                let refRating = allLiveFiles.first?.starRating ?? 0

                HStack(spacing: 12) {
                    Spacer()
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            let newRating = refRating == n ? 0 : n
                            manager.setStarRating(newRating, forFiles: allLiveFiles)
                        } label: {
                            Image(systemName: n <= refRating ? "star.fill" : "star")
                                .font(.system(size: 32))
                                .foregroundStyle(n <= refRating ? Color.yellow : Color(.tertiaryLabel))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // ── Colour swatches ──────────────────────────────────────
                let refColour = allLiveFiles.first?.labelColour ?? .none

                HStack(spacing: 14) {
                    Spacer()

                    // "None" swatch
                    Button {
                        manager.setLabelColour(.none, forFiles: allLiveFiles)
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 15, weight: .light))
                                .foregroundStyle(Color(.tertiaryLabel))
                                .rotationEffect(.degrees(90))
                        }
                        .overlay {
                            if refColour == .none {
                                Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(LabelColour.allCases.filter { $0 != .none }, id: \.self) { colour in
                        Button {
                            manager.setLabelColour(colour, forFiles: allLiveFiles)
                        } label: {
                            Circle()
                                .fill(colour.swiftUIColor ?? .clear)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if refColour == colour {
                                        Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // Resolve snapshot IDs to live copies so ratings display correctly after changes.
    private var allLiveFiles: [RAWFile] {
        selectedFiles.compactMap { manager.liveFile(id: $0.id) }
    }
}

// MARK: - Conditional modifier helper
// Lets us write .if(condition) { view in view.someModifier() }
// Used to attach long-press only when not in selection mode.

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
