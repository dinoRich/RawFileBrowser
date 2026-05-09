# Settings Page — Implementation Guide

## Overview of what's being added

- **`AppSettings.swift`** — a new file that stores your preferences (persisted between app launches)
- **`SettingsView.swift`** — a new file: the settings UI screen
- **`RAWFileBrowserApp.swift`** — replace the existing file (adds AppSettings to the app)
- **`ContentView.swift`** — replace the existing file (adds the settings gear button)
- Four targeted edits to **`FocusAnalyzer.swift`** (thread sharpening setting through)
- Three targeted edits to **`SDCardManager.swift`** (thread settings through, apply outcome actions)

---

## Step 1 — Add the two new files

In Xcode, right-click your **RawFileBrowser** folder in the Project Navigator and choose **New File → Swift File** for each:

1. Name it **`AppSettings.swift`** — paste in the full contents from the provided `AppSettings.swift` output file.
2. Name it **`SettingsView.swift`** — paste in the full contents from the provided `SettingsView.swift` output file.

---

## Step 2 — Replace two existing files entirely

### RAWFileBrowserApp.swift
Open the file, select all (`Cmd+A`), delete, paste the provided `RAWFileBrowserApp.swift` content.

### ContentView.swift
Open the file, select all (`Cmd+A`), delete, paste the provided `ContentView.swift` content.

---

## Step 3 — Edit FocusAnalyzer.swift

Open `FocusAnalyzer.swift`. Make the following four changes in order.

### 3a — Add a parameter to `analyze(url:)`

Find this line (approximately line 180):
```swift
static func analyze(url: URL) async -> FocusResult {
```
Change it to:
```swift
static func analyze(url: URL, sharpenIntensity: Double = 0.4) async -> FocusResult {
```

### 3b — Pass the parameter into `route()`

A few lines below, find:
```swift
return route(cgImage: cgImage, afRect: afRect, subject: subject)
```
Change it to:
```swift
return route(cgImage: cgImage, afRect: afRect, subject: subject,
             sharpenIntensity: sharpenIntensity)
```

Then find the `route` function declaration:
```swift
private static func route(cgImage: CGImage,
                           afRect: CGRect?,
                           subject: SubjectResult) -> FocusResult {
```
Change it to:
```swift
private static func route(cgImage: CGImage,
                           afRect: CGRect?,
                           subject: SubjectResult,
                           sharpenIntensity: Double = 0.4) -> FocusResult {
```

> **Note:** You will also need to pass `sharpenIntensity: sharpenIntensity` wherever `route()` calls `rawLaplacian()` or `contourMaskedLaplacian()` (see 3c and 3d).

### 3c — Update `sharpenCrop` to accept intensity

Find the function (approximately line 413):
```swift
private static func sharpenCrop(_ image: CGImage) -> CGImage {
    let ciImage = CIImage(cgImage: image)
    let filter  = CIFilter(name: "CIUnsharpMask")!
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(1.0,     forKey: kCIInputRadiusKey)
    filter.setValue(0.4,     forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage else { return image }
    return ciContext.createCGImage(output, from: output.extent) ?? image
}
```
Replace the **entire function** with:
```swift
private static func sharpenCrop(_ image: CGImage, intensity: Double = 0.4) -> CGImage {
    guard intensity > 0 else { return image }
    let ciImage = CIImage(cgImage: image)
    let filter  = CIFilter(name: "CIUnsharpMask")!
    filter.setValue(ciImage,   forKey: kCIInputImageKey)
    filter.setValue(1.0,       forKey: kCIInputRadiusKey)
    filter.setValue(intensity, forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage else { return image }
    return ciContext.createCGImage(output, from: output.extent) ?? image
}
```

### 3d — Update `rawLaplacian` to accept and use the intensity

Find the `rawLaplacian` function signature:
```swift
private static func rawLaplacian(cgImage: CGImage) -> Double? {
```
Change to:
```swift
private static func rawLaplacian(cgImage: CGImage, sharpenIntensity: Double = 0.4) -> Double? {
```
Inside that function, find:
```swift
let sharpened = sharpenCrop(cgImage)
```
Change to:
```swift
let sharpened = sharpenCrop(cgImage, intensity: sharpenIntensity)
```

### 3e — Update `contourMaskedLaplacian` similarly

