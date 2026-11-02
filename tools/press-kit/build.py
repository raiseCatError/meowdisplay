#!/usr/bin/env python3
"""Build the website gallery and ZIP from an explicitly reviewed inventory.

Run with Python 3. No image generation, screenshot substitution or device access.
The manifest records final exported assets, never raw capture paths.
"""
import hashlib
import html
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
KIT = ROOT / "press-kit"


def approved_files():
    manifest = json.loads((ROOT / "tools/press-kit/approved-assets.json").read_text())
    files = []
    categories = set()
    for item in manifest:
        relative = Path(item["file"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[0] not in {"Brand", "Screenshots", "Graphics", "Information"}:
            raise ValueError("Invalid asset path")
        path = KIT / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing or symlinked asset: {relative}")
        if item.get("review") != "approved":
            raise ValueError(f"Unreviewed asset: {relative}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError(f"Asset changed since review: {relative}")
        if relative.parts[0] == "Screenshots" and not all(item.get(key) for key in ["device", "version", "captured", "liveSession", "privacyReviewed", "visualReviewed"]):
            raise ValueError(f"Missing live-capture provenance: {relative}")
        categories.add(relative.parts[0])
        files.append((path, item))
    if not {"Brand", "Screenshots", "Information"}.issubset(categories):
        raise ValueError("Brand, reviewed live Screenshots and Information are required")
    if len({path for path, _ in files}) != len(files):
        raise ValueError("Duplicate asset")
    return files


def gallery(files, category):
    cards = []
    for path, item in files:
        if path.relative_to(KIT).parts[0] != category:
            continue
        url = "/press-kit/" + path.relative_to(KIT).as_posix()
        label = html.escape(item["caption"])
        cards.append(f'<figure><a href="{url}" download><img src="{url}" width="{int(item["width"])}" height="{int(item["height"])}" alt="{label}" loading="lazy"></a><figcaption>{label}<br><a href="{url}" download>Download PNG ↓</a></figcaption></figure>')
    return "\n".join(cards)


def main():
    files = approved_files()  # Fail before writing anything when capture review is pending.
    readme = KIT / "README.txt"
    if not readme.is_file():
        raise ValueError("README.txt is required")
    page = (ROOT / "tools/press-kit/press.template.html").read_text()
    for category in ["Brand", "Screenshots", "Graphics"]:
        page = page.replace("<!-- " + category.upper() + " -->", gallery(files, category))
    archive = KIT / "MeowDisplay-Press-Kit.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        for path, _ in sorted(files):
            output.write(path, path.relative_to(KIT).as_posix())
        output.write(readme, "README.txt")
    with zipfile.ZipFile(archive) as output:
        if output.testzip() is not None or len(output.namelist()) != len(files) + 1:
            raise ValueError("ZIP verification failed")
    (ROOT / "press.html").write_text(page)
    print(f"Built {archive} with {len(files)} approved assets and press.html")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError) as error:
        sys.exit(f"Press kit not ready: {error}")
