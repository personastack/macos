"""Inspect real package archives without installing or touching system policy."""

import importlib.util
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("package_appcast", ROOT / "scripts/render-package-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class PackageAppcastTests(unittest.TestCase):
    def test_package_update_preserves_older_items_and_authored_notes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "PersonaStack-1.2.3-developerid.dmg"
            archive.write_bytes(b"fixture archive")
            notes = root / "notes.md"
            notes.write_text("# PersonaStack 1.2.3\n\n## Fixes\n\n- Fixed Desktop Control installation.\n")
            output = root / "appcast.xml"
            output.write_text(f'<rss xmlns:sparkle="{appcast.SPARKLE}"><channel><item><sparkle:version>1.2.2</sparkle:version></item></channel></rss><!-- old signature -->')
            signature = base64.b64encode(bytes(64)).decode()
            appcast.render("1.2.3", archive, notes, signature, output)
            appcast.render("1.2.3", archive, notes, signature, output)
            items = ET.parse(output).findall(".//item")
            self.assertEqual([item.findtext(f"{{{appcast.SPARKLE}}}version") for item in items], ["1.2.3", "1.2.2"])
            enclosure = items[0].find("enclosure")
            self.assertEqual(enclosure.get(f"{{{appcast.SPARKLE}}}installationType"), "package")
            self.assertEqual(enclosure.get("length"), str(archive.stat().st_size))
            self.assertEqual(items[0].findtext("description"), notes.read_text().strip())
            self.assertNotIn("old signature", output.read_text())


@unittest.skipUnless(sys.platform == "darwin", "requires macOS package tools")
class DesktopInstallerTests(unittest.TestCase):
    def test_unsigned_main_package_has_only_app_in_applications_and_no_policy_scripts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "PersonaStack.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "ai.personastack.desktop", "CFBundleShortVersionString": "1.2.3",
                              "CFBundleVersion": "1.2.3", "CFBundleExecutable": "PersonaStack", "CFBundlePackageType": "APPL"}, file)
            binary = app / "Contents/MacOS/PersonaStack"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            output = root / "Install PersonaStack.pkg"
            env = {key: value for key, value in os.environ.items() if not key.startswith("PERSONASTACK_")}
            env["PERSONASTACK_INCLUDE_LOCKED_CONTROL"] = "0"
            result = subprocess.run([str(ROOT / "scripts/package-desktop-installer.sh"), str(app), str(root / "unused-tool"), str(output)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            expanded = root / "expanded"
            subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(output), str(expanded)], check=True, capture_output=True)
            distribution = ET.parse(expanded / "Distribution")
            self.assertEqual(distribution.findtext("title"), "PersonaStack")
            self.assertEqual(distribution.find("domains").get("enable_currentUserHome"), "false")
            self.assertEqual(distribution.find("volume-check/allowed-os-versions/os-version").get("min"), "14.0")
            self.assertEqual(distribution.find("pkg-ref/must-close/app").get("id"), "ai.personastack.desktop")
            packages = list(expanded.glob("**/PackageInfo"))
            self.assertEqual(len(packages), 1)
            package = ET.parse(packages[0]).getroot()
            self.assertEqual(package.get("identifier"), "ai.personastack.desktop")
            self.assertIsNone(package.find("scripts"))
            self.assertFalse(list(package.find("relocate")), ET.tostring(package, encoding="unicode"))
            self.assertTrue(list(expanded.glob("**/Payload/Applications/PersonaStack.app/Contents/MacOS/PersonaStack")))
            self.assertFalse(list(expanded.glob("**/Library/Security/**")))
            result = subprocess.run([str(ROOT / "scripts/package-desktop-installer.sh"), str(app), str(root / "unused-tool"), str(output)],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to replace", result.stderr)

    def test_missing_signing_identity_fails_before_packaging_privileged_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "PersonaStack.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, file)
            env = {key: value for key, value in os.environ.items() if not key.startswith("PERSONASTACK_")}
            output = root / "Install PersonaStack.pkg"
            result = subprocess.run([str(ROOT / "scripts/package-desktop-installer.sh"), str(app), "/missing/policy-tool", str(output)],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Developer ID Installer identity is required", result.stderr)
            self.assertFalse(output.exists())