Find its signature:
```swift
private static func contourMaskedLaplacian(cgImage: CGImage,
                                           normRect: CGRect,
                                           contours: [[CGPoint]]) -> Double? {
```
Change to:
```swift
private static func contourMaskedLaplacian(cgImage: CGImage,
                                           normRect: CGRect,
                                           contours: [[CGPoint]],
                                           sharpenIntensity: Double = 0.4) -> Double? {
```
Inside that function there are **two** `sharpenCrop` / `rawLaplacian` lines. Find:
```swift
let sharpened = sharpenCrop(cropped)
```
Change to:
```swift
let sharpened = sharpenCrop(cropped, intensity: sharpenIntensity)
```
And find both fallback returns:
```swift
return rawLaplacian(cgImage: cropped)
```
Change each one to:
```swift
return rawLaplacian(cgImage: cropped, sharpenIntensity: sharpenIntensity)
```

> **How to find these quickly:** Use Xcode's Find in File (`Cmd+F`) and search for `sharpenCrop` and `rawLaplacian` to locate every occurrence.

---

## Step 4 — Edit SDCardManager.swift

### 4a — Add the helper function

Scroll to the very bottom of `SDCardManager.swift`, just before the closing `}` of the class. Add this new function:

```swift
private func applyOutcomeAction(_ action: FocusOutcomeAction, to idx: Int) {
    if action.pick != .unpicked {
        rawFiles[idx].pickStatus = action.pick
    }
    if action.stars > 0 {
        rawFiles[idx].starRating = action.stars
    }
    if action.colour != .none {
        rawFiles[idx].labelColour = action.colour
    }
}
```

### 4b — Update `analyzeAllFocus`

Find the function signature:
```swift
func analyzeAllFocus() async {
```
Change to:
```swift
func analyzeAllFocus(settings: AppSettings) async {
```

Inside that function, find where the task calls the analyser:
```swift
let result = await FocusAnalyzer.analyze(url: url)
```
Change to (the capture of `sharpen` must happen **before** `addTask` — just add the `let sharpen` line immediately before the existing `group.addTask {` line):
```swift
let sharpen = settings.sharpenIntensity
group.addTask {
    let result = await FocusAnalyzer.analyze(url: url, sharpenIntensity: sharpen)
    return (i, result)
}
```
> The `let sharpen` must be **outside** the `group.addTask { }` closure because `settings` is a `@MainActor` object and cannot be accessed from a background task.

Then find:
```swift
if !rawFiles[i].pickIsOverridden {
    rawFiles[i].pickStatus = result.status.isRejected ? .rejected : .accepted
}
```
Replace with:
```swift
if !rawFiles[i].pickIsOverridden {
    applyOutcomeAction(settings.action(for: result.status), to: i)
}
```

### 4c — Update `analyzeFocus(for:)`

Find:
```swift
func analyzeFocus(for file: RAWFile) async {
```
Change to:
```swift
func analyzeFocus(for file: RAWFile, settings: AppSettings) async {
```

Find:
```swift
let result = await FocusAnalyzer.analyze(url: file.url)
```
Change to:
```swift
let result = await FocusAnalyzer.analyze(url: file.url,
                                          sharpenIntensity: settings.sharpenIntensity)
```

Find:
```swift
if !rawFiles[idx].pickIsOverridden {
    rawFiles[idx].pickStatus = result.status.isRejected ? .rejected : .accepted
}
```
Replace with:
```swift
if !rawFiles[idx].pickIsOverridden {
    applyOutcomeAction(settings.action(for: result.status), to: idx)
}
```

---

## Step 5 — Update the two call sites that trigger analysis

### RAWFileGridView.swift — line ~284

Find:
```swift
Task { await manager.analyzeAllFocus() }
```
Change to:
```swift
Task { await manager.analyzeAllFocus(settings: settings) }
```

Also add `@EnvironmentObject var settings: AppSettings` near the top of the struct, alongside the existing `@ObservedObject var manager`:
```swift
@EnvironmentObject var settings: AppSettings
```

### RAWFileDetailView.swift — line ~192

Find:
```swift
Task { await manager.analyzeFocus(for: file) }
```
Change to:
```swift
Task { await manager.analyzeFocus(for: file, settings: settings) }
```

Also add `@EnvironmentObject var settings: AppSettings` near the top of that struct's properties.

---

## Step 6 — Build and test

Press `Cmd+B` to build. Xcode will show errors for any missed change — they will say something like *"extra argument in call"* or *"missing argument"*, pointing you to the exact line.

Once it builds cleanly, run the app. Tap the **gear icon** (top-left of the main screen) to open Settings. You should see:
- A **sharpening slider** (0–1, default 0.4)
- Three **outcome sections** (Sharp / Slightly Blurry / Blurry), each with flag, star and colour pickers

Settings are saved automatically — they persist after you close and reopen the app.
