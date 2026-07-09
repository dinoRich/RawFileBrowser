"""
Downloads research-grade UK wildlife observations from iNaturalist.
Restricted to birds (Aves) and mammals (Mammalia) only.

Key fix: ranks species by UK-specific observation counts, not global counts.
Uses the /observations/species_counts endpoint which returns species
ranked by how many times they have been observed *within the UK bounding box*.
This ensures common UK species rank above globally-common American species.

Requirements: pip3 install pandas requests Pillow tqdm
"""

import time
import requests
import pandas as pd
from pathlib import Path
from tqdm import tqdm

# ── Configuration ─────────────────────────────────────────────────────────────

# Absolute path on the internal volume, OUTSIDE the iCloud-synced Desktop.
# A relative path here previously meant the dataset landed wherever the script
# was run from; iCloud eviction of a Desktop dataset caused ~140x training
# slowdowns. Keep datasets under /Users/Shared so they are never cloud-managed.
OUTPUT_DIR   = Path("/Users/Shared/uk_wildlife_dataset")
IMAGES_DIR   = OUTPUT_DIR / "images"

# Minimum UK observations to be included
MIN_UK_OBS             = 100
# Maximum images to download per species
MAX_IMAGES_PER_SPECIES = 300
# How many species to include in the model
MAX_SPECIES_TOTAL      = 200

# iNaturalist stable taxon IDs for the classes we want
TAXON_FILTERS = [
    {"name": "Aves",     "taxon_id": 3},
    {"name": "Mammalia", "taxon_id": 40151},
]

INAT_API = "https://api.inaturalist.org/v1"
PLACE_ID = 6857   # United Kingdom on iNaturalist

# UK bounding box — used for observation queries
UK_BOUNDS = {
    "nelat": 60.9, "nelng": 1.8,
    "swlat": 49.8, "swlng": -8.2,
}

# ── Core: rank by UK observation count ───────────────────────────────────────

def get_uk_species_counts(class_taxon_id: int, class_name: str) -> list:
    """
    Uses /observations/species_counts with the UK bounding box.
    This endpoint returns species ranked by how many research-grade
    observations exist *within that geographic area* — not globally.
    This is the key fix: an American Robin will have very few UK
    observations and won't appear; a European Robin will rank highly.
    """
    results = []
    page    = 1

    print(f"\n  Fetching UK {class_name} observation counts...")

    while True:
        try:
            resp = requests.get(
                f"{INAT_API}/observations/species_counts",
                params={
                    "taxon_id":      class_taxon_id,
                    "quality_grade": "research",
                    "per_page":      500,
                    "page":          page,
                    **UK_BOUNDS,
                },
                timeout=30,
            )
        except requests.RequestException as e:
            print(f"    Network error: {e}")
            break

        if resp.status_code != 200:
            print(f"    API error {resp.status_code}: {resp.text[:200]}")
            break

        data    = resp.json()
        entries = data.get("results", [])
        if not entries:
            break

        for entry in entries:
            uk_count = entry.get("count", 0)
            if uk_count < MIN_UK_OBS:
                # Results are sorted descending — safe to stop
                return results

            taxon = entry.get("taxon", {})
            if not taxon:
                continue

            # Strict ancestry validation — confirm this really is Aves/Mammalia
            ancestors = set(taxon.get("ancestor_ids", []))
            if class_taxon_id not in ancestors:
                continue

            # Must be species rank
            if taxon.get("rank") != "species":
                continue

            common = taxon.get("preferred_common_name", "").strip()
            if not common:
                common = taxon.get("name", "")

            results.append({
                "taxon_id":    taxon["id"],
                "scientific":  taxon.get("name", ""),
                "common_name": common,
                "class":       class_name,
                "uk_obs_count": uk_count,
            })

        # Check if there are more pages
        total_results = data.get("total_results", 0)
        if len(results) >= total_results:
            break

        page += 1
        time.sleep(0.5)

    return results


def collect_all_species() -> pd.DataFrame:
    all_rows = []

    for tf in TAXON_FILTERS:
        rows = get_uk_species_counts(tf["taxon_id"], tf["name"])
        print(f"    → {len(rows)} {tf['name']} species with >= {MIN_UK_OBS} UK observations")
        all_rows.extend(rows)

    if not all_rows:
        print("ERROR: No species found. Check internet connection.")
        return pd.DataFrame()

    df = pd.DataFrame(all_rows)

    # Deduplicate by taxon_id (belt and braces)
    before = len(df)
    df = (df.sort_values("uk_obs_count", ascending=False)
            .drop_duplicates(subset="taxon_id", keep="first")
            .reset_index(drop=True))
    removed = before - len(df)
    if removed:
        print(f"  Removed {removed} duplicate entries")

    # Sort by UK observation count, take top N
    df = (df.sort_values("uk_obs_count", ascending=False)
            .head(MAX_SPECIES_TOTAL)
            .reset_index(drop=True))
    df["class_index"] = df.index

    return df


# ── Image download ────────────────────────────────────────────────────────────

