#!/usr/bin/env python3
"""Download San Francisco area OSM extract from Geofabrik."""

import os
import sys
import requests

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
PBF_URL = "https://download.geofabrik.de/north-america/us/california/norcal-latest.osm.pbf"
PBF_FILENAME = "norcal-latest.osm.pbf"


def download_pbf(url=PBF_URL, dest_dir=DATA_DIR, filename=PBF_FILENAME):
    """Download the PBF file if it doesn't already exist."""
    os.makedirs(dest_dir, exist_ok=True)
    dest_path = os.path.join(dest_dir, filename)

    if os.path.exists(dest_path):
        print(f"File already exists: {dest_path}")
        return dest_path

    print(f"Downloading {url}...")
    print("This file is ~700MB and may take a while.")

    response = requests.get(url, stream=True)
    response.raise_for_status()

    total_size = int(response.headers.get("content-length", 0))
    downloaded = 0

    with open(dest_path, "wb") as f:
        for chunk in response.iter_content(chunk_size=8192):
            f.write(chunk)
            downloaded += len(chunk)
            if total_size:
                pct = downloaded / total_size * 100
                print(f"\r  {downloaded / 1e6:.1f} / {total_size / 1e6:.1f} MB ({pct:.1f}%)", end="", flush=True)

    print(f"\nSaved to {dest_path}")
    return dest_path


if __name__ == "__main__":
    download_pbf()
