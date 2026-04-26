import SwiftUI
import ImageIO

struct RAWFileThumbnailCard: View {
    let file: RAWFile
    @State private var thumbnail: UIImage?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail image area
                GeometryReader { geo in
                    let imgHeight = geo.size.width * 3 / 4   // 4:3 ratio
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
                        if file.isRejected {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 2.5)
                        }
                    }
                    .opacity(file.isRejected ? 0.7 : 1.0)
                }
                .aspectRatio(4/3, contentMode: .fit)   // reserves correct height

                if file.focusStatus != .unanalyzed {
                    FocusBadge(status: file.focusStatus, region: file.focusRegion)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(file.isRejected ? .secondary : .primary)

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
        // Dispatch to background queue — no async/await needed for sync work
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

// MARK: - Focus badge

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
