"""Exercise the app-only packaging boundary with disposable build/signing fakes."""
from pathlib import Path
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "package-macos.sh"


class IMessageCandidateTests(unittest.TestCase):
    def fixture(self, root):
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copyfile(SOURCE, scripts / SOURCE.name)
        tools = root / "tools"
        tools.mkdir()
        trace = root / "trace"

        def executable(path, text):
            path.write_text("#!/bin/sh\nset -eu\n" + text)
            path.chmod(0o755)

        for name in ["build-icon.sh", "sign-app.sh", "verify-update-bundle.sh", "verify-arm64-binaries.sh"]:
            executable(scripts / name, f'printf "%s\\n" "{name}" >> "{trace}"\n')
        (scripts / "lima_runtime.py").write_text(f'from pathlib import Path\nwith Path({str(trace)!r}).open("a") as output: output.write("bundle-lima\\n")\n')
        executable(scripts / "notarize.sh", f'printf "%s\\n" "notarize" >> "{trace}"\nexit 42\n')
        executable(scripts / "build-agent-bridge.sh", 'mkdir -p "$1"\nprintf bridge > "$1/PersonaStackAgentBridge"\n')
        executable(tools / "swift", '''
if [ "$1" != build ]; then exit 0; fi
scratch=""
configuration=""
show_path=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scratch-path) scratch="$2"; shift ;;
    -c) configuration="$2"; shift ;;
    --show-bin-path) show_path=1 ;;
  esac
  shift
done
test -n "$scratch"
test -n "$configuration"
product="$scratch/bin/$configuration"
if [ "$show_path" = 1 ]; then
  printf '%s\\n' "$product"
  exit 0
fi
mkdir -p "$product/PersonaStackDesktop_PersonaStackCore.bundle"
printf 'fresh-%s' "$configuration" > "$product/PersonaStack"
chmod 755 "$product/PersonaStack"
printf hook > "$product/PersonaStackHarnessHook"
printf resource > "$product/PersonaStackDesktop_PersonaStackCore.bundle/fixture"
''')
        executable(tools / "plutil", "exit 0\n")
        executable(tools / "ditto", 'cp -R "$1" "$2"\n')
        for relative in [
            "Resources/Info.plist", "Resources/AppIcon.icns", "Resources/MenuBarIcon.png",
            "Resources/ReleaseSigningCertificate.der",
            "Resources/LaunchAgents/ai.personastack.desktop.crash-recovery.plist",
            "Resources/LaunchAgents/ai.personastack.desktop.agent-bridge.plist",
            ".build/checkouts/Sparkle/LICENSE",
            ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Sparkle",
        ]:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        bundler = root / "third_party/imsg/bundle.py"
        bundler.parent.mkdir(parents=True)
        bundler.write_text(f'from pathlib import Path\nwith Path({str(trace)!r}).open("a") as output: output.write("bundle-provider\\n")\n')
        environment = {
            **os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "PERSONASTACK_DEFAULT_URL": "https://example.invalid/user/personas",
            "PERSONASTACK_CODESIGN_IDENTITY": "synthetic identity",
            "PERSONASTACK_CODESIGN_KEYCHAIN": str(root / "synthetic.keychain"),
            "PERSONASTACK_SPARKLE_PUBLIC_ED_KEY": "", "CONFIGURATION": "release",
        }
        environment.pop("PERSONASTACK_INSTALLER_SIGNING_IDENTITY", None)
        return scripts / SOURCE.name, trace, environment

    def test_app_only_builds_and_verifies_without_notarization_or_installer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command, trace, environment = self.fixture(root)
            result = subprocess.run(["sh", str(command), "--app-only"], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = trace.read_text().splitlines()
            self.assertIn("bundle-provider", calls)
            self.assertLess(calls.index("bundle-lima"), calls.index("sign-app.sh"))
            self.assertLess(calls.index("bundle-provider"), calls.index("sign-app.sh"))
            self.assertLess(calls.index("sign-app.sh"), calls.index("verify-update-bundle.sh"))
            self.assertNotIn("notarize", calls)
            self.assertFalse((root / "artifacts").exists())
            self.assertIn("Signed app candidate:", result.stdout)

    def test_app_only_selects_current_configuration_with_a_stale_release_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command, trace, environment = self.fixture(root)
            environment.update(CONFIGURATION="debug", CLEAN_BUILD="0")
            stale = root / "build/swift-arm64/bin/release"
            (stale / "PersonaStackDesktop_PersonaStackCore.bundle").mkdir(parents=True)
            (stale / "PersonaStack").write_text("stale-release")
            (stale / "PersonaStack").chmod(0o755)
            (stale / "PersonaStackHarnessHook").write_text("stale-hook")
            result = subprocess.run(["sh", str(command), "--app-only"], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            selected = root / "build/PersonaStack.app/Contents/MacOS/PersonaStack"
            self.assertEqual(selected.read_text(), "fresh-debug")
            self.assertEqual((stale / "PersonaStack").read_text(), "stale-release")
            self.assertIn("verify-update-bundle.sh", trace.read_text().splitlines())

    def test_normal_packaging_keeps_the_notarization_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command, trace, environment = self.fixture(root)
            environment["PERSONASTACK_INSTALLER_SIGNING_IDENTITY"] = "synthetic installer"
            result = subprocess.run(["sh", str(command)], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertEqual(trace.read_text().splitlines()[-1], "notarize")

    def test_unknown_packaging_mode_is_rejected_before_build_or_signing(self):
        result = subprocess.run(["sh", str(SOURCE), "--unexpected"], env={"PATH": os.environ["PATH"]}, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


class IMessageProviderSigningTests(unittest.TestCase):
    def test_provider_gets_only_apple_events_before_parent_is_signed(self):
        repository = SOURCE.parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            command = scripts / "sign-app.sh"
            shutil.copyfile(repository / "scripts/sign-app.sh", command)
            (scripts / "communication_profile.py").write_text("pass\n")
            (scripts / "lima_runtime.py").write_text("pass\n")
            for name in ["verify-sparkle-runtime.sh", "verify-app-signature.sh"]:
                (scripts / name).write_text("#!/bin/sh\nexit 0\n")
                (scripts / name).chmod(0o755)
            resources = root / "Resources"
            resources.mkdir()
            entitlement = resources / "IMessageProvider.entitlements"
            shutil.copyfile(repository / "Resources/IMessageProvider.entitlements", entitlement)
            self.assertEqual(plistlib.loads(entitlement.read_bytes()), {"com.apple.security.automation.apple-events": True})
            bundle = root / "Candidate.app"
            (bundle / "Contents/Resources").mkdir(parents=True)
            (bundle / "Contents/Resources/imsg-provider-manifest.json").write_text("{}")
            bundler = root / "third_party/imsg/bundle.py"
            bundler.parent.mkdir(parents=True)
            bundler.write_text("pass\n")
            tools = root / "tools"
            tools.mkdir()
            trace = root / "calls.jsonl"
            codesign = tools / "codesign"
            codesign.write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["IMESSAGE_SIGN_TRACE"], "a") as output: output.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            codesign.chmod(0o755)
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
                           "PERSONASTACK_CODESIGN_IDENTITY": "synthetic", "PERSONASTACK_CODESIGN_KEYCHAIN": "synthetic",
                           "IMESSAGE_SIGN_TRACE": str(trace)}
            result = subprocess.run(["sh", str(command), str(bundle)], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in trace.read_text().splitlines()]
            provider_index = next(i for i, args in enumerate(calls) if "ai.personastack.desktop.imsg" in args)
            parent_index = next(i for i, args in enumerate(calls) if "ai.personastack.desktop" in args)
            lima_index = next(i for i, args in enumerate(calls) if "ai.personastack.desktop.lima" in args)
            self.assertLess(lima_index, parent_index)
            lima = calls[lima_index]
            self.assertIn("runtime", lima)
            self.assertIn("--timestamp", lima)
            self.assertEqual(lima[lima.index("--entitlements") + 1], str(resources / "Lima.entitlements"))
            self.assertEqual(lima[-1], str(bundle / "Contents/Resources/LocalCluster/lima/bin/limactl"))
            self.assertLess(provider_index, parent_index)
            provider = calls[provider_index]
            self.assertEqual(provider[provider.index("--entitlements") + 1], str(entitlement))
            self.assertEqual(provider[-1], str(bundle / "Contents/MacOS/imsg"))


class IMessageCISelectionTests(unittest.TestCase):
    repository = SOURCE.parents[1]
    probe_path = "Experiments/IMessageBridgeProbe/Tests/IMessageBridgeProbeTests"

    def test_root_package_compiles_probe_tests_with_the_actual_core_dependency(self):
        package = (self.repository / "Package.swift").read_text()
        target = re.search(
            r'\.testTarget\(\s*name:\s*"IMessageBridgeProbeTests"(?P<body>.*?)\)\s*,',
            package, re.DOTALL,
        )
        self.assertIsNotNone(target, "Root native validation must compile the guarded provider-backend tests")
        body = target.group("body")
        dependencies = re.search(r'dependencies:\s*\[([^\]]*)\]', body)
        self.assertIsNotNone(dependencies)
        self.assertEqual(set(re.findall(r'"([^"]+)"', dependencies.group(1))),
                         {"PersonaStackCore", "IMessageBridgeProbe"})
        self.assertIn(f'path: "{self.probe_path}"', body)
        self.assertTrue((self.repository / self.probe_path / "CoreProbeBackendTests.swift").is_file())

    def test_both_native_workflow_filters_select_actual_imessage_and_probe_tests(self):
        def test_names(sources):
            names = []
            for source in sorted(sources):
                names.extend(re.findall(r'@Test\b(?:(?!\bfunc\b).)*\bfunc\s+(\w+)\s*\(',
                                        source.read_text(), re.DOTALL))
            return names

        native_directory = self.repository / "Tests/PersonaStackTests"
        native_sources = list(native_directory.glob("IMessage*Tests.swift"))
        native_sources.append(native_directory / "DesktopControlCredentialStoreTests.swift")
        native = [f"PersonaStackTests.{name}()" for name in test_names(native_sources)]
        probe = [f"IMessageBridgeProbeTests.{name}()" for name in
                 test_names((self.repository / self.probe_path).glob("*.swift"))]
        self.assertTrue(native, "No real native iMessage tests were discovered by the selector regression")
        self.assertTrue(probe, "No real probe tests were discovered by the selector regression")
        self.assertTrue(any("firstCheckpointIsOnlyMetadataBaseline" in name for name in probe))
        for workflow in ["validate-source.yml", "release.yml"]:
            with self.subTest(workflow=workflow):
                source = (self.repository / ".github/workflows" / workflow).read_text()
                filters = [re.compile(match.group(2)) for match in
                           re.finditer(r"--filter\s+(['\"])(.*?)\1", source, re.DOTALL)]
                self.assertTrue(filters, f"{workflow} has no native Swift test selector")
                missing = [name for name in native + probe if not any(pattern.search(name) for pattern in filters)]
                self.assertEqual(len(missing), 0, f"{workflow} excludes {len(missing)} iMessage/probe tests: {missing[:5]}")


if __name__ == "__main__":
    unittest.main()
