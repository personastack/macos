#!/usr/bin/env python3
"""Seal a tag-release installer and verify its acceptance handoff."""

import argparse
import hashlib
import json
import re
from pathlib import Path


def validate_environment(environment):
    if not isinstance(environment, dict) or environment.get("can_admins_bypass") is not False:
        raise ValueError("Publication environment must disable administrator bypass")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list):
        raise ValueError("Publication environment must require a release-owner reviewer")
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("type") != "required_reviewers":
            continue
        reviewers = rule.get("reviewers")
        if not isinstance(reviewers, list) or not reviewers:
            continue
        if all(
            isinstance(entry, dict)
            and entry.get("type") in ("User", "Team")
            and isinstance(entry.get("reviewer"), dict)
            and type(entry["reviewer"].get("id")) is int
            and entry["reviewer"]["id"] > 0
            for entry in reviewers
        ):
            return
    raise ValueError("Publication environment must require a release-owner reviewer")


def candidate_manifest(directory, version, source_sha):
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise ValueError("Candidate version must be numeric semver")
    if re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("Candidate source must be the exact commit SHA")
    filename = f"PersonaStack-{version}-developerid.dmg"
    installer = directory / filename
    if not installer.is_file() or installer.is_symlink() or installer.stat().st_size == 0:
        raise ValueError("Finalized candidate installer is missing")
    digest = hashlib.sha256()
    with installer.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "schema_version": 1,
        "version": version,
        "source_sha": source_sha,
        "filename": filename,
        "sha256": digest.hexdigest(),
    }


def seal_candidate(directory, version, source_sha):
    manifest = candidate_manifest(directory, version, source_sha)
    (directory / "release-candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def verify_candidate(directory, version, source_sha, expected_sha256):
    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        raise ValueError("Prepare-job installer SHA-256 is required")
    stored = json.loads((directory / "release-candidate.json").read_text())
    actual = candidate_manifest(directory, version, source_sha)
    if stored != actual or actual["sha256"] != expected_sha256:
        raise ValueError("Candidate version, source or installer bytes changed after preparation")
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("environment", "seal", "verify"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--source-sha")
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    if args.operation == "environment":
        validate_environment(json.loads(args.path.read_text()))
        return
    if not args.version or not args.source_sha:
        parser.error("Candidate version and source SHA are required")
    if args.operation == "seal":
        result = seal_candidate(args.path, args.version, args.source_sha)
    else:
        result = verify_candidate(args.path, args.version, args.source_sha, args.expected_sha256 or "")
    print(result["sha256"])


if __name__ == "__main__":
    main()
