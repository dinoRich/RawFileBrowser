"""
06_fix_val_set.py — One-time, reversible val-set cleanup for the UKWildlife dataset.

Fixes two issues flagged during training:
  (3) Orphan val classes: Yellow-necked_Mouse and Yellowhammer exist in val but
      not in train, so they can never be scored. Ultralytics auto-skips them
      (360 samples) with a warning. This moves them out cleanly.
  (4) Oversized val: val (~67k) is nearly as large as train (~69k), causing
      ~22h validation per epoch. A proper held-out split is ~10-15% of train.
      This keeps a random VAL_FRACTION of each aligned class (floor VAL_FLOOR),
      moving the surplus to backup.

REVERSIBLE: nothing is deleted. Everything moves to _val_backup/ on the SAME
volume (instant APFS move). Use --restore to put it all back.

SAFE BY DEFAULT: dry-run unless --apply is passed. Dry-run prints per-class
before/after counts and dataset totals, and performs no filesystem changes.

DETERMINISTIC: fixed RANDOM_SEED, so the retained subset is reproducible.

Usage:
    /opt/homebrew/bin/python3.11 06_fix_val_set.py            # dry-run (default)
    /opt/homebrew/bin/python3.11 06_fix_val_set.py --apply    # perform moves
    /opt/homebrew/bin/python3.11 06_fix_val_set.py --restore  # undo (from backup)
"""

from pathlib import Path
import argparse
import random
import shutil
import sys

# ── Configuration ─────────────────────────────────────────────────────────────

DATASET_ROOT = Path("/Users/Shared/uk_wildlife_dataset")
IMAGES_DIR   = DATASET_ROOT / "images"
TRAIN_DIR    = IMAGES_DIR / "train"
VAL_DIR      = IMAGES_DIR / "val"
BACKUP_DIR   = DATASET_ROOT / "_val_backup"      # same volume → instant moves

VAL_FRACTION = 0.15    # keep 15% of each class's current val images
VAL_FLOOR    = 20      # ...but never fewer than this (if class has that many)
RANDOM_SEED  = 42      # reproducible subset selection

IMG_EXTS = (".jpg", ".jpeg", ".png")


# ── Helpers ───────────────────────────────────────────────────────────────────

def _images_in(d: Path) -> list:
    return [f for f in d.iterdir() if f.suffix.lower() in IMG_EXTS] if d.is_dir() else []


def _validate_paths() -> bool:
    ok = True
    if not TRAIN_DIR.is_dir():
        print(f"ERROR: train dir not found: {TRAIN_DIR}"); ok = False
    if not VAL_DIR.is_dir():
        print(f"ERROR: val dir not found: {VAL_DIR}"); ok = False
    return ok


def _class_sets():
    train_classes = {d.name for d in TRAIN_DIR.iterdir() if d.is_dir()}
    val_classes   = {d.name for d in VAL_DIR.iterdir() if d.is_dir()}
    return train_classes, val_classes


# ── Restore ───────────────────────────────────────────────────────────────────

def restore() -> int:
    if not BACKUP_DIR.is_dir():
        print(f"Nothing to restore — no backup at {BACKUP_DIR}")
        return 1

    restored = 0
    # Orphan classes were backed up as whole folders under _val_backup/_orphans/
    orphans = BACKUP_DIR / "_orphans"
    if orphans.is_dir():
        for cls_dir in orphans.iterdir():
            if cls_dir.is_dir():
                dst = VAL_DIR / cls_dir.name
                dst.parent.mkdir(parents=True, exist_ok=True)
                if dst.exists():
                    print(f"  skip (exists): val/{cls_dir.name}")
                    continue
                shutil.move(str(cls_dir), str(dst))
                restored += 1
                print(f"  restored orphan class: val/{cls_dir.name}")

    # Trimmed images were backed up under _val_backup/<class>/<file>
    for cls_dir in BACKUP_DIR.iterdir():
        if cls_dir.name == "_orphans" or not cls_dir.is_dir():
            continue
        dst_cls = VAL_DIR / cls_dir.name
        dst_cls.mkdir(parents=True, exist_ok=True)
        for img in _images_in(cls_dir):
            dst = dst_cls / img.name
            if not dst.exists():
                shutil.move(str(img), str(dst))
                restored += 1

    # Clean up empty backup tree
    shutil.rmtree(BACKUP_DIR, ignore_errors=True)
    print(f"\n✓ Restore complete — {restored} items returned to val/")
    print("  Backup directory removed.")
    return 0


