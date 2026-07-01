import SwiftUI
import Combine

// MARK: - Focus outcome action
//
// Describes what the app automatically does to a photo when focus analysis
// produces a particular result (sharp / slightly blurry / blurry).
//
// Each of the three actions is independent — the user can set a pick status,
// a star rating, AND a colour label for the same outcome if they want.

struct FocusOutcomeAction: Codable, Equatable {
    /// Pick flag to apply. `.unpicked` means "do nothing".
    var pick: PickStatus = .unpicked
    /// Star rating to apply (1-5). 0 means "do nothing".
    var stars: Int = 0
    /// Colour label to apply. `.none` means "do nothing".
    var colour: LabelColour = .none
}

// MARK: - AppSettings

/// Persists user preferences across app launches using UserDefaults via @AppStorage.
/// Create one instance in the app root and pass it through the environment:
///
///   .environmentObject(AppSettings())
///
/// Any view that needs settings can then read them with:
///
///   @EnvironmentObject var settings: AppSettings
///
final class AppSettings: ObservableObject {

    // ── Sharpening ────────────────────────────────────────────────────────
    // ── Sharpness thresholds ──────────────────────────────────────────────
    //
    // Control how the Laplacian variance score (0–1) maps to badge colours.
    //   score >= sharpThreshold      → Sharp  (green)
    //   score >= acceptableThreshold → Slightly Blurry (orange)
    //   score < acceptableThreshold  → Blurry (red)
    //
    // Defaults match the hardcoded RegionThresholds in FocusAnalyzer.
    // Tune these in Settings after running analysis on a known set of photos.

    @Published var sharpThreshold: Double {
        didSet { UserDefaults.standard.set(sharpThreshold, forKey: "sharpThreshold") }
    }
    @Published var acceptableThreshold: Double {
        didSet { UserDefaults.standard.set(acceptableThreshold, forKey: "acceptableThreshold") }
    }

    // ── Species ID confidence thresholds (per subject size) ───────────────
    //
    // Minimum classifier confidence required to display a species ID,
    // depending on how much of the frame the subject occupies.
    // Tighter (higher) thresholds for smaller subjects reduce confident
    // misidentifications caused by background texture dominating the crop.

    @Published var speciesConfidenceTiny: Double {       // subject < 1% of frame
        didSet { UserDefaults.standard.set(speciesConfidenceTiny,   forKey: "speciesConfidenceTiny") }
    }
    @Published var speciesConfidenceSmall: Double {      // subject 1–5% of frame
        didSet { UserDefaults.standard.set(speciesConfidenceSmall,  forKey: "speciesConfidenceSmall") }
    }
    @Published var speciesConfidenceMedium: Double {     // subject 5–10% of frame
        didSet { UserDefaults.standard.set(speciesConfidenceMedium, forKey: "speciesConfidenceMedium") }
    }
    @Published var speciesConfidenceLarge: Double {      // subject 10–25% of frame
        didSet { UserDefaults.standard.set(speciesConfidenceLarge,  forKey: "speciesConfidenceLarge") }
    }
    @Published var speciesConfidenceFull: Double {       // subject 25%+ of frame
        didSet { UserDefaults.standard.set(speciesConfidenceFull,   forKey: "speciesConfidenceFull") }
    }

    // ── Similar photo detection ───────────────────────────────────────────
    /// Maximum Hamming distance (differing bits out of 64) between two perceptual
    /// hashes for the photos to be considered "similar".
    /// Lower = stricter (only near-identical photos match).
    /// Higher = looser (more photos grouped together).
    /// Range 1–20. Default 10.
    @Published var similarityThreshold: Int {
        didSet { UserDefaults.standard.set(similarityThreshold, forKey: "similarityThreshold") }
    }

    /// Maximum minutes between two photos' capture times for them to be eligible
    /// for similar grouping. Prevents photos from different subjects photographed
    /// in the same session being bridged by a tonal match.
    /// Range 5–120. Default 30.
    @Published var sessionWindowMinutes: Int {
        didSet { UserDefaults.standard.set(sessionWindowMinutes, forKey: "sessionWindowMinutes") }
    }

    /// Maximum colour histogram distance (0–1) for two photos to be grouped as similar.
    /// 0 = identical colour distribution. 1 = no overlap.
    /// Near-grey/low-saturation images produce flat histograms and are unaffected.
    /// Range 0.1–1.0. Default 0.45.
    @Published var colourSimilarityThreshold: Double {
        didSet { UserDefaults.standard.set(colourSimilarityThreshold, forKey: "colourSimilarityThreshold") }
    }

