import Foundation
import UIKit
import Combine

// MARK: - Pick status

enum PickStatus: String, Codable {
    case accepted
    case rejected
    case unpicked
}

// MARK: - Label colour

enum LabelColour: String, Codable, CaseIterable {
    case none, red, yellow, green, blue, purple
}

// MARK: - RAWFile model

struct RAWFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let fileExtension: String
    let modificationDate: Date?
    let size: Int64

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    init(url: URL) {
        self.url           = url
        self.name          = url.lastPathComponent
        self.fileExtension = url.pathExtension.uppercased()
        let rv             = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.modificationDate = rv?.contentModificationDate
        self.size          = Int64(rv?.fileSize ?? 0)
    }

    // MARK: Focus analysis
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

    // MARK: Exposure assessment — populated alongside focus analysis
    var exposureAssessment: ExposureAssessment? = nil

    // MARK: Perceptual hash — populated at load time
    var pHash: UInt64? = nil

    // MARK: Species — populated alongside focus analysis
    var speciesLabel: String? = nil
    var speciesConfidence: Float? = nil
    var speciesCandidates: [(label: String, confidence: Float)] = []

    // MARK: Pick / rating / label
    var pickStatus: PickStatus = .unpicked
    var pickIsOverridden: Bool = false
    var starRating: Int = 0
    var labelColour: LabelColour = .none

    // MARK: Burst sharpness ranking — set by runBurstSharpnessRanking()
    var isBurstSharpnessBest: Bool = false
    /// True when this photo's score is >1.5σ below the burst mean — a genuine soft outlier.
    var isBurstOutlier: Bool = false
    /// Rank within burst by sharpness: 1 = sharpest, 2 = second, 3 = third. nil otherwise.
    var burstRank: Int? = nil

    // MARK: Frame geometry flags — set during focus analysis
    /// True when the subject's bounding rect touches within 2% of any image edge.
    var subjectClipped: Bool = false

    var isRejected: Bool { pickStatus == .rejected }
}

