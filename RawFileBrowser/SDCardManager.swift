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
    var colourSig: [Float]? = nil

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

    enum Kind {
        case confirmedBurst
        case similar
        /// A group assembled by rejection-reason logic in the My Picks view.
        /// The associated label is the reason name (e.g. "Blurry", "No Flags").
        case reasonGroup(label: String)
    }

    init(files: [RAWFile], kind: Kind, id: UUID = UUID()) {
        self.id    = id
        self.files = files
        self.kind  = kind
    }

    var coverFile: RAWFile { files[0] }
    var count: Int { files.count }
    var isBurst:       Bool    { if case .confirmedBurst = kind { return true }; return false }
    var isSimilar:     Bool    { if case .similar        = kind { return true }; return false }
    var isReasonGroup: Bool    { if case .reasonGroup    = kind { return true }; return false }
    var reasonLabel:   String? { if case .reasonGroup(let l) = kind { return l }; return nil }
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

    // XMP batch export state — drives the progress banner in the grid.
    @Published var isWritingXMP:     Bool   = false
    @Published var xmpProgress:      Double = 0
    @Published var errorMessage:     String?

    var burstPhotoCount:   Int { burstGroups.reduce(0)   { $0 + $1.count } }
    var similarPhotoCount: Int { similarGroups.reduce(0)  { $0 + $1.count } }
    var speciesPhotoCount: Int { speciesGroups.reduce(0)  { $0 + $1.count } }

    private var activeDirectoryURL: URL? {
        didSet { oldValue?.stopAccessingSecurityScopedResource() }
    }
    deinit { activeDirectoryURL?.stopAccessingSecurityScopedResource() }

    // MARK: - Fast id → index lookup
    //
    // Views resolve a file's live copy on every render. Scanning the whole
    // rawFiles array each time is O(n) per card, which dominates scrolling and
    // culling on large shoots. We keep an id → position map, rebuilt whenever the
    // array is repopulated. Element mutations (pick, rating, focus result) don't
    // change positions, so the map stays valid between reloads. Every lookup
    // validates the cached position and falls back to a linear scan if it is ever
    // stale, so correctness never depends on the cache being perfectly in sync.

    private var indexByID: [UUID: Int] = [:]

    private func rebuildIndex() {
        var map = [UUID: Int](minimumCapacity: rawFiles.count)
        for (i, f) in rawFiles.enumerated() { map[f.id] = i }
        indexByID = map
    }

    /// Validated O(1) index for a file id. Falls back to a linear scan when the
    /// cached position is missing or stale.
    private func index(for id: UUID) -> Int? {
        if let i = indexByID[id], i < rawFiles.count, rawFiles[i].id == id { return i }
        return rawFiles.firstIndex(where: { $0.id == id })
    }

    /// The live copy of a file by id, or nil if it is no longer present.
    /// Used by the grid, cards and detail view for O(1) live-state resolution.
    func liveFile(id: UUID) -> RAWFile? {
        guard let i = index(for: id) else { return nil }
        return rawFiles[i]
    }

    // MARK: - Discovery

    func refresh() {
        guard !isSDCardMounted else { return }
        isLoading = true; errorMessage = nil
        Task {
            // Disk enumeration off the main actor so the UI stays responsive.
            let found = await Task.detached(priority: .userInitiated) {
                Self.scanForRAWFiles()
            }.value
            await loadAndGroup(found)
            if !found.isEmpty { isSDCardMounted = true }
            isLoading = false
        }
    }

    func forceRefresh() {
        activeDirectoryURL = nil
        isSDCardMounted = false
        RAWImageLoader.clearThumbnailCache()
        rawFiles = []; gridItems = []; burstGroups = []; similarGroups = []; speciesGroups = []
        isLoading = true; errorMessage = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.scanForRAWFiles()
            }.value
            await loadAndGroup(found)
            isSDCardMounted = !found.isEmpty || detectExternalVolumes()
            isLoading = false
        }
    }

    func loadFilesFromDirectory(_ url: URL) {
        activeDirectoryURL = url
        RAWImageLoader.clearThumbnailCache()
        isLoading = true; errorMessage = nil
        Task {
            // Enumeration + per-file resourceValues reads are disk I/O — run off
            // the main actor so the loading spinner stays responsive on big cards.
            let found = await Task.detached(priority: .userInitiated) {
                Self.collectRAWFiles(in: url)
            }.value
            let sorted = found.sorted { $0.name < $1.name }
            isSDCardMounted = true
            if sorted.isEmpty {
                errorMessage = "No RAW files found in the selected directory."
                rawFiles = []; gridItems = []; burstGroups = []; similarGroups = []; speciesGroups = []
                isLoading = false
                return
            }
            await loadAndGroup(sorted)
            isLoading = false
        }
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
        rebuildIndex()
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
                let (hashes, colourSigs): ([UInt64?], [[Float]?]) = await Task.detached(priority: .userInitiated) {
                    let h = urls.map { PHasher.hash(for: $0) }
                    let c = urls.map { PHasher.colourSignature(for: $0) }
                    return (h, c)
                }.value
                for (offset, i) in indices.enumerated() {
                    rawFiles[i].pHash     = hashes[offset]
                    rawFiles[i].colourSig = colourSigs[offset]
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
        let threshold       = settings?.similarityThreshold  ?? PHasher.defaultSimilarityThreshold
        let windowSeconds   = TimeInterval((settings?.sessionWindowMinutes ?? 30) * 60)
        let colourThreshold = Float(settings?.colourSimilarityThreshold ?? 0.45)

        // Only files with a hash are candidates, sorted by date.
        let candidates = files
            .filter { $0.pHash != nil }
            .sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
        let m = candidates.count
        guard m >= 2 else { return [] }

        // Seed-based grouping — avoids Union-Find chaining where A~B and B~C
        // would incorrectly merge A and C even when hammingDistance(A,C) > threshold.
        //
        // A candidate joins an existing group only if it is within:
        //   1. sessionWindowMinutes of the SEED's capture time, AND
        //   2. pHash Hamming distance ≤ similarityThreshold from the SEED, AND
        //   3. colour histogram distance ≤ colourSimilarityThreshold from the SEED.
        //
        // The colour gate prevents compositionally-similar but chromatically-different
        // scenes (e.g. sandy beach vs green grass) from being grouped together.
        // Near-grey images produce flat histograms; colourDistance returns ~0 for
        // both, so the gate is effectively skipped for low-saturation scenes.

        var assigned = [Bool](repeating: false, count: m)
        var clusters: [[RAWFile]] = []

        for i in 0..<m {
            guard !assigned[i],
                  let seedHash = candidates[i].pHash,
                  let seedDate = candidates[i].modificationDate else { continue }

            var group: [RAWFile] = [candidates[i]]
            assigned[i] = true

            for j in (i+1)..<m {
                guard !assigned[j],
                      let hj = candidates[j].pHash,
                      let dj = candidates[j].modificationDate,
                      abs(seedDate.timeIntervalSince(dj)) <= windowSeconds,
                      PHasher.hammingDistance(seedHash, hj) <= threshold,
                      PHasher.colourDistance(candidates[i].colourSig, candidates[j].colourSig) <= colourThreshold
                else { continue }
                group.append(candidates[j])
                assigned[j] = true
            }

            clusters.append(group)
        }

        // ── Pass 2: merge adjacent clusters whose seeds match ───────────────
        //
        // Seed-based grouping can split a continuous sequence into multiple groups
        // when photos drift gradually from the seed (subject moves, slight reframe).
        // A second pass merges clusters whose SEEDS are directly similar to each
        // other — preserving the no-chaining guarantee while collapsing splits.
        //
        // Safety: the same three gates (time window, pHash, colour) must all pass
        // between seeds before two clusters are merged. No transitive merging —
        // we only merge a cluster into the earliest compatible cluster.

        var mergedClusters: [[RAWFile]] = []

        for cluster in clusters {
            guard let clusterSeed     = cluster.first,
                  let clusterSeedHash = clusterSeed.pHash,
                  let clusterSeedDate = clusterSeed.modificationDate else {
                mergedClusters.append(cluster)
                continue
            }

            // Find the first existing merged cluster whose seed matches this one
            var didMerge = false
            for idx in 0..<mergedClusters.count {
                guard let existingSeed     = mergedClusters[idx].first,
                      let existingSeedHash = existingSeed.pHash,
                      let existingSeedDate = existingSeed.modificationDate,
                      abs(existingSeedDate.timeIntervalSince(clusterSeedDate)) <= windowSeconds,
                      PHasher.hammingDistance(existingSeedHash, clusterSeedHash) <= threshold,
                      PHasher.colourDistance(existingSeed.colourSig, clusterSeed.colourSig) <= colourThreshold
                else { continue }

                mergedClusters[idx].append(contentsOf: cluster)
                didMerge = true
                break
            }

            if !didMerge { mergedClusters.append(cluster) }
        }

        // Species veto temporarily disabled.
        return mergedClusters
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
        // Guard against misconfigured Settings: acceptable must sit below sharp,
        // otherwise the slightly-blurry band vanishes or inverts.
        let acceptableT = min(settings?.acceptableThreshold ?? 0.32, sharpT - 0.01)
        let total       = rawFiles.count
        // Capture (id, url) pairs so each result is applied to the right file even
        // if the array is repopulated mid-analysis (forceRefresh / directory
        // switch). Applying by stale positional index could hit the wrong file.
        let targets     = rawFiles.map { (id: $0.id, url: $0.url) }

        // Batch size 3: Vision (VNGenerateForegroundInstanceMaskRequest) competes for the
        // Neural Engine. At batch 6, five tasks queue behind the first and each take ~950ms.
        // At batch 3, contention is lower and per-file times are more consistent (~300ms).
        let analysisBatchSize = 3

        for batchStart in stride(from: 0, to: total, by: analysisBatchSize) {
            if analysisCancelled { break }
            let batchEnd = min(batchStart + analysisBatchSize, total)
            let batch    = Array(targets[batchStart..<batchEnd])

            // ── Pass 1: load thumbnails SERIALLY, off the main actor ─────────
            // Concurrent 2048px decodes contend on SD-card random I/O and hold
            // several large buffers at once. One detached task decodes the batch
            // in order; analysis then runs concurrently on the in-memory images.
            let images: [CGImage?] = await Task.detached(priority: .userInitiated) {
                batch.map { FocusAnalyzer.loadThumbnail(from: $0.url, maxDimension: 2048) }
            }.value

            // ── Pass 2: analyse the in-memory images concurrently ────────────
            await withTaskGroup(of: (UUID, FocusResult).self) { group in
                for (offset, target) in batch.enumerated() {
                    let cgImage = images[offset]
                    group.addTask {
                        let r: FocusResult
                        if let cgImage {
                            r = await FocusAnalyzer.analyze(cgImage: cgImage,
                                                            url: target.url,
                                                            sharpThreshold: sharpT,
                                                            acceptableThreshold: acceptableT)
                        } else {
                            // Serial decode failed — the url overload retries the
                            // load once and returns the unanalyzed sentinel if it
                            // fails again, so the file is never silently skipped.
                            r = await FocusAnalyzer.analyze(url: target.url,
                                                            sharpThreshold: sharpT,
                                                            acceptableThreshold: acceptableT)
                        }
                        return (target.id, r)
                    }
                }
                for await (id, result) in group {
                    guard let idx = index(for: id) else { continue }
                    applyFocusResult(result, to: idx)
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
        guard let idx = index(for: file.id) else { return }
        let sharpT      = settings?.sharpThreshold ?? 0.62
        let acceptableT = min(settings?.acceptableThreshold ?? 0.32, sharpT - 0.01)
        let result = await FocusAnalyzer.analyze(
            url: file.url,
            sharpThreshold:      sharpT,
            acceptableThreshold: acceptableT)
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
        // Note: detectionConfidence is deliberately NOT seeded from
        // speciesConfidence — they measure different things (Vision geometric
        // detection vs classifier), and conflating them made the diagnostic
        // view's confidence row misleading and gated the Vision fallback label
        // against classifier thresholds it was never meant to face.
        if let speciesLabel = result.speciesLabel {
            let normLabel = SDCardManager.normaliseSpeciesLabel(speciesLabel)
            rawFiles[idx].speciesLabel      = normLabel
            rawFiles[idx].speciesConfidence = result.speciesConfidence
            rawFiles[idx].speciesCandidates = result.speciesCandidates
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
            // 2. Motion blur — fires in addition to focus status action when blur
            //    type is specifically motion (not defocus), allowing separate handling
            //    of intentional panning shots vs missed focus.
            if result.blurType == .motionBlur,
               let action = settings?.motionBlurAction {
                applyOutcomeAction(action, to: idx)
            }
            // 3. Subject clipping flag — applied on top, overrides where non-default
            if result.subjectClipped,
               let action = settings?.subjectClippedAction {
                applyOutcomeAction(action, to: idx)
            }
            // 4. No subject detected — fires when neither geometric detection nor
            //    contour localisation found any subject. Distinct from "blurry".
            if result.detectedAnimalLabel == nil && result.subjectContour.isEmpty,
               let action = settings?.noSubjectDetectedAction {
                applyOutcomeAction(action, to: idx)
            }
            // 5. Subject too small — fires when a subject was detected but occupies
            //    less than the user-configured minimum area fraction of the image.
            if result.detectedAnimalLabel != nil || !result.subjectContour.isEmpty,
               let threshold = settings?.minSubjectAreaThreshold,
               result.subjectBodyArea < threshold,
               let action = settings?.subjectTooSmallAction {
                applyOutcomeAction(action, to: idx)
            }
            // 6. AF missed subject — fires when a Canon AF point was found but
            //    confirmed NOT to overlap the detected subject.
            if result.afNotOnSubject,
               let action = settings?.afMissedSubjectAction {
                applyOutcomeAction(action, to: idx)
            }
            // 7. Exposure flags — subject clip fractions checked against user thresholds
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
        guard let idx = index(for: file.id) else { return }
        rawFiles[idx].pickStatus = status
        rawFiles[idx].pickIsOverridden = (status != .unpicked)
    }

    func setPickStatus(_ status: PickStatus, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
    }

    func setStarRating(_ rating: Int, for file: RAWFile) {
        guard let idx = index(for: file.id) else { return }
        rawFiles[idx].starRating = min(max(rating, 0), 5)
    }

    func setStarRating(_ rating: Int, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
    }

    func setLabelColour(_ colour: LabelColour, for file: RAWFile) {
        guard let idx = index(for: file.id) else { return }
        rawFiles[idx].labelColour = colour
    }

    func setLabelColour(_ colour: LabelColour, forAllIn group: PhotoGroup) {
        for file in group.files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].labelColour = colour
        }
    }

    func resetAllLabels() {
        for idx in rawFiles.indices {
            rawFiles[idx].pickStatus = .unpicked
            rawFiles[idx].pickIsOverridden = false
            rawFiles[idx].starRating = 0
            rawFiles[idx].labelColour = .none
        }
    }

    func setPickStatus(_ status: PickStatus, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].pickStatus = status
            rawFiles[idx].pickIsOverridden = (status != .unpicked)
        }
    }

    func setStarRating(_ rating: Int, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].starRating = min(max(rating, 0), 5)
        }
    }

    func setLabelColour(_ colour: LabelColour, forFiles files: [RAWFile]) {
        for file in files {
            guard let idx = index(for: file.id) else { continue }
            rawFiles[idx].labelColour = colour
        }
    }

    func markXMPWritten(for file: RAWFile) {
        guard let idx = index(for: file.id) else { return }
        rawFiles[idx].xmpWritten = true
    }

    // MARK: - XMP

    func writeXMP(for file: RAWFile) {
        guard let idx = index(for: file.id) else { return }
        // Resolve the species HERE so the sidecar keyword always matches what the
        // UI shows. Previously the writer preferred speciesLabel unconditionally,
        // so a below-band classifier guess could be written while the UI showed
        // the Vision fallback.
        guard let species = settings?.displaySpecies(for: file)?.label else {
            errorMessage = XMPSidecarWriter.WriteError.noSpeciesLabel.localizedDescription
            return
        }
        do {
            try XMPSidecarWriter.write(for: file, species: species)
            rawFiles[idx].xmpWritten = true
        } catch { errorMessage = error.localizedDescription }
    }

    /// Writes XMP sidecars for every file whose species clears the per-size
    /// confidence band. Runs the disk writes off the main actor and publishes
    /// progress so the grid can show a banner. Returns a user-facing summary.
    func writeXMPBatch() async -> String {
        guard let settings else { return "Settings unavailable" }
        // Eligibility + resolution in one pass: the resolved display label is
        // handed to the writer, guaranteeing UI and sidecar always agree.
        let eligible: [(file: RAWFile, species: String)] = rawFiles.compactMap { f in
            settings.displaySpecies(for: f).map { (f, $0.label) }
        }
        guard !eligible.isEmpty else { return "No files with a confident species to write" }

        isWritingXMP = true; xmpProgress = 0
        var written = 0
        var errors: [String] = []

        for (i, item) in eligible.enumerated() {
            let file = item.file, species = item.species
            do {
                _ = try await Task.detached(priority: .utility) {
                    try XMPSidecarWriter.write(for: file, species: species)
                }.value
                written += 1
                if let idx = index(for: file.id) { rawFiles[idx].xmpWritten = true }
            } catch {
                errors.append("\(file.name): \(error.localizedDescription)")
            }
            xmpProgress = Double(i + 1) / Double(eligible.count)
        }

        isWritingXMP = false
        var summary = "\(written) XMP file(s) written"
        if !errors.isEmpty { summary += ", \(errors.count) error(s)" }
        return summary
    }

    // MARK: - Burst sharpness ranking
    //
    // Runs automatically after species grouping completes and after any full
    // focus analysis batch. For every burst (2+ time-adjacent photos),
    // ranks photos by a composite score (sharpness × weight + exposure × weight
    // + subject area × weight — configured by the user in Settings).
    //
    // burstKeepCount (user-configured) controls how many photos per burst are
    // "winners". Photos outside the top-N receive burstNonWinnerAction if set.
    //
    // isBurstSharpnessBest marks the single best photo (rank 1) as before.
    // burstRank stores the numeric rank (1 = best) for all ranked photos.
    //
    // Outlier detection (mean − 1.5σ) fires softInBurstAction independently
    // and is not affected by burstKeepCount.
    //
    // Only fully-analysed photos (focusStatus != .unanalyzed) are candidates.
    // Rejected photos are excluded from contention entirely.

    private func runBurstSharpnessRanking() {
        // Reset all burst flags so every run starts clean.
        for i in rawFiles.indices {
            rawFiles[i].isBurstSharpnessBest = false
            rawFiles[i].isBurstOutlier       = false
            rawFiles[i].burstRank            = nil
        }

        let keepCount = settings?.burstKeepCount ?? 1

        for group in burstGroups {
            let sorted = group.files
                .compactMap { file in liveFile(id: file.id) }
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

                // ── Composite score ranking ───────────────────────────────────
                // Sort by composite score descending; tie-break on focusScore,
                // then afOverlapsSubject, then rawSharpnessScore, then burst order.
                let ranked = candidates.sorted { a, b in
                    let scoreA = settings?.burstCompositeScore(
                        focusScore: a.focusScore,
                        subjectBodyArea: a.subjectBodyArea,
                        exposureAssessment: a.exposureAssessment) ?? a.focusScore
                    let scoreB = settings?.burstCompositeScore(
                        focusScore: b.focusScore,
                        subjectBodyArea: b.subjectBodyArea,
                        exposureAssessment: b.exposureAssessment) ?? b.focusScore
                    if scoreA != scoreB { return scoreA > scoreB }
                    if a.focusScore != b.focusScore { return a.focusScore > b.focusScore }
                    let afA = a.afOverlapsSubject ?? false
                    let afB = b.afOverlapsSubject ?? false
                    if afA != afB { return afA }
                    if a.rawSharpnessScore != b.rawSharpnessScore {
                        return a.rawSharpnessScore > b.rawSharpnessScore
                    }
                    return (a.modificationDate ?? .distantFuture) < (b.modificationDate ?? .distantFuture)
                }

                for (rank, candidate) in ranked.enumerated() {
                    guard let idx = index(for: candidate.id) else { continue }
                    let rankNumber = rank + 1
                    // Only assign a crown badge for photos within the keep window.
                    // keepCount == 0 means burst ranking UI is disabled entirely.
                    if keepCount > 0 && rankNumber <= keepCount {
                        rawFiles[idx].burstRank = rankNumber
                        if rankNumber == 1 {
                            rawFiles[idx].isBurstSharpnessBest = true
                        }
                    }
                    // burstNonWinnerAction fires for photos outside the top-N,
                    // but only when burstKeepCount > 0 (feature is enabled).
                    if keepCount > 0 && rankNumber > keepCount && !rawFiles[idx].pickIsOverridden,
                       let action = settings?.burstNonWinnerAction {
                        applyOutcomeAction(action, to: idx)
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
                    if let idx = index(for: candidate.id) {
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

    nonisolated private static func collectRAWFiles(in directory: URL) -> [RAWFile] {
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

    nonisolated private static func scanForRAWFiles() -> [RAWFile] {
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
