import Foundation
import ImageIO
import UIKit

struct RAWImageLoadResult {
    let image: UIImage?
    let metadata: [String: String]
    let error: String?
    let usedFallback: Bool
}

enum RAWImageLoader {

    // MARK: - Full image load (detail view)

    static func load(from url: URL) -> RAWImageLoadResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return RAWImageLoadResult(image: nil, metadata: [:],
                                     error: "Could not open file. Check the file is still accessible.",
                                     usedFallback: false)
        }

        var meta: [String: String] = [:]
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            meta = flattenMetadata(props)
        }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8000
        ]

        // 1. Full RAW decode at index 0
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return RAWImageLoadResult(image: UIImage(cgImage: cg), metadata: meta,
                                     error: nil, usedFallback: false)
        }

        // 2. Large thumbnail at index 0
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            return RAWImageLoadResult(image: UIImage(cgImage: cg), metadata: meta,
                                     error: nil, usedFallback: false)
        }

        // 3. Sub-image iteration — guard against count <= 1 to avoid bad range
        let count = CGImageSourceGetCount(src)
        if count > 1 {
            for i in 1..<count {
                if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    return RAWImageLoadResult(image: UIImage(cgImage: cg), metadata: meta,
                                             error: nil, usedFallback: true)
                }
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, thumbOpts as CFDictionary) {
                    return RAWImageLoadResult(image: UIImage(cgImage: cg), metadata: meta,
                                             error: nil, usedFallback: true)
                }
            }
        }

        // 4. Raw byte scan for embedded JPEG — last resort for unsupported CR3 cameras
        if let data = try? Data(contentsOf: url),
           let jpeg = extractEmbeddedJPEG(from: data),
           let img = UIImage(data: jpeg) {
            return RAWImageLoadResult(image: img, metadata: meta,
                                     error: nil, usedFallback: true)
        }

        return RAWImageLoadResult(image: nil, metadata: meta,
                                  error: "Unable to decode this file. This camera model may not be supported by iOS.",
                                  usedFallback: false)
    }

    // MARK: - Thumbnail load (grid card)

    static func thumbnail(from url: URL, maxDimension: Int = 400) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        // 1. Standard thumbnail at index 0
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }

        // 2. Sub-image iteration — guard against bad range
        let count = CGImageSourceGetCount(src)
        if count > 1 {
            for i in 1..<count {
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                    return UIImage(cgImage: cg)
                }
                if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    return UIImage(cgImage: cg)
                }
            }
        }

        // 3. Embedded JPEG byte scan, then downscale
        if let data = try? Data(contentsOf: url),
           let jpeg = extractEmbeddedJPEG(from: data),
           let img = UIImage(data: jpeg) {
            let targetSize = CGSize(width: maxDimension, height: maxDimension * 3 / 4)
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            return renderer.image { _ in
                img.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }

        return nil
    }

    // MARK: - Helpers

    static func extractEmbeddedJPEG(from data: Data) -> Data? {
        guard data.count > 3 else { return nil }
        let bytes = [UInt8](data)

        // Find first JPEG SOI marker: FF D8 FF
        var start: Int? = nil
        for i in 0..<(bytes.count - 2) {
            if bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF {
                start = i
                break
            }
        }
        guard let s = start else { return nil }

        // Find last JPEG EOI marker: FF D9
        var end: Int? = nil
        for i in stride(from: bytes.count - 2, through: s, by: -1) {
            if bytes[i] == 0xFF && bytes[i+1] == 0xD9 {
                end = i + 2
                break
            }
        }
        guard let e = end, e > s else { return nil }
        return data.subdata(in: s..<e)
    }

    private static func flattenMetadata(_ dict: [String: Any], prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix) > \(key)"
            if let nested = value as? [String: Any] {
                result.merge(flattenMetadata(nested, prefix: fullKey)) { $1 }
            } else {
                result[fullKey] = "\(value)"
            }
        }
        return result
    }
}