extension RAWFile: Hashable, Equatable {
    static func == (lhs: RAWFile, rhs: RAWFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - PhotoGroup
//
// A named group of related photos.
// kind == .confirmedBurst : time-adjacent sequence (≤2 s between frames)
// kind == .similar        : visually similar photos identified by pHash

struct PhotoGroup: Identifiable {
    let id: UUID
    var files: [RAWFile]
    var kind: Kind

    enum Kind { case confirmedBurst, similar }

    init(files: [RAWFile], kind: Kind, id: UUID = UUID()) {
        self.id    = id
        self.files = files
        self.kind  = kind
    }

    var coverFile: RAWFile { files[0] }
    var count: Int { files.count }
    var isBurst:   Bool { if case .confirmedBurst = kind { return true }; return false }
    var isSimilar: Bool { if case .similar        = kind { return true }; return false }
}

// MARK: - GridItem
//
// Used only by the "All" view in the grid.
// Singles = photos not in any burst.
// Groups  = burst stacks (similar groups are shown via a separate path).

enum GridItem: Identifiable {
    case single(RAWFile)
    case group(PhotoGroup)

    var id: UUID {
        switch self {
        case .single(let f): return f.id
        case .group(let g):  return g.id
        }
    }
}

// MARK: - Constants

private let burstGapThreshold: TimeInterval = 2.0

/// Session window for similar grouping. Photos further apart than this are
/// never grouped as similar, regardless of visual appearance.
private let sessionWindowSeconds: TimeInterval = 2 * 60 * 60   // 2 hours

private let rawExtensions: Set<String> = [
    "raw", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "raf", "srw", "dng", "3fr", "fff", "iiq", "rwl",
    "mrw", "x3f", "erf", "kdc", "dcr", "mef", "mos", "ptx",
    "tif", "tiff"
]

// MARK: - SDCardManager

@MainActor
final class SDCardManager: ObservableObject {

    var settings: AppSettings?

    @Published var rawFiles: [RAWFile] = []

    // ── Burst groups ─────────────────────────────────────────────────────────
    // Built from timestamp proximity only. Independent of similarGroups.
    // A photo can appear in both a burstGroup and a similarGroup simultaneously.
    @Published var burstGroups: [PhotoGroup] = []

    // ── Similar groups ───────────────────────────────────────────────────────
    // Built from pHash comparison across all files. Independent of burstGroups.
    @Published var similarGroups: [PhotoGroup] = []

    // ── Species groups ───────────────────────────────────────────────────────
    // One group per identified species, containing all photos of that species
    // within the session window. Built from species labels, not pHash.
    // Independent of burstGroups and similarGroups.
    @Published var speciesGroups: [PhotoGroup] = []

    // ── Grid items (All view) ────────────────────────────────────────────────
    // Burst stacks shown as cards; singles shown flat.
    // Similar and species groups have their own views.
    @Published var gridItems: [GridItem] = []

    // pHash pass state — shown during initial load
    @Published var isComputingHashes: Bool   = false
    @Published var hashProgress:      Double = 0

    @Published var isSDCardMounted:  Bool   = false
    @Published var isLoading:        Bool   = false
    @Published var isAnalyzing:      Bool   = false
    @Published var analysisProgress: Double = 0
    @Published var errorMessage:     String?

    var burstPhotoCount:   Int { burstGroups.reduce(0)   { $0 + $1.count } }
    var similarPhotoCount: Int { similarGroups.reduce(0)  { $0 + $1.count } }
    var speciesPhotoCount: Int { speciesGroups.reduce(0)  { $0 + $1.count } }

    private var activeDirectoryURL: URL? {
        didSet { oldValue?.stopAccessingSecurityScopedResource() }
    }
    deinit { activeDirectoryURL?.stopAccessingSecurityScopedResource() }

    // MARK: - Discovery

    func refresh() {
        guard !isSDCardMounted else { return }
        isLoading = true; errorMessage = nil
        Task {
            let found = scanForRAWFiles()
            await loadAndGroup(found)
            if !found.isEmpty { isSDCardMounted = true }
            isLoading = false
        }
    }

    func forceRefresh() {
        activeDirectoryURL = nil
        isSDCardMounted = false
        rawFiles = []; gridItems = []; burstGroups = []; similarGroups = []; speciesGroups = []
        isLoading = true; errorMessage = nil
        Task {
            let found = scanForRAWFiles()
            await loadAndGroup(found)
            isSDCardMounted = !found.isEmpty || detectExternalVolumes()
            isLoading = false
        }
    }

    func loadFilesFromDirectory(_ url: URL) {
        activeDirectoryURL = url
        isLoading = true; errorMessage = nil
        let found  = collectRAWFiles(in: url)
        let sorted = found.sorted { $0.name < $1.name }
        isSDCardMounted = true; isLoading = false
        if found.isEmpty {
            errorMessage = "No RAW files found in the selected directory."
            rawFiles = []; gridItems = []; burstGroups = []; similarGroups = []; speciesGroups = []
            return
        }
        Task { await loadAndGroup(sorted) }
    }

    // MARK: - Load pipeline
    //
    // Pass 1 — immediate:   compute pHash for every file.
    //                       Publish rawFiles, burstGroups, similarGroups, gridItems.
    // Pass 2 — on demand:   full focus analysis (user-initiated).
    //                       Species identification runs as part of focus analysis.

    private func loadAndGroup(_ files: [RAWFile]) async {
        // Publish files immediately so the grid appears with thumbnails.
        // The user can browse while hashing runs in the background.
        rawFiles      = files
        burstGroups   = buildBurstGroups(from: rawFiles)
        similarGroups = []
        speciesGroups = []
        gridItems     = buildGridItems(from: rawFiles, bursts: burstGroups)
    }

    // MARK: - pHash / similar groups (on demand)
    //
    // Called explicitly by the user via the "Find Similar" toolbar button.
    // Computes pHash for any files that don't have one yet, then rebuilds
    // similar groups. Hashes are cached so re-running is fast.

    func computeSimilarGroups() async {
        guard !rawFiles.isEmpty else { return }
        isComputingHashes = true
        hashProgress = 0

        let total     = rawFiles.count
        let batchSize = 16

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            let indices  = Array(batchStart..<batchEnd).filter { rawFiles[$0].pHash == nil }

            if !indices.isEmpty {
                let urls = indices.map { rawFiles[$0].url }
                let hashes: [UInt64?] = await Task.detached(priority: .userInitiated) {
                    urls.map { PHasher.hash(for: $0) }
                }.value
                for (offset, i) in indices.enumerated() {
                    rawFiles[i].pHash = hashes[offset]
                }
            }

            hashProgress = Double(batchEnd) / Double(total)
        }

        isComputingHashes = false
        similarGroups = buildSimilarGroups(from: rawFiles)
    }

    // MARK: - Rebuild helper

    private func rebuildAllGroups() {
        burstGroups   = buildBurstGroups(from: rawFiles)
        similarGroups = buildSimilarGroups(from: rawFiles)
        speciesGroups = buildSpeciesGroups(from: rawFiles)
        gridItems     = buildGridItems(from: rawFiles, bursts: burstGroups)
    }

    // MARK: - Label normalisation
    //
    // Species labels come from CoreML model identifiers which may use underscores,
    // mixed case, or slightly different formatting between the load-time classifier
    // and focus analysis. Normalise to a consistent display string and lookup key
    // everywhere so the same species always maps to the same group.

    /// Returns a display-ready species label: underscores replaced with spaces,
    /// each word capitalised. e.g. "european_robin" → "European Robin".
    static func normaliseSpeciesLabel(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Lowercase key for dictionary grouping — strips all whitespace variation.
    private static func speciesKey(_ label: String) -> String {
        normaliseSpeciesLabel(label).lowercased()
    }

    // MARK: - Burst grouping
    //
    // Pure time-based: consecutive files within burstGapThreshold seconds
    // form a burst group. No pHash check — we trust the camera's timing.
    // Species veto applied after grouping.

    private func buildBurstGroups(from files: [RAWFile]) -> [PhotoGroup] {

        let sorted = files.sorted {
            ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
        }

        var rawGroups: [[RAWFile]] = []
        var current: [RAWFile] = []

        for file in sorted {
            if current.isEmpty { current.append(file); continue }
            let gap: TimeInterval = {
                guard let d0 = current.last!.modificationDate,
                      let d1 = file.modificationDate
                else { return burstGapThreshold + 1 }
                return d1.timeIntervalSince(d0)
            }()
            if gap <= burstGapThreshold { current.append(file) }
            else { rawGroups.append(current); current = [file] }
        }
        if !current.isEmpty { rawGroups.append(current) }

        // Keep only groups of 2+. Species veto temporarily disabled.
        return rawGroups
            .filter { $0.count >= 2 }
            .map { PhotoGroup(files: $0, kind: .confirmedBurst) }
    }

    // MARK: - Similar grouping
    //
    // Pure pHash-based: every file compared against every other file.
    // Two files are similar if:
    //   • Their modification dates are within sessionWindowSeconds, AND
    //   • Their pHash Hamming distance ≤ similarityThreshold.
    //
    // Grouping is seed-based (not Union-Find transitivity) to avoid chaining
    // dissimilar photos through an intermediate bridge match.
    //
    // Species veto applied after grouping.
    //
    // Note: a file may appear in both a burstGroup and a similarGroup.
    // The two arrays are completely independent.

    private func buildSimilarGroups(from files: [RAWFile]) -> [PhotoGroup] {
        let threshold = settings?.similarityThreshold ?? PHasher.defaultSimilarityThreshold

        // Only files with a hash are candidates, sorted by date.
        let candidates = files
            .filter { $0.pHash != nil }
            .sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
        let m = candidates.count
        guard m >= 2 else { return [] }

        // Union-Find over candidate indices.
        // Two files are connected if they are within the session window AND
        // their pHash distance is within the threshold.
        // Union-Find transitivity is correct here: if A~B and B~C then A, B, C
        // are genuinely related — they form a chain of visually similar photos.
        // The session window prevents unrelated photos from different days linking.
        var parent = Array(0..<m)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<m {
            guard let hi = candidates[i].pHash,
                  let di = candidates[i].modificationDate else { continue }
            for j in (i+1)..<m {
                guard let hj = candidates[j].pHash,
                      let dj = candidates[j].modificationDate,
                      abs(di.timeIntervalSince(dj)) <= sessionWindowSeconds,
                      PHasher.hammingDistance(hi, hj) <= threshold
                else { continue }
                union(i, j)
            }
        }

        // Collect clusters by root index.
        var clusters: [Int: [RAWFile]] = [:]
        for i in 0..<m {
            clusters[find(i), default: []].append(candidates[i])
        }

        // Species veto temporarily disabled.
        return clusters.values
            .filter { $0.count >= 2 }
            .map { group in
                let sorted = group.sorted {
                    ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
                }
                return PhotoGroup(files: sorted, kind: .similar)
            }
            .sorted { ($0.coverFile.modificationDate ?? .distantPast) > ($1.coverFile.modificationDate ?? .distantPast) }
    }

    // MARK: - Species grouping
    //
    // Groups photos by their identified species label.
    // One PhotoGroup per species, containing every photo of that species
    // whose modification date falls within the session window of the first
    // photo of that species shot that day.
    //
    // This is semantically more meaningful than pHash for wildlife photography:
    // "show me all my Robin shots" is a useful cull group.
    //
    // Photos with no confident species label are excluded entirely.
    // A photo may appear in both a speciesGroup and a burstGroup or similarGroup.

    private func buildSpeciesGroups(from files: [RAWFile]) -> [PhotoGroup] {
        // Use banded threshold — tighter for small subjects, relaxed for large ones.
        // subjectBodyArea is populated by FocusAnalyzer alongside species classification.
        let labelled = files.filter { file in
            guard let conf = file.speciesConfidence,
                  file.speciesLabel != nil else { return false }
            let threshold = Float(settings?.speciesThreshold(for: Float(file.subjectBodyArea)) ?? 0.65)
            return conf >= threshold
        }
        guard !labelled.isEmpty else { return [] }

        // Group by normalised species key (lowercased, underscores → spaces).
        var bySpecies: [String: [RAWFile]] = [:]
        for file in labelled {
            let key = SDCardManager.speciesKey(file.speciesLabel!)
            bySpecies[key, default: []].append(file)
        }


        // Expand each species group to include burst companions.
        // A burst companion is time-adjacent (within burstGapThreshold) to a labelled
        // file in the group AND either has no species label, or has the SAME species.
        // This prevents jackdaw-labelled files bleeding into grey heron groups etc.
        let allFilesSorted = files.sorted {
            ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
        }

        var expandedBySpecies: [String: Set<UUID>] = [:]

        for (species, labelledFiles) in bySpecies {
            var ids = Set(labelledFiles.map { $0.id })

            for labelled in labelledFiles {
                guard let pos = allFilesSorted.firstIndex(where: { $0.id == labelled.id })
                else { continue }

                // Walk backwards
                var i = pos - 1
                while i >= 0 {
                    let candidate = allFilesSorted[i]
                    guard let dPrev = candidate.modificationDate,
                          let dNext = allFilesSorted[i + 1].modificationDate,
                          abs(dNext.timeIntervalSince(dPrev)) <= burstGapThreshold
                    else { break }
                    // Only include if no conflicting species label.
                    let candidateKey = candidate.speciesLabel.map { SDCardManager.speciesKey($0) }
                    if let ck = candidateKey, ck != species { break }
                    ids.insert(candidate.id)
                    i -= 1
                }

                // Walk forwards
                var j = pos + 1
                while j < allFilesSorted.count {
                    let candidate = allFilesSorted[j]
                    guard let dThis = candidate.modificationDate,
                          let dPrev = allFilesSorted[j - 1].modificationDate,
                          abs(dThis.timeIntervalSince(dPrev)) <= burstGapThreshold
                    else { break }
                    let candidateKey = candidate.speciesLabel.map { SDCardManager.speciesKey($0) }
                    if let ck = candidateKey, ck != species { break }
                    ids.insert(candidate.id)
                    j += 1
                }
            }

            expandedBySpecies[species] = ids
        }

        // Build final PhotoGroups from the expanded ID sets.
        let fileByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        // Use a deterministic ID derived from the species key so that rebuilding
        // the same species group always produces the same ID. SwiftUI uses this to
        // decide whether to animate or replace a cell — a stable ID prevents
        // phantom duplicates appearing during the progressive species pass rebuilds.
        return expandedBySpecies
            .compactMap { (speciesKey, ids) -> PhotoGroup? in
                let groupFiles = ids.compactMap { fileByID[$0] }
                    .sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
                guard groupFiles.count >= 1 else { return nil }
                let stableID = SDCardManager.deterministicUUID(for: speciesKey)
                return PhotoGroup(files: groupFiles, kind: .similar, id: stableID)
            }
            .sorted { $0.count > $1.count }   // most photos first
    }

    /// Produces a deterministic UUID from a string by hashing it.
    /// The same string always produces the same UUID, making SwiftUI list IDs
    /// stable across rebuilds of species groups.
    private static func deterministicUUID(for string: String) -> UUID {
        // Use a simple DJB2 hash to produce 16 bytes deterministically.
        var h1: UInt64 = 5381
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for scalar in string.unicodeScalars {
            h1 = (h1 &<< 5) &+ h1 &+ UInt64(scalar.value)
            h2 = (h2 ^ UInt64(scalar.value)) &* 0x9e3779b97f4a7c15
        }
        // Pack h1 and h2 into 16 bytes for a UUID.
        return UUID(uuid: (
            UInt8(h1 & 0xFF), UInt8((h1 >> 8) & 0xFF),
            UInt8((h1 >> 16) & 0xFF), UInt8((h1 >> 24) & 0xFF),
            UInt8((h1 >> 32) & 0xFF), UInt8((h1 >> 40) & 0xFF),
            UInt8((h1 >> 48) & 0xFF), UInt8((h1 >> 56) & 0xFF),
            UInt8(h2 & 0xFF), UInt8((h2 >> 8) & 0xFF),
            UInt8((h2 >> 16) & 0xFF), UInt8((h2 >> 24) & 0xFF),
            UInt8((h2 >> 32) & 0xFF), UInt8((h2 >> 40) & 0xFF),
            UInt8((h2 >> 48) & 0xFF), UInt8((h2 >> 56) & 0xFF)
        ))
    }

    // MARK: - Grid items (All view)
    //
    // Burst groups appear as stacked cards; photos not in any burst appear as singles.
    // Similar and species groups have their own filtered views.

    private func buildGridItems(from files: [RAWFile],
                                bursts: [PhotoGroup]) -> [GridItem] {
        // Which file IDs are in a burst group?
        let burstFileIDs = Set(bursts.flatMap { $0.files.map { $0.id } })

        // Files sorted by date for consistent ordering.
        let sorted = files.sorted {
            ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture)
        }

        var items: [GridItem] = []
        var emittedIDs = Set<UUID>()

        for file in sorted {
            guard !emittedIDs.contains(file.id) else { continue }

            if burstFileIDs.contains(file.id),
               let group = bursts.first(where: { $0.files.contains { $0.id == file.id } }) {
                // Emit the whole burst group once (keyed on cover file).
                if !emittedIDs.contains(group.coverFile.id) {
                    items.append(.group(group))
                    group.files.forEach { emittedIDs.insert($0.id) }
                }
            } else {
                items.append(.single(file))
                emittedIDs.insert(file.id)
            }
        }
        return items
    }

    // MARK: - Species veto
    //
    // Splits a flat file array into sub-arrays wherever confident species labels
    // conflict. Files with no confident label are neutral — never trigger a split.

    private func applySpeciesVeto(to files: [RAWFile],
                                   kind: PhotoGroup.Kind,
                                   threshold: Float) -> [[RAWFile]] {
        func label(_ f: RAWFile) -> String? {
            guard let l = f.speciesLabel, let c = f.speciesConfidence, c >= threshold
            else { return nil }
            return l.lowercased()
        }

        // Pass 1: find the dominant species (most frequent confident label).
        // Files with no confident label are neutral and do not vote.
        var counts: [String: Int] = [:]
        for file in files {
            if let lbl = label(file) { counts[lbl, default: 0] += 1 }
        }
        let dominant = counts.max(by: { $0.value < $1.value })?.key

        // If no file has a confident label, or all confident labels agree,
        // no split is needed — return the group unchanged.
        if counts.count <= 1 { return [files] }

        // Pass 2: separate files whose confident label CONFLICTS with the dominant
        // species into their own buckets. Files with no confident label stay with
        // the dominant group (neutral). Files with a minority confident label that
        // differs from dominant form their own groups.
        var dominantGroup: [RAWFile] = []
        var minorityGroups: [String: [RAWFile]] = [:]

        for file in files {
            if let lbl = label(file), lbl != dominant {
                minorityGroups[lbl, default: []].append(file)
            } else {
                // No confident label (neutral) or matches dominant — stays in main group.
                dominantGroup.append(file)
            }
        }

        var result: [[RAWFile]] = []
        if !dominantGroup.isEmpty { result.append(dominantGroup) }
        for (_, group) in minorityGroups.sorted(by: { $0.key < $1.key }) {
            result.append(group)
        }
        return result
    }

    // MARK: - Focus Analysis (user-initiated)

    private var analysisCancelled = false
    func cancelAnalysis() { analysisCancelled = true }

    func analyzeAllFocus() async {
        guard !rawFiles.isEmpty else { return }
        isAnalyzing = true; analysisCancelled = false; analysisProgress = 0
        let sharpT      = settings?.sharpThreshold      ?? 0.62
        let acceptableT = settings?.acceptableThreshold ?? 0.32
        let total       = rawFiles.count
        let urls        = rawFiles.map { $0.url }

        // Batch size 3: Vision (VNGenerateForegroundInstanceMaskRequest) competes for the
        // Neural Engine. At batch 6, five tasks queue behind the first and each take ~950ms.
        // At batch 3, contention is lower and per-file times are more consistent (~300ms).
        let analysisBatchSize = 3

        for batchStart in stride(from: 0, to: total, by: analysisBatchSize) {
            if analysisCancelled { break }
            let batchEnd = min(batchStart + analysisBatchSize, total)

            await withTaskGroup(of: (Int, FocusResult).self) { group in
                for i in batchStart..<batchEnd {
                    let url = urls[i]
                    group.addTask {
                        let r = await FocusAnalyzer.analyze(url: url,
                                                            sharpThreshold: sharpT,
                                                            acceptableThreshold: acceptableT)
                        return (i, r)
                    }
                }
                for await (i, result) in group {
                    applyFocusResult(result, to: i)
                }
            }
            analysisProgress = Double(batchEnd) / Double(total)
        }

        isAnalyzing = false
        analysisCancelled = false
        rebuildAllGroups()
        runBurstSharpnessRanking()
    }

    func analyzeFocus(for file: RAWFile) async {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let result = await FocusAnalyzer.analyze(
            url: file.url,
            sharpThreshold:      settings?.sharpThreshold      ?? 0.62,
            acceptableThreshold: settings?.acceptableThreshold ?? 0.32)
        applyFocusResult(result, to: idx)
        rebuildAllGroups()
        runBurstSharpnessRanking()
    }

    private func applyFocusResult(_ result: FocusResult, to idx: Int) {
        rawFiles[idx].focusStatus           = result.status
        rawFiles[idx].focusScore            = result.score
        rawFiles[idx].focusRegion           = result.analysisRegion
        rawFiles[idx].blurType              = result.blurType
        rawFiles[idx].subjectSizeConfidence = result.subjectSizeConfidence
        rawFiles[idx].analysisRect          = result.analysisRect
        rawFiles[idx].subjectContour        = result.subjectContour
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
        rawFiles[idx].exposureAssessment    = result.exposureAssessment
        rawFiles[idx].subjectClipped        = result.subjectClipped

        // Species — from SpeciesDetector (classifier). Stored separately from
        // detectedAnimalLabel which tracks geometric subject detection.
        if let speciesLabel = result.speciesLabel {
            let normLabel = SDCardManager.normaliseSpeciesLabel(speciesLabel)
            rawFiles[idx].speciesLabel        = normLabel
            rawFiles[idx].speciesConfidence   = result.speciesConfidence
            rawFiles[idx].speciesCandidates   = result.speciesCandidates
            rawFiles[idx].detectionConfidence = result.speciesConfidence
        }

        // detectedAnimalLabel — only from routing-time subject detection (requires contour).
        if let detectedLabel = result.detectedAnimalLabel {
            let normLabel = SDCardManager.normaliseSpeciesLabel(detectedLabel)
            let newConf = result.detectionConfidence ?? 0
            let oldConf = rawFiles[idx].detectionConfidence ?? 0
            if newConf >= oldConf {
                rawFiles[idx].detectedAnimalLabel = normLabel
                rawFiles[idx].detectionConfidence = result.detectionConfidence
            }
        }
        if !rawFiles[idx].pickIsOverridden {
            resetOutcomeFields(at: idx)
            // 1. Base action from focus status (sharp / slightly blurry / blurry)
            if let action = settings?.action(for: result.status) {
                applyOutcomeAction(action, to: idx)
            }
            // 2. Subject clipping flag — applied on top, overrides where non-default
            if result.subjectClipped,
               let action = settings?.subjectClippedAction {
                applyOutcomeAction(action, to: idx)
            }
            // 3. Exposure flags — subject clip fractions checked against user thresholds
            if let ea = result.exposureAssessment,
               let issue = settings?.exposureIssue(for: ea) {
                let action = issue == .overexposed
                    ? settings?.overexposedAction
                    : settings?.underexposedAction
                if let action { applyOutcomeAction(action, to: idx) }
            }
        }
    }

    var rejectedCount: Int { rawFiles.filter { $0.pickStatus == .rejected }.count }

    // MARK: - Pick / rating / label setters

    func setPickStatus(_ status: PickStatus, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].pickStatus = status
        rawFiles[idx].pickIsOverridden = (status != .unpicked)
        rebuildAllGroups()
    }

