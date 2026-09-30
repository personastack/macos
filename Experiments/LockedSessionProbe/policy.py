"""Offline plist composition only. Never installs or calls security/authdb."""

import argparse
import copy
import os
import plistlib
from pathlib import Path

RIGHT = "ai.personastack.locked-session-probe"
MECHANISM = "PersonaStackLockedSessionProbe:observe-screensaver,privileged"
MAX_PLIST_BYTES = 1024 * 1024


def leaf():
    # authd retries a denying mechanism indefinitely when tries is zero.
    return {
        "class": "evaluate-mechanisms",
        "mechanisms": [MECHANISM],
        "tries": 1,
        "shared": False,
        "allow-root": False,
        "version": 1,
    }


def delegates(policy):
    if type(policy) is not dict or policy.get("class") != "rule":
        raise ValueError("expected a class=rule screensaver policy")
    rules = policy.get("rule")
    if type(rules) is str:
        rules = [rules]
    if type(rules) is not list or not rules or len(rules) > 64:
        raise ValueError("expected 1 through 64 existing delegates")
    if any(type(rule) is not str or not rule or len(rule) > 256 for rule in rules):
        raise ValueError("invalid delegate name")
    k_of_n = policy.get("k-of-n", 0)
    if type(k_of_n) is not int or k_of_n not in (0, 1):
        raise ValueError("unsupported k-of-n policy")
    if len(rules) > 1 and k_of_n != 1:
        raise ValueError("cannot change an all-of policy into any-of")
    return rules


def compose(original):
    rules = delegates(original)
    if len(rules) >= 64:
        raise ValueError("no room for a probe delegate within the 64-delegate limit")
    if RIGHT in rules:
        raise ValueError("owned probe delegate already exists")
    candidate = copy.deepcopy(original)
    # Deny falls through to every original branch in its original order.
    candidate["rule"] = [RIGHT, *rules]
    candidate["k-of-n"] = 1
    return candidate


def remove(current, original):
    expected = compose(original)
    rules = delegates(current)
    if RIGHT not in rules:
        return copy.deepcopy(current)
    if rules.count(RIGHT) != 1 or current.get("k-of-n") != 1:
        raise ValueError("ambiguous probe delegate; inspect policy manually")
    if current == expected:
        return copy.deepcopy(original)
    remaining = [rule for rule in rules if rule != RIGHT]
    if not remaining:
        raise ValueError("refusing to remove the only authorization delegate")
    result = copy.deepcopy(current)
    result["rule"] = remaining
    # Keep all unrelated current fields and branches. Do not restore a stale dump.
    return result


def read_policy(path):
    with Path(path).open("rb") as source:
        data = source.read(MAX_PLIST_BYTES + 1)
    if len(data) > MAX_PLIST_BYTES:
        raise ValueError("policy exceeds 1 MiB")
    try:
        policy = plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError) as error:
        raise ValueError("invalid policy plist") from error
    if type(policy) is not dict:
        raise ValueError("policy must be a dictionary")
    return policy


def write_new(path, policy):
    data = plistlib.dumps(policy, fmt=plistlib.FMT_XML, sort_keys=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    leaf_command = commands.add_parser("leaf")
    leaf_command.add_argument("output")
    compose_command = commands.add_parser("compose")
    compose_command.add_argument("original")
    compose_command.add_argument("output")
    remove_command = commands.add_parser("remove")
    remove_command.add_argument("current")
    remove_command.add_argument("original")
    remove_command.add_argument("output")
    arguments = parser.parse_args()
    try:
        if arguments.action == "leaf":
            result = leaf()
        elif arguments.action == "compose":
            result = compose(read_policy(arguments.original))
        else:
            result = remove(read_policy(arguments.current), read_policy(arguments.original))
        write_new(arguments.output, result)
    except (OSError, ValueError) as error:
        parser.exit(1, f"offline policy composition failed: {error}\n")


if __name__ == "__main__":
    main()
