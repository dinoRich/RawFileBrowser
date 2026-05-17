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

    // Stored once at init — never re-read from disk.
    // modificationDate is accessed O(N log N) times during burst grouping sort,
    // so a computed property hitting the filesystem each time is expensive.
    let name: String
    let fileExtension: String
    let modificationDate: Date?
    let size: Int64

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    init(url: URL) {
        self.url              = url
        self.name             = url.lastPathComponent
        self.fileExtension    = url.pathExtension.uppercased()
        let rv                = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.modificationDate = rv?.contentModificationDate
        self.size             = Int64(rv?.fileSize ?? 0)
    }

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

    // MARK: Perceptual hash
    /// 64-bit perceptual hash computed from the embedded JPEG preview.
    /// nil until computeSimilarGroups() has run. Used for near-duplicate detection.
    var pHash: UInt64? = nil

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
    /// Assigned once from ContentView.onAppear. The manager reads from this
    /// directly whenever analysis runs, so it always sees current values.
    var settings: AppSettings?

    @Published var rawFiles: [RAWFile] = []

    /// The grouped representation used by the top-level grid.
    /// Solo photos appear as `.single`, burst groups as `.stack`.
    /// Rebuilt automatically whenever `rawFiles` is set.
    @Published var gridItems: [GridItem] = []

    /// Groups of near-duplicate photos detected by perceptual hash comparison.
    /// Only populated after computeSimilarGroups() has been called.
    /// Each group contains 2+ files whose pHash Hamming distance is within
    /// PHasher.similarityThreshold (≤10 differing bits out of 64).
    @Published var similarGroups: [SimilarGroup] = []

    /// True while pHash computation is running.
    @Published var isComputingSimilar: Bool = false

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
        similarGroups = []
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
        similarGroups = []
        isLoading = false

        if found.isEmpty {
            errorMessage = "No RAW files found in the selected directory."
        }
    }

    // MARK: Focus Analysis

    private var analysisCancelled = false

    func cancelAnalysis() {
        analysisCancelled = true
    }

    func analyzeAllFocus() async {
        guard !rawFiles.isEmpty else { return }
        isAnalyzing = true
        analysisCancelled = false
        analysisProgress = 0

        let sharpen = settings?.sharpenIntensity ?? 0.4

        let total = rawFiles.count
        let batchSize = 4

        for batchStart in stride(from: 0, to: total, by: batchSize) {

            // Stop between batches if the user cancelled
            if analysisCancelled { break }

            let batchEnd = min(batchStart + batchSize, total)
            let indices = Array(batchStart..<batchEnd)

            await withTaskGroup(of: (Int, FocusResult).self) { group in
                for i in indices {
                    let url = rawFiles[i].url
                    group.addTask {
                        let result = await FocusAnalyzer.analyze(url: url, sharpenIntensity: sharpen)
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
                        resetOutcomeFields(at: i)
                        if let action = settings?.action(for: result.status) {
                            applyOutcomeAction(action, to: i)
                        }
                    }
                }
            }

            analysisProgress = Double(batchEnd) / Double(total)
        }

        isAnalyzing = false
        analysisCancelled = false

        // Rebuild gridItems so stack cover photos reflect updated analysis state
        gridItems = groupIntoBursts(rawFiles)
    }

    func analyzeFocus(for file: RAWFile) async {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let result = await FocusAnalyzer.analyze(url: file.url,
                                                  sharpenIntensity: settings?.sharpenIntensity ?? 0.4)
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
            resetOutcomeFields(at: idx)
            if let action = settings?.action(for: result.status) {
                applyOutcomeAction(action, to: idx)
            }
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    var rejectedCount: Int { rawFiles.filter { $0.pickStatus == .rejected }.count }

    // MARK: - Similar photo detection (pHash)

    /// Compute perceptual hashes for all files, then group near-duplicates.
    ///
    /// How it works:
    ///   1. For each file, load its embedded JPEG preview and compute a 64-bit pHash.
    ///      This is fast — it uses the same small thumbnail already loaded for focus
    ///      analysis, not the full RAW data.
    ///   2. Compare every pair of hashes. Two files are "similar" if their Hamming
    ///      distance (number of differing bits) is ≤ PHasher.similarityThreshold (10).
    ///   3. Use Union-Find to merge overlapping pairs into groups, so that if A≈B and
    ///      B≈C, all three end up in the same group even if A and C are not directly
    ///      compared as similar.
    ///   4. Publish the resulting groups as `similarGroups`.
    ///
    /// Call this once after files are loaded (or after the user requests it).
    /// Hashes are cached in rawFiles[i].pHash so re-grouping after label changes
    /// does not require re-hashing from disk.
    func computeSimilarGroups() async {
        guard !rawFiles.isEmpty else { return }
        isComputingSimilar = true

        let total = rawFiles.count
        let threshold = settings?.similarityThreshold ?? PHasher.defaultSimilarityThreshold

        // ── Step 1: compute hashes (skip files that already have one) ────────
        // Hashing is pure CPU work with no Swift concurrency contention on
        // rawFiles, so we compute off-MainActor and write results back in bulk.
        let urls: [(index: Int, url: URL)] = rawFiles.indices.compactMap { i in
            rawFiles[i].pHash == nil ? (i, rawFiles[i].url) : nil
        }

        // Compute hashes off the main thread in a detached task to avoid
        // blocking the UI. Results come back as (index, hash?) pairs.
        let hashes: [(Int, UInt64?)] = await Task.detached(priority: .userInitiated) {
            urls.map { (idx, url) in (idx, PHasher.hash(for: url)) }
        }.value

        for (idx, hash) in hashes {
            rawFiles[idx].pHash = hash
        }

        // ── Step 2: collect (index, hash) for files that have a valid hash ───
        let indexed: [(index: Int, hash: UInt64)] = rawFiles.indices.compactMap { i in
            guard let h = rawFiles[i].pHash else { return nil }
            return (i, h)
        }

        // ── Step 3: Union-Find to cluster similar pairs ──────────────────────
        //
        // Union-Find (also called Disjoint Set Union) is a data structure that
        // efficiently groups items into clusters. Think of it as labelling each
        // photo with a "group representative": when we find two similar photos
        // we merge their groups by pointing one representative at the other.
        //
        // parent[i] = the index of i's group representative (starts as itself).
        // find(i) follows the chain until it reaches a self-referencing root.
        // union(a, b) merges the two groups that a and b belong to.

        var parent = Array(0..<total)

        func find(_ x: Int) -> Int {
            // Path compression: point every node directly to the root
            // so future lookups are faster.
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Compare every pair. O(N²) in the number of files.
        // For a typical SD card of a few hundred photos this is fast (microseconds
        // per comparison). For very large sets (1000+) a hash-bucket approach
        // would be faster, but is not needed here.
        for i in 0..<indexed.count {
            for j in (i + 1)..<indexed.count {
                let dist = PHasher.hammingDistance(indexed[i].hash, indexed[j].hash)
                if dist <= threshold {
                    union(indexed[i].index, indexed[j].index)
                }
            }
        }

        // ── Step 4: collect groups of size ≥ 2 ──────────────────────────────
        // Build a dictionary: root index → [RAWFile]
        var clusters: [Int: [RAWFile]] = [:]
        for (fileIndex, _) in indexed {
            let root = find(fileIndex)
            clusters[root, default: []].append(rawFiles[fileIndex])
        }

        // Keep only groups with 2+ members; sort each group by modification date.
        let groups: [SimilarGroup] = clusters.values
            .filter { $0.count >= 2 }
            .map { files in
                let sorted = files.sorted {
                    ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
                }
                return SimilarGroup(files: sorted)
            }
            // Sort groups so the one with the most members appears first.
            .sorted { $0.count > $1.count }

        similarGroups = groups
        isComputingSimilar = false
    }

    /// Total number of individual photos that appear in at least one similar group.
    var similarPhotoCount: Int {
        similarGroups.reduce(0) { $0 + $1.count }
    }

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

    // MARK: - Batch setters for arbitrary file sets (used by multi-selection)

    /// Clear all flags, star ratings, and colour labels on every file.
    func resetAllLabels() {
        for idx in rawFiles.indices {
            rawFiles[idx].pickStatus = .unpicked
            rawFiles[idx].pickIsOverridden = false
            rawFiles[idx].starRating = 0
            rawFiles[idx].labelColour = .none
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Apply a pick status to every file in the supplied array.
    func setPickStatus(_ status: PickStatus, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Apply a star rating to every file in the supplied array.
    func setStarRating(_ rating: Int, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
        gridItems = groupIntoBursts(rawFiles)
    }

    /// Apply a colour label to every file in the supplied array.
    func setLabelColour(_ colour: LabelColour, forFiles files: [RAWFile]) {
        for file in files {
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
                // modificationDate is now a stored let — safe to access repeatedly.
                // If either date is missing, treat as a gap > threshold (no grouping).
                let gap: TimeInterval
                if let last = currentGroup.last!.modificationDate,
                   let this = file.modificationDate {
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

    private func resetOutcomeFields(at idx: Int) {
        rawFiles[idx].pickStatus  = .unpicked
        rawFiles[idx].starRating  = 0
        rawFiles[idx].labelColour = .none
    }

    private func applyOutcomeAction(_ action: FocusOutcomeAction, to idx: Int) {
        if action.pick != .unpicked {
            rawFiles[idx].pickStatus = action.pick
        }
        if action.stars > 0 {
            rawFiles[idx].starRating = action.stars
        }
        if action.colour != .none {
            rawFiles[idx].labelColour = action.colour
        }
    }

    private func detectExternalVolumes() -> Bool {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        return !(contents?.isEmpty ?? true)
    }
}