    func setPickStatus(_ status: PickStatus, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
        rebuildAllGroups()
    }

    func setStarRating(_ rating: Int, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].starRating = min(max(rating, 0), 5)
        rebuildAllGroups()
    }

    func setStarRating(_ rating: Int, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
        rebuildAllGroups()
    }

    func setLabelColour(_ colour: LabelColour, for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].labelColour = colour
        rebuildAllGroups()
    }

    func setLabelColour(_ colour: LabelColour, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].labelColour = colour
        }
        rebuildAllGroups()
    }

    func resetAllLabels() {
        for idx in rawFiles.indices {
            rawFiles[idx].pickStatus = .unpicked
            rawFiles[idx].pickIsOverridden = false
            rawFiles[idx].starRating = 0
            rawFiles[idx].labelColour = .none
        }
        rebuildAllGroups()
    }

    func setPickStatus(_ status: PickStatus, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
        rebuildAllGroups()
    }

    func setStarRating(_ rating: Int, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
        rebuildAllGroups()
    }

    func setLabelColour(_ colour: LabelColour, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { continue }
            rawFiles[idx].labelColour = colour
        }
        rebuildAllGroups()
    }

    func markXMPWritten(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        rawFiles[idx].xmpWritten = true
    }

    // MARK: - XMP

    func writeXMP(for file: RAWFile) {
        guard let idx = rawFiles.firstIndex(where: { $0.id == file.id }) else { return }
        do {
            try XMPSidecarWriter.write(for: file)
            rawFiles[idx].xmpWritten = true
        } catch { errorMessage = error.localizedDescription }
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
        if result.skipped > 0     { summary += ", \(result.skipped) skipped (no species)" }
        if !result.errors.isEmpty { summary += ", \(result.errors.count) error(s)" }
        return summary
    }

    // MARK: - Burst sharpness ranking
    //
    // Runs automatically after species grouping completes and after any full
    // focus analysis batch. For every species burst (2+ time-adjacent photos
    // of the same species), finds the photo with the highest focusScore and
    // marks it isBurstSharpnessBest = true. All other photos in that burst
    // are set to false.
    //
    // Only fully-analysed photos (focusStatus != .unanalyzed) are candidates.
    // A burst needs at least 2 analysed photos for any crown to be awarded.
    // Rejected photos are excluded from contention entirely.
    //
    // Tie-breaking order:
    //   1. focusScore (higher wins)
    //   2. afOverlapsSubject (true wins)
    //   3. rawSharpnessScore (higher wins)
    //   4. burst order (earlier photo wins)

    private func runBurstSharpnessRanking() {
        // Reset all burst flags so every run starts clean.
        for i in rawFiles.indices {
            rawFiles[i].isBurstSharpnessBest = false
            rawFiles[i].isBurstOutlier       = false
            rawFiles[i].burstRank            = nil
        }

        // Rank within burstGroups, not speciesGroups. speciesGroups only contains
        // photos with a recognised species label, so unidentified photos (no YOLO
        // classification above threshold) would never receive a crown or rank.
        // burstGroups covers all time-adjacent photos regardless of species.
        for group in burstGroups {
            let sorted = group.files
                .compactMap { file in rawFiles.first { $0.id == file.id } }
                .sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }

            var bursts: [[RAWFile]] = []
            var current: [RAWFile] = []
            for file in sorted {
                if current.isEmpty { current.append(file); continue }
                let gap: TimeInterval = {
                    guard let a = current.last!.modificationDate,
                          let b = file.modificationDate
                    else { return burstGapThreshold + 1 }
                    return b.timeIntervalSince(a)
                }()
                if gap <= burstGapThreshold { current.append(file) }
                else { bursts.append(current); current = [file] }
            }
            if !current.isEmpty { bursts.append(current) }

            for burst in bursts {
                let candidates = burst.filter {
                    $0.pickStatus != .rejected && $0.focusStatus != .unanalyzed
                }
                guard candidates.count >= 2 else { continue }

                // ── Crown: single best photo ──────────────────────────────────
                let best = candidates.max { a, b in
                    if a.focusScore != b.focusScore { return a.focusScore < b.focusScore }
                    let afA = a.afOverlapsSubject ?? false
                    let afB = b.afOverlapsSubject ?? false
                    if afA != afB { return !afA }
                    if a.rawSharpnessScore != b.rawSharpnessScore {
                        return a.rawSharpnessScore < b.rawSharpnessScore
                    }
                    return (a.modificationDate ?? .distantFuture) > (b.modificationDate ?? .distantFuture)
                }
                if let best, let idx = rawFiles.firstIndex(where: { $0.id == best.id }) {
                    rawFiles[idx].isBurstSharpnessBest = true
                }

                // ── Top-3 ranks ───────────────────────────────────────────────
                let ranked = candidates.sorted { $0.focusScore > $1.focusScore }
                for (rank, candidate) in ranked.prefix(3).enumerated() {
                    if let idx = rawFiles.firstIndex(where: { $0.id == candidate.id }) {
                        rawFiles[idx].burstRank = rank + 1
                    }
                }

                // ── Outlier detection: mean − 1.5σ ────────────────────────────
                // Requires ≥3 photos and meaningful spread (std > 0.02) so that
                // uniformly-sharp bursts don't generate false outlier flags.
                guard candidates.count >= 3 else { continue }
                let scores   = candidates.map { $0.focusScore }
                let mean     = scores.reduce(0, +) / Double(scores.count)
                let std      = sqrt(scores.map { pow($0 - mean, 2) }.reduce(0, +) / Double(scores.count))
                guard std > 0.02 else { continue }
                let threshold = mean - 1.5 * std

                for candidate in candidates where candidate.focusScore < threshold {
                    if let idx = rawFiles.firstIndex(where: { $0.id == candidate.id }) {
                        rawFiles[idx].isBurstOutlier = true
                        if !rawFiles[idx].pickIsOverridden,
                           let action = settings?.softInBurstAction {
                            applyOutcomeAction(action, to: idx)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    private func collectRAWFiles(in directory: URL) -> [RAWFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { RAWFile(url: $0) }
    }

    private func scanForRAWFiles() -> [RAWFile] {
        var results: [RAWFile] = []
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if let vols = try? FileManager.default.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) { for vol in vols { results += collectRAWFiles(in: vol) } }
        if let dcim = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .deletingLastPathComponent().appendingPathComponent("Media/DCIM") {
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
        if action.pick   != .unpicked { rawFiles[idx].pickStatus  = action.pick }
        if action.stars  >  0        { rawFiles[idx].starRating  = action.stars }
        if action.colour != .none    { rawFiles[idx].labelColour = action.colour }
    }

    private func detectExternalVolumes() -> Bool {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return !(contents?.isEmpty ?? true)
    }
}
