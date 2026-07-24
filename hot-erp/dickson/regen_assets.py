#!/usr/bin/env python3
"""Restore this image's baked assets into the persistent sites/assets volume.

sites/assets is a named Docker volume, not an image layer. After any image
rebuild (new app code, updated posawesome, etc.) the volume still holds the
previous image's assets until something overwrites it, causing hash
mismatches between served JS/CSS and what the backend expects. Copy this
image's own freshly-built assets over the volume on every container start
so they always match the code that's actually running.
"""
import shutil
import pathlib

BAKED = pathlib.Path("/opt/assets-image-baked")
LIVE = pathlib.Path("/home/frappe/frappe-bench/sites/assets")

if not BAKED.exists():
    raise SystemExit(f"{BAKED} missing -- was this image built without the asset-baking step?")

# LIVE is itself a volume mountpoint, so it can't be rmtree'd and recreated
# via copytree's own os.makedirs -- clear its contents in place instead.
LIVE.mkdir(parents=True, exist_ok=True)
for child in LIVE.iterdir():
    if child.is_dir() and not child.is_symlink():
        shutil.rmtree(child)
    else:
        child.unlink()

shutil.copytree(BAKED, LIVE, dirs_exist_ok=True)
print(f"Restored assets from {BAKED} -> {LIVE}")
