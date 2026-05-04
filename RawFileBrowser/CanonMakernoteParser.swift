import Foundation
import ImageIO

// MARK: - Canon AF Point

struct CanonAFPoint {
    let normRect: CGRect
    let isInFocus: Bool
    let isSelected: Bool
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
//   AF Area Y Positions =  405 0 0 0 ... (centre-relative, Y down)
//   AF Points In Focus  = 0             (bitmask: bit 0 set = point 0 in focus)
//   AF Points Selected  = 0             (bitmask: bit 0 set = point 0 selected)
//   Valid AF Points     = 1             (how many entries in arrays are real)
//
// Coordinate conversion:
//   normX = 0.5 + x / AFImageWidth
//   normY = 0.5 + y / AFImageHeight
//
// The CMT3 box inside the CR3 ISOBMFF container holds the Canon Makernote TIFF IFD.
// Apple's ImageIO parses only 6 cosmetic fields; we must read CMT3 directly from
// the raw file bytes.
//
// CMT3 tag for R-series AF data: 0x4013 (AFInfo, int16s array)
// Header layout (int16s):
//   [0] NumAFPoints
//   [1] ValidAFPoints
//   [2] CanonImageWidth   (full image width)
//   [3] CanonImageHeight
//   [4] AFImageWidth      (AF coordinate space — equals sensor for R7)
//   [5] AFImageHeight
//   [6..6+N-1]             AFAreaWidths
//   [6+N..6+2N-1]          AFAreaHeights
//   [6+2N..6+3N-1]         AFAreaXPositions (centre-relative)
//   [6+3N..6+4N-1]         AFAreaYPositions (centre-relative)
//   then bitmask words:    AFPointsInFocus  (16 points per uint16)
//   then bitmask words:    AFPointsSelected (16 points per uint16)

enum CanonMakernoteParser {

    // MARK: - Public API

    static func extractAFPoints(from url: URL) -> [CanonAFPoint]? {
        // Read first 2MB — covers CMT3 (CR3) or the Makernote (CR2) near file start.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        let readSize = min(2 * 1024 * 1024, Int(handle.seekToEndOfFile()))
        try? handle.seek(toOffset: 0)
        let headerData = handle.readData(ofLength: readSize)
        let bytes = [UInt8](headerData)
        print("CanonParser: Read \(bytes.count) bytes from \(url.lastPathComponent)")

        let ext = url.pathExtension.lowercased()

        // CR3 path — AF data is inside the CMT3 ISOBMFF box
        if ext == "cr3" {
            if let cmt3 = findCMT3(in: bytes) {
                print("CanonParser: Found CMT3 (\(cmt3.count) bytes)")
                if let points = parseCanonTIFF(cmt3) {
                    print("CanonParser: \(points.count) AF point(s), \(points.filter(\.isInFocus).count) in focus")
                    return points
                }
                print("CanonParser: parseCanonTIFF returned nil")
            } else {
                print("CanonParser: CMT3 not found in first 2MB")
            }
            return nil
        }

        // CR2 path — AF data is in the Canon Makernote inside the EXIF TIFF IFD.
        // CR2 is itself a TIFF file, so we walk the IFD chain to find the Makernote,
        // then walk the Makernote IFD to find the AFInfo tag (0x0026).
        if ext == "cr2" {
            if let points = parseCR2Makernote(bytes) {
                print("CanonParser: \(points.count) AF point(s), \(points.filter(\.isInFocus).count) in focus")
                return points
            }
            print("CanonParser: CR2 Makernote AF parse failed")
            return nil
        }

        // Fallback for other Canon formats — try CMT3 first, then CR2-style
        if let cmt3 = findCMT3(in: bytes) {
            print("CanonParser: Found CMT3 (\(cmt3.count) bytes)")
            if let points = parseCanonTIFF(cmt3) {
                return points
            }
        }
        return parseCR2Makernote(bytes)
    }

    // MARK: - ISOBMFF box search
    // CMT3 sits directly inside the moov box (or inside a uuid wrapper inside moov).
    // We scan linearly for the ASCII bytes "CMT3" rather than walking the full tree,
    // which is simpler and reliable since CMT3 is always in the first 256KB.

