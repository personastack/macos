"""Prove artifact custody and the nested signing gate with inert fixtures."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("lima_runtime", SCRIPTS / "lima_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class LimaRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Candidate With Spaces.app"
        self.app.mkdir()
        self.data = {
            RUNTIME.EXECUTABLE: struct.pack("<IIII", 0xFEEDFACF, 0x0100000C, 0, 2) + b"inert executable",
            "share/lima/lima-guestagent.Linux-aarch64.gz": b"inert guestagent",
            "share/doc/lima/LICENSE": b"license",
            "share/doc/lima/VERSION": b"2.2.1\n",
        }
        self.files = {name: (len(data), hashlib.sha256(data).hexdigest()) for name, data in self.data.items()}
        self.archive = self.root / "lima.tar.gz"
        self.make_archive()
        self.pin = {"version": "2.2.1", "url": "https://github.com/lima-vm/lima/releases/download/v2.2.1/lima-2.2.1-Darwin-arm64.tar.gz",
                    "size": self.archive.stat().st_size, "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.addCleanup(patch.stopall)
        patch.object(RUNTIME, "FILES", self.files).start()
        patch.object(RUNTIME, "artifact_pin", return_value=self.pin).start()

    def make_archive(self, extra=None):
        with tarfile.open(self.archive, "w:gz") as output:
            for name, data in self.data.items():
                member = tarfile.TarInfo("./" + name)
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
            if extra:
                output.addfile(extra)

    def test_preparation_selects_only_reviewed_runtime_and_preserves_license(self):
        RUNTIME.prepare(self.app, self.archive)
        root, manifest = RUNTIME.verify(self.app, sealed=False)
        self.assertEqual((root / "share/doc/lima/LICENSE").read_bytes(), b"license")
        self.assertEqual(manifest["artifact"], self.pin)
        self.assertFalse((root / "libexec").exists())
        self.assertFalse(manifest["sealed"])
        with self.assertRaisesRegex(ValueError, "receipt"):
            RUNTIME.verify(self.app)

    def test_signing_changes_only_host_code_before_resource_seal(self):
        RUNTIME.prepare(self.app, self.archive)
        root = RUNTIME.bundle_root(self.app)
        with (root / RUNTIME.EXECUTABLE).open("ab") as output:
            output.write(b"fake codesign bytes")
        RUNTIME.seal(self.app)
        _, manifest = RUNTIME.verify(self.app)
        self.assertTrue(manifest["sealed"])
        self.assertNotEqual(manifest["files"][RUNTIME.EXECUTABLE], self.files[RUNTIME.EXECUTABLE][1])
        with self.assertRaisesRegex(ValueError, "freshly prepared"):
            RUNTIME.seal(self.app)

    def test_unsigned_archive_and_postsign_resource_tampering_are_rejected(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "descriptor"):
            RUNTIME.prepare(self.app, self.archive)
        self.make_archive()
        RUNTIME.prepare(self.app, self.archive)
        root = RUNTIME.bundle_root(self.app)
        (root / "share/doc/lima/LICENSE").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            RUNTIME.seal(self.app)

    def test_extra_executable_symlinks_and_unsafe_archive_members_are_rejected(self):
        RUNTIME.prepare(self.app, self.archive)
        root = RUNTIME.bundle_root(self.app)
        extra = root / "extra"
        extra.symlink_to(root / RUNTIME.EXECUTABLE)
        with self.assertRaisesRegex(ValueError, "Unexpected content"):
            RUNTIME.verify(self.app, sealed=False)
        other = self.root / "Other.app"
        other.mkdir()
        unsafe = tarfile.TarInfo("../outside")
        self.make_archive(unsafe)
        self.pin.update(size=self.archive.stat().st_size, sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            RUNTIME.prepare(other, self.archive)

    def test_wrong_host_architecture_rejected(self):
        RUNTIME.prepare(self.app, self.archive)
        executable = RUNTIME.bundle_root(self.app) / RUNTIME.EXECUTABLE
        executable.write_bytes(struct.pack("<IIII", 0xFEEDFACF, 0x01000007, 0, 2))
        with self.assertRaisesRegex(ValueError, "ARM64"):
            RUNTIME.require_executable(executable)

    def test_member_links_duplicates_and_linked_destination_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.REGTYPE):
            with self.subTest(kind=kind):
                app = self.root / ("Symlink.app" if kind == tarfile.SYMTYPE else "Duplicate.app")
                app.mkdir()
                member = tarfile.TarInfo("./" + RUNTIME.EXECUTABLE)
                member.type = kind
                member.linkname = "/outside"
                self.make_archive(member)
                self.pin.update(size=self.archive.stat().st_size, sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest())
                with self.assertRaisesRegex(ValueError, "Invalid or duplicate"):
                    RUNTIME.prepare(app, self.archive)
        contents = self.app / "Contents"
        contents.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Linked runtime"):
            RUNTIME.bundle_root(self.app, create=True)


class LimaSignatureGateTests(unittest.TestCase):
    def test_signature_gate_checks_identity_timestamp_runtime_and_exact_entitlements(self):
        for mode in ("valid", "wrong-arch", "adhoc", "wrong-team", "no-runtime", "no-timestamp", "extra-entitlement", "wrong-cert", "bad-requirement"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts = root / "scripts"
                scripts.mkdir()
                shutil.copy(SCRIPTS / "verify-lima-runtime.sh", scripts)
                (scripts / "lima_runtime.py").write_text("pass\n")
                shutil.copyfile(SCRIPTS / "verify-arm64-binaries.sh", scripts / "verify-arm64-binaries.sh")
                (scripts / "verify-arm64-binaries.sh").chmod(0o644)
                resources = root / "Resources"
                resources.mkdir()
                (resources / "ReleaseSigningCertificate.der").write_text("expected")
                tools = root / "tools"
                tools.mkdir()
                lipo = tools / "lipo"
                lipo.write_text("#!/bin/sh\ntest \"$1\" = -archs\nif [ \"$LIMA_SIGN_MODE\" = wrong-arch ]; then printf '%s\\n' x86_64; else printf '%s\\n' arm64; fi\n")
                lipo.chmod(0o755)
                codesign = tools / "codesign"
                codesign.write_text('''#!/usr/bin/env python3
import os, pathlib, plistlib, sys
mode = os.environ['LIMA_SIGN_MODE']
args = sys.argv[1:]
if '--verify' in args:
    assert '--strict' in args and '-R' in args
    assert 'ai.personastack.desktop.lima' in args[args.index('-R')+1]
    raise SystemExit(mode in {'adhoc', 'bad-requirement'})
prefix = next((a.split('=',1)[1] for a in args if a.startswith('--extract-certificates=')), None)
if prefix:
    pathlib.Path(prefix+'0').write_text('wrong' if mode == 'wrong-cert' else 'expected')
elif '--entitlements' in args:
    value = {'com.apple.security.virtualization': True}
    if mode == 'extra-entitlement': value['com.apple.security.get-task-allow'] = True
    sys.stdout.buffer.write(plistlib.dumps(value))
else:
    print('Identifier=ai.personastack.desktop.lima')
    print('TeamIdentifier=' + ('WRONG' if mode == 'wrong-team' else '5T2T8KL852'))
    if mode != 'no-runtime': print('CodeDirectory flags=0x10000(runtime)')
    if mode != 'no-timestamp': print('Timestamp=fixture timestamp')
''')
                codesign.chmod(0o755)
                result = subprocess.run(["sh", str(scripts / "verify-lima-runtime.sh"), "Fixture.app"],
                                        env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"], "LIMA_SIGN_MODE": mode},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, mode == "valid", result.stderr)


class LimaSigningContinuityTests(unittest.TestCase):
    def test_positive_fixtures_supply_unsigned_runtime_to_real_signer_and_negatives_keep_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            tools = root / "tools"
            tools.mkdir()
            resources = root / "Resources"
            resources.mkdir()
            for name in ("Lima.entitlements", "Release.entitlements"):
                shutil.copyfile(SCRIPTS.parent / "Resources" / name, resources / name)
            trace = root / "trace.jsonl"

            def executable(path, body):
                path.write_text("#!/usr/bin/env python3\n" + body)
                path.chmod(0o755)

            continuity = (SCRIPTS / "test-signing-continuity.sh").read_text()
            continuity = continuity.replace("openssl_bin=/usr/bin/openssl", "openssl_bin=" + str(tools / "openssl"))
            command = scripts / "test-signing-continuity.sh"
            command.write_text(continuity)
            shutil.copyfile(SCRIPTS / "sign-app.sh", scripts / "sign-app.sh")
            (scripts / "sign-app.sh").chmod(0o755)
            (scripts / "communication_profile.py").write_text("pass\n")
            (scripts / "verify-sparkle-runtime.sh").write_text("#!/bin/sh\nexit 0\n")
            executable(scripts / "lima_runtime.py", '''import json, os, pathlib, sys
operation, app = sys.argv[1:]
app = pathlib.Path(app)
runtime = app / 'Contents/Resources/LocalCluster/lima'
manifest = runtime / 'runtime-manifest.json'
with open(os.environ['LIMA_CONTINUITY_TRACE'], 'a') as log: log.write(json.dumps([operation, app.name])+'\\n')
if operation == 'prepare':
    (runtime/'bin').mkdir(parents=True)
    (runtime/'bin/limactl').write_bytes(b'ARM64 inert fixture')
    (runtime/'bin/limactl').chmod(0o755)
    (runtime/'share/lima').mkdir(parents=True)
    (runtime/'share/lima/lima-guestagent.Linux-aarch64.gz').write_bytes(b'guestagent')
    manifest.write_text('unsigned')
elif operation == 'verify-unsigned':
    assert manifest.read_text() == 'unsigned', 'fixture lacks unsigned Lima receipt'
    assert (runtime/'share/lima/lima-guestagent.Linux-aarch64.gz').read_bytes() == b'guestagent'
    for binary in ('PersonaStack', 'PersonaStackHarnessHook', 'PersonaStackAgentBridge'):
        assert (app/'Contents/MacOS'/binary).read_bytes() == b'ARM64 inert fixture'
elif operation == 'seal':
    assert manifest.read_text() == 'unsigned'
    manifest.write_text('sealed')
else: raise SystemExit('unplanned runtime operation')
''')
            executable(scripts / "verify-app-signature.sh", '''import json, os, pathlib, sys
app = pathlib.Path(sys.argv[1])
with open(os.environ['LIMA_CONTINUITY_TRACE'], 'a') as log: log.write(json.dumps(['verify-app', app.name])+'\\n')
runtime = app/'Contents/Resources/LocalCluster/lima'
assert (runtime/'runtime-manifest.json').read_text() == 'sealed'
assert (runtime/'share/lima/lima-guestagent.Linux-aarch64.gz').read_bytes() == b'guestagent'
raise SystemExit(app.name in {'foreign.app', 'adhoc.app'} or (app/'Contents/Resources/probe.txt').read_text().strip() == 'tampered')
''')
            executable(tools / "codesign", '''import pathlib, sys
args = sys.argv[1:]
app = pathlib.Path(args[-1])
if '--display' in args:
    print('designated => identifier "ai.personastack.desktop" and anchor apple generic')
elif '--verify' in args:
    raise SystemExit(app.name == 'foreign.app')
elif '--force' not in args:
    raise SystemExit('unplanned codesign operation')
''')
            executable(tools / "openssl", '''import sys
if sys.argv[1] == 'rand': print('fixture-password')
elif sys.argv[1] == 'x509': print('sha1 Fingerprint=00:11:22')
elif sys.argv[1] not in {'req', 'pkcs12'}: raise SystemExit('unplanned openssl operation')
''')
            executable(tools / "security", '''import sys
if sys.argv[1] == 'list-keychains' and '-s' not in sys.argv: print('"/fixture/existing.keychain"')
''')
            environment = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                           "PERSONASTACK_CODESIGN_IDENTITY": "inert fixture identity",
                           "PERSONASTACK_CODESIGN_KEYCHAIN": "inert fixture keychain",
                           "LIMA_CONTINUITY_TRACE": str(trace)}
            result = subprocess.run(["sh", str(command)], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in trace.read_text().splitlines()]
            self.assertEqual(calls, [
                ['prepare', 'runtime.app'], ['verify-unsigned', 'first.app'], ['seal', 'first.app'], ['verify-app', 'first.app'],
                ['verify-unsigned', 'second.app'], ['seal', 'second.app'], ['verify-app', 'second.app'],
                ['verify-app', 'foreign.app'], ['verify-app', 'adhoc.app'], ['verify-app', 'second.app'],
            ])
            self.assertIn('Signing continuity, foreign-signer rejection, ad-hoc rejection, and resource seals passed.', result.stdout)


if __name__ == "__main__":
    unittest.main()
