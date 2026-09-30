"""In-process fixtures only. Never collects OS logs or reads an installed plug-in."""

import copy
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import receipt

REVISION = "a" * 40
IMAGE = "12345678-1234-1234-1234-123456789abc"
OTHER_IMAGE = "23456789-2345-2345-2345-23456789abcd"
INSTANCE = "34567890-3456-3456-3456-34567890abcd"


def document():
    hashes = {name: "a" * 64 for name in receipt.SOURCES}
    return {"schema": 1, "build_version": "2", "build_id": receipt.source_identity(hashes),
            "source_revision": REVISION, "source_sha256": hashes,
            "sender_uuids": {"arm64": IMAGE, "x86_64": OTHER_IMAGE},
            "sha256": {name: receipt.digest(name.encode()) for name in receipt.ARTIFACTS}}


def records(sender=receipt.SENDERS[0]):
    result = []
    for index, event in enumerate(("plugin_loaded", "mechanism_created", "mechanism_invoked", "denial_returned")):
        result.append({"subsystem": receipt.SUBSYSTEM, "category": "authorization",
            "processImagePath": receipt.HOST, "processID": 321, "senderImagePath": sender,
            "senderImageUUID": IMAGE.upper(),
            "timestamp": datetime.fromtimestamp(1000 + index, timezone.utc).isoformat(),
            "eventMessage": f'event={event} build_id={document()["build_id"]} instance={INSTANCE} mechanism={0 if index == 0 else 1}'})
    return result


