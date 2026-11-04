import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("imsg_prepare", ROOT / "prepare.py")
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


def archive_with(name, kind=tarfile.REGTYPE, data=b"source"):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        member = tarfile.TarInfo(name)
        member.type = kind
        if kind == tarfile.REGTYPE:
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        else:
            member.linkname = "/tmp/outside"
            archive.addfile(member)
    return output.getvalue()


class DependencyPreparationTests(unittest.TestCase):
    def test_digest_mismatch_rejects_before_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source"
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                prepare.prepare(b"untrusted archive", destination)
            self.assertFalse(destination.exists())

    def test_safe_pinned_prefix_is_stripped(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source"
            prepare.extract_source(archive_with("imsg-abc/Sources/test.swift"), destination, "abc")
            self.assertEqual((destination / "Sources/test.swift").read_bytes(), b"source")

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            keep = destination / "owned"
            keep.write_text("keep")
            with self.assertRaises(FileExistsError):
                prepare.extract_source(archive_with("imsg-abc/source"), destination, "abc")
            self.assertEqual(keep.read_text(), "keep")

    def test_unsafe_paths_and_links_are_rejected(self):
        cases = [
            ("/absolute", tarfile.REGTYPE),
            ("imsg-abc/../../outside", tarfile.REGTYPE),
            ("different/source", tarfile.REGTYPE),
            ("imsg-abc/link", tarfile.SYMTYPE),
            ("imsg-abc/hardlink", tarfile.LNKTYPE),
        ]
        for name, kind in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / "source"
                with self.assertRaises(ValueError):
                    prepare.extract_source(archive_with(name, kind), destination, "abc")
                self.assertFalse(destination.exists())

    def test_committed_patch_and_lock_pins_match(self):
        import json
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["upstream_commit"], "41de9c8b58ffbff2beff9ce3992192d5c11a753e")
        self.assertEqual(manifest["adapter_revision"], 2)
        self.assertEqual(manifest["artifact_status"], "not_built")
        self.assertFalse(manifest["production_qualified"])
        for patch in manifest["patches"]:
            self.assertEqual(hashlib.sha256((ROOT / patch["path"]).read_bytes()).hexdigest(), patch["sha256"])


if __name__ == "__main__":
    unittest.main()
