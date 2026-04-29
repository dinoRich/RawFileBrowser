import Foundation
import ImageIO

// MARK: - Canon AF Point

struct CanonAFPoint {
    let normRect: CGRect

    /// True when the camera confirmed focus lock on this point (AFPointsInFocus bitmask).
    let isInFocus: Bool

    /// True when the camera was actively tracking this point (AFPointsSelected bitmask).
    /// On Animal Eye AF shots the R7 sets this flag but NOT isInFocus — this is the
    /// correct indicator when using subject/eye tracking modes.
    let isSelected: Bool

    /// True when this point came from tag 0x4013 (R-series mirrorless, precise ~163px box).
    /// False when it came from tag 0x0026 (legacy DSLR fallback, coarse ~348px zone).
    /// The overlay draws dashed brackets for imprecise fallback points.
    let isPrecise: Bool
}

// MARK: - Canon CR3 AF Parser
//
// From exiftool output on Canon R7 CR3 files, the AF data structure is:
//
//   AF Image Width  = 6960  (same as full sensor — no scaling needed for R7)
//   AF Image Height = 4640
//   AF Area Widths  = 163 0 0 0 ...   (only first ValidAFPoints entries are non-zero)
//   AF Area Heights = 163 0 0 0 ...
//   AF Area X Positions = -121 0 0 0 ... (centre-relative, pixels)
//   AF Area Y Positions =  405 0 0 0 ... (centre-relative)
//   AF Points In Focus  = 0             (bitmask: bit 0 set = point 0 in focus)
//   AF Points Selected  = 0             (bitmask: bit 0 set = point 0 selected)
//   Valid AF Points     = 1             (how many entries in arrays are real)
//
// The CMT3 box inside the CR3 ISOBMFF container holds the Canon Makernote TIFF IFD.
// Apple's ImageIO parses only 6 cosmetic fields; we must read CMT3 directly.
//
// ── Y-AXIS CONVENTIONS ─────────────────────────────────────────────────────────
//
//   Tag 0x4013 (R-series mirrorless):
//     Y axis increases DOWNWARD from centre — matches UIKit/SwiftUI screen coords.
//     normCY = 0.5 + y / afImageH
//     Confirmed: y=405 (positive) → below centre → normCY > 0.5 ✓
//
//   Tag 0x0026 (legacy DSLR AFInfo2):
//     Y axis increases UPWARD from centre — mathematical convention, opposite to screen.
//     normCY = 0.5 - y / afImageH   ← sign is NEGATED
//     Confirmed via DPP: y=404 (positive) → above centre → normCY < 0.5 ✓
//
// ── TAG PRIORITY ───────────────────────────────────────────────────────────────
//
//   The R7 writes BOTH tags into every file:
//     0x4013 — Precise mirrorless point (~163px). Preferred.
//               On shots where Animal Eye AF found no subject, written as a stub
//               (11 int16 values, afW=0, afH=0). Parser detects and skips stub.
//     0x0026 — Coarse legacy zone (~348px). Used as fallback only.
//   IFD entries are NOT tag-sorted — always do two passes to guarantee priority.
//
// ── BITMASK BEHAVIOUR ──────────────────────────────────────────────────────────
//
//   Animal Eye AF / subject tracking: R7 sets AFPointsSelected but NOT
//   AFPointsInFocus. Both must be read. Display priority:
//     1. inFocus  → green  (confirmed focus lock)
//     2. selected → yellow (eye/subject tracking)
//     3. fallback → white  (valid point, neither bitmask set)
//
// ── HEADER LAYOUT (int16s) ─────────────────────────────────────────────────────
//
//   Standard: [0]=NumAFPoints [1]=ValidAFPoints [2]=ImgW [3]=ImgH
//             [4]=AFImageW [5]=AFImageH  then coordinate arrays...
//   R7 adds two prefix words:
//             [0]=AFInfoSize [1]=unknown  (remaining fields at +2 offset)

enum CanonMakernoteParser {

    // MARK: - Public API

    static func extractAFPoints(from url: URL) -> [CanonAFPoint]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        let readSize = min(2 * 1024 * 1024, Int((try? handle.seekToEndOfFile()) ?? 0))
        try? handle.seek(toOffset: 0)
        let headerData = handle.readData(ofLength: readSize)
        let bytes = [UInt8](headerData)
        print("CanonParser: Read \(bytes.count) bytes from \(url.lastPathComponent)")

