import copy
import datetime
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("communication_profile", ROOT / "scripts/communication_profile.py")
profile_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile_module)


class CommunicationProfileTests(unittest.TestCase):
    def test_rejects_profiles_that_cannot_authorize_the_release(self):
        now = datetime.datetime(2026, 10, 11)
        certificate = b"pinned-public-certificate"
        profile = {
            "TeamIdentifier": [profile_module.TEAM], "ProvisionsAllDevices": True, "Platform": ["OSX"],
            "ExpirationDate": now + datetime.timedelta(days=1), "DeveloperCertificates": [certificate],
            "Entitlements": {
                "com.apple.application-identifier": profile_module.APP_ID,
                "com.apple.developer.team-identifier": profile_module.TEAM,
                profile_module.CAPABILITY: True,
            },
        }
        profile_module.validate(profile, certificate, now)
        for key, value in [("TeamIdentifier", ["foreign"]), ("ProvisionsAllDevices", False),
                           ("Platform", ["iOS"]), ("ExpirationDate", now), ("ExpirationDate", None),
                           ("DeveloperCertificates", [b"foreign"])]:
            with self.subTest(key=key):
                invalid = copy.deepcopy(profile)
                invalid[key] = value
                with self.assertRaises(ValueError):
                    profile_module.validate(invalid, certificate, now)
        for key, value in [("com.apple.application-identifier", "foreign"),
                           ("com.apple.developer.team-identifier", "foreign"),
                           (profile_module.CAPABILITY, False), ("get-task-allow", True)]:
            with self.subTest(entitlement=key):
                invalid = copy.deepcopy(profile)
                invalid["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    profile_module.validate(invalid, certificate, now)

    def test_profile_precedes_signing_and_is_release_only(self):
        signer = (ROOT / "scripts/sign-app.sh").read_text()
        self.assertLess(signer.index("communication_profile.py"), signer.index("codesign --force"))
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("- name: Prepare communication notification profile", 1)[1].split("- name:", 1)[0]
        self.assertIn("github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')", step)
        self.assertIn("secrets.PERSONASTACK_COMMUNICATION_PROFILE_BASE64", step)
