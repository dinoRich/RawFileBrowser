import Foundation
import CoreImage
import ImageIO
import UIKit
import Vision

// MARK: - Public types

enum FocusStatus: String, Codable, Hashable, Equatable {
    case sharp                = "Sharp"
    case slightlyBlur         = "Slightly Blurry"
    case blurry               = "Blurry"
    case missedFocus          = "Missed Focus"          // AF point found, NOT on subject, subject below acceptable
    case possibleMissedFocus  = "Possible Missed Focus" // AF point found, NOT on subject, subject meets acceptable
    case unanalyzed           = "Not Analyzed"

    /// True for outcomes where the photo should be considered a reject
    var isRejected: Bool {
        self == .blurry || self == .slightlyBlur || self == .missedFocus || self == .possibleMissedFocus
    }

    var systemImage: String {
        switch self {
        case .sharp:               return "checkmark.circle.fill"
        case .slightlyBlur:        return "exclamationmark.circle.fill"
        case .blurry:              return "xmark.circle.fill"
        case .missedFocus:         return "scope"
        case .possibleMissedFocus: return "questionmark.diamond.fill"
        case .unanalyzed:          return "questionmark.circle"
        }
    }

    var color: UIColor {
        switch self {
        case .sharp:               return .systemGreen
        case .slightlyBlur:        return .systemOrange
        case .blurry:              return .systemRed
        case .missedFocus:         return .systemPurple
        case .possibleMissedFocus: return .systemIndigo
        case .unanalyzed:          return .systemGray
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

    /// Describes which region drove the final sharpness rating and why.
    enum RatingBasis: String {
        case afPoint         = "AF Point"                     // Case 5: AF score met sharp threshold
        case subjectBody     = "Subject Body"                 // Cases 2, 3, 4, or Case 5 fallback
        case afPointDegraded = "Subject (AF Point Degraded)"  // Case 5: AF below sharp, subject used instead
        case fullImage       = "Full Image"                   // Case 1
        case missedFocus     = "Missed Focus"                 // Case 3
        case possibleMissed  = "Possible Missed Focus"        // Case 4
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

// MARK: - Per-region sharpness thresholds
//
// normalisationDivisor: raw Laplacian variance is divided by this to produce a 0-1 score.
// The smaller the crop, the sharper it tends to look at pixel level, so eye crops
// need a higher divisor to avoid over-rewarding tiny sharp patches.
// sharp / acceptable: the final normalised score thresholds for Sharp / Slightly Blurry.

private struct RegionThresholds {
    let normalisationDivisor: Double
    let sharp: Double
    let acceptable: Double

    static let eyes = RegionThresholds(normalisationDivisor: 200,  sharp: 0.55, acceptable: 0.25)
    static let head = RegionThresholds(normalisationDivisor: 400,  sharp: 0.60, acceptable: 0.30)
    static let body = RegionThresholds(normalisationDivisor: 700,  sharp: 0.62, acceptable: 0.32)
    static let full = RegionThresholds(normalisationDivisor: 1000, sharp: 0.65, acceptable: 0.35)
}

private enum Threshold {
    /// Minimum fractional area for a detected region to be trusted
    static let minSubjectArea = 0.002
    /// Horizontal:vertical variance ratio that implies motion blur
    static let motionRatio    = 2.5
    /// Absolute padding (normalised 0-1) added to the AF rect before overlap test.
    /// 0.10 = 10% of image dimension on each side — intentionally generous because
    /// AF point rects are tiny and Vision body boxes are approximate.
    static let afPaddingForOverlap: CGFloat = 0
}

// MARK: - FocusAnalyzer

struct FocusAnalyzer {

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

    static func analyze(url: URL) async -> FocusResult {
        guard let cgImage = loadThumbnail(from: url, maxDimension: 2048) else {
            return unanalyzed()
        }

        // Step 1 — AF point from camera Makernote
        let afRect = extractAFRegion(from: url,
                                     imageWidth: cgImage.width,
                                     imageHeight: cgImage.height)

        // Step 2 — Subject detection (YOLO first, Vision fallback)
        let subject = await detectSubject(in: cgImage)

        // Step 3 — Route to the correct analysis path
        return route(cgImage: cgImage, afRect: afRect, subject: subject)
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
                               subject: SubjectResult) -> FocusResult {

        let hasAF      = afRect != nil
        let hasSubject = subject.bestRect != nil

        switch (hasAF, hasSubject) {

        // ── Case 5 / Case 3 / Case 4: AF + Subject ──────────────────────────
        case (true, true):
            let af = afRect!
            let subjectBody = subject.bodyRect ?? subject.bestRect!

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
                print("FocusAnalyzer: AF overlaps subject → dual score (AF point + subject body)")
                return scoreAFOnSubject(cgImage: cgImage,
                                        afRect: af,
                                        subjectBody: subjectBody,
                                        subject: subject,
                                        afOnEye: afOnEye)
            } else {
                // ── Cases 3 & 4: AF NOT on subject ──────────────────────────
                print("FocusAnalyzer: AF does NOT overlap subject → missed focus path")
                return missedFocusResult(cgImage: cgImage,
                                         afRect: af,
                                         subjectRect: subjectBody,
                                         label: subject.label,
                                         confidence: subject.confidence,
                                         afOnEye: afOnEye,
                                         subjectContour: subject.contours)
            }

        // ── AF only (no subject detected) ────────────────────────────────────
        case (true, false):
            print("FocusAnalyzer: AF found, no subject → score at AF point")
            return scoreAtRect(afRect!,
                               in: cgImage,
                               region: .afPoint,
                               label: nil,
                               confidence: nil,
                               afOverlaps: nil,
                               hadAF: true,
                               ratingBasis: .afPoint)

        // ── Case 2: Subject only (no AF data) ────────────────────────────────
        case (false, true):
            print("FocusAnalyzer: No AF, subject found → score at subject body")
            let bodyRect = subject.bodyRect ?? subject.bestRect!
            return scoreAtRect(bodyRect,
                               in: cgImage,
                               region: .animalBody,
                               label: subject.label,
                               confidence: subject.confidence,
                               afOverlaps: nil,
                               bodyRect: bodyRect,        // pass the resolved rect, never nil
                               subjectContour: subject.contours,
                               ratingBasis: .subjectBody)

        // ── Case 1: No AF, no subject ─────────────────────────────────────────
        case (false, false):
            print("FocusAnalyzer: No AF, no subject → full image sharpness")
            return scoreFullImage(cgImage: cgImage)
        }
    }

    // MARK: - Case 5 dual-score: AF intersects subject

    /// Scores both the AF point rect and the subject body rect independently,
    /// then decides which to use as the final rating:
    ///   • AF score meets sharp threshold   → use AF score (camera nailed it)
    ///   • AF score below sharp, subject meets acceptable → use subject score + note degraded AF
    ///   • Both poor                        → use subject score (more representative)
    private static func scoreAFOnSubject(cgImage: CGImage,
                                          afRect: CGRect,
                                          subjectBody: CGRect,
                                          subject: SubjectResult,
                                          afOnEye: Bool?) -> FocusResult {

        // Score the AF point crop.
        // Important: do NOT apply a size-confidence penalty to the AF score.
        // The AF point rect is intentionally tiny (camera hardware, not detection error).
        // Applying the small-subject penalty would push nearly every AF score below
        // the sharp threshold, causing the body score to win by default every time.
        let afCropped = crop(cgImage, to: afRect)
        let afRaw     = afCropped.flatMap { rawLaplacian(cgImage: $0) } ?? 0.0
        let afThresh  = RegionThresholds.body
        let afFinal   = min(afRaw / afThresh.normalisationDivisor, 1.0)  // no size penalty

        // Score the subject body crop
        let bodySizeConf = subjectSizeConfidence(rect: subjectBody,
                                                 imageWidth: cgImage.width,
                                                 imageHeight: cgImage.height)
        let bodyCropped  = crop(cgImage, to: subjectBody)
        let bodyRaw      = bodyCropped.flatMap { rawLaplacian(cgImage: $0) } ?? 0.0
        let bodyThresh   = RegionThresholds.body
        let bodyFinal    = min(bodyRaw / bodyThresh.normalisationDivisor, 1.0) * bodySizeConf

        let bodyArea    = Double(subjectBody.width * subjectBody.height)
        let scoringArea = Double(afRect.width * afRect.height)

        // Normalise both scores for threshold comparison and display.
        // NOTE: We compare afNorm vs bodyNorm directly (not against threshold) to decide
        // which region is sharper — this avoids the crop-size bias where a large body crop
        // produces higher absolute Laplacian variance than a tiny AF crop even when the AF
        // region is objectively sharper pixel-for-pixel.
        let afNorm   = min(afRaw   / afThresh.normalisationDivisor,   1.0)
        let bodyNorm = min(bodyRaw / bodyThresh.normalisationDivisor,  1.0)
        let bodyFinalWithConf = bodyNorm * bodySizeConf

        // Decide which score to use
        let basis: FocusResult.RatingBasis
        let useRaw:   Double
        let useFinal: Double
        let useThresh = bodyThresh

        if afNorm >= bodyNorm {
            // AF point is at least as sharp as the subject body — use it
            basis    = .afPoint
            useRaw   = afNorm
            useFinal = afNorm   // no size penalty for AF point (see comment above)
            print("FocusAnalyzer: Case 5 → AF (\(String(format:"%.2f", afNorm))) ≥ body (\(String(format:"%.2f", bodyNorm))), using AF score")
        } else {
            // Subject body is sharper than AF point — AF focus was degraded
            basis    = .afPointDegraded
            useRaw   = bodyNorm
            useFinal = bodyFinalWithConf
            print("FocusAnalyzer: Case 5 → body (\(String(format:"%.2f", bodyNorm))) > AF (\(String(format:"%.2f", afNorm))), AF degraded, using subject score")
        }

        // Determine blur type and final status from chosen score
        let blurType: BlurType
        if useFinal >= useThresh.sharp {
            blurType = .none
        } else if useFinal < useThresh.acceptable {
            blurType = .defocus
        } else {
            blurType = .mixed
        }

        let status: FocusStatus
        switch useFinal {
        case useThresh.sharp...:      status = .sharp
        case useThresh.acceptable...: status = .slightlyBlur
        default:                       status = .blurry
        }

        return FocusResult(status: status,
                           score: useFinal,
                           analysisRegion: .afOnSubject,
                           blurType: blurType,
                           subjectSizeConfidence: bodySizeConf,
                           detectedAnimalLabel: subject.label,
                           analysisRect: afRect,          // always show AF point rect in overlay
                           subjectContour: subject.contours,
                           detectionConfidence: subject.confidence,
                           afOverlapsSubject: true,
                           afOnEye: afOnEye,
                           rawSharpnessScore: useRaw,
                           subjectBodyArea: bodyArea,
                           scoringRectArea: scoringArea,
                           hadAFPoint: true,
                           sharpThreshold: useThresh.sharp,
                           acceptableThreshold: useThresh.acceptable,
                           afPointRawScore: afNorm,
                           subjectBodyRawScore: bodyNorm,
                           ratingBasis: basis)
    }

    /// Computes raw Laplacian variance for a CGImage crop without building a full FocusResult.
    /// Returns the combined sqrt(varH * varV) value — the same metric used in score().
    private static func rawLaplacian(cgImage: CGImage) -> Double? {
        let w = cgImage.width, h = cgImage.height
        guard w > 2 && h > 2 else { return nil }
        let bpr = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
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
                                           subjectContour: [[CGPoint]] = []) -> FocusResult {

        let sizeConf   = subjectSizeConfidence(rect: subjectRect,
                                               imageWidth: cgImage.width,
                                               imageHeight: cgImage.height)
        let thresholds = RegionThresholds.body
        let bodyArea   = Double(subjectRect.width * subjectRect.height)

        // Score subject body sharpness
        let rawScore: Double
        let finalScore: Double
        if let cropped = crop(cgImage, to: subjectRect), cropped.width > 4, cropped.height > 4,
           let lap = rawLaplacian(cgImage: cropped) {
            rawScore   = min(lap / thresholds.normalisationDivisor, 1.0)
            finalScore = rawScore * sizeConf
        } else {
            rawScore   = 0
            finalScore = 0
        }

        // Case 3 vs Case 4
        let focusStatus: FocusStatus
        let basis: FocusResult.RatingBasis
        if finalScore >= thresholds.acceptable {
            focusStatus = .possibleMissedFocus
            basis       = .possibleMissed
            print("FocusAnalyzer: Case 4 → Possible Missed Focus (subject score \(String(format:"%.2f", finalScore)) meets acceptable)")
        } else {
            focusStatus = .missedFocus
            basis       = .missedFocus
            print("FocusAnalyzer: Case 3 → Missed Focus (subject score \(String(format:"%.2f", finalScore)) below acceptable)")
        }

        return FocusResult(
            status:                focusStatus,
            score:                 finalScore,
            analysisRegion:        .missedFocus,
            blurType:              finalScore < thresholds.acceptable ? .defocus : .mixed,
            subjectSizeConfidence: sizeConf,
            detectedAnimalLabel:   label,
            analysisRect:          afRect,
            subjectContour:        subjectContour,
            detectionConfidence:   confidence,
            afOverlapsSubject:     false,
            afOnEye:               afOnEye,
            rawSharpnessScore:     rawScore,
            subjectBodyArea:       bodyArea,
            scoringRectArea:       Double(afRect.width * afRect.height),
            hadAFPoint:            true,
            sharpThreshold:        thresholds.sharp,
            acceptableThreshold:   thresholds.acceptable,
            afPointRawScore:       nil,
            subjectBodyRawScore:   rawScore,
            ratingBasis:           basis
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
                                     ratingBasis: FocusResult.RatingBasis = .subjectBody) -> FocusResult {
        let sizeConf = subjectSizeConfidence(rect: bodyRect ?? normRect,
                                             imageWidth: cgImage.width,
                                             imageHeight: cgImage.height)

        let bodyArea    = Double((bodyRect ?? normRect).width * (bodyRect ?? normRect).height)
        let scoringArea = Double(normRect.width * normRect.height)

        guard let cropped = crop(cgImage, to: normRect), cropped.width > 4, cropped.height > 4 else {
            return scoreFullImage(cgImage: cgImage, label: label, confidence: confidence,
                                  afOverlaps: afOverlaps, afOnEye: afOnEye, hadAF: hadAF,
                                  ratingBasis: ratingBasis)
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
                     ratingBasis: ratingBasis,
                     subjectContour: subjectContour)
    }

    private static func scoreFullImage(cgImage: CGImage,
                                        label: String? = nil,
                                        confidence: Float? = nil,
                                        afOverlaps: Bool? = nil,
                                        afOnEye: Bool? = nil,
                                        hadAF: Bool = false,
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

        // Run foreground mask contour and YOLO concurrently — independent operations.
        async let contourTask: [[CGPoint]] = {
            if #available(iOS 17.0, *) {
                return await foregroundMaskContour(cgImage: cgImage)
            }
            return []
        }()
        async let yoloTask = YOLODetector.shared.detect(cgImage: cgImage)

        let contours       = await contourTask
        let yoloDetections = await yoloTask

        // Bounding rect of all contours combined — used for overlap testing and size confidence.
        let allContourPoints = contours.flatMap { $0 }
        let contourBodyRect: CGRect? = allContourPoints.isEmpty ? nil : boundingRectWithPadding(allContourPoints, pad: 0.005)

        if let best = bestAnimalDetection(from: yoloDetections) {
            // YOLO identified the species. Use the contour bbox as bodyRect when
            // available (tighter than YOLO's classifier full-image bbox).
            // For detection models (non-classifier) YOLO provides a real bbox.
            let isClassifier = YOLODetector.isClassificationModel
            let bodyRect = contourBodyRect ?? (isClassifier ? nil : best.boundingBox)
            let bestRect = best.eyeRect ?? best.headRect
            return SubjectResult(
                bestRect:   bestRect,
                eyeRect:    best.eyeRect,
                bodyRect:   bodyRect,
                contours:   contours,
                label:      best.label.capitalized,
                confidence: best.confidence
            )
        }

        // YOLO found nothing — fall back to Apple Vision animal/human detection.
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

            // ── Step 1: generate the foreground instance mask ─────────────────
            // VNGenerateForegroundInstanceMaskRequest assigns a distinct pixel value
            // to each foreground instance (1, 2, 3 …). We process each instance
            // separately so we get one contour per subject rather than one merged blob.
            let maskRequest = VNGenerateForegroundInstanceMaskRequest()
            let handler     = VNImageRequestHandler(cgImage: cgImage, options: [:])

            guard (try? handler.perform([maskRequest])) != nil,
                  let observation = maskRequest.results?.first,
                  !observation.allInstances.isEmpty else {
                continuation.resume(returning: [])
                return
            }

            let targetSize = 256
            var allContours: [[CGPoint]] = []

            // ── Step 2: process each instance individually ────────────────────
            for instance in observation.allInstances {
                guard let maskBuffer = try? observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: Int(instance)),
                    from: handler) else { continue }

                CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
                let bufW = CVPixelBufferGetWidth(maskBuffer)
                let bufH = CVPixelBufferGetHeight(maskBuffer)
                let bpr  = CVPixelBufferGetBytesPerRow(maskBuffer)
                guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else {
                    CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly)
                    continue
                }
                let floats = base.bindMemory(to: Float32.self, capacity: bufH * bpr / 4)

                // Build an 8-bit greyscale buffer at targetSize×targetSize
                var grey = [UInt8](repeating: 0, count: targetSize * targetSize)
                let scaleX = Double(bufW) / Double(targetSize)
                let scaleY = Double(bufH) / Double(targetSize)
                for row in 0..<targetSize {
                    let srcRow = Int(Double(row) * scaleY)
                    for col in 0..<targetSize {
                        let srcCol = Int(Double(col) * scaleX)
                        let fval   = floats[srcRow * (bpr / 4) + srcCol]
                        grey[row * targetSize + col] = fval > 0.5 ? 255 : 0
                    }
                }
                CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly)

                guard let greyCtx = CGContext(
                    data: &grey, width: targetSize, height: targetSize,
                    bitsPerComponent: 8, bytesPerRow: targetSize,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ), let greyImage = greyCtx.makeImage() else { continue }

                // ── Step 3: trace contour on this instance's mask ─────────────
                let contourRequest = VNDetectContoursRequest()
                contourRequest.detectsDarkOnLight = false   // mask is white-on-black
                let contourHandler = VNImageRequestHandler(cgImage: greyImage, options: [:])
                guard (try? contourHandler.perform([contourRequest])) != nil,
                      let contourObs = contourRequest.results?.first,
                      let outerContour = contourObs.topLevelContours.first else { continue }

                // ── Step 4: convert to top-left origin, downsample to ≤300 pts ─
                let rawPoints   = outerContour.normalizedPoints
                let totalPoints = rawPoints.count
                let step        = max(1, totalPoints / 300)
                var result: [CGPoint] = []
                result.reserveCapacity(min(totalPoints, 300))
                var i = 0
                while i < totalPoints {
                    let p = rawPoints[i]
                    result.append(CGPoint(x: CGFloat(p.x), y: 1.0 - CGFloat(p.y)))
                    i += step
                }

                // Sanity check: reject if contour covers nearly the full image
                let bbox = boundingRectWithPadding(result, pad: 0)
                guard !result.isEmpty, bbox.area < 0.90 else { continue }

                allContours.append(result)
            }

