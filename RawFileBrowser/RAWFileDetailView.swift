import SwiftUI
import ImageIO

struct RAWFileDetailView: View {
    let file: RAWFile
    @ObservedObject var manager: SDCardManager
    @Environment(\.dismiss) private var dismiss

    @State private var fullImage: UIImage?
    @State private var metadata: [String: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showMetadata = false
    @State private var showShareSheet = false
    @State private var usedFallback = false
    @State private var xmpMessage: String? = nil

    // Zoom + pan state
    @State private var scale: CGFloat       = 1.0
    @State private var lastScale: CGFloat   = 1.0
    @State private var offset: CGSize       = .zero
    @State private var lastOffset: CGSize   = .zero

    // Overlay toggles
    @State private var showAnalysisOverlay  = true
    @State private var showAFPointOverlay   = false

    // AF point rect extracted from EXIF (normalised 0-1, top-left origin)
    @State private var afPoints: [CanonAFPoint] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Decoding RAW…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else if let img = fullImage {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .scaleEffect(scale)
                                .offset(offset)
                                // Combined pinch + pan
                                .gesture(
                                    SimultaneousGesture(
                                        MagnificationGesture()
                                            .onChanged { val in
                                                let newScale = max(1.0, lastScale * val)
                                                scale = newScale
                                                // Clamp offset so we don't pan outside bounds
                                                offset = clampedOffset(
                                                    offset: lastOffset,
                                                    scale: newScale,
                                                    containerSize: geo.size,
                                                    imageSize: img.size
                                                )
                                            }
                                            .onEnded { _ in
                                                lastScale  = scale
                                                lastOffset = offset
                                            },
                                        DragGesture()
                                            .onChanged { val in
                                                guard scale > 1.0 else { return }
                                                let proposed = CGSize(
                                                    width:  lastOffset.width  + val.translation.width,
                                                    height: lastOffset.height + val.translation.height
                                                )
                                                offset = clampedOffset(
                                                    offset: proposed,
                                                    scale: scale,
                                                    containerSize: geo.size,
                                                    imageSize: img.size
                                                )
                                            }
                                            .onEnded { _ in
                                                lastOffset = offset
                                            }
                                    )
                                )
                                // Double-tap to toggle zoom
                                .onTapGesture(count: 2) {
                                    withAnimation(.spring(response: 0.35)) {
                                        if scale > 1.0 {
                                            scale      = 1.0
                                            lastScale  = 1.0
                                            offset     = .zero
                                            lastOffset = .zero
                                        } else {
                                            scale     = 3.0
                                            lastScale = 3.0
                                        }
                                    }
                                }

                            // Analysis region overlay
                            if showAnalysisOverlay, let normRect = file.analysisRect {
                                AnalysisRegionOverlay(
                                    normRect: normRect,
                                    imageSize: img.size,
                                    containerSize: geo.size,
                                    region: file.focusRegion,
                                    scale: scale,
                                    offset: offset
                                )
                            }

                            // Camera AF point overlay
                            if showAFPointOverlay, !afPoints.isEmpty {
                                AFPointOverlay(
                                    points: afPoints,
                                    imageSize: img.size,
                                    containerSize: geo.size,
                                    scale: scale,
                                    offset: offset
                                )
                            }
                        }
                    }

