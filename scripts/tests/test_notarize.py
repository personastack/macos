"""Notarization must accept Apple's verdict before stapling release artifacts."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "notarize.sh"


class NotarizationTests(unittest.TestCase):
    def run_notarization(self, status="Accepted", submit_exit=0, staple_exit=0, extension="dmg"):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shim = root / "xcrun"
            shim.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['notarytool', 'submit']:
    print(json.dumps({'id': 'fixture-submission', 'status': os.environ['VERDICT']}))
    sys.exit(int(os.environ['SUBMIT_EXIT']))
if args[:2] == ['notarytool', 'log']:
    pathlib.Path(args[3]).write_text('{"issues": ["fixture rejection"]}')
if args[:2] == ['stapler', 'staple']:
    sys.exit(int(os.environ['STAPLE_EXIT']))
""")
            shim.chmod(0o755)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       PERSONASTACK_NOTARY_KEY_PATH=str(root / "fixture.p8"),
                       PERSONASTACK_NOTARY_KEY_ID="fixture-key",
                       PERSONASTACK_NOTARY_ISSUER_ID="fixture-issuer",
                       CALL_LOG=str(log), VERDICT=status,
                       SUBMIT_EXIT=str(submit_exit), STAPLE_EXIT=str(staple_exit))
            result = subprocess.run([str(SCRIPT), str(root / f"Fixture.{extension}")],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def test_accepted_submission_staples_and_validates(self):
        result, calls = self.run_notarization()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[:2] for c in calls],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])
        self.assertIn("--wait", calls[0])

    def test_main_package_is_submitted_and_stapled_without_repacking(self):
        result, calls = self.run_notarization(extension="pkg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls[0][2].endswith("Fixture.pkg"))
        self.assertEqual([call[:2] for call in calls],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])

    def test_rejected_submission_reads_log_without_stapling(self):
        result, calls = self.run_notarization(status="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[:2] for c in calls], [["notarytool", "submit"], ["notarytool", "log"]])
        self.assertIn("fixture rejection", result.stdout)

    def test_submission_error_cannot_staple(self):
        result, calls = self.run_notarization(submit_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_stapling_error_fails_release(self):
        result, calls = self.run_notarization(staple_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[:2] for c in calls], [["notarytool", "submit"], ["stapler", "staple"]])
