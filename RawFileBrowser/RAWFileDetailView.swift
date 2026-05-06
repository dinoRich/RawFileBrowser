import SwiftUI
import ImageIO

struct RAWFileDetailView: View {
    let fileID: UUID
    @ObservedObject var manager: SDCardManager

    private var file: RAWFile {
        manager.rawFiles.first(where: { $0.id == fileID }) ?? RAWFile(url: URL(fileURLWithPath: ""))
    }
    
    @Environment(\.dismiss) private var dismiss

    @State private var fullImage: UIImage?
    @State private var metadata: [String: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showMetadata = false
    @State private var showShareSheet = false
    @State private var usedFallback = false
    @State private var xmpMessage: String? = nil
    @State private var showDiagnostics = false

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
                                    offset: offset,
                                    subjectContour: file.subjectContour,
                                    detectedLabel: file.detectedAnimalLabel
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

                            // Exposure badge — top-left corner, always visible
                            exposureBadge
                                .padding(10)
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

                    Button { showDiagnostics.toggle() } label: {
                        Image(systemName: "stethoscope")
                    }
                    .foregroundStyle(file.focusStatus != .unanalyzed ? .white : .white.opacity(0.4))
                    .disabled(file.focusStatus == .unanalyzed)

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
            .sheet(isPresented: $showDiagnostics) {
                FocusDiagnosticView(file: file)
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
                            if file.focusStatus == .missedFocus {
                                Label("AF point missed subject",
                                      systemImage: "scope")
                                    .foregroundStyle(.purple)
                            } else {
                                if file.blurType != .none && file.blurType != .unknown {
                                    Label(file.blurType.rawValue,
                                          systemImage: file.blurType == .motionBlur
                                              ? "arrow.left.and.right" : "scope")
                                        .foregroundStyle(.orange)
                                }
                                if file.subjectSizeConfidence < 0.4 {
                                    Label("Small subject",
                                          systemImage: "minus.magnifyingglass")
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                        .font(.caption2)
                    }

                    // AF-on-eye indicator — shown whenever an eye was detected,
                    // regardless of overall sharpness result
                    if let afOnEye = file.afOnEye {
                        HStack(spacing: 4) {
                            Image(systemName: afOnEye
                                  ? "eye.circle.fill"
                                  : "eye.trianglebadge.exclamationmark")
                                .foregroundStyle(afOnEye ? .green : .orange)
                            Text(afOnEye ? "AF on eye" : "AF missed eye")
                                .foregroundStyle(afOnEye ? .green : .orange)
                        }
                        .font(.caption2)
                    }
                }
            }

            // ISO noise indicator
            if let iso = isoValue {
                let level = classifyISO(iso)
                HStack(spacing: 6) {
                    Image(systemName: level.systemImage)
                        .foregroundStyle(level.color)
                    Text("ISO \(iso)")
                        .fontWeight(.medium)
                    Text("·")
                    Text(level.label)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }

            // Shutter speed indicator
            if let shutter = shutterSpeedSeconds {
                let level = classifyShutter(shutter, focalLength: focalLengthMM)
                HStack(spacing: 6) {
                    Image(systemName: level.systemImage)
                        .foregroundStyle(level.color)
                    Text(formatShutter(shutter))
                        .fontWeight(.medium)
                    if let fl = focalLengthMM {
                        Text("@ \(Int(fl))mm")
                            .foregroundStyle(.secondary)
                    }
                    Text("·")
                    Text(level.label)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
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

    // MARK: - Exposure badge (top-left overlay)

    @ViewBuilder
    private var exposureBadge: some View {
        let items = exposureBadgeItems
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.label) { item in
                    VStack(spacing: 1) {
                        Text(item.value)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(item.label)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
        }
    }

    private struct ExposureItem {
        let label: String
        let value: String
    }

    private var exposureBadgeItems: [ExposureItem] {
        var items: [ExposureItem] = []
        if let f = apertureValue {
            items.append(ExposureItem(label: "APERTURE", value: "f/\(f)"))
        }
        if let s = shutterSpeedSeconds {
            items.append(ExposureItem(label: "SHUTTER", value: formatShutter(s)))
        }
        if let iso = isoValue {
            items.append(ExposureItem(label: "ISO", value: "\(iso)"))
        }
        return items
    }

    // MARK: - ISO noise assessment

    /// Look up a metadata value by trying exact keys first, then suffix-matching
    /// the nested "{Exif} > Key" format that RAWImageLoader produces on this device.
    private func metadataValue(for keys: String...) -> String? {
        for key in keys {
            if let v = metadata[key] { return v }
            for (k, v) in metadata where k.hasSuffix("> \(key)") { return v }
        }
        return nil
    }

    private var isoValue: Int? {
        if let raw = metadataValue(for: "ISOSpeed", "ISOSpeedRatings", "PhotographicSensitivity"),
           let val = Int(raw) {
            return val
        }
        return nil
    }

    private enum ISOLevel {
        case low, moderate, high, veryHigh

        var label: String {
            switch self {
            case .low:      return "Low ISO — noise unlikely"
            case .moderate: return "Moderate ISO — minor noise possible"
            case .high:     return "High ISO — noise may reduce sharpness"
            case .veryHigh: return "Very high ISO — noise likely affecting sharpness"
            }
        }

        var color: Color {
            switch self {
            case .low:      return .green
            case .moderate: return .yellow
            case .high:     return .orange
            case .veryHigh: return .red
            }
        }

        var systemImage: String {
            switch self {
            case .low:      return "checkmark.circle"
            case .moderate: return "exclamationmark.triangle"
            case .high:     return "exclamationmark.triangle.fill"
            case .veryHigh: return "xmark.octagon.fill"
            }
        }
    }

    /// Classify ISO for Canon APS-C cameras (7D MkII, R7).
    private func classifyISO(_ iso: Int) -> ISOLevel {
        switch iso {
        case ..<800:       return .low
        case 800..<3200:   return .moderate
        case 3200..<12800: return .high
        default:           return .veryHigh
        }
    }

    // MARK: - Shutter speed assessment

    /// Returns shutter speed as decimal seconds (e.g. 0.002 for 1/500s).
    private var shutterSpeedSeconds: Double? {
        guard let raw = metadataValue(for: "ExposureTime", "Exposure Time") else { return nil }
        return Double(raw)
    }

    /// Returns focal length in mm.
    private var focalLengthMM: Double? {
        guard let raw = metadataValue(for: "FocalLength", "Focal Length") else { return nil }
        return Double(raw)
    }

    /// Returns aperture as a formatted string (e.g. "6.3").
    private var apertureValue: String? {
        guard let raw = metadataValue(for: "FNumber", "F Number", "ApertureValue") else { return nil }
        guard let f = Double(raw) else { return nil }
        return f.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(f))
            : String(format: "%.1f", f)
    }

    private enum ShutterLevel {
        case fast, adequate, marginal, slow

        var label: String {
            switch self {
            case .fast:     return "Fast — motion blur unlikely"
            case .adequate: return "Adequate — may show subject motion"
            case .marginal: return "Marginal — likely cause of blur"
            case .slow:     return "Slow — motion blur very likely"
            }
        }

        var color: Color {
            switch self {
            case .fast:     return .green
            case .adequate: return .yellow
            case .marginal: return .orange
            case .slow:     return .red
            }
        }

        var systemImage: String {
            switch self {
            case .fast:     return "checkmark.circle"
            case .adequate: return "exclamationmark.triangle"
            case .marginal: return "exclamationmark.triangle.fill"
            case .slow:     return "xmark.octagon.fill"
            }
        }
    }

    /// Classify shutter speed for wildlife photography.
    /// Uses focal length to set the camera-shake floor (1/focal length rule).
    private func classifyShutter(_ seconds: Double, focalLength: Double?) -> ShutterLevel {
        let effectiveFocal = focalLength ?? 400.0
        let shakeFloor     = 1.0 / effectiveFocal

        let fastThreshold:     Double = 1.0 / 1000.0
        let adequateThreshold: Double = 1.0 / 500.0

        switch seconds {
        case ...fastThreshold:
            return .fast
        case ...adequateThreshold:
            return .adequate
        case ...max(adequateThreshold, shakeFloor * 2):
            return .marginal
        default:
            return .slow
        }
    }

    /// Formats a shutter speed in seconds as a human-readable string.
    private func formatShutter(_ seconds: Double) -> String {
        if seconds < 1.0 {
            let denom = Int((1.0 / seconds).rounded())
            return "1/\(denom)s"
        } else {
            return String(format: "%.1fs", seconds)
        }
    }

    // MARK: - Image loading

    private func loadFullImage() async {
        isLoading = true
        let url   = file.url

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
                let r = imageFrame.projectedToScreenAFPoint(
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
    func projectedToScreenAFPoint(normRect: CGRect, scale: CGFloat, offset: CGSize) -> CGRect {
        let cx = midX, cy = midY
        let scaledW = width  * scale
        let scaledH = height * scale
        let originX = cx - scaledW / 2 + offset.width
        let originY = cy - scaledH / 2 + offset.height

        // The AF point is physically square on the sensor.
        // normW was normalised against sensor width; use it for both axes
        // so the bracket displays as a square regardless of image orientation.
        let screenSize = normRect.width * scaledW
        let screenX    = originX + normRect.minX * scaledW
        let screenCY   = originY + normRect.midY * scaledH   // Y centre uses scaledH (correct)

        return CGRect(x: screenX,
                      y: screenCY - screenSize / 2,
                      width:  screenSize,
                      height: screenSize)
    }

}
/// Projects AF point normRects where both width and height were normalised
/// against sensor width, so both axes must scale against scaledW to stay square.
