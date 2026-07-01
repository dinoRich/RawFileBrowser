import Foundation
import UIKit
import ImageIO
import CoreGraphics

// MARK: - PHasher
//
// Computes a 64-bit perceptual hash (pHash) from an image's embedded JPEG preview.
//
// Algorithm:
//   1. Load the embedded thumbnail (same one used by FocusAnalyzer — fast, no full RAW decode).
//   2. Resize to 32×32 greyscale pixels.
//   3. Compute the 2-D Discrete Cosine Transform (DCT) over the 32×32 grid.
//   4. Take the top-left 8×8 of the DCT output (the low-frequency components).
//   5. Compute the mean of those 64 values (excluding the DC term at [0,0]).
//   6. Each of the 64 bits is 1 if the value is above the mean, 0 if below.
//
// Two hashes are "similar" if their Hamming distance (number of differing bits)
// is below a threshold. A distance of 0 = identical; ≤10 = near-duplicate in practice.
//
// Why this works for near-duplicate detection:
//   The DCT captures the overall tonal structure of the image at low frequency.
//   Compression artefacts, minor exposure differences, and small crops between
//   burst frames do not affect the low-frequency content meaningfully.
//   High-frequency detail (fine feathers, noise) is discarded — that is intentional.

struct PHasher {

    // MARK: - Public API

    /// Compute a 64-bit perceptual hash for the RAW file at `url`.
    /// Returns nil if no usable thumbnail can be loaded.
    static func hash(for url: URL) -> UInt64? {
        guard let thumbnail = loadThumbnail(from: url) else { return nil }
        guard let grey = toGreyscale32x32(thumbnail)   else { return nil }
        let dct  = dct8x8(grey)
        return buildHash(from: dct)
    }

    /// Hamming distance between two 64-bit hashes.
    /// Returns the number of bit positions where the two hashes differ (0–64).
    /// Lower = more similar. ≤10 is a reliable near-duplicate threshold.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        // XOR flips every bit that differs, then count the 1-bits.
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Threshold

    /// Default maximum Hamming distance to consider two photos "similar".
    /// Callers can pass a different value — this is the fallback used when no
    /// setting is available. See AppSettings.similarityThreshold.
    static let defaultSimilarityThreshold = 10

    // MARK: - Thumbnail loading
    //
    // Mirrors the approach in FocusAnalyzer: use ImageIO to pull the embedded
    // JPEG preview rather than decoding the full RAW. Fast and low-memory.

    private static func loadThumbnail(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Ask ImageIO for the largest embedded thumbnail.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,    // 256 px is more than enough for a 32×32 hash
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - Greyscale 32×32 downscale

    private static func toGreyscale32x32(_ image: CGImage) -> [Float]? {
        let size = 32
        let bpr  = size   // 1 byte per pixel (greyscale, 8-bit)

        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels.map { Float($0) }
    }

    // MARK: - DCT-II (8×8 of a 32×32 input)
    //
    // Full 32×32 DCT is not needed. We only use the top-left 8×8 output values,
    // which represent the image's lowest spatial frequencies.
    //
    // This is a naive O(N⁴) implementation — fine for a single 32×32 block.
    // For a library-quality implementation you would use the separable row/column
    // approach, but for 1024 input pixels run once per photo it is imperceptible.

    private static func dct8x8(_ pixels: [Float]) -> [Float] {
        let N = 32   // input grid size
        let M = 8    // output coefficients we care about

        // Precompute the cosine terms to avoid repeated trig inside the loop.
        // cos_h[u][x] = cos(π * u * (2x+1) / (2N))
        var cos_h = [[Float]](repeating: [Float](repeating: 0, count: N), count: M)
        for u in 0..<M {
            for x in 0..<N {
                cos_h[u][x] = cos(Float.pi * Float(u) * Float(2 * x + 1) / Float(2 * N))
            }
        }

        var result = [Float](repeating: 0, count: M * M)

        for v in 0..<M {
            for u in 0..<M {
                var sum: Float = 0
                for y in 0..<N {
                    for x in 0..<N {
                        sum += pixels[y * N + x] * cos_h[u][x] * cos_h[v][y]
                    }
                }
                result[v * M + u] = sum
            }
        }

        return result
    }

    // MARK: - Hash construction

    private static func buildHash(from dct: [Float]) -> UInt64 {
        // dct has 64 values (8×8).
        // Exclude the DC component at index 0 when computing the mean,
        // because it encodes overall brightness and would dominate the average.
        let values = Array(dct.dropFirst())             // 63 values
        let mean   = values.reduce(0, +) / Float(values.count)

        // Build a 64-bit integer: bit i is 1 if dct[i] >= mean, else 0.
        // We include dct[0] in the bit assignment (standard pHash convention)
        // even though it was excluded from the mean calculation.
        var hash: UInt64 = 0
        for i in 0..<64 {
            if dct[i] >= mean {
                hash |= (1 << i)
            }
        }
        return hash
    }
}

// MARK: - SimilarGroup
//
// A group of photos that are all near-duplicates of each other,
// as determined by pairwise Hamming distance ≤ PHasher.similarityThreshold.

struct SimilarGroup: Identifiable {
    let id = UUID()
    /// All files in this group, ordered by modification date (earliest first).
    var files: [RAWFile]

