import Foundation
import CoreML
import Vision
import UIKit
import CoreImage

// MARK: - YOLO Detection Result

struct YOLODetection {
    let label: String
    let confidence: Float
    /// Bounding box in normalised 0-1 coords, top-left origin
    let boundingBox: CGRect
    /// Eye keypoints [leftEye, rightEye] in normalised 0-1 coords, top-left origin.
    /// Only present when using a pose model (yolov8n-pose / yolov8n-animal-pose).
    let eyeKeypoints: [CGPoint]
    /// Nose keypoint if available
    let noseKeypoint: CGPoint?

    /// Approximate head region derived from eye/nose keypoints or upper bbox fraction
    var headRect: CGRect {
        var pts = eyeKeypoints
        if let nose = noseKeypoint { pts.append(nose) }
        if pts.count >= 2 {
            let minX = pts.map(\.x).min()!
            let maxX = pts.map(\.x).max()!
            let minY = pts.map(\.y).min()!
            let maxY = pts.map(\.y).max()!
            let pad: CGFloat = 0.04
            return CGRect(
                x: max(0, minX - pad), y: max(0, minY - pad),
                width: min(1, (maxX - minX) + pad * 2),
                height: min(1, (maxY - minY) + pad * 2)
            )
        }
        // Fallback: upper 30% of bounding box
        return CGRect(x: boundingBox.minX, y: boundingBox.minY,
                      width: boundingBox.width, height: boundingBox.height * 0.3)
    }

    /// Eye region with padding — the primary sharpness target
    var eyeRect: CGRect? {
        guard eyeKeypoints.count >= 2 else { return nil }
        let minX = eyeKeypoints.map(\.x).min()!
        let maxX = eyeKeypoints.map(\.x).max()!
        let minY = eyeKeypoints.map(\.y).min()!
        let maxY = eyeKeypoints.map(\.y).max()!
        let pad: CGFloat = 0.05
        let r = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(1, (maxX - minX) + pad * 2),
            height: min(1, (maxY - minY) + pad * 2)
        )
        return r.width > 0.005 && r.height > 0.005 ? r : nil
    }

    var isAnimal: Bool { YOLOLabels.animalClasses.contains(label.lowercased()) }
    var isBird:   Bool { YOLOLabels.birdClasses.contains(label.lowercased()) }
}

// MARK: - YOLO class lists

enum YOLOLabels {
    /// COCO classes that are animals
    static let animalClasses: Set<String> = [
        "bird", "cat", "dog", "horse", "sheep", "cow", "elephant",
        "bear", "zebra", "giraffe", "deer", "fox", "wolf", "lion",
        "tiger", "leopard", "cheetah", "monkey", "gorilla", "rabbit",
        "squirrel", "hedgehog", "badger", "otter", "seal", "penguin",
        "eagle", "hawk", "owl", "parrot", "duck", "goose", "swan",
        "heron", "kingfisher", "woodpecker", "robin", "sparrow",
        "finch", "pigeon", "dove", "crow", "raven", "magpie",
        "puffin", "gannet", "cormorant", "osprey", "kite", "buzzard",
        "falcon", "kestrel", "merlin", "hobby"
    ]
    static let birdClasses: Set<String> = animalClasses.filter {
        ["bird","eagle","hawk","owl","parrot","duck","goose","swan",
         "heron","kingfisher","woodpecker","robin","sparrow","finch",
         "pigeon","dove","crow","raven","magpie","puffin","gannet",
         "cormorant","osprey","kite","buzzard","falcon","kestrel",
         "merlin","hobby"].contains($0)
    }
}

// MARK: - YOLODetector

/// Wraps a CoreML YOLOv8 model exported with:
///   model.export(format='coreml', nms=True, imgsz=640)
///
/// Supports both detection-only models (yolov8n.mlpackage)
/// and pose models (yolov8n-pose.mlpackage / animal-pose).
///
/// Drop your exported .mlpackage into the Xcode project and set
/// YOLODetector.modelName to match the filename (without extension).
final class YOLODetector {

    // MARK: - Configuration

    /// Change this to match your exported model filename (without extension).
    /// e.g. "yolov8n", "yolov8s", "UKWildlife"
    static let modelName = "yolov8n"

