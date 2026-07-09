"""
Downloads images for specific new species only, adding them into the
existing dataset tree. Run this BEFORE 03_train_extended.py when adding
new species to the model.

The script:
  1. Verifies every taxon ID against the iNaturalist API and checks the
     scientific name matches — aborts on any mismatch before downloading.
  2. Skips folders that already have enough images.
  3. Downloads into the existing train/ and val/ structure alongside
     the Phase 1 and Phase 2 species.

Run:
    cd ~/Desktop/RawFileBrowser/ml_scripts
    python3 05_download_new_species.py

Requirements: pip3 install requests tqdm Pillow
"""

import time
import requests
from pathlib import Path
from tqdm import tqdm

# ── Configuration ─────────────────────────────────────────────────────────────

# Absolute path on the internal volume, OUTSIDE the iCloud-synced Desktop.
# Datasets on an iCloud-synced Desktop get evicted ("dataless"), causing ~140x
# training slowdowns from per-file re-download. Keep under /Users/Shared.
DATASET_DIR = Path("/Users/Shared/uk_wildlife_dataset")
IMAGES_DIR  = DATASET_DIR / "images"

MAX_IMAGES_PER_SPECIES = 300   # per split (train only; val uses VAL_RATIO)
VAL_RATIO              = 0.2   # 20% of downloaded images go to val/

INAT_API  = "https://api.inaturalist.org/v1"
UK_BOUNDS = {
    "nelat": 60.9, "nelng": 1.8,
    "swlat": 49.8, "swlng": -8.2,
}

# ── Phase 3 new species ───────────────────────────────────────────────────────
# IDs verified from iNaturalist taxon page URLs — DO NOT GUESS IDs.
# See ML_CLASSIFIER_GUIDE.md for lookup methodology.
#
# Notes:
#   Wild Boar (Sus scrofa, 42134) covers both wild boar and domestic pig on
#   iNaturalist — they share the same taxon. Images will be a mix of both.
#
#   Farm animals (cattle, sheep, horse, goat) are globally abundant on iNat
#   but UK-specific breeds may be under-represented. Images are downloaded
#   UK-bounded to bias toward familiar UK subjects.
#
#   Water Shrew — expected low UK observation count. The verification step
#   will report this; delete its folders before training if count is < 50.
#
#   Yellow-necked Mouse (Apodemus flavicollis, 45550) was REMOVED from this
#   list: it is low-observation in the UK and was an orphan val-only class
#   (no train data) that 06_fix_val_set.py had to move out. Re-adding it would
#   silently resurrect a class the current 245-class model does not contain.

