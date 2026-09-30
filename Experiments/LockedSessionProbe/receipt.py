"""Bind a deny-only diagnostic to its source and inspect a dedicated-Mac log export.

An invocation receipt is not unlock, lock-state, consent or eligibility proof.
No authorization request, policy change or helper installation occurs here.
"""

import argparse
from datetime import datetime
from datetime import timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import stat
import subprocess
import uuid

BUILD_VERSION = "2"
SOURCES = (
    "AuthorizationProbe.c", "AuthorizationProbeTests.c", "ProbeActions.c",
    "ProbeActions.h", "ProbeActionsTests.c", "ProbeIdentity.h", "README.md",
    "build.sh", "policy.py", "receipt.py", "test_policy.py", "test_receipt.py",
)
BINARY = "PersonaStackLockedSessionProbe.bundle/Contents/MacOS/PersonaStackLockedSessionProbe"
ARTIFACTS = (
    "personastack-locked-session-probe", BINARY,
    "PersonaStackLockedSessionProbe.bundle/Contents/Info.plist",
    "PersonaStackLockedSessionProbe.bundle/Contents/_CodeSignature/CodeResources",
    "policy.py", "receipt.py", "README.md", "probe-right.plist",
)
HOST = "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/authorizationhost.bundle/Contents/MacOS/authorizationhost"
SENDERS = tuple(f"/Library/Security/SecurityAgentPlugins/{prefix}{BINARY}" for prefix in ("", "StagedPlugins/"))
SUBSYSTEM = "ai.personastack.locked-session-probe"
HEX = re.compile(r"[0-9a-f]{64}")
MESSAGE = re.compile(r"event=([a-z_]+) build_id=([0-9a-f]{64}) instance=([0-9a-f-]{36}) mechanism=([0-9]{1,20})")
EVENTS = {"plugin_loaded", "mechanism_created", "mechanism_invoked", "denial_returned",
          "decision_delivery_failed", "deactivated", "destroyed"}
MAX_BINARY = 2 * 1024 * 1024
MAX_JSON = 4 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bounded_read(path, limit):
    with Path(path).open("rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("input exceeds its bounded size")
    return data


def source_hashes(directory):
    return {name: digest(bounded_read(Path(directory) / name, MAX_BINARY)) for name in SOURCES}


def source_identity(hashes):
    if type(hashes) is not dict or set(hashes) != set(SOURCES):
        raise ValueError("unexpected source inventory")
    if any(type(value) is not str or HEX.fullmatch(value) is None for value in hashes.values()):
        raise ValueError("invalid source hash")
    return digest(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode())


def manifest(directory, kit, expected):
    hashes = source_hashes(directory)
    if source_identity(hashes) != expected:
        raise ValueError("source changed during the build")
    revision = None
    result = subprocess.run(["git", "-C", str(directory), "status", "--porcelain", "--", "."],
                            capture_output=True, text=True, timeout=5, check=False)
    if result.returncode == 0 and not result.stdout:
        result = subprocess.run(["git", "-C", str(directory), "rev-parse", "HEAD"],
                                capture_output=True, text=True, timeout=5, check=False)
        if result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}\n?", result.stdout):
            revision = result.stdout.strip()
    return {"schema": 1, "build_version": BUILD_VERSION, "build_id": expected,
            "source_revision": revision, "source_sha256": hashes,
            "purpose": "deny-only invocation diagnostic; does not unlock",
            "identity": "development ad-hoc; no Developer ID", "sender_uuids": binary_uuids(Path(kit) / BINARY),
            "sha256": {name: digest(bounded_read(Path(kit) / name, MAX_BINARY)) for name in ARTIFACTS}}


def binary_uuids(path):
    result = subprocess.run(["/usr/bin/dwarfdump", "--uuid", str(path)],
                            capture_output=True, text=True, timeout=5, check=False)
    if result.returncode != 0:
        raise ValueError("cannot inspect diagnostic image UUIDs")
    identities = {}
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"UUID: ([0-9A-Fa-f-]{36}) \((arm64|x86_64)\) .+", line)
        if match is None or match[2] in identities:
            raise ValueError("unexpected diagnostic image inventory")
        identities[match[2]] = str(uuid.UUID(match[1]))
    if set(identities) != {"arm64", "x86_64"} or len(set(identities.values())) != 2:
        raise ValueError("both diagnostic image UUIDs are required")
    return identities


