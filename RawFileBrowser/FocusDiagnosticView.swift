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

                    // ── Sharpness numbers ────────────────────────────────────
                    DiagSection(title: "Sharpness Scores", icon: "waveform.path.ecg") {
                        DiagRow("Raw Laplacian score",
                                value: pct(file.rawSharpnessScore),
                                detail: "variance before size penalty",
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
            if file.focusStatus == .missedFocus { return "AF + Subject → Missed Focus" }
            return "AF + Subject → Score at AF point"
        case (true, false):  return "AF only → Score at AF point"
        case (false, true):  return "Subject only → Score at subject"
        case (false, false): return "No AF, no subject → Full image"
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

                    // Score needle
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
