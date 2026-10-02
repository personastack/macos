import copy
import unittest

import policy


class CandidatePolicyTests(unittest.TestCase):
    def test_denied_candidate_keeps_manual_authentication_fallback(self):
        original = {"class": "rule", "rule": ["use-login-window-ui"],
                    "k-of-n": 1, "version": 7, "comment": "managed policy"}
        before = copy.deepcopy(original)
        candidate = policy.compose(original)
        self.assertEqual(original, before)
        self.assertEqual(candidate["rule"],
                         [policy.RIGHT, "use-login-window-ui"])
        self.assertEqual(candidate["k-of-n"], 1)
        self.assertEqual(candidate["comment"], original["comment"])
        self.assertEqual(policy.leaf()["mechanisms"], [policy.MECHANISM])
        self.assertEqual(policy.leaf()["tries"], 1)
        self.assertFalse(policy.leaf()["shared"])
        self.assertEqual(policy.remove(candidate, original), original)

    def test_removal_preserves_another_vendors_later_changes(self):
        original = {"class": "rule", "rule": ["use-login-window-ui"]}
        candidate = policy.compose(original)
        candidate["rule"].append("vendor.right")
        candidate["comment"] = "new managed policy"
        removed = policy.remove(candidate, original)
        self.assertEqual(removed["rule"], ["use-login-window-ui", "vendor.right"])
        self.assertEqual(removed["comment"], "new managed policy")

    def test_unknown_or_ambiguous_policy_is_not_replaced(self):
        for original in [
            {"class": "evaluate-mechanisms", "mechanisms": ["builtin:authenticate"]},
            {"class": "rule", "rule": ["first", "second"], "k-of-n": 2},
            {"class": "rule", "rule": []},
            {"class": "rule", "rule": [policy.RIGHT, "use-login-window-ui"], "k-of-n": 1},
        ]:
            with self.subTest(original=original), self.assertRaises(ValueError):
                policy.compose(original)

    def test_receipt_pins_original_fallback_order_without_mutating_it(self):
        original = {"class": "rule", "rule": ["use-login-window-ui", "vendor.right"], "k-of-n": 1}
        before = copy.deepcopy(original)
        self.assertEqual(policy.receipt(original), {
            "version": 1, "right": policy.RIGHT,
            "manualFallbacks": ["use-login-window-ui", "vendor.right"]})
        self.assertEqual(original, before)

    def test_receipt_rejects_an_already_modified_or_ambiguous_policy(self):
        for rules in [[policy.RIGHT, "use-login-window-ui"], ["same", "same"]]:
            with self.subTest(rules=rules), self.assertRaises(ValueError):
                policy.receipt({"class": "rule", "rule": rules, "k-of-n": 1})


if __name__ == "__main__":
    unittest.main()