    // ── Focus outcome actions ────────────────────────────────────────────
    /// What to do automatically when a photo is rated Sharp.
    @Published var sharpAction: FocusOutcomeAction {
        didSet { saveAction(sharpAction, key: "sharpAction") }
    }
    /// What to do automatically when a photo is rated Slightly Blurry.
    @Published var slightlyBlurAction: FocusOutcomeAction {
        didSet { saveAction(slightlyBlurAction, key: "slightlyBlurAction") }
    }
    /// What to do automatically when a photo is rated Blurry.
    @Published var blurryAction: FocusOutcomeAction {
        didSet { saveAction(blurryAction, key: "blurryAction") }
    }

    // ── Flag-based outcome actions ───────────────────────────────────────
    // Applied on top of the focus status action above. If both fire,
    // non-default values in the flag action override the status action.

    /// Applied when the subject's bounding rect touches within 2% of any image edge.
    @Published var subjectClippedAction: FocusOutcomeAction {
        didSet { saveAction(subjectClippedAction, key: "subjectClippedAction") }
    }
    /// Applied when a photo is significantly softer than its burst peers (outlier).
    @Published var softInBurstAction: FocusOutcomeAction {
        didSet { saveAction(softInBurstAction, key: "softInBurstAction") }
    }
    /// Applied when the subject (or image) has too many blown highlight pixels.
    @Published var overexposedAction: FocusOutcomeAction {
        didSet { saveAction(overexposedAction, key: "overexposedAction") }
    }
    /// Applied when the subject (or image) has too many blocked shadow pixels.
    @Published var underexposedAction: FocusOutcomeAction {
        didSet { saveAction(underexposedAction, key: "underexposedAction") }
    }

    /// Applied when the camera AF point was found but did NOT overlap the detected subject.
    /// Distinct from blurry — the subject may be sharp, but the camera focused on the wrong thing.
    @Published var afMissedSubjectAction: FocusOutcomeAction {
        didSet { saveAction(afMissedSubjectAction, key: "afMissedSubjectAction") }
    }
    /// Applied when no animal or human subject was detected in the frame at all.
    /// Fires independently of focus status — a no-subject frame may still be sharp (e.g. habitat shot).
    @Published var noSubjectDetectedAction: FocusOutcomeAction {
        didSet { saveAction(noSubjectDetectedAction, key: "noSubjectDetectedAction") }
    }
    /// Applied when the detected subject occupies less than minSubjectAreaThreshold of the frame.
    /// Fires independently of focus status. Does NOT fire when no subject was detected at all.
    @Published var subjectTooSmallAction: FocusOutcomeAction {
        didSet { saveAction(subjectTooSmallAction, key: "subjectTooSmallAction") }
    }
    /// Applied when blur type is identified as motion blur rather than defocus.
    /// Allows photographers to keep intentional panning shots while rejecting defocus.
    /// Fires in addition to the focus status action — configure to taste.
    @Published var motionBlurAction: FocusOutcomeAction {
        didSet { saveAction(motionBlurAction, key: "motionBlurAction") }
    }
    /// Applied to photos in a burst that are NOT in the best-N (burstKeepCount).
    /// Only fires after burst ranking has run and burstKeepCount > 0.
    @Published var burstNonWinnerAction: FocusOutcomeAction {
        didSet { saveAction(burstNonWinnerAction, key: "burstNonWinnerAction") }
    }

    // ── Exposure thresholds ──────────────────────────────────────────────
    // Fraction of subject pixels (0–1) that must be clipped before the
    // overexposed / underexposed action fires. Subject pixels are checked
    // first; whole-image highlight clipping is used as a fallback.

    /// Fraction of subject pixels at ≥250/255 brightness before overexposed fires.
    /// Default 0.03 (3%). Range 0.01–0.20.
    @Published var overexposureThreshold: Double {
        didSet { UserDefaults.standard.set(overexposureThreshold, forKey: "overexposureThreshold") }
    }
    /// Fraction of subject pixels at ≤5/255 brightness before underexposed fires.
    /// Default 0.10 (10%). Range 0.02–0.40.
    @Published var underexposureThreshold: Double {
        didSet { UserDefaults.standard.set(underexposureThreshold, forKey: "underexposureThreshold") }
    }

    // ── Composition thresholds ───────────────────────────────────────────

    /// Minimum subject body area (fraction of image, 0–1) below which
    /// subjectTooSmallAction fires. Default 0.01 (1%). Range 0.001–0.10.
    @Published var minSubjectAreaThreshold: Double {
        didSet { UserDefaults.standard.set(minSubjectAreaThreshold, forKey: "minSubjectAreaThreshold") }
    }

    // ── Burst ranking ────────────────────────────────────────────────────
    // Controls how many photos are kept per burst (burstKeepCount) and how
    // the composite ranking score is calculated from individual metrics.
    // Weights must sum to 1.0; they are normalised at runtime if they drift.

