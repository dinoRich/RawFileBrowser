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
    case missedFocus  = "Missed Focus"   // AF point found but didn't land on the subject
    case unanalyzed   = "Not Analyzed"

    /// True for outcomes where the photo should be considered a reject
    var isRejected: Bool {
        self == .blurry || self == .slightlyBlur || self == .missedFocus
    }

    var systemImage: String {
        switch self {
        case .sharp:        return "checkmark.circle.fill"
        case .slightlyBlur: return "exclamationmark.circle.fill"
        case .blurry:       return "xmark.circle.fill"
        case .missedFocus:  return "scope"          // crosshair icon — visually distinct
        case .unanalyzed:   return "questionmark.circle"
        }
    }

    var color: UIColor {
        switch self {
        case .sharp:        return .systemGreen
        case .slightlyBlur: return .systemOrange
        case .blurry:       return .systemRed
        case .missedFocus:  return .systemPurple
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
    /// Normalised (0-1) rect of the subject's full body, used to draw the subject outline.
    /// nil if no subject was detected (AF-only or full-image paths).
    let subjectBodyRect: CGRect?
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
    static let afPaddingForOverlap: CGFloat = 0.10
}

// MARK: - FocusAnalyzer

struct FocusAnalyzer {

    // MARK: - Entry point
    //
    // Decision tree:
    //
    //  1. Try to read the camera AF point from the file's Makernote.
    //  2. Try to detect a subject (animal / human) using Apple Vision.
    //     (YOLO model is used if present in the bundle, Vision is the fallback.)
    //
    //  Then:
    //   AF + Subject + overlap  →  score sharpness AT the AF point
    //                              (camera focused correctly on the subject)
    //   AF + Subject + NO overlap →  MISSED FOCUS  (camera focused on background)
    //   AF + no subject          →  score sharpness AT the AF point
    //   no AF + Subject          →  score sharpness AT the best subject region
    //   no AF + no Subject       →  score sharpness of the full image

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

    private static func route(cgImage: CGImage,
                               afRect: CGRect?,
                               subject: SubjectResult) -> FocusResult {

        let hasAF      = afRect != nil
        let hasSubject = subject.bestRect != nil

        switch (hasAF, hasSubject) {

        // ── AF + Subject ──────────────────────────────────────────────────────
        case (true, true):
            let af = afRect!
            // Expand the AF rect before testing overlap.
            // AF point rects parsed from Makernote are often very small (e.g. 163×163 px
            // in a 6960-wide sensor → ~2.3% of image width as normalised coords).
            // Subject bboxes from Vision are also approximate.
            // A generous expansion prevents false "missed focus" calls.
            // Use the subject BODY rect (full silhouette) for overlap, not the
            // precision-scoring rect (eyes/head). An AF point on a bird's wing is
            // still on the subject even though it misses the tiny eye crop.
            let subjectBody = subject.bodyRect ?? subject.bestRect!

            // Pad the AF rect by a fixed 10% of image in each direction.
            // Relative expansion (e.g. 3× af.width) breaks when the AF rect is tiny.
            let expandedAF = af.insetBy(
                dx: -Threshold.afPaddingForOverlap,
                dy: -Threshold.afPaddingForOverlap
            ).clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

            let overlaps = expandedAF.intersects(subjectBody)

            // Check whether the AF point specifically covered the eye region.
            // We use the raw (un-expanded) AF rect here — if the camera was
            // accurate enough to hit the eye, we want to know; generous expansion
            // would make almost every shot look like an eye hit.
            let afOnEye = afCoversEye(afRect: af, eyeRect: subject.eyeRect)

            if overlaps {
                // AF landed on the subject — score sharpness at the AF point itself
                // (not the subject rect, because the AF point is where the lens focused)
                print("FocusAnalyzer: AF overlaps subject → score at AF point (afOnEye=\(String(describing: afOnEye)))")
                return scoreAtRect(af,
                                   in: cgImage,
                                   region: .afOnSubject,
                                   label: subject.label,
                                   confidence: subject.confidence,
                                   afOverlaps: true,
                                   afOnEye: afOnEye,
                                   bodyRect: subjectBody,
                                   hadAF: true)
            } else {
                // AF point is clearly on the background — flag as missed focus
                print("FocusAnalyzer: AF does NOT overlap subject → missed focus")
                return missedFocusResult(afRect: af,
                                         subjectRect: subjectBody,
                                         label: subject.label,
                                         confidence: subject.confidence,
                                         afOnEye: afOnEye)
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
                               hadAF: true)

        // ── Subject only (no AF data) ─────────────────────────────────────────
        case (false, true):
            print("FocusAnalyzer: No AF, subject found → score at subject region")
            let (rect, region) = bestSubjectRegion(subject)
            return scoreAtRect(rect,
                               in: cgImage,
                               region: region,
                               label: subject.label,
                               confidence: subject.confidence,
                               afOverlaps: nil,
                               bodyRect: subject.bodyRect)

        // ── No AF, no subject ─────────────────────────────────────────────────
        case (false, false):
            print("FocusAnalyzer: No AF, no subject → full image sharpness")
            return scoreFullImage(cgImage: cgImage)
        }
    }

    // MARK: - AF / eye overlap check

    /// Returns true if the AF rect meaningfully overlaps the detected eye region.
    /// Uses the raw (un-expanded) AF rect — we only want to claim eye coverage
    /// when the camera actually aimed at the eye, not just nearby.
    /// nil if either rect is absent (can't determine either way).
    private static func afCoversEye(afRect: CGRect?, eyeRect: CGRect?) -> Bool? {
        guard let af = afRect, let eye = eyeRect else { return nil }
        // Expand the AF rect slightly — just enough to absorb small detection errors.
        // 5% of image dimension is much tighter than the 10% used for body overlap.
        let expandedAF = af.insetBy(dx: -0.05, dy: -0.05)
            .clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return expandedAF.intersects(eye)
    }

    // MARK: - Missed focus result

    /// Returns a FocusResult that records the missed-focus condition.
    /// We still measure sharpness at the AF point (the camera DID focus there,
    /// just not on the subject), and we store the subject rect as the analysisRect
    /// so the overlay shows where the subject actually was.
    private static func missedFocusResult(afRect: CGRect,
                                           subjectRect: CGRect,
                                           label: String?,
                                           confidence: Float?,
                                           afOnEye: Bool? = nil) -> FocusResult {
        return FocusResult(
                    status:                .missedFocus,
                    score:                 0,
                    analysisRegion:        .missedFocus,
                    blurType:              .unknown,
                    subjectSizeConfidence: 1.0,
                    detectedAnimalLabel:   label,
                    analysisRect:          subjectRect,
                    subjectBodyRect:       subjectRect,
                    detectionConfidence:   confidence,
                    afOverlapsSubject:     false,
                    afOnEye:               afOnEye,
                    rawSharpnessScore:     0,
                    subjectBodyArea:       Double(subjectRect.width * subjectRect.height),
                    scoringRectArea:       Double(afRect.width * afRect.height),
                    hadAFPoint:            true,
                    sharpThreshold:        0,
                    acceptableThreshold:   0
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
                                     hadAF: Bool = false) -> FocusResult {
        // Use bodyRect for size confidence if available — the scoring crop (eyes/head)
        // is intentionally small even when the animal fills the frame, so using it
        // would wrongly trigger the "small subject" warning.
        let sizeConf = subjectSizeConfidence(rect: bodyRect ?? normRect,
                                             imageWidth: cgImage.width,
                                             imageHeight: cgImage.height)

        let bodyArea    = Double((bodyRect ?? normRect).width * (bodyRect ?? normRect).height)
        let scoringArea = Double(normRect.width * normRect.height)

        // If the crop would be too small to score reliably, fall back to full image
        guard let cropped = crop(cgImage, to: normRect), cropped.width > 4, cropped.height > 4 else {
            return scoreFullImage(cgImage: cgImage, label: label, confidence: confidence,
                                  afOverlaps: afOverlaps, afOnEye: afOnEye, hadAF: hadAF)
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
                            bodyRect: bodyRect)
    }

    private static func scoreFullImage(cgImage: CGImage,
                                        label: String? = nil,
                                        confidence: Float? = nil,
                                        afOverlaps: Bool? = nil,
                                        afOnEye: Bool? = nil,
                                        hadAF: Bool = false) -> FocusResult {
        score(cgImage: cgImage,
              region: .fullImage,
              sizeConfidence: 0.7,
              analysisRect: nil,
              animalLabel: label,
              detectionConfidence: confidence,
              afOverlapsSubject: afOverlaps,
              afOnEye: afOnEye,
              hadAF: hadAF)
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
        let label:      String?
        let confidence: Float?
    }

    private static func detectSubject(in cgImage: CGImage) async -> SubjectResult {
        // Try YOLO first (requires model in bundle — gracefully absent)
        let yoloDetections = await YOLODetector.shared.detect(cgImage: cgImage)
        if let best = bestAnimalDetection(from: yoloDetections) {
            // Prefer eyes > head > body for sharpness scoring precision
            let bestRect = best.eyeRect ?? best.headRect
            return SubjectResult(
                bestRect:   bestRect,
                eyeRect:    best.eyeRect,
                bodyRect:   best.boundingBox,
                label:      best.label.capitalized,
                confidence: best.confidence
            )
        }

        // Vision fallback
        async let animalResult = detectAnimalRegion(in: cgImage)
        async let humanResult  = detectHumanRegion(in: cgImage)
        let animal = await animalResult
        let human  = await humanResult

        // Pick the best Vision region
        if let eyes = animal.eyeRect, eyes.area > 0.0004 {
            return SubjectResult(bestRect: eyes, eyeRect: eyes, bodyRect: animal.bodyRect,
                                 label: animal.animalLabel, confidence: nil)
        }
        if let head = animal.headRect {
            return SubjectResult(bestRect: head, eyeRect: nil, bodyRect: animal.bodyRect,
                                 label: animal.animalLabel, confidence: nil)
        }
        if let eyes = human.eyeRect, eyes.area > 0.0004 {
            return SubjectResult(bestRect: eyes, eyeRect: eyes, bodyRect: human.faceRect,
                                 label: nil, confidence: nil)
        }
        if let face = human.faceRect {
            return SubjectResult(bestRect: face, eyeRect: nil, bodyRect: face,
                                 label: nil, confidence: nil)
        }
        if let body = animal.bodyRect {
            return SubjectResult(bestRect: body, eyeRect: nil, bodyRect: body,
                                 label: animal.animalLabel, confidence: nil)
        }

        return SubjectResult(bestRect: nil, eyeRect: nil, bodyRect: nil, label: nil, confidence: nil)
    }

    /// Given a SubjectResult, return the best (most specific) rect and matching region enum.
    private static func bestSubjectRegion(_ subject: SubjectResult)
        -> (CGRect, FocusResult.AnalysisRegion) {
        guard let rect = subject.bestRect else {
            return (CGRect(x: 0, y: 0, width: 1, height: 1), .fullImage)
        }
        // We can't tell eyes from head here without more context,
        // so use body-level thresholds for safety (slightly more lenient).
        return (rect, .animalBody)
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
                                  bodyRect: CGRect? = nil) -> FocusResult {
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
                                   subjectBodyRect: bodyRect,
                                   detectionConfidence: detectionConfidence,
                                   afOverlapsSubject: afOverlapsSubject,
                                   afOnEye: afOnEye,
                                   rawSharpnessScore: rawScore,
                                   subjectBodyArea: bodyArea,
                                   scoringRectArea: scoringArea,
                                   hadAFPoint: hadAF,
                                   sharpThreshold: thresholds.sharp,
                                   acceptableThreshold: thresholds.acceptable)
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
                    detectionConfidence: nil, afOverlapsSubject: nil,
                    afOnEye: nil,
                    rawSharpnessScore: 0, subjectBodyArea: 0, scoringRectArea: 0,
                    hadAFPoint: false, sharpThreshold: 0, acceptableThreshold: 0)
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
