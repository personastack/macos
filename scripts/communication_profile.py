#!/usr/bin/env python3
"""Require Apple's authorization before signing communication notifications."""

import base64
import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEAM = "5T2T8KL852"
APP_ID = TEAM + ".ai.personastack.desktop"
CAPABILITY = "com.apple.developer.usernotifications.communication"


def validate(profile, certificate, now):
    entitlements = profile.get("Entitlements", {})
    required = {
        "com.apple.application-identifier": APP_ID,
        "com.apple.developer.team-identifier": TEAM,
        CAPABILITY: True,
    }
    if any(entitlements.get(key) != value for key, value in required.items()):
        raise ValueError("profile must authorize this app, team, and Communication Notifications")
    if profile.get("TeamIdentifier") != [TEAM] or profile.get("ProvisionsAllDevices") is not True:
        raise ValueError("profile must authorize Developer ID distribution for the pinned team")
    if "OSX" not in profile.get("Platform", []) or entitlements.get("get-task-allow", False) is not False:
        raise ValueError("profile must be a macOS distribution profile without debugging access")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime) or expiry <= now:
        raise ValueError("communication notification profile is expired or has no expiry")
    if certificate not in profile.get("DeveloperCertificates", []):
        raise ValueError("profile does not authorize the pinned Developer ID certificate")


def read_profile(path):
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(path)], check=True, capture_output=True)
    profile = plistlib.loads(decoded.stdout)
    validate(profile, (ROOT / "Resources/ReleaseSigningCertificate.der").read_bytes(), datetime.datetime.utcnow())


def main():
    if sys.argv[1:] == ["prepare"]:
        encoded = os.environ.get("PERSONASTACK_COMMUNICATION_PROFILE_BASE64", "")
        if not encoded:
            raise ValueError("PERSONASTACK_COMMUNICATION_PROFILE_BASE64 must contain an Apple Developer ID profile with Communication Notifications enabled")
        path = pathlib.Path(os.environ["RUNNER_TEMP"]) / "communication.provisionprofile"
        path.write_bytes(base64.b64decode(encoded, validate=True))
        path.chmod(0o600)
        read_profile(path)
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write("PERSONASTACK_COMMUNICATION_PROFILE=" + str(path) + "\n")
        return
    if len(sys.argv) == 3 and sys.argv[1] == "embed":
        raw_path = os.environ.get("PERSONASTACK_COMMUNICATION_PROFILE", "")
        if not raw_path:
            raise ValueError("PERSONASTACK_COMMUNICATION_PROFILE is required before signing")
        path = pathlib.Path(raw_path)
        read_profile(path)
        bundle = pathlib.Path(sys.argv[2])
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "ai.personastack.desktop":
            raise ValueError("communication profile target does not match the app bundle")
        shutil.copyfile(path, bundle / "Contents/embedded.provisionprofile")
        return
    raise ValueError("usage: communication_profile.py prepare | embed APP_BUNDLE")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        # Never print decoded profile data, certificate bytes, or command output.
        print("Communication notification profile: " + str(error), file=sys.stderr)
        sys.exit(1)
