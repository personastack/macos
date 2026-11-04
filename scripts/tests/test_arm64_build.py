"""Exercise the native helper target and exact owned-binary architecture gate."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class ARM64BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="personastack-arm64-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        CALL_LOG=str(self.log), ARCHITECTURES="arm64")
        self.shim("lipo", """import os, sys
if sys.argv[1] != '-archs':
    raise SystemExit('unplanned lipo operation')
print(os.environ['ARCHITECTURES'])
""")

    def shim(self, name, body):
        path = self.root / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(["sh", str(SCRIPTS / name), *map(str, args)],
                              env=self.env, capture_output=True, text=True)

    def test_helper_build_targets_only_darwin_arm64_with_offline_modules(self):
        self.shim("xcrun", """import sys
assert sys.argv[1:] == ['--sdk', 'macosx', '--show-sdk-path']
print('/fixture/MacOS SDK')
""")
        self.shim("go", """import json, os, pathlib, sys
keys = ['GOOS', 'GOARCH', 'CGO_ENABLED', 'CC', 'CGO_CFLAGS', 'CGO_LDFLAGS',
        'GOFLAGS', 'GOPROXY', 'GOSUMDB']
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps({'args': sys.argv[1:], 'env': {k: os.environ[k] for k in keys}}) + '\\n')
args = sys.argv[1:]
assert args[0] == 'build'
pathlib.Path(args[args.index('-o') + 1]).write_text('fixture executable')
""")
        output = self.root / "Output With Spaces"
        result = self.run_script("build-agent-bridge.sh", output, "0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertEqual(call["env"], {
            "GOOS": "darwin", "GOARCH": "arm64", "CGO_ENABLED": "1",
            "CC": "clang -arch arm64",
            "CGO_CFLAGS": "-isysroot /fixture/MacOS SDK -mmacosx-version-min=14.0",
            "CGO_LDFLAGS": "-isysroot /fixture/MacOS SDK -mmacosx-version-min=14.0",
            "GOFLAGS": "-mod=vendor", "GOPROXY": "off", "GOSUMDB": "off",
        })
        self.assertEqual(call["args"], [
            "build", "-trimpath", "-ldflags",
            "-X github.com/personastack/macos/agent-bridge/internal/buildinfo.Version=0.2.0",
            "-o", str(output / "PersonaStackAgentBridge"), "./cmd/personastack-agent-bridge",
        ])
        binary = output / "PersonaStackAgentBridge"
        self.assertTrue(binary.stat().st_mode & 0o111)
        self.assertEqual(list(output.iterdir()), [binary])

    def test_owned_executables_require_exactly_arm64(self):
        for architectures in ("arm64", "x86_64", "arm64 x86_64", "x86_64 arm64", ""):
            with self.subTest(architectures=architectures):
                self.env["ARCHITECTURES"] = architectures
                result = self.run_script("verify-arm64-binaries.sh", "App With Spaces/PersonaStack")
                self.assertEqual(result.returncode == 0, architectures == "arm64", result.stderr)
                if architectures != "arm64":
                    self.assertIn("Expected ARM64-only executable", result.stderr)

    def test_gate_propagates_unreadable_binary_failure(self):
        self.shim("lipo", "raise SystemExit(7)\n")
        result = self.run_script("verify-arm64-binaries.sh", "missing binary")
        self.assertEqual(result.returncode, 7)

    def test_gate_checks_every_owned_binary(self):
        self.shim("lipo", """import sys
print('x86_64' if sys.argv[-1].endswith('AgentBridge') else 'arm64')
""")
        result = self.run_script("verify-arm64-binaries.sh", "PersonaStack", "PersonaStackHarnessHook", "PersonaStackAgentBridge")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PersonaStackAgentBridge", result.stderr)