                    VStack {
                        Spacer()
                        infoBar
                    }

                } else if let err = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.yellow)
                        Text(err)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {

                    // Analysis region overlay toggle
                    if file.analysisRect != nil {
                        Button {
                            withAnimation { showAnalysisOverlay.toggle() }
                        } label: {
                            Image(systemName: showAnalysisOverlay
                                  ? "viewfinder.circle.fill" : "viewfinder.circle")
                        }.foregroundStyle(.white)
                    }

                    // AF point overlay toggle — only shown when EXIF AF data exists
                    if !afPoints.isEmpty {
                        Button {
                            withAnimation { showAFPointOverlay.toggle() }
                        } label: {
                            Image(systemName: showAFPointOverlay
                                  ? "scope" : "scope")
                                .foregroundStyle(showAFPointOverlay ? .yellow : .white)
                        }
                    }

                    // On-demand focus analysis
                    if file.focusStatus == .unanalyzed {
                        Button {
                            Task { await manager.analyzeFocus(for: file) }
                        } label: {
                            Image(systemName: "wand.and.stars")
                        }.foregroundStyle(.white)
                    }

                    Button { showMetadata.toggle() } label: {
                        Image(systemName: "info.circle")
                    }.foregroundStyle(.white)

                    Button { showShareSheet = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.white)
                    .disabled(fullImage == nil)

                    // Write XMP
                    if file.detectedAnimalLabel != nil {
                        Button {
                            do {
                                try XMPSidecarWriter.write(for: file)
                                manager.markXMPWritten(for: file)
                                xmpMessage = "XMP written for \(file.detectedAnimalLabel ?? "")"
                            } catch {
                                xmpMessage = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: file.xmpWritten ? "tag.fill" : "tag")
                        }
                        .foregroundStyle(file.xmpWritten ? .green : .white)
                    }
                }
            }
            .sheet(isPresented: $showMetadata) {
                MetadataView(fileName: file.name, metadata: metadata)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showShareSheet) {
                if let img = fullImage { ShareSheet(items: [img, file.url]) }
            }
        }
        .alert("XMP Sidecar", isPresented: Binding(
            get: { xmpMessage != nil },
            set: { if !$0 { xmpMessage = nil } }
        )) {
            Button("OK") { xmpMessage = nil }
        } message: {
            Text(xmpMessage ?? "")
        }
        .task { await loadFullImage() }
    }

    // MARK: - Pan clamping

    /// Clamps a proposed offset so the image never reveals black bars
    /// when zoomed in — the image edge always stays at or beyond the container edge.
    private func clampedOffset(offset: CGSize,
                                scale: CGFloat,
                                containerSize: CGSize,
                                imageSize: CGSize) -> CGSize {
        // Compute how much of the image is visible at this scale
        let imageAspect     = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let renderedW, renderedH: CGFloat
        if imageAspect > containerAspect {
            renderedW = containerSize.width
            renderedH = containerSize.width / imageAspect
        } else {
            renderedH = containerSize.height
            renderedW = containerSize.height * imageAspect
        }

        let scaledW = renderedW * scale
        let scaledH = renderedH * scale

        // Maximum allowable offset in each direction
        let maxX = max(0, (scaledW - containerSize.width)  / 2)
        let maxY = max(0, (scaledH - containerSize.height) / 2)

        return CGSize(
            width:  min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }

    // MARK: - Info bar

    @ViewBuilder
    private var infoBar: some View {
        VStack(spacing: 4) {
            if file.focusStatus != .unanalyzed {
                VStack(spacing: 4) {
                    if let label = file.detectedAnimalLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "pawprint.fill")
                            Text(label.capitalized).fontWeight(.medium)
                            if let conf = file.detectionConfidence {
                                Text("YOLO \(Int(conf * 100))%").foregroundStyle(.cyan.opacity(0.7))
                            } else {
                                Text("Vision").foregroundStyle(.cyan.opacity(0.7))
                            }
                        }
                        .font(.caption).foregroundStyle(.cyan)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: file.focusStatus.systemImage)
                            .foregroundStyle(Color(file.focusStatus.color))
                        Text(file.focusStatus.rawValue).fontWeight(.medium)
                        Text("·")
                        Text(file.focusRegion.rawValue).foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    if file.focusStatus != .sharp {
                        HStack(spacing: 6) {
                            if file.blurType != .none && file.blurType != .unknown {
                                Label(file.blurType.rawValue,
                                      systemImage: file.blurType == .motionBlur
                                          ? "arrow.left.and.right" : "scope")
                                    .foregroundStyle(.orange)
                            }
                            if file.subjectSizeConfidence < 0.7 {
                                Label("Small subject",
                                      systemImage: "minus.magnifyingglass")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .font(.caption2)
                    }
                }
            }

            if usedFallback {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Showing embedded JPEG — RAW decode not supported for this camera on iOS")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            // Pan hint — shown only when zoomed in
            if scale > 1.01 {
                Text("Drag to pan")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    // MARK: - Image loading

    private func loadFullImage() async {
        isLoading = true
        let url   = file.url

        // Diagnostic — remove once AF points are confirmed working
        await Task.detached(priority: .background) {
            CanonMakernoteDiagnostic.dump(url: url)
        }.value

        // Extract Canon AF points via Makernote parser
        let extractedPoints: [CanonAFPoint] = await Task.detached(priority: .userInitiated) {
            CanonMakernoteParser.extractAFPoints(from: url) ?? []
        }.value
        afPoints = extractedPoints

        let result = await Task.detached(priority: .userInitiated) {
            RAWImageLoader.load(from: url)
        }.value

        fullImage    = result.image
        metadata     = result.metadata
        loadError    = result.error
        usedFallback = result.usedFallback
        isLoading    = false
    }
}


// MARK: - AF Point Overlay

/// Draws Canon AF points parsed from the Makernote.
/// In-focus points are shown in green, others in white.
struct AFPointOverlay: View {
    let points: [CanonAFPoint]
    let imageSize: CGSize
    let containerSize: CGSize
    let scale: CGFloat
    let offset: CGSize

    private var imageFrame: CGRect {
        let ia = imageSize.width / imageSize.height
        let ca = containerSize.width / containerSize.height
        let rw, rh: CGFloat
        if ia > ca { rw = containerSize.width;  rh = rw / ia }
        else        { rh = containerSize.height; rw = rh * ia }
        return CGRect(
            x: (containerSize.width  - rw) / 2,
            y: (containerSize.height - rh) / 2,
            width: rw, height: rh
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                let r = imageFrame.projectedToScreen(
                    normRect: point.normRect, scale: scale, offset: offset)
                let color: Color = point.isInFocus ? .green : .white.opacity(0.6)
                let arm = max(6, min(r.width, r.height) * 0.35)
                AFBrackets(rect: r, color: color, armLength: arm,
                           lineWidth: point.isInFocus ? 2.0 : 1.0)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct AFBrackets: View {
    let rect: CGRect
    let color: Color
    let armLength: CGFloat
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, _ in
            func corner(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y + dy))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx, y: y))
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth))
            }
            let arm = armLength
            corner(x: rect.minX, y: rect.minY,  dx:  arm, dy:  arm)
            corner(x: rect.maxX, y: rect.minY,  dx: -arm, dy:  arm)
            corner(x: rect.minX, y: rect.maxY,  dx:  arm, dy: -arm)
            corner(x: rect.maxX, y: rect.maxY,  dx: -arm, dy: -arm)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Metadata sheet

struct MetadataView: View {
    let fileName: String
    let metadata: [String: String]
    @State private var searchText = ""

    private var filtered: [(String, String)] {
        let sorted = metadata.sorted { $0.key < $1.key }
        guard !searchText.isEmpty else { return sorted.map { ($0.key, $0.value) } }
        return sorted
            .filter { $0.key.localizedCaseInsensitiveContains(searchText) ||
                      $0.value.localizedCaseInsensitiveContains(searchText) }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.0) { key, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.subheadline).textSelection(.enabled)
                }
            }
            .searchable(text: $searchText, prompt: "Search metadata")
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - CGRect screen projection helper

extension CGRect {
    /// Projects a normalised (0-1) rect onto screen coordinates,
    /// accounting for letterboxing, zoom scale and pan offset.
    func projectedToScreen(normRect: CGRect, scale: CGFloat, offset: CGSize) -> CGRect {
        let cx = midX, cy = midY
        let scaledW = width  * scale
        let scaledH = height * scale
        let originX = cx - scaledW / 2 + offset.width
        let originY = cy - scaledH / 2 + offset.height

        return CGRect(
            x: originX + normRect.minX * scaledW,
            y: originY + normRect.minY * scaledH,
            width:  normRect.width  * scaledW,
            height: normRect.height * scaledH
        )
    }
}
