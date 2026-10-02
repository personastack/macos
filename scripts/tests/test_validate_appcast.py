import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-appcast.py"


class ValidateAppcastTests(unittest.TestCase):
    def run_validator(
        self,
        archive_url: Optional[str] = None,
        notes: Optional[str] = None,
        embedded_notes: Optional[str] = None,
        notes_format: str = "markdown",
        filename: Optional[str] = None,
        render_cask: bool = False,
        cask_url: Optional[str] = None,
        installation_type: str = "package",
        cask_artifact: str = 'pkg "Install PersonaStack.pkg"',
    ) -> subprocess.CompletedProcess[str]:
        version = "1.2.3"
        tap_tag = f"desktop-v{version}"
        filename = filename if filename is not None else f"PersonaStack-{version}-unsigned.dmg"
        expected_url = (
            f"https://raw.githubusercontent.com/personastack/homebrew-tap/"
            f"{tap_tag}/Downloads/{filename}"
        )
        dmg_bytes = b"fixture dmg bytes"
        digest = hashlib.sha256(dmg_bytes).hexdigest()
        notes = notes if notes is not None else f"# PersonaStack {version}\n\n## Fixes\n\n- Fixed update progress.\n"
        embedded_notes = embedded_notes if embedded_notes is not None else notes
        appcast = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <description sparkle:format="{notes_format}">{escape(embedded_notes)}</description>
      <enclosure url="{archive_url or expected_url}" length="{len(dmg_bytes)}"
                 sparkle:edSignature="fixture-signature" sparkle:installationType="{installation_type}" />
      <sparkle:version>{version}</sparkle:version>
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: fixture-feed-signature
-->
'''
        cask = f'''cask "personastack" do
  version "{version}"
  sha256 "{digest}"
  url "{cask_url or expected_url}"
  auto_updates true
  {cask_artifact}
end
'''

        with tempfile.TemporaryDirectory(prefix="personastack-appcast-test-") as temporary:
            fixture_dir = Path(temporary)
            appcast_path = fixture_dir / "appcast.xml"
            dmg_path = fixture_dir / filename
            cask_path = fixture_dir / "personastack.rb"
            notes_path = fixture_dir / "release-notes.md"
            appcast_path.write_text(appcast, encoding="utf-8")
            dmg_path.write_bytes(dmg_bytes)
            cask_path.write_text(cask, encoding="utf-8")
            if render_cask:
                subprocess.run([str(ROOT / "scripts/render-homebrew-cask.sh"), version,
                                str(dmg_path), str(cask_path)], check=True)
            notes_path.write_text(notes, encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    str(appcast_path),
                    version,
                    tap_tag,
                    str(dmg_path),
                    str(cask_path),
                    str(notes_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_exact_versioned_archive_url_and_cask_digest(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_certificate_signed_installer(self) -> None:
        result = self.run_validator(filename="PersonaStack-1.2.3-developerid.dmg", render_cask=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_application_update_that_skips_control_component(self) -> None:
        result = self.run_validator(installation_type="application")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("main package", result.stderr)

    def test_rejects_cask_that_only_copies_app(self) -> None:
        result = self.run_validator(cask_artifact='app "PersonaStack.app"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same main", result.stderr)

    def test_rejects_cask_selecting_a_different_installer(self) -> None:
        result = self.run_validator(cask_url="https://example.invalid/other.dmg")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_wrong_signing_kind_for_supplied_installer(self) -> None:
        result = self.run_validator(
            archive_url="https://raw.githubusercontent.com/personastack/homebrew-tap/desktop-v1.2.3/Downloads/PersonaStack-1.2.3-unsigned.dmg",
            filename="PersonaStack-1.2.3-developerid.dmg",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_ad_hoc_installer(self) -> None:
        result = self.run_validator(filename="PersonaStack-1.2.3-adhoc.dmg")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_untrusted_origin_with_matching_path_suffix(self) -> None:
        result = self.run_validator(
            "https://updates.example.invalid/homebrew-tap/desktop-v1.2.3/"
            "Downloads/PersonaStack-1.2.3-unsigned.dmg"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable tap artifact", result.stderr)

    def test_rejects_link_only_authored_notes(self) -> None:
        result = self.run_validator(notes="# PersonaStack 1.2.3\n\n- **Full Changelog**: https://github.com/example/compare/v1...v2\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not only links", result.stderr)

    def test_rejects_stale_embedded_notes(self) -> None:
        result = self.run_validator(embedded_notes="**Full Changelog**: https://github.com/example/compare/v1...v2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differ from the authored", result.stderr)

    def test_rejects_incorrect_markdown_format(self) -> None:
        result = self.run_validator(notes_format="plain-text")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use Markdown", result.stderr)

    def test_accepts_xml_sensitive_authored_notes(self) -> None:
        result = self.run_validator(notes="# PersonaStack 1.2.3\n\n- Fixed downloads & update notices when progress is < 100%.\n")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
