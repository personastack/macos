import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "release_notes.py"


class ReleaseNotesTests(unittest.TestCase):
    def test_cli_checks_authored_content(self) -> None:
        cases = [
            ("# PersonaStack 1.2.3\n\n- Fixed update progress.\n", True),
            ("# PersonaStack 1.2.3\n\n- Fixed update progress.\n\n[Full Changelog](https://github.com/example/compare/v1...v2)", True),
            ("", False),
            ("# PersonaStack 1.2.3\n", False),
            ("# PersonaStack 1.2.4\n\n- Fixed update progress.\n", False),
            ("# PersonaStack 1.2.3\n\n**Full Changelog**: https://github.com/example/compare/v1...v2", False),
            ("# PersonaStack 1.2.3\n\n- [Full Changelog](https://github.com/example/compare/v1...v2)", False),
            ("# PersonaStack 1.2.3\n\n- **Full Changelog**: https://github.com/example/compare/v1...v2", False),
            ("# PersonaStack 1.2.3\n\n- https://github.com/example/compare/v1...v2", False),
        ]
        with tempfile.TemporaryDirectory(prefix="personastack-notes-test-") as temporary:
            notes_path = Path(temporary) / "notes.md"
            for notes, valid in cases:
                with self.subTest(notes=notes):
                    notes_path.write_text(notes, encoding="utf-8")
                    result = subprocess.run([sys.executable, str(VALIDATOR), "1.2.3", str(notes_path)],
                                            check=False, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_cli_rejects_missing_notes_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="personastack-notes-test-") as temporary:
            result = subprocess.run([sys.executable, str(VALIDATOR), "1.2.3", str(Path(temporary) / "missing.md")],
                                    check=False, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_tag_renders_version_and_date_from_authored_change_notes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="personastack-notes-test-") as temporary:
            source, output = Path(temporary) / "next.md", Path(temporary) / "1.2.3.md"
            source.write_text("## Fixed\n\n- Keep avatar clicks in the app.\n")
            subprocess.run([sys.executable, str(VALIDATOR), "render", "1.2.3", "2026-10-11", str(source), str(output)], check=True)
            self.assertEqual(output.read_text(), "# PersonaStack 1.2.3\n\nRelease date: 2026-10-11\n\n## Fixed\n\n- Keep avatar clicks in the app.\n")
            for body, version, date in [("", "1.2.3", "2026-10-11"),
                                        ("## Fixed\n- https://example.invalid/compare", "1.2.3", "2026-10-11"),
                                        ("# PersonaStack 1.2.3\n- Fixed avatar routing.", "1.2.3", "2026-10-11"),
                                        ("## Fixed\n- Fixed avatar routing.", "../1.2.3", "2026-10-11"),
                                        ("## Fixed\n- Fixed avatar routing.", "1.2.3", "invalid")]:
                with self.subTest(body=body, version=version, date=date):
                    source.write_text(body)
                    result = subprocess.run([sys.executable, str(VALIDATOR), "render", version, date, str(source), str(output)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
