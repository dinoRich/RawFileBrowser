import SwiftUI

// MARK: - SettingsView
//
// A modal settings page presented as a sheet.
// Shows:
//   1. Sharpness threshold sliders (Sharp / Acceptable cutpoints)
//   2. A species ID confidence threshold slider
//   3. Three rows — one per focus outcome — each letting the user choose:
//        • Pick flag (accept / reject / none)
//        • Star rating (1-5, or none)
//        • Colour label (red/yellow/green/blue/purple/none)

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {

                // ── Section 1: Sharpness thresholds ──────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("These control when a photo is rated Sharp (green), Slightly Blurry (orange), or Blurry (red). The score shown in diagnostics is 0–1; higher = sharper. Raise the Sharp threshold to be stricter; lower it to pass more photos. Re-run analysis after changing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ThresholdSliderRow(
                            label: "Sharp",
                            detail: "Score at or above this → green badge",
                            color: .green,
                            value: $settings.sharpThreshold,
                            range: 0.25...0.95
                        )

                        ThresholdSliderRow(
                            label: "Acceptable",
                            detail: "Score at or above this → orange; below → red",
                            color: .orange,
                            value: $settings.acceptableThreshold,
                            range: 0.10...0.70
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Sharpness Thresholds")
                } footer: {
                    Text("Acceptable must be lower than Sharp. Defaults: Sharp 0.62, Acceptable 0.32.")
                }

                // ── Section 2: Species ID confidence thresholds ──────────────
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Minimum confidence required to display a species ID, based on how much of the frame the subject occupies. Tighter thresholds for smaller subjects reduce confident misidentifications caused by background texture. Species identification runs as part of focus analysis.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        SpeciesThresholdRow(
                            label: "Tiny (0–1%)",
                            detail: "Subject is a distant speck",
                            value: $settings.speciesConfidenceTiny
                        )
                        SpeciesThresholdRow(
                            label: "Small (1–5%)",
                            detail: "Subject small in frame",
                            value: $settings.speciesConfidenceSmall
                        )
                        SpeciesThresholdRow(
                            label: "Medium (5–10%)",
                            detail: "Subject reasonably sized",
                            value: $settings.speciesConfidenceMedium
                        )
                        SpeciesThresholdRow(
                            label: "Large (10–25%)",
                            detail: "Subject prominent in frame",
                            value: $settings.speciesConfidenceLarge
                        )
                        SpeciesThresholdRow(
                            label: "Full (25%+)",
                            detail: "Subject fills the frame",
                            value: $settings.speciesConfidenceFull
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Species ID Thresholds")
                }

                // ── Section 3: Similar photo threshold ───────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Similarity Threshold")
                                .font(.body)
                            Spacer()
                            Text("\(settings.similarityThreshold) bits")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(settings.similarityThreshold) },
                                set: { settings.similarityThreshold = Int($0.rounded()) }
                            ),
                            in: 1...20, step: 1
                        )
                        .tint(.accentColor)

                        Text("Controls how different two photos can be and still be grouped as similar. Lower = stricter (only near-identical). Higher = looser (more photos grouped). Default is 10. Re-run Find Similar after changing this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Similar Photo Detection")
                }

                // ── Section 4: Focus outcome actions ─────────────────────
                Section {
                    OutcomeRow(
                        label: "Sharp",
                        icon: "checkmark.circle.fill",
                        iconColor: .green,
                        action: $settings.sharpAction
                    )
                    OutcomeRow(
                        label: "Slightly Blurry",
                        icon: "exclamationmark.circle.fill",
                        iconColor: .orange,
                        action: $settings.slightlyBlurAction
                    )
                    OutcomeRow(
                        label: "Blurry",
                        icon: "xmark.circle.fill",
                        iconColor: .red,
                        action: $settings.blurryAction
                    )
                } header: {
                    Text("Auto-Actions After Analysis")
                } footer: {
                    Text("These are applied automatically when focus analysis completes. You can still change individual photos manually afterwards. \"None\" means the app takes no action for that setting.")
                }

                // ── Section 5: Flag-based auto-actions ────────────────────
                Section {
                    OutcomeRow(
                        label: "Subject Clipped",
                        icon: "rectangle.and.arrow.up.right.and.arrow.down.left",
                        iconColor: .purple,
                        action: $settings.subjectClippedAction
                    )
                    OutcomeRow(
                        label: "Soft in Burst",
                        icon: "waveform.path.ecg",
                        iconColor: .cyan,
                        action: $settings.softInBurstAction
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        OutcomeRow(
                            label: "Overexposed",
                            icon: "sun.max.fill",
                            iconColor: .yellow,
                            action: $settings.overexposedAction
                        )
                        ThresholdSliderRow(
                            label: "Overexposure level",
                            detail: "% of subject pixels blown (\u{2265}250/255)",
                            color: .yellow,
                            value: $settings.overexposureThreshold,
                            range: 0.01...0.20,
                            formatAsPercent: true
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        OutcomeRow(
                            label: "Underexposed",
                            icon: "moon.fill",
                            iconColor: .blue,
                            action: $settings.underexposedAction
                        )
                        ThresholdSliderRow(
                            label: "Underexposure level",
                            detail: "% of subject pixels blocked (\u{2264}5/255)",
                            color: .blue,
                            value: $settings.underexposureThreshold,
                            range: 0.02...0.40,
                            formatAsPercent: true
                        )
                    }
                } header: {
                    Text("Flag-Based Auto-Actions")
                } footer: {
                    Text("Applied on top of the focus status action above. Subject Clipped fires when the detected subject touches the frame edge. Soft in Burst fires when a photo is significantly softer than its burst peers. Exposure flags use the subject region where available. Re-run analysis after changing exposure levels.")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - ThresholdSliderRow

private struct ThresholdSliderRow: View {
    let label:  String
    let detail: String
    let color:  Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    var formatAsPercent: Bool = false

    private var displayValue: String {
        formatAsPercent
            ? String(format: "%.0f%%", value * 100)
            : String(format: "%.2f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.subheadline.weight(.medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(displayValue)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: formatAsPercent ? 0.01 : 0.01).tint(color)
        }
    }
}

// MARK: - OutcomeRow
//
// One row in the settings list. Shows the focus-status label, then three
// inline pickers: pick flag, star rating, colour label.

private struct OutcomeRow: View {
    let label: String
    let icon: String
    let iconColor: Color
    @Binding var action: FocusOutcomeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Outcome label ─────────────────────────────────────────
            Label {
                Text(label).font(.headline)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }

            Divider()

            // ── Pick flag picker ──────────────────────────────────────
            PickerRow(title: "Flag") {
                Picker("Flag", selection: $action.pick) {
                    Text("None").tag(PickStatus.unpicked)
                    Label("Accept", systemImage: "flag.fill").tag(PickStatus.accepted)
                    Label("Reject", systemImage: "flag.fill").tag(PickStatus.rejected)
                }
                .pickerStyle(.segmented)
            }

            // ── Star rating picker ────────────────────────────────────
            PickerRow(title: "Stars") {
                StarPicker(selection: $action.stars)
            }

            // ── Colour label picker ───────────────────────────────────
            PickerRow(title: "Colour") {
                ColourPicker(selection: $action.colour)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - PickerRow
// A helper that places a title label above a picker control.

private struct PickerRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - StarPicker
// Tap a star to set the rating; tap the current rating to clear it.

private struct StarPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            // "None" option — a dash button
            Button {
                selection = 0
            } label: {
                Image(systemName: "minus.circle")
                    .font(.title3)
                    .foregroundStyle(selection == 0 ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            ForEach(1...5, id: \.self) { n in
                Button {
                    selection = (selection == n) ? 0 : n
                } label: {
                    Image(systemName: n <= selection ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(n <= selection ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - SpeciesThresholdRow

private struct SpeciesThresholdRow: View {
    let label: String
    let detail: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.subheadline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(value: $value, in: 0...1, step: 0.05)
                .tint(.accentColor)
        }
    }
}

// MARK: - ColourPicker
// Colour swatches. Tap a colour to select it; tap again or tap the "X" to clear.

private struct ColourPicker: View {
    @Binding var selection: LabelColour

    private let colours: [LabelColour] = [.red, .yellow, .green, .blue, .purple]

    var body: some View {
        HStack(spacing: 10) {
            // "None" swatch
            Button {
                selection = .none
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(90))
                }
                .overlay {
                    if selection == .none {
                        Circle().strokeBorder(Color.primary, lineWidth: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(colours, id: \.self) { colour in
                Button {
                    selection = (selection == colour) ? .none : colour
                } label: {
                    Circle()
                        .fill(colour.swiftUIColor ?? .clear)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if selection == colour {
                                Circle().strokeBorder(Color.primary, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
