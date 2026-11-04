#!/usr/bin/env python3
"""Package verified Lima bytes. Signing belongs exclusively to sign-app.sh."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import tarfile
import tempfile
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
RELATIVE_ROOT = Path("Contents/Resources/LocalCluster/lima")
MANIFEST = "runtime-manifest.json"
EXECUTABLE = "bin/limactl"
FILES = {
    EXECUTABLE: (32685200, "6d32fb0f880c0ea750434f2ac855a3f2129126752a301ce4d88adbd2fa599e1e"),
    "share/lima/lima-guestagent.Linux-aarch64.gz": (7421099, "ed41b146a0aa9fb5e75d4b42d7af40c9ffb2cafadf4d8685762599e1960a72d7"),
    "share/doc/lima/LICENSE": (11358, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    "share/doc/lima/VERSION": (7, "51a76904570dfd01d966325f09cddf7ecc5f7608a65d6f4bf11d135bbb88ba0d"),
}


def artifact_pin():
    """The Go descriptor remains the single archive-version/URL/digest authority."""
    source = (ROOT / "agent-bridge/internal/localcluster/descriptor.go").read_text()
    match = re.search(r'\{Lima, "([^"]+)", "darwin", "arm64",\s*"([^"]+)",\s*"([a-f0-9]{64})", ([0-9]+),', source)
    if not match:
        raise ValueError("The source-owned ARM64 Lima descriptor is missing")
    version, url, sha256, size = match.groups()
    return {"version": version, "url": url, "sha256": sha256, "size": int(size)}


def digest(path, maximum):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise ValueError("Missing, linked or oversized Lima artifact")
    output = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            output.update(chunk)
    return output.hexdigest()


def bundle_root(app, create=False):
    app = Path(app).absolute()
    if app.suffix != ".app" or app.is_symlink() or not app.is_dir():
        raise ValueError("An existing app bundle is required")
    target = app
    for part in RELATIVE_ROOT.parts:
        target = target / part
        if target.is_symlink():
            raise ValueError("Linked runtime directories are forbidden")
        if create:
            target.mkdir(exist_ok=True)
        if not target.is_dir():
            raise ValueError("The bundled Lima runtime is missing")
    return target


class DownloadRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname not in {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"} or parsed.username or parsed.password:
            raise ValueError("Unsupported Lima artifact redirect")
        return super().redirect_request(request, response, code, message, headers, url)


def download(pin, destination):
    if pin["url"] != f'https://github.com/lima-vm/lima/releases/download/v{pin["version"]}/lima-{pin["version"]}-Darwin-arm64.tar.gz':
        raise ValueError("Unexpected Lima archive origin")
    opener = urllib.request.build_opener(DownloadRedirects())
    with opener.open(pin["url"], timeout=60) as response, destination.open("xb") as output:
        remaining = pin["size"] + 1
        while remaining:
            chunk = response.read(min(1 << 20, remaining))
            if not chunk:
                break
            output.write(chunk)
            remaining -= len(chunk)


def require_executable(path):
    with path.open("rb") as source:
        header = source.read(16)
    if len(header) != 16 or struct.unpack("<IIII", header) != (0xFEEDFACF, 0x0100000C, 0, 2):
        raise ValueError("Lima launcher must be a thin ARM64 Mach-O executable")


def prepare(app, archive):
    pin = artifact_pin()
    if not archive:
        with tempfile.TemporaryDirectory(prefix="personastack-lima-download-") as temporary:
            archive = Path(temporary) / "lima.tar.gz"
            download(pin, archive)
            return prepare(app, archive)
    archive = Path(archive)
    if archive.stat().st_size != pin["size"] or digest(archive, pin["size"]) != pin["sha256"]:
        raise ValueError("Lima archive does not match the source-owned descriptor")
    target = bundle_root(app, create=True)
    if any(target.iterdir()):
        raise ValueError("The bundled Lima destination must be empty")
    selected = {}
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            name = member.name.removeprefix("./")
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe Lima archive path")
            if name not in FILES:
                continue
            if name in selected or not member.isfile() or member.size != FILES[name][0]:
                raise ValueError("Invalid or duplicate Lima archive member")
            with source.extractfile(member) as input_file:
                data = input_file.read(member.size + 1)
            if len(data) != member.size or hashlib.sha256(data).hexdigest() != FILES[name][1]:
                raise ValueError("Lima member does not match the reviewed ARM64 runtime")
            selected[name] = data
    if set(selected) != set(FILES):
        raise ValueError("Lima archive lacks required runtime members")
    for name, data in selected.items():
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(0o755 if name == EXECUTABLE else 0o644)
    require_executable(target / EXECUTABLE)
    write_manifest(target, {"schema": 1, "artifact": pin, "sealed": False,
                            "files": {name: value[1] for name, value in FILES.items()}})


def write_manifest(target, manifest):
    path = target / MANIFEST
    if path.is_symlink():
        raise ValueError("Linked Lima runtime manifest is forbidden")
    path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    path.chmod(0o644)


def load_manifest(target):
    manifest_path = target / MANIFEST
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 16384:
        raise ValueError("Invalid Lima runtime manifest")
    return json.loads(manifest_path.read_text())


def verify(app, sealed=True):
    target = bundle_root(app)
    manifest = load_manifest(target)
    if set(manifest) != {"schema", "artifact", "sealed", "files"} or manifest["schema"] != 1 or manifest["artifact"] != artifact_pin() or manifest["sealed"] is not sealed or set(manifest["files"]) != set(FILES):
        raise ValueError("Lima runtime receipt does not match the source descriptor")
    paths = list(target.rglob("*"))
    if any(path.is_symlink() for path in paths) or {p.relative_to(target).as_posix() for p in paths if p.is_file()} != set(FILES) | {MANIFEST}:
        raise ValueError("Unexpected content in bundled Lima runtime")
    for name, (size, source_digest) in FILES.items():
        path = target / name
        recorded = manifest["files"][name]
        if not isinstance(recorded, str) or not re.fullmatch("[a-f0-9]{64}", recorded):
            raise ValueError("Invalid Lima member digest")
        if name != EXECUTABLE or not sealed:
            if recorded != source_digest or path.stat().st_size != size:
                raise ValueError("Lima resource differs from the reviewed archive")
        if digest(path, size + (1 << 20)) != recorded:
            raise ValueError("Bundled Lima resource failed integrity verification")
        if path.stat().st_mode & 0o777 != (0o755 if name == EXECUTABLE else 0o644):
            raise ValueError("Unexpected Lima resource permissions")
    require_executable(target / EXECUTABLE)
    return target, manifest


def seal(app):
    # codesign changes only limactl. Resource bytes must still match upstream.
    target = bundle_root(app)
    manifest = load_manifest(target)
    original = manifest["files"][EXECUTABLE]
    if original != FILES[EXECUTABLE][1] or manifest["sealed"] is not False:
        raise ValueError("Only a freshly prepared Lima runtime can be sealed")
    manifest["sealed"] = True
    manifest["files"][EXECUTABLE] = digest(target / EXECUTABLE, FILES[EXECUTABLE][0] + (1 << 20))
    write_manifest(target, manifest)
    verify(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "seal", "verify", "verify-unsigned"])
    parser.add_argument("app_bundle")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    if args.operation == "prepare":
        prepare(args.app_bundle, args.archive)
    elif args.operation == "seal":
        seal(args.app_bundle)
    else:
        verify(args.app_bundle, sealed=args.operation == "verify")


if __name__ == "__main__":
    main()
