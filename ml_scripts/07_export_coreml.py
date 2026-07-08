"""
07_export_coreml.py — Export best.pt to CoreML with correct input normalisation,
then VERIFY the exported model matches the PyTorch model before deployment.

WHY THIS SCRIPT EXISTS:
    Ultralytics' YOLO.export(format="coreml") produced an .mlpackage that omitted
    the /255 input normalisation. YOLO classification models expect pixels scaled
    to 0-1, but the exported CoreML image input received raw 0-255 values from
    Vision. The ~255x oversized input saturated the network, producing near-
    uniform ~0.5% confidence across all 245 classes on-device — while the same
    weights scored 0.94-1.00 in PyTorch. Symptom: no species ever cleared the
    app's confidence threshold, so zero detections displayed.

WHAT THIS DOES:
    1. Loads best.pt (newest UKWildlife* run, or --weights PATH).
    2. Exports to CoreML with scale = 1/255 baked into the image input, so Vision's
       0-255 pixels are normalised to 0-1 inside the model.
    3. VERIFIES: runs the same N val images through both the .pt and the exported
       .mlpackage and compares top-1. Exits non-zero if any disagree — so a broken
       export is caught here, not in Xcode.
    4. On success, copies the verified .mlpackage to ~/Desktop/UKWildlife.mlpackage.

Requires: coremltools >= 8, ultralytics, Pillow, numpy.
Usage:
    /opt/homebrew/bin/python3.11 07_export_coreml.py
    /opt/homebrew/bin/python3.11 07_export_coreml.py --weights /path/to/best.pt
    /opt/homebrew/bin/python3.11 07_export_coreml.py --verify-count 8
"""

from pathlib import Path
import argparse
import shutil
import sys

IMAGE_SIZE   = 224
OUTPUT_NAME  = "UKWildlife"
TRAIN_RUNS   = Path.home() / "Desktop" / "training_runs"
DATASET_VAL  = Path("/Users/Shared/uk_wildlife_dataset/images/val")
DESKTOP_DEST = Path.home() / "Desktop" / f"{OUTPUT_NAME}.mlpackage"


# ── Locate newest best.pt ─────────────────────────────────────────────────────

