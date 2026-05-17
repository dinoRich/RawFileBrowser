import SwiftUI

// MARK: - SettingsView
//
// A modal settings page presented as a sheet.
// Shows:
//   1. A sharpening slider (controls unsharp mask intensity pre-analysis)
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

                // ── Section 1: Sharpening ─────────────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sharpening Strength")
                                .font(.body)
                            Spacer()
                            Text(String(format: "%.2f", settings.sharpenIntensity))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $settings.sharpenIntensity, in: 0...1, step: 0.05)
                            .tint(.accentColor)

                        Text("Applied to each image crop before focus scoring. Higher values compensate for heavy JPEG compression but may inflate scores on blurry images. 0 = off, 0.4 = default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Pre-Analysis Sharpening")
                }

                // ── Section 2: Species ID confidence threshold ────────────────
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Minimum Confidence")
                                .font(.body)
                            Spacer()
                            Text("\(Int(settings.speciesConfidenceThreshold * 100))%")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $settings.speciesConfidenceThreshold, in: 0...1, step: 0.05)
                            .tint(.accentColor)

                        Text("Species identifications below this confidence level will be hidden and excluded from XMP files. The detection still runs — only the display is filtered. Default is 50%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Species ID Threshold")
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
