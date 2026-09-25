import copy
import json
from pathlib import Path
import tempfile
import unittest
from qualify_screens import command, compare, complete_mac_recovery, recovery_evidence_error


class QualificationContract(unittest.TestCase):
    def test_exact_physical_serial_and_no_arbitrary_commands(self):
        for serial in (None, "emulator-5554"):
            with self.assertRaises(ValueError):
                command({"runner": "android-codec"}, serial)
        with self.assertRaises(ValueError):
            command({"runner": "shell"}, None)
        with self.assertRaises(ValueError):
            command({"runner": "native", "switches": {"DIETER_HOME": "/live"}}, None)
        with self.assertRaises(ValueError):
            command({"runner": "native", "switches": {"DIETER_SCREEN_OVERLAP": 50}}, None)
        with self.assertRaises(ValueError):
            command({"runner": "android-sdk"}, "emulator-5554")
        argv, _ = command({"runner": "android-sdk"}, "explicit-phone")
        self.assertEqual(argv, ["just", "e2e", "run", "--serial", "explicit-phone", "--suite", "sdk"])

    def test_comparison_requires_matching_measurements_and_sample_count(self):
        value = {"hardware": {"model": "fixture"}, "cases": [{"id": "motion", "status": "passed", "scenario": {"runner": "mac-latency"},
                 "metrics": {"inputP95Ms": 60, "inputSamples": 200, "achievedFps": 60, "presentationEndpoint": "metal-presented-time",
                             "codec": "h264", "requestedFps": 60, "width": 1440, "height": 810}}]}
        before = copy.deepcopy(value)
        self.assertEqual(compare(value, before)["status"], "passed")
        value["cases"][0]["metrics"]["achievedFps"] = 30
        self.assertEqual(compare(value, before)["status"], "failed")
        value["cases"][0]["metrics"]["presentationEndpoint"] = "egl-submitted"
        self.assertEqual(compare(value, before)["cases"][0]["status"], "unavailable")
        value["hardware"]["model"] = "another device"
        self.assertEqual(compare(value, before)["status"], "unavailable")

    def test_missing_or_invalid_measurements_never_pass_by_matching_each_other(self):
        metrics = {"inputP95Ms": 60, "inputSamples": 200, "achievedFps": 60, "presentationEndpoint": "metal-presented-time",
                   "codec": "h264", "requestedFps": 60, "width": 1440, "height": 810}
        for key in metrics:
            for invalid in (None, False, float("nan"), float("inf")) if key not in ("codec", "presentationEndpoint") else (None, ""):
                with self.subTest(key=key, invalid=invalid):
                    value = {"hardware": {}, "cases": [{"id": "motion", "status": "passed",
                             "scenario": {"runner": "mac-latency"}, "metrics": dict(metrics, **{key: invalid})}]}
                    self.assertNotEqual(compare(value, copy.deepcopy(value))["status"], "passed")
        value["cases"][0]["metrics"] = dict(metrics, inputSamples=199)
        self.assertNotEqual(compare(value, copy.deepcopy(value))["status"], "passed")

    def test_recovery_requires_both_codecs_exact_frame_and_actual_completion(self):
        case = {"codec": "H264", "decoder": "hardware", "nativeFramesDecoded": 20, "referenceRecoveries": 1,
                "presentationEndpoint": "REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED",
                "protectedRtpTimestamp": 9001, "decodedQuantizedRtpTimestamp": 9000,
                "postLossContinuityCheckMs": 260, "fecProbeToObservedDecodeMs": 50,
                "fault": {"mode": "proof-complete", "dropped": 1, "repair": 1, "repairedTimestamp": 9001}}
        evidence = {"schemaVersion": 1, "cases": [case, dict(case, codec="H265")]}
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            path = directory / "0-recovery.json"
            def check(value):
                path.write_text(json.dumps(value))
                return recovery_evidence_error(directory, [path.name])
            self.assertIsNone(check(evidence))
            self.assertIsNotNone(recovery_evidence_error(directory, []))
            self.assertIsNotNone(check({"schemaVersion": 1, "cases": [case]}))
            for key, invalid in (("decodedQuantizedRtpTimestamp", 9090), ("nativeFramesDecoded", 0),
                                 ("referenceRecoveries", 0), ("decoder", ""), ("fecProbeToObservedDecodeMs", -1),
                                 ("presentationEndpoint", "unknown"), ("protectedRtpTimestamp", 1 << 32)):
                with self.subTest(key=key):
                    bad = copy.deepcopy(evidence)
                    bad["cases"][0][key] = invalid
                    self.assertIsNotNone(check(bad))
            for key, invalid in (("dropped", 0), ("repair", 0), ("mode", "random"), ("repairedTimestamp", 9090)):
                bad = copy.deepcopy(evidence)
                bad["cases"][1]["fault"][key] = invalid
                self.assertIsNotNone(check(bad))
            path.write_text("broken artifact")
            self.assertIsNotNone(recovery_evidence_error(directory, [path.name]))

    def test_native_runner_summary_cannot_hide_a_partial_matrix(self):
        summary = "✔ Test remoteDesktopRecoveryAuthenticatedTransport() passed"
        self.assertFalse(complete_mac_recovery(summary))
        cells = [f"RECOVERY codec={codec} mode={mode} frames=400 max_gap_ms=100" for codec in ("H264", "H265") for mode in ("baseline", "ltr", "fec", "both")]
        proofs = [f"FEC PROOF codec={codec} decoded RTP timestamp=9000 with original and retransmissions discarded" for codec in ("H264", "H265") for _ in range(2)]
        self.assertTrue(complete_mac_recovery("\n".join([summary, *cells, *proofs])))
        self.assertFalse(complete_mac_recovery("\n".join([summary, *cells[:-1], *proofs])))
        self.assertFalse(complete_mac_recovery("\n".join([summary, *cells, *proofs[:-1]])))


if __name__ == "__main__":
    unittest.main()
