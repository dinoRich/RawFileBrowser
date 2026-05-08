import SwiftUI

/// Thumbnail card shown in the grid when a grid item is a burst stack.
/// Displays the cover photo with a stacked-cards visual effect and a count
/// badge. Long-pressing opens BurstLabelPickerSheet, which is visually
/// identical to LabelPickerSheet but applies every action to all photos
/// in the stack.
struct BurstStackCard: View {
    let stack: BurstStack
    @ObservedObject var manager: SDCardManager
    let visibleCount: Int

    @State private var thumbnail: UIImage?
    @State private var isLoading = true
    @State private var showActionSheet = false

    /// Always read the cover file live so badges stay in sync.
    private var liveCover: RAWFile? {
        manager.rawFiles.first { $0.id == stack.coverFile.id }
    }

    var body: some View {
        let cover = liveCover ?? stack.coverFile

        VStack(alignment: .leading, spacing: 6) {

            // ── Image area ──────────────────────────────────────────────
            GeometryReader { geo in
                let imgHeight = geo.size.width * 3 / 4  // 4:3 ratio

                ZStack(alignment: .bottomLeading) {

                    // Stacked-cards shadow layers drawn behind the main card
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray4))
                        .frame(width: geo.size.width - 8, height: imgHeight)
                        .offset(x: 6, y: -6)

                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .frame(width: geo.size.width - 4, height: imgHeight)
                        .offset(x: 3, y: -3)

                    // Main (front) card
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
                    .overlay {
                        if let outlineColor = cover.labelColour.swiftUIColor {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(outlineColor, lineWidth: 3)
                        } else if cover.pickStatus == .accepted {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white, lineWidth: 3)
                        } else if cover.pickStatus == .rejected {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.black, lineWidth: 3)
                        }
                    }

                    // Top-right: burst count badge
                    BurstCountBadge(count: visibleCount)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(6)

                    // Bottom-left: quality badge (cover photo)
                    if cover.focusStatus != .unanalyzed,
                       let badge = QualityBadgeInfo(status: cover.focusStatus) {
                        QualityBadge(info: badge)
                            .padding(6)
                    }

                    // Bottom-right: pick/flag badge (cover photo)
                    if cover.pickStatus != .unpicked {
                        PickFlagBadge(status: cover.pickStatus)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(6)
                    }
                }
            }
            .aspectRatio(4/3, contentMode: .fit)
            .onLongPressGesture {
                showActionSheet = true
            }
            .sheet(isPresented: $showActionSheet) {
                BurstLabelPickerSheet(stack: stack, manager: manager)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
            }

            // ── Filename / metadata row ─────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text("Burst — \(stack.count) photos")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

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

// MARK: - BurstLabelPickerSheet
//
// Visually identical to LabelPickerSheet. Every action applies to all files
// in the stack. The cover photo's current values are used as the "active"
// indicator for pick status, stars, and colour — giving a clear, consistent
// reference state without trying to reconcile mixed states across the burst.

struct BurstLabelPickerSheet: View {
    let stack: BurstStack
    @ObservedObject var manager: SDCardManager

    // Local pick state mirrors LabelPickerSheet — prevents sheet dismissal
    // on each tap, and is initialised from the cover photo.
    @State private var pickStatus: PickStatus

    init(stack: BurstStack, manager: SDCardManager) {
        self.stack = stack
        self.manager = manager
        _pickStatus = State(initialValue: stack.coverFile.pickStatus)
    }

    /// Live cover file — drives the star and colour indicator.
    private var liveCover: RAWFile? {
        manager.rawFiles.first { $0.id == stack.coverFile.id }
    }

    var body: some View {
        let cover = liveCover ?? stack.coverFile

        VStack(spacing: 24) {

            // ── Pick row ─────────────────────────────────────────────────
            HStack(spacing: 32) {
                Spacer()

                // Accept all: white fill, black outline
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

                // Reject all: black fill, white outline
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

                // None swatch
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

// MARK: - Burst count badge

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