    /// Set to true when using a classification model (yolov8n-cls / UKWildlife).
    /// Classification models return class probabilities rather than bounding boxes.
    static let isClassificationModel = false

    /// Input size the model was exported with.
    /// Detection models: 640. Classification models: 224.
    static let inputSize = 640

    /// Minimum confidence to report a detection
    static let confidenceThreshold: Float = 0.35

    /// Maximum detections to return
    static let maxDetections = 10

    // MARK: - Singleton

    static let shared = YOLODetector()

    private var vnModel: VNCoreMLModel?
    private var isPoseModel = false

    private init() {
        loadModel()
    }

    private func loadModel() {
        // Try to load the model from the app bundle
        guard let modelURL = Bundle.main.url(
            forResource: YOLODetector.modelName,
            withExtension: "mlpackage"
        ) ?? Bundle.main.url(
            forResource: YOLODetector.modelName,
            withExtension: "mlmodelc"
        ) else {
            print("YOLODetector: model '\(YOLODetector.modelName)' not found in bundle.")
            print("  → Export with: model.export(format='coreml', nms=True, imgsz=640)")
            print("  → Then add the .mlpackage to your Xcode project.")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            vnModel = try VNCoreMLModel(for: mlModel)
            isPoseModel = YOLODetector.modelName.contains("pose")
            print("YOLODetector: loaded \(YOLODetector.modelName) (pose=\(isPoseModel))")
        } catch {
            print("YOLODetector: failed to load model — \(error)")
        }
    }

    // MARK: - Detection