        if let cmt3 = findCMT3(in: bytes) {
            print("CanonParser: Found CMT3 (\(cmt3.count) bytes)")
            if let points = parseCanonTIFF(cmt3) {
                let nFocus    = points.filter(\.isInFocus).count
                let nSelected = points.filter(\.isSelected).count
                let precise   = points.first?.isPrecise == true
                print("CanonParser: \(points.count) point(s) — inFocus=\(nFocus) selected=\(nSelected) precise=\(precise)")
                return points
            }
            print("CanonParser: parseCanonTIFF returned nil")
        } else {
            print("CanonParser: CMT3 not found in first 2MB")
        }
        return nil
    }

    // MARK: - ISOBMFF box search

    private static func findCMT3(in bytes: [UInt8]) -> [UInt8]? {
        let target: [UInt8] = [0x43, 0x4D, 0x54, 0x33] // "CMT3"
        guard bytes.count > 16 else { return nil }

        for i in 4..<(bytes.count - 8) {
            guard bytes[i]   == target[0],
                  bytes[i+1] == target[1],
                  bytes[i+2] == target[2],
                  bytes[i+3] == target[3] else { continue }

            let sizeOffset = i - 4
            let boxSize    = Int(readU32BE(bytes, at: sizeOffset))
            guard boxSize >= 8, sizeOffset + boxSize <= bytes.count else { continue }

            let payloadStart = i + 4
            let payloadEnd   = sizeOffset + boxSize
            guard payloadEnd > payloadStart else { continue }

            return Array(bytes[payloadStart..<payloadEnd])
        }
        return nil
    }

    // MARK: - TIFF IFD parser

    private static func parseCanonTIFF(_ bytes: [UInt8]) -> [CanonAFPoint]? {
        guard bytes.count > 8 else { return nil }

        let b0 = bytes[0], b1 = bytes[1]
        guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else { return nil }
        let le = b0 == 0x49

        guard readU16(bytes, at: 2, le: le) == 42 else { return nil }

        let ifd0 = Int(readU32(bytes, at: 4, le: le))
        guard ifd0 + 2 < bytes.count else { return nil }

        let entryCount = Int(readU16(bytes, at: ifd0, le: le))
        guard entryCount > 0 && entryCount < 500 else { return nil }

        print("CanonParser: TIFF IFD has \(entryCount) entries")

        // Two-pass scan: prefer 0x4013 (precise mirrorless) over 0x0026 (coarse legacy).
        // IFD entries are not tag-sorted, so we cannot stop at first match.
        func extractPayload(forTag tag: UInt16) -> (payload: [UInt8], count: Int)? {
            for i in 0..<entryCount {
                let e = ifd0 + 2 + i * 12
                guard e + 12 <= bytes.count else { break }
                guard readU16(bytes, at: e, le: le) == tag else { continue }

                let count      = Int(readU32(bytes, at: e + 4, le: le))
                let valOrOff   = Int(readU32(bytes, at: e + 8, le: le))
                let totalBytes = count * 2
                let dataStart  = totalBytes > 4 ? valOrOff : e + 8
                guard dataStart >= 0, dataStart + totalBytes <= bytes.count else { continue }

                print("CanonParser: Found tag 0x\(String(format: "%04X", tag)) at entry \(i) (\(count) int16 values)")
                return (Array(bytes[dataStart..<(dataStart + totalBytes)]), count)
            }
            return nil
        }

        // Pass 1 — precise R-series mirrorless tag, Y axis increases downward
        if let (payload, count) = extractPayload(forTag: 0x4013) {
            if let points = parseAFPayload(payload, count: count, le: le,
                                           isPrecise: true, yAxisDownward: true) {
                print("CanonParser: Using 0x4013 (precise mirrorless, Y-down)")
                return points
            }
            // afW=0/afH=0 stub — Animal Eye AF found no subject
            print("CanonParser: 0x4013 is a stub — falling back to legacy tag")
        }

        // Pass 2 — coarse legacy DSLR tag, Y axis increases upward (mathematical convention)
        for legacyTag: UInt16 in [0x0026, 0x0025] {
            if let (payload, count) = extractPayload(forTag: legacyTag) {
                if let points = parseAFPayload(payload, count: count, le: le,
                                               isPrecise: false, yAxisDownward: false) {
                    print("CanonParser: Using 0x\(String(format: "%04X", legacyTag)) (imprecise DSLR zone, Y-up)")
                    return points
                }
            }
        }

        return nil
    }

    // MARK: - AF payload parser

    /// - Parameter yAxisDownward: true for tag 0x4013 (Y increases down, matches screen).
    ///                            false for tag 0x0026 (Y increases up, must be negated).
    private static func parseAFPayload(_ bytes: [UInt8],
                                       count: Int,
                                       le: Bool,
                                       isPrecise: Bool,
                                       yAxisDownward: Bool) -> [CanonAFPoint]? {
        guard count >= 6 else { return nil }

        func s16(_ index: Int) -> Int {
            guard index * 2 + 1 < bytes.count else { return 0 }
            return Int(Int16(bitPattern: readU16(bytes, at: index * 2, le: le)))
        }

        // Detect R7/R5/R6mkII layout: two prefix words before NumAFPoints.
        // val[0] > 1000 means it is a byte-count, not a point count.
        let val0 = s16(0), val2 = s16(2), val3 = s16(3)
        let isR7Layout = val0 > 1000 && val2 > 0 && val2 < 1000 && val3 >= 0 && val3 <= val2
        let offset = isR7Layout ? 2 : 0

        let numAFPoints = s16(offset + 0)
        let validPoints = s16(offset + 1)
        let afImageW    = CGFloat(s16(offset + 4))
        let afImageH    = CGFloat(s16(offset + 5))

        print("CanonParser: offset=\(offset) numAFPoints=\(numAFPoints) valid=\(validPoints) afW=\(afImageW) afH=\(afImageH) yDown=\(yAxisDownward)")

        // Reject stubs (afW=0/afH=0 means no valid AF data)
        guard numAFPoints > 0, numAFPoints <= 1024,
              afImageW > 0, afImageH > 0 else { return nil }

        let n     = max(1, validPoints)
        let wBase = offset + 6
        let hBase = wBase + numAFPoints
        let xBase = hBase + numAFPoints
        let yBase = xBase + numAFPoints

        // Read both bitmasks (AFPointsInFocus then AFPointsSelected).
        // Animal Eye AF sets AFPointsSelected but not AFPointsInFocus.
        let wordsNeeded  = (numAFPoints + 15) / 16
        let inFocusBase  = yBase + numAFPoints
        let selectedBase = inFocusBase + wordsNeeded

        func readBitmask(base: Int) -> [Bool] {
            var mask = Array(repeating: false, count: numAFPoints)
            for word in 0..<wordsNeeded {
                let idx = base + word
                guard idx * 2 + 1 < bytes.count else { break }
                let raw = readU16(bytes, at: idx * 2, le: le)
                for bit in 0..<16 {
                    let pt = word * 16 + bit
                    if pt < numAFPoints { mask[pt] = (raw >> bit) & 1 == 1 }
                }
            }
            return mask
        }

        let inFocusMask  = readBitmask(base: inFocusBase)
        let selectedMask = readBitmask(base: selectedBase)
        print("CanonParser: inFocus any=\(inFocusMask.contains(true))  selected any=\(selectedMask.contains(true))")

        var points: [CanonAFPoint] = []

        for i in 0..<n {
            let w = CGFloat(s16(wBase + i))
            let h = CGFloat(s16(hBase + i))
            guard w > 0, h > 0 else { continue }

            let x = CGFloat(s16(xBase + i))
            let y = CGFloat(s16(yBase + i))

            let normCX = 0.5 + x / afImageW

            // Y convention differs between tags:
            //   0x4013 mirrorless: Y increases downward from centre (matches screen) → add
            //   0x0026 legacy DSLR: Y increases upward from centre (mathematical) → subtract
            let normCY = yAxisDownward
                ? 0.5 + y / afImageH   // screen-native, no flip needed
                : 0.5 - y / afImageH   // invert so positive Y maps above centre on screen

            let normW = w / afImageW
            let normH = h / afImageH

            let rect = CGRect(
                x: max(0, min(1, normCX - normW / 2)),
                y: max(0, min(1, normCY - normH / 2)),
                width:  min(normW, 1),
                height: min(normH, 1)
            )

            print("CanonParser: point[\(i)] x=\(x) y=\(y) w=\(w) h=\(h) inFocus=\(inFocusMask[i]) selected=\(selectedMask[i]) precise=\(isPrecise) normCY=\(String(format:"%.3f",normCY)) → \(rect)")
            points.append(CanonAFPoint(
                normRect:   rect,
                isInFocus:  inFocusMask[i],
                isSelected: selectedMask[i],
                isPrecise:  isPrecise
            ))
        }

        // Priority: inFocus > selected > any valid point
        let focused  = points.filter(\.isInFocus)
        if !focused.isEmpty  { return focused }
        let selected = points.filter(\.isSelected)
        if !selected.isEmpty { return selected }
        return points.isEmpty ? nil : points
    }

    // MARK: - Binary helpers

    private static func readU16(_ b: [UInt8], at i: Int, le: Bool) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return le
            ? (UInt16(b[i+1]) << 8 | UInt16(b[i]))
            : (UInt16(b[i])   << 8 | UInt16(b[i+1]))
    }

    private static func readU32(_ b: [UInt8], at i: Int, le: Bool) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        let v = [UInt32(b[i]), UInt32(b[i+1]), UInt32(b[i+2]), UInt32(b[i+3])]
        return le
            ? (v[3]<<24 | v[2]<<16 | v[1]<<8 | v[0])
            : (v[0]<<24 | v[1]<<16 | v[2]<<8 | v[3])
    }

    private static func readU32BE(_ b: [UInt8], at i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i])<<24 | UInt32(b[i+1])<<16 | UInt32(b[i+2])<<8 | UInt32(b[i+3])
    }
}
