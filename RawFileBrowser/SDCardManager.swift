import Foundation
import UIKit
import Combine

// MARK: - Pick status

/// Whether the user (or the auto-analysis pass) has accepted or rejected a photo.
/// Separate from focus quality — the user can override the auto-set value.
enum PickStatus: String, Codable {
    case accepted   // white flag (black outline)
    case rejected   // black flag (white outline) + greyed thumbnail
    case unpicked   // no flag shown — not yet decided
}

// MARK: - Label colour

/// A colour label the user can attach to a photo. `.none` means no label.
enum LabelColour: String, Codable, CaseIterable {
    case none
    case red
    case yellow
    case green
    case blue
    case purple
}

// MARK: - RAWFile model

struct RAWFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var size: Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0) ?? 0
    }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var modificationDate: Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    var fileExtension: String { url.pathExtension.uppercased() }

    var focusStatus: FocusStatus = .unanalyzed
    var focusScore: Double = 0
    var focusRegion: FocusResult.AnalysisRegion = .fullImage
    var blurType: BlurType = .unknown
    var subjectSizeConfidence: Double = 0
    var detectedAnimalLabel: String? = nil
    var analysisRect: CGRect? = nil
    var subjectContour: [[CGPoint]] = []
    var detectionConfidence: Float? = nil
    var afOverlapsSubject: Bool? = nil
    var afOnEye: Bool? = nil
    var afNotOnSubject: Bool = false
    var rawSharpnessScore: Double = 0
    var subjectBodyArea: Double = 0
    var scoringRectArea: Double = 0
    var hadAFPoint: Bool = false
    var sharpThreshold: Double = 0
    var acceptableThreshold: Double = 0
    var afPointRawScore: Double? = nil
    var subjectBodyRawScore: Double? = nil
    var ratingBasis: FocusResult.RatingBasis = .fullImage
    var xmpWritten: Bool = false

    // MARK: Pick status
    var pickStatus: PickStatus = .unpicked
    var pickIsOverridden: Bool = false

    // MARK: Star rating & colour label
    var starRating: Int = 0
    var labelColour: LabelColour = .none

    var isRejected: Bool { pickStatus == .rejected }
}