NEW_SPECIES = [
    # ── New UK wild mammals ────────────────────────────────────────────────
    {
        "taxon_id":       43793,
        "common_name":    "Eurasian Beaver",
        "scientific_name": "Castor fiber",
    },
    {
        "taxon_id":       67819,
        "common_name":    "European Water Vole",
        "scientific_name": "Arvicola amphibius",
    },
    {
        "taxon_id":       45316,
        "common_name":    "Eurasian Harvest Mouse",
        "scientific_name": "Micromys minutus",
    },
    {
        "taxon_id":       45856,
        "common_name":    "Hazel Dormouse",
        "scientific_name": "Muscardinus avellanarius",
    },
    {
        "taxon_id":       46859,
        "common_name":    "Water Shrew",
        "scientific_name": "Neomys fodiens",
        # NOTE: Expected low UK observation count — check summary before training.
        # Delete train/Water_Shrew and val/Water_Shrew if total < 50 images.
    },
    {
        "taxon_id":       42134,
        "common_name":    "Wild Boar",
        "scientific_name": "Sus scrofa",
        # NOTE: iNat treats domestic pig and wild boar as the same taxon.
        # This class will contain a mix of both.
    },
    # ── Farm / domestic animals ────────────────────────────────────────────
    {
        "taxon_id":       74113,
        "common_name":    "Domestic Cattle",
        "scientific_name": "Bos taurus",
    },
    {
        "taxon_id":       121578,
        "common_name":    "Domestic Sheep",
        "scientific_name": "Ovis aries",
    },
    {
        "taxon_id":       209233,
        "common_name":    "Domestic Horse",
        "scientific_name": "Equus caballus",
    },
    {
        "taxon_id":       123070,
        "common_name":    "Domestic Goat",
        "scientific_name": "Capra hircus",
    },
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def sanitise(name: str) -> str:
    """Matches the sanitise() logic used in 01_download_uk_data.py."""
    for ch in [" ", "/", "'", "(", ")", ".", ","]:
        name = name.replace(ch, "_")
    return name.strip("_")


def verify_taxon(taxon_id: int, expected_scientific: str) -> bool:
    """
    Fetch the taxon page and confirm the scientific name matches.
    Aborts the whole run if any ID is wrong — never silently download
    wrong-species images.
    """
    try:
        resp = requests.get(
            f"{INAT_API}/taxa/{taxon_id}",
            timeout=15,
        )
    except requests.RequestException as e:
        print(f"  ✗ Network error verifying taxon {taxon_id}: {e}")
        return False

    if resp.status_code != 200:
        print(f"  ✗ API error {resp.status_code} for taxon {taxon_id}")
        return False

    data = resp.json()
    results = data.get("results", [])
    if not results:
        print(f"  ✗ Taxon {taxon_id} not found on iNaturalist")
        return False

    taxon = results[0]
    actual_scientific = taxon.get("name", "").strip()

    if actual_scientific.lower() != expected_scientific.lower():
        print(
            f"  ✗ MISMATCH taxon {taxon_id}: "
            f"expected '{expected_scientific}', got '{actual_scientific}'"
        )
        return False

    common = taxon.get("preferred_common_name", taxon.get("name", ""))
    print(f"  ✓ {taxon_id}  {actual_scientific:<35}  ({common})")
    return True


def count_uk_observations(taxon_id: int) -> int:
    """Returns the number of research-grade UK observations for a taxon."""
    try:
        resp = requests.get(
            f"{INAT_API}/observations",
            params={
                "taxon_id":      taxon_id,
                "quality_grade": "research",
                "photos":        True,
                "per_page":      1,
                **UK_BOUNDS,
            },
            timeout=15,
        )
        if resp.status_code == 200:
            return resp.json().get("total_results", 0)
    except requests.RequestException:
        pass
    return 0


def download_images_for_split(
    taxon_id: int,
    common_name: str,
    split: str,
    target: int,
) -> int:
    """
    Download up to `target` images into images/<split>/<folder>/.
    Skips images already on disk. Returns final image count.
    Farm animals use global bounds (no UK_BOUNDS restriction) to get
    enough images — this is noted in the progress output.
    """
    save_dir = IMAGES_DIR / split / sanitise(common_name)
    save_dir.mkdir(parents=True, exist_ok=True)

    existing = list(save_dir.glob("*.jpg"))
    if len(existing) >= target:
        return len(existing)

    saved = len(existing)
    page  = 1

    # Farm animals: relax geographic bounds to avoid under-sampling.
    # Wild species: UK-bounded for relevance.
    farm_taxon_ids = {74113, 121578, 209233, 123070}
    geo_params = {} if taxon_id in farm_taxon_ids else UK_BOUNDS

    while saved < target:
        try:
            resp = requests.get(
                f"{INAT_API}/observations",
                params={
                    "taxon_id":      taxon_id,
                    "quality_grade": "research",
                    "photos":        True,
                    "per_page":      50,
                    "page":          page,
                    **geo_params,
                },
                timeout=30,
            )
        except requests.RequestException:
            break

        if resp.status_code != 200:
            break

        observations = resp.json().get("results", [])
        if not observations:
            break

        for obs in observations:
            if saved >= target:
                break
            photos = obs.get("photos", [])
            if not photos:
                continue
            url = photos[0].get("url", "").replace("square", "medium")
            if not url:
                continue
            filepath = save_dir / f"{taxon_id}_{obs['id']}.jpg"
            if filepath.exists():
                saved += 1
                continue
            try:
                r = requests.get(url, timeout=15)
                if r.status_code == 200:
                    filepath.write_bytes(r.content)
                    saved += 1
            except Exception:
                pass

        page += 1
        time.sleep(0.3)

    return saved


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 65)
    print("UK Wildlife — New Species Downloader (Phase 3)")
    print("=" * 65)
    print(f"\nDataset directory: {DATASET_DIR}")

    if not IMAGES_DIR.exists():
        print(f"\nERROR: Dataset directory not found at {IMAGES_DIR}")
        print("Run 01_download_uk_data.py first to create the base dataset.")
        return

    # ── Step 1: Verify all taxon IDs before downloading anything ─────────────
    print(f"\nStep 1: Verifying {len(NEW_SPECIES)} taxon IDs against iNaturalist API...")
    print("-" * 65)

    all_ok = True
    for sp in NEW_SPECIES:
        ok = verify_taxon(sp["taxon_id"], sp["scientific_name"])
        if not ok:
            all_ok = False
        time.sleep(0.3)

    if not all_ok:
        print("\nERROR: One or more taxon IDs failed verification.")
        print("Fix the mismatches above before re-running.")
        return

    print("\n✓ All taxon IDs verified.")

    # ── Step 2: Report UK observation counts ─────────────────────────────────
    print(f"\nStep 2: Checking UK observation counts...")
    print("-" * 65)

    low_count_species = []
    for sp in NEW_SPECIES:
        farm_taxon_ids = {74113, 121578, 209233, 123070}
        if sp["taxon_id"] in farm_taxon_ids:
            # Farm animals: report global count (UK-bounded would be misleadingly low)
            count = 0  # skip — they're globally abundant
            print(f"  {sp['common_name']:<30}  (farm animal — global images used)")
        else:
            count = count_uk_observations(sp["taxon_id"])
            flag = "  ⚠️  LOW" if count < 50 else ""
            print(f"  {sp['common_name']:<30}  {count:>5} UK observations{flag}")
            if count < 50:
                low_count_species.append(sp["common_name"])
        time.sleep(0.3)

    if low_count_species:
        print(f"\n⚠️  Low-count warning: {', '.join(low_count_species)}")
        print("   Consider excluding these species before training.")
        print("   Delete their train/ and val/ folders if you decide to exclude.")
        answer = input("\nContinue with download anyway? [y/N]: ").strip().lower()
        if answer != "y":
            print("Aborted.")
            return
    else:
        answer = input("\nProceed with download? [y/N]: ").strip().lower()
        if answer != "y":
            print("Aborted.")
            return

    # ── Step 3: Download images ───────────────────────────────────────────────
    train_target = MAX_IMAGES_PER_SPECIES
    val_target   = max(30, int(MAX_IMAGES_PER_SPECIES * VAL_RATIO))

    print(f"\nStep 3: Downloading images...")
    print(f"  Target: {train_target} train / {val_target} val per species")
    print("-" * 65)

    summary = []
    for sp in tqdm(NEW_SPECIES, desc="Species"):
        t = download_images_for_split(sp["taxon_id"], sp["common_name"], "train", train_target)
        v = download_images_for_split(sp["taxon_id"], sp["common_name"], "val",   val_target)
        summary.append({
            "common_name":  sp["common_name"],
            "scientific":   sp["scientific_name"],
            "taxon_id":     sp["taxon_id"],
            "train_images": t,
            "val_images":   v,
            "total":        t + v,
        })

    # ── Step 4: Summary ───────────────────────────────────────────────────────
    print(f"\n{'=' * 65}")
    print("Download complete — summary:")
    print(f"  {'Species':<30}  {'Train':>6}  {'Val':>5}  {'Total':>6}")
    print(f"  {'-' * 52}")

    total_images = 0
    needs_review = []
    for row in summary:
        flag = "  ⚠️" if row["total"] < 50 else ""
        print(f"  {row['common_name']:<30}  {row['train_images']:>6}  {row['val_images']:>5}  {row['total']:>6}{flag}")
        total_images += row["total"]
        if row["total"] < 50:
            needs_review.append(row["common_name"])

    print(f"\n  Total new images downloaded: {total_images:,}")

    if needs_review:
        print(f"\n⚠️  Species with < 50 images — review before training:")
        for name in needs_review:
            print(f"    rm -rf {IMAGES_DIR}/train/{sanitise(name)}")
            print(f"    rm -rf {IMAGES_DIR}/val/{sanitise(name)}")

    print(f"\nNext step:")
    print(f"  cd ~/Desktop/RawFileBrowser/ml_scripts")
    print(f"  python3 03_train_extended.py")
    print("=" * 65)


if __name__ == "__main__":
    main()
