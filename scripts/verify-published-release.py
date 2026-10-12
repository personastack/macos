#!/usr/bin/env python3
"""Verify public delivery of the exact CI installer and authored changelog."""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

from release_notes import validate_release_notes

ROOT = Path(__file__).resolve().parents[1]
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fetch(url, path, maximum_bytes):
    deadline = time.monotonic() + 60
    while True:
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "PersonaStack-release-verification", "Cache-Control": "no-cache"})
            with urllib.request.urlopen(request, timeout=20) as response, path.open("wb") as output:
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > maximum_bytes:
                        raise ValueError("published response exceeds its expected size")
                    output.write(block)
            return
        except (urllib.error.URLError, TimeoutError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(2)


def verify_release(metadata, tag, notes, assets):
    if metadata.get("tag_name") != tag or metadata.get("draft") is not False or metadata.get("prerelease") is not False:
        raise ValueError("public release identity or publication state does not match")
    if metadata.get("body", "").strip() != notes.strip():
        raise ValueError("public release notes differ from the authored changelog")
    names = {asset.get("name") for asset in metadata.get("assets", [])}
    if not assets.issubset(names):
        raise ValueError("public release is missing an installer asset")


def verify_installer(path, expected_sha256, expected_size):
    if path.stat().st_size != expected_size or hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha256:
        raise ValueError("public installer bytes differ from the signed CI artifact")


def verify_signature(tool, path, key, signature=None):
    command = [tool, "--ed-key-file", "-", "--verify", str(path)]
    if signature:
        command.append(signature)
    result = subprocess.run(command, input=key, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise ValueError("Sparkle signature verification failed for " + path.name)


def main():
    if len(sys.argv) != 6:
        raise ValueError("usage: verify-published-release.py VERSION DMG NOTES SPARKLE_TOOL OUTPUT_DIRECTORY")
    version, dmg, notes_path, sparkle_tool, output_path = sys.argv[1:]
    dmg, notes_path, output = Path(dmg), Path(notes_path), Path(output_path)
    notes = notes_path.read_text()
    validate_release_notes(notes, version)
    name = f"PersonaStack-{version}-developerid.dmg"
    if dmg.name != name:
        raise ValueError("CI installer filename does not match its version")
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not key:
        raise ValueError("Sparkle signing key is required for verification")
    digest, size = hashlib.sha256(dmg.read_bytes()).hexdigest(), dmg.stat().st_size
    output.mkdir(parents=True, exist_ok=True)
    tag = f"desktop-v{version}"
    urls = {
        "source-release.json": f"https://api.github.com/repos/personastack/macos/releases/tags/v{version}",
        "tap-release.json": f"https://api.github.com/repos/personastack/homebrew-tap/releases/tags/{tag}",
        "source.dmg": f"https://github.com/personastack/macos/releases/download/v{version}/{name}",
        "tap.dmg": f"https://github.com/personastack/homebrew-tap/releases/download/{tag}/{name}",
        name: f"https://raw.githubusercontent.com/personastack/homebrew-tap/{tag}/Downloads/{name}",
        "latest.dmg": "https://github.com/personastack/homebrew-tap/releases/latest/download/PersonaStack-latest.dmg",
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futures = {pool.submit(fetch, url, output / label, size if label.endswith(".dmg") else 2 * 1024 * 1024): label
                   for label, url in urls.items()}
        for future in concurrent.futures.as_completed(futures):
            label = futures[future]
            future.result()
            if label.endswith(".dmg"):
                verify_installer(output / label, digest, size)
    verify_release(json.loads((output / "source-release.json").read_text()), f"v{version}", notes, {name})
    verify_release(json.loads((output / "tap-release.json").read_text()), tag, notes, {name, "PersonaStack-latest.dmg"})

    deadline = time.monotonic() + 60
    while True:
        fetch("https://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml", output / "appcast.xml", 2 * 1024 * 1024)
        fetch("https://raw.githubusercontent.com/personastack/homebrew-tap/main/Casks/personastack.rb", output / "personastack.rb", 16 * 1024)
        validation = subprocess.run([sys.executable, str(ROOT / "scripts/validate-appcast.py"),
                                     str(output / "appcast.xml"), version, tag, str(output / name),
                                     str(output / "personastack.rb"), str(notes_path)], capture_output=True)
        if validation.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise ValueError("served cask or feed does not select the signed installer and authored notes")
        time.sleep(2)
    items = ET.parse(output / "appcast.xml").findall(".//item")
    item = next(item for item in items if item.findtext(f"{{{SPARKLE_NAMESPACE}}}version") == version)
    signature = item.find("enclosure").get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    verify_signature(sparkle_tool, output / name, key, signature)
    verify_signature(sparkle_tool, output / "appcast.xml", key)
    receipt = {"version": version, "sha256": digest, "tap_tag": tag,
               "release_notes_exact": True, "archive_and_feed_signatures_verified": True,
               "public_installers_byte_identical": True, "served_cask_and_feed_verified": True}
    (output / "verification.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
