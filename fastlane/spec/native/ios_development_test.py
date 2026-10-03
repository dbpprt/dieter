from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("ios_development", Path(__file__).resolve().parents[2] / "lib/dieter/native/ios_development.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class DevelopmentProfilesTest(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 4, tzinfo=timezone.utc)
        self.request = dict(team="ABCDEFGHIJ", device="exact-phone", app="com.test.e2e", share="com.test.e2e.share", group="group.com.test.e2e", now=self.now)
        self.identity = hashlib.sha1(b"development-certificate").hexdigest().upper()
        self.profiles = [dict(UUID=f"11111111-1111-1111-1111-{index:012d}", TeamIdentifier=[self.request["team"]], ProvisionedDevices=[self.request["device"]], CreationDate=self.now - timedelta(days=1), ExpirationDate=self.now + timedelta(days=30), DeveloperCertificates=[b"development-certificate"], Entitlements={"get-task-allow": True, "application-identifier": self.request["team"] + "." + bundle, "com.apple.security.application-groups": [self.request["group"]]}) for index, bundle in enumerate([self.request["app"], self.request["share"], self.request["app"] + ".uitests.xctrunner"])]

    def test_requires_exact_device_development_entitlements_and_one_common_available_key(self):
        result = signing.select(self.profiles, [self.identity], **self.request)
        self.assertEqual(self.identity, result["certificate"])
        self.assertEqual(self.profiles[2]["UUID"], result["runner"])
        for profile in self.profiles:
            original = profile["ProvisionedDevices"]
            profile["ProvisionedDevices"] = ["another-phone"]
            with self.assertRaises(ValueError):
                signing.select(self.profiles, [self.identity], **self.request)
            profile["ProvisionedDevices"] = original
        with self.assertRaises(ValueError):
            signing.select(self.profiles, ["0" * 40], **self.request)

    def test_expired_future_issued_and_distribution_profiles_cannot_sign_device_tests(self):
        for key, value in [("ExpirationDate", self.now), ("CreationDate", self.now + timedelta(days=1)), ("CreationDate", None)]:
            previous = self.profiles[0][key]
            self.profiles[0][key] = value
            with self.assertRaises(ValueError):
                signing.select(self.profiles, [self.identity], **self.request)
            self.profiles[0][key] = previous
        self.profiles[0]["Entitlements"]["get-task-allow"] = False
        with self.assertRaises(ValueError):
            signing.select(self.profiles, [self.identity], **self.request)


if __name__ == "__main__":
    unittest.main()