            continuation.resume(returning: allContours)
        }
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

        let thresholds: RegionThresholds
        switch region {
        case .animalEyes, .humanEyes:                         thresholds = .eyes
        case .animalHead, .humanFace, .yoloHead:              thresholds = .head
        case .yoloEyes:                                       thresholds = .eyes
        case .yoloBody, .animalBody, .afOnSubject, .afPoint:  thresholds = .body
        default:                                              thresholds = .full
        }

        let rawScore   = min(combined / thresholds.normalisationDivisor, 1.0)
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
                           rawSharpnessScore: rawScore,
                           subjectBodyArea: bodyArea,
                           scoringRectArea: scoringArea,
                           hadAFPoint: hadAF,
                           sharpThreshold: thresholds.sharp,
                           acceptableThreshold: thresholds.acceptable,
                           afPointRawScore: afPointRawScore,
                           subjectBodyRawScore: subjectBodyRawScore,
                           ratingBasis: ratingBasis)
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
                                        imageHeight: Int) -> CGRect? {
        guard let points = CanonMakernoteParser.extractAFPoints(from: url),
              !points.isEmpty else { return nil }

        let focused = points.filter { $0.isInFocus }
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

        return corrected.reduce(CGRect.null) { $0.union($1) }
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

    private static func loadThumbnail(from url: URL, maxDimension: Int) -> CGImage? {
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

    private static func unanalyzed() -> FocusResult {
        FocusResult(status: .unanalyzed, score: 0, analysisRegion: .fullImage,
                    blurType: .unknown, subjectSizeConfidence: 0,
                    detectedAnimalLabel: nil, analysisRect: nil,
                    subjectContour: [],
                    detectionConfidence: nil, afOverlapsSubject: nil,
                    afOnEye: nil,
                    rawSharpnessScore: 0, subjectBodyArea: 0, scoringRectArea: 0,
                    hadAFPoint: false, sharpThreshold: 0, acceptableThreshold: 0,
                    afPointRawScore: nil, subjectBodyRawScore: nil,
                    ratingBasis: .fullImage)
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
