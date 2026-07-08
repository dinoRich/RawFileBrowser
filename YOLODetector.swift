import Foundation
import CoreML
import Vision
import UIKit
import CoreImage

// MARK: - YOLO Classification Result

struct YOLODetection {
    let label:      String
    let confidence: Float

    var isAnimal: Bool { YOLOLabels.animalClasses.contains(label.lowercased()) }
    var isBird:   Bool { YOLOLabels.birdClasses.contains(label.lowercased()) }
}

enum YOLOLabels {
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

/// Wraps the UKWildlife CoreML classification model.
///
/// Uses a serial DispatchQueue to serialise inference requests, preventing
/// Neural Engine contention when multiple analyses run concurrently.
/// Converting to `actor` caused a deadlock because the actor executor was
/// blocked by the synchronous VNImageRequestHandler.perform call inside
/// withCheckedContinuation, preventing the completion callback from running.
final class YOLODetector {

    static let modelName            = "UKWildlife"
    // The species threshold is applied downstream in SpeciesDetector: baseThreshold
    // (0.15) for the stored winner, and the per-size banded thresholds for display.
    // Keeping this pre-filter at 0 lets the full ranked list reach SpeciesDetector,
    // so its top-5 candidate list (shown in the diagnostic view) is complete and its
    // baseThreshold is what actually governs the result — previously this 0.35 gate
    // silently hid every candidate below 0.35 before SpeciesDetector ever saw them.
    static let confidenceThreshold: Float = 0.0
    static let maxDetections        = 10

    static let shared = YOLODetector()

    private var vnModel: VNCoreMLModel?

    /// Serial queue — inference requests queue here rather than competing on
    /// the Neural Engine, which caused 2–35 second stalls.
    private let inferenceQueue = DispatchQueue(label: "com.sharpeye.yolo.inference",
                                               qos: .userInitiated)

    private init() {
        guard let modelURL = Bundle.main.url(forResource: YOLODetector.modelName,
                                             withExtension: "mlpackage")
                          ?? Bundle.main.url(forResource: YOLODetector.modelName,
                                             withExtension: "mlmodelc") else {
            print("YOLODetector: model '\(YOLODetector.modelName)' not found in bundle.")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            vnModel     = try VNCoreMLModel(for: mlModel)
            print("YOLODetector: loaded \(YOLODetector.modelName)")
        } catch {
            print("YOLODetector: failed to load model — \(error)")
        }
    }

    func detect(cgImage: CGImage) async -> [YOLODetection] {
        guard let vnModel else {
            print("YOLODetector: no model loaded — falling back to Vision animal detection")
            return []
        }

        return await withCheckedContinuation { continuation in
            // Dispatch onto the serial queue so concurrent callers queue up
            // rather than running simultaneous Neural Engine inferences.
            inferenceQueue.async {
                let request = VNCoreMLRequest(model: vnModel) { req, error in
                    guard error == nil, let results = req.results else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: self.parseResults(results))
                }
                request.imageCropAndScaleOption = .scaleFit
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    private func parseResults(_ results: [VNObservation]) -> [YOLODetection] {
        let allClassifications = results.compactMap { $0 as? VNClassificationObservation }
        return allClassifications
            .filter     { $0.confidence >= YOLODetector.confidenceThreshold }
            .sorted     { $0.confidence > $1.confidence }
            .prefix(YOLODetector.maxDetections)
            .map        { YOLODetection(label: $0.identifier, confidence: $0.confidence) }
    }
}
