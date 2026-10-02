"""Check real Mach-O dependency lookup without credentials or launching an app."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-sparkle-runtime.sh"


@unittest.skipUnless(sys.platform == "darwin", "Mach-O validation requires macOS")
class SparkleRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="personastack-sparkle-fixture-")
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.root = Path(cls.fixture.name)
        source = cls.root / "fixture.c"
        source.write_text("int sparkle_fixture(void) { return 0; }\n")
        cls.library = cls.root / "Sparkle"
        subprocess.run(["cc", "-dynamiclib", str(source), "-o", str(cls.library),
                        "-Wl,-install_name,@rpath/Sparkle.framework/Versions/B/Sparkle"], check=True)
        source.write_text("extern int sparkle_fixture(void); int main(void) { return sparkle_fixture(); }\n")
        cls.binary = cls.root / "PersonaStack"
        subprocess.run(["cc", str(source), str(cls.library), "-o", str(cls.binary),
                        "-Wl,-rpath,@executable_path/../Frameworks"], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="personastack-sparkle-test-")
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "App With Spaces.app"
        self.executable = self.bundle / "Contents/MacOS/PersonaStack"
        self.framework = self.bundle / "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
        self.executable.parent.mkdir(parents=True)
        self.framework.parent.mkdir(parents=True)
        shutil.copy2(self.binary, self.executable)
        shutil.copy2(self.library, self.framework)

    def verify(self):
        return subprocess.run(["sh", str(SCRIPT), str(self.bundle)], capture_output=True, text=True)

    def test_bundled_dependency_and_runpath_pass(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_runpath_rejects_the_reported_crash(self):
        subprocess.run(["install_name_tool", "-delete_rpath", "@executable_path/../Frameworks",
                        str(self.executable)], check=True, capture_output=True)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the @executable_path/../Frameworks runpath", result.stderr)

    def test_missing_framework_is_rejected(self):
        self.framework.unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundled framework is missing", result.stderr)

    def test_signing_continuity_fixture_without_sparkle_passes(self):
        shutil.copyfile("/usr/bin/true", self.executable)
        self.framework.unlink()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_executable_is_rejected(self):
        self.executable.unlink()
        self.assertNotEqual(self.verify().returncode, 0)
