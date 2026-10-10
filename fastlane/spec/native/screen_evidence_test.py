import copy
import json
from pathlib import Path
import tempfile
import unittest
from fastlane.lib.dieter.native.screen_evidence import compare, complete_mac_recovery, qualify


class QualificationContract(unittest.TestCase):
    def test_mac_latency_retains_evidence_and_still_requires_execution(self):
        def run(log="✔ Test run with 2 tests in 1 suite passed", latency=True, link=False):
            with tempfile.TemporaryDirectory() as root:
                directory = Path(root)
                (directory / "viewer.png").write_bytes(b"png")
                (directory / "screens.log").write_text(log)
                native = directory / "native"
                native.mkdir()
                if latency:
                    source = directory / "private.json" if link else native / "latency.json"
                    source.write_text(json.dumps({"inputP95Ms": 60, "inputSamples": 200}))
                    if link:
                        (native / "latency.json").symlink_to(source)
                return qualify({"directory": root, "runner": "mac-latency"})

        result = run()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["metrics"]["inputP95Ms"], 60)
        self.assertIn("viewer.png", result["artifacts"])
        self.assertTrue(any(a.endswith("-latency.json") for a in result["artifacts"]))
        self.assertEqual(run(log="✔ Test run with 0 tests in 0 suites passed")["status"], "failed")
        self.assertEqual(run(latency=False)["status"], "failed")
        linked = run(link=True)
        self.assertEqual(linked["status"], "failed")
        self.assertNotIn("private.json", linked["artifacts"])

    def test_comparison_requires_matching_measurements_and_sample_count(self):
        value = {
            "hardware": {"model": "fixture"},
            "cases": [
                {
                    "id": "motion",
                    "status": "passed",
                    "scenario": {"runner": "mac-latency"},
                    "metrics": {
                        "inputP95Ms": 60,
                        "inputSamples": 200,
                        "achievedFps": 60,
                        "presentationEndpoint": "metal-presented-time",
                        "codec": "h264",
                        "requestedFps": 60,
                        "width": 1440,
                        "height": 810,
                    },
                }
            ],
        }
        before = copy.deepcopy(value)
        self.assertEqual(compare(value, before)["status"], "passed")
        value["cases"][0]["metrics"]["achievedFps"] = 30
        self.assertEqual(compare(value, before)["status"], "failed")
        value["cases"][0]["metrics"]["presentationEndpoint"] = "egl-submitted"
        self.assertEqual(compare(value, before)["cases"][0]["status"], "unavailable")
        value["hardware"]["model"] = "another device"
        self.assertEqual(compare(value, before)["status"], "unavailable")

    def test_missing_or_invalid_measurements_never_pass_by_matching_each_other(self):
        metrics = {
            "inputP95Ms": 60,
            "inputSamples": 200,
            "achievedFps": 60,
            "presentationEndpoint": "metal-presented-time",
            "codec": "h264",
            "requestedFps": 60,
            "width": 1440,
            "height": 810,
        }
        for key in metrics:
            for invalid in (
                (None, False, float("nan"), float("inf"))
                if key not in ("codec", "presentationEndpoint")
                else (None, "")
            ):
                with self.subTest(key=key, invalid=invalid):
                    value = {
                        "hardware": {},
                        "cases": [
                            {
                                "id": "motion",
                                "status": "passed",
                                "scenario": {"runner": "mac-latency"},
                                "metrics": dict(metrics, **{key: invalid}),
                            }
                        ],
                    }
                    self.assertNotEqual(compare(value, copy.deepcopy(value))["status"], "passed")
        value["cases"][0]["metrics"] = dict(metrics, inputSamples=199)
        self.assertNotEqual(compare(value, copy.deepcopy(value))["status"], "passed")

    def test_native_runner_summary_cannot_hide_a_partial_matrix(self):
        summary = "✔ Test remoteDesktopRecoveryAuthenticatedTransport() passed"
        self.assertFalse(complete_mac_recovery(summary))
        cells = [
            f"RECOVERY codec={codec} mode={mode} frames=400 max_gap_ms=100"
            for codec in ("H264", "H265")
            for mode in ("baseline", "ltr", "fec", "both")
        ]
        proofs = [
            f"FEC PROOF codec={codec} decoded RTP timestamp=9000 with original and retransmissions discarded"
            for codec in ("H264", "H265")
            for _ in range(2)
        ]
        self.assertTrue(complete_mac_recovery("\n".join([summary, *cells, *proofs])))
        self.assertFalse(complete_mac_recovery("\n".join([summary, *cells[:-1], *proofs])))
        self.assertFalse(complete_mac_recovery("\n".join([summary, *cells, *proofs[:-1]])))
        executed = "✔ Test run with 1 test in 1 suite passed"
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "screens.log"
            request = {"directory": root, "runner": "mac-recovery"}
            log.write_text("\n".join([summary, *cells, *proofs, executed]))
            self.assertEqual(qualify(request)["status"], "passed")
            log.write_text("\n".join([summary, *cells[:-1], *proofs, executed]))
            self.assertEqual(qualify(request)["status"], "failed")
            log.write_text("\n".join([summary, *cells, *proofs]))
            self.assertEqual(qualify(request)["status"], "failed")


if __name__ == "__main__":
    unittest.main()
