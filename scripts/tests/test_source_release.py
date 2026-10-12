"""Source release creation and GitHub UI handoff without network calls."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("source_release", Path(__file__).resolve().parents[1] / "publish-source-release.py")
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)


class SourceReleaseTests(unittest.TestCase):
    def test_existing_release_requires_empty_matching_stable_release(self):
        release = {"tag_name": "v1.2.3", "draft": False, "prerelease": False, "assets": []}
        SOURCE.validate_existing(release, "v1.2.3")
        for change in ({"tag_name": "v1.2.2"}, {"draft": True}, {"prerelease": True},
                       {"assets": [{"name": "installer.dmg"}]}, {"assets": None}, {"draft": None}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                SOURCE.validate_existing({**release, **change}, "v1.2.3")

    def test_tag_creates_release_and_ui_release_receives_same_ci_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            installer = Path(temporary) / "PersonaStack-1.2.3-developerid.dmg"
            installer.write_bytes(b"immutable signed installer")
            notes = Path(temporary) / "notes.md"
            notes.write_text("authored notes")
            existing = {"tagName": "v1.2.3", "isDraft": False, "isPrerelease": False, "assets": []}
            for response, operations in ((subprocess.CompletedProcess([], 1, "", "release not found"), ["create"]),
                                         (subprocess.CompletedProcess([], 0, json.dumps(existing), ""), ["upload", "edit"])):
                with self.subTest(operations=operations), patch.object(SOURCE.subprocess, "run") as run:
                    run.side_effect = [response] + [subprocess.CompletedProcess([], 0)] * len(operations)
                    SOURCE.publish("1.2.3", installer, notes)
                    calls = [x.args[0] for x in run.call_args_list]
                    self.assertEqual([x[2] for x in calls[1:]], operations)
                    self.assertTrue(all("--repo" in x and "personastack/macos" in x for x in calls))
                    self.assertIn(str(installer), calls[1])
                    self.assertIn(str(notes), calls[-1])
                    self.assertTrue(all("--clobber" not in x for x in calls))
                    self.assertEqual(installer.read_bytes(), b"immutable signed installer")

    def test_api_errors_or_existing_assets_make_no_publication_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            installer = Path(temporary) / "PersonaStack-1.2.3-developerid.dmg"
            installer.write_bytes(b"signed installer")
            notes = Path(temporary) / "notes.md"
            notes.write_text("notes")
            existing = {"tagName": "v1.2.3", "isDraft": False, "isPrerelease": False, "assets": [{"name": installer.name}]}
            for response in (subprocess.CompletedProcess([], 1, "", "HTTP 403 forbidden"),
                             subprocess.CompletedProcess([], 0, json.dumps(existing), "")):
                with self.subTest(response=response), patch.object(SOURCE.subprocess, "run", return_value=response) as run:
                    with self.assertRaises(ValueError):
                        SOURCE.publish("1.2.3", installer, notes)
                    self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
