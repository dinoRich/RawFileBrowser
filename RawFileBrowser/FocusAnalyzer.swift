import Foundation
import CoreImage
import ImageIO
import UIKit
import Vision

// MARK: - Public types

enum FocusStatus: String, Codable, Hashable, Equatable {
    case sharp        = "Sharp"
    case slightlyBlur = "Slightly Blurry"
    case blurry       = "Blurry"
    case unanalyzed   = "Not Analyzed"

    /// True for outcomes where the photo should be considered a reject
    var isRejected: Bool {
        self == .blurry
    }

    var systemImage: String {
        switch self {
        case .sharp:        return "checkmark.circle.fill"
        case .slightlyBlur: return "exclamationmark.circle.fill"
        case .blurry:       return "xmark.circle.fill"
        case .unanalyzed:   return "questionmark.circle"
        }
    }

    var color: UIColor {
        switch self {
        case .sharp:        return .systemGreen
        case .slightlyBlur: return .systemOrange
        case .blurry:       return .systemRed
        case .unanalyzed:   return .systemGray
        }
    }
}

enum BlurType: String {
    case none       = "None"
    case defocus    = "Out of Focus"
    case motionBlur = "Motion Blur"
    case mixed      = "Mixed"
    case unknown    = "Unknown"
}

struct FocusResult {
    let status: FocusStatus
    let score: Double
    let analysisRegion: AnalysisRegion
    let blurType: BlurType
    let subjectSizeConfidence: Double
    let detectedAnimalLabel: String?
    /// Normalised (0-1) rect of the analysed region, top-left origin.
    let analysisRect: CGRect?
    /// Normalised (0-1) contour points tracing each detected subject's silhouette.
    /// Derived from VNGenerateForegroundInstanceMaskRequest — the same API used
    /// by Photos' "lift subject". Empty when no subject was localised.
    let subjectContour: [[CGPoint]]
    /// Detection confidence from YOLO (0-1), nil if Vision fallback was used
    let detectionConfidence: Float?
    /// Whether the AF point overlapped the detected subject.
    /// nil = no AF point or no subject detected (overlap not applicable).
    let afOverlapsSubject: Bool?
    /// Whether the AF point specifically overlapped the detected eye region.
    /// nil = no AF point, or no eye was detected (can't say either way).
    /// true = AF covered the eye. false = eye found but AF missed it.
    let afOnEye: Bool?
    /// True when an AF point was found but did NOT overlap the detected subject.
    /// The sharpness status reflects the subject body independently of this flag.
    let afNotOnSubject: Bool

    // MARK: Diagnostic fields
    /// Laplacian score BEFORE the size-confidence multiplier (0–1 normalised).
    /// Compare against the threshold values to see how close the call was.
    let rawSharpnessScore: Double
    /// What fraction of the image area the subject BODY occupied (0–1).
    let subjectBodyArea: Double
    /// What fraction of the image area the SCORING rect (eyes/head/AF) occupied (0–1).
    let scoringRectArea: Double
    /// Whether a camera AF point was found in the Makernote.
    let hadAFPoint: Bool
    /// The sharp threshold used for this region (for display in diagnostics).
    let sharpThreshold: Double
    /// The acceptable (slightly blurry) threshold used for this region.
    let acceptableThreshold: Double

    // MARK: Dual-score fields (Case 5 — AF intersects subject)
    /// Raw Laplacian score measured specifically AT the AF point rect (0–1, before size penalty).
    /// nil unless this was a Case 5 result (AF intersects subject).
    let afPointRawScore: Double?
    /// Raw Laplacian score measured AT the subject body rect (0–1, before size penalty).
    /// nil unless this was a Case 5 result (AF intersects subject).
    let subjectBodyRawScore: Double?
    /// Which region was actually used to determine the final rating.
    let ratingBasis: RatingBasis

    // MARK: Species identification — populated alongside focus analysis
    /// Species label from the classifier, e.g. "Short Eared Owl".
    /// nil when no animal was detected or confidence was below the base threshold.
    let speciesLabel: String?
    /// Classifier confidence for speciesLabel (0–1). nil when no detection was made.
    let speciesConfidence: Float?
    /// Top-N species candidates sorted highest-confidence first.
    /// Contains up to 5 entries for use in the diagnostic view.
    let speciesCandidates: [(label: String, confidence: Float)]

    // MARK: Exposure assessment
    /// Exposure quality signals measured from the embedded JPEG preview.
    /// nil only for the synthetic `unanalyzed()` sentinel value.
    let exposureAssessment: ExposureAssessment?

    // MARK: Frame geometry flags
    /// True when the subject's bounding rect is within 2% of any image edge,
    /// indicating the subject is clipped by the frame.
    var subjectClipped: Bool = false

    /// Describes which region drove the final sharpness rating and why.
    enum RatingBasis: String {
        case afPoint         = "AF Point"                    // Case 5: AF score met sharp threshold
        case subjectBody     = "Subject Body"                // Cases 2, 3, 4, or Case 5 fallback
        case afPointDegraded = "Subject (AF Point Degraded)" // Case 5: AF below sharp, subject used instead
        case fullImage       = "Full Image"                  // Case 1
    }

    enum AnalysisRegion: String {
        case yoloEyes     = "Eyes (YOLO)"
        case yoloHead     = "Head (YOLO)"
        case yoloBody     = "Body (YOLO)"
        case animalEyes   = "Animal Eyes"
        case animalHead   = "Animal Head"
        case animalBody   = "Animal Body"
        case humanEyes    = "Human Eyes"
        case humanFace    = "Human Face"
        case afOnSubject  = "AF on Subject"   // AF point confirmed on animal/person
        case afPoint      = "AF Point"        // AF point only (no subject detected)
        case missedFocus  = "Missed Focus"    // AF point confirmed NOT on subject
        case fullImage    = "Full Image"
    }
}

// MARK: - Exposure assessment

/// All exposure-quality signals computed during focus analysis.
/// Measured from the embedded JPEG preview — values are approximate
/// but consistent and useful for relative comparisons within a shoot.
struct ExposureAssessment {

    // ── Whole-image signals ───────────────────────────────────────────────

    /// Fraction of pixels at or above brightness 250/255 (blown highlights).
    /// 0–1. Above ~0.02 (2%) means noticeable clipping.
    let highlightClipFraction: Double

    /// Fraction of pixels at or below brightness 5/255 (blocked shadows).
    /// 0–1. A small amount is normal; above ~0.05 (5%) is heavy.
    let shadowClipFraction: Double

    /// Mean luminance of the whole image, 0–1 (0 = black, 1 = white).
    let meanLuminance: Double

    // ── Subject-specific signals (nil when no subject was detected) ───────

    /// Mean luminance of the subject bounding box region, 0–1.
    let subjectMeanLuminance: Double?

    /// Fraction of subject pixels that are blown highlights (≥ 250/255).
    let subjectHighlightClipFraction: Double?

    /// Fraction of subject pixels that are blocked shadows (≤ 5/255).
    let subjectShadowClipFraction: Double?

    // ── Computed verdicts ─────────────────────────────────────────────────

    /// Overall exposure verdict.
    /// Subject pixel clip fractions are the primary signal when available —
    /// they are more reliable than mean luminance because wildlife subjects
    /// often have non-average brightness relative to the background.
    var verdict: ExposureVerdict {
        // Subject clip fractions are the most precise signal.
        if let hc = subjectHighlightClipFraction, hc > 0.03 { return .overexposed  }
        if let sc = subjectShadowClipFraction,    sc > 0.10 { return .underexposed }
        // Subject mean luminance as a secondary check.
        if let sl = subjectMeanLuminance {
            if sl < 0.12 { return .underexposed }
            if sl > 0.88 { return .overexposed  }
        }
        // Fall back to whole-image signals.
        if highlightClipFraction > 0.05 { return .overexposed  }
        if meanLuminance         < 0.12 { return .underexposed }
        if meanLuminance         > 0.82 { return .overexposed  }
        return .good
    }

    /// Human-readable one-liner for use in diagnostic displays.
    var summaryLabel: String {
        switch verdict {
        case .good:         return "Well exposed"
        case .overexposed:  return "Overexposed"
        case .underexposed: return "Underexposed"
        }
    }

