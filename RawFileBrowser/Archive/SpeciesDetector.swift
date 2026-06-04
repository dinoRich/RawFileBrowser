import Foundation
import CoreML
import Vision
import UIKit
import ImageIO

// MARK: - SpeciesResult

/// The result of a species classification on a single photo.
struct SpeciesResult {
    /// The top species label, e.g. "Short Eared Owl". nil when no detection cleared
    /// the base confidence threshold or the model is not loaded.
    let label: String?
    /// Confidence score 0–1 for the top result. nil when no detection was made.
    let confidence: Float?
    /// Top-N candidates sorted highest-confidence first.
    /// Contains up to 5 entries regardless of the confidence threshold —
    /// useful in the diagnostic view for understanding runner-up scores.
    let candidates: [(label: String, confidence: Float)]
}

// MARK: - SpeciesDetector

/// Runs species classification using the embedded YOLO classifier.
///
/// This struct does NOT load thumbnails or run subject detection —
/// both are handled upstream by FocusAnalyzer, which passes the
/// already-decoded image and the detected subject body rect.
///
/// The body rect is used to crop the image to the subject before
/// classifying, removing background/habitat bias. Falls back to the
/// full image if no body rect is available.

struct SpeciesDetector {

    // MARK: - Base confidence threshold
    //
    // This is the minimum confidence for a result to be stored at all.
    // Display-time filtering uses the banded threshold in AppSettings,
    // which is tighter for small subjects. The base threshold here is
    // deliberately low so runners-up are captured for the diagnostic view.

    private static let baseThreshold: Float = 0.15

    // MARK: - Public API

    /// Classify the species in a CGImage, optionally cropping to a subject rect first.
    ///
    /// - Parameters:
    ///   - cgImage:        The full decoded image from FocusAnalyzer.
    ///   - subjectBodyRect: Normalised (0–1, top-left origin) body bounding box
    ///                      from subject detection. When provided, the classifier
    ///                      receives a padded crop of this region rather than the
    ///                      full image, removing background/habitat bias.
    static func classify(cgImage: CGImage,
                         subjectBodyRect: CGRect? = nil) async -> SpeciesResult {

        // Crop to the subject body rect if available, with 15% padding on each side
        // to avoid clipping feathers or wings at the bounding box edge.
        let imageToClassify: CGImage
        if let bodyRect = subjectBodyRect,
           let crop = cropWithPadding(cgImage: cgImage, normRect: bodyRect, padding: 0.15) {
            imageToClassify = crop
        } else {
            imageToClassify = cgImage
        }

        let detections = await YOLODetector.shared.detect(cgImage: imageToClassify)

        // Collect top-5 regardless of the base threshold for the diagnostic view.
        let top5 = detections
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { (label: $0.label.capitalized, confidence: $0.confidence) }

        // The winner must clear the base threshold to be stored.
        // Display-time banded filtering in AppSettings may further suppress it.
        let best = detections
            .filter { $0.confidence >= baseThreshold }
            .max(by: { $0.confidence < $1.confidence })

        guard let best else {
            return SpeciesResult(label: nil, confidence: nil, candidates: Array(top5))
        }

        return SpeciesResult(
            label: best.label.capitalized,
            confidence: best.confidence,
            candidates: Array(top5)
        )
    }

    // MARK: - Crop helper

    /// Crops a CGImage to a normalised rect, expanded by `padding` on each side.
    /// Returns nil if the resulting rect is degenerate or cropping fails.
    private static func cropWithPadding(cgImage: CGImage,
                                        normRect: CGRect,
                                        padding: CGFloat) -> CGImage? {
        let padX = normRect.width  * padding
        let padY = normRect.height * padding
        let padded = CGRect(
            x: max(0, normRect.minX - padX),
            y: max(0, normRect.minY - padY),
            width:  min(1, normRect.width  + padX * 2),
            height: min(1, normRect.height + padY * 2)
        )
        guard padded.width > 0.01 && padded.height > 0.01 else { return nil }

        let pixelRect = CGRect(
            x: padded.minX * CGFloat(cgImage.width),
            y: padded.minY * CGFloat(cgImage.height),
            width:  padded.width  * CGFloat(cgImage.width),
            height: padded.height * CGFloat(cgImage.height)
        )
        return cgImage.cropping(to: pixelRect)
    }
}