# ── Main fix ──────────────────────────────────────────────────────────────────

def run(apply: bool) -> int:
    if not _validate_paths():
        return 1

    random.seed(RANDOM_SEED)
    train_classes, val_classes = _class_sets()

    orphan_classes = sorted(val_classes - train_classes)
    aligned_classes = sorted(val_classes & train_classes)

    mode = "APPLY" if apply else "DRY-RUN"
    print(f"── Val-set fix [{mode}] ─────────────────────────────────────")
    print(f"  train classes: {len(train_classes)}")
    print(f"  val classes:   {len(val_classes)}")
    print(f"  orphan (val-only, will be moved out): {len(orphan_classes)} "
          f"{orphan_classes if orphan_classes else ''}")
    print(f"  aligned (kept, trimmed): {len(aligned_classes)}")
    print(f"  keep fraction: {VAL_FRACTION:.0%}  floor: {VAL_FLOOR}/class")
    print()

    if apply:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    val_before = 0
    val_after  = 0
    moved_total = 0

    # (3) Orphan classes — move whole folder to _val_backup/_orphans/
    for cls in orphan_classes:
        src = VAL_DIR / cls
        n = len(_images_in(src))
        val_before += n
        print(f"  [orphan] val/{cls}: {n} imgs → backup (class has no train data)")
        if apply:
            dst = BACKUP_DIR / "_orphans" / cls
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
            moved_total += n

    # (4) Aligned classes — trim to VAL_FRACTION (floor VAL_FLOOR)
    for cls in aligned_classes:
        src = VAL_DIR / cls
        imgs = _images_in(src)
        n = len(imgs)
        val_before += n

        keep_n = max(VAL_FLOOR, round(n * VAL_FRACTION))
        keep_n = min(keep_n, n)  # can't keep more than exist
        val_after += keep_n
        move_n = n - keep_n

        if move_n <= 0:
            continue

        if apply:
            random.shuffle(imgs)
            to_move = imgs[keep_n:]  # surplus beyond the kept subset
            dst_cls = BACKUP_DIR / cls
            dst_cls.mkdir(parents=True, exist_ok=True)
            for img in to_move:
                shutil.move(str(img), str(dst_cls / img.name))
            moved_total += move_n

    print()
    print(f"── Summary ──────────────────────────────────────────────────")
    print(f"  val images before: {val_before}")
    print(f"  val images after:  {val_after}  (aligned classes only)")
    print(f"  moved to backup:   {val_before - val_after}")
    if apply:
        print(f"  actually moved:    {moved_total}")
        print(f"  backup location:   {BACKUP_DIR}")
        print(f"\n✓ Applied. Val now has {len(aligned_classes)} classes aligned "
              f"with train.")
        print(f"  Reversible: /opt/homebrew/bin/python3.11 06_fix_val_set.py --restore")
        print(f"  Reclaim space once training is confirmed good: rm -rf {BACKUP_DIR}")
    else:
        print(f"\n  DRY-RUN only — no files changed.")
        print(f"  To apply: /opt/homebrew/bin/python3.11 06_fix_val_set.py --apply")
    return 0


# ── Entry ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Reversible val-set cleanup.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--apply",   action="store_true", help="perform moves (default: dry-run)")
    g.add_argument("--restore", action="store_true", help="undo: restore from backup")
    args = ap.parse_args()

    if args.restore:
        sys.exit(restore())
    sys.exit(run(apply=args.apply))
