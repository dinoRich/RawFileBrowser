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
    /// Strength of the unsharp mask applied to each crop before Laplacian scoring.
    /// 0 = no sharpening, 1 = maximum sharpening.
    /// The default (0.4) is conservative: enough to recover edge detail lost to
    /// JPEG compression in the embedded preview, but not enough to inflate scores
    /// on genuinely blurry images.
    @Published var sharpenIntensity: Double {
        didSet { UserDefaults.standard.set(sharpenIntensity, forKey: "sharpenIntensity") }
    }

    // ── Species ID confidence threshold ──────────────────────────────────
    /// Minimum YOLO confidence (0–1) required before a detected species name
    /// is shown in the UI or written to an XMP sidecar.
    /// Detection always runs in full — this only controls what is displayed.
    /// Default 0.5 (50 %).
    @Published var speciesConfidenceThreshold: Double {
        didSet { UserDefaults.standard.set(speciesConfidenceThreshold, forKey: "speciesConfidenceThreshold") }
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

    // MARK: Init

    init() {
        // Sharpening — default 0.4
        self.sharpenIntensity = UserDefaults.standard.object(forKey: "sharpenIntensity") as? Double ?? 0.4

        // Species confidence threshold — default 0.5 (50 %)
        self.speciesConfidenceThreshold = UserDefaults.standard.object(forKey: "speciesConfidenceThreshold") as? Double ?? 0.5

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

    func visibleSpeciesLabel(label: String?, confidence: Float?) -> String? {
        guard let label else { return nil }
        // Vision fallback has no numeric confidence — always show it.
        guard let confidence else { return label }
        return Double(confidence) >= speciesConfidenceThreshold ? label : nil
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
}
