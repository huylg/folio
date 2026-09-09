#!/usr/bin/env python3
"""Embed Sparkle from SwiftPM, preserve its symlinks, and sign from the inside out."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys

bundle, build_dir = map(Path, sys.argv[1:])
source = build_dir / "Sparkle.framework"
if not source.is_dir():
    raise SystemExit(f"Missing {source}; run swift build first")
destination = bundle / "Contents/Frameworks/Sparkle.framework"
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["ditto", str(source), str(destination)], check=True)

# The checked-in public key makes local and CI builds work without Keychain access.
# An explicit override is useful for isolated signing tests or a planned key rotation.
plist = bundle / "Contents/Info.plist"
with plist.open("rb") as file:
    info = plistlib.load(file)
key = os.environ.get("SPARKLE_PUBLIC_KEY", "").strip() or info.get("SUPublicEDKey", "")
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("A base64 encoded 32-byte Sparkle public key is required")
info["SUPublicEDKey"] = key
with plist.open("wb") as file:
    plistlib.dump(info, file)

# Folio currently distributes ad-hoc signed builds. Preserve the existing signing model;
# Sparkle's Ed25519 signature authenticates update archives independently of Developer ID.
version = destination / "Versions/B"
for component in [version / "Autoupdate",
                  version / "Updater.app",
                  *sorted((version / "XPCServices").glob("*.xpc")),
                  destination]:
    subprocess.run(["codesign", "--force", "--sign", "-", str(component)], check=True)
