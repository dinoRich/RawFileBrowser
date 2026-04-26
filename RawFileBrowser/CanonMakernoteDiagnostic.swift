import Foundation
import ImageIO

enum CanonMakernoteDiagnostic {

    static func dump(url: URL) {
        print("\n========== Canon Makernote Diagnostic v3 ==========")
        print("File: \(url.lastPathComponent)")

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("ERROR: Could not open file"); return
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            print("ERROR: No properties"); return
        }

        print("Image size: \(props[kCGImagePropertyPixelWidth as String] ?? "?") x \(props[kCGImagePropertyPixelHeight as String] ?? "?")")

        // Dump EVERY top-level key with its type and value
        print("\n-- All top-level keys with types --")
        for key in props.keys.sorted() {
            let val = props[key]!
            print("  [\(type(of: val))] \(key)")
        }

        // Specifically probe {MakerCanon} regardless of type
        print("\n-- {MakerCanon} raw probe --")
        if let mc = props["{MakerCanon}"] {
            print("  Type: \(type(of: mc))")
            print("  Value: \(mc)")

            // Try casting to various types
            if let dict = mc as? [String: Any] {
                print("  Cast to [String:Any]: SUCCESS — \(dict.keys.count) keys")
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    print("    \(k): \(v)")
                }
            } else if let dict = mc as? NSDictionary {
                print("  Cast to NSDictionary: SUCCESS — \(dict.count) keys")
                for (k, v) in dict {
                    print("    \(k): \(v)")
                }
            } else if let arr = mc as? [Any] {
                print("  Cast to [Any]: SUCCESS — \(arr.count) elements")
                for (i, v) in arr.enumerated() { print("    [\(i)]: \(v)") }
            } else if let data = mc as? Data {
                let bytes = [UInt8](data)
                print("  Cast to Data: \(bytes.count) bytes")
                print("  Hex: \(bytes.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        } else {
            print("  {MakerCanon} key not found in props")
        }

        // Probe {ExifAux}
        print("\n-- {ExifAux} raw probe --")
        if let aux = props["{ExifAux}"] {
            print("  Type: \(type(of: aux))")
            if let dict = aux as? [String: Any] {
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    print("  \(k): \(v)")
                }
            } else if let dict = aux as? NSDictionary {
                for (k, v) in dict { print("  \(k): \(v)") }
            }
        }

        // Probe {Exif} for SubjectArea and any AF tags
        print("\n-- {Exif} AF-related keys --")
        if let exif = props["{Exif}"] as? [String: Any] ?? props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            for (k, v) in exif.sorted(by: { $0.key < $1.key }) {
                let lower = k.lowercased()
                if lower.contains("af") || lower.contains("focus") ||
                   lower.contains("subject") || lower.contains("area") {
                    print("  \(k): \(v)")
                }
            }
            print("  (SubjectArea present: \(exif["SubjectArea"] != nil))")
        }

        print("====================================================\n")
    }
}
