{\rtf1\ansi\ansicpg1252\cocoartf2868
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fnil\fcharset0 .AppleSystemUIFontMonospaced-Regular;}
{\colortbl;\red255\green255\blue255;\red15\green15\blue15;\red255\green255\blue255;}
{\*\expandedcolortbl;;\cssrgb\c7059\c7059\c7059;\cssrgb\c100000\c100000\c100000;}
\paperw11900\paperh16840\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\deftab720
\pard\pardeftab720\partightenfactor0

\f0\fs24 \cf2 \cb3 \expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 # RawFileBrowser \'97 Project Brief\
\
\pard\pardeftab720\partightenfactor0
\cf2 ## Rules for Claude\
\
Before proposing any code change, Claude MUST:\
1. Use the `view` tool to read the full source of every function being modified\
2. Use the `view` tool to read every function that the modified function calls\
3. Only then propose changes \'97 never from memory or summaries\
\
Specific mistakes to avoid:\
- YOLODetector: `isClassificationModel = true` means YOLO provides species labels only,\
  NO spatial location. All subject localisation comes from Apple Vision APIs.\
- Subject overlap uses contour point-in-polygon testing (contourContainsPoint), NOT\
  bounding box intersection \'97 except as a fallback when no contour is available.\
\
## What it is\
\pard\pardeftab720\partightenfactor0
\cf2 An iOS app (SwiftUI, iOS 16+) for browsing and culling RAW photo files directly\
from SD cards connected to iPhone via USB-C or Lightning adapter.\
\
## Target device\
- iPhone 15 (iOS 26.4)\
- Canon EOS R7 shooting CR3 files\
- SD card connected via USB-C adapter\
\
## Bundle ID\
com.davidrichards.rawfilebrowser\
\
## Build setup\
- Project: ~/Desktop/RawFileBrowser/RawFileBrowser.xcodeproj\
- Source files: ~/Desktop/RawFileBrowser/RawFileBrowser/\
- Bundle (script + Swift files): ~/Desktop/RawFileBrowser_Bundle/\
- Rebuild script: chmod +x ~/Desktop/RawFileBrowser_Bundle/create_rawfilebrowser.sh\
                  ~/Desktop/RawFileBrowser_Bundle/create_rawfilebrowser.sh\
\
---\
\
## Features implemented\
\
### Grid View\
- 2-column thumbnail grid (3 on iPad)\
- Sort and filter by focus status\
- Batch focus analysis with progress indicator\
- Batch XMP sidecar writing for species keywords\
- Tag icon appears when species detected\
\
### Detail View  \
- Full-screen RAW image display (embedded JPEG fallback for unsupported cameras)\
- Pinch to zoom + drag to pan with clamped offset (no black bars)\
- Double-tap to zoom 3x / reset\
- Analysis region overlay (viewfinder icon toggle)\
- Canon AF point overlay (scope icon toggle) \'97 green=in focus, white=other\
- Focus analysis on demand (wand icon)\
- XMP write button (tag icon, fills green when written)\
- Metadata sheet with searchable EXIF data\
\
### Focus Analysis\
- YOLOv8 CoreML model for subject detection (optional \'97 app works without it)\
- Vision framework: VNDetectAnimalBodyPoseRequest, VNRecognizeAnimalsRequest\
- Laplacian variance sharpness scoring\
- Per-region thresholds (eyes/head/body/full image)\
- Blur type detection (defocus vs motion blur)\
- FocusStatus: unanalyzed / sharp / slightlyBlurry / blurry / rejected\
\
### Canon AF Point Parsing\
- Reads CMT3 box from CR3 ISOBMFF container (bypasses ImageIO limitations)\
- Tag 0x0026 (AFInfo) inside Canon Makernote TIFF IFD\
- R7 layout detection: 2-word prefix (AFInfoSize + unknown) before NumAFPoints\
- Coordinate conversion: centre-relative pixels \uc0\u8594  normalised 0-1 top-left\
- Used for both overlay display and focus analysis region\
\
### XMP Sidecar Writing\
- Writes filename.xmp alongside RAW file (non-destructive)\
- dc:subject (flat keyword) + lr:hierarchicalSubject (hierarchical)\
- Species label only \'97 no ratings or other metadata\
- User-initiated only (never automatic)\
- Lightroom reads via Metadata \uc0\u8594  Read Metadata from Files\
\
---\
\
## Key technical facts\
\
### Canon R7 CR3 AF data structure\
From exiftool on _16A4847.CR3:\
- AF Info Size: 5472 (byte count, R7-specific prefix word)\
- Unknown word: 13 (second prefix word, R7-specific)  \
- Num AF Points: 651\
- Valid AF Points: 1\
- AF Image Width: 6960 (equals full sensor \'97 no scaling needed)\
- AF Image Height: 4640\
- AF Area X Positions: -121 (centre-relative, first point only)\
- AF Area Y Positions: 405\
- AF Area Widths: 163\
- AF Area Heights: 163\
- AF Points In Focus: 0 (bitmask \'97 bit 0 = point 0 in focus)\
\
### R7 vs standard Canon layout\
Standard: [0]=NumAFPoints [1]=ValidAFPoints [2]=ImgW [3]=ImgH [4]=AFImgW [5]=AFImgH\
R7:       [0]=AFInfoSize  [1]=unknown       [2]=NumAFPoints [3]=ValidAFPoints\
          [4]=ImgW [5]=ImgH [6]=AFImgW [7]=AFImgH\
Detection: if val[0] > 1000 && val[2] < 1000 && val[3] <= val[2] \uc0\u8594  offset = 2\
\
### ImageIO limitation\
Apple's ImageIO on iOS only exposes 6 cosmetic fields from Canon Makernote\
(\{MakerCanon\}: ColorSpace, FirmwareVersion, ImageType, LensModel, ModelID, OwnerName).\
AF data must be parsed directly from the raw CR3 binary.\
\
---\
\
## Files\
\
| File | Purpose |\
|------|---------|\
| RAWFileBrowserApp.swift | App entry point |\
| ContentView.swift | Root view \'97 grid or prompt |\
| SDCardManager.swift | @MainActor ObservableObject, RAWFile model |\
| SDCardPromptView.swift | Onboarding / SD card picker |\
| DocumentPickerHelper.swift | UIDocumentPickerViewController wrapper |\
| RAWImageLoader.swift | 4-stage CR3 loading with JPEG fallback |\
| RAWFileGridView.swift | 2-column grid with toolbar |\
| RAWFileThumbnailCard.swift | Thumbnail with focus badge |\
| RAWFileDetailView.swift | Full-screen viewer, pan/zoom, overlays |\
| AnalysisRegionOverlay.swift | Focus analysis region overlay |\
| FocusAnalyzer.swift | Laplacian + Vision focus analysis |\
| YOLODetector.swift | CoreML YOLOv8 wrapper |\
| CanonMakernoteParser.swift | CR3 CMT3 box AF point parser |\
| CanonMakernoteDiagnostic.swift | Debug tool \'97 remove when AF confirmed working |\
| XMPSidecarWriter.swift | Non-destructive XMP sidecar writer |\
\
---\
\
## Pending / in progress\
- Canon AF point overlay: parser finds CMT3 and tag 0x0026, offset=2 fix applied,\
  awaiting confirmation that offset=2 produces correct numAFPoints=651\
- ML species model: training scripts written, not yet trained or integrated\
- Metadata detail view: needs redesign to match structured card layout (reference provided)\
- CanonMakernoteDiagnostic.swift: remove once AF points confirmed working}