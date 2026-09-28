import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-appcast.py"


class ValidateAppcastTests(unittest.TestCase):
    def run_validator(self, archive_url: Optional[str] = None) -> subprocess.CompletedProcess[str]:
        version = "1.2.3"
        tap_tag = f"desktop-v{version}"
        filename = f"PersonaStack-{version}-unsigned.dmg"
        expected_url = (
            f"https://raw.githubusercontent.com/personastack/homebrew-tap/"
            f"{tap_tag}/Downloads/{filename}"
        )
        dmg_bytes = b"fixture dmg bytes"
        digest = hashlib.sha256(dmg_bytes).hexdigest()
        appcast = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <description>Release notes</description>
      <enclosure url="{archive_url or expected_url}" length="{len(dmg_bytes)}"
                 sparkle:edSignature="fixture-signature" />
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
  auto_updates true
end
'''

        with tempfile.TemporaryDirectory(prefix="personastack-appcast-test-") as temporary:
            fixture_dir = Path(temporary)
            appcast_path = fixture_dir / "appcast.xml"
            dmg_path = fixture_dir / filename
            cask_path = fixture_dir / "personastack.rb"
            appcast_path.write_text(appcast, encoding="utf-8")
            dmg_path.write_bytes(dmg_bytes)
            cask_path.write_text(cask, encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    str(appcast_path),
                    version,
                    tap_tag,
                    str(dmg_path),
                    str(cask_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_exact_versioned_archive_url_and_cask_digest(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_untrusted_origin_with_matching_path_suffix(self) -> None:
        result = self.run_validator(
            "https://updates.example.invalid/homebrew-tap/desktop-v1.2.3/"
            "Downloads/PersonaStack-1.2.3-unsigned.dmg"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable tap artifact", result.stderr)


if __name__ == "__main__":
    unittest.main()
