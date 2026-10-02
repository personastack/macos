"""Compose candidate policy files offline. Never installs or calls authdb."""

import importlib.util
from pathlib import Path

RIGHT = "ai.personastack.locked-grant-candidate"
MECHANISM = "PersonaStackLockedGrantCandidate:consume-locked-grant,privileged"

# The portable kit contains the same composer used by the deny-only probe.
# Source checkouts resolve that owner directly instead of copying its policy.
base_path = Path(__file__).with_name("policy_base.py")
if not base_path.exists():
    base_path = Path(__file__).parent.parent / "LockedSessionProbe" / "policy.py"
spec = importlib.util.spec_from_file_location("locked_policy_base", base_path)
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def leaf():
    return base.leaf(MECHANISM)


def compose(original):
    return base.compose(original, RIGHT)


def remove(current, original):
    return base.remove(current, original, RIGHT)


def receipt(original):
    # Use the same input validation as the actual candidate composition.
    compose(original)
    fallbacks = base.delegates(original)
    if len(set(fallbacks)) != len(fallbacks):
        raise ValueError("duplicate fallback delegates require manual review")
    return {"version": 1, "right": RIGHT, "manualFallbacks": list(fallbacks)}


if __name__ == "__main__":
    base.main(RIGHT, MECHANISM, receipt_factory=receipt)
