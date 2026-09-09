#!/usr/bin/env python3
"""Exercise packaging/signing with an ephemeral key; never touches the login Keychain.

Run after `make app`. All test bundles and keys are confined to a temporary directory.
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent

def run(args, **kwargs):
    return subprocess.run(args, text=True, check=True, capture_output=True, **kwargs)

# Capture the test key directly into memory. Do not log it or pass it in argv.
keys = json.loads(run(["swift", "-e", '''
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let value = ["private": key.rawRepresentation.base64EncodedString(),
             "public": key.publicKey.rawRepresentation.base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
''']).stdout)
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
with tempfile.TemporaryDirectory(prefix="folio-sparkle-release-test-") as directory:
    scratch = Path(directory)
    bundle = scratch / "image/Folio.app"
    bundle.parent.mkdir()
    run(["ditto", str(root / "build/Folio.app"), str(bundle)])
    plist = bundle / "Contents/Info.plist"
    with plist.open("rb") as file:
        info = plistlib.load(file)
    info.update(SUPublicEDKey=keys["public"], CFBundleShortVersionString="99.0.0",
                CFBundleVersion="999999")
    with plist.open("wb") as file:
        plistlib.dump(info, file)
    run(["codesign", "--force", "--sign", "-", str(bundle)])
    run(["codesign", "--verify", "--deep", "--strict", str(bundle)])
    archive = scratch / "Folio-v99.0.0.dmg"
    run(["hdiutil", "create", "-srcfolder", str(bundle.parent), "-format", "UDZO", str(archive)])
    env = dict(os.environ, SPARKLE_PRIVATE_KEY=keys["private"])
    result = run(["python3", str(root / "Tools/create_appcast.py"), str(archive), "v99.0.0"], env=env)
    assert keys["private"] not in result.stdout + result.stderr
    item = ET.parse(scratch / "appcast.xml").find("./channel/item")
    assert item is not None
    assert item.findtext(namespace + "version") == "999999"
    signature = item.find("enclosure").get(namespace + "edSignature")
    # Independently verify Sparkle's signature using the public key shipped inside the app.
    verifier = scratch / "verify.swift"
    verifier.write_text('''
import CryptoKit
import Foundation
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let signature = Data(base64Encoded: args[2])!
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
assert(key.isValidSignature(signature, for: archive))
assert(!key.isValidSignature(signature, for: archive + Data([0])))
''')
    run(["swift", str(verifier), keys["public"], signature, str(archive)])
    # Start the real framework inside an isolated native app, without making network calls.
    startup = scratch / "Startup.app"
    run(["ditto", str(bundle), str(startup)])
    startup_plist = startup / "Contents/Info.plist"
    startup_info = dict(info, CFBundleIdentifier="io.huylg.folio.smoke." + uuid.uuid4().hex)
    with startup_plist.open("wb") as file:
        plistlib.dump(startup_info, file)
    executable = startup / "Contents/MacOS/Folio"
    run(["swiftc", str(root / "Tools/SparkleStartupCheck.swift"),
         "-F", str(startup / "Contents/Frameworks"), "-framework", "Sparkle",
         "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
         "-o", str(executable)])
    run(["codesign", "--force", "--sign", "-", str(startup)])
    result = run([str(executable)], timeout=30)
    assert "Sparkle startup and hourly schedule verified" in result.stdout
    # A mismatched public/private pair must stop publication, even if Sparkle only warns.
    wrong = dict(env, SPARKLE_PRIVATE_KEY=base64.b64encode(os.urandom(32)).decode())
    failure = subprocess.run(["python3", str(root / "Tools/create_appcast.py"), str(archive), "v99.0.0"],
                             env=wrong, text=True, capture_output=True)
    assert failure.returncode != 0, "A mismatched key must not produce a publishable feed"
print("PASS: real Sparkle startup, hourly schedule, embedded helpers, signed DMG/appcast, public-key verification, tamper rejection, and mismatched-key rejection")