    /// Run detection on a CGImage. Returns empty array if model not loaded.
    func detect(cgImage: CGImage) async -> [YOLODetection] {
        guard let vnModel else {
            print("YOLODetector: no model loaded — falling back to Vision animal detection")
            return []
        }

        return await withCheckedContinuation { continuation in
            let request = VNCoreMLRequest(model: vnModel) { req, error in
                guard error == nil,
                      let results = req.results else {
                    continuation.resume(returning: [])
                    return
                }

                let detections = self.parseResults(results, imageWidth: cgImage.width,
                                                   imageHeight: cgImage.height)
                continuation.resume(returning: detections)
            }

            // Maintain aspect ratio — critical for correct bbox coordinates
            request.imageCropAndScaleOption = .scaleFit

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Result parsing

    private func parseResults(_ results: [VNObservation],
                               imageWidth: Int,
                               imageHeight: Int) -> [YOLODetection] {

        // ── Classification model path ─────────────────────────────────────────
        // YOLOv8-cls returns VNClassificationObservation results
        if YOLODetector.isClassificationModel {
            return parseClassificationResults(results)
        }

        // ── Detection model path ──────────────────────────────────────────────
        var detections: [YOLODetection] = []

        for observation in results {
            if let obj = observation as? VNRecognizedObjectObservation {
                guard let topLabel = obj.labels.first,
                      topLabel.confidence >= YOLODetector.confidenceThreshold else { continue }

                let bb = flipRect(obj.boundingBox)
                detections.append(YOLODetection(
                    label: topLabel.identifier,
                    confidence: topLabel.confidence,
                    boundingBox: bb,
                    eyeKeypoints: [],
                    noseKeypoint: nil
                ))
            }
        }

        if isPoseModel, let featureResult = results.first as? VNCoreMLFeatureValueObservation {
            detections = parsePoseOutput(featureResult)
        }

        return detections
            .sorted { $0.confidence > $1.confidence }
            .prefix(YOLODetector.maxDetections)
            .map { $0 }
    }

    /// Parse VNClassificationObservation from a classification model.
    /// Returns a single YOLODetection covering the whole image since
    /// classification models don't produce bounding boxes.
    private func parseClassificationResults(_ results: [VNObservation]) -> [YOLODetection] {
        let classifications = results.compactMap { $0 as? VNClassificationObservation }
            .filter { $0.confidence >= YOLODetector.confidenceThreshold }
            .sorted { $0.confidence > $1.confidence }
            .prefix(YOLODetector.maxDetections)

        return classifications.map { obs in
            YOLODetection(
                label: obs.identifier,
                confidence: obs.confidence,
                // Full image bounding box — no spatial info from classifier
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                eyeKeypoints: [],
                noseKeypoint: nil
            )
        }
    }

    /// Parse YOLOv8 pose model raw output.
    /// YOLOv8 pose exports produce a [1, 56, 8400] tensor:
    ///   - dims 0-3: x, y, w, h (centre format, normalised)
    ///   - dim  4:   objectness
    ///   - dims 5-N: class scores
    ///   - remaining: keypoints as [x, y, visibility] triples
    private func parsePoseOutput(_ result: VNCoreMLFeatureValueObservation) -> [YOLODetection] {
        guard let multiArray = result.featureValue.multiArrayValue else { return [] }

        // Shape: [1, numFeatures, numAnchors]
        let shape = multiArray.shape.map { $0.intValue }
        guard shape.count == 3 else { return [] }
        let numFeatures = shape[1]
        let numAnchors  = shape[2]

        var detections: [YOLODetection] = []

        for a in 0..<numAnchors {
            func val(_ f: Int) -> Float {
                Float(truncating: multiArray[[0, f, a] as [NSNumber]])
            }

            let cx = CGFloat(val(0)), cy = CGFloat(val(1))
            let bw = CGFloat(val(2)), bh = CGFloat(val(3))
            let obj = val(4)
            guard obj >= YOLODetector.confidenceThreshold else { continue }

            // Find best class (dims 5 onwards until keypoints start)
            // YOLOv8 detection: 4 bbox + 1 conf + 80 classes = 85 before keypoints
            // For single-class animal pose: 4 + 1 + 1 = 6 before keypoints
            let numClasses = max(1, numFeatures - 4 - 1 - 51) // 17 keypoints * 3
            var bestClass = 0
            var bestScore: Float = 0
            for c in 0..<numClasses {
                let s = val(5 + c)
                if s > bestScore { bestScore = s; bestClass = c }
            }
            guard bestScore * obj >= YOLODetector.confidenceThreshold else { continue }

            // BBox: centre format → top-left, flip Y
            let x = cx - bw/2, y = 1 - (cy + bh/2)
            let bb = CGRect(x: x, y: y, width: bw, height: bh)
                .clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

            // Keypoints start after 4+1+numClasses
            let kpOffset = 5 + numClasses
            var eyeKps: [CGPoint] = []
            var noseKp: CGPoint?

            // COCO keypoint order: 0=nose, 1=left_eye, 2=right_eye, ...
            // Animal pose keypoint order varies by model
            let numKeypoints = (numFeatures - kpOffset) / 3
            for k in 0..<min(numKeypoints, 17) {
                let kx  = CGFloat(val(kpOffset + k*3))
                let ky  = 1 - CGFloat(val(kpOffset + k*3 + 1))  // flip Y
                let vis = val(kpOffset + k*3 + 2)
                guard vis > 0.3 else { continue }
                let pt = CGPoint(x: kx, y: ky)
                switch k {
                case 0: noseKp = pt
                case 1, 2: eyeKps.append(pt)   // COCO: 1=left_eye, 2=right_eye
                default: break
                }
            }

            let label = COCO80Labels.label(for: bestClass)
            detections.append(YOLODetection(
                label: label, confidence: bestScore * obj,
                boundingBox: bb, eyeKeypoints: eyeKps, noseKeypoint: noseKp
            ))
        }

        return detections
    }

    private func flipRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1.0 - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - COCO 80 class labels

enum COCO80Labels {
    static func label(for index: Int) -> String {
        guard index >= 0 && index < labels.count else { return "unknown" }
        return labels[index]
    }

    static let labels = [
        "person","bicycle","car","motorcycle","airplane","bus","train","truck",
        "boat","traffic light","fire hydrant","stop sign","parking meter","bench",
        "bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe",
        "backpack","umbrella","handbag","tie","suitcase","frisbee","skis","snowboard",
        "sports ball","kite","baseball bat","baseball glove","skateboard","surfboard",
        "tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl",
        "banana","apple","sandwich","orange","broccoli","carrot","hot dog","pizza",
        "donut","cake","chair","couch","potted plant","bed","dining table","toilet",
        "tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven",
        "toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear",
        "hair drier","toothbrush"
    ]
}

// MARK: - CGRect helpers

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, min(minX, bounds.maxX))
        let y = max(bounds.minY, min(minY, bounds.maxY))
        let w = min(maxX, bounds.maxX) - x
        let h = min(maxY, bounds.maxY) - y
        return CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }
}
