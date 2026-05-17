import Foundation
import CoreML
import Vision
import UIKit
import ImageIO

// MARK: - SpeciesResult

/// The result of a species classification on a single photo.
struct SpeciesResult {
    /// The top species label, e.g. "Robin". nil if model not loaded or confidence too low.
    let label: String?
    /// Confidence score 0–1. nil when no detection was made.
    let confidence: Float?
}

// MARK: - SpeciesDetector
//
// A lightweight wrapper around YOLODetector that runs ONLY species classification
// from the embedded JPEG preview — no Laplacian, no Vision pose detection.
//
// This is designed to run at file-load time in a background pass so that species
// labels are available for grouping before focus analysis runs.
//
// It reuses YOLODetector.shared internally, so the model is only loaded once.

struct SpeciesDetector {

    // MARK: - Public API

    /// Classify the species in the photo at `url`.
    /// Loads the embedded thumbnail (same one used by FocusAnalyzer and PHasher).
    /// Returns a SpeciesResult with nil label if the model isn't loaded or nothing
    /// was detected above the confidence threshold.
    static func classify(url: URL, confidenceThreshold: Float = 0.35) async -> SpeciesResult {
        guard let cgImage = loadThumbnail(from: url) else {
            return SpeciesResult(label: nil, confidence: nil)
        }
        return await classify(cgImage: cgImage, confidenceThreshold: confidenceThreshold)
    }

    /// Classify from an already-loaded CGImage (avoids reloading if caller has it).
    static func classify(cgImage: CGImage, confidenceThreshold: Float = 0.35) async -> SpeciesResult {
        let detections = await YOLODetector.shared.detect(cgImage: cgImage)

        // Pick the highest-confidence result that clears the threshold.
        let best = detections
            .filter { $0.confidence >= confidenceThreshold }
            .max(by: { $0.confidence < $1.confidence })

        guard let best else {
            return SpeciesResult(label: nil, confidence: nil)
        }

        return SpeciesResult(label: best.label.capitalized, confidence: best.confidence)
    }

    // MARK: - Thumbnail loading
    //
    // Identical approach to PHasher — pulls the embedded JPEG preview via ImageIO.
    // 512 px is large enough for the classifier but much faster than a full decode.

    static func loadThumbnail(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