    private static func findCMT3(in bytes: [UInt8]) -> [UInt8]? {
        let target: [UInt8] = [0x43, 0x4D, 0x54, 0x33] // "CMT3"
        guard bytes.count > 16 else { return nil }

        for i in 4..<(bytes.count - 8) {
            guard bytes[i]   == target[0],
                  bytes[i+1] == target[1],
                  bytes[i+2] == target[2],
                  bytes[i+3] == target[3] else { continue }

            // Found "CMT3" at position i.
            // The box size is the 4 bytes BEFORE the name (big-endian uint32).
            let sizeOffset = i - 4
            let boxSize = Int(readU32BE(bytes, at: sizeOffset))

            guard boxSize >= 8,
                  sizeOffset + boxSize <= bytes.count else { continue }

            // Payload starts after the 8-byte header (size + name)
            let payloadStart = i + 4
            let payloadEnd   = sizeOffset + boxSize
            guard payloadEnd > payloadStart else { continue }

            return Array(bytes[payloadStart..<payloadEnd])
        }
        return nil
    }

    // MARK: - CR2 Makernote parser
    //
    // CR2 is a TIFF file. Layout:
    //   Bytes 0-1:  byte order ("II" = little-endian)
    //   Bytes 2-3:  magic (42)
    //   Bytes 4-7:  offset to IFD0
    //
    // IFD0 contains tag 0x8769 (ExifIFD pointer) and tag 0x8827 (MakerNote pointer).
    // The MakerNote itself starts with "Canon\0" (6 bytes) then a full TIFF IFD.
    // That inner IFD contains tag 0x0026 (AFInfo) with the AF point array.

    private static func parseCR2Makernote(_ bytes: [UInt8]) -> [CanonAFPoint]? {
        guard bytes.count > 8 else { return nil }

        // Verify TIFF header
        let b0 = bytes[0], b1 = bytes[1]
        guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else {
            print("CanonParser CR2: not a TIFF file")
            return nil
        }
        let le = b0 == 0x49
        guard readU16(bytes, at: 2, le: le) == 42 else { return nil }

        let ifd0Offset = Int(readU32(bytes, at: 4, le: le))
        print("CanonParser CR2: IFD0 at offset \(ifd0Offset)")

        // Walk IFD0 looking for ExifIFD (0x8769) and/or MakerNote via ExifIFD (0x927C)
        guard let makernoteOffset = findMakernoteOffset(bytes, ifdOffset: ifd0Offset, le: le) else {
            print("CanonParser CR2: Makernote not found")
            return nil
        }

        print("CanonParser CR2: Makernote at offset \(makernoteOffset)")

        // Canon Makernote starts with "Canon\0" (6 bytes) then a TIFF IFD
        // The IFD offsets inside the Makernote are relative to the START OF THE FILE,
        // not relative to the Makernote — Canon uses absolute file offsets.
        let canonSig: [UInt8] = [0x43, 0x61, 0x6E, 0x6F, 0x6E, 0x00] // "Canon\0"
        let hasSig = makernoteOffset + 6 < bytes.count &&
            bytes[makernoteOffset..<(makernoteOffset+6)].elementsEqual(canonSig)

        let ifdStart = hasSig ? makernoteOffset + 6 : makernoteOffset
        print("CanonParser CR2: Makernote IFD at \(ifdStart) (hasSig=\(hasSig))")

        guard ifdStart + 2 < bytes.count else { return nil }
        let entryCount = Int(readU16(bytes, at: ifdStart, le: le))
        guard entryCount > 0 && entryCount < 500 else {
            print("CanonParser CR2: bad entry count \(entryCount)")
            return nil
        }

        print("CanonParser CR2: Makernote IFD has \(entryCount) entries")

        // Canon Makernote IFD value offsets are relative to the Makernote start,
        // not the file start. We try both interpretations and pick the one that
        // produces a sane numAFPoints value (between 1 and 1000).
        for i in 0..<entryCount {
            let e = ifdStart + 2 + i * 12
            guard e + 12 <= bytes.count else { break }

            let tagID = readU16(bytes, at: e, le: le)
            guard tagID == 0x0026 || tagID == 0x0025 || tagID == 0x4013 else { continue }

            print("CanonParser CR2: Found AF tag 0x\(String(format: "%04X", tagID)) at entry \(i)")

            let count      = Int(readU32(bytes, at: e + 4, le: le))
            let valOrOff   = Int(readU32(bytes, at: e + 8, le: le))
            let totalBytes = count * 2
            guard totalBytes > 0 else { continue }

            // Try Makernote-relative offset first, then absolute file offset
            let candidateOffsets: [Int] = totalBytes > 4
                ? [makernoteOffset + valOrOff, valOrOff]
                : [e + 8]

            for dataStart in candidateOffsets {
                guard dataStart >= 0, dataStart + totalBytes <= bytes.count else { continue }
                let payload = Array(bytes[dataStart..<(dataStart + totalBytes)])
                // Sanity-check: first int16 should be a plausible numAFPoints (1-1000)
                // or an R7-style size prefix (>1000) followed by a plausible count
                let firstVal  = Int(Int16(bitPattern: readU16(payload, at: 0, le: le)))
                let secondVal = Int(Int16(bitPattern: readU16(payload, at: 2, le: le)))
                guard (firstVal > 0 && firstVal <= 1000) ||
                      (firstVal > 1000 && secondVal > 0 && secondVal <= 1000) else {
                    print("CanonParser CR2: offset \(dataStart) gives implausible firstVal=\(firstVal), trying next")
                    continue
                }
                print("CanonParser CR2: AF payload \(count) int16 values at offset \(dataStart)")
                return parseAFPayload(payload, count: count, le: le)
            }
            print("CanonParser CR2: no valid offset found for AF tag")
        }

        print("CanonParser CR2: AF tag not found in Makernote IFD")
        return nil
    }

