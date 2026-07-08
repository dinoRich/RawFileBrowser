import SwiftUI

// MARK: - Focus Diagnostic Sheet
//
// Shows every intermediate value computed during focus analysis so you can
// see exactly why an image was accepted or rejected and tune the thresholds.
// Open it from the detail view toolbar (the "stethoscope" icon).

struct FocusDiagnosticView: View {
    let file: RAWFile
    /// Inherited from the presenting view's environment. Used so the exposure
    /// verdict shown here agrees with the user-configured thresholds that drive
    /// the filters and outcome actions (not the hardcoded fallback values).
    @EnvironmentObject var settings: AppSettings

    /// Exposure verdict using the user's configured clip thresholds.
    /// exposureIssue returns nil when no threshold fires → "Well exposed".
    private func settingsVerdict(for ea: ExposureAssessment) -> (label: String, color: Color) {
        switch settings.exposureIssue(for: ea) {
        case .overexposed:  return ("Overexposed",  Color(UIColor.systemRed))
        case .underexposed: return ("Underexposed", Color(UIColor.systemBlue))
        default:            return ("Well exposed", Color(UIColor.systemGreen))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Verdict ─────────────────────────────────────────────
                    VerdictCard(file: file)

                    // ── Decision path ────────────────────────────────────────
                    DiagSection(title: "Decision Path", icon: "arrow.triangle.branch") {
                        DiagRow("AF point in file",     value: file.hadAFPoint  ? "Yes" : "No",
                                highlight: file.hadAFPoint ? .green : .secondary)
                        DiagRow("Subject detected",     value: !file.subjectContour.isEmpty
                                                                || file.focusRegion == .humanEyes
                                                                || file.focusRegion == .humanFace
                                                                ? "Yes" : "No")
                        if let overlaps = file.afOverlapsSubject {
                            DiagRow("AF on subject", value: overlaps ? "Yes ✓" : "No ✗",
                                    highlight: overlaps ? .green : .red)
                        }
                        DiagRow("Analysis branch",      value: branchDescription(file))
                        DiagRow("Scoring region",        value: file.focusRegion.rawValue)
                    }

                    // ── Sharpness numbers ────────────────────────────────────
                    DiagSection(title: "Sharpness Scores", icon: "waveform.path.ecg") {

                        DiagRow("Rating basis",
                                value: file.ratingBasis.rawValue,
                                highlight: ratingBasisColor(file.ratingBasis))

                        // Case 5 dual scores — show both when available
                        if let afRaw = file.afPointRawScore, let subRaw = file.subjectBodyRawScore {
                            DiagRow("AF point score (raw)",
                                    value: pct(afRaw),
                                    detail: "Laplacian at AF point rect",
                                    highlight: scoreColor(afRaw,
                                                          sharp: file.sharpThreshold,
                                                          ok: file.acceptableThreshold))
                            DiagRow("Subject body score (raw)",
                                    value: pct(subRaw),
                                    detail: "Laplacian at subject body rect",
                                    highlight: scoreColor(subRaw,
                                                          sharp: file.sharpThreshold,
                                                          ok: file.acceptableThreshold))
                            Divider()
                        }

                        DiagRow("Raw Laplacian score",
                                value: pct(file.rawSharpnessScore),
                                detail: "score used for rating (before size penalty)",
                                highlight: scoreColor(file.rawSharpnessScore,
                                                      sharp: file.sharpThreshold,
                                                      ok: file.acceptableThreshold))

                        DiagRow("Size confidence",
                                value: pct(file.subjectSizeConfidence),
                                detail: "penalty for small subjects in frame",
                                highlight: file.subjectSizeConfidence < 0.5 ? .orange : .primary)

                        DiagRow("Final score  (raw × size)",
                                value: pct(file.focusScore),
                                detail: "what the threshold is applied to",
                                highlight: scoreColor(file.focusScore,
                                                      sharp: file.sharpThreshold,
                                                      ok: file.acceptableThreshold),
                                bold: true)

                        Divider()

                        DiagRow("Sharp threshold",      value: pct(file.sharpThreshold),
                                highlight: .green)
                        DiagRow("Acceptable threshold", value: pct(file.acceptableThreshold),
                                highlight: .orange)
                        DiagRow("Gap to sharp",
                                value: gap(file.focusScore, target: file.sharpThreshold),
                                highlight: file.focusScore >= file.sharpThreshold ? .green : .red)

                        Divider()

                        DiagRow("Blur type",            value: file.blurType.rawValue)
                    }

                    // ── Subject & region sizes ───────────────────────────────
                    DiagSection(title: "Region Sizes", icon: "crop") {
                        DiagRow("Subject body area",
                                value: areaPct(file.subjectBodyArea),
                                detail: "% of image — used for size confidence",
                                highlight: file.subjectBodyArea > 0.05 ? .green : .orange)

                        DiagRow("Scoring rect area",
                                value: areaPct(file.scoringRectArea),
                                detail: "% of image — the actual crop scored")

                        if let conf = file.detectionConfidence {
                            DiagRow("Detection confidence",
                                    value: pct(Double(conf)),
                                    detail: "YOLO confidence",
                                    highlight: conf > 0.6 ? .green : .orange)
                        }

                        if let label = file.detectedAnimalLabel {
                            DiagRow("Detected species", value: label,
                                    detail: "Raw detection result (shown regardless of display threshold)")
                        }

                        if !file.speciesCandidates.isEmpty {
                            Divider()
                            Text("Species candidates")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(Array(file.speciesCandidates.enumerated()), id: \.offset) { index, candidate in
                                HStack(spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                    Text(candidate.label)
                                        .font(.subheadline)
                                    Spacer()
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.secondary.opacity(0.2))
                                                .frame(height: 6)
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(index == 0 ? Color.green : Color.secondary.opacity(0.5))
                                                .frame(width: geo.size.width * CGFloat(candidate.confidence), height: 6)
                                        }
                                    }
                                    .frame(width: 60, height: 6)
                                    Text(String(format: "%.0f%%", candidate.confidence * 100))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(index == 0 ? .primary : .secondary)
                                        .frame(width: 38, alignment: .trailing)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // ── Threshold guide ──────────────────────────────────────
                    ThresholdGuideCard(file: file)

                    // ── Exposure assessment ──────────────────────────────────
                    if let exp = file.exposureAssessment {
                        ExposureSection(exposure: exp,
                                        verdictOverride: settingsVerdict(for: exp))
                    }

                    Spacer(minLength: 32)
                }
                .padding()
            }
            .navigationTitle("Focus Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Helpers

    private func triStateLabel(_ value: Bool?, yes: String, no: String, unknown: String) -> String {
        guard let v = value else { return unknown }
        return v ? yes : no
    }

    private func triStateColor(_ value: Bool?) -> Color {
        guard let v = value else { return .secondary }
        return v ? .green : .orange
    }

    private func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    private func areaPct(_ v: Double) -> String {
        if v <= 0 { return "—" }
        return String(format: "%.2f%%", v * 100)
    }

    private func gap(_ score: Double, target: Double) -> String {
        let diff = score - target
        let sign = diff >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", diff * 100))pp"
    }

    private func scoreColor(_ score: Double, sharp: Double, ok: Double) -> Color {
        if score >= sharp { return .green }
        if score >= ok    { return .orange }
        return .red
    }

    private func branchDescription(_ file: RAWFile) -> String {
        switch (file.hadAFPoint, !file.subjectContour.isEmpty || isHuman(file)) {
        case (true, true):
            if file.afNotOnSubject {
                return "AF + Subject → AF not on subject (Cases 3/4)"
            } else {
                return "AF + Subject → AF on Subject (Case 5)"
            }
        case (true, false):  return "AF only → Score at AF point"
        case (false, true):  return "Subject only → Score at subject body (Case 2)"
        case (false, false): return "No AF, no subject → Full image (Case 1)"
        }
    }

    private func ratingBasisColor(_ basis: FocusResult.RatingBasis) -> Color {
        switch basis {
        case .afPoint:         return .secondary  // AF-only path (no subject detected)
        case .subjectBody:     return .primary
        case .afPointDegraded: return .orange
        case .fullImage:       return .secondary
        }
    }

    private func isHuman(_ file: RAWFile) -> Bool {
        file.focusRegion == .humanEyes || file.focusRegion == .humanFace
    }
}

// MARK: - Verdict card

private struct VerdictCard: View {
    let file: RAWFile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: file.focusStatus.systemImage)
                .font(.system(size: 36))
                .foregroundStyle(Color(file.focusStatus.color))

            VStack(alignment: .leading, spacing: 4) {
                Text(file.focusStatus.rawValue)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(file.focusStatus.color))
                Text(file.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(file.focusStatus.color).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(file.focusStatus.color).opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Threshold guide card
// Shows a mini bar chart so you can visually see where the score sits
// relative to the thresholds.

private struct ThresholdGuideCard: View {
    let file: RAWFile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Score vs Thresholds", systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 28)

                    // Acceptable zone (orange)
                    if file.acceptableThreshold > 0 {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.25))
                            .frame(width: geo.size.width * CGFloat(min(file.sharpThreshold, 1.0)),
                                   height: 28)
                    }

                    // Sharp zone (green) — only right portion above sharp threshold
                    if file.sharpThreshold > 0 {
                        HStack(spacing: 0) {
                            Spacer()
                                .frame(width: geo.size.width * CGFloat(min(file.sharpThreshold, 1.0)))
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.25))
                                .frame(height: 28)
                        }
                    }

                    // Acceptable threshold line
                    if file.acceptableThreshold > 0 {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2, height: 36)
                            .offset(x: geo.size.width * CGFloat(file.acceptableThreshold) - 1)
                    }

                    // Sharp threshold line
                    if file.sharpThreshold > 0 {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 2, height: 36)
                            .offset(x: geo.size.width * CGFloat(file.sharpThreshold) - 1)
                    }

                    // Score needle — primary (the rating score)
                    if file.focusScore > 0 {
                        ZStack {
                            Circle()
                                .fill(Color(file.focusStatus.color))
                                .frame(width: 20, height: 20)
                            Circle()
                                .fill(.white)
                                .frame(width: 8, height: 8)
                        }
                        .offset(x: geo.size.width * CGFloat(min(file.focusScore, 1.0)) - 10,
                                y: 4)
                    }

                    // Second needle — AF point raw score (shown whenever dual scores are available)
                    if let afRaw = file.afPointRawScore, afRaw > 0 {
                        ZStack {
                            Diamond()
                                .fill(Color.cyan.opacity(0.85))
                                .frame(width: 16, height: 16)
                            Diamond()
                                .fill(.white)
                                .frame(width: 6, height: 6)
                        }
                        .offset(x: geo.size.width * CGFloat(min(afRaw, 1.0)) - 8,
                                y: -16)
                    }
                }
            }
            .frame(height: 36)

            HStack {
                Text("0%").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if file.acceptableThreshold > 0 {
                    Text("Acceptable \(Int(file.acceptableThreshold * 100))%")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if file.sharpThreshold > 0 {
                    Text("Sharp \(Int(file.sharpThreshold * 100))%")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Text("100%").font(.caption2).foregroundStyle(.secondary)
            }

            // Dual-score legend — shown whenever both AF point and body scores are available
            if file.afPointRawScore != nil {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(file.focusStatus.color)).frame(width: 10, height: 10)
                        Text("Rating score").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Diamond().fill(Color.cyan.opacity(0.85)).frame(width: 10, height: 10)
                        Text("AF point raw score").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if file.sharpThreshold > 0 {
                let gap = file.focusScore - file.sharpThreshold
                if gap < 0 {
                    Text("Score is \(String(format: "%.1f", abs(gap) * 100)) points below the Sharp threshold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Score clears the Sharp threshold by \(String(format: "%.1f", gap * 100)) points.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - Exposure Section

private struct ExposureSection: View {
    let exposure: ExposureAssessment
    /// Verdict computed with the user's configured thresholds, overriding the
    /// hardcoded ExposureAssessment.verdict so the diagnostic never disagrees
    /// with the grid filters and outcome actions.
    var verdictOverride: (label: String, color: Color)? = nil

    var body: some View {
        DiagSection(title: "Exposure", icon: "sun.max") {

            // Overall verdict — user thresholds when available
            DiagRow("Verdict",
                    value: verdictOverride?.label ?? exposure.summaryLabel,
                    highlight: verdictOverride?.color ?? Color(exposure.verdictColor),
                    bold: true)

            // Whole-image signals
            DiagRow("Mean luminance",
                    value: pct(exposure.meanLuminance),
                    detail: "0% = black, 100% = white. 30–70% is typical.",
                    highlight: luminanceColor(exposure.meanLuminance))

            DiagRow("Highlight clipping",
                    value: pct(exposure.highlightClipFraction),
                    detail: "% of pixels blown to white. Above 2% loses detail.",
                    highlight: exposure.highlightClipFraction > 0.02 ? .red
                             : exposure.highlightClipFraction > 0.005 ? .orange
                             : .green)

            DiagRow("Shadow clipping",
                    value: pct(exposure.shadowClipFraction),
                    detail: "% of pixels blocked to black.",
                    highlight: exposure.shadowClipFraction > 0.05 ? .orange : .primary)

            // Subject-specific signals
            if let sl = exposure.subjectMeanLuminance {
                DiagRow("Subject luminance",
                        value: pct(sl),
                        detail: "Mean brightness inside the subject bounding box.",
                        highlight: luminanceColor(sl))
            }
            if let sh = exposure.subjectHighlightClipFraction {
                DiagRow("Subject highlights",
                        value: pct(sh),
                        detail: "Blown pixels inside the subject area.",
                        highlight: sh > 0.02 ? .red : sh > 0.005 ? .orange : .green)
            }
        }
    }

    private func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    private func luminanceColor(_ lum: Double) -> Color {
        if lum < 0.15 { return .blue   }  // underexposed
        if lum > 0.80 { return .red    }  // overexposed
        return .green
    }
}

// MARK: - Reusable section container

private struct DiagSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground)))
        }
    }
}

// MARK: - Single diagnostic row

private struct DiagRow: View {
    let label: String
    let value: String
    var detail: String? = nil
    var highlight: Color = .primary
    var bold: Bool = false

    init(_ label: String, value: String, detail: String? = nil,
         highlight: Color = .primary, bold: Bool = false) {
        self.label     = label
        self.value     = value
        self.detail    = detail
        self.highlight = highlight
        self.bold      = bold
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(value)
                    .font(bold ? .subheadline.weight(.bold).monospacedDigit()
                               : .subheadline.monospacedDigit())
                    .foregroundStyle(highlight)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.leading, 14)
        }
    }
}

// MARK: - Diamond shape (used as second needle on the score scale for Case 5 AF point score)

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to:    CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}
