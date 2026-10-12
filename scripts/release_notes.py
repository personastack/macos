#!/usr/bin/env python3
"""Validate the authored notes shared by GitHub and the Sparkle appcast."""

import re
import sys
from datetime import date
from pathlib import Path


def validate_release_notes(notes: str, version: str) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("release version must use numeric major.minor.patch")
    if f"# PersonaStack {version}" not in notes.splitlines():
        raise ValueError("release notes must have the matching PersonaStack version heading")
    for line in notes.splitlines():
        if not line.startswith("- "):
            continue
        text = re.sub(r"\[[^\]]*\]\([^)]*\)", "", line[2:])
        text = re.sub(r"https?://\S+", "", text)
        words = re.findall(r"[A-Za-z]+", text)
        if len(words) < 2 or " ".join(words).lower() in {
            "full changelog", "changelog", "full release notes", "release notes", "compare releases"
        }:
            continue
        return
    raise ValueError("release notes must contain a change bullet, not only links")


def main() -> int:
    if len(sys.argv) == 6 and sys.argv[1] == "render":
        version, release_date, source, output = sys.argv[2:]
        try:
            notes = render_release_notes(Path(source).read_text(encoding="utf-8"), version, release_date)
            Path(output).write_text(notes, encoding="utf-8")
        except (OSError, ValueError) as error:
            raise SystemExit(str(error)) from error
        return 0
    if len(sys.argv) != 3:
        raise SystemExit("usage: release_notes.py VERSION NOTES_FILE | render VERSION DATE SOURCE OUTPUT")
    version, notes_path = sys.argv[1:]
    try:
        validate_release_notes(Path(notes_path).read_text(encoding="utf-8"), version)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    return 0


def render_release_notes(body: str, version: str, release_date: str) -> str:
    if date.fromisoformat(release_date).isoformat() != release_date:
        raise ValueError("release date must use YYYY-MM-DD")
    if any(line.startswith("# ") or line.startswith("Release date:") for line in body.splitlines()):
        raise ValueError("next release notes must omit the generated version and date")
    notes = f"# PersonaStack {version}\n\nRelease date: {release_date}\n\n{body.strip()}\n"
    validate_release_notes(notes, version)
    return notes


if __name__ == "__main__":
    raise SystemExit(main())
