import copy
import importlib.util
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("published_release", ROOT / "scripts/verify-published-release.py")
published = importlib.util.module_from_spec(spec)
spec.loader.exec_module(published)


class PublishedReleaseTests(unittest.TestCase):
    def test_public_release_requires_exact_identity_notes_and_assets(self):
        notes = "# PersonaStack 1.2.3\n\n- Fixed avatar routing.\n"
        valid = {"tag_name": "v1.2.3", "draft": False, "prerelease": False, "body": notes,
                 "assets": [{"name": "PersonaStack-1.2.3-developerid.dmg"}]}
        assets = {"PersonaStack-1.2.3-developerid.dmg"}
        published.verify_release(valid, "v1.2.3", notes, assets)
        for key, value in [("tag_name", "v1.2.2"), ("draft", True), ("prerelease", True),
                           ("body", "stale changelog"), ("assets", [])]:
            with self.subTest(key=key):
                invalid = copy.deepcopy(valid)
                invalid[key] = value
                with self.assertRaises(ValueError):
                    published.verify_release(invalid, "v1.2.3", notes, assets)

    def test_installer_readback_rejects_replaced_or_truncated_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "published.dmg"
            source = b"immutable signed CI installer"
            digest = hashlib.sha256(source).hexdigest()
            path.write_bytes(source)
            published.verify_installer(path, digest, len(source))
            for changed in [source[:-1], b"x" * len(source)]:
                path.write_bytes(changed)
                with self.assertRaises(ValueError):
                    published.verify_installer(path, digest, len(source))

    def test_archive_and_feed_verification_pipe_key_without_argument_exposure(self):
        with patch.object(published.subprocess, "run") as run:
            run.return_value.returncode = 0
            published.verify_signature("/pinned/sign_update", Path("archive.dmg"), "private-fixture", "archive-signature")
            self.assertEqual(run.call_args.args[0], ["/pinned/sign_update", "--ed-key-file", "-", "--verify", "archive.dmg", "archive-signature"])
            self.assertEqual(run.call_args.kwargs["input"], "private-fixture")
            run.return_value.returncode = 1
            with self.assertRaises(ValueError):
                published.verify_signature("/pinned/sign_update", Path("appcast.xml"), "private-fixture")
            self.assertNotIn("private-fixture", run.call_args.args[0])
