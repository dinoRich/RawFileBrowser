import SwiftUI
import ImageIO

struct RAWFileThumbnailCard: View {
    let file: RAWFile
    @ObservedObject var manager: SDCardManager
    @State private var thumbnail: UIImage?
    @State private var isLoading = true

    var body: some View {
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
                    .overlay {
                        if file.pickStatus == .accepted {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white, lineWidth: 3)
                        } else if file.pickStatus == .rejected {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.black, lineWidth: 3)
                        }
                    }

                    // ── Bottom-left: quality badge ───────────────────────
                    if file.focusStatus != .unanalyzed,
                       let badge = QualityBadgeInfo(status: file.focusStatus) {
                        QualityBadge(info: badge)
                            .padding(6)
                    }

                    // ── Bottom-right: pick/flag badge ────────────────────
                    if file.pickStatus != .unpicked {
                        PickFlagBadge(status: file.pickStatus)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(6)
                    }
                }
            }
            .aspectRatio(4/3, contentMode: .fit)   // reserves correct height
            // Long-press to change pick status
            .contextMenu {
                Button {
                    manager.setPickStatus(.accepted, for: file)
                } label: {
                    Label("Accept", systemImage: "flag")
                }
                Button {
                    manager.setPickStatus(.rejected, for: file)
                } label: {
                    Label("Reject", systemImage: "flag.fill")
                }
                if file.pickIsOverridden {
                    Button {
                        manager.setPickStatus(.unpicked, for: file)
                    } label: {
                        Label("Clear Pick", systemImage: "xmark.circle")
                    }
                }
            }

            // ── Filename / metadata row ──────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(file.pickStatus == .rejected ? .secondary : .primary)

                HStack {
                    Text(file.fileExtension)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                    Spacer()
                    Text(file.formattedSize)
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

// MARK: - Quality badge
// Only three states are shown: sharp, slightly blurry, blurry.
// missedFocus / possibleMissedFocus / unanalyzed are not shown here.

struct QualityBadgeInfo {
    let systemImage: String
    let color: Color
    let label: String

    /// Returns nil for statuses that don't need a quality badge on the thumbnail.
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
// Accepted: white flag, black outline.
// Rejected: black flag, white outline.

struct PickFlagBadge: View {
    let status: PickStatus

    var body: some View {
        ZStack {
            // Outline layer — contrasting colour, slightly larger
            Image(systemName: "flag.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(status == .accepted ? Color.black : Color.white)

            // Fill layer — the flag colour itself
            Image(systemName: "flag.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(status == .accepted ? Color.white : Color.black)
        }
        .shadow(radius: 1)
        .help(status == .accepted ? "Accepted" : "Rejected")
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