    var coverFile: RAWFile { files[0] }
    var count: Int { files.count }
}

// MARK: - Colour signature

extension PHasher {

    // A compact colour signature: a 16-bin normalised hue histogram computed
    // from the same 256px thumbnail used for pHash. Saturation-weighted so that
    // near-grey pixels (which have unreliable hue) contribute less to the bins.
    //
    // Low-saturation images (overcast grey mud, grey sky) will produce flat
    // histograms — colourDistance will then be near 0 for any two such images,
    // which is correct: we cannot distinguish them by colour alone. The pHash
    // gate still applies in that case.

    /// Compute a 16-bin hue histogram for the RAW file at `url`.
    /// Returns nil if the thumbnail cannot be loaded.
    static func colourSignature(for url: URL) -> [Float]? {
        guard let thumbnail = loadThumbnailForColour(from: url) else { return nil }
        return hueHistogram(thumbnail, bins: 16)
    }

    /// Histogram intersection distance in [0, 1].
    /// 0 = identical colour distribution. 1 = no overlap at all.
    /// Returns 0 when either signature is nil (no colour gate applied).
    static func colourDistance(_ a: [Float]?, _ b: [Float]?) -> Float {
        guard let a, let b, a.count == b.count else { return 0 }
        let intersection = zip(a, b).map { min($0, $1) }.reduce(0, +)
        return 1.0 - intersection   // both histograms are already normalised to sum=1
    }

    // MARK: - Private helpers

    /// Load the thumbnail at a slightly larger size than pHash needs so hue
    /// sampling has more pixels to work with. Reuses the same ImageIO path.
    private static func loadThumbnailForColour(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Build a normalised saturation-weighted hue histogram from a CGImage.
    private static func hueHistogram(_ image: CGImage, bins: Int) -> [Float]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        // Render to an RGBA 8-bit buffer
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var histogram = [Float](repeating: 0, count: bins)
        var totalWeight: Float = 0

        let pixelCount = w * h
        for i in 0..<pixelCount {
            let base = i * 4
            let r = Float(pixels[base])     / 255.0
            let g = Float(pixels[base + 1]) / 255.0
            let b = Float(pixels[base + 2]) / 255.0

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC

            // Skip near-grey pixels — their hue is unreliable
            let saturation = maxC > 0 ? delta / maxC : 0
            guard saturation > 0.15 else { continue }

            // Compute hue in [0, 360)
            var hue: Float = 0
            if delta > 0 {
                switch maxC {
                case r: hue = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                case g: hue = 60.0 * ((b - r) / delta + 2)
                default: hue = 60.0 * ((r - g) / delta + 4)
                }
                if hue < 0 { hue += 360 }
            }

            let bin = min(Int(hue / 360.0 * Float(bins)), bins - 1)
            histogram[bin] += saturation   // weight by saturation
            totalWeight    += saturation
        }

        // Normalise to sum = 1; return flat histogram for near-grey images
        guard totalWeight > 0 else { return [Float](repeating: 1.0 / Float(bins), count: bins) }
        return histogram.map { $0 / totalWeight }
    }
}