    /// Walks the TIFF IFD chain to find the MakerNote tag (0x927C) inside ExifIFD (0x8769).
    /// Returns the file offset of the start of the MakerNote data.
    private static func findMakernoteOffset(_ bytes: [UInt8], ifdOffset: Int, le: Bool) -> Int? {
        guard ifdOffset + 2 < bytes.count else { return nil }
        let entryCount = Int(readU16(bytes, at: ifdOffset, le: le))
        guard entryCount > 0 && entryCount < 500 else { return nil }

        var exifIFDOffset: Int? = nil

        for i in 0..<entryCount {
            let e = ifdOffset + 2 + i * 12
            guard e + 12 <= bytes.count else { break }
            let tagID = readU16(bytes, at: e, le: le)

            if tagID == 0x8769 {
                // ExifIFD pointer
                exifIFDOffset = Int(readU32(bytes, at: e + 8, le: le))
            }
        }

        guard let exifOffset = exifIFDOffset else { return nil }
        guard exifOffset + 2 < bytes.count else { return nil }

        let exifEntryCount = Int(readU16(bytes, at: exifOffset, le: le))
        guard exifEntryCount > 0 && exifEntryCount < 500 else { return nil }

        for i in 0..<exifEntryCount {
            let e = exifOffset + 2 + i * 12
            guard e + 12 <= bytes.count else { break }
            let tagID = readU16(bytes, at: e, le: le)

            if tagID == 0x927C {
                // MakerNote — value field is offset to makernote data
                let count    = Int(readU32(bytes, at: e + 4, le: le))
                let valOrOff = Int(readU32(bytes, at: e + 8, le: le))
                return count > 4 ? valOrOff : e + 8
            }
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

        for i in 0..<entryCount {
            let e = ifd0 + 2 + i * 12
            guard e + 12 <= bytes.count else { break }

            let tagID = readU16(bytes, at: e, le: le)

            // Tag 0x4013 = AFInfo (R-series mirrorless: R7, R5, R6, R3, R50, R10 etc.)
            // Tag 0x0026 = AFInfo2 (older EOS DSLR models)
            guard tagID == 0x4013 || tagID == 0x0026 || tagID == 0x0025 else { continue }

            print("CanonParser: Found AF tag 0x\(String(format: "%04X", tagID)) at IFD entry \(i)")

            let count    = Int(readU32(bytes, at: e + 4, le: le))
            let valOrOff = Int(readU32(bytes, at: e + 8, le: le))
            // type 3 = SHORT (2 bytes), type 8 = SSHORT (2 bytes signed)
            let totalBytes = count * 2
            let dataStart  = totalBytes > 4 ? valOrOff : e + 8

            guard dataStart >= 0,
                  dataStart + totalBytes <= bytes.count else { continue }

            let payload = Array(bytes[dataStart..<(dataStart + totalBytes)])
            print("CanonParser: AF payload \(count) int16 values, \(payload.count) bytes")

            return parseAFPayload(payload, count: count, le: le)
        }
        return nil
    }

    // MARK: - AF payload parser

    private static func parseAFPayload(_ bytes: [UInt8],
                                        count: Int,
                                        le: Bool) -> [CanonAFPoint]? {
        guard count >= 6 else { return nil }

        func s16(_ index: Int) -> Int {
            guard index * 2 + 1 < bytes.count else { return 0 }
            let raw = readU16(bytes, at: index * 2, le: le)
            return Int(Int16(bitPattern: raw))
        }

        // Detect the "size-prefixed" layout used by R-series and some DSLRs (7D MkII etc.)
        // which has two extra header words before NumAFPoints:
        //   [0]=AFInfoSize (byte count of payload)  [1]=unknown
        //   [2]=NumAFPoints  [3]=ValidAFPoints  [4]=ImgW  [5]=ImgH  [6]=AFImageW  [7]=AFImageH
        // Standard layout (older bodies):
        //   [0]=NumAFPoints  [1]=ValidAFPoints  [2]=ImgW  [3]=ImgH  [4]=AFImageW  [5]=AFImageH
        //
        // Detection: val[0] * 2 ≈ total payload bytes (it's a byte count, not a point count)
        // AND val[2] is a plausible AF point count (1–1000)
        // AND val[3] <= val[2] (ValidAFPoints <= NumAFPoints)
        let val0 = s16(0)
        let val1 = s16(1)
        let val2 = s16(2)
        let val3 = s16(3)
        // val0 is the byte count: val0 should be close to count*2 (total payload bytes)
        let isPrefixedLayout = val0 > 0
            && abs(val0 - count * 2) <= 4       // val0 is byte count, count is word count
            && val2 > 0 && val2 <= 1000        // val2 looks like NumAFPoints
            && val3 >= 0 && val3 <= val2       // val3 looks like ValidAFPoints
        let offset = isPrefixedLayout ? 2 : 0
        if isPrefixedLayout {
            print("CanonParser: prefixed layout detected (val0=\(val0) val1=\(val1) val2=\(val2) val3=\(val3))")
        }

        let numAFPoints  = s16(offset + 0)
        let validPoints  = s16(offset + 1)
        let afImageW     = CGFloat(s16(offset + 4))
        let afImageH     = CGFloat(s16(offset + 5))

        print("CanonParser: offset=\(offset) numAFPoints=\(numAFPoints) valid=\(validPoints) afW=\(afImageW) afH=\(afImageH)")

        guard numAFPoints > 0, numAFPoints <= 1024,
              afImageW > 0, afImageH > 0 else { return nil }

        // Only process the number of valid points — rest are zeroed padding
        let n = max(1, validPoints)

        let wBase = offset + 6
        let hBase = wBase + numAFPoints
        let xBase = hBase + numAFPoints
        let yBase = xBase + numAFPoints

        // In-focus bitmask — one bit per AF point, packed into uint16 words
        let bitmaskBase  = yBase + numAFPoints
        let wordsNeeded  = (numAFPoints + 15) / 16
        var inFocusMask  = Array(repeating: false, count: numAFPoints)
        for word in 0..<wordsNeeded {
            let idx = bitmaskBase + word
            guard idx * 2 + 1 < bytes.count else { break }
            let raw = readU16(bytes, at: idx * 2, le: le)
            for bit in 0..<16 {
                let ptIdx = word * 16 + bit
                if ptIdx < numAFPoints {
                    inFocusMask[ptIdx] = (raw >> bit) & 1 == 1
                }
            }
        }

        // Selected bitmask — immediately follows the in-focus bitmask
        let selectedBase = bitmaskBase + wordsNeeded
        var selectedMask = Array(repeating: false, count: numAFPoints)
        for word in 0..<wordsNeeded {
            let idx = selectedBase + word
            guard idx * 2 + 1 < bytes.count else { break }
            let raw = readU16(bytes, at: idx * 2, le: le)
            for bit in 0..<16 {
                let ptIdx = word * 16 + bit
                if ptIdx < numAFPoints {
                    selectedMask[ptIdx] = (raw >> bit) & 1 == 1
                }
            }
        }

        var points: [CanonAFPoint] = []

        for i in 0..<n {
            let w = CGFloat(s16(wBase + i))
            let h = CGFloat(s16(hBase + i))
            guard w > 0, h > 0 else { continue }

            let x = CGFloat(s16(xBase + i))
            let y = CGFloat(s16(yBase + i))

            // Convert from centre-relative pixel coords to normalised 0-1 top-left
            let normCX = 0.5 + x / afImageW
            let normCY = 0.5 - y / afImageH
            let normW  = w / afImageW
            let normH  = h / afImageH   // correct proportional height — restored

            let rect = CGRect(
                x: max(0, min(1, normCX - normW / 2)),
                y: max(0, min(1, normCY - normH / 2)),
                width:  min(normW, 1),
                height: min(normH, 1)
            )

            print("CanonParser: point[\(i)] x=\(x) y=\(y) w=\(w) h=\(h) inFocus=\(inFocusMask[i]) selected=\(selectedMask[i]) → normRect=\(rect)")
            points.append(CanonAFPoint(normRect: rect, isInFocus: inFocusMask[i], isSelected: selectedMask[i]))
        }

        // Return in-focus points if any, then selected points, otherwise all valid points
        let focused   = points.filter(\.isInFocus)
        if !focused.isEmpty { return focused }
        let selected  = points.filter(\.isSelected)
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
