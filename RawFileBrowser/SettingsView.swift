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

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Session Window")
                                .font(.body)
                            Spacer()
                            Text("\(settings.sessionWindowMinutes) min")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(settings.sessionWindowMinutes) },
                                set: { settings.sessionWindowMinutes = Int($0.rounded()) }
                            ),
                            in: 5...120, step: 5
                        )
                        .tint(.accentColor)

                        Text("Maximum time between two photos for them to be eligible for similar grouping. Prevents photos from different subjects shot in the same session being incorrectly grouped. Default is 30 minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Colour Similarity")
                                .font(.body)
                            Spacer()
                            Text(String(format: "%.2f", settings.colourSimilarityThreshold))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $settings.colourSimilarityThreshold,
                            in: 0.1...1.0, step: 0.05
                        )
                        .tint(.accentColor)

                        Text("Maximum colour histogram distance for similar grouping. Lower = stricter colour matching. Near-grey scenes are unaffected. Default is 0.45. Re-run Find Similar after changing.")
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
                    OutcomeRow(
                        label: "AF Missed Subject",
                        icon: "scope",
                        iconColor: .orange,
                        action: $settings.afMissedSubjectAction
                    )
                    OutcomeRow(
                        label: "No Subject Detected",
                        icon: "questionmark.circle",
                        iconColor: .gray,
                        action: $settings.noSubjectDetectedAction
                    )
                    OutcomeRow(
                        label: "Motion Blur",
                        icon: "wind",
                        iconColor: .teal,
                        action: $settings.motionBlurAction
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
                    Text("Applied on top of the focus status action. AF Missed Subject fires when Canon AF data shows the camera focused away from the detected subject. Motion Blur is separate from defocus — configure to taste if you shoot panning shots. Exposure flags use the subject region where available. Re-run analysis after changing.")
                }

                // ── Section 6: Composition auto-actions ──────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        OutcomeRow(
                            label: "Subject Too Small",
                            icon: "arrow.down.right.and.arrow.up.left",
                            iconColor: .indigo,
                            action: $settings.subjectTooSmallAction
                        )
                        ThresholdSliderRow(
                            label: "Minimum subject size",
                            detail: "% of image area — below this fires action",
                            color: .indigo,
                            value: $settings.minSubjectAreaThreshold,
                            range: 0.001...0.10,
                            formatAsPercent: true
                        )
                    }
                } header: {
                    Text("Composition Auto-Actions")
                } footer: {
                    Text("Subject Too Small fires when a subject was detected but occupies less than the threshold. No Subject Detected (above) fires when no subject was found at all. Both fire independently of focus status.")
                }

                // ── Section 7: Burst ranking ──────────────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        OutcomeRow(
                            label: "Burst Non-Winner",
                            icon: "photo.stack",
                            iconColor: .brown,
                            action: $settings.burstNonWinnerAction
                        )

                        HStack {
                            Text("Keep per burst")
                                .font(.subheadline)
                            Spacer()
                            Text(settings.burstKeepCount == 0 ? "Disabled" : "\(settings.burstKeepCount)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.burstKeepCount) },
                                set: { settings.burstKeepCount = Int($0.rounded()) }
                            ),
                            in: 0...10, step: 1
                        )
                        .tint(.brown)
                        Text("Set to 0 to disable burst non-winner actions entirely. Set to 1 to keep only the best photo per burst. The Burst Non-Winner action is applied to all photos outside the top-N after burst ranking runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Burst Ranking Weights")
                            .font(.subheadline.weight(.medium))
                        Text("Controls how the best photo in a burst is chosen. Weights are normalised automatically — you control the relative importance of each factor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ThresholdSliderRow(
                            label: "Sharpness",
                            detail: "Focus score contribution",
                            color: .green,
                            value: $settings.burstRankSharpnessWeight,
                            range: 0.0...1.0
                        )
                        ThresholdSliderRow(
                            label: "Exposure",
                            detail: "Well-exposed frames score higher",
                            color: .yellow,
                            value: $settings.burstRankExposureWeight,
                            range: 0.0...1.0
                        )
                        ThresholdSliderRow(
                            label: "Subject Size",
                            detail: "Larger subject in frame scores higher",
                            color: .indigo,
                            value: $settings.burstRankSubjectSizeWeight,
                            range: 0.0...1.0
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Burst Ranking")
                } footer: {
                    Text("Burst ranking runs automatically after analysis. Re-run analysis to apply updated weights to existing results.")
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
