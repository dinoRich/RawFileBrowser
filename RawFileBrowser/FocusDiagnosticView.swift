import SwiftUI

// MARK: - Focus Diagnostic Sheet
//
// Shows every intermediate value computed during focus analysis so you can
// see exactly why an image was accepted or rejected and tune the thresholds.
// Open it from the detail view toolbar (the "stethoscope" icon).

struct FocusDiagnosticView: View {
    let file: RAWFile

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
                        DiagRow("Subject detected",     value: file.detectedAnimalLabel != nil
                                                                || file.focusRegion == .humanEyes
                                                                || file.focusRegion == .humanFace
                                                                ? "Yes" : "No")
                        if let overlaps = file.afOverlapsSubject {
                            DiagRow("AF overlaps subject", value: overlaps ? "Yes ✓" : "No ✗",
                                    highlight: overlaps ? .green : .red)
                        }
                        DiagRow("Analysis branch",      value: branchDescription(file))
                        DiagRow("Scoring region",        value: file.focusRegion.rawValue)
                    }

                    // ── AF / Eye overlap ─────────────────────────────────────
                    if file.hadAFPoint {
                        DiagSection(title: "AF / Eye Overlap", icon: "eye") {
                            DiagRow("AF on subject",
                                    value: triStateLabel(file.afOverlapsSubject,
                                                         yes: "Yes ✓", no: "No ✗", unknown: "No subject"),
                                    highlight: triStateColor(file.afOverlapsSubject))

                            DiagRow("AF on eye",
                                    value: triStateLabel(file.afOnEye,
                                                         yes: "Yes ✓", no: "No ✗", unknown: "No eye detected"),
                                    highlight: triStateColor(file.afOnEye),
                                    bold: true)

                            DiagRow("Eye detected",
                                    value: file.afOnEye != nil ? "Yes" : "No",
                                    highlight: file.afOnEye != nil ? .primary : .secondary)
                        }

                        // Explanatory note below the section
                        AFEyeExplanationCard(afOnEye: file.afOnEye, hadAFPoint: file.hadAFPoint)
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
                            DiagRow("Detected species",  value: label)
                        }
                    }

                    // ── Threshold guide ──────────────────────────────────────
                    ThresholdGuideCard(file: file)

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
        switch (file.hadAFPoint, file.detectedAnimalLabel != nil || isHuman(file)) {
        case (true, true):
            switch file.focusStatus {
            case .missedFocus:        return "AF + Subject → Missed Focus (Case 3)"
            case .possibleMissedFocus: return "AF + Subject → Possible Missed Focus (Case 4)"
            default:                  return "AF + Subject → AF on Subject (Case 5)"
            }
        case (true, false):  return "AF only → Score at AF point"
        case (false, true):  return "Subject only → Score at subject body (Case 2)"
        case (false, false): return "No AF, no subject → Full image (Case 1)"
        }
    }

    private func ratingBasisColor(_ basis: FocusResult.RatingBasis) -> Color {
        switch basis {
        case .afPoint:         return .green
        case .subjectBody:     return .primary
        case .afPointDegraded: return .orange
        case .fullImage:       return .secondary
        case .missedFocus:     return .purple
        case .possibleMissed:  return .indigo
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

                    // Second needle — AF point raw score (degraded AF only)
                    if file.ratingBasis == .afPointDegraded,
                       let afRaw = file.afPointRawScore, afRaw > 0 {
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

            // Dual-score legend — only shown when AF was degraded and subject score was used instead
            if file.ratingBasis == .afPointDegraded, file.afPointRawScore != nil {
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

// MARK: - AF / Eye explanation card

private struct AFEyeExplanationCard: View {
    let afOnEye: Bool?
    let hadAFPoint: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(iconColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(iconColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var iconName: String {
        guard let v = afOnEye else { return "eye.slash" }
        return v ? "eye.circle.fill" : "eye.trianglebadge.exclamationmark"
    }

    private var iconColor: Color {
        guard let v = afOnEye else { return .secondary }
        return v ? .green : .orange
    }

    private var message: String {
        guard let v = afOnEye else {
            return "No eye was detected in this image, so it is not possible to determine whether the AF point covered the eye. This is normal for distant subjects, side-on angles, or non-animal photos."
        }
        if v {
            return "The camera's AF point overlapped the detected eye region. This is the best possible outcome — the lens was focused at the eye. The sharpness score above reflects how sharp that region actually is."
        } else {
            return "An eye was detected but the AF point did not cover it. The camera focused on a different part of the subject (body, background, or nearby object). The eye may still be acceptably sharp if the subject was at a similar distance, but check carefully at 100%."
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