    /// Number of photos to keep per burst (rank 1…N are "winners").
    /// 0 = disabled (burstNonWinnerAction never fires). Default 1.
    @Published var burstKeepCount: Int {
        didSet { UserDefaults.standard.set(burstKeepCount, forKey: "burstKeepCount") }
    }
    /// Weight of sharpness score in burst composite ranking. Default 0.6.
    @Published var burstRankSharpnessWeight: Double {
        didSet { UserDefaults.standard.set(burstRankSharpnessWeight, forKey: "burstRankSharpnessWeight") }
    }
    /// Weight of exposure quality in burst composite ranking. Default 0.25.
    @Published var burstRankExposureWeight: Double {
        didSet { UserDefaults.standard.set(burstRankExposureWeight, forKey: "burstRankExposureWeight") }
    }
    /// Weight of subject body area in burst composite ranking. Default 0.15.
    @Published var burstRankSubjectSizeWeight: Double {
        didSet { UserDefaults.standard.set(burstRankSubjectSizeWeight, forKey: "burstRankSubjectSizeWeight") }
    }

    // MARK: Init

    init() {
        // Sharpness thresholds — defaults match RegionThresholds.body in FocusAnalyzer
        self.sharpThreshold      = UserDefaults.standard.object(forKey: "sharpThreshold")      as? Double ?? 0.62
        self.acceptableThreshold = UserDefaults.standard.object(forKey: "acceptableThreshold") as? Double ?? 0.32

        // Species confidence thresholds (per size band)
        self.speciesConfidenceTiny   = UserDefaults.standard.object(forKey: "speciesConfidenceTiny")   as? Double ?? 0.90
        self.speciesConfidenceSmall  = UserDefaults.standard.object(forKey: "speciesConfidenceSmall")  as? Double ?? 0.80
        self.speciesConfidenceMedium = UserDefaults.standard.object(forKey: "speciesConfidenceMedium") as? Double ?? 0.70
        self.speciesConfidenceLarge  = UserDefaults.standard.object(forKey: "speciesConfidenceLarge")  as? Double ?? 0.60
        self.speciesConfidenceFull   = UserDefaults.standard.object(forKey: "speciesConfidenceFull")   as? Double ?? 0.50

        // Similarity threshold — default 10 bits
        self.similarityThreshold = UserDefaults.standard.object(forKey: "similarityThreshold") as? Int ?? 10

        // Session window — default 30 minutes
        self.sessionWindowMinutes = UserDefaults.standard.object(forKey: "sessionWindowMinutes") as? Int ?? 30

        // Colour similarity threshold — default 0.45
        self.colourSimilarityThreshold = UserDefaults.standard.object(forKey: "colourSimilarityThreshold") as? Double ?? 0.45

        // Outcome actions — sensible defaults that match the previous hardcoded behaviour:
        //   sharp        → accepted
        //   slightlyBlur → accepted  (previously treated same as sharp)
        //   blurry       → rejected
        self.sharpAction        = AppSettings.loadAction(key: "sharpAction")
                               ?? FocusOutcomeAction(pick: .accepted, stars: 0, colour: .none)
        self.slightlyBlurAction = AppSettings.loadAction(key: "slightlyBlurAction")
                               ?? FocusOutcomeAction(pick: .accepted, stars: 0, colour: .none)
        self.blurryAction       = AppSettings.loadAction(key: "blurryAction")
                               ?? FocusOutcomeAction(pick: .rejected, stars: 0, colour: .none)

        // Flag-based actions — default: do nothing
        self.subjectClippedAction   = AppSettings.loadAction(key: "subjectClippedAction")
                                   ?? FocusOutcomeAction()
        self.softInBurstAction      = AppSettings.loadAction(key: "softInBurstAction")
                                   ?? FocusOutcomeAction()
        self.overexposedAction      = AppSettings.loadAction(key: "overexposedAction")
                                   ?? FocusOutcomeAction()
        self.underexposedAction     = AppSettings.loadAction(key: "underexposedAction")
                                   ?? FocusOutcomeAction()
        self.afMissedSubjectAction  = AppSettings.loadAction(key: "afMissedSubjectAction")
                                   ?? FocusOutcomeAction()
        self.noSubjectDetectedAction = AppSettings.loadAction(key: "noSubjectDetectedAction")
                                    ?? FocusOutcomeAction()
        self.subjectTooSmallAction  = AppSettings.loadAction(key: "subjectTooSmallAction")
                                   ?? FocusOutcomeAction()
        self.motionBlurAction       = AppSettings.loadAction(key: "motionBlurAction")
                                   ?? FocusOutcomeAction()
        self.burstNonWinnerAction   = AppSettings.loadAction(key: "burstNonWinnerAction")
                                   ?? FocusOutcomeAction()

        // Exposure thresholds
        self.overexposureThreshold  = UserDefaults.standard.object(forKey: "overexposureThreshold")  as? Double ?? 0.03
        self.underexposureThreshold = UserDefaults.standard.object(forKey: "underexposureThreshold") as? Double ?? 0.10

        // Composition thresholds
        self.minSubjectAreaThreshold = UserDefaults.standard.object(forKey: "minSubjectAreaThreshold") as? Double ?? 0.01

        // Burst ranking
        self.burstKeepCount              = UserDefaults.standard.object(forKey: "burstKeepCount")              as? Int    ?? 1
        self.burstRankSharpnessWeight    = UserDefaults.standard.object(forKey: "burstRankSharpnessWeight")    as? Double ?? 0.60
        self.burstRankExposureWeight     = UserDefaults.standard.object(forKey: "burstRankExposureWeight")     as? Double ?? 0.25
        self.burstRankSubjectSizeWeight  = UserDefaults.standard.object(forKey: "burstRankSubjectSizeWeight")  as? Double ?? 0.15
    }