def sanitise(name: str) -> str:
    for ch in [" ", "/", "'", "(", ")", ".", ","]:
        name = name.replace(ch, "_")
    return name.strip("_")


def download_images(taxon_id: int, common_name: str, split: str) -> int:
    save_dir = IMAGES_DIR / split / sanitise(common_name)
    save_dir.mkdir(parents=True, exist_ok=True)

    existing = list(save_dir.glob("*.jpg"))
    if len(existing) >= MAX_IMAGES_PER_SPECIES:
        return len(existing)

    saved = len(existing)
    page  = 1

    while saved < MAX_IMAGES_PER_SPECIES:
        try:
            resp = requests.get(
                f"{INAT_API}/observations",
                params={
                    "taxon_id":      taxon_id,
                    "quality_grade": "research",
                    "photos":        True,
                    "per_page":      50,
                    "page":          page,
                    **UK_BOUNDS,
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
            if saved >= MAX_IMAGES_PER_SPECIES:
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


# ── Config files ──────────────────────────────────────────────────────────────

def write_config(df: pd.DataFrame):
    with open(OUTPUT_DIR / "classes.txt", "w") as f:
        for _, row in df.iterrows():
            f.write(row["common_name"] + "\n")

    yaml_lines = [
        "# UK Birds & Mammals — YOLOv8 Classification",
        f"path: {OUTPUT_DIR.absolute()}",
        "train: images/train",
        "val:   images/val",
        "",
        f"nc: {len(df)}",
        "names:",
    ]
    for _, row in df.iterrows():
        yaml_lines.append(f'  - "{row["common_name"]}"')

    (OUTPUT_DIR / "uk_wildlife.yaml").write_text("\n".join(yaml_lines) + "\n")
    print("✓ classes.txt and uk_wildlife.yaml written")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("UK Birds & Mammals — iNaturalist Dataset Downloader")
    print("=" * 60)

    # Step 1: Build validated species list ranked by UK observations
    print("\nStep 1: Collecting species ranked by UK observation count...")
    df = collect_all_species()
    if df.empty:
        return

    birds_n   = (df["class"] == "Aves").sum()
    mammals_n = (df["class"] == "Mammalia").sum()

    print(f"\n  Final species list: {len(df)} unique species")
    print(f"    Birds:   {birds_n}")
    print(f"    Mammals: {mammals_n}")

    # Save metadata
    meta = df.drop(columns=["class_index"])
    meta.to_csv(OUTPUT_DIR / "species_metadata.csv", index=False)
    print(f"\n✓ Saved metadata → species_metadata.csv")

    write_config(df)

    # Preview — show top 15 of each class so user can verify before downloading
    print("\n  Top 15 birds by UK observations:")
    for _, r in df[df["class"] == "Aves"].head(15).iterrows():
        print(f"    {r.uk_obs_count:>6,}  {r.common_name:<30}  {r.scientific}")

    print("\n  Top 15 mammals by UK observations:")
    for _, r in df[df["class"] == "Mammalia"].head(15).iterrows():
        print(f"    {r.uk_obs_count:>6,}  {r.common_name:<30}  {r.scientific}")

    # Pause to let user review before starting download
    print("\n" + "=" * 60)
    answer = input("Does the species list look correct? Start downloading? [y/N]: ").strip().lower()
    if answer != "y":
        print("Aborted. Edit the configuration at the top of the script and re-run.")
        return

    # Step 2: Download images
    print(f"\nStep 2: Downloading images (up to {MAX_IMAGES_PER_SPECIES} per species)...")
    print("  This typically takes 30–90 minutes.\n")

    summary = []
    for _, row in tqdm(df.iterrows(), total=len(df), desc="Downloading"):
        t = download_images(row["taxon_id"], row["common_name"], "train")
        v = download_images(row["taxon_id"], row["common_name"], "val")
        summary.append({
            "common_name":  row["common_name"],
            "class":        row["class"],
            "uk_obs_count": row["uk_obs_count"],
            "train_images": t,
            "val_images":   v,
            "total":        t + v,
        })

    sdf = pd.DataFrame(summary)
    sdf.to_csv(OUTPUT_DIR / "download_summary.csv", index=False)

    too_few = sdf[sdf["total"] < 20]
    print(f"\n{'=' * 60}")
    print(f"✓ Download complete")
    print(f"  Total images: {sdf['total'].sum():,}")
    print(f"  Species with data: {len(sdf) - len(too_few)}/{len(sdf)}")
    if not too_few.empty:
        print(f"  Species with < 20 images (may affect accuracy):")
        for _, r in too_few.iterrows():
            print(f"    - {r.common_name} ({r.total} images)")
    # This script builds the ~200-species base dataset. The current production
    # model is 245 classes: run 05_download_new_species.py next to add the extra
    # species, THEN 03_train_extended.py to train. 02_train_model.py is the old
    # pre-extension trainer and should not be used for the current model.
    print(f"\nNext steps:")
    print(f"  1. python3 05_download_new_species.py   # add extra species")
    print(f"  2. python3 03_train_extended.py         # train 245-class model")
    print("=" * 60)


if __name__ == "__main__":
    main()
