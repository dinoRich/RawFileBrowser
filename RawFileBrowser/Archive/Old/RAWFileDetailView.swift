import SwiftUI
import ImageIO

struct RAWFileDetailView: View {
    // ── Inputs ───────────────────────────────────────────────────────────
    /// The ordered list of file IDs the user can swipe through.
    let fileIDs: [UUID]
    /// Index into fileIDs to open first.
    let startIndex: Int
    @ObservedObject var manager: SDCardManager
    @EnvironmentObject var settings: AppSettings
    /// Called when Done is tapped, passing the UUID of the photo last on screen.
    var onDismiss: (UUID) -> Void = { _ in }

    // ── Current position ─────────────────────────────────────────────────
    /// Tracks which photo is currently displayed. Swiping updates this.
    @State private var currentIndex: Int

    private var currentFileID: UUID { fileIDs[currentIndex] }

    private var file: RAWFile {
        manager.rawFiles.first(where: { $0.id == currentFileID })
            ?? RAWFile(url: URL(fileURLWithPath: ""))
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
    @State private var showLabelSheet  = false
    @State private var showOverflowMenu = false

    // Zoom + pan state
    @State private var scale: CGFloat       = 1.0
    @State private var lastScale: CGFloat   = 1.0
    @State private var offset: CGSize       = .zero
    @State private var lastOffset: CGSize   = .zero
    // Zoom percentage indicator
    @State private var showZoomIndicator: Bool = false
    @State private var zoomHideTask: Task<Void, Never>? = nil

    // Overlay toggles
    @State private var showAnalysisOverlay  = true
    @State private var showAFPointOverlay   = true

    // AF point rect extracted from EXIF (normalised 0-1, top-left origin)
    @State private var afPoints: [CanonAFPoint] = []

    // ── Initialiser ──────────────────────────────────────────────────────
    init(fileIDs: [UUID],
         startIndex: Int,
         manager: SDCardManager,
         onDismiss: @escaping (UUID) -> Void = { _ in }) {
        self.fileIDs    = fileIDs
        self.startIndex = startIndex
        self.manager    = manager
        self.onDismiss  = onDismiss
        // @State must be initialised via _varName in an init
        _currentIndex   = State(initialValue: startIndex)
    }

    // ── Convenience init for single-file callers (backwards compatibility) ──
    /// Opens a single file with no swipe neighbours and no dismiss callback.
    init(fileID: UUID, manager: SDCardManager) {
        self.init(fileIDs: [fileID], startIndex: 0, manager: manager)
    }

    // MARK: - Body

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
                                // Combined pinch + pan + swipe navigation
                                .gesture(
                                    SimultaneousGesture(
                                        MagnificationGesture()
                                            .onChanged { val in
                                                let newScale = max(1.0, lastScale * val)
                                                scale = newScale
                                                offset = clampedOffset(
                                                    offset: lastOffset,
                                                    scale: newScale,
                                                    containerSize: geo.size,
                                                    imageSize: img.size
                                                )
                                                showZoomIndicator = true
                                                zoomHideTask?.cancel()
                                                zoomHideTask = Task {
                                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                                    if !Task.isCancelled {
                                                        withAnimation { showZoomIndicator = false }
                                                    }
                                                }
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
                                // Swipe left / right to navigate (only when not zoomed in)
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 40)
                                        .onEnded { val in
                                            // Only act when the image is at normal zoom;
                                            // at zoom > 1 the drag gesture above handles panning.
                                            guard scale <= 1.0 else { return }
                                            let horizontal = val.translation.width
                                            let vertical   = abs(val.translation.height)
                                            // Require the swipe to be more horizontal than vertical
                                            guard abs(horizontal) > vertical else { return }
                                            if horizontal < 0 {
                                                // Swipe left → next photo
                                                navigateTo(currentIndex + 1)
                                            } else {
                                                // Swipe right → previous photo
                                                navigateTo(currentIndex - 1)
                                            }
                                        }
                                )
                                // Double-tap → 50% actual size centred on tap point (or reset)
                                .gesture(
                                    SpatialTapGesture(count: 2)
                                        .onEnded { tap in
                                            let imageAspect     = img.size.width / img.size.height
                                            let containerAspect = geo.size.width / geo.size.height
                                            let fitRenderedW: CGFloat = imageAspect > containerAspect
                                                ? geo.size.width
                                                : geo.size.height * imageAspect
                                            let fitFactor = fitRenderedW / img.size.width
                                            let target50 = max(1.0, 0.5 / fitFactor)
                                            withAnimation(.spring(response: 0.35)) {
                                                if scale > 1.0 {
                                                    scale      = 1.0
                                                    lastScale  = 1.0
                                                    offset     = .zero
                                                    lastOffset = .zero
                                                } else {
                                                    let cx = geo.size.width  / 2
                                                    let cy = geo.size.height / 2
                                                    let newOffset = CGSize(
                                                        width:  (cx - tap.location.x) * (target50 - 1),
                                                        height: (cy - tap.location.y) * (target50 - 1)
                                                    )
                                                    scale      = target50
                                                    lastScale  = target50
                                                    offset     = clampedOffset(
                                                        offset: newOffset,
                                                        scale: target50,
                                                        containerSize: geo.size,
                                                        imageSize: img.size
                                                    )
                                                    lastOffset = offset
                                                }
                                            }
                                            showZoomIndicator = true
                                            zoomHideTask?.cancel()
                                            zoomHideTask = Task {
                                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                                if !Task.isCancelled {
                                                    withAnimation { showZoomIndicator = false }
                                                }
                                            }
                                        }
                                )
                                // Triple-tap → 100% actual size centred on tap point (or reset)
                                .gesture(
                                    SpatialTapGesture(count: 3)
                                        .onEnded { tap in
                                            let imageAspect     = img.size.width / img.size.height
                                            let containerAspect = geo.size.width / geo.size.height
                                            let fitRenderedW: CGFloat = imageAspect > containerAspect
                                                ? geo.size.width
                                                : geo.size.height * imageAspect
                                            let fitFactor = fitRenderedW / img.size.width
                                            let target100 = max(1.0, 1.0 / fitFactor)
                                            withAnimation(.spring(response: 0.35)) {
                                                if scale >= target100 * 0.95 {
                                                    scale      = 1.0
                                                    lastScale  = 1.0
                                                    offset     = .zero
                                                    lastOffset = .zero
                                                } else {
                                                    let cx = geo.size.width  / 2
                                                    let cy = geo.size.height / 2
                                                    let newOffset = CGSize(
                                                        width:  (cx - tap.location.x) * (target100 - 1),
                                                        height: (cy - tap.location.y) * (target100 - 1)
                                                    )
                                                    scale      = target100
                                                    lastScale  = target100
                                                    offset     = clampedOffset(
                                                        offset: newOffset,
                                                        scale: target100,
                                                        containerSize: geo.size,
                                                        imageSize: img.size
                                                    )
                                                    lastOffset = offset
                                                }
                                            }
                                            showZoomIndicator = true
                                            zoomHideTask?.cancel()
                                            zoomHideTask = Task {
                                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                                if !Task.isCancelled {
                                                    withAnimation { showZoomIndicator = false }
                                                }
                                            }
                                        }
                                )

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
                                    detectedLabel: settings.visibleSpeciesLabel(
                                        label: file.detectedAnimalLabel,
                                        confidence: file.detectionConfidence,
                                        subjectBodyArea: file.subjectBodyArea
                                    )
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

                            // Zoom percentage badge — centred, shown briefly after zoom change.
                            // Percentage is relative to actual image pixel size:
                            //   100% = one screen point per image point.
                            if showZoomIndicator {
                                let imageAspect     = img.size.width / img.size.height
                                let containerAspect = geo.size.width / geo.size.height
                                let fitRenderedW: CGFloat = imageAspect > containerAspect
                                    ? geo.size.width
                                    : geo.size.height * imageAspect
                                let fitFactor = fitRenderedW / img.size.width
                                let actualPct = Int((fitFactor * scale * 100).rounded())
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Text("\(actualPct)%")
                                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(.black.opacity(0.55))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Spacer()
                                    }
                                    Spacer()
                                }
                                .allowsHitTesting(false)
                                .transition(.opacity)
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
            .toolbarBackground(Color.black.opacity(0.75), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss(currentFileID)
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }

                // ── Photo counter (e.g. "3 / 12") ───────────────────────
                if fileIDs.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Text("\(currentIndex + 1) / \(fileIDs.count)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {

                    // ── 1. Focus Analyser — leftmost (circle.dashed, matches grid view) ─
                    Button {
                        Task { await manager.analyzeFocus(for: file) }
                    } label: {
                        Image(systemName: "circle.dashed")
                    }
                    .foregroundStyle(file.focusStatus == .unanalyzed ? .white : .white.opacity(0.4))
                    .disabled(file.focusStatus != .unanalyzed)

                    // ── 2. AF point overlay toggle — inverted colours when ON ──────────
                    if !afPoints.isEmpty {
                        Button {
                            withAnimation { showAFPointOverlay.toggle() }
                        } label: {
                            Image(systemName: showAFPointOverlay
                                  ? "viewfinder.circle.fill" : "viewfinder.circle")
                                .padding(5)
                                .background(showAFPointOverlay ? Color.white : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(showAFPointOverlay ? .black : .white)
                        }
                    }

                    // ── 3. Diagnostics (stethoscope) ─────────────────────────────────
                    Button { showDiagnostics.toggle() } label: {
                        Image(systemName: "stethoscope")
                    }
                    .foregroundStyle(file.focusStatus != .unanalyzed ? .white : .white.opacity(0.4))
                    .disabled(file.focusStatus == .unanalyzed)

                    // ── 4. Overflow menu — secondary actions ─────────────────────────
                    Button {
                        showOverflowMenu = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.white)
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
            .sheet(isPresented: $showLabelSheet) {
                LabelPickerSheet(file: file, manager: manager)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
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
        .confirmationDialog("", isPresented: $showOverflowMenu, titleVisibility: .hidden) {
            Button("Metadata") { showMetadata = true }
            if fullImage != nil {
                Button("Share") { showShareSheet = true }
            }
            if settings.visibleSpeciesLabel(label: file.detectedAnimalLabel, confidence: file.detectionConfidence, subjectBodyArea: file.subjectBodyArea) != nil {
                Button(file.xmpWritten ? "XMP Already Written" : "Write XMP") {
                    if !file.xmpWritten {
                        do {
                            try XMPSidecarWriter.write(for: file)
                            manager.markXMPWritten(for: file)
                            xmpMessage = "XMP written for \(file.detectedAnimalLabel ?? String())"
                        } catch {
                            xmpMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(file.xmpWritten)
            }
            Button(file.pickStatus != .unpicked ? "Change Flag" : "Set Flag") {
                showLabelSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: currentFileID) {
            // Reload the image every time currentFileID changes (i.e. after a swipe)
            await loadFullImage()
        }
    }

    // MARK: - Swipe navigation

    /// Moves to a new index, resetting zoom/pan and reloading the image.
    private func navigateTo(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < fileIDs.count else { return }
        // Reset zoom so the new photo starts at fit-to-screen
        scale      = 1.0
        lastScale  = 1.0
        offset     = .zero
        lastOffset = .zero
        currentIndex = newIndex
        // The .task(id: currentFileID) above will automatically re-fire
        // and call loadFullImage() because currentFileID has changed.
    }

    // MARK: - Pan clamping

    private func clampedOffset(offset: CGSize,
                                scale: CGFloat,
                                containerSize: CGSize,
                                imageSize: CGSize) -> CGSize {
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

            // ── Label status strip: flag · stars · colour ────────────────
            // Always visible. Tapping opens the LabelPickerSheet.
            // Items dim when unset so the strip is always a clear tap target.
            Button { showLabelSheet = true } label: {
                HStack(spacing: 12) {

                    // Pick flag — two-tone when set, dim outline when not
                    if file.pickStatus != .unpicked {
                        PickFlagBadge(status: file.pickStatus)
                    } else {
                        Image(systemName: "flag")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    // Stars — filled yellow when set, dim outlines when not
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { n in
                            Image(systemName: n <= file.starRating ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(n <= file.starRating
                                    ? Color.yellow
                                    : Color.white.opacity(0.25))
                        }
                    }

                    // Colour swatch — filled when set, dim ring when not
                    if let swatchColor = file.labelColour.swiftUIColor {
                        Circle()
                            .fill(swatchColor)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(.regularMaterial).padding(-2))
                            .shadow(radius: 1)
                    } else {
                        Circle()
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .buttonStyle(.plain)
            if file.focusStatus != .unanalyzed || file.detectedAnimalLabel != nil {
                VStack(spacing: 5) {
                    if let label = settings.visibleSpeciesLabel(label: file.detectedAnimalLabel, confidence: file.detectionConfidence, subjectBodyArea: file.subjectBodyArea) {
                        HStack(spacing: 4) {
                            Image(systemName: "pawprint.fill")
                            Text(label.replacingOccurrences(of: "_", with: " ").capitalized)
                                .fontWeight(.medium)
                            if let conf = file.detectionConfidence {
                                Text("\(Int(conf * 100))%").foregroundStyle(.cyan.opacity(0.7))
                            } else {
                                Text("Vision").foregroundStyle(.cyan.opacity(0.7))
                            }
                        }
                        .font(.subheadline).foregroundStyle(.cyan)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(Color(file.focusStatus.color))
                        Text(file.focusStatus.rawValue).fontWeight(.medium)
                        Text("·")
                        Text(file.focusRegion.rawValue).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    // "AF not on subject" warning — shown regardless of sharpness
                    if file.afNotOnSubject {
                        HStack(spacing: 6) {
                            Label("AF not on subject",
                                  systemImage: "scope")
                                .foregroundStyle(.purple)
                        }
                        .font(.caption)
                    }

                    if file.focusStatus != .sharp {
                        HStack(spacing: 6) {
                            if file.blurType != .none && file.blurType != .unknown {
                                let blurLabel = file.blurType == .mixed
                                    ? "Mixed (motion + defocus)"
                                    : file.blurType.rawValue
                                Label(blurLabel,
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
                        .font(.caption)
                    }


                }
            }

            // ISO and shutter warnings — only shown for blurry photos where
            // they may be contributing causes. Not shown for sharp photos.
            let isBlurry = file.focusStatus == .slightlyBlur || file.focusStatus == .blurry
            if isBlurry {

                // ISO noise indicator — only if high enough to contribute to blur
                if let iso = isoValue {
                    let level = classifyISO(iso)
                    if level != .low {
                        HStack(spacing: 6) {
                            Image(systemName: level.systemImage)
                                .foregroundStyle(level.color)
                            Text("ISO \(iso)")
                                .fontWeight(.medium)
                            Text("·")
                            Text(level.label)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                // Shutter speed indicator — only if slow enough to contribute to blur
                if let shutter = shutterSpeedSeconds {
                    let level = classifyShutter(shutter, focalLength: focalLengthMM)
                    if level != .fast {
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
                        .font(.caption)
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

            // Exposure histogram
            if let img = fullImage {
                HistogramView(image: img)
                    .frame(height: 40)
                    .padding(.top, 2)
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
        if let fl = focalLengthMM {
            items.append(ExposureItem(label: "FOCAL", value: "\(Int(fl))mm"))
        }
        return items
    }

    // MARK: - Metadata helpers

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

    // MARK: - ISO noise assessment

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
        isLoading    = true
        fullImage    = nil
        loadError    = nil
        afPoints     = []

        let url = file.url

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
                let color: Color = point.isInFocus ? .green : .red
                let arm = max(6, min(r.width, r.height) * 0.35)
                AFBrackets(rect: r, color: color, armLength: arm,
                           lineWidth: point.isInFocus ? 2.0 : 1.5)
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

// MARK: - Exposure Histogram

/// A simple luminance histogram rendered from the loaded image.
/// Samples a small downscaled copy of the image for speed, then
/// renders 256 bars from black (left) to white (right).
struct HistogramView: View {
    let image: UIImage

    private var buckets: [CGFloat] {
        guard let cgImage = image.cgImage else { return Array(repeating: 0, count: 256) }
        let width  = cgImage.width
        let height = cgImage.height
        let scale  = min(1.0, 200.0 / Double(width))
        let sw     = max(1, Int(Double(width)  * scale))
        let sh     = max(1, Int(Double(height) * scale))
        let bytesPerRow = sw * 4
        var data   = [UInt8](repeating: 0, count: sh * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: sw, height: sh,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Array(repeating: 0, count: 256) }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var counts = [Int](repeating: 0, count: 256)
        for py in 0..<sh {
            for px in 0..<sw {
                let base = py * bytesPerRow + px * 4
                let r = Double(data[base])
                let g = Double(data[base + 1])
                let b = Double(data[base + 2])
                // Standard luminance weighting (ITU-R BT.709)
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                counts[min(255, Int(lum))] += 1
            }
        }
        let maxCount = counts.max() ?? 1
        return counts.map { CGFloat($0) / CGFloat(maxCount) }
    }

    var body: some View {
        Canvas { ctx, size in
            let b = buckets
            let barW = size.width / CGFloat(b.count)
            for (i, height) in b.enumerated() {
                let barH = height * size.height
                let rect = CGRect(
                    x: CGFloat(i) * barW,
                    y: size.height - barH,
                    width: max(1, barW - 0.5),
                    height: barH
                )
                ctx.fill(Path(rect), with: .color(.white.opacity(0.75)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - CGRect screen projection helper

extension CGRect {
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

        let screenSize = normRect.width * scaledW
        let screenX    = originX + normRect.minX * scaledW
        let screenCY   = originY + normRect.midY * scaledH

        return CGRect(x: screenX,
                      y: screenCY - screenSize / 2,
                      width:  screenSize,
                      height: screenSize)
    }
}