def find_latest_best() -> Path | None:
    if not TRAIN_RUNS.is_dir():
        return None
    candidates = sorted(
        TRAIN_RUNS.glob(f"{OUTPUT_NAME}*/weights/best.pt"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


# ── Export with normalisation ────────────────────────────────────────────────

def export_with_scale(weights: Path) -> Path:
    """
    Export best.pt to CoreML. Ultralytics bakes the model graph; we then ensure
    the image input carries scale = 1/255 via coremltools. Returns the path to the
    corrected .mlpackage (written alongside best.pt as best.mlpackage).
    """
    from ultralytics import YOLO
    import coremltools as ct

    model = YOLO(str(weights))

    # Ultralytics export first (produces weights/best.mlpackage next to best.pt).
    print("Exporting via Ultralytics...")
    exported = model.export(format="coreml", imgsz=IMAGE_SIZE, half=False)
    exported = Path(exported)
    print(f"  Ultralytics export: {exported}")

    # Load spec and check/patch the image input scale.
    print("Checking input normalisation in exported spec...")
    m = ct.models.MLModel(str(exported))
    spec = m.get_spec()

    img_inputs = [i for i in spec.description.input
                  if i.type.WhichOneof("Type") == "imageType"]
    if not img_inputs:
        print("  ⚠️  No image input found in spec — cannot patch scale. Aborting.")
        sys.exit(2)

    # For mlProgram models, the scale lives in the model's preprocessing. The most
    # robust cross-version approach is to re-export using coremltools' ImageType
    # with a scale, driven from the traced torch model. Ultralytics doesn't expose
    # that directly, so we instead re-wrap: if the Ultralytics export already
    # applied scale, verification will pass; if not, we rebuild input scaling here.
    #
    # coremltools >= 7 exposes ct.models. MLModel spec image preprocessing for
    # neuralnetwork; for mlProgram we set scale via the conversion. Because the
    # Ultralytics graph normalises internally in some versions but not others, the
    # decisive check is the verification step below. We first TRY a scale-patched
    # rebuild; if the API isn't available, we fall back to the raw export and let
    # verification decide.
    patched = exported  # default: use Ultralytics export as-is

    try:
        # Attempt a clean re-conversion from the traced model WITH scale.
        # This path is the reliable fix when Ultralytics omitted /255.
        import torch
        from ultralytics.nn.autobackend import AutoBackend  # noqa: F401

        pt = YOLO(str(weights)).model.eval()
        example = torch.rand(1, 3, IMAGE_SIZE, IMAGE_SIZE)
        traced = torch.jit.trace(pt, example, strict=False)

        # Class labels in index order from the model.
        names = pt.names if hasattr(pt, "names") else None
        class_labels = [names[i] for i in range(len(names))] if names else None

        mlmodel = ct.convert(
            traced,
            inputs=[ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                scale=1/255.0,          # ← the fix: normalise 0-255 → 0-1
                bias=[0, 0, 0],
                color_layout=ct.colorlayout.RGB,
            )],
            classifier_config=ct.ClassifierConfig(class_labels) if class_labels else None,
            minimum_deployment_target=ct.target.iOS16,
            convert_to="mlprogram",
        )
        patched = exported.with_name("best_scaled.mlpackage")
        if patched.exists():
            shutil.rmtree(patched)
        mlmodel.save(str(patched))
        print(f"  Re-converted with scale=1/255: {patched}")
    except Exception as e:
        print(f"  ⚠️  Scale re-conversion unavailable ({type(e).__name__}: {e})")
        print(f"      Falling back to Ultralytics export; verification will decide.")
        patched = exported

    return patched


# ── Verify .pt vs .mlpackage agree ────────────────────────────────────────────

def verify(weights: Path, mlpackage: Path, n: int) -> bool:
    from ultralytics import YOLO
    import coremltools as ct
    from PIL import Image
    import numpy as np

    if not DATASET_VAL.is_dir():
        print(f"  ⚠️  Val dir not found for verification: {DATASET_VAL}")
        print(f"      Skipping verification — DEPLOY AT YOUR OWN RISK.")
        return False

    # Gather n images from n distinct classes.
    samples = []
    for cls in sorted(DATASET_VAL.iterdir()):
        if not cls.is_dir():
            continue
        f = next((p for p in cls.iterdir()
                  if p.suffix.lower() in (".jpg", ".jpeg", ".png")), None)
        if f:
            samples.append((cls.name, f))
        if len(samples) >= n:
            break

    if not samples:
        print("  ⚠️  No verification images found.")
        return False

    pt = YOLO(str(weights))
    ml = ct.models.MLModel(str(mlpackage))

    # Determine the ML model's class-prob output name.
    spec = ml.get_spec()
    prob_out = None
    for o in spec.description.output:
        if o.type.WhichOneof("Type") == "dictionaryType":
            prob_out = o.name
            break

    print(f"\n── Verification ({len(samples)} images) ─────────────────────────")
    agree = 0
    for true_cls, f in samples:
        # PyTorch top-1
        r = pt.predict(str(f), verbose=False)[0]
        pt_top = r.names[r.probs.top1]

        # CoreML top-1
        img = Image.open(f).convert("RGB").resize((IMAGE_SIZE, IMAGE_SIZE))
        out = ml.predict({"image": img})
        if prob_out and prob_out in out:
            probs = out[prob_out]
            ml_top = max(probs, key=probs.get)
        else:
            # Fall back to the declared classLabel output.
            ml_top = out.get("classLabel", "<unknown>")

        ok = (pt_top == ml_top)
        agree += int(ok)
        mark = "✅" if ok else "❌"
        print(f"  {mark} true={true_cls:<26} pt={pt_top:<24} coreml={ml_top}")

    passed = (agree == len(samples))
    print(f"\n  {agree}/{len(samples)} agree — "
          f"{'PASS' if passed else 'FAIL'}")
    return passed


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Export + verify UKWildlife CoreML model.")
    ap.add_argument("--weights", type=str, default=None,
                    help="path to best.pt (default: newest UKWildlife* run)")
    ap.add_argument("--verify-count", type=int, default=5,
                    help="number of distinct-class images to verify (default 5)")
    args = ap.parse_args()

    weights = Path(args.weights) if args.weights else find_latest_best()
    if not weights or not weights.exists():
        print(f"ERROR: best.pt not found "
              f"({'given path' if args.weights else 'no UKWildlife* run'}).")
        sys.exit(1)
    print(f"Weights: {weights}")

    mlpackage = export_with_scale(weights)

    if not verify(weights, mlpackage, args.verify_count):
        print("\n❌ Verification FAILED — not deploying. The exported model does "
              "not match the PyTorch model. Do NOT drag this into Xcode.")
        print("   Investigate before retrying (normalisation / class order).")
        sys.exit(3)

    # Deploy: copy verified package to Desktop.
    if DESKTOP_DEST.exists():
        shutil.rmtree(DESKTOP_DEST)
    shutil.copytree(mlpackage, DESKTOP_DEST)
    print(f"\n✅ Verified export copied to: {DESKTOP_DEST}")
    print(f"""
── Deploy in Xcode ──────────────────────────────────────────
1. Remove the old UKWildlife.mlpackage from the project navigator
   (right-click → Delete → Move to Trash).
2. Drag {DESKTOP_DEST.name} from ~/Desktop into the navigator.
3. Tick 'Copy items if needed' → target: RawFileBrowser.
4. Revert the diagnostic computeUnits line in YOLODetector.swift back
   to .cpuAndNeuralEngine, remove the 🔍 diagnostic prints, build & run.
""")


if __name__ == "__main__":
    main()
