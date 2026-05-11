import SwiftUI

// MARK: - BurstStackCard

/// Thumbnail card shown in the grid when a grid item is a burst stack.
///
/// Badge layout:
///   Top-left:     stack count badge
///   Top-right:    star-range badge   — matches StarRatingBadge exactly
///   Bottom-left:  focus-range pill   — frosted Capsule with circle.dashed icons inside
///   Bottom-right: pick-flag badge    (solid white / solid black / diagonal mix)
///
/// Stack visual: front card sits at top-left (0,0). Two darker shadow layers
/// are offset 5 pt and 10 pt to the bottom-right. The front card is shrunk by
/// 10 pt in each dimension so the entire composition fits within the same
/// bounding box as a solo card — grid rows stay perfectly aligned.

struct BurstStackCard: View {
    let stack: BurstStack
    @ObservedObject var manager: SDCardManager
    let visibleCount: Int

    // ── Selection mode support ──────────────────────────────────────────
    var isSelectMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil

    @State private var thumbnail: UIImage?
    @State private var isLoading = true
    @State private var showActionSheet = false

    private var liveCover: RAWFile? {
        manager.rawFiles.first { $0.id == stack.coverFile.id }
    }

    private var liveFiles: [RAWFile] {
        let ids = Set(stack.files.map { $0.id })
        let live = manager.rawFiles.filter { ids.contains($0.id) }
        return live.isEmpty ? stack.files : live
    }

    var body: some View {
        let cover = liveCover ?? stack.coverFile
        let files = liveFiles

        VStack(alignment: .leading, spacing: 6) {

            // ── Image area ──────────────────────────────────────────────
            // Outer box: totalW × totalH — identical to RAWFileThumbnailCard.
            //
            // All three cards are the same size: (totalW - step*2) × (totalH - step*2).
            // Front card:    offset (0, 0)         — top+left flush with cell edge
            // Middle shadow: offset (step, step)   — peeks step pt at bottom+right
            // Back shadow:   offset (step*2, step*2) — bottom-right corner lands
            //                                          exactly at the cell boundary
            // ZStack clipped to totalW × totalH — no overflow.
            GeometryReader { geo in
                let totalW = geo.size.width
                let totalH = geo.size.width * 3 / 4
                let step: CGFloat = 8

                let cardW = totalW - step * 2
                let cardH = totalH - step * 2

                ZStack(alignment: .topLeading) {

                    // ── Back shadow ──────────────────────────────────────
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray3))
                        .frame(width: cardW, height: cardH)
                        .offset(x: step * 2, y: step * 2)

                    // ── Middle shadow ────────────────────────────────────
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .frame(width: cardW, height: cardH)
                        .offset(x: step, y: step)

                    // ── Front card — top-left flush, smaller than box ────
                    ZStack(alignment: .bottomLeading) {

                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.secondarySystemBackground))

                        if let thumb = thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: cardW, height: cardH)
                                .clipped()
                        } else if isLoading {
                            ProgressView()
                                .frame(width: cardW, height: cardH)
                        } else {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .frame(width: cardW, height: cardH)
                        }

                        // Top-left: colour swatches (up to 3, one per unique colour)
                        BurstColourSwatches(files: files)
                            .frame(width: cardW, height: cardH,
                                   alignment: .topLeading)
                            .padding(6)

                        // Top-centre: stack count badge
                        BurstCountBadge(count: visibleCount)
                            .frame(width: cardW, height: cardH,
                                   alignment: .top)
                            .padding(.top, 6)

                        // Top-right: star-range badge
                        if let starBadge = BurstStarRangeBadge(files: files) {
                            starBadge
                                .frame(width: cardW, height: cardH,
                                       alignment: .topTrailing)
                                .padding(6)
                        }

                        // Bottom-left: focus-range pill
                        if let focusPill = BurstFocusRangePill(files: files) {
                            focusPill
                                .frame(width: cardW, height: cardH,
                                       alignment: .bottomLeading)
                                .padding(6)
                        }

                        // Bottom-right: pick-flag badge
                        BurstPickBadge(files: files)
                            .frame(width: cardW, height: cardH,
                                   alignment: .bottomTrailing)
                            .padding(6)
                    }
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        // Blue selection border — same as single-photo thumbnails
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                    // No offset — front card at (0,0), top-left flush
                }
                .frame(width: totalW, height: totalH, alignment: .topLeading)
                .clipped()
                // Dim when in selection mode but not selected
                .opacity(isSelectMode && !isSelected ? 0.55 : 1.0)
            }
            .aspectRatio(4/3, contentMode: .fit)
            .if(!isSelectMode) { view in
                view.onLongPressGesture {
                    showActionSheet = true
                }
            }
            .sheet(isPresented: $showActionSheet) {
                BurstLabelPickerSheet(stack: stack, manager: manager)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
            }

            // ── Filename / metadata row ─────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .topLeading) {
                    Text("A\nA")
                        .font(.caption.weight(.medium))
                        .opacity(0)
                    Text("Burst — \(stack.count) photos")
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }

                HStack {
                    Text(cover.fileExtension)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                    Spacer()
                    Text(cover.formattedSize)
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
        let url = stack.coverFile.url
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

// MARK: - BurstFocusRangePill

struct BurstFocusRangePill: View {

    private let bestColor:  Color
    private let worstColor: Color
    private let isSame:     Bool

    init?(files: [RAWFile]) {
        let analysed = files.filter { $0.focusStatus != .unanalyzed }
        guard !analysed.isEmpty else { return nil }

        func rank(_ s: FocusStatus) -> Int {
            switch s {
            case .sharp:        return 0
            case .slightlyBlur: return 1
            case .blurry:       return 2
            default:            return 99
            }
        }
        func color(_ s: FocusStatus) -> Color {
            switch s {
            case .sharp:        return .green
            case .slightlyBlur: return .orange
            case .blurry:       return .red
            default:            return .gray
            }
        }

        let statuses = analysed.map { $0.focusStatus }
        let best  = statuses.min(by: { rank($0) < rank($1) })!
        let worst = statuses.max(by: { rank($0) < rank($1) })!

        bestColor  = color(best)
        worstColor = color(worst)
        isSame     = (best == worst)
    }

    var body: some View {
        if isSame {
            // Single indicator — identical to QualityBadge on solo thumbnails
            Image(systemName: "circle.dashed")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(bestColor)
                .background(Circle().fill(.regularMaterial).padding(-3))
                .shadow(radius: 1)
        } else {
            // Range indicator — capsule uses the same -3 inset as the single
            // indicator's circle, so the background hugs the glyphs identically
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(bestColor)

                Text("–")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Image(systemName: "circle.dashed")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(worstColor)
            }
            .background(Capsule().fill(.regularMaterial).padding(-3))
            .shadow(radius: 1)
        }
    }
}

