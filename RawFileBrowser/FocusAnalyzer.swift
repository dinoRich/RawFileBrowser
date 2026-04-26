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

    var isRejected: Bool { self == .blurry || self == .slightlyBlur }

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
    /// Detection confidence from YOLO (0-1), nil if Vision fallback was used
    let detectionConfidence: Float?

    enum AnalysisRegion: String {
        case yoloEyes     = "Eyes (YOLO)"
        case yoloHead     = "Head (YOLO)"
        case yoloBody     = "Body (YOLO)"
        case animalEyes   = "Animal Eyes"
        case animalHead   = "Animal Head"
        case animalBody   = "Animal Body"
        case humanEyes    = "Human Eyes"
        case humanFace    = "Human Face"
        case afPoint      = "AF Point"
        case afAndSubject = "AF Point + Subject"
        case subject      = "Subject (Vision)"
        case fullImage    = "Full Image"
    }
}

// MARK: - Per-region thresholds

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
    static let minSubjectArea = 0.002
    static let motionRatio    = 2.5
}

// MARK: - FocusAnalyzer

struct FocusAnalyzer {

    // MARK: - Entry point

    static func analyze(url: URL) async -> FocusResult {
        guard let cgImage = loadThumbnail(from: url, maxDimension: 1536) else {
            return unanalyzed()
        }

        let afRect = extractAFRegion(from: url,
                                     imageWidth: cgImage.width,
                                     imageHeight: cgImage.height)

        // --- YOLO path (requires model in bundle) ---
        let yoloDetections = await YOLODetector.shared.detect(cgImage: cgImage)
        let primaryYOLO    = bestAnimalDetection(from: yoloDetections)

        if let yolo = primaryYOLO {
            return analyzeWithYOLO(yolo, cgImage: cgImage, afRect: afRect)
        }

        // --- Vision fallback (no model / subject not in YOLO classes) ---
        return await analyzeWithVision(cgImage: cgImage, afRect: afRect)
    }

    // MARK: - YOLO analysis path

    private static func bestAnimalDetection(from detections: [YOLODetection]) -> YOLODetection? {
        // Prefer animals; take highest confidence
        let animals = detections.filter { $0.isAnimal }
        return animals.max(by: { $0.confidence < $1.confidence })
            ?? detections.max(by: { $0.confidence < $1.confidence })
    }

    private static func analyzeWithYOLO(_ detection: YOLODetection,
                                         cgImage: CGImage,
                                         afRect: CGRect?) -> FocusResult {
        // Choose the most precise region available
        let (analysisRect, region): (CGRect, FocusResult.AnalysisRegion)

        if let eyes = detection.eyeRect, eyes.area > 0.0004 {
            (analysisRect, region) = (eyes, .yoloEyes)
        } else {
            let head = detection.headRect
            // Optionally intersect with AF point for extra precision
            if let af = afRect {
                let intersection = head.intersection(af)
                if !intersection.isNull && intersection.area > 0.001 {
                    (analysisRect, region) = (intersection, .afAndSubject)
                } else {
                    (analysisRect, region) = (head, .yoloHead)
                }
            } else {
                (analysisRect, region) = (head, .yoloHead)
            }
        }

        let sizeConf = subjectSizeConfidence(rect: analysisRect,
                                             imageWidth: cgImage.width,
                                             imageHeight: cgImage.height)

        guard let cropped = crop(cgImage, to: analysisRect) else {
            return scoreFullImage(cgImage: cgImage,
                                  label: detection.label,
                                  confidence: detection.confidence,
                                  analysisRect: detection.boundingBox)
        }

        return score(cgImage: cropped, region: region,
                     sizeConfidence: sizeConf,
                     analysisRect: analysisRect,
                     animalLabel: detection.label.capitalized,
                     detectionConfidence: detection.confidence)
    }

    // MARK: - Vision fallback path

    private static func analyzeWithVision(cgImage: CGImage,
                                          afRect: CGRect?) async -> FocusResult {
        async let animalResult = detectAnimalRegion(in: cgImage)
        async let humanResult  = detectHumanRegion(in: cgImage)

        let animal = await animalResult
        let human  = await humanResult

        let (analysisRect, region) = chooseBestRegion(
            animal: animal, human: human, afRect: afRect
        )

        let sizeConf = subjectSizeConfidence(
            rect: analysisRect,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height
        )

        let targetImage: CGImage
        if let rect = analysisRect, let cropped = crop(cgImage, to: rect) {
            targetImage = cropped
        } else {
            targetImage = cgImage
        }

        return score(cgImage: targetImage, region: region,
                     sizeConfidence: sizeConf,
                     analysisRect: analysisRect,
                     animalLabel: animal.animalLabel,
                     detectionConfidence: nil)
    }

    // MARK: - Vision animal detection

    private struct AnimalDetectionResult {
        let eyeRect:    CGRect?
        let headRect:   CGRect?
        let bodyRect:   CGRect?
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

            // Also get species label
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

    // MARK: - Vision region cascade