def decode_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON field")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique)
    except (json.JSONDecodeError, UnicodeDecodeError, RecursionError) as error:
        raise ValueError("invalid bounded JSON input") from error


def read_json(path):
    return decode_json(bounded_read(path, MAX_JSON))


def verify_manifest(document, kit):
    if type(document) is not dict or type(document.get("schema")) is not int or document.get("schema") != 1 or document.get("build_version") != BUILD_VERSION:
        raise ValueError("unsupported diagnostic manifest")
    identity = source_identity(document.get("source_sha256"))
    if document.get("build_id") != identity:
        raise ValueError("manifest source identity mismatch")
    revision = document.get("source_revision")
    if type(revision) is not str or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("a clean committed source revision is required")
    identities = document.get("sender_uuids")
    if type(identities) is not dict or set(identities) != {"arm64", "x86_64"}:
        raise ValueError("both diagnostic image UUIDs are required")
    if any(type(value) is not str or str(uuid.UUID(value)) != value for value in identities.values()):
        raise ValueError("invalid diagnostic image UUID")
    if len(set(identities.values())) != 2:
        raise ValueError("ambiguous diagnostic image UUIDs")
    expected = document.get("sha256")
    if type(expected) is not dict or set(expected) != set(ARTIFACTS):
        raise ValueError("unexpected diagnostic artifact inventory")
    for name in ARTIFACTS:
        if type(expected[name]) is not str or HEX.fullmatch(expected[name]) is None:
            raise ValueError("invalid diagnostic artifact hash")
        if digest(bounded_read(Path(kit) / name, MAX_BINARY)) != expected[name]:
            raise ValueError("diagnostic artifact hash mismatch")
    return document


def parse_event(record, document):
    if type(record) is not dict:
        raise ValueError("unexpected log record")
    if record.get("subsystem") != SUBSYSTEM or record.get("category") != "authorization":
        return None
    if record.get("processImagePath") != HOST or record.get("senderImagePath") not in SENDERS:
        raise ValueError("unqualified authorization host or sender")
    pid = record.get("processID")
    if type(pid) is not int or not 0 < pid <= 2**31 - 1:
        raise ValueError("invalid authorization-host PID")
    message = record.get("eventMessage")
    match = MESSAGE.fullmatch(message) if type(message) is str else None
    if match is None or match[1] not in EVENTS or match[2] != document["build_id"]:
        raise ValueError("unknown, stale or mismatched diagnostic event")
    instance = str(uuid.UUID(match[3]))
    if instance != match[3]:
        raise ValueError("invalid plug-in instance identity")
    image = record.get("senderImageUUID")
    if type(image) is not str or str(uuid.UUID(image)) not in document["sender_uuids"].values():
        raise ValueError("loaded image UUID does not match this diagnostic")
    try:
        time = datetime.fromisoformat(record["timestamp"])
        if time.tzinfo is None:
            raise ValueError("missing timestamp timezone")
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("unqualified log timestamp") from error
    return (time.timestamp(), pid, record["senderImagePath"], instance, int(match[4]), match[1])


def inspect_events(records, document, start, end, require_load, verify_host, sender_hash):
    if type(records) is not list or len(records) > 4096:
        raise ValueError("expected a bounded JSON log array")
    if not math.isfinite(start) or not math.isfinite(end) or not 0 < end - start <= 120:
        raise ValueError("select a positive trial interval no longer than 120 seconds")
    groups = {}
    loaded = {}
    for record in records:
        event = parse_event(record, document)
        if event is None or not start <= event[0] <= end:
            continue
        group_event(event, groups, loaded)
    candidates = []
    for key, events in groups.items():
        events = sorted(events, key=lambda event: event[0])
        names = [name for _, name in events]
        if names != ["mechanism_created", "mechanism_invoked", "denial_returned"]:
            raise ValueError("incomplete, duplicated or mixed invocation sequence")
        if require_load and (key[:3] not in loaded or loaded[key[:3]] > events[0][0]):
            raise ValueError("the preflight does not establish this plug-in load")
        candidates.append(key)
    if len(candidates) != 1:
        raise ValueError("expected one unambiguous diagnostic invocation")
    pid, sender, instance, mechanism = candidates[0]
    verify_host(HOST)
    if sender_hash(sender) != document["sha256"][BINARY]:
        raise ValueError("loaded sender bytes do not match this artifact")
    return {"result": "matching_invocation_records", "build_id": document["build_id"],
            "source_revision": document["source_revision"], "host_pid": pid,
            "host_path": HOST, "sender_path": sender, "instance": instance, "mechanism": mechanism,
            "unlock_verified": False,
            "limitation": "Log correlation only. Operator must establish the trial context. No lock state, unlock, grant, privacy or eligibility is qualified."}


