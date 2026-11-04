#!/usr/bin/env python3
"""Build and bundle the pinned ARM64 provider. This script never signs or publishes."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import struct
import sys
import tempfile

from prepare import ROOT, prepare
import urllib.request

TRIPLE = "arm64-apple-macosx14.0"
RECEIPT_NAME = "imsg-provider-manifest.json"
RESOURCE_STEMS = {"PhoneNumberKit_PhoneNumberKit", "SQLite.swift_SQLite"}
MAX_RECEIPT = 256 << 10
MAX_RESOURCE_BYTES = 32 << 20
MAX_EXECUTABLE_BYTES = 128 << 20
MAX_NOTICE_BYTES = 32 << 10
MAX_NOTICES_BYTES = 64 << 10
NOTICE_SOURCES = {
    "imsg-MIT-LICENSE.txt": "LICENSE",
    "imsg-PhoneNumberKit-MIT-LICENSE.txt": "licenses/PhoneNumberKit-MIT-LICENSE.txt",
    "imsg-SQLite.swift-MIT-LICENSE.txt": "licenses/SQLite.swift-MIT-LICENSE.txt",
    "imsg-libphonenumber-APACHE-LICENSE.txt": "licenses/libphonenumber-APACHE-LICENSE.txt",
}


def digest(path, maximum):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise ValueError("Provider artifact is missing, linked or oversized")
    output = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            output.update(chunk)
    return output.hexdigest()


def manifest():
    return json.loads((ROOT / "manifest.json").read_text())


def pinned_notices(pin):
    declared = pin.get("notices")
    if not isinstance(declared, dict) or set(declared) != set(NOTICE_SOURCES):
        raise ValueError("Provider notice source identities do not match the fixed set")
    if (ROOT / "licenses").is_symlink():
        raise ValueError("Provider notice source directory is linked")
    notices = {}
    total = 0
    for name, relative in NOTICE_SOURCES.items():
        entry = declared[name]
        if not isinstance(entry, dict) or entry.get("path") != relative:
            raise ValueError("Provider notice source path changed")
        expected = entry.get("sha256")
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError("Provider notice source digest is invalid")
        source = ROOT / relative
        actual = digest(source, MAX_NOTICE_BYTES)
        size = source.stat().st_size
        total += size
        if size == 0 or total > MAX_NOTICES_BYTES:
            raise ValueError("Provider notice source budget exceeded")
        if actual != expected:
            raise ValueError("Provider notice source digest mismatch")
        notices[name] = (source, actual)
    return notices


def app_paths(app):
    app = Path(app).absolute()
    if app.is_symlink() or app.suffix != ".app" or not app.is_dir():
        raise ValueError("A trusted existing application bundle is required")
    contents = app / "Contents"
    if contents.is_symlink() or not contents.is_dir():
        raise ValueError("Application Contents directory is missing or linked")
    for name in ["MacOS", "Resources"]:
        target = contents / name
        if target.is_symlink() or not target.is_dir():
            raise ValueError("Application bundle directories are missing or linked")
    return app, contents / "MacOS", contents / "Resources"


def resource_fingerprints(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Provider resource directory is missing or linked")
    files = []
    total = 0
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError("SwiftPM resource symlinks are not supported")
        if path.is_dir():
            continue
        relative = path.relative_to(directory).as_posix()
        if len(relative) > 1024 or path.suffix in {".dylib", ".so"} or "MacOS" in PurePosixPath(relative).parts:
            raise ValueError("Unexpected executable content in provider resources")
        total += path.stat().st_size
        if total > MAX_RESOURCE_BYTES or len(files) >= 128:
            raise ValueError("Provider resource budget exceeded")
        files.append({"path": relative, "sha256": digest(path, MAX_RESOURCE_BYTES)})
    return files


def require_arm64_executable(path):
    digest(path, MAX_EXECUTABLE_BYTES)
    with path.open("rb") as source:
        header = source.read(8)
    if len(header) != 8 or struct.unpack("<II", header) != (0xFEEDFACF, 0x0100000C):
        raise ValueError("Provider must be a thin ARM64 macOS executable")


def resource_name(name):
    if not isinstance(name, str):
        raise ValueError("Invalid provider resource name")
    path = PurePosixPath(name)
    if len(path.parts) != 1 or path.stem not in RESOURCE_STEMS or path.suffix not in {".bundle", ".resources"}:
        raise ValueError("Invalid provider resource identity")
    return path


def resource_snapshot(path):
    identity = resource_name(path.name)
    files = resource_fingerprints(path)
    if identity.stem == "PhoneNumberKit_PhoneNumberKit":
        if not any(PurePosixPath(item["path"]).name == "PhoneNumberMetadata.json" for item in files):
            raise ValueError("PhoneNumberKit metadata resource is missing")
    return files


def require_resource_set(names):
    identities = [resource_name(name).stem for name in names]
    if not 1 <= len(identities) <= 2 or len(set(identities)) != len(identities):
        raise ValueError("Invalid or duplicate provider resource identities")
    if "PhoneNumberKit_PhoneNumberKit" not in identities:
        raise ValueError("PhoneNumberKit resource bundle is missing")


def collect_resources(product_dir):
    resources = []
    for path in sorted(Path(product_dir).iterdir()):
        if path.suffix not in {".bundle", ".resources"}:
            continue
        resources.append((path, resource_snapshot(path)))
    require_resource_set([path.name for path, _ in resources])
    return resources


def install_artifacts(app, product_dir, swift_version):
    _, macos, resources = app_paths(app)
    source = Path(product_dir) / "imsg"
    require_arm64_executable(source)
    executable_hash = digest(source, MAX_EXECUTABLE_BYTES)
    resource_sources = collect_resources(product_dir)
    pin = manifest()
    notices = pinned_notices(pin)
    notice_hashes = {name: value[1] for name, value in notices.items()}
    record = {
        "schema_version": 1,
        "adapter_revision": pin["adapter_revision"],
        "upstream_commit": pin["upstream_commit"],
        "source_archive_sha256": pin["source_archive_sha256"],
        "patches": pin["patches"],
        "target_triple": TRIPLE,
        "swift_version": swift_version,
        "unsigned_executable_sha256": executable_hash,
        "executable_sha256": executable_hash,
        "signing_state": "unsigned",
        "resources": [{"name": path.name, "files": files} for path, files in resource_sources],
        "license_sha256": notice_hashes["imsg-MIT-LICENSE.txt"],
        "notices_sha256": notice_hashes,
    }
    encoded = json.dumps(record, indent=2, sort_keys=True) + "\n"
    if len(encoded.encode()) > MAX_RECEIPT:
        raise ValueError("Provider receipt budget exceeded")
    if any(path.name not in notices for path in resources.glob("imsg-*.txt")):
        raise ValueError("Unknown provider notice destination")
    destinations = [macos / "imsg", resources / RECEIPT_NAME, resources / "imsg-source-manifest.json"]
    destinations += [resources / name for name in notices]
    destinations += [parent / path.name for path, _ in resource_sources for parent in [macos, resources]]
    if any(path.exists() or path.is_symlink() for path in destinations):
        raise ValueError("Provider bundle destination already exists")
    # This destination is an explicitly supplied build artifact, never source or
    # a running app. Validate all source artifacts before changing it.
    shutil.copyfile(source, macos / "imsg")
    (macos / "imsg").chmod(0o755)
    for path, _ in resource_sources:
        destination = resources / path.name
        shutil.copytree(path, destination)
        alias = macos / path.name
        alias.symlink_to(Path("..") / "Resources" / path.name, target_is_directory=True)
    for name, (source_notice, _) in notices.items():
        shutil.copyfile(source_notice, resources / name)
    shutil.copyfile(ROOT / "manifest.json", resources / "imsg-source-manifest.json")
    (resources / RECEIPT_NAME).write_text(encoded)
    return record


def checked_receipt_object(resources):
    path = resources / RECEIPT_NAME
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_RECEIPT:
        raise ValueError("Provider receipt is missing, linked or oversized")
    record = json.loads(path.read_text())
    if not isinstance(record, dict):
        raise ValueError("Invalid provider receipt object")
    return record


def verify_receipt_pin(record):
    pin = manifest()
    expected = {"schema_version": 1, "adapter_revision": pin["adapter_revision"],
                "upstream_commit": pin["upstream_commit"],
                "source_archive_sha256": pin["source_archive_sha256"],
                "patches": pin["patches"], "target_triple": TRIPLE}
    if any(record.get(key) != value for key, value in expected.items()):
        raise ValueError("Provider receipt does not match the pinned source")
    for field in ["unsigned_executable_sha256", "executable_sha256"]:
        value = record.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError("Invalid provider executable digest")
    if record.get("signing_state") not in {"unsigned", "sealed"}:
        raise ValueError("Invalid provider signing receipt state")


def verify_resource_entry(entry, macos, resources):
    if not isinstance(entry, dict) or set(entry) != {"name", "files"}:
        raise ValueError("Invalid provider resource entry")
    name = entry["name"]
    resource_name(name)
    if entry["files"] != resource_snapshot(resources / name):
        raise ValueError("Provider resources changed after bundling")
    alias = macos / name
    if not alias.is_symlink() or os.readlink(alias) != "../Resources/" + name:
        raise ValueError("Provider resource alias changed")
    return name


def verify_resource_receipts(record, macos, resources):
    listed = record.get("resources")
    if not isinstance(listed, list) or not 1 <= len(listed) <= 2:
        raise ValueError("Invalid provider resource receipt")
    names = [verify_resource_entry(entry, macos, resources) for entry in listed]
    require_resource_set(names)


def verify_notice_files(record, resources):
    notices = pinned_notices(manifest())
    expected = {name: value[1] for name, value in notices.items()}
    if record.get("notices_sha256") != expected or record.get("license_sha256") != expected["imsg-MIT-LICENSE.txt"]:
        raise ValueError("Provider notice receipt does not match pinned sources")
    if {path.name for path in resources.glob("imsg-*.txt")} != set(expected):
        raise ValueError("Provider notice files do not match the fixed set")
    total = 0
    for name, expected_hash in expected.items():
        path = resources / name
        actual = digest(path, MAX_NOTICE_BYTES)
        total += path.stat().st_size
        if total > MAX_NOTICES_BYTES:
            raise ValueError("Provider notice budget exceeded")
        if actual != expected_hash:
            raise ValueError("Provider notice file changed")
    if digest(resources / "imsg-source-manifest.json", MAX_RECEIPT) != digest(ROOT / "manifest.json", MAX_RECEIPT):
        raise ValueError("Provider source manifest changed")


def read_receipt(app):
    _, macos, resources = app_paths(app)
    record = checked_receipt_object(resources)
    verify_receipt_pin(record)
    require_arm64_executable(macos / "imsg")
    verify_resource_receipts(record, macos, resources)
    verify_notice_files(record, resources)
    return record, macos, resources


def verify_existing(app, require_sealed=True):
    record, macos, _ = read_receipt(app)
    if require_sealed and record["signing_state"] != "sealed":
        raise ValueError("Provider artifact has not been sealed after signing")
    if digest(macos / "imsg", MAX_EXECUTABLE_BYTES) != record.get("executable_sha256"):
        raise ValueError("Provider executable changed after its recorded build/signing")
    return record


def seal_existing(app):
    record, macos, resources = read_receipt(app)
    # Caller runs codesign before this. Sealing records bytes, never asserts that
    # codesign or Gatekeeper validation passed. The parent's signature gate owns it.
    record["executable_sha256"] = digest(macos / "imsg", MAX_EXECUTABLE_BYTES)
    record["signing_state"] = "sealed"
    encoded = json.dumps(record, indent=2, sort_keys=True) + "\n"
    if len(encoded.encode()) > MAX_RECEIPT:
        raise ValueError("Provider receipt budget exceeded")
    (resources / RECEIPT_NAME).write_text(encoded)
    return record


def build_and_bundle(app, build_root, archive_path=None, runner=subprocess.run):
    app_paths(app)
    build_root = Path(build_root).absolute()
    if build_root.is_symlink():
        raise ValueError("Provider build root cannot be a symlink")
    build_root.mkdir(parents=True, exist_ok=True)
    swift = shutil.which("swift")
    if not swift:
        raise ValueError("Swift 6.2 is required on the build host")
    version = runner([swift, "--version"], check=True, capture_output=True, text=True).stdout
    match = re.search(r"Swift version (\d+)\.(\d+)", version)
    if not match or tuple(map(int, match.groups())) < (6, 2) or len(version.encode()) > 16 << 10:
        raise ValueError("Swift 6.2 or newer is required")
    pin = manifest()
    if archive_path:
        data = Path(archive_path).read_bytes()
    else:
        with urllib.request.urlopen(pin["source_archive_url"], timeout=30) as response:
            data = response.read(pin["source_archive_max_bytes"] + 1)
    # Each invocation owns a separate source and scratch directory. No workspace lock.
    with tempfile.TemporaryDirectory(prefix="imsg-arm64-", dir=build_root) as temporary:
        source = Path(temporary) / "source"
        scratch = Path(temporary) / "scratch"
        prepare(data, source)
        common = [swift, "build", "--package-path", str(source), "--scratch-path", str(scratch),
                  "--disable-automatic-resolution", "--triple", TRIPLE, "-c", "release"]
        runner(common + ["--product", "imsg"], check=True)
        product_dir = runner(common + ["--show-bin-path"], check=True, capture_output=True, text=True).stdout.strip()
        output = Path(product_dir).resolve()
        if not output.is_relative_to(scratch.resolve()):
            raise ValueError("Swift product directory escaped the owned build root")
        return install_artifacts(app, output, version.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--archive", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--seal-existing", action="store_true")
    modes.add_argument("--verify-existing", action="store_true")
    args = parser.parse_args()
    try:
        if args.seal_existing:
            if args.build_root or args.archive:
                parser.error("Sealing accepts only --app-bundle")
            seal_existing(args.app_bundle)
        elif args.verify_existing:
            if args.build_root or args.archive:
                parser.error("Verification accepts only --app-bundle")
            verify_existing(args.app_bundle)
        else:
            if not args.build_root:
                parser.error("Building requires --build-root")
            build_and_bundle(args.app_bundle, args.build_root, args.archive)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("iMessage provider bundle failed: " + str(error), file=sys.stderr)
        return 1
    print("iMessage provider bundle operation completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
