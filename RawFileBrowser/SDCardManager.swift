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
    /// Whether the camera AF point overlapped the detected subject.
    /// nil = no AF point or no subject (not applicable).
    /// false = AF point was on the background → missed focus.
    var afOverlapsSubject: Bool? = nil
    /// Whether the AF point specifically overlapped the detected eye region.
    /// nil = no AF point, or no eye detected.
    /// true = AF was on the eye. false = eye found but AF missed it.
    var afOnEye: Bool? = nil
    /// True when analysis found the AF point was NOT on the detected subject.
    /// The sharpness status is determined from the subject body regardless.
    var afNotOnSubject: Bool = false
    // Diagnostic fields — raw values before thresholds are applied
    /// Laplacian variance score BEFORE the size-confidence penalty is applied (0-1 normalised)
    var rawSharpnessScore: Double = 0
    /// Fraction of image area occupied by the subject body rect (0-1)
    var subjectBodyArea: Double = 0
    /// Fraction of image area occupied by the scoring rect (eyes/head/AF point) (0-1)
    var scoringRectArea: Double = 0
    /// Whether a camera AF point was found in the file
    var hadAFPoint: Bool = false
    var sharpThreshold: Double = 0
    var acceptableThreshold: Double = 0
    /// Raw Laplacian score at the AF point rect (Case 5 only — nil otherwise)
    var afPointRawScore: Double? = nil
    /// Raw Laplacian score at the subject body rect (Case 5 only — nil otherwise)
    var subjectBodyRawScore: Double? = nil
    /// Which region drove the final rating
    var ratingBasis: FocusResult.RatingBasis = .fullImage
    var xmpWritten: Bool = false

    // MARK: Pick status
    /// The current accept/reject decision for this photo.
    var pickStatus: PickStatus = .unpicked
    /// True once the user has manually overridden the auto-set pick status.
    var pickIsOverridden: Bool = false

    /// Convenience: true when the photo should be visually treated as rejected.
    var isRejected: Bool { pickStatus == .rejected }
}

extension RAWFile: Hashable, Equatable {
    static func == (lhs: RAWFile, rhs: RAWFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Supported RAW extensions

private let rawExtensions: Set<String> = [
    "raw", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "raf", "srw", "dng", "3fr", "fff", "iiq", "rwl",
    "mrw", "x3f", "erf", "kdc", "dcr", "mef", "mos", "ptx"
]

// MARK: - SDCardManager

@MainActor
final class SDCardManager: ObservableObject {
    @Published var rawFiles: [RAWFile] = []
    @Published var isSDCardMounted: Bool = false
    @Published var isLoading: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var analysisProgress: Double = 0
    @Published var errorMessage: String?

    /// Holds the security-scoped directory URL open for the lifetime of the session.
    /// MUST remain started until the user picks a new directory or the app quits.
    private var activeDirectoryURL: URL? {
        didSet {
            // Stop access on the previous directory when a new one is picked
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
            if !found.isEmpty { isSDCardMounted = true }
            isLoading = false
        }
    }

    func forceRefresh() {
        activeDirectoryURL = nil   // stops security-scoped access on old dir
        isSDCardMounted = false
        rawFiles = []
        isLoading = true
        errorMessage = nil

        Task {
            let found = scanForRAWFiles()
            rawFiles = found
            isSDCardMounted = !found.isEmpty || detectExternalVolumes()
            isLoading = false
        }
    }

    /// Called by the document picker after the user selects a folder.
    /// Security-scoped access has already been started by the coordinator —
    /// we store the URL to keep it open for as long as we need to read files.
    func loadFilesFromDirectory(_ url: URL) {
        // Store BEFORE enumeration — keeps access open for thumbnails and image loads
        activeDirectoryURL = url
        isLoading = true
        errorMessage = nil

        let found = collectRAWFiles(in: url)

        isSDCardMounted = true
        rawFiles = found.sorted { $0.name < $1.name }
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
                    // Auto-set pick status from quality, unless the user has already overridden it
                    if !rawFiles[i].pickIsOverridden {
                        rawFiles[i].pickStatus = result.status.isRejected ? .rejected : .accepted
                    }
                }
            }

            analysisProgress = Double(batchEnd) / Double(total)
        }

        isAnalyzing = false
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
    }

    var rejectedCount: Int { rawFiles.filter { $0.pickStatus == .rejected }.count }

    /// Set the pick status for a file. Marks the override flag so re-analysis won't reset it.
    func setPickStatus(_ status: PickStatus, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].pickStatus = status
        rawFiles[idx].pickIsOverridden = (status != .unpicked)
    }

    func markXMPWritten(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].xmpWritten = true
    }

    // MARK: - XMP sidecar writing

    /// Writes an XMP sidecar for a single file. Called on user request only.
    func writeXMP(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        do {
            try XMPSidecarWriter.write(for: file)
            rawFiles[idx].xmpWritten = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes XMP sidecars for all analysed files that have a species label.
    /// Returns a summary string for display.
    func writeXMPBatch() -> String {
        let eligible = rawFiles.filter { $0.detectedAnimalLabel != nil }
        let result   = XMPSidecarWriter.writeBatch(for: eligible)

        // Mark written files
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