// MARK: - BurstPickBadge

struct BurstPickBadge: View {

    enum PickState {
        case allAccepted, allRejected, mixed, allUnpicked
    }

    private let pickState: PickState

    init(files: [RAWFile]) {
        let picked = files.filter { $0.pickStatus != .unpicked }
        if picked.isEmpty {
            pickState = .allUnpicked
        } else {
            let hasAccepted = picked.contains { $0.pickStatus == .accepted }
            let hasRejected = picked.contains { $0.pickStatus == .rejected }
            if hasAccepted && hasRejected {
                pickState = .mixed
            } else if hasAccepted {
                pickState = .allAccepted
            } else {
                pickState = .allRejected
            }
        }
    }

    var body: some View {
        switch pickState {
        case .allUnpicked:
            EmptyView()

        case .allAccepted:
            ZStack {
                Image(systemName: "flag.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.black)
                Image(systemName: "flag.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .shadow(radius: 1)
            .help("All accepted")

        case .allRejected:
            ZStack {
                Image(systemName: "flag.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                Image(systemName: "flag.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black)
            }
            .shadow(radius: 1)
            .help("All rejected")

        case .mixed:
            MixedPickFlagBadge()
                .help("Mix of accepted and rejected")
        }
    }
}

private struct MixedPickFlagBadge: View {
    var body: some View {
        ZStack {
            Image(systemName: "flag.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.black)

            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)

                var topLeft = Path()
                topLeft.move(to:    CGPoint(x: rect.minX, y: rect.minY))
                topLeft.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                topLeft.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                topLeft.closeSubpath()

                var bottomRight = Path()
                bottomRight.move(to:    CGPoint(x: rect.maxX, y: rect.minY))
                bottomRight.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                bottomRight.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                bottomRight.closeSubpath()

                ctx.clip(to: topLeft)
                ctx.fill(Path(rect), with: .color(.white))

                ctx.clip(to: bottomRight)
                ctx.fill(Path(rect), with: .color(.black))
            }
            .mask {
                Image(systemName: "flag.fill")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(width: 19, height: 19)
        }
        .shadow(radius: 1)
    }
}

// MARK: - BurstStarRangeBadge

struct BurstStarRangeBadge: View {

    private let lo: Int
    private let hi: Int

    init?(files: [RAWFile]) {
        let ratings = files.map { $0.starRating }
        let low  = ratings.min() ?? 0
        let high = ratings.max() ?? 0
        guard high > 0 else { return nil }
        lo = low
        hi = high
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(lo == hi ? "\(hi)" : "\(lo)–\(hi)")
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

// MARK: - BurstColourSwatches
//
// Shows up to three small colour circles stacked vertically in the top-left,
// one per unique non-none label colour present in the stack's files.
// Matches the circle swatch style used on single-photo thumbnails.

struct BurstColourSwatches: View {

    private let colours: [Color]

    init(files: [RAWFile]) {
        // Collect unique colours in the order they first appear, skip .none.
        var seen: [LabelColour] = []
        for file in files {
            if file.labelColour != .none && !seen.contains(file.labelColour) {
                seen.append(file.labelColour)
            }
            if seen.count == 3 { break }
        }
        colours = seen.compactMap { $0.swiftUIColor }
    }

    var body: some View {
        if colours.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 4) {
                ForEach(colours.indices, id: \.self) { i in
                    Circle()
                        .fill(colours[i])
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.regularMaterial).padding(-3))
                        .shadow(radius: 1)
                }
            }
        }
    }
}

// MARK: - BurstCountBadge

struct BurstCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.fill")
                .font(.system(size: 9, weight: .bold))
            Text("×\(count)")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.65), in: Capsule())
        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
    }
}

