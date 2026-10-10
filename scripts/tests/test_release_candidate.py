"""Offline acceptance/publication handoff fixtures. No signing or GitHub calls."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_candidate", ROOT / "scripts/release_candidate.py")
CANDIDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CANDIDATE)


class ReleaseCandidateTests(unittest.TestCase):
    def test_only_protected_release_owner_review_allows_signing(self):
        valid = {
            "can_admins_bypass": False,
            "protection_rules": [{"type": "required_reviewers", "reviewers": [
                {"type": "User", "reviewer": {"id": 42}}
            ]}],
        }
        CANDIDATE.validate_environment(valid)
        invalid = [None, {}, {**valid, "can_admins_bypass": True},
                   {**valid, "protection_rules": []}]
        for reviewers in ([], None, [None], [{"type": "User", "reviewer": {"id": 0}}],
                          [{"type": "User", "reviewer": {"id": True}}],
                          [{"type": "Unknown", "reviewer": {"id": 42}}]):
            value = copy.deepcopy(valid)
            value["protection_rules"][0]["reviewers"] = reviewers
            invalid.append(value)
        for value in invalid:
            with self.subTest(environment=value), self.assertRaises(ValueError):
                CANDIDATE.validate_environment(value)

    def test_exact_signed_bytes_survive_acceptance_handoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            installer = directory / "PersonaStack-1.2.3-developerid.dmg"
            installer.write_bytes(b"finalized signed installer fixture")
            manifest = CANDIDATE.seal_candidate(directory, "1.2.3", "a" * 40)
            self.assertEqual(CANDIDATE.verify_candidate(directory, "1.2.3", "a" * 40,
                                                       manifest["sha256"]), manifest)
            self.assertEqual(installer.read_bytes(), b"finalized signed installer fixture")
            for version, source, digest in (("1.2.4", "a" * 40, manifest["sha256"]),
                                            ("1.2.3", "b" * 40, manifest["sha256"]),
                                            ("1.2.3", "a" * 40, "b" * 64)):
                with self.subTest(version=version, source=source, digest=digest), self.assertRaises((ValueError, FileNotFoundError)):
                    CANDIDATE.verify_candidate(directory, version, source, digest)
            installer.write_bytes(b"changed installer")
            with self.assertRaises(ValueError):
                CANDIDATE.verify_candidate(directory, "1.2.3", "a" * 40, manifest["sha256"])
            replacement = CANDIDATE.seal_candidate(directory, "1.2.3", "a" * 40)
            with self.assertRaises(ValueError):
                CANDIDATE.verify_candidate(directory, "1.2.3", "a" * 40, manifest["sha256"])
            self.assertNotEqual(replacement["sha256"], manifest["sha256"])

    def test_unknown_manifest_fields_and_missing_artifact_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(ValueError):
                CANDIDATE.seal_candidate(directory, "1.2.3", "a" * 40)
            installer = directory / "PersonaStack-1.2.3-developerid.dmg"
            installer.write_bytes(b"signed fixture")
            manifest = CANDIDATE.seal_candidate(directory, "1.2.3", "a" * 40)
            (directory / "release-candidate.json").write_text(json.dumps({**manifest, "unknown": True}))
            with self.assertRaises(ValueError):
                CANDIDATE.verify_candidate(directory, "1.2.3", "a" * 40, manifest["sha256"])
            for version, source in (("../1.2.3", "a" * 40), ("1.2.3", "main")):
                with self.subTest(version=version, source=source), self.assertRaises(ValueError):
                    CANDIDATE.seal_candidate(directory, version, source)

    def test_dispatch_stays_unsigned_and_publication_uses_sealed_artifact(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        prepare, publish = workflow.split("\n  publish:\n", 1)
        self.assertIn("concurrency:\n  group:", prepare)
        self.assertIn("queue: max", prepare)
        self.assertIn("needs: prepare", publish)
        self.assertIn("environment: macos-release-publication", publish)
        self.assertIn("artifact-ids: ${{ needs.prepare.outputs.artifact_id }}", publish)
        self.assertIn("--expected-sha256", publish)
        self.assertIn("cmp artifacts/release-notes.md", publish)
        self.assertNotIn("package-macos.sh", publish)
        self.assertNotIn("import-release-signing.sh", publish)
        self.assertLess(prepare.index("Require protected publication handoff"),
                        prepare.index("Import pinned release signing identity"))
        self.assertLess(publish.index("Verify exact accepted candidate"), publish.index("Publish GitHub release"))
        tag_gate = "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"
        for name in ("Import pinned release signing identity", "Configure Apple notarization",
                     "Build certificate-signed installer", "Retain immutable signed candidate"):
            section = prepare.split("      - name: " + name, 1)[1].split("      - name:", 1)[0]
            self.assertIn(tag_gate, section)
        self.assertIn(tag_gate, publish)
        self.assertNotIn("Publish GitHub release", prepare)


if __name__ == "__main__":
    unittest.main()
