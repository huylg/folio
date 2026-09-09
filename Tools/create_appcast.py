#!/usr/bin/env python3
"""Generate and validate the signed Sparkle feed before publishing any release files."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

archive = Path(sys.argv[1]).resolve()
tag = sys.argv[2]
secret = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
if not secret and os.environ.get("CI"):
    raise SystemExit("SPARKLE_PRIVATE_KEY is required to sign updates in CI")
tool = Path(__file__).resolve().parent.parent / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
base = f"https://github.com/huylg/folio/releases/download/{tag}/"
with tempfile.TemporaryDirectory(prefix="folio-appcast-") as directory:
    staging = Path(directory)
    shutil.copy2(archive, staging / archive.name)
    # CI reads its secret on stdin. Local signing uses the existing Folio Keychain item
    # directly, without exporting it or creating another signing identity.
    signing_args = ["--ed-key-file", "-"] if secret else ["--account", "io.huylg.folio"]
    subprocess.run([str(tool), *signing_args, "--maximum-deltas", "0",
                    "--download-url-prefix", base,
                    "--full-release-notes-url", f"https://github.com/huylg/folio/releases/tag/{tag}",
                    "--link", "https://github.com/huylg/folio", str(staging)],
                   input=secret + "\n" if secret else None, text=True, check=True)
    feed = staging / "appcast.xml"
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise SystemExit("Expected exactly one release in the generated appcast")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != base + archive.name:
        raise SystemExit("The appcast does not point to this release archive")
    signature = enclosure.get(namespace + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit("Sparkle did not sign the archive; check that the public/private keys match")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise SystemExit("The appcast archive size is incorrect")
    if item.findtext(namespace + "shortVersionString") != tag.removeprefix("v"):
        raise SystemExit("The appcast version does not match the release tag")
    shutil.copy2(feed, archive.parent / "appcast.xml")
