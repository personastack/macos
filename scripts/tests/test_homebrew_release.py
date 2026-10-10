"""Drive tap publication without GitHub, Apple, or real signing credentials."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PUBLISHER = ROOT / "scripts/publish-homebrew-release.sh"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class HomebrewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="personastack-tap-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tap = self.root / "tap"
        self.remote = self.root / "remote.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{self.bin}:{self.env['PATH']}",
            "GH_TOKEN": "fixture-tap-token",
            "SPARKLE_PRIVATE_KEY": "fixture-signing-key",
            "RUNNER_TEMP": str(self.root),
            "FIXTURE_LOG": str(self.root / "calls.jsonl"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        })
        self.command("git", "init", "--bare", "--initial-branch=main", str(self.remote))
        self.command("git", "clone", str(self.remote), str(self.tap))
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.tap / "README.md").write_text("Unrelated tap contents\n")
        self.git("add", "README.md")
        self.git("commit", "-m", "fixture")
        self.git("push", "origin", "main")
        self.baseline = self.git("rev-parse", "HEAD").stdout.strip()
        self.sparkle = self.root / "sparkle"
        (self.sparkle / "bin").mkdir(parents=True)
        self.write_executable(self.bin / "gh", '''
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
assert os.environ["GH_TOKEN"] == "fixture-tap-token"
assert args[:2] in (["release", "view"], ["release", "create"]), args
assert args[2:4] == ["--repo", "personastack/homebrew-tap"], args
record = {"tool": "gh", "args": args}
if args[1] == "create":
    assert args[-1] == "--latest", args
    record["assets"] = [hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in args[5:7]]
    record["notes"] = pathlib.Path(args[args.index("--notes-file") + 1]).read_text()
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\\n")
if args[1] == "view":
    sys.exit(0 if os.environ.get("FIXTURE_EXISTING_RELEASE") else 1)
sys.exit(1 if os.environ.get("FIXTURE_RELEASE_FAILURE") else 0)
''')
        self.write_executable(self.sparkle / "bin/sign_update", '''
import base64, json, os, pathlib, sys
args = sys.argv[1:]
assert sys.stdin.read() == "fixture-signing-key"
assert args[:2] == ["--ed-key-file", "-"], args
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "sign_update", "args": args}) + "\\n")
if os.environ.get("FIXTURE_SIGNING_FAILURE"):
    sys.exit(1)
if "--verify" in args:
    sys.exit(1 if os.environ.get("FIXTURE_VERIFY_FAILURE") else 0)
if "-p" in args:
    print(base64.b64encode(bytes(64)).decode())
else:
    with pathlib.Path(args[-1]).open("a") as feed:
        feed.write("<!-- sparkle-signatures:\\nedSignature: fixture\\n-->\\n")
''')

    def write_executable(self, path, body):
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    def command(self, *args):
        return subprocess.run(args, env=self.env, check=True, capture_output=True, text=True, timeout=15)

    def git(self, *args):
        return self.command("git", "-C", str(self.tap), *args)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def publish(self, version="1.2.3", notes=None, filename=None):
        archive = self.root / (filename or f"PersonaStack-{version}-developerid.dmg")
        archive.write_bytes(f"finalized CI archive {version}".encode())
        notes_path = self.root / f"{version}.md"
        notes_path.write_text(notes if notes is not None else f"# PersonaStack {version}\n\n- Fixed update progress & display.\n")
        result = subprocess.run([str(PUBLISHER), version, str(archive), str(self.tap),
                                 str(self.sparkle), str(notes_path)], env=self.env,
                                capture_output=True, text=True, timeout=15)
        return result, archive, notes_path

    def remote_file(self, revision, path):
        return self.command("git", "--git-dir", str(self.remote), "show", f"{revision}:{path}").stdout

    def test_each_release_updates_cask_assets_and_feed_without_rebuilding(self):
        for version in ("1.2.3", "1.2.4"):
            with self.subTest(version=version):
                result, archive, notes = self.publish(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                tag = f"desktop-v{version}"
                cask = self.remote_file("main", "Casks/personastack.rb")
                self.assertIn(f'version "{version}"', cask)
                self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), cask)
                self.assertIn('pkg "Install PersonaStack.pkg"', cask)
                self.assertIn("auto_updates true", cask)
                self.assertEqual(self.remote_file(tag, "Casks/personastack.rb"), cask)
                self.assertEqual(self.remote_file(tag, f"Downloads/{archive.name}"), archive.read_text())
                create = [c for c in self.calls() if c["tool"] == "gh" and c["args"][1] == "create"][-1]
                self.assertEqual(create["assets"], [hashlib.sha256(archive.read_bytes()).hexdigest()] * 2)
                self.assertEqual(create["notes"], notes.read_text())
                self.assertEqual(create["args"][4], tag)
                self.assertEqual(Path(create["args"][6]).name, "PersonaStack-latest.dmg")
                feed = ET.fromstring(self.remote_file("main", "appcast.xml"))
                item = feed.find("channel/item")
                self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), version)
                self.assertEqual(item.findtext("description"), notes.read_text().strip())
                self.assertIn(f"/{tag}/Downloads/{archive.name}", item.find("enclosure").get("url"))
        self.assertEqual([i.findtext(f"{{{SPARKLE}}}version") for i in feed.findall("channel/item")],
                         ["1.2.4", "1.2.3"])
        self.assertEqual(self.remote_file("desktop-v1.2.3", "Downloads/PersonaStack-1.2.3-developerid.dmg"),
                         "finalized CI archive 1.2.3")
        self.assertEqual(self.remote_file("main", "README.md"), "Unrelated tap contents\n")
        signing = [c for c in self.calls() if c["tool"] == "sign_update"]
        self.assertEqual(len(signing), 8)
        self.assertEqual(sum("--verify" in c["args"] for c in signing), 4)

    def test_existing_tag_or_release_is_rejected_before_tap_changes(self):
        for existing in ("tag", "release"):
            with self.subTest(existing=existing):
                if existing == "tag":
                    self.git("tag", "desktop-v1.2.3")
                else:
                    self.env["FIXTURE_EXISTING_RELEASE"] = "1"
                result, _, _ = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already exists", result.stderr)
                self.assertEqual(self.git("status", "--porcelain").stdout, "")
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.baseline)
                self.assertFalse(any(c["args"][1] == "create" for c in self.calls()))
                if existing == "tag":
                    # Only remove this fixture's disposable tag.
                    self.git("tag", "-d", "desktop-v1.2.3")

    def test_invalid_inputs_stop_before_any_publication(self):
        cases = [("notes", {"notes": "# PersonaStack 1.2.3\n"}),
                 ("version", {"version": "1.2.3-beta"}),
                 ("archive", {"filename": "PersonaStack-1.2.3-unsigned.dmg"})]
        for name, args in cases:
            with self.subTest(name=name):
                result, _, _ = self.publish(**args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertEqual(self.git("status", "--porcelain").stdout, "")
        for key in ("GH_TOKEN", "SPARKLE_PRIVATE_KEY"):
            with self.subTest(missing=key):
                saved = self.env.pop(key)
                result, _, _ = self.publish()
                self.env[key] = saved
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_release_failure_stops_before_feed_signing(self):
        self.env["FIXTURE_RELEASE_FAILURE"] = "1"
        result, _, _ = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c["tool"] == "sign_update" for c in self.calls()))
        self.assertEqual(self.git("log", "-1", "--format=%s", "origin/main").stdout.strip(),
                         "feat: publish PersonaStack cask 1.2.3")

    def test_signature_failure_never_publishes_feed(self):
        self.env["FIXTURE_VERIFY_FAILURE"] = "1"
        result, _, _ = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.tap / "appcast.xml").exists())
        self.assertEqual(self.git("log", "-1", "--format=%s", "origin/main").stdout.strip(),
                         "feat: publish PersonaStack cask 1.2.3")

    def test_tap_push_failure_stops_before_release_or_feed(self):
        self.write_executable(self.remote / "hooks/pre-receive", "import sys\nsys.exit(1)\n")
        result, _, _ = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0]["args"][1], "view")
        self.assertEqual(self.command("git", "--git-dir", str(self.remote), "rev-parse", "main").stdout.strip(),
                         self.baseline)


class HomebrewWorkflowTests(unittest.TestCase):
    def test_tap_publication_is_mandatory_for_tags_and_excluded_from_validation(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        steps = workflow.split("      - name: ")
        for name in ("Check out Homebrew tap", "Download pinned Sparkle release tools",
                     "Publish Homebrew release and signed appcast"):
            step = next(step for step in steps if step.startswith(name + "\n"))
            self.assertIn("if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')", step)
            self.assertNotIn("continue-on-error", step)
        checkout = next(step for step in steps if step.startswith("Check out Homebrew tap\n"))
        self.assertIn("repository: personastack/homebrew-tap", checkout)
        self.assertIn("ref: main", checkout)
        self.assertIn("fetch-depth: 0", checkout)
        publisher = next(step for step in steps if step.startswith("Publish Homebrew release and signed appcast\n"))
        self.assertIn("GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}", publisher)
        self.assertIn('./scripts/publish-homebrew-release.sh "$RELEASE_VERSION"', publisher)
        self.assertIn("unittest discover -s scripts/tests", workflow)
        self.assertLess(workflow.index("Publish GitHub release"), workflow.index("Check out Homebrew tap"))


if __name__ == "__main__":
    unittest.main()
