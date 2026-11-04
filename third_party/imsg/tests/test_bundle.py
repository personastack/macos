import importlib.util
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("imsg_bundle", ROOT / "bundle.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


def make_app(root):
    app = root / "PersonaStack.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources").mkdir()
    return app


def make_product(root):
    root.mkdir(parents=True)
    (root / "imsg").write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"synthetic ARM64 artifact")
    resource = root / "PhoneNumberKit_PhoneNumberKit.bundle"
    resource.mkdir()
    (resource / "PhoneNumberMetadata.json").write_text('{"synthetic":true}')
    (resource / "PrivacyInfo.xcprivacy").write_text("fixture")
    return root


def make_notice_root(root, payloads=None):
    root.mkdir(parents=True)
    pin = bundle.manifest()
    for name, relative in bundle.NOTICE_SOURCES.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = (ROOT / relative).read_bytes() if payloads is None else payloads[name]
        target.write_bytes(data)
        pin["notices"][name]["sha256"] = hashlib.sha256(data).hexdigest()
    (root / "manifest.json").write_text(json.dumps(pin))
    return root


class ProviderBundleTests(unittest.TestCase):
    def test_unsigned_bundle_copies_actual_resources_and_requires_seal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            product = make_product(root / "products")
            result = bundle.install_artifacts(app, product, "Swift version 6.2.4")
            self.assertEqual(result["signing_state"], "unsigned")
            self.assertEqual(result["adapter_revision"], 2)
            self.assertEqual(result["target_triple"], "arm64-apple-macosx14.0")
            self.assertTrue((app / "Contents/Resources/imsg-MIT-LICENSE.txt").is_file())
            expected_notices = {name: entry["sha256"] for name, entry in bundle.manifest()["notices"].items()}
            self.assertEqual(result["notices_sha256"], expected_notices)
            self.assertEqual(result["license_sha256"], expected_notices["imsg-MIT-LICENSE.txt"])
            for name, relative in bundle.NOTICE_SOURCES.items():
                self.assertEqual((app / "Contents/Resources" / name).read_bytes(), (ROOT / relative).read_bytes())
            self.assertEqual((app / "Contents/MacOS/PhoneNumberKit_PhoneNumberKit.bundle").readlink(), Path("../Resources/PhoneNumberKit_PhoneNumberKit.bundle"))
            bundle.verify_existing(app, require_sealed=False)
            with self.assertRaisesRegex(ValueError, "sealed"):
                bundle.verify_existing(app)

    def test_seal_records_changed_binary_but_does_not_run_codesign(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            result = bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
            executable = app / "Contents/MacOS/imsg"
            executable.write_bytes(executable.read_bytes() + b"synthetic signature bytes")
            with mock.patch.object(bundle.subprocess, "run", side_effect=AssertionError("No process may run while sealing")):
                sealed = bundle.seal_existing(app)
                bundle.verify_existing(app)
            self.assertEqual(sealed["signing_state"], "sealed")
            self.assertEqual(sealed["unsigned_executable_sha256"], result["unsigned_executable_sha256"])
            self.assertNotEqual(sealed["executable_sha256"], sealed["unsigned_executable_sha256"])

    def test_tampered_binary_resources_and_alias_are_rejected(self):
        for target in ["binary", "resources", "alias"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = make_app(root)
                bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
                bundle.seal_existing(app)
                if target == "binary":
                    binary = app / "Contents/MacOS/imsg"
                    binary.write_bytes(binary.read_bytes() + b"tampered")
                elif target == "resources":
                    (app / "Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle/PhoneNumberMetadata.json").write_text("tampered")
                else:
                    alias = app / "Contents/MacOS/PhoneNumberKit_PhoneNumberKit.bundle"
                    alias.unlink()
                    alias.symlink_to("/tmp/untrusted")
                with self.assertRaises(ValueError):
                    bundle.verify_existing(app)

    def test_existing_destination_fails_before_overwriting_any_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            prior = app / "Contents/MacOS/imsg"
            prior.write_bytes(b"preserve")
            with self.assertRaisesRegex(ValueError, "already exists"):
                bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
            self.assertEqual(prior.read_bytes(), b"preserve")
            self.assertFalse((app / "Contents/Resources/imsg-provider-manifest.json").exists())

    def test_non_arm64_or_missing_runtime_resources_are_rejected(self):
        for target in ["architecture", "missing", "unexpected", "nested_code"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = make_app(root)
                product = make_product(root / "product")
                if target == "architecture":
                    (product / "imsg").write_bytes(b"not ARM64")
                elif target == "missing":
                    (product / "PhoneNumberKit_PhoneNumberKit.bundle/PhoneNumberMetadata.json").unlink()
                elif target == "unexpected":
                    (product / "PrivateIMCore.bundle").mkdir()
                else:
                    (product / "PhoneNumberKit_PhoneNumberKit.bundle/private.dylib").write_bytes(b"forbidden")
                with self.assertRaises(ValueError):
                    bundle.install_artifacts(app, product, "Swift version 6.2.4")
                self.assertFalse((app / "Contents/MacOS/imsg").exists())

    def test_receipt_cannot_select_paths_or_another_pin(self):
        for key, value in [("upstream_commit", "wrong"), ("target_triple", "x86_64-apple-macosx14.0"), ("resources", [{"name": "../../escape", "files": []}])]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = make_app(root)
                bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
                receipt = app / "Contents/Resources/imsg-provider-manifest.json"
                data = json.loads(receipt.read_text())
                data[key] = value
                receipt.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    bundle.seal_existing(app)

    def test_build_driver_uses_one_pinned_arm64_build_and_owned_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            archive = root / "archive"
            archive.write_bytes(b"verified by preparation owner")
            calls = []
            preparations = []

            def fake_prepare(data, output):
                preparations.append(data)
                output.mkdir()

            def runner(command, **kwargs):
                calls.append(command)
                if command[-1] == "--version":
                    return subprocess.CompletedProcess(command, 0, "Swift version 6.2.4\nTarget: arm64-apple-macosx14.0\n")
                scratch = Path(command[command.index("--scratch-path") + 1])
                product = scratch / "arm64-apple-macosx/release"
                if "--show-bin-path" in command:
                    return subprocess.CompletedProcess(command, 0, str(product) + "\n")
                make_product(product)
                return subprocess.CompletedProcess(command, 0)

            with mock.patch.object(bundle.shutil, "which", return_value="/toolchain/swift"), mock.patch.object(bundle, "prepare", side_effect=fake_prepare):
                bundle.build_and_bundle(app, root / "build", archive, runner=runner)
            builds = [call for call in calls if "--product" in call]
            self.assertEqual(len(builds), 1)
            self.assertIn("--disable-automatic-resolution", builds[0])
            self.assertEqual(builds[0][builds[0].index("--triple") + 1], "arm64-apple-macosx14.0")
            self.assertNotIn("x86_64", " ".join(builds[0]))
            self.assertEqual(preparations, [b"verified by preparation owner"])
            self.assertEqual(list((root / "build").iterdir()), [])
            self.assertTrue((app / "Contents/MacOS/imsg").is_file())

    def test_build_driver_rejects_old_toolchain_before_preparation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0, "Swift version 6.1.3\n"))
            with mock.patch.object(bundle.shutil, "which", return_value="/toolchain/swift"), mock.patch.object(bundle, "prepare", side_effect=AssertionError("No source preparation")):
                with self.assertRaisesRegex(ValueError, "6.2"):
                    bundle.build_and_bundle(app, root / "build", runner=runner)
            self.assertFalse((app / "Contents/MacOS/imsg").exists())

    def test_linked_app_contents_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = make_app(root / "actual")
            linked = root / "Linked.app"
            linked.mkdir()
            (linked / "Contents").symlink_to(actual / "Contents", target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "linked"):
                bundle.app_paths(linked)

    def test_all_notice_mutations_fail_seal_and_verify_without_repairs(self):
        for name in bundle.NOTICE_SOURCES:
            for mutation in ["missing", "corrupt", "symlink", "oversized", "directory"]:
                with self.subTest(name=name, mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    app = make_app(root)
                    bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
                    bundle.seal_existing(app)
                    notice = app / "Contents/Resources" / name
                    notice.unlink()
                    if mutation == "corrupt":
                        notice.write_bytes(b"changed license")
                    elif mutation == "symlink":
                        notice.symlink_to(ROOT / bundle.NOTICE_SOURCES[name])
                    elif mutation == "oversized":
                        notice.write_bytes(b"x" * (bundle.MAX_NOTICE_BYTES + 1))
                    elif mutation == "directory":
                        notice.mkdir()
                    receipt = app / "Contents/Resources" / bundle.RECEIPT_NAME
                    before = receipt.read_bytes()
                    contents = notice.read_bytes() if notice.is_file() and not notice.is_symlink() else None
                    for action in [bundle.seal_existing, bundle.verify_existing]:
                        with self.assertRaises(ValueError):
                            action(app)
                        self.assertEqual(receipt.read_bytes(), before)
                        self.assertEqual(notice.exists(), mutation != "missing")
                        self.assertEqual(notice.is_symlink(), mutation == "symlink")
                        self.assertEqual(notice.is_dir(), mutation == "directory")
                        if contents is not None:
                            self.assertEqual(notice.read_bytes(), contents)

    def test_notice_receipt_must_match_the_exact_fixed_map(self):
        for mutation in ["absent", "missing", "extra", "hash", "type", "legacy_hash"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = make_app(root)
                bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
                receipt = app / "Contents/Resources" / bundle.RECEIPT_NAME
                record = json.loads(receipt.read_text())
                name = next(iter(bundle.NOTICE_SOURCES))
                if mutation == "absent":
                    del record["notices_sha256"]
                elif mutation == "missing":
                    del record["notices_sha256"][name]
                elif mutation == "extra":
                    record["notices_sha256"]["../../untrusted.txt"] = "0" * 64
                elif mutation == "hash":
                    record["notices_sha256"][name] = "0" * 64
                elif mutation == "type":
                    record["notices_sha256"] = []
                else:
                    record["license_sha256"] = "0" * 64
                receipt.write_text(json.dumps(record))
                with self.assertRaises(ValueError):
                    bundle.seal_existing(app)

    def test_unknown_notice_file_fails_install_and_existing_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = make_app(root)
            unknown = app / "Contents/Resources/imsg-unknown.txt"
            unknown.write_text("preserve unknown")
            product = make_product(root / "product")
            with self.assertRaisesRegex(ValueError, "Unknown provider notice"):
                bundle.install_artifacts(app, product, "Swift version 6.2.4")
            self.assertFalse((app / "Contents/MacOS/imsg").exists())
            self.assertEqual(unknown.read_text(), "preserve unknown")
            unknown.unlink()
            bundle.install_artifacts(app, product, "Swift version 6.2.4")
            bundle.seal_existing(app)
            unknown.write_text("unexpected")
            with self.assertRaisesRegex(ValueError, "fixed set"):
                bundle.verify_existing(app)
            self.assertEqual(unknown.read_text(), "unexpected")

    def test_source_notice_pins_and_paths_fail_before_copying_any_artifact(self):
        for mutation in ["missing", "corrupt", "symlink", "oversized", "path", "hash", "extra", "missing_pin", "linked_directory"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                owner = make_notice_root(root / "owner")
                app = make_app(root)
                product = make_product(root / "product")
                name = "imsg-PhoneNumberKit-MIT-LICENSE.txt"
                notice = owner / bundle.NOTICE_SOURCES[name]
                pin = json.loads((owner / "manifest.json").read_text())
                if mutation in ["missing", "symlink"]:
                    notice.unlink()
                    if mutation == "symlink":
                        notice.symlink_to(ROOT / bundle.NOTICE_SOURCES[name])
                elif mutation == "corrupt":
                    notice.write_text("changed")
                elif mutation == "oversized":
                    notice.write_bytes(b"x" * (bundle.MAX_NOTICE_BYTES + 1))
                elif mutation == "path":
                    pin["notices"][name]["path"] = "../untrusted"
                elif mutation == "hash":
                    pin["notices"][name]["sha256"] = "0" * 64
                elif mutation == "extra":
                    pin["notices"]["imsg-unknown.txt"] = pin["notices"][name]
                elif mutation == "missing_pin":
                    del pin["notices"][name]
                else:
                    (owner / "licenses").rename(owner / "real-licenses")
                    (owner / "licenses").symlink_to("real-licenses", target_is_directory=True)
                (owner / "manifest.json").write_text(json.dumps(pin))
                with mock.patch.object(bundle, "ROOT", owner):
                    with self.assertRaises(ValueError):
                        bundle.install_artifacts(app, product, "Swift version 6.2.4")
                self.assertFalse((app / "Contents/MacOS/imsg").exists())
                self.assertFalse((app / "Contents/Resources" / bundle.RECEIPT_NAME).exists())

    def test_combined_notice_budget_is_bounded_even_with_valid_individual_pins(self):
        for sizes, accepted in [([16 << 10] * 4, True), ([20 << 10] * 4, False)]:
            with self.subTest(accepted=accepted), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                payloads = {name: b"x" * size for name, size in zip(bundle.NOTICE_SOURCES, sizes)}
                owner = make_notice_root(root / "owner", payloads)
                app = make_app(root)
                product = make_product(root / "product")
                with mock.patch.object(bundle, "ROOT", owner):
                    if accepted:
                        bundle.install_artifacts(app, product, "Swift version 6.2.4")
                        bundle.seal_existing(app)
                        bundle.verify_existing(app)
                    else:
                        with self.assertRaisesRegex(ValueError, "budget"):
                            bundle.install_artifacts(app, product, "Swift version 6.2.4")
                        self.assertFalse((app / "Contents/MacOS/imsg").exists())

    def test_notice_pin_change_is_not_trusted_from_the_artifact_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            owner = make_notice_root(root / "owner")
            app = make_app(root)
            with mock.patch.object(bundle, "ROOT", owner):
                bundle.install_artifacts(app, make_product(root / "product"), "Swift version 6.2.4")
                bundle.seal_existing(app)
                pin = json.loads((owner / "manifest.json").read_text())
                name = next(iter(bundle.NOTICE_SOURCES))
                pin["notices"][name]["sha256"] = "0" * 64
                (owner / "manifest.json").write_text(json.dumps(pin))
                with self.assertRaisesRegex(ValueError, "source digest mismatch"):
                    bundle.verify_existing(app)


if __name__ == "__main__":
    unittest.main()