    var verdictColor: UIColor {
        switch verdict {
        case .good:         return .systemGreen
        case .overexposed:  return .systemRed
        case .underexposed: return .systemBlue
        }
    }
}

enum ExposureVerdict: String {
    case good         = "Good"
    case overexposed  = "Overexposed"
    case underexposed = "Underexposed"
}

// MARK: - Per-region sharpness thresholds
//
// normalisationDivisor: raw Laplacian variance is divided by this to produce a 0-1 score.
// The smaller the crop, the sharper it tends to look at pixel level, so eye crops
// need a higher divisor to avoid over-rewarding tiny sharp patches.
// sharp / acceptable: fallback values used when no user thresholds are provided.

private struct RegionThresholds {
    let normalisationDivisor: Double
    let sharp: Double
    let acceptable: Double

    static let eyes = RegionThresholds(normalisationDivisor: 200,  sharp: 0.55, acceptable: 0.25)
    static let head = RegionThresholds(normalisationDivisor: 400,  sharp: 0.60, acceptable: 0.30)
    static let body = RegionThresholds(normalisationDivisor: 700,  sharp: 0.62, acceptable: 0.32)
    static let full = RegionThresholds(normalisationDivisor: 1000, sharp: 0.65, acceptable: 0.35)
}

// User-configurable sharp / acceptable thresholds that override the per-region
// defaults above. Passed through the call chain from analyze() → score().
private struct SharpnessThresholds {
    let sharp:      Double
    let acceptable: Double
}

private enum Threshold {
    /// Minimum fractional area for a detected region to be trusted
    static let minSubjectArea = 0.002
    /// Horizontal:vertical variance ratio that implies motion blur
    static let motionRatio    = 2.5
    /// Absolute padding (normalised 0-1) added to the AF rect before overlap test.
    static let afPaddingForOverlap: CGFloat = 0
}

// MARK: - FocusAnalyzer

struct FocusAnalyzer {

    // Shared CIContext — creating a new CIContext per image is expensive and
    // can cause createCGImage to return nil under memory pressure.
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Serial queue for VNGenerateForegroundInstanceMaskRequest.
    /// Running multiple mask requests concurrently causes the same Neural Engine
    /// contention as concurrent YOLO calls — none complete. Serialising fixes this.
    private static let maskQueue = DispatchQueue(label: "com.sharpeye.visionmask",
                                                  qos: .userInitiated)

    // MARK: - Entry point
    //
    // Decision tree:
    //
    //  1. Try to read the camera AF point from the file's Makernote.
    //  2. Try to detect a subject (animal / human) using Apple Vision / YOLO.
    //
    //  Case 1 — no AF, no subject           →  full image sharpness
    //  Case 2 — no AF, subject              →  subject body sharpness
    //  Case 3 — AF + subject, no overlap,
    //           subject below acceptable    →  Missed Focus, rate on subject
    //  Case 4 — AF + subject, no overlap,
    //           subject meets acceptable    →  Possible Missed Focus, rate on subject
    //  Case 5 — AF + subject, overlap       →  dual score AF point vs subject body;
    //           AF sharp → use AF;  AF degraded → use subject

    // Convenience overload: loads the thumbnail then calls the cgImage variant.
    // Used for single-file re-analysis. Bulk analysis calls analyze(cgImage:url:)
    // directly after loading thumbnails serially to avoid SD card contention.
    static func analyze(url: URL,
                        sharpThreshold:      Double = 0.62,
                        acceptableThreshold: Double = 0.32) async -> FocusResult {
        guard let cgImage = loadThumbnail(from: url, maxDimension: 2048) else {
            return unanalyzed()
        }
        return await analyze(cgImage: cgImage, url: url,
                             sharpThreshold: sharpThreshold,
                             acceptableThreshold: acceptableThreshold)
    }

    // Primary entry point. Accepts an already-decoded CGImage so that bulk
    // analysis can load thumbnails serially (avoiding SD card I/O contention)
    // then run Vision/YOLO analysis concurrently on the in-memory images.
    static func analyze(cgImage: CGImage,
                        url: URL,
                        sharpThreshold:      Double = 0.62,
                        acceptableThreshold: Double = 0.32) async -> FocusResult {

        // Step 1 — AF point from camera Makernote
        let afRegion    = extractAFRegion(from: url,
                                          imageWidth: cgImage.width,
                                          imageHeight: cgImage.height)
        let afRect      = afRegion?.rect
        let afConfirmed = afRegion?.confirmed ?? false

        async let subjectTask = detectSubject(in: cgImage)
        async let speciesTask = SpeciesDetector.classify(cgImage: cgImage, subjectBodyRect: nil)
        let subject       = await subjectTask
        let speciesResult = await speciesTask

        // Step 3 — Exposure assessment
        let exposure = assessExposure(cgImage: cgImage,
                                      subjectRect: subject.bodyRect ?? subject.bestRect)

        // Step 5 — Route to the correct analysis path
        var result = route(cgImage: cgImage, afRect: afRect, afConfirmed: afConfirmed,
                           subject: subject, sharpenIntensity: 0.4,
                           thresholds: SharpnessThresholds(sharp: sharpThreshold,
                                                           acceptable: acceptableThreshold))

        // Step 6 — Subject clipping: is the subject rect within 2% of any image edge?
        // Only computed when a contour exists — the contour body rect is tight and
        // reliable. Vision detection rects (used when no contour) can cover the full
        // image and would generate spurious clipping flags.
        let edgeMargin: CGFloat = 0.02
        let clipped: Bool = subject.contours.isEmpty ? false : (subject.bodyRect.map { r in
            r.minX < edgeMargin || r.minY < edgeMargin ||
            r.maxX > (1.0 - edgeMargin) || r.maxY > (1.0 - edgeMargin)
        } ?? false)

        result = FocusResult(
            status:                result.status,
            score:                 result.score,
            analysisRegion:        result.analysisRegion,
            blurType:              result.blurType,
            subjectSizeConfidence: result.subjectSizeConfidence,
            detectedAnimalLabel:   result.detectedAnimalLabel,
            analysisRect:          result.analysisRect,
            subjectContour:        result.subjectContour,
            detectionConfidence:   result.detectionConfidence,
            afOverlapsSubject:     result.afOverlapsSubject,
            afOnEye:               result.afOnEye,
            afNotOnSubject:        result.afNotOnSubject,
            rawSharpnessScore:     result.rawSharpnessScore,
            subjectBodyArea:       result.subjectBodyArea,
            scoringRectArea:       result.scoringRectArea,
            hadAFPoint:            result.hadAFPoint,
            sharpThreshold:        result.sharpThreshold,
            acceptableThreshold:   result.acceptableThreshold,
            afPointRawScore:       result.afPointRawScore,
            subjectBodyRawScore:   result.subjectBodyRawScore,
            ratingBasis:           result.ratingBasis,
            speciesLabel:          speciesResult.label,
            speciesConfidence:     speciesResult.confidence,
            speciesCandidates:     speciesResult.candidates,
            exposureAssessment:    exposure
        )
        result.subjectClipped = clipped
        return result
    }

    // MARK: - Routing
    //
    // Decision tree (new logic):
    //
    //  Case 1 — no AF, no subject  →  full image sharpness
    //  Case 2 — no AF, subject     →  subject body sharpness
    //  Case 3 — AF + subject, no overlap, subject FAILS acceptable threshold
    //           → Missed Focus, rate on subject body
    //  Case 4 — AF + subject, no overlap, subject MEETS acceptable threshold
    //           → Possible Missed Focus, rate on subject body
    //  Case 5 — AF + subject, overlap
    //           → Score both AF point AND subject body.
    //             If AF score meets sharp threshold → use AF score  (label: AF on Subject)
    //             If AF score is below sharp but subject meets acceptable → use subject score
    //                                                                        (label: AF on Subject — Focus Degraded at AF Point)
    //             If both are poor → use subject score  (label: AF on Subject — Out of Focus)
    //  (bonus) AF only, no subject → score at AF point

