#!/usr/bin/env python3
"""Fail closed unless a generated Sparkle feed contains its signed release."""

import sys
import hashlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from release_notes import validate_release_notes


def main() -> int:
    if len(sys.argv) != 7:
        raise SystemExit("usage: validate-appcast.py APPCAST VERSION TAP_TAG DMG CASK NOTES_FILE")
    feed_path, version, tap_tag, dmg_path, cask_path, notes_path = sys.argv[1:]
    contents = Path(feed_path).read_text(encoding="utf-8")
    namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    root = ET.fromstring(contents)
    matches = [
        item
        for item in root.findall(".//item")
        if item.findtext(f"{{{namespace}}}version") == version
    ]
    if len(matches) != 1:
        raise SystemExit(f"expected one appcast item for {version}")
    item = matches[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("release item has no enclosure")
    url = enclosure.get("url", "")
    expected_name = Path(dmg_path).name
    if expected_name not in (f"PersonaStack-{version}-unsigned.dmg", f"PersonaStack-{version}-selfsigned.dmg", f"PersonaStack-{version}-developerid.dmg"):
        raise SystemExit("release archive filename is not a supported versioned installer")
    expected_url = f"https://raw.githubusercontent.com/personastack/homebrew-tap/{tap_tag}/Downloads/{expected_name}"
    if url != expected_url:
        raise SystemExit("release archive URL is not the immutable tap artifact")
    if not enclosure.get(f"{{{namespace}}}edSignature"):
        raise SystemExit("release archive has no EdDSA signature")
    if enclosure.get(f"{{{namespace}}}installationType") != "package":
        raise SystemExit("release must install the app and Desktop Control through the main package")
    if int(enclosure.get("length", "0")) <= 0:
        raise SystemExit("release archive length is missing")
    if int(enclosure.get("length", "0")) != Path(dmg_path).stat().st_size:
        raise SystemExit("appcast archive length does not match the published DMG")
    checksum = hashlib.sha256()
    with Path(dmg_path).open("rb") as dmg:
        for block in iter(lambda: dmg.read(1024 * 1024), b""):
            checksum.update(block)
    digest = checksum.hexdigest()
    cask = Path(cask_path).read_text(encoding="utf-8")
    if not re.search(rf'^  version "{re.escape(version)}"$', cask, re.MULTILINE):
        raise SystemExit("cask version does not match the appcast")
    if f'sha256 "{digest}"' not in cask:
        raise SystemExit("cask digest does not match the published DMG")
    cask_url = re.search(r'^  url "([^"]+)"$', cask, re.MULTILINE)
    if cask_url is None or cask_url.group(1).replace("#{version}", version) != expected_url:
        raise SystemExit("cask URL does not select the same immutable installer as the appcast")
    if "auto_updates true" not in cask:
        raise SystemExit("cask does not enable application updates")
    if '  pkg "Install PersonaStack.pkg"' not in cask:
        raise SystemExit("cask must run the same main PersonaStack package")
    if "<!-- sparkle-signatures:\n" not in contents or "edSignature:" not in contents:
        raise SystemExit("appcast has no signed-feed signature")
    description = item.find("description")
    if description is None or not description.text:
        raise SystemExit("release notes are not embedded in the appcast")
    if description.get(f"{{{namespace}}}format") != "markdown":
        raise SystemExit("embedded release notes must use Markdown")
    expected_notes = Path(notes_path).read_text(encoding="utf-8").strip()
    try:
        validate_release_notes(expected_notes, version)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if description.text.strip() != expected_notes:
        raise SystemExit("embedded release notes differ from the authored changelog")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
