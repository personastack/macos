import copy
import os
import plistlib
import stat
import tempfile
import unittest
from pathlib import Path

import policy


class PolicyTests(unittest.TestCase):
    def test_leaf_denies_once_and_cannot_shortcut_for_root(self):
        self.assertEqual(policy.leaf(), {
            "class": "evaluate-mechanisms",
            "mechanisms": ["PersonaStackLockedSessionProbe:observe-screensaver,privileged"],
            "tries": 1, "shared": False, "allow-root": False, "version": 1,
        })

    def test_stock_preserves_original_fields_and_manual_login(self):
        original = {"class": "rule", "rule": "use-login-window-ui", "version": 1,
                    "comment": "stock rule", "timeout": 17}
        before = copy.deepcopy(original)
        candidate = policy.compose(original)
        self.assertEqual(candidate["rule"], [policy.RIGHT, "use-login-window-ui"])
        self.assertEqual(candidate["k-of-n"], 1)
        for key, value in original.items():
            if key != "rule":
                self.assertEqual(candidate[key], value)
        self.assertEqual(original, before)
        self.assertEqual(policy.remove(candidate, original), original)

    def test_existing_alternatives_remain_in_order(self):
        original = {"class": "rule", "rule": ["third-party", "use-login-window-ui"],
                    "k-of-n": 1, "metadata": {"values": [1, 2]}}
        candidate = policy.compose(original)
        self.assertEqual(candidate["rule"], [policy.RIGHT, *original["rule"]])
        candidate["metadata"]["values"].append(3)
        self.assertEqual(original["metadata"]["values"], [1, 2])

    def test_single_delegate_all_of_is_equivalent(self):
        for rules in ("use-login-window-ui", ["use-login-window-ui"]):
            for k_of_n in (None, 0, 1):
                with self.subTest(rules=rules, k_of_n=k_of_n):
                    original = {"class": "rule", "rule": rules}
                    if k_of_n is not None:
                        original["k-of-n"] = k_of_n
                    candidate = policy.compose(original)
                    self.assertEqual(policy.remove(candidate, original), original)

    def test_unsupported_policy_is_rejected_without_mutation(self):
        cases = [None, [], {}, {"class": "allow"}, {"class": "evaluate-mechanisms"},
                 {"class": "rule", "rule": []}, {"class": "rule", "rule": ""},
                 {"class": "rule", "rule": ["manual", "other"]},
                 {"class": "rule", "rule": "manual", "k-of-n": True},
                 {"class": "rule", "rule": "manual", "k-of-n": 2},
                 {"class": "rule", "rule": "manual", "k-of-n": "1"},
                 {"class": "rule", "rule": ["manual", 7], "k-of-n": 1},
                 {"class": "rule", "rule": "x" * 257},
                 {"class": "rule", "rule": ["x"] * 65, "k-of-n": 1},
                 {"class": "rule", "rule": ["x"] * 64, "k-of-n": 1},
                 {"class": "rule", "rule": [policy.RIGHT, "manual"], "k-of-n": 1}]
        for original in cases:
            with self.subTest(original=original):
                before = copy.deepcopy(original)
                with self.assertRaises(ValueError):
                    policy.compose(original)
                self.assertEqual(original, before)

    def test_removal_preserves_concurrent_third_party_changes(self):
        original = {"class": "rule", "rule": "manual", "version": 1}
        current = policy.compose(original)
        current["rule"].insert(1, "new-third-party")
        current["version"] = 4
        current["comment"] = "new policy metadata"
        before = copy.deepcopy(current)
        restored = policy.remove(current, original)
        self.assertEqual(restored, {"class": "rule", "rule": ["new-third-party", "manual"],
                                  "version": 4, "comment": "new policy metadata", "k-of-n": 1})
        self.assertEqual(current, before)

    def test_removal_without_our_branch_is_idempotent(self):
        original = {"class": "rule", "rule": "manual"}
        current = {"class": "rule", "rule": ["new-third-party", "manual"], "k-of-n": 1}
        self.assertEqual(policy.remove(current, original), current)

    def test_ambiguous_removal_is_rejected(self):
        original = {"class": "rule", "rule": "manual"}
        for current in ({"class": "rule", "rule": [policy.RIGHT, policy.RIGHT, "manual"], "k-of-n": 1},
                        {"class": "rule", "rule": policy.RIGHT},
                        {"class": "rule", "rule": [policy.RIGHT], "k-of-n": 1}):
            with self.subTest(current=current), self.assertRaises(ValueError):
                policy.remove(current, original)

    def test_output_is_private_exclusive_and_does_not_follow_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate.plist"
            policy.write_new(output, policy.leaf())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(plistlib.loads(output.read_bytes()), policy.leaf())
            original_bytes = output.read_bytes()
            with self.assertRaises(FileExistsError):
                policy.write_new(output, {"class": "allow"})
            self.assertEqual(output.read_bytes(), original_bytes)
            link = Path(directory) / "link.plist"
            os.symlink(output, link)
            with self.assertRaises(FileExistsError):
                policy.write_new(link, {"class": "allow"})
            self.assertEqual(output.read_bytes(), original_bytes)

    def test_read_is_bounded_and_requires_dictionary(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.plist"
            for data in (b"bad plist", plistlib.dumps([]), b"x" * (policy.MAX_PLIST_BYTES + 1)):
                source.write_bytes(data)
                with self.subTest(length=len(data)), self.assertRaises(ValueError):
                    policy.read_policy(source)
            source.write_bytes(plistlib.dumps(policy.leaf()))
            self.assertEqual(policy.read_policy(source), policy.leaf())


if __name__ == "__main__":
    unittest.main()