    // MARK: - Persistence helpers

    private static func loadAction(key: String) -> FocusOutcomeAction? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FocusOutcomeAction.self, from: data)
    }

    private func saveAction(_ action: FocusOutcomeAction, key: String) {
        if let data = try? JSONEncoder().encode(action) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Species display helper
    //
    // Returns the species label only when the detection confidence meets
    // the user-configured threshold. Pass nil confidence (Vision fallback)
    // to always show — Vision does not produce a numeric confidence score.

    // MARK: - Species threshold for a given subject area

    /// Returns the confidence threshold appropriate for a subject occupying
    /// `area` fraction of the image (normalised 0–1 area value).
    func speciesThreshold(for area: Float) -> Double {
        switch Double(area) {
        case ..<0.01: return speciesConfidenceTiny
        case ..<0.05: return speciesConfidenceSmall
        case ..<0.10: return speciesConfidenceMedium
        case ..<0.25: return speciesConfidenceLarge
        default:      return speciesConfidenceFull
        }
    }

    // MARK: - Species display helper

    func visibleSpeciesLabel(label: String?, confidence: Float?,
                             subjectBodyArea: Double = 0) -> String? {
        guard let label else { return nil }
        guard let confidence else { return label }   // Vision fallback: always show
        let threshold = speciesThreshold(for: Float(subjectBodyArea))
        return Double(confidence) >= threshold ? label : nil
    }

    // MARK: - Exposure issue check (using user-configured thresholds)
    //
    // Returns the exposure verdict using the user's configured clip thresholds
    // rather than the hardcoded values in ExposureAssessment.verdict.
    // Subject clip fractions take priority over whole-image signals.

    func exposureIssue(for ea: ExposureAssessment) -> ExposureVerdict? {
        if let hc = ea.subjectHighlightClipFraction, hc >= overexposureThreshold  { return .overexposed  }
        if let sc = ea.subjectShadowClipFraction,    sc >= underexposureThreshold { return .underexposed }
        if ea.highlightClipFraction >= overexposureThreshold { return .overexposed }
        return nil
    }

    // MARK: - Apply to a file
    //
    // Given a focus status, returns the action the user configured for that outcome.

    func action(for status: FocusStatus) -> FocusOutcomeAction {
        switch status {
        case .sharp:        return sharpAction
        case .slightlyBlur: return slightlyBlurAction
        case .blurry:       return blurryAction
        case .unanalyzed:   return FocusOutcomeAction() // do nothing
        }
    }

    // MARK: - Burst composite score
    //
    // Produces a single 0–1 ranking value for a photo within a burst.
    // Weights are normalised to sum to 1.0 to guard against misconfiguration.
    // exposureScore: 1.0 = well exposed, 0.5 = under/overexposed, 0.0 = unknown.

    func burstCompositeScore(focusScore: Double,
                             subjectBodyArea: Double,
                             exposureAssessment: ExposureAssessment?) -> Double {
        let totalWeight = burstRankSharpnessWeight + burstRankExposureWeight + burstRankSubjectSizeWeight
        guard totalWeight > 0 else { return focusScore }
        let wS = burstRankSharpnessWeight   / totalWeight
        let wE = burstRankExposureWeight    / totalWeight
        let wA = burstRankSubjectSizeWeight / totalWeight

        // Exposure: good = 1.0, any issue = 0.5, no data = 0.5
        let exposureScore: Double
        if let ea = exposureAssessment {
            exposureScore = (exposureIssue(for: ea) == nil) ? 1.0 : 0.5
        } else {
            exposureScore = 0.5
        }

        // Subject area is already 0–1 (fraction of image). Cap at 0.5 to avoid
        // heavily penalising tight crops that fill the frame — that's desirable.
        let areaScore = min(subjectBodyArea * 4.0, 1.0) // 25%+ of frame → 1.0

        return wS * focusScore + wE * exposureScore + wA * areaScore
    }
}