    private static func route(cgImage: CGImage,
                               afRect: CGRect?,
                               afConfirmed: Bool = false,
                               subject: SubjectResult,
                               sharpenIntensity: Double = 0.4,
                               thresholds: SharpnessThresholds) -> FocusResult {

        let hasAF      = afRect != nil
        // hasSubject is true when any of the following found something:
        // YOLO, Vision eyes/head/face, or the foreground mask contour.
        // Previously only bestRect (YOLO/Vision) gated this, meaning a photo
        // with a clear contour but no YOLO/Vision hit was treated as Case 1.
        let hasSubject = subject.bestRect != nil || !subject.contours.isEmpty

        switch (hasAF, hasSubject) {

        // ── Case 5 / Case 3 / Case 4: AF + Subject ──────────────────────────
        case (true, true):
            let af = afRect!
            // bestRect may be nil when subject was detected via contour only —
            // fall back to bodyRect (contour bbox) which is always set when contours exist.
            let subjectBody = subject.bodyRect ?? subject.bestRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)

            let expandedAF = af.insetBy(
                dx: -Threshold.afPaddingForOverlap,
                dy: -Threshold.afPaddingForOverlap
            ).clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

            let overlaps: Bool
            if !subject.contours.isEmpty {
                // Test centre + all four corners against each subject's contour.
                // If any sample point is inside any contour, the AF bracket
                // meaningfully covers at least one subject.
                let samples = [
                    CGPoint(x: expandedAF.midX, y: expandedAF.midY),
                    CGPoint(x: expandedAF.minX, y: expandedAF.minY),
                    CGPoint(x: expandedAF.maxX, y: expandedAF.minY),
                    CGPoint(x: expandedAF.minX, y: expandedAF.maxY),
                    CGPoint(x: expandedAF.maxX, y: expandedAF.maxY),
                ]
                overlaps = subject.contours.contains { contour in
                    contour.count >= 3 && samples.contains { contourContainsPoint(contour, point: $0) }
                }
            } else {
                overlaps = expandedAF.intersects(subjectBody)
            }
            let afOnEye  = afCoversEye(afRect: af, eyeRect: subject.eyeRect)

            if overlaps {
                // ── Case 5: AF on subject — dual score ──────────────────────
                return scoreAFOnSubject(cgImage: cgImage,
                                        afRect: af,
                                        afConfirmed: afConfirmed,
                                        subjectBody: subjectBody,
                                        subject: subject,
                                        afOnEye: afOnEye,
                                        sharpenIntensity: sharpenIntensity,
                                        thresholds: thresholds)
            } else {
                // ── Cases 3 & 4: AF NOT on subject ──────────────────────────
                return missedFocusResult(cgImage: cgImage,
                                         afRect: af,
                                         subjectRect: subjectBody,
                                         label: subject.label,
                                         confidence: subject.confidence,
                                         afOnEye: afOnEye,
                                         subjectContour: subject.contours,
                                         sharpenIntensity: sharpenIntensity,
                                         thresholds: thresholds)
            }

        // ── AF only (no subject detected) ────────────────────────────────────
        case (true, false):
            return scoreAtRect(afRect!,
                               in: cgImage,
                               region: .afPoint,
                               label: nil,
                               confidence: nil,
                               afOverlaps: nil,
                               hadAF: true,
                               thresholds: thresholds,
                               ratingBasis: .afPoint)

        // ── Case 2: Subject only (no AF data) ────────────────────────────────
        case (false, true):
            // bestRect may be nil when subject was detected via contour only.
            let bodyRect = subject.bodyRect ?? subject.bestRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            return scoreAtRect(bodyRect,
                               in: cgImage,
                               region: .animalBody,
                               label: subject.label,
                               confidence: subject.confidence,
                               afOverlaps: nil,
                               bodyRect: bodyRect,
                               subjectContour: subject.contours,
                               thresholds: thresholds,
                               ratingBasis: .subjectBody)

        // ── Case 1: No AF, no subject ─────────────────────────────────────────
        case (false, false):
            return scoreFullImage(cgImage: cgImage, thresholds: thresholds)
        }
    }

    // MARK: - Case 5 dual-score: AF intersects subject

    private static func scoreAFOnSubject(cgImage: CGImage,
                                          afRect: CGRect,
                                          afConfirmed: Bool = false,
                                          subjectBody: CGRect,
                                          subject: SubjectResult,
                                          afOnEye: Bool?,
                                          sharpenIntensity: Double = 0.4,
                                          thresholds: SharpnessThresholds) -> FocusResult {

        // Score the AF point crop — subject pixels only.
        // Important: do NOT apply a size-confidence penalty to the AF score.
        // The AF point rect is intentionally tiny (camera hardware, not detection error).
        // Applying the small-subject penalty would push nearly every AF score below
        // the sharp threshold, causing the body score to win by default every time.
        //
        // We use the contour-masked Laplacian so that background pixels inside the AF
        // rect (e.g. blurry sky behind the subject's edge) are excluded from the score.
        // Only pixels whose normalised image position falls inside the subject contour
        // contribute to the variance, giving a clean read on subject sharpness alone.
        // If no contour is available the function falls back to the plain scorer.
        let afRaw = contourMaskedLaplacian(cgImage: cgImage,
                                           normRect: afRect,
                                           contours: subject.contours,
                                           sharpenIntensity: sharpenIntensity) ?? 0.0
        let afThresh  = RegionThresholds.body
        let afFinal   = min(afRaw / afThresh.normalisationDivisor, 1.0)  // no size penalty

        // Score the subject body crop
        let bodySizeConf = subjectSizeConfidence(rect: subjectBody,
                                                 imageWidth: cgImage.width,
                                                 imageHeight: cgImage.height)
        let bodyCropped  = crop(cgImage, to: subjectBody)
        let bodyRaw      = bodyCropped.flatMap { rawLaplacian(cgImage: $0, sharpenIntensity: sharpenIntensity) } ?? 0.0
        let bodyThresh   = RegionThresholds.body
        let bodyFinal    = min(bodyRaw / bodyThresh.normalisationDivisor, 1.0) * bodySizeConf

        let bodyArea    = Double(subjectBody.width * subjectBody.height)
        let scoringArea = Double(afRect.width * afRect.height)

        // Normalise both scores for threshold comparison and display.
        let afNorm   = min(afRaw   / afThresh.normalisationDivisor,   1.0)
        let bodyNorm = min(bodyRaw / bodyThresh.normalisationDivisor,  1.0)
        let bodyFinalWithConf = bodyNorm * bodySizeConf

        // Decide which score to use.
        //
        // The body score is the default in all cases. The AF score can only win if:
        //   (a) afConfirmed — camera reported isInFocus = true at this point
        //   (b) afClearlyBetter — AF score beats body by at least afBoostMargin,
        //       meaning the AF region has genuinely more fine detail than the body
        //       crop (rules out noise and minor fluctuations)
        //   (c) bodyIsNearSharp — body score is already within borderlineMargin of
        //       the sharp threshold, so the AF score is confirming a near-sharp photo
        //       rather than overriding a poor one
        //
        // Without (a): an unconfirmed selected-only point is not reliable enough.
        // Without (b): AF on feathers vs AF on eye would produce different results
        //              for the same photo — the exact inconsistency we are fixing.
        // Without (c): a high AF score on a blurry body would inflate the rating.
        let afBoostMargin    = 0.15
        let borderlineMargin = 0.20

        let bodyIsNearSharp = bodyNorm >= (thresholds.sharp - borderlineMargin)
        let afClearlyBetter = afNorm   >= (bodyNorm + afBoostMargin)

        let basis: FocusResult.RatingBasis
        let useRaw:   Double
        let useFinal: Double

        if afConfirmed && afClearlyBetter && bodyIsNearSharp {
            basis    = .afPoint
            useRaw   = afNorm
            useFinal = afNorm
        } else {
            basis    = afNorm >= bodyNorm ? .subjectBody : .afPointDegraded
            useRaw   = bodyNorm
            useFinal = bodyFinalWithConf
        }

        let blurType: BlurType
        if useFinal >= thresholds.sharp {
            blurType = .none
        } else if useFinal < thresholds.acceptable {
            blurType = .defocus
        } else {
            blurType = .mixed
        }

        let status: FocusStatus
        switch useFinal {
        case thresholds.sharp...:      status = .sharp
        case thresholds.acceptable...: status = .slightlyBlur
        default:                        status = .blurry
        }

        return FocusResult(status: status,
                           score: useFinal,
                           analysisRegion: .afOnSubject,
                           blurType: blurType,
                           subjectSizeConfidence: bodySizeConf,
                           detectedAnimalLabel: subject.label,
                           analysisRect: afRect,
                           subjectContour: subject.contours,
                           detectionConfidence: subject.confidence,
                           afOverlapsSubject: true,
                           afOnEye: afOnEye,
                           afNotOnSubject: false,
                           rawSharpnessScore: useRaw,
                           subjectBodyArea: bodyArea,
                           scoringRectArea: scoringArea,
                           hadAFPoint: true,
                           sharpThreshold: thresholds.sharp,
                           acceptableThreshold: thresholds.acceptable,
                           afPointRawScore: afNorm,
                           subjectBodyRawScore: bodyNorm,
                           ratingBasis: basis,
                           speciesLabel: nil,
                           speciesConfidence: nil,
                           speciesCandidates: [],
                           exposureAssessment: nil)
    }

    /// Shared CIContext for all sharpening operations.
    /// Creating a CIContext is expensive (it sets up GPU resources), so we reuse
    /// a single instance across all calls rather than allocating one per photo.
    private static let ciContext = CIContext()

    /// Applies a mild unsharp mask to a crop before Laplacian scoring.
    /// This compensates for JPEG compression softening in the embedded preview,
    /// which would otherwise cause the Laplacian to underestimate true sharpness.
    /// Strength is deliberately conservative: enough to recover edge detail lost
    /// to JPEG compression, but not enough to inflate scores on genuinely blurry images.
    /// If the filter fails for any reason, the original image is returned unchanged.
    private static func sharpenCrop(_ image: CGImage, intensity: Double = 0.4) -> CGImage {
        guard intensity > 0 else { return image }
        let ciImage = CIImage(cgImage: image)
        let filter  = CIFilter(name: "CIUnsharpMask")!
        filter.setValue(ciImage,   forKey: kCIInputImageKey)
        filter.setValue(1.0,       forKey: kCIInputRadiusKey)    // edge detection radius in pixels
        filter.setValue(intensity, forKey: kCIInputIntensityKey) // sharpening strength (0=none, 1=strong)
        guard let output = filter.outputImage else { return image }
        return ciContext.createCGImage(output, from: output.extent) ?? image
    }

    /// Computes raw Laplacian variance for a normalised rect, counting only pixels
    /// whose position in the full image falls inside at least one subject contour.
    ///
    /// Background pixels are simply skipped — they are never added to the sums or
    /// to `n`. Because the final variance is divided by `n`, skipped pixels contribute
    /// nothing to the result. There are no artificial edges and no score dilution.
    ///
    /// Falls back to plain `rawLaplacian` on the cropped rect when `contours` is empty,
    /// so callers never need to guard against the no-contour case themselves.
    ///
    /// - Parameters:
    ///   - cgImage:   The full (thumbnail) image — NOT a pre-cropped region.
    ///   - normRect:  The AF point rect in normalised 0-1 coords, top-left origin.
    ///   - contours:  Subject silhouette contours in normalised 0-1 coords, top-left origin.
    private static func contourMaskedLaplacian(cgImage: CGImage,
                                               normRect: CGRect,
                                               contours: [[CGPoint]],
                                               sharpenIntensity: Double = 0.4) -> Double? {
        // No contour available — fall back to the standard scorer on the plain crop.
        guard !contours.isEmpty else {
            guard let cropped = crop(cgImage, to: normRect) else { return nil }
            return rawLaplacian(cgImage: cropped, sharpenIntensity: sharpenIntensity)
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Crop the AF rect out of the full image and render into a pixel buffer.
        let cropX = Int((normRect.minX * imgW).rounded())
        let cropY = Int((normRect.minY * imgH).rounded())
        let cropW = max(Int((normRect.width  * imgW).rounded()), 3)
        let cropH = max(Int((normRect.height * imgH).rounded()), 3)

        guard let cropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY,
                                                         width: cropW, height: cropH))
        else { return nil }

        let bpr = cropW * 4
        var pixels = [UInt8](repeating: 0, count: cropH * bpr)
        guard let ctx = CGContext(data: &pixels, width: cropW, height: cropH,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let sharpened = sharpenCrop(cropped, intensity: sharpenIntensity)
        ctx.draw(sharpened, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))

        // Walk every interior pixel. For each one, convert its position back to
        // normalised image space and test whether it lies inside any subject contour.
        // Only pixels that pass the test contribute to the Laplacian variance sums.
        var sumH = 0.0, ssH = 0.0, sumV = 0.0, ssV = 0.0, n = 0.0

        for py in 1..<(cropH - 1) {
            for px in 1..<(cropW - 1) {

                // Normalised position of the centre of this pixel in the full image.
                let nx = (CGFloat(cropX + px) + 0.5) / imgW
                let ny = (CGFloat(cropY + py) + 0.5) / imgH
                let pt = CGPoint(x: nx, y: ny)

                // Skip pixel if it does not belong to any subject contour.
                let insideSubject = contours.contains { contour in
                    contour.count >= 3 && contourContainsPoint(contour, point: pt)
                }
                guard insideSubject else { continue }

                let c = gray(pixels, x: px,   y: py,   w: cropW)
                let l = gray(pixels, x: px-1, y: py,   w: cropW)
                let r = gray(pixels, x: px+1, y: py,   w: cropW)
                let t = gray(pixels, x: px,   y: py-1, w: cropW)
                let b = gray(pixels, x: px,   y: py+1, w: cropW)
                let lH = Double(2*c - l - r)
                let lV = Double(2*c - t - b)
                sumH += lH; ssH += lH * lH
                sumV += lV; ssV += lV * lV
                n += 1
            }
        }

        // If no pixels were inside the contour (very small subject, contour mismatch),
        // fall back to the plain scorer so we always return a usable value.
        guard n > 0 else {
            return rawLaplacian(cgImage: cropped, sharpenIntensity: sharpenIntensity)
        }

        let varH = (ssH / n) - pow(sumH / n, 2)
        let varV = (ssV / n) - pow(sumV / n, 2)
        return sqrt(max(varH, 0) * max(varV, 0))
    }

    /// Computes raw Laplacian variance for a CGImage crop without building a full FocusResult.
    /// Returns the combined sqrt(varH * varV) value — the same metric used in score().
    private static func rawLaplacian(cgImage: CGImage, sharpenIntensity: Double = 0.4) -> Double? {
        // Cap the scoring resolution to 512px on the longest side.
        // Laplacian variance is reliable at this size and the pixel iteration
        // is O(w*h) — scoring a 500x400 AF crop at full 2048px resolution takes
        // 20s; capped to 512px it takes <0.1s with no meaningful accuracy loss.
        let maxScoringDimension = 512
        let scale = min(1.0, Double(maxScoringDimension) / Double(max(cgImage.width, cgImage.height)))
        let w = max(3, Int(Double(cgImage.width)  * scale))
        let h = max(3, Int(Double(cgImage.height) * scale))
        guard w > 2 && h > 2 else { return nil }
        let bpr = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Apply mild sharpening before scoring to compensate for JPEG compression
        // softening in the embedded preview. This makes the Laplacian a more accurate
        // proxy for the true sharpness of the underlying RAW sensor data.
        let sharpened = sharpenCrop(cgImage, intensity: sharpenIntensity)
        ctx.draw(sharpened, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sumH = 0.0, ssH = 0.0, sumV = 0.0, ssV = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = gray(pixels, x: x,   y: y,   w: w)
                let l = gray(pixels, x: x-1, y: y,   w: w)
                let r = gray(pixels, x: x+1, y: y,   w: w)
                let t = gray(pixels, x: x,   y: y-1, w: w)
                let b = gray(pixels, x: x,   y: y+1, w: w)
                let lH = Double(2*c - l - r), lV = Double(2*c - t - b)
                sumH += lH; ssH += lH*lH; sumV += lV; ssV += lV*lV; n += 1
            }
        }
        guard n > 0 else { return nil }
        let varH = (ssH/n) - pow(sumH/n, 2)
        let varV = (ssV/n) - pow(sumV/n, 2)
        return sqrt(max(varH, 0) * max(varV, 0))
    }

    // MARK: - AF / eye overlap check

    /// Returns true if the AF rect meaningfully overlaps the detected eye region.
    /// Uses the raw (un-expanded) AF rect — we only want to claim eye coverage
    /// when the camera actually aimed at the eye, not just nearby.
    /// nil if either rect is absent (can't determine either way).
    private static func afCoversEye(afRect: CGRect?, eyeRect: CGRect?) -> Bool? {
        guard let af = afRect, let eye = eyeRect else { return nil }
        let expandedAF = af.insetBy(dx: -0.05, dy: -0.05)
            .clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return expandedAF.intersects(eye)
    }
    
    /// Returns true if the given point lies inside the polygon defined by contour points.
    /// Uses the ray-casting algorithm — works for any simple (non-self-intersecting) polygon.
    private static func contourContainsPoint(_ contour: [CGPoint], point: CGPoint) -> Bool {
        var inside = false
        var j = contour.count - 1
        for i in 0..<contour.count {
            let xi = contour[i].x, yi = contour[i].y
            let xj = contour[j].x, yj = contour[j].y
            if ((yi > point.y) != (yj > point.y)) &&
                (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
    
    // MARK: - Cases 3 & 4: AF not on subject

    /// AF point found but does NOT overlap the subject.
    /// Scores subject body sharpness, then decides:
    ///   • Subject below acceptable → Missed Focus (Case 3)
    ///   • Subject meets acceptable  → Possible Missed Focus (Case 4)
    private static func missedFocusResult(cgImage: CGImage,
                                           afRect: CGRect,
                                           subjectRect: CGRect,
                                           label: String?,
                                           confidence: Float?,
                                           afOnEye: Bool? = nil,
                                           subjectContour: [[CGPoint]] = [],
                                           sharpenIntensity: Double = 0.4,
                                           thresholds: SharpnessThresholds) -> FocusResult {

        let sizeConf   = subjectSizeConfidence(rect: subjectRect,
                                               imageWidth: cgImage.width,
                                               imageHeight: cgImage.height)
        let regionThresh = RegionThresholds.body
        let bodyArea   = Double(subjectRect.width * subjectRect.height)

        let rawScore: Double
        let finalScore: Double
        if let cropped = crop(cgImage, to: subjectRect), cropped.width > 4, cropped.height > 4,
           let lap = rawLaplacian(cgImage: cropped, sharpenIntensity: sharpenIntensity) {
            rawScore   = min(lap / regionThresh.normalisationDivisor, 1.0)
            finalScore = rawScore * sizeConf
        } else {
            rawScore   = 0
            finalScore = 0
        }

        let focusStatus: FocusStatus
        switch finalScore {
        case thresholds.sharp...:      focusStatus = .sharp
        case thresholds.acceptable...: focusStatus = .slightlyBlur
        default:                       focusStatus = .blurry
        }

        let blurType: BlurType
        if finalScore >= thresholds.sharp {
            blurType = .none
        } else if finalScore < thresholds.acceptable {
            blurType = .defocus
        } else {
            blurType = .mixed
        }

        return FocusResult(
            status:                focusStatus,
            score:                 finalScore,
            analysisRegion:        .missedFocus,
            blurType:              blurType,
            subjectSizeConfidence: sizeConf,
            detectedAnimalLabel:   label,
            analysisRect:          afRect,
            subjectContour:        subjectContour,
            detectionConfidence:   confidence,
            afOverlapsSubject:     false,
            afOnEye:               afOnEye,
            afNotOnSubject:        true,
            rawSharpnessScore:     rawScore,
            subjectBodyArea:       bodyArea,
            scoringRectArea:       Double(afRect.width * afRect.height),
            hadAFPoint:            true,
            sharpThreshold:        thresholds.sharp,
            acceptableThreshold:   thresholds.acceptable,
            afPointRawScore:       nil,
            subjectBodyRawScore:   rawScore,
            ratingBasis:           .subjectBody,
            speciesLabel:          nil,
            speciesConfidence:     nil,
            speciesCandidates:     [],
            exposureAssessment:    nil
        )
    }

    // MARK: - Score at a specific normalised rect

    private static func scoreAtRect(_ normRect: CGRect,
                                     in cgImage: CGImage,
                                     region: FocusResult.AnalysisRegion,
                                     label: String?,
                                     confidence: Float?,
                                     afOverlaps: Bool?,
                                     afOnEye: Bool? = nil,
                                     bodyRect: CGRect? = nil,
                                     hadAF: Bool = false,
                                     subjectContour: [[CGPoint]] = [],
                                     thresholds: SharpnessThresholds,
                                     ratingBasis: FocusResult.RatingBasis = .subjectBody) -> FocusResult {
        let sizeConf = subjectSizeConfidence(rect: bodyRect ?? normRect,
                                             imageWidth: cgImage.width,
                                             imageHeight: cgImage.height)

        let bodyArea    = Double((bodyRect ?? normRect).width * (bodyRect ?? normRect).height)
        let scoringArea = Double(normRect.width * normRect.height)

        guard let cropped = crop(cgImage, to: normRect), cropped.width > 4, cropped.height > 4 else {
            return scoreFullImage(cgImage: cgImage, label: label, confidence: confidence,
                                  afOverlaps: afOverlaps, afOnEye: afOnEye, hadAF: hadAF,
                                  thresholds: thresholds, ratingBasis: ratingBasis)
        }

        return score(cgImage: cropped,
                     region: region,
                     sizeConfidence: sizeConf,
                     analysisRect: normRect,
                     animalLabel: label,
                     detectionConfidence: confidence,
                     afOverlapsSubject: afOverlaps,
                     afOnEye: afOnEye,
                     bodyArea: bodyArea,
                     scoringArea: scoringArea,
                     hadAF: hadAF,
                     thresholds: thresholds,
                     ratingBasis: ratingBasis,
                     subjectContour: subjectContour)
    }

    private static func scoreFullImage(cgImage: CGImage,
                                        label: String? = nil,
                                        confidence: Float? = nil,
                                        afOverlaps: Bool? = nil,
                                        afOnEye: Bool? = nil,
                                        hadAF: Bool = false,
                                        thresholds: SharpnessThresholds,
                                        ratingBasis: FocusResult.RatingBasis = .fullImage) -> FocusResult {
        score(cgImage: cgImage,
              region: .fullImage,
              sizeConfidence: 0.7,
              analysisRect: nil,
              animalLabel: label,
              detectionConfidence: confidence,
              afOverlapsSubject: afOverlaps,
              afOnEye: afOnEye,
              hadAF: hadAF,
              thresholds: thresholds,
              ratingBasis: ratingBasis)
    }

    // MARK: - Subject detection

    // A unified struct that both the YOLO path and the Vision path fill in.
    private struct SubjectResult {
        /// The best available rect for this subject (eyes > head > body)
        let bestRect:   CGRect?
        /// The subject's eye rect specifically — used to test AF-on-eye
        let eyeRect:    CGRect?
        /// The subject's full body rect (used for overlap checking against AF point)
        let bodyRect:   CGRect?
        /// One contour per detected subject instance from VNGenerateForegroundInstanceMaskRequest.
        /// Used to draw the subject silhouette overlay. Empty when unavailable.
        let contours:   [[CGPoint]]
        let label:      String?
        let confidence: Float?
    }

    private static func detectSubject(in cgImage: CGImage) async -> SubjectResult {
        // Contour detection only — YOLO is no longer called here.
        // SpeciesDetector.classify handles YOLO separately. Running YOLO twice
        // per photo (once here, once in SpeciesDetector) doubled Neural Engine
        // load and caused 2–35 second stalls when multiple analyses ran concurrently.
        let contours: [[CGPoint]]
        if #available(iOS 17.0, *) {
            contours = await foregroundMaskContour(cgImage: cgImage)
        } else {
            contours = []
        }

        // Bounding rect of all contours combined — used for overlap testing and size confidence.
        let allContourPoints = contours.flatMap { $0 }
        let contourBodyRect: CGRect? = allContourPoints.isEmpty ? nil : boundingRectWithPadding(allContourPoints, pad: 0)

        // Fall back to Apple Vision animal/human detection for geometric subject localisation.
        async let animalResult = detectAnimalRegion(in: cgImage)
        async let humanResult  = detectHumanRegion(in: cgImage)
        let animal = await animalResult
        let human  = await humanResult

        // For Vision paths, prefer the contour bbox as bodyRect.
        // VNRecognizeAnimalsRequest bodyRect is full-image and must not be used.
        func bodyRect(visionRect: CGRect?, visionIsLocalised: Bool) -> CGRect? {
            contourBodyRect ?? (visionIsLocalised ? visionRect : nil)
        }

        if let eyes = animal.eyeRect, eyes.area > 0.0004 {
            return SubjectResult(bestRect: eyes, eyeRect: eyes,
                                 bodyRect: bodyRect(visionRect: animal.bodyRect, visionIsLocalised: true),
                                 contours: contours,
                                 label: animal.animalLabel, confidence: nil)
        }
        if let head = animal.headRect {
            return SubjectResult(bestRect: head, eyeRect: nil,
                                 bodyRect: bodyRect(visionRect: animal.bodyRect, visionIsLocalised: true),
                                 contours: contours,
                                 label: animal.animalLabel, confidence: nil)
        }
        if let eyes = human.eyeRect, eyes.area > 0.0004 {
            return SubjectResult(bestRect: eyes, eyeRect: eyes,
                                 bodyRect: bodyRect(visionRect: human.faceRect, visionIsLocalised: true),
                                 contours: contours,
                                 label: nil, confidence: nil)
        }
        if let face = human.faceRect {
            return SubjectResult(bestRect: face, eyeRect: nil,
                                 bodyRect: bodyRect(visionRect: face, visionIsLocalised: true),
                                 contours: contours,
                                 label: nil, confidence: nil)
        }

        // No Vision detection. If we have a contour, use its bbox as the subject.
        if let cbr = contourBodyRect {
            return SubjectResult(bestRect: cbr, eyeRect: nil, bodyRect: cbr,
                                 contours: contours, label: nil, confidence: nil)
        }

        return SubjectResult(bestRect: nil, eyeRect: nil, bodyRect: nil,
                             contours: [], label: nil, confidence: nil)
    }

    // MARK: - Foreground subject mask contour (iOS 17+)
    //
    // VNGenerateForegroundInstanceMaskRequest is the API behind Photos' "lift subject".
    // We generate the mask, scale it to a small greyscale image, then run
    // VNDetectContoursRequest on it to get a clean vector outline of the subject.
    // The resulting contour points are in normalised 0-1 coords, top-left origin.

    @available(iOS 17.0, *)
    private static func foregroundMaskContour(cgImage: CGImage) async -> [[CGPoint]] {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[[CGPoint]], Never>) in

            maskQueue.async {
            let maskRequest = VNGenerateForegroundInstanceMaskRequest()
            let handler     = VNImageRequestHandler(cgImage: cgImage, options: [:])

            guard (try? handler.perform([maskRequest])) != nil,
                  let observation = maskRequest.results?.first,
                  !observation.allInstances.isEmpty else {
                continuation.resume(returning: [])
                return
            }

            // Merge ALL instances into one mask rather than processing each separately.
            // Processing per-instance produces competing fragments (e.g. a bird's wing
            // and body become two small regions). Merging gives one unified subject region.
            let allInstances = IndexSet(observation.allInstances.map { Int($0) })
            guard let maskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: allInstances, from: handler) else {
                continuation.resume(returning: [])
                return
            }

            let bufW = CVPixelBufferGetWidth(maskBuffer)
            let bufH = CVPixelBufferGetHeight(maskBuffer)

            // Convert the float mask buffer to a CGImage at native resolution via CIImage,
            // then draw it scaled into a greyscale bitmap using CGContext. Drawing through
            // CGContext applies bilinear filtering, producing stable anti-aliased edges
            // across burst frames. The previous nearest-neighbour pixel loop landed
            // differently on each frame due to minor JPEG differences, causing the
            // inconsistent contour detection seen within bursts.
            let targetSize = 512
            let ciMask = CIImage(cvPixelBuffer: maskBuffer)

            guard let maskCG = sharedCIContext.createCGImage(
                ciMask, from: ciMask.extent)
            else {
                continuation.resume(returning: [])
                return
            }

            var grey = [UInt8](repeating: 0, count: targetSize * targetSize)
            guard let greyCtx = CGContext(
                data: &grey, width: targetSize, height: targetSize,
                bitsPerComponent: 8, bytesPerRow: targetSize,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else {
                continuation.resume(returning: [])
                return
            }
            greyCtx.draw(maskCG, in: CGRect(x: 0, y: 0,
                                             width: targetSize,
                                             height: targetSize))

            // Threshold at 0.3 (76/255): captures ambiguous boundary pixels
            // (thin necks, legs, partially-camouflaged edges) cut out at 0.5.
            var anyWhite = false
            for i in 0..<(targetSize * targetSize) {
                if grey[i] > 76 { grey[i] = 255; anyWhite = true }
                else { grey[i] = 0 }
            }
            guard anyWhite else {
                continuation.resume(returning: [])
                return
            }

            guard let greyImage = greyCtx.makeImage() else {
                continuation.resume(returning: [])
                return
            }

            let contourRequest = VNDetectContoursRequest()
            contourRequest.detectsDarkOnLight = false
            let contourHandler = VNImageRequestHandler(cgImage: greyImage, options: [:])
            guard (try? contourHandler.perform([contourRequest])) != nil,
                  let contourObs = contourRequest.results?.first else {
                continuation.resume(returning: [])
                return
            }

            // Filter top-level contours: reject tiny fragments (< 0.5% of image area).
            var allContours: [[CGPoint]] = []
            for outerContour in contourObs.topLevelContours {
                let rawPoints   = outerContour.normalizedPoints
                let totalPoints = rawPoints.count
                guard totalPoints >= 6 else { continue }

                let step = max(1, totalPoints / 300)
                var result: [CGPoint] = []
                result.reserveCapacity(min(totalPoints, 300))
                var i = 0
                while i < totalPoints {
                    let p = rawPoints[i]
                    result.append(CGPoint(x: CGFloat(p.x), y: 1.0 - CGFloat(p.y)))
                    i += step
                }

                let bbox = boundingRectWithPadding(result, pad: 0)
                guard !result.isEmpty, bbox.area > 0.005 else { continue }
                allContours.append(result)
            }

            continuation.resume(returning: allContours)
            } // end maskQueue.async
        }
    }
        /// Morphological dilation: expands white (255) pixels outward by `radius` pixels.
    /// Used to bridge small gaps in the foreground mask that would otherwise fragment
    /// the subject into disconnected regions.
    private static func dilateMask(_ input: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard input[y * width + x] > 0 else { continue }
                let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
                let x0 = max(0, x - radius), x1 = min(width  - 1, x + radius)
                for dy in y0...y1 { for dx in x0...x1 {
                    output[dy * width + dx] = 255
                }}
            }
        }
        return output
    }

    // MARK: - YOLO helpers

    private static func bestAnimalDetection(from detections: [YOLODetection]) -> YOLODetection? {
        let animals = detections.filter { $0.isAnimal }
        return animals.max(by: { $0.confidence < $1.confidence })
            ?? detections.max(by: { $0.confidence < $1.confidence })
    }

    // MARK: - Vision animal detection

    private struct AnimalDetectionResult {
        let eyeRect:     CGRect?
        let headRect:    CGRect?
        let bodyRect:    CGRect?
        let animalLabel: String?
    }

    private static func detectAnimalRegion(in cgImage: CGImage) async -> AnimalDetectionResult {
        if #available(iOS 17.0, *) {
            let poseResult = await detectAnimalPoseiOS17(cgImage: cgImage)
            if poseResult.bodyRect != nil { return poseResult }
        }
        return detectAnimalRectangle(cgImage: cgImage)
    }

    @available(iOS 17.0, *)
    private static func detectAnimalPoseiOS17(cgImage: CGImage) async -> AnimalDetectionResult {
        return await withCheckedContinuation { continuation in
            let request = VNDetectAnimalBodyPoseRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            guard (try? handler.perform([request])) != nil,
                  let observations = request.results,
                  !observations.isEmpty else {
                continuation.resume(returning: AnimalDetectionResult(
                    eyeRect: nil, headRect: nil, bodyRect: nil, animalLabel: nil))
                return
            }

            let primary = observations.max(by: {
                $0.availableJointNames.count < $1.availableJointNames.count
            })!

            var allPoints:  [CGPoint] = []
            var eyePoints:  [CGPoint] = []
            var headPoints: [CGPoint] = []

            for jointName in primary.availableJointNames {
                guard let pt = try? primary.recognizedPoint(jointName),
                      pt.confidence > 0.2 else { continue }
                let flipped = CGPoint(x: pt.location.x, y: 1.0 - pt.location.y)
                allPoints.append(flipped)
                let name = jointName.rawValue.rawValue.lowercased()
                if name.contains("eye") {
                    eyePoints.append(flipped); headPoints.append(flipped)
                } else if name.contains("ear") || name.contains("nose") || name.contains("head") {
                    headPoints.append(flipped)
                }
            }

            let eyeRect  = eyePoints.isEmpty  ? nil : boundingRectWithPadding(eyePoints,  pad: 0.06)
            let headRect = headPoints.isEmpty ? nil : boundingRectWithPadding(headPoints, pad: 0.04)
            let bodyRect = allPoints.isEmpty  ? nil : boundingRectWithPadding(allPoints,  pad: 0.02)

            let labelReq = VNRecognizeAnimalsRequest()
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([labelReq])
            let label = labelReq.results?.first?.labels
                .max(by: { $0.confidence < $1.confidence })?.identifier

            continuation.resume(returning: AnimalDetectionResult(
                eyeRect: eyeRect, headRect: headRect, bodyRect: bodyRect, animalLabel: label))
        }
    }

    private static func detectAnimalRectangle(cgImage: CGImage) -> AnimalDetectionResult {
        let request = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results, !results.isEmpty else {
            return AnimalDetectionResult(eyeRect: nil, headRect: nil, bodyRect: nil, animalLabel: nil)
        }

        let largest = results.max(by: { $0.boundingBox.area < $1.boundingBox.area })!
        let body    = flipRect(largest.boundingBox)
        let head    = CGRect(x: body.minX, y: body.minY,
                             width: body.width, height: body.height * 0.30)
        let label   = largest.labels.max(by: { $0.confidence < $1.confidence })?.identifier
        return AnimalDetectionResult(eyeRect: nil, headRect: head, bodyRect: body, animalLabel: label)
    }

    // MARK: - Vision human detection

    private struct HumanDetectionResult {
        let eyeRect:  CGRect?
        let faceRect: CGRect?
    }

    private static func detectHumanRegion(in cgImage: CGImage) async -> HumanDetectionResult {
        return await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])

            guard let faces = request.results, !faces.isEmpty else {
                continuation.resume(returning: HumanDetectionResult(eyeRect: nil, faceRect: nil))
                return
            }

            let largest  = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area })!
            let faceRect = flipRect(largest.boundingBox)

            var eyePts: [CGPoint] = []
            if let lm = largest.landmarks {
                func add(_ r: VNFaceLandmarkRegion2D?) {
                    guard let r else { return }
                    let bb = largest.boundingBox
                    for pt in r.normalizedPoints {
                        eyePts.append(CGPoint(
                            x: bb.minX + pt.x * bb.width,
                            y: 1.0 - (bb.minY + pt.y * bb.height)
                        ))
                    }
                }
                add(lm.leftEye); add(lm.rightEye)
                add(lm.leftPupil); add(lm.rightPupil)
            }

            let eyeRect: CGRect? = eyePts.isEmpty ? nil : boundingRectWithPadding(eyePts, pad: 0.04)
            continuation.resume(returning: HumanDetectionResult(eyeRect: eyeRect, faceRect: faceRect))
        }
    }

    // MARK: - Sharpness scoring (Laplacian variance)
    //
    // We compute the variance of the discrete Laplacian (a measure of edge strength)
    // across the cropped region. A sharp image has high variance; a blurry image has low.
    // We use both horizontal and vertical Laplacians to detect motion blur direction.

    private static func score(cgImage: CGImage,
                               region: FocusResult.AnalysisRegion,
                               sizeConfidence: Double,
                               analysisRect: CGRect?,
                               animalLabel: String?,
                               detectionConfidence: Float?,
                               afOverlapsSubject: Bool?,
                               afOnEye: Bool? = nil,
                               bodyArea: Double = 0,
                               scoringArea: Double = 0,
                               hadAF: Bool = false,
                               thresholds: SharpnessThresholds,
                               ratingBasis: FocusResult.RatingBasis = .subjectBody,
                               afPointRawScore: Double? = nil,
                               subjectBodyRawScore: Double? = nil,
                               subjectContour: [[CGPoint]] = []) -> FocusResult {
        let w = cgImage.width, h = cgImage.height
        guard w > 2 && h > 2 else { return unanalyzed() }

        let bpr    = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return unanalyzed() }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sumH = 0.0, ssH = 0.0, sumV = 0.0, ssV = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = gray(pixels, x: x,   y: y,   w: w)
                let l = gray(pixels, x: x-1, y: y,   w: w)
                let r = gray(pixels, x: x+1, y: y,   w: w)
                let t = gray(pixels, x: x,   y: y-1, w: w)
                let b = gray(pixels, x: x,   y: y+1, w: w)
                let lH = Double(2*c - l - r), lV = Double(2*c - t - b)
                sumH += lH; ssH += lH*lH; sumV += lV; ssV += lV*lV; n += 1
            }
        }
        guard n > 0 else { return unanalyzed() }

        let varH = (ssH/n) - pow(sumH/n, 2)
        let varV = (ssV/n) - pow(sumV/n, 2)
        let combined = sqrt(max(varH, 0) * max(varV, 0))

        // Use the per-region divisor only for normalising the raw value to 0-1.
        // The sharp/acceptable verdict uses the user-provided thresholds.
        let regionThresh: RegionThresholds
        switch region {
        case .animalEyes, .humanEyes:                         regionThresh = .eyes
        case .animalHead, .humanFace, .yoloHead:              regionThresh = .head
        case .yoloEyes:                                       regionThresh = .eyes
        case .yoloBody, .animalBody, .afOnSubject, .afPoint:  regionThresh = .body
        default:                                              regionThresh = .full
        }

        let rawScore   = min(combined / regionThresh.normalisationDivisor, 1.0)
        let finalScore = rawScore * sizeConfidence

        let maxVar = max(varH, varV), minVar = min(varH, varV)
        let blurType: BlurType
        if finalScore >= thresholds.sharp {
            blurType = .none
        } else if maxVar > 1.0 && (minVar / maxVar) < (1.0 / Threshold.motionRatio) {
            blurType = .motionBlur
        } else if finalScore < thresholds.acceptable {
            blurType = .defocus
        } else {
            blurType = .mixed
        }

        let status: FocusStatus
        switch finalScore {
        case thresholds.sharp...:      status = .sharp
        case thresholds.acceptable...: status = .slightlyBlur
        default:                       status = .blurry
        }

        return FocusResult(status: status, score: finalScore, analysisRegion: region,
                           blurType: blurType, subjectSizeConfidence: sizeConfidence,
                           detectedAnimalLabel: animalLabel, analysisRect: analysisRect,
                           subjectContour: subjectContour,
                           detectionConfidence: detectionConfidence,
                           afOverlapsSubject: afOverlapsSubject,
                           afOnEye: afOnEye,
                           afNotOnSubject: false,
                           rawSharpnessScore: rawScore,
                           subjectBodyArea: bodyArea,
                           scoringRectArea: scoringArea,
                           hadAFPoint: hadAF,
                           sharpThreshold: thresholds.sharp,
                           acceptableThreshold: thresholds.acceptable,
                           afPointRawScore: afPointRawScore,
                           subjectBodyRawScore: subjectBodyRawScore,
                           ratingBasis: ratingBasis,
                           speciesLabel: nil,
                           speciesConfidence: nil,
                           speciesCandidates: [],
                           exposureAssessment: nil)  // filled in by analyze() after routing
    }

    // MARK: - Subject size confidence
    //
    // Reduces the final score when the subject region is very small in the frame.
    // A tiny crop is more likely to produce a misleadingly high sharpness score
    // (a single sharp hair, a glinting eye) that doesn't reflect the overall image.

    private static func subjectSizeConfidence(rect: CGRect,
                                              imageWidth: Int,
                                              imageHeight: Int) -> Double {
        let area = Double(rect.width * rect.height)
        if area >= Threshold.minSubjectArea * 5 { return 1.0 }
        if area <  Threshold.minSubjectArea      { return 0.3 }
        return 0.3 + 0.7 * (area - Threshold.minSubjectArea) / (Threshold.minSubjectArea * 4)
    }

    // MARK: - EXIF AF point extraction

    private static func extractAFRegion(from url: URL,
                                        imageWidth: Int,
                                        imageHeight: Int) -> (rect: CGRect, confirmed: Bool)? {
        guard let points = CanonMakernoteParser.extractAFPoints(from: url),
              !points.isEmpty else { return nil }

        let focused = points.filter { $0.isInFocus }
        // confirmed = true means the camera's phase-detect system reported a locked
        // point (isInFocus). false means we only have a selected-but-not-locked point,
        // which is less reliable as a sharpness signal.
        let afConfirmed = !focused.isEmpty
        let target  = focused.isEmpty ? points : focused

        // The display overlay enforces a square by using normW * scaledW for both
        // screen width and height. To match that in normalised crop space:
        //   screen side = normW * scaledW
        //   as proportion of image height = (normW * scaledW) / scaledH
        //                                 = normW * (imageWidth / imageHeight)
        let aspect = CGFloat(imageWidth) / CGFloat(imageHeight)
        let corrected = target.map { point -> CGRect in
            let r = point.normRect
            let normSide = r.width * aspect   // height in proportional coords that gives a square
            return CGRect(x: r.minX,
                          y: r.midY - normSide / 2,
                          width:  r.width,
                          height: normSide)
        }

        let rect = corrected.reduce(CGRect.null) { $0.union($1) }
        return (rect: rect, confirmed: afConfirmed)
    }
    
    // MARK: - Geometry helpers

    private static func flipRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1.0 - r.maxY, width: r.width, height: r.height)
    }

    private static func boundingRectWithPadding(_ points: [CGPoint], pad: CGFloat) -> CGRect {
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let w = min(1 - x, (maxX - minX) + pad * 2), h = min(1 - y, (maxY - minY) + pad * 2)
        return CGRect(x: x, y: y, width: max(w, 0.01), height: max(h, 0.01))
    }

    private static func crop(_ image: CGImage, to norm: CGRect) -> CGImage? {
        image.cropping(to: CGRect(
            x: norm.minX * CGFloat(image.width),
            y: norm.minY * CGFloat(image.height),
            width:  norm.width  * CGFloat(image.width),
            height: norm.height * CGFloat(image.height)
        ))
    }

    static func loadThumbnail(from url: URL, maxDimension: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func gray(_ p: [UInt8], x: Int, y: Int, w: Int) -> Int {
        let i = (y * w + x) * 4
        return (Int(p[i]) * 299 + Int(p[i+1]) * 587 + Int(p[i+2]) * 114) / 1000
    }

    // MARK: - Exposure assessment
    //
    // Scans a downscaled copy of the image for luminance statistics.
    // We downsample to at most 200 px wide so this completes in under 1 ms
    // on any modern device — far faster than the Laplacian scorer.
    //
    // When a subject rect is provided we also measure luminance inside that
    // region so we can distinguish "sky is blown out" from "bird is blown out".

    private static func assessExposure(cgImage: CGImage,
                                        subjectRect: CGRect?) -> ExposureAssessment {
        let targetWidth = 200
        let scale = min(1.0, Double(targetWidth) / Double(cgImage.width))
        let sw    = max(1, Int(Double(cgImage.width)  * scale))
        let sh    = max(1, Int(Double(cgImage.height) * scale))
        let bpr   = sw * 4

        var data = [UInt8](repeating: 0, count: sh * bpr)
        guard let ctx = CGContext(data: &data, width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return ExposureAssessment(highlightClipFraction: 0, shadowClipFraction: 0,
                                       meanLuminance: 0.5, subjectMeanLuminance: nil,
                                       subjectHighlightClipFraction: nil,
                                       subjectShadowClipFraction: nil)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sw, height: sh))

        var totalPixels = 0
        var lumSum = 0.0
        var highlights = 0
        var shadows = 0

        // Subject region in pixel coords of the downscaled image (nil = whole frame)
        let subjPx: (minX: Int, minY: Int, maxX: Int, maxY: Int)? = subjectRect.map { r in
            (minX: max(0, Int(r.minX * Double(sw))),
             minY: max(0, Int(r.minY * Double(sh))),
             maxX: min(sw - 1, Int(r.maxX * Double(sw))),
             maxY: min(sh - 1, Int(r.maxY * Double(sh))))
        }
        var subjPixels = 0
        var subjLumSum = 0.0
        var subjHighlights = 0
        var subjShadows    = 0

        for py in 0..<sh {
            for px in 0..<sw {
                let base = py * bpr + px * 4
                let r = Double(data[base])
                let g = Double(data[base + 1])
                let b = Double(data[base + 2])
                // ITU-R BT.709 luminance weighting (same as HistogramView)
                let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0

                totalPixels += 1
                lumSum      += lum
                if lum >= 0.98 { highlights += 1 }  // ≥250/255
                if lum <= 0.02 { shadows    += 1 }  // ≤5/255

                // Subject region measurement
                if let s = subjPx, px >= s.minX, px <= s.maxX, py >= s.minY, py <= s.maxY {
                    subjPixels  += 1
                    subjLumSum  += lum
                    if lum >= 0.98 { subjHighlights += 1 }
                    if lum <= 0.02 { subjShadows    += 1 }
                }
            }
        }

        let n = Double(max(totalPixels, 1))
        let highlightClip = Double(highlights) / n
        let shadowClip    = Double(shadows)    / n
        let meanLum       = lumSum / n

        let subjectMean: Double? = subjPixels > 0
            ? subjLumSum / Double(subjPixels)
            : nil
        let subjectHighlightClip: Double? = subjPixels > 0
            ? Double(subjHighlights) / Double(subjPixels)
            : nil
        let subjectShadowClip: Double? = subjPixels > 0
            ? Double(subjShadows) / Double(subjPixels)
            : nil

        return ExposureAssessment(
            highlightClipFraction:        highlightClip,
            shadowClipFraction:           shadowClip,
            meanLuminance:                meanLum,
            subjectMeanLuminance:         subjectMean,
            subjectHighlightClipFraction: subjectHighlightClip,
            subjectShadowClipFraction:    subjectShadowClip
        )
    }

    private static func unanalyzed() -> FocusResult {
        FocusResult(status: .unanalyzed, score: 0, analysisRegion: .fullImage,
                    blurType: .unknown, subjectSizeConfidence: 0,
                    detectedAnimalLabel: nil, analysisRect: nil,
                    subjectContour: [],
                    detectionConfidence: nil, afOverlapsSubject: nil,
                    afOnEye: nil,
                    afNotOnSubject: false,
                    rawSharpnessScore: 0, subjectBodyArea: 0, scoringRectArea: 0,
                    hadAFPoint: false, sharpThreshold: 0, acceptableThreshold: 0,
                    afPointRawScore: nil, subjectBodyRawScore: nil,
                    ratingBasis: .fullImage,
                    speciesLabel: nil,
                    speciesConfidence: nil,
                    speciesCandidates: [],
                    exposureAssessment: nil)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
    func clamped(to b: CGRect) -> CGRect {
        let x = max(b.minX, min(minX, b.maxX)), y = max(b.minY, min(minY, b.maxY))
        let w = min(maxX, b.maxX) - x, h = min(maxY, b.maxY) - y
        return CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }
}

private extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
