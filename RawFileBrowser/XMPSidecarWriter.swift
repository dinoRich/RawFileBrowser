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
    ///
    /// - Parameter species: The resolved display species from the caller
    ///   (AppSettings.displaySpecies). Passing it guarantees the sidecar keyword
    ///   matches what the UI shows — a below-threshold classifier guess is never
    ///   written. When nil, falls back to speciesLabel ?? detectedAnimalLabel.
    @discardableResult
    static func write(for file: RAWFile, species overrideSpecies: String? = nil) throws -> URL {
        guard let species = overrideSpecies ?? speciesKeyword(for: file), !species.isEmpty else {
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

    // MARK: - XMP construction

    private static func buildXMP(species: String, file: RAWFile) -> String {
        // Build hierarchical keyword: Wildlife|Birds|Robin
        // or Wildlife|Mammals|Red Fox depending on the class
        let group         = groupLabel(species: species, for: file)
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

    /// The species keyword to write. Prefers the trained classifier result
    /// (speciesLabel); falls back to the generic Vision animal label. Confidence
    /// banding is applied by callers that have AppSettings (e.g. writeXMPBatch and
    /// the detail-view action), so this returns the best available name for the
    /// keyword itself.
    private static func speciesKeyword(for file: RAWFile) -> String? {
        if let s = file.speciesLabel, !s.isEmpty { return s }
        if let g = file.detectedAnimalLabel, !g.isEmpty { return g }
        return nil
    }

    /// Returns the sidecar URL for a given RAW file URL.
    /// e.g. /Volumes/SD/DCIM/IMG_0001.CR3 → /Volumes/SD/DCIM/IMG_0001.xmp
    static func sidecarURL(for rawURL: URL) -> URL {
        rawURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Returns true if a sidecar already exists for this file.
    static func sidecarExists(for file: RAWFile) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: file.url).path)
    }

    /// Maps the written species name to a human-readable group label.
    /// Uses the SAME species string as the keyword so the hierarchy is always
    /// consistent with the flat keyword.
    private static func groupLabel(species: String, for file: RAWFile) -> String {
        let name = species.lowercased()
        switch file.focusRegion {
        case .animalEyes, .animalHead, .animalBody, .yoloEyes, .yoloHead, .yoloBody:
            return isBirdName(name) ? "Birds" : "Mammals"
        default:
            // Even without an animal scoring region, use the name to place birds
            // correctly (the classifier may identify a species the geometric
            // detector didn't localise).
            return isBirdName(name) ? "Birds" : "Wildlife"
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