    private static func chooseBestRegion(
        animal: AnimalDetectionResult,
        human: HumanDetectionResult,
        afRect: CGRect?
    ) -> (CGRect?, FocusResult.AnalysisRegion) {
        if let eyes = animal.eyeRect,  eyes.area > 0.0004 { return (eyes, .animalEyes) }
        if let head = animal.headRect {
            if let af = afRect {
                let i = head.intersection(af)
                if !i.isNull && i.area > 0.001 { return (i, .afAndSubject) }
            }
            return (head, .animalHead)
        }
        if let eyes = human.eyeRect,  eyes.area > 0.0004 { return (eyes, .humanEyes) }
        if let face = human.faceRect                      { return (face, .humanFace) }
        if let af = afRect, let body = animal.bodyRect {
            let i = af.intersection(body)
            if !i.isNull && i.area > 0.001 { return (i, .afAndSubject) }
        }
        if let af = afRect {
            let expanded = af.insetBy(dx: -af.width * 0.5, dy: -af.height * 0.5)
                .clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (expanded, .afPoint)
        }
        if let body = animal.bodyRect { return (body, .animalBody) }
        return (nil, .fullImage)
    }

    // MARK: - Sharpness scoring

    private static func score(cgImage: CGImage,
                               region: FocusResult.AnalysisRegion,
                               sizeConfidence: Double,
                               analysisRect: CGRect?,
                               animalLabel: String?,
                               detectionConfidence: Float?) -> FocusResult {
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
        case .yoloEyes, .animalEyes, .humanEyes:         thresholds = .eyes
        case .yoloHead, .animalHead, .humanFace:          thresholds = .head
        case .yoloBody, .animalBody, .afAndSubject, .afPoint: thresholds = .body
        default:                                          thresholds = .full
        }

        let finalScore = min(combined / thresholds.normalisationDivisor, 1.0) * sizeConfidence

        let maxVar = max(varH, varV), minVar = min(varH, varV)
        let blurType: BlurType
        if finalScore >= thresholds.sharp {
            blurType = .none
        } else if maxVar > 1.0 && (minVar/maxVar) < (1.0/Threshold.motionRatio) {
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
                           detectionConfidence: detectionConfidence)
    }

    private static func scoreFullImage(cgImage: CGImage,
                                       label: String,
                                       confidence: Float,
                                       analysisRect: CGRect) -> FocusResult {
        score(cgImage: cgImage, region: .yoloBody, sizeConfidence: 0.7,
              analysisRect: analysisRect, animalLabel: label.capitalized,
              detectionConfidence: confidence)
    }

    // MARK: - Subject size confidence

    private static func subjectSizeConfidence(rect: CGRect?,
                                              imageWidth: Int,
                                              imageHeight: Int) -> Double {
        guard let rect else { return 0.7 }
        let area = Double(rect.width * rect.height)
        if area >= Threshold.minSubjectArea * 5 { return 1.0 }
        if area <  Threshold.minSubjectArea      { return 0.3 }
        return 0.3 + 0.7*(area - Threshold.minSubjectArea)/(Threshold.minSubjectArea*4)
    }

    // MARK: - EXIF AF point

    private static func extractAFRegion(from url: URL,
                                        imageWidth: Int,
                                        imageHeight: Int) -> CGRect? {
        // Use CanonMakernoteParser which handles both standard EXIF SubjectArea
        // and Canon R7/R3/R50/R6mkII Makernote AFInfo2 (tag 0x0026)
        guard let points = CanonMakernoteParser.extractAFPoints(from: url),
              !points.isEmpty else { return nil }

        // Use the union of all in-focus points as the AF region
        let focused = points.filter { $0.isInFocus }
        let target  = focused.isEmpty ? points : focused

        return target.reduce(CGRect.null) { $0.union($1.normRect) }
    }

    // MARK: - Geometry helpers

    private static func flipRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1.0 - r.maxY, width: r.width, height: r.height)
    }

    private static func boundingRectWithPadding(_ points: [CGPoint], pad: CGFloat) -> CGRect {
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let x = max(0, minX-pad), y = max(0, minY-pad)
        let w = min(1-x, (maxX-minX)+pad*2), h = min(1-y, (maxY-minY)+pad*2)
        return CGRect(x: x, y: y, width: max(w, 0.01), height: max(h, 0.01))
    }

    private static func crop(_ image: CGImage, to norm: CGRect) -> CGImage? {
        image.cropping(to: CGRect(
            x: norm.minX * CGFloat(image.width),  y: norm.minY * CGFloat(image.height),
            width: norm.width * CGFloat(image.width), height: norm.height * CGFloat(image.height)
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
        let i = (y*w+x)*4
        return (Int(p[i])*299 + Int(p[i+1])*587 + Int(p[i+2])*114)/1000
    }

    private static func unanalyzed() -> FocusResult {
        FocusResult(status: .unanalyzed, score: 0, analysisRegion: .fullImage,
                    blurType: .unknown, subjectSizeConfidence: 0,
                    detectedAnimalLabel: nil, analysisRect: nil, detectionConfidence: nil)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
    func clamped(to b: CGRect) -> CGRect {
        let x = max(b.minX, min(minX, b.maxX)), y = max(b.minY, min(minY, b.maxY))
        let w = min(maxX, b.maxX)-x, h = min(maxY, b.maxY)-y
        return CGRect(x: x, y: y, width: max(w,0), height: max(h,0))
    }
}

private extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