class ReceiptTests(unittest.TestCase):
    def inspect(self, entries, require_load=True, start=999, end=1010):
        calls = []
        expected = document()
        def host(path):
            self.assertEqual(path, receipt.HOST)
            calls.append("host")
        def sender(path):
            self.assertIn(path, receipt.SENDERS)
            calls.append("sender")
            return expected["sha256"][receipt.BINARY]
        result = receipt.inspect_events(entries, expected, start, end, require_load, host, sender)
        self.assertEqual(calls, ["host", "sender"])
        return result

    def assert_unqualified(self, entries, **options):
        def unplanned(_):
            self.fail("Rejected log evidence must not inspect OS code or installed sender bytes")
        with self.assertRaises(ValueError):
            receipt.inspect_events(entries, document(), options.get("start", 999), options.get("end", 1010),
                                   options.get("require_load", True), unplanned, unplanned)

    def test_installed_and_staged_exact_receipts_never_claim_unlock(self):
        for sender in receipt.SENDERS:
            with self.subTest(sender=sender):
                result = self.inspect(records(sender))
                self.assertEqual(result["result"], "matching_invocation_records")
                self.assertEqual(result["source_revision"], REVISION)
                self.assertEqual(result["sender_path"], sender)
                self.assertEqual(result["instance"], INSTANCE)
                self.assertFalse(result["unlock_verified"])
                self.assertIn("No lock state", result["limitation"])

    def test_old_staged_build_and_wrong_loaded_image_are_rejected(self):
        for key, value in [("eventMessage", records()[1]["eventMessage"].replace(document()["build_id"], "b" * 64)),
                           ("senderImageUUID", INSTANCE), ("senderImageUUID", None),
                           ("senderImagePath", "/tmp/PersonaStackLockedSessionProbe"),
                           ("processImagePath", "/System/Library/CoreServices/SecurityAgent.app/Contents/MacOS/SecurityAgent")]:
            entries = records()
            entries[1][key] = value
            with self.subTest(key=key, value=value): self.assert_unqualified(entries)

    def test_wrong_process_instance_or_mechanism_cannot_mix_sequences(self):
        for field, value in [("processID", 322), ("processID", True), ("processID", 0),
                             ("eventMessage", records()[2]["eventMessage"].replace(INSTANCE, IMAGE)),
                             ("eventMessage", records()[2]["eventMessage"].replace("mechanism=1", "mechanism=2"))]:
            entries = records()
            entries[2][field] = value
            with self.subTest(field=field, value=value): self.assert_unqualified(entries)

    def test_missing_duplicated_and_failed_events_remain_unqualified(self):
        for removed in range(4):
            entries = records()
            entries.pop(removed)
            with self.subTest(removed=removed): self.assert_unqualified(entries)
        entries = records()
        self.assert_unqualified(entries + [copy.deepcopy(entries[-1])])
        self.assert_unqualified(entries + [copy.deepcopy(entries[0])])
        failed = copy.deepcopy(entries[2])
        failed["eventMessage"] = failed["eventMessage"].replace("mechanism_invoked", "decision_delivery_failed")
        self.assert_unqualified(entries + [failed])

    def test_time_window_and_order_are_required(self):
        for start, end in [(1002, 1010), (999, 1001), (999, 999), (999, 1200), (float("nan"), 1010), (999, float("inf"))]:
            with self.subTest(start=start, end=end): self.assert_unqualified(records(), start=start, end=end)
        entries = records()
        entries[1]["timestamp"], entries[3]["timestamp"] = entries[3]["timestamp"], entries[1]["timestamp"]
        self.assert_unqualified(entries)
        for timestamp in (None, "not-a-date", "1970-01-01T00:16:42", []):
            entries = records()
            entries[2]["timestamp"] = timestamp
            with self.subTest(timestamp=timestamp): self.assert_unqualified(entries)

    def test_same_microsecond_events_keep_export_order(self):
        entries = records()
        for entry in entries: entry["timestamp"] = entries[0]["timestamp"]
        self.inspect(entries)

    def test_reused_host_does_not_require_another_load_for_each_trial(self):
        self.inspect(records()[1:], require_load=False)
        self.assert_unqualified(records()[1:])
        entries = records()
        entries[0]["timestamp"] = entries[-1]["timestamp"]
        self.assert_unqualified(entries)

    def test_unknown_schema_and_ambiguous_rival_are_rejected(self):
        for change in [None, {}, {"eventMessage": "plugin_loaded"},
                       {"eventMessage": records()[1]["eventMessage"].replace("mechanism_created", "allowed")},
                       {"eventMessage": records()[1]["eventMessage"].replace("mechanism=1", "mechanism=0")}]:
            entries = records()
            entries[1] = change if change is None else {**entries[1], **change}
            if change == {}: entries[1] = {}
            with self.subTest(change=change): self.assert_unqualified(entries)
        rivals = records()
        for entry in rivals:
            entry["eventMessage"] = entry["eventMessage"].replace(INSTANCE, IMAGE)
        self.assert_unqualified(records() + rivals)
        self.assert_unqualified([{}] * 4097)

    def test_sender_hash_mismatch_or_host_signature_failure_never_qualifies(self):
        with self.assertRaises(ValueError):
            receipt.inspect_events(records(), document(), 999, 1010, True, lambda _: None, lambda _: "b" * 64)
        calls = []
        def denied(_): raise ValueError("untrusted host")
        with self.assertRaises(ValueError):
            receipt.inspect_events(records(), document(), 999, 1010, True, denied, lambda _: calls.append("unexpected"))
        self.assertEqual(calls, [])

    def test_json_duplicates_malformed_and_oversized_inputs_are_rejected(self):
        for data in (b'{"build_id":"a","build_id":"b"}', b'[', b'\xff', b'[{"processID":1,"processID":2}]'):
            with self.subTest(data=data), self.assertRaises(ValueError): receipt.decode_json(data)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "oversized.json"
            path.write_bytes(b" " * 65)
            with patch.object(receipt, "MAX_JSON", 64), self.assertRaises(ValueError): receipt.read_json(path)

    def test_source_identity_is_stable_and_manifest_pins_all_artifacts(self):
        with tempfile.TemporaryDirectory() as root:
            source, kit = Path(root) / "source", Path(root) / "kit"
            source.mkdir(); kit.mkdir()
            for name in receipt.SOURCES: (source / name).write_text(name)
            for name in receipt.ARTIFACTS:
                target = kit / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(name)
            identity = receipt.source_identity(receipt.source_hashes(source))
            self.assertEqual(identity, receipt.source_identity(dict(reversed(list(receipt.source_hashes(source).items())))))
            replies = [SimpleNamespace(returncode=0, stdout=""), SimpleNamespace(returncode=0, stdout=REVISION + "\n"),
                SimpleNamespace(returncode=0, stdout=f"UUID: {IMAGE} (arm64) fixture\nUUID: {OTHER_IMAGE} (x86_64) fixture\n")]
            with patch.object(receipt.subprocess, "run", side_effect=replies) as run:
                proof = receipt.manifest(source, kit, identity)
                self.assertEqual(run.call_count, 3)
            self.assertEqual(receipt.verify_manifest(proof, kit), proof)
            (kit / "README.md").write_text("changed artifact")
            with self.assertRaises(ValueError): receipt.verify_manifest(proof, kit)
            (source / "ProbeActions.c").write_text("changed source")
            with patch.object(receipt.subprocess, "run", side_effect=AssertionError("No Git or binary reads expected")):
                with self.assertRaises(ValueError): receipt.manifest(source, kit, identity)

    def test_manifest_rejects_wrong_types_dirty_source_and_uuid_inventory(self):
        for field, value in [("schema", True), ("build_version", "1"), ("build_id", "b" * 64),
                             ("source_revision", None), ("source_revision", "dirty"),
                             ("source_sha256", {}), ("sender_uuids", {}),
                             ("sender_uuids", {"arm64": IMAGE, "x86_64": IMAGE}), ("sha256", {})]:
            proof = document(); proof[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): receipt.verify_manifest(proof, "/unused-fixture")

    def test_codesign_requires_exact_apple_authorization_host_identity(self):
        with patch.object(receipt.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            receipt.verify_apple_host(receipt.HOST)
            run.assert_called_once_with(["/usr/bin/codesign", "--verify", "--strict", "-R",
                '=anchor apple and identifier "com.apple.authorizationhost"', receipt.HOST],
                capture_output=True, timeout=5, check=False)
        with patch.object(receipt.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaises(ValueError): receipt.verify_apple_host(receipt.HOST)

    def test_sender_reader_refuses_other_paths_and_unsafe_ownership_before_read(self):
        class Sender(io.BytesIO):
            def fileno(self): return 7
        for owner, mode, success in [(0, stat.S_IFREG | 0o644, True), (501, stat.S_IFREG | 0o644, False),
                                      (0, stat.S_IFREG | 0o666, False), (0, stat.S_IFDIR | 0o755, False)]:
            stream = Sender(b"owned diagnostic bytes")
            with patch.object(receipt.os, "open", return_value=7) as opened, \
                 patch.object(receipt.os, "fdopen", return_value=stream), \
                 patch.object(receipt.os, "fstat", return_value=SimpleNamespace(st_mode=mode, st_uid=owner)):
                if success: self.assertEqual(receipt.installed_sender_hash(receipt.SENDERS[0]), receipt.digest(b"owned diagnostic bytes"))
                else:
                    with self.assertRaises(ValueError): receipt.installed_sender_hash(receipt.SENDERS[0])
                opened.assert_called_once_with(receipt.SENDERS[0], receipt.os.O_RDONLY | receipt.os.O_CLOEXEC | 0x20000000)
        with patch.object(receipt.os, "open", side_effect=AssertionError("No arbitrary path open expected")):
            with self.assertRaises(ValueError): receipt.installed_sender_hash("/tmp/other-plugin")

    def test_direct_collector_has_fixed_predicate_bounds_and_resource_limit(self):
        def collect(command, **options):
            self.assertEqual(command[:4], ["/usr/bin/log", "show", "--style", "json"])
            self.assertEqual(command[4:8], ["--start", "1970-01-01 00:16:39+0000", "--end", "1970-01-01 00:16:51+0000"])
            self.assertEqual(command[8:], ["--predicate", f'subsystem == "{receipt.SUBSYSTEM}" AND category == "authorization"'])
            self.assertEqual(options["timeout"], 15)
            with patch.object(receipt.resource, "setrlimit") as limit:
                options["preexec_fn"]()
                limit.assert_called_once_with(receipt.resource.RLIMIT_FSIZE, (receipt.MAX_JSON, receipt.MAX_JSON))
            options["stdout"].write(json.dumps(records()).encode())
            return SimpleNamespace(returncode=0)
        with patch.object(receipt.subprocess, "run", side_effect=collect): self.assertEqual(receipt.collect_logs(999, 1010), records())
        with patch.object(receipt.subprocess, "run", side_effect=AssertionError("Invalid interval must not collect")):
            with self.assertRaises(ValueError): receipt.collect_logs(999, 1200)
        with patch.object(receipt.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaises(ValueError): receipt.collect_logs(999, 1010)


if __name__ == "__main__":
    unittest.main()