// MARK: - BurstLabelPickerSheet

struct BurstLabelPickerSheet: View {
    let stack: BurstStack
    @ObservedObject var manager: SDCardManager

    @State private var pickStatus: PickStatus

    init(stack: BurstStack, manager: SDCardManager) {
        self.stack = stack
        self.manager = manager
        _pickStatus = State(initialValue: stack.coverFile.pickStatus)
    }

    private var liveCover: RAWFile? {
        manager.rawFiles.first { $0.id == stack.coverFile.id }
    }

    var body: some View {
        let cover = liveCover ?? stack.coverFile

        VStack(spacing: 24) {

            // ── Pick row ─────────────────────────────────────────────────
            HStack(spacing: 32) {
                Spacer()
                Button {
                    let next: PickStatus = pickStatus == .accepted ? .unpicked : .accepted
                    pickStatus = next
                    manager.setPickStatus(next, forAllIn: stack)
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

                Button {
                    let next: PickStatus = pickStatus == .rejected ? .unpicked : .rejected
                    pickStatus = next
                    manager.setPickStatus(next, forAllIn: stack)
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

            // ── Stars ────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    Button {
                        manager.setStarRating(cover.starRating == n ? 0 : n, forAllIn: stack)
                    } label: {
                        Image(systemName: n <= cover.starRating ? "star.fill" : "star")
                            .font(.system(size: 32))
                            .foregroundStyle(n <= cover.starRating ? Color.yellow : Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            // ── Colour swatches ──────────────────────────────────────────
            HStack(spacing: 14) {
                Spacer()
                Button {
                    manager.setLabelColour(.none, forAllIn: stack)
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
                        if cover.labelColour == .none {
                            Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(LabelColour.allCases.filter { $0 != .none }, id: \.self) { colour in
                    Button {
                        manager.setLabelColour(colour, forAllIn: stack)
                    } label: {
                        Circle()
                            .fill(colour.swiftUIColor ?? .clear)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if cover.labelColour == colour {
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