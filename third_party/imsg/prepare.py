#!/usr/bin/env python3
"""Prepare the pinned imsg source for a build. Never used by the installed app."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent


def checked_digest(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Pinned dependency digest mismatch")


def extract_source(data, destination, commit):
    prefix = "imsg-" + commit
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        entries = []
        total_size = 0
        for member in archive:
            if len(entries) >= 10_000:
                raise ValueError("Dependency archive has too many entries")
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != prefix:
                raise ValueError("Unsafe dependency archive path")
            if not (member.isdir() or member.isfile()):
                raise ValueError("Dependency archive contains a link or special file")
            total_size += member.size
            if total_size > 32 << 20:
                raise ValueError("Dependency source exceeds its extraction budget")
            entries.append((member, Path(*path.parts[1:])))
        destination.mkdir(parents=True, exist_ok=False)
        for member, relative in entries:
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("Missing dependency archive content")
            with stream, target.open("xb") as output:
                output.write(stream.read())
            target.chmod(member.mode & 0o777)


def prepare(archive_data, destination):
    manifest = json.loads((ROOT / "manifest.json").read_text())
    if len(archive_data) > manifest["source_archive_max_bytes"]:
        raise ValueError("Dependency archive exceeds its download budget")
    checked_digest(archive_data, manifest["source_archive_sha256"])
    patches = []
    for patch in manifest["patches"]:
        relative = PurePosixPath(patch["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid dependency patch path")
        patch_path = ROOT / relative
        checked_digest(patch_path.read_bytes(), patch["sha256"])
        patches.append(patch_path)
    extract_source(archive_data, destination, manifest["upstream_commit"])
    checked_digest((destination / "Package.resolved").read_bytes(), manifest["package_resolved_sha256"])
    for patch in patches:
        subprocess.run(["patch", "-p1", "--batch", "--forward", "-i", str(patch)], cwd=destination, check=True, stdout=subprocess.DEVNULL)
    (destination / ".personastack-imsg-source.json").write_text(json.dumps({
        "upstream_commit": manifest["upstream_commit"],
        "adapter_revision": manifest["adapter_revision"],
        "patches": manifest["patches"],
    }, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--archive", type=Path, help="Previously downloaded pinned archive")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "manifest.json").read_text())
    if args.archive:
        data = args.archive.read_bytes()
    else:
        request = urllib.request.Request(manifest["source_archive_url"], headers={"User-Agent": "PersonaStack dependency preparation"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(manifest["source_archive_max_bytes"] + 1)
    prepare(data, args.output.resolve())
    print(f"Prepared pinned imsg source with PersonaStack adapter revision {manifest['adapter_revision']}")


if __name__ == "__main__":
    main()
