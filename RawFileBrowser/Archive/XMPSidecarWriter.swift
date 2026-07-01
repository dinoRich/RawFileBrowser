import Foundation

// MARK: - XMP Sidecar Writer

/// Writes a minimal XMP sidecar file alongside a RAW file.
/// The sidecar contains only the detected species name as a keyword,
/// written in both dc:subject (flat) and lr:hierarchicalSubject (hierarchical)
/// so it appears correctly in Lightroom's keyword tree.
///
/// The file is written non-destructively — the RAW file is never touched.
/// Lightroom reads the sidecar automatically on import or when
/// "Read Metadata from File" is triggered (Metadata menu → Read Metadata from Files).
enum XMPSidecarWriter {

    enum WriteError: LocalizedError {
        case noSpeciesLabel
        case directoryNotAccessible
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSpeciesLabel:
                return "No species detected — run focus analysis first."
            case .directoryNotAccessible:
                return "Cannot write to SD card. Make sure it is still connected."
            case .writeFailed(let msg):
                return "Failed to write XMP file: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Writes an XMP sidecar for a single RAWFile.
    /// Returns the URL of the written sidecar on success.
    @discardableResult
    static func write(for file: RAWFile) throws -> URL {
        guard let species = file.detectedAnimalLabel, !species.isEmpty else {
            throw WriteError.noSpeciesLabel
        }
        let sidecarURL = sidecarURL(for: file.url)
        let xmp        = buildXMP(species: species, file: file)
        do {
            try xmp.write(to: sidecarURL, atomically: true, encoding: .utf8)
            return sidecarURL
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
    }

    /// Writes XMP sidecars for multiple files. Returns a summary of results.
    static func writeBatch(for files: [RAWFile]) -> (written: Int, skipped: Int, errors: [String]) {
        var written = 0
        var skipped = 0
        var errors: [String] = []

        for file in files {
            guard file.detectedAnimalLabel != nil else {
                skipped += 1
                continue
            }
            do {
                try write(for: file)
                written += 1
            } catch {
                errors.append("\(file.name): \(error.localizedDescription)")
            }
        }

        return (written, skipped, errors)
    }

    // MARK: - XMP construction

    private static func buildXMP(species: String, file: RAWFile) -> String {
        // Build hierarchical keyword: Wildlife|Birds|Robin
        // or Wildlife|Mammals|Red Fox depending on the class
        let group         = groupLabel(for: file)
        let hierarchical  = "Wildlife|\(group)|\(species)"
        let escaped        = xmlEscape(species)
        let escapedHier   = xmlEscape(hierarchical)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="RAWFileBrowser">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:lr="http://ns.adobe.com/lightroom/1.0/">

              <!-- Flat keyword — appears in Lightroom keyword list -->
              <dc:subject>
                <rdf:Bag>
                  <rdf:li>\(escaped)</rdf:li>
                </rdf:Bag>
              </dc:subject>

              <!-- Hierarchical keyword — appears as Wildlife > \(group) > \(species) -->
              <lr:hierarchicalSubject>
                <rdf:Bag>
                  <rdf:li>\(escapedHier)</rdf:li>
                </rdf:Bag>
              </lr:hierarchicalSubject>

            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: - Helpers

    /// Returns the sidecar URL for a given RAW file URL.
    /// e.g. /Volumes/SD/DCIM/IMG_0001.CR3 → /Volumes/SD/DCIM/IMG_0001.xmp
    static func sidecarURL(for rawURL: URL) -> URL {
        rawURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Returns true if a sidecar already exists for this file.
    static func sidecarExists(for file: RAWFile) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: file.url).path)
    }

    /// Maps the detected animal's iconic taxon to a human-readable group label.
    private static func groupLabel(for file: RAWFile) -> String {
        // Use the analysis region to infer bird vs mammal
        switch file.focusRegion {
        case .animalEyes, .animalHead, .animalBody, .yoloEyes, .yoloHead, .yoloBody:
            // Try to determine from the label itself
            if let label = file.detectedAnimalLabel?.lowercased() {
                if isBirdName(label) { return "Birds" }
            }
            return "Mammals"
        default:
            return "Wildlife"
        }
    }

    /// Heuristic check whether a common name refers to a bird.
    /// This avoids needing to store the taxon class in RAWFile.
    private static func isBirdName(_ name: String) -> Bool {
        let birdIndicators = [
            "robin", "tit", "finch", "warbler", "thrush", "blackbird",
            "sparrow", "starling", "pigeon", "dove", "hawk", "falcon",
            "eagle", "owl", "heron", "duck", "goose", "swan", "kite",
            "buzzard", "kestrel", "martin", "swift", "swallow", "wren",
            "nuthatch", "treecreeper", "woodpecker", "kingfisher", "dipper",
            "bunting", "linnet", "redpoll", "siskin", "goldfinch", "chaffinch",
            "greenfinch", "bullfinch", "crossbill", "jay", "crow", "rook",
            "jackdaw", "magpie", "raven", "chough", "gannet", "cormorant",
            "shag", "puffin", "guillemot", "razorbill", "tern", "gull",
            "plover", "sandpiper", "curlew", "snipe", "lapwing", "oystercatcher",
            "redshank", "greenshank", "godwit", "knot", "dunlin", "stint",
            "pheasant", "grouse", "partridge", "quail", "moorhen", "coot",
            "rail", "crake", "bittern", "egret", "spoonbill", "ibis",
            "osprey", "harrier", "merlin", "hobby", "peregrine", "goshawk",
            "sparrowhawk", "red kite", "white-tailed", "golden eagle",
        ]
        return birdIndicators.contains { name.contains($0) }
    }

    /// Escapes special XML characters in a string.
    private static func xmlEscape(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }
}