extension RAWFile: Hashable, Equatable {
    static func == (lhs: RAWFile, rhs: RAWFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Burst stack

/// A group of RAWFile objects detected as a continuous burst sequence.
/// `coverFile` is the first photo in the burst and is used as the stack thumbnail.
struct BurstStack: Identifiable {
    let id = UUID()
    var files: [RAWFile]

    var coverFile: RAWFile { files[0] }
    var count: Int { files.count }
}

// MARK: - Grid item

/// Represents one item in the top-level grid — either a single photo or a burst stack.
enum GridItem: Identifiable {
    case single(RAWFile)
    case stack(BurstStack)

    var id: UUID {
        switch self {
        case .single(let f): return f.id
        case .stack(let s):  return s.id
        }
    }
}

// MARK: - Supported RAW extensions

private let rawExtensions: Set<String> = [
    "raw", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "raf", "srw", "dng", "3fr", "fff", "iiq", "rwl",
    "mrw", "x3f", "erf", "kdc", "dcr", "mef", "mos", "ptx"
]

/// Two photos are considered part of the same burst if their timestamps
/// are within this many seconds of each other.
private let burstGapThreshold: TimeInterval = 2.0

// MARK: - SDCardManager

@MainActor
final class SDCardManager: ObservableObject {
    @Published var rawFiles: [RAWFile] = []

    /// The grouped representation used by the top-level grid.
    /// Solo photos appear as `.single`, burst groups as `.stack`.
    /// Rebuilt automatically whenever `rawFiles` is set.
    @Published var gridItems: [GridItem] = []

    @Published var isSDCardMounted: Bool = false
    @Published var isLoading: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var analysisProgress: Double = 0
    @Published var errorMessage: String?

    /// Holds the security-scoped directory URL open for the lifetime of the session.
    private var activeDirectoryURL: URL? {
        didSet {
            oldValue?.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        activeDirectoryURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: Discovery

    func refresh() {
        guard !isSDCardMounted else { return }
        isLoading = true
        errorMessage = nil

        Task {
            let found = scanForRAWFiles()
            rawFiles = found
            gridItems = groupIntoBursts(found)
            if !found.isEmpty { isSDCardMounted = true }
            isLoading = false
        }
    }

    func forceRefresh() {
        activeDirectoryURL = nil
        isSDCardMounted = false
        rawFiles = []
        gridItems = []
        isLoading = true
        errorMessage = nil

        Task {
            let found = scanForRAWFiles()
            rawFiles = found
            gridItems = groupIntoBursts(found)
            isSDCardMounted = !found.isEmpty || detectExternalVolumes()
            isLoading = false
        }
    }

    /// Called by the document picker after the user selects a folder.
    func loadFilesFromDirectory(_ url: URL) {
        activeDirectoryURL = url
        isLoading = true
        errorMessage = nil

        let found = collectRAWFiles(in: url)
        let sorted = found.sorted { $0.name < $1.name }

        isSDCardMounted = true
        rawFiles = sorted
        gridItems = groupIntoBursts(sorted)
        isLoading = false

        if found.isEmpty {
            errorMessage = "No RAW files found in the selected directory."
        }
    }

    // MARK: Focus Analysis

    func analyzeAllFocus() async {
        guard !rawFiles.isEmpty else { return }
        isAnalyzing = true
        analysisProgress = 0

        let total = rawFiles.count
        let batchSize = 4

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            let indices = Array(batchStart..<batchEnd)

            await withTaskGroup(of: (Int, FocusResult).self) { group in
                for i in indices {
                    let url = rawFiles[i].url
                    group.addTask {
                        let result = await FocusAnalyzer.analyze(url: url)
                        return (i, result)
                    }
                }
                for await (i, result) in group {
                    rawFiles[i].focusStatus           = result.status
                    rawFiles[i].focusScore            = result.score
                    rawFiles[i].focusRegion           = result.analysisRegion
                    rawFiles[i].blurType              = result.blurType
                    rawFiles[i].subjectSizeConfidence = result.subjectSizeConfidence
                    rawFiles[i].detectedAnimalLabel   = result.detectedAnimalLabel
                    rawFiles[i].analysisRect          = result.analysisRect
                    rawFiles[i].subjectContour        = result.subjectContour
                    rawFiles[i].detectionConfidence   = result.detectionConfidence
                    rawFiles[i].afOverlapsSubject     = result.afOverlapsSubject
                    rawFiles[i].afOnEye               = result.afOnEye
                    rawFiles[i].rawSharpnessScore     = result.rawSharpnessScore
                    rawFiles[i].subjectBodyArea       = result.subjectBodyArea
                    rawFiles[i].scoringRectArea       = result.scoringRectArea
                    rawFiles[i].hadAFPoint            = result.hadAFPoint
                    rawFiles[i].sharpThreshold        = result.sharpThreshold
                    rawFiles[i].acceptableThreshold   = result.acceptableThreshold
                    rawFiles[i].afPointRawScore       = result.afPointRawScore
                    rawFiles[i].subjectBodyRawScore   = result.subjectBodyRawScore
                    rawFiles[i].ratingBasis           = result.ratingBasis
                    if !rawFiles[i].pickIsOverridden {
                        rawFiles[i].pickStatus = result.status.isRejected ? .rejected : .accepted
                    }
                }
            }

            analysisProgress = Double(batchEnd) / Double(total)
        }

        isAnalyzing = false

        // Rebuild gridItems so stack cover photos reflect updated analysis state
        gridItems = groupIntoBursts(rawFiles)
    }

    func analyzeFocus(for file: RAWFile) async {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let result = await FocusAnalyzer.analyze(url: file.url)
        rawFiles[idx].focusStatus           = result.status
        rawFiles[idx].focusScore            = result.score
        rawFiles[idx].focusRegion           = result.analysisRegion
        rawFiles[idx].blurType              = result.blurType
        rawFiles[idx].subjectSizeConfidence = result.subjectSizeConfidence
        rawFiles[idx].detectedAnimalLabel   = result.detectedAnimalLabel
        rawFiles[idx].analysisRect          = result.analysisRect
        rawFiles[idx].subjectContour        = result.subjectContour
        rawFiles[idx].detectionConfidence   = result.detectionConfidence
        rawFiles[idx].afOverlapsSubject     = result.afOverlapsSubject
        rawFiles[idx].afOnEye               = result.afOnEye
        rawFiles[idx].afNotOnSubject        = result.afNotOnSubject
        rawFiles[idx].rawSharpnessScore     = result.rawSharpnessScore
        rawFiles[idx].subjectBodyArea       = result.subjectBodyArea
        rawFiles[idx].scoringRectArea       = result.scoringRectArea
        rawFiles[idx].hadAFPoint            = result.hadAFPoint
        rawFiles[idx].sharpThreshold        = result.sharpThreshold
        rawFiles[idx].acceptableThreshold   = result.acceptableThreshold
        rawFiles[idx].afPointRawScore       = result.afPointRawScore
        rawFiles[idx].subjectBodyRawScore   = result.subjectBodyRawScore
        rawFiles[idx].ratingBasis           = result.ratingBasis
        if !rawFiles[idx].pickIsOverridden {
            rawFiles[idx].pickStatus = result.status.isRejected ? .rejected : .accepted
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    var rejectedCount: Int { rawFiles.filter { $0.pickStatus == .rejected }.count }

    // MARK: - Pick / rating / label setters

    func setPickStatus(_ status: PickStatus, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].pickStatus = status
        rawFiles[idx].pickIsOverridden = (status != .unpicked)
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Set the same pick status on every file in a burst stack.
    func setPickStatus(_ status: PickStatus, forAllIn stack: BurstStack) {
        for file in stack.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    func setStarRating(_ rating: Int, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].starRating = min(max(rating, 0), 5)
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Set the same star rating on every file in a burst stack.
    func setStarRating(_ rating: Int, forAllIn stack: BurstStack) {
        for file in stack.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    func setLabelColour(_ colour: LabelColour, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].labelColour = colour
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Set the same colour label on every file in a burst stack.
    func setLabelColour(_ colour: LabelColour, forAllIn stack: BurstStack) {
        for file in stack.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].labelColour = colour
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    func markXMPWritten(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].xmpWritten = true
    }

    // MARK: - XMP sidecar writing

    func writeXMP(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        do {
            try XMPSidecarWriter.write(for: file)
            rawFiles[idx].xmpWritten = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func writeXMPBatch() -> String {
        let eligible = rawFiles.filter { $0.detectedAnimalLabel != nil }
        let result   = XMPSidecarWriter.writeBatch(for: eligible)

        for i in rawFiles.indices {
            if rawFiles[i].detectedAnimalLabel != nil && !rawFiles[i].xmpWritten {
                rawFiles[i].xmpWritten = XMPSidecarWriter.sidecarExists(for: rawFiles[i])
            }
        }

        var summary = "\(result.written) XMP file(s) written"
        if result.skipped > 0 { summary += ", \(result.skipped) skipped (no species)" }
        if !result.errors.isEmpty { summary += ", \(result.errors.count) error(s)" }
        return summary
    }

    // MARK: - Burst grouping

    /// Groups a sorted array of RAWFiles into GridItems by comparing consecutive
    /// modification timestamps. Files within `burstGapThreshold` seconds of the
    /// previous file are considered part of the same burst.
    ///
    /// The input should already be sorted by name (which for Canon files is also
    /// chronological order). A secondary sort by modificationDate is applied here
    /// to ensure correctness regardless of how the files were originally sorted.
    private func groupIntoBursts(_ files: [RAWFile]) -> [GridItem] {
        // Sort by modification date so timestamp comparison is meaningful.
        // Files without a date sort to the end and are treated as solo items.
        let sorted = files.sorted {
            let d0 = $0.modificationDate ?? .distantFuture
            let d1 = $1.modificationDate ?? .distantFuture
            return d0 < d1
        }

        var result: [GridItem] = []
        var currentGroup: [RAWFile] = []

        for file in sorted {
            if currentGroup.isEmpty {
                // Start the first group
                currentGroup.append(file)
            } else {
                let lastDate = currentGroup.last!.modificationDate
                let thisDate = file.modificationDate

                // Determine the time gap between this file and the previous one.
                // If either date is missing, treat as a gap > threshold (no grouping).
                let gap: TimeInterval
                if let last = lastDate, let this = thisDate {
                    gap = this.timeIntervalSince(last)
                } else {
                    gap = burstGapThreshold + 1  // force a new group
                }

                if gap <= burstGapThreshold {
                    // Within threshold — same burst
                    currentGroup.append(file)
                } else {
                    // Gap too large — save current group and start a new one
                    result.append(gridItem(from: currentGroup))
                    currentGroup = [file]
                }
            }
        }

        // Don't forget the last group
        if !currentGroup.isEmpty {
            result.append(gridItem(from: currentGroup))
        }

        return result
    }

    /// Converts a group of files into the appropriate GridItem.
    /// A group of 1 is always a solo item. A group of 2+ becomes a stack.
    private func gridItem(from group: [RAWFile]) -> GridItem {
        if group.count == 1 {
            return .single(group[0])
        } else {
            return .stack(BurstStack(files: group))
        }
    }

    // MARK: - Private helpers

    private func collectRAWFiles(in directory: URL) -> [RAWFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let allURLs = enumerator.compactMap { $0 as? URL }
        return allURLs
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { RAWFile(url: $0) }
    }

    private func scanForRAWFiles() -> [RAWFile] {
        var results: [RAWFile] = []
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if let vols = try? FileManager.default.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            for vol in vols { results += collectRAWFiles(in: vol) }
        }
        if let dcim = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .deletingLastPathComponent()
            .appendingPathComponent("Media/DCIM") {
            results += collectRAWFiles(in: dcim)
        }
        return results
    }

    private func detectExternalVolumes() -> Bool {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        return !(contents?.isEmpty ?? true)
    }
}
