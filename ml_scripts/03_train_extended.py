"""
03_train_extended.py — Train the extended ~245-species UKWildlife model from scratch.

WHY resume=False:
    Adding new species changes the classifier head output classes.
    YOLO cannot resume a checkpoint whose head dimensions differ from the current
    dataset. Setting resume=True would crash (mismatched weight shapes) or, worse,
    silently load incorrect weights. Always train from the base yolov8s-cls.pt
    pretrained weights when the class count changes.

WHY NOT to fine-tune from UKWildlife best.pt:
    Fine-tuning from the old weights would require replacing the head,
    which discards the classifier entirely — you'd only retain the backbone.
    Starting from yolov8s-cls.pt gives the same backbone benefit without the
    complexity, and avoids the de-training seen with 04_finetune_gbif.py.

Run AFTER 05_download_new_species.py has completed.
Requirements: /opt/homebrew/bin/python3.11 -m pip install ultralytics coremltools
"""

from pathlib import Path
from ultralytics import YOLO
import shutil

# ── Configuration ─────────────────────────────────────────────────────────────

DATASET_DIR = Path("/Users/Shared/uk_wildlife_dataset/images")
MODEL_SIZE  = "s"     # match original — yolov8s-cls
IMAGE_SIZE  = 224     # classification models use 224
EPOCHS      = 100     # max epochs — early stopping via patience
BATCH_SIZE  = 16      # reduce to 8 if memory errors on M4 Pro
OUTPUT_NAME = "UKWildlife"


# ── Sanity check — confirm class count before training ───────────────────────

def check_dataset(dataset_dir: Path) -> int:
    train_dir = dataset_dir / "train"
    if not train_dir.exists():
        print(f"ERROR: train directory not found: {train_dir}")
        return 0
    classes = [d for d in train_dir.iterdir() if d.is_dir()]
    return len(classes)


# ── Train ─────────────────────────────────────────────────────────────────────

def train() -> YOLO:
    n_classes = check_dataset(DATASET_DIR)
    if n_classes == 0:
        exit(1)

    print(f"Training YOLOv8{MODEL_SIZE}-cls on extended UK wildlife dataset...")
    print(f"  Classes:    {n_classes}")
    print(f"  Image size: {IMAGE_SIZE}px")
    print(f"  Epochs:     {EPOCHS} (max — early stopping at patience=20)")
    print(f"  Batch:      {BATCH_SIZE}")
    print(f"  resume:     False  ← required: class count changed, fresh run")

    if n_classes < 215:
        print(f"\n  ⚠️  WARNING: expected ~220+ classes, found {n_classes}.")
        print(f"  Check that 05_download_new_species.py completed without errors.")
        answer = input("  Continue anyway? [y/N]: ").strip().lower()
        if answer != "y":
            print("Aborted.")
            exit(0)

    # Start from ImageNet-pretrained yolov8s-cls weights (not a previous run).
    # resume=False is explicit and intentional — see module docstring.
    model = YOLO(f"yolov8{MODEL_SIZE}-cls.pt")

    results = model.train(
        data      = str(DATASET_DIR),
        epochs    = EPOCHS,
        imgsz     = IMAGE_SIZE,
        batch     = BATCH_SIZE,
        device    = "mps",
        patience  = 20,
        augment   = True,
        degrees   = 15,
        flipud    = 0.1,
        fliplr    = 0.5,
        mosaic    = 0.0,         # disable mosaic for classification
        workers   = 8,
        project   = str(Path.home() / "Desktop" / "training_runs"),
        name      = OUTPUT_NAME,
        resume    = False,      # ← must be False — class count changed (fresh run)
        verbose   = True,
    )

    top1 = results.results_dict.get("metrics/accuracy_top1", 0)
    top5 = results.results_dict.get("metrics/accuracy_top5", 0)

    print(f"\n✓ Training complete")
    print(f"  Top-1 accuracy: {top1:.1%}")
    print(f"  Top-5 accuracy: {top5:.1%}")

    return model


# ── Export to CoreML ──────────────────────────────────────────────────────────

def export_to_coreml(model: YOLO):
    print("\nExporting to CoreML...")

    export_path = model.export(
        format = "coreml",
        imgsz  = IMAGE_SIZE,
        half   = False,   # full precision — better accuracy on device
    )

    print(f"✓ CoreML model exported to: {export_path}")

    dest = Path.home() / "Desktop" / f"{OUTPUT_NAME}.mlpackage"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(export_path, dest)

    print(f"✓ Copied to: {dest}")
    print(f"""
── Next steps ──────────────────────────────────────────────
1. In Xcode, remove the existing UKWildlife.mlpackage from
   the project navigator (right-click → Delete → Move to Trash)
2. Drag {dest.name} from ~/Desktop into the project navigator
3. Tick 'Copy items if needed' → Add to target: RawFileBrowser
4. Build and run — no Swift changes needed (model name unchanged)

── If accuracy is lower than expected ───────────────────────
- Check download_summary via 05_download_new_species.py output
  for species with very few images (< 50) — these will drag
  down performance and may need manual augmentation or removal
- Re-run with EPOCHS = 150 if val accuracy is still climbing
  at epoch 100 (check training_runs/UKWildlife/results.png)
""")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not DATASET_DIR.exists():
        print(f"ERROR: Dataset not found at {DATASET_DIR}")
        print("Run 01_download_uk_data.py and 05_download_new_species.py first.")
        exit(1)

    model = train()
    export_to_coreml(model)
