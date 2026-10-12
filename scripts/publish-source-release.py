#!/usr/bin/env python3
"""Attach immutable CI bytes to a new tag release or an empty GitHub UI release."""

import json
from pathlib import Path
import re
import subprocess
import sys


def validate_existing(release, tag):
    if release.get("tag_name") != tag or release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("source release must be the matching published stable tag")
    if release.get("assets") != []:
        raise ValueError("source release already has assets; refusing to replace published bytes")


def publish(version, installer, notes):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("release version must be numeric semver")
    tag = "v" + version
    if installer.name != "PersonaStack-" + version + "-developerid.dmg" or not installer.is_file() or not notes.is_file():
        raise ValueError("release needs the exact CI installer and authored notes")
    command = ["gh", "release", "view", tag, "--repo", "personastack/macos", "--json", "tagName,isDraft,isPrerelease,assets"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        data = json.loads(result.stdout)
        validate_existing({"tag_name": data.get("tagName"), "draft": data.get("isDraft"),
                           "prerelease": data.get("isPrerelease"), "assets": data.get("assets")}, tag)
        subprocess.run(["gh", "release", "upload", tag, str(installer), "--repo", "personastack/macos"], check=True)
        subprocess.run(["gh", "release", "edit", tag, "--repo", "personastack/macos", "--notes-file", str(notes),
                        "--title", "PersonaStack " + tag, "--latest"], check=True)
        return
    if "release not found" not in result.stderr.lower() and "404" not in result.stderr:
        raise ValueError("could not inspect source release; refusing to treat an API error as an absent release")
    subprocess.run(["gh", "release", "create", tag, str(installer), "--repo", "personastack/macos",
                    "--notes-file", str(notes), "--title", "PersonaStack " + tag, "--latest"], check=True)


if __name__ == "__main__":
    try:
        publish(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
    except (ValueError, OSError, IndexError, subprocess.CalledProcessError) as error:
        print("Source publication: " + str(error), file=sys.stderr)
        sys.exit(1)
