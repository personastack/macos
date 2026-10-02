#!/usr/bin/env python3
"""Render a Sparkle package update. sign_update seals the resulting feed."""

import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

from release_notes import validate_release_notes

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def render(version: str, archive: Path, notes_path: Path, signature: str, output: Path) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("stable version must use major.minor.patch")
    if archive.name != f"PersonaStack-{version}-developerid.dmg":
        raise ValueError("package update must select the versioned Developer ID archive")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("archive signature must be an Ed25519 signature")
    notes = notes_path.read_text(encoding="utf-8").strip()
    validate_release_notes(notes, version)
    root = ET.parse(output).getroot() if output.exists() else ET.Element("rss", version="2.0")
    if root.tag != "rss":
        raise ValueError("existing feed must be RSS")
    channel = root.find("channel")
    if channel is None:
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "PersonaStack updates"
        ET.SubElement(channel, "link").text = "https://personastack.ai"
        ET.SubElement(channel, "description").text = "PersonaStack for macOS"
    for item in list(channel.findall("item")):
        if item.findtext(f"{{{SPARKLE}}}version") == version:
            channel.remove(item)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"PersonaStack {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"https://raw.githubusercontent.com/personastack/homebrew-tap/desktop-v{version}/Downloads/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/x-apple-diskimage",
        f"{{{SPARKLE}}}edSignature": signature,
        f"{{{SPARKLE}}}installationType": "package",
    })
    channel.insert(0, item)
    ET.indent(root)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("usage: render-package-appcast.py VERSION DMG NOTES SIGNATURE OUTPUT")
    try:
        render(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5]))
    except (ValueError, OSError, ET.ParseError) as error:
        raise SystemExit(str(error)) from error