def group_event(event, groups, loaded):
    time, pid, sender, instance, mechanism, name = event
    if name == "decision_delivery_failed":
        raise ValueError("the diagnostic could not deliver its denial")
    if name == "plugin_loaded":
        if mechanism != 0 or (pid, sender, instance) in loaded:
            raise ValueError("invalid or duplicated load identity")
        loaded[(pid, sender, instance)] = time
    elif name in {"mechanism_created", "mechanism_invoked", "denial_returned"}:
        if mechanism == 0:
            raise ValueError("invalid mechanism identity")
        groups.setdefault((pid, sender, instance, mechanism), []).append((time, name))


def verify_apple_host(path):
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R",
                             '=anchor apple and identifier "com.apple.authorizationhost"', path],
                            capture_output=True, timeout=5, check=False)
    if result.returncode != 0:
        raise ValueError("the expected authorization host does not pass Apple signature verification")


def installed_sender_hash(path):
    if path not in SENDERS:
        raise ValueError("unexpected sender path")
    # O_NOFOLLOW_ANY is public macOS fcntl.h. Refuse redirected components.
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | 0x20000000)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("sender must be an installed root-owned non-writable regular executable")
        data = source.read(MAX_BINARY + 1)
    if len(data) > MAX_BINARY:
        raise ValueError("sender exceeds the bounded binary size")
    return digest(data)


def collect_logs(start, end):
    if not math.isfinite(start) or not math.isfinite(end) or not 0 < end - start <= 120:
        raise ValueError("select a positive trial interval no longer than 120 seconds")
    stamps = [datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%d %H:%M:%S+0000") for value in (start, end + 1)]
    command = ["/usr/bin/log", "show", "--style", "json", "--start", stamps[0], "--end", stamps[1],
               "--predicate", f'subsystem == "{SUBSYSTEM}" AND category == "authorization"']
    # Bounded scratch output avoids retaining an unbounded subprocess result.
    import tempfile
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run(command, stdout=output, stderr=errors, timeout=15, check=False,
            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_JSON, MAX_JSON)))
        if result.returncode != 0:
            raise ValueError("system log collection failed")
        output.seek(0)
        data = output.read(MAX_JSON + 1)
        if len(data) > MAX_JSON:
            raise ValueError("system log export exceeds its bounded size")
    return decode_json(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    identity = commands.add_parser("identity")
    identity.add_argument("source")
    commands.add_parser("version")
    build = commands.add_parser("manifest")
    build.add_argument("source")
    build.add_argument("kit")
    build.add_argument("identity")
    inspect = commands.add_parser("inspect")
    inspect.add_argument("--kit", required=True)
    inspect.add_argument("--start", type=float, required=True)
    inspect.add_argument("--end", type=float, required=True)
    inspect.add_argument("--require-load", action="store_true")
    inspect.add_argument("--dedicated-mac", action="store_true", required=True)
    args = parser.parse_args()
    try:
        if args.action == "identity":
            print(source_identity(source_hashes(args.source)))
        elif args.action == "version":
            print(BUILD_VERSION)
        elif args.action == "manifest":
            document = manifest(args.source, args.kit, args.identity)
            path = Path(args.kit) / "SOURCE.json"
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "w") as output:
                json.dump(document, output, indent=2, sort_keys=True)
                output.write("\n")
        else:
            document = verify_manifest(read_json(Path(args.kit) / "SOURCE.json"), args.kit)
            result = inspect_events(collect_logs(args.start, args.end), document, args.start, args.end,
                                    args.require_load, verify_apple_host, installed_sender_hash)
            result["result"] = "exact_probe_invocation"
            result["collection"] = "direct dedicated-Mac system log"
            print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Diagnostic receipt remains unqualified: {type(error).__name__}.\n")


if __name__ == "__main__":
    main()
