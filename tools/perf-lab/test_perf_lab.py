"""Tests for the Performance Lab analysis tool (#123).

Run: python3 -m unittest discover -s tools/perf-lab -p 'test_*.py'
"""

import copy
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf_lab  # noqa: E402

EDGES = [0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
         20, 22, 25, 28, 30, 33, 36, 40, 45, 50, 60, 70, 80, 90, 100, 125, 150, 175, 200, 250, 300,
         400, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000]


def histogram(stage_id, values):
    """A trial stage record exactly as the app builds it."""
    buckets = [0] * (len(EDGES) + 1)
    for v in values:
        i = next((k for k, e in enumerate(EDGES) if v <= e), len(EDGES))
        buckets[i] += 1
    lo, hi = min(values), max(values)
    rec = {"id": stage_id, "count": len(values), "sum": float(sum(values)), "min": float(lo), "max": float(hi), "buckets": buckets}
    for p, k in ((0.5, "p50"), (0.95, "p95"), (0.99, "p99")):
        rec[k] = perf_lab.hist_percentile(p, buckets, len(values), lo, hi, EDGES)
    return rec


SCENARIO = {
    "id": "extend.frame-counter", "version": 1, "caption": "Extend, frame counter", "purpose": "Test purpose.",
    "mode": "extend", "panes": "none", "workload": "frame-counter", "warmUpSeconds": 10, "trialWindows": 1,
    "primaryMetrics": ["source_unique_fps", "payload_mbps"], "expectsRestarts": False,
    "steps": [{"timing": "beforeRun", "instruction": "Do the thing."}],
}


def make_trial(index, unique, status="complete", issues=(), arrival=(59.0,), cpu=(10.0, 12.0), mem=(100.0, 104.0)):
    return {
        "format": perf_lab.TRIAL_FORMAT, "schemaVersion": 1, "synthetic": False, "scenarioID": SCENARIO["id"],
        "trialIndex": index, "status": status, "issues": list(issues), "warmUpSeconds": 10, "requestedWindows": 1,
        "measuredSeconds": 5.0,
        "windows": [{"sequence": i + 1, "offsetSeconds": 0, "durationSeconds": 5,
                     "snapshot": {"resources": {"processCPUPercent": c, "memoryFootprintMB": m, "thermalState": "nominal",
                                                "lowPowerMode": False}},
                     "verdict": {"cause": "noBottleneckEvident", "confidence": "medium"}}
                    for i, (c, m) in enumerate(zip(cpu, mem))],
        "stages": [histogram("sender.submit_interval_ms", [16, 17, 17, 18, 40])],
        "counters": {"sender.submit.source_unique": unique, "sender.send.bytes": 2_500_000, "sender.submit.live": unique},
        "gaps": {"sender.submit_interval_ms": [1, 0, 0]},
        "receiverSummaries": [{"offsetSeconds": 5 + i, "summary": {"side": "receiver", "arrivalFPS": a, "rttMs": 4}}
                              for i, a in enumerate(arrival)],
    }


def make_manifest(trials, synthetic=False, minimum=3):
    return {
        "format": perf_lab.RUN_FORMAT, "schemaVersion": 1, "synthetic": synthetic, "createdAt": "2026-11-17T09:30:00Z",
        "plan": {"scenario": SCENARIO, "trials": len(trials), "synthetic": synthetic},
        "minimumTrials": minimum, "workloadSignature": "frame-counter@1:counter/60", "frameIDVersion": 1,
        "environment": {"sender": {"appVersion": "2.0 (300)", "osMajor": 26, "osMinor": 1, "osPatch": 0,
                                   "platform": "macOS", "deviceClass": "mac"},
                        "commit": "4c0e8067", "context": {"displayMode": "extend", "codec": "hevc", "route": "usb"}},
        "metrics": [{"id": "sender.submit_interval_ms", "unit": "ms", "timebase": "localMonotonic",
                     "source": "Successive encoder submissions", "caveat": "Counts duplicates."}],
        "histogramUpperEdgesMs": EDGES, "windowSeconds": 5,
        "trials": [{"index": t["trialIndex"], "status": t["status"], "issues": t["issues"]} for t in trials],
        "limitations": ["A fixed limitation."],
    }


class BundleFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="perf-lab-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_bundle(self, name, trials, manifest=None, synthetic=False):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        with open(os.path.join(path, "manifest.json"), "w") as f:
            json.dump(manifest or make_manifest(trials, synthetic), f)
        for t in trials:
            with open(os.path.join(path, perf_lab.trial_file_name(t["trialIndex"])), "w") as f:
                json.dump(t, f)
        return path


class StatisticsTests(BundleFixture):
    def test_summary_matches_hand_computed_values(self):
        s = perf_lab.summarize([54.0, 60.0, 66.0, None])
        self.assertEqual(s["n"], 3)
        self.assertEqual(s["median"], 60.0)
        self.assertEqual(s["p95"], 66.0)  # nearest rank: ceil(0.95 * 3) = 3rd
        self.assertEqual((s["min"], s["max"], s["spread"]), (54.0, 66.0, 12.0))
        self.assertAlmostEqual(s["cv"], 0.1)  # sample stdev 6 / mean 60
        self.assertEqual(perf_lab.summarize([None])["n"], 0)
        self.assertIsNone(perf_lab.summarize([5.0])["cv"])

    def test_nearest_rank(self):
        values = list(range(1, 101))
        self.assertEqual(perf_lab.nearest_rank(values, 0.95), 95)
        self.assertEqual(perf_lab.nearest_rank(values, 0.99), 99)
        self.assertEqual(perf_lab.nearest_rank([3, 1, 2], 0.5), 2)

    def test_histogram_percentile_follows_the_app_rule(self):
        rec = histogram("x", [16, 17, 17, 18, 40])
        # p50: rank 3 → bucket (16,17] → 17; p95: rank 5 → bucket (36,40] → 40 clamped to max 40.
        self.assertEqual(rec["p50"], 17)
        self.assertEqual(rec["p95"], 40)
        one = histogram("y", [0.3])
        self.assertEqual(one["p50"], 0.3, "edge 0.5 clamped to the max")

    def test_per_trial_metrics_from_counters_stages_and_receiver(self):
        trial = make_trial(1, 300, arrival=(58.0, 60.0, 59.0))
        m = perf_lab.trial_metrics(trial)
        self.assertEqual(m["source_unique_fps"], 60.0)
        self.assertEqual(m["payload_mbps"], 4.0)  # 2.5 MB * 8 / 5 s
        self.assertEqual(m["submit_interval_p50_ms"], 17)
        self.assertEqual(m["submit_gaps_over_100ms"], 1)
        self.assertEqual(m["receiver_arrival_fps"], 59.0)
        self.assertEqual(m["sender_cpu_percent_median"], 11.0)
        self.assertEqual(m["sender_memory_mb_delta"], 4.0)
        self.assertIsNone(m["frame_id_unique_fps"], "no frame-ID data = not measured, never 0")
        self.assertIsNone(m["fixture_drawn_fps"])

    def test_report_uses_complete_trials_and_lists_all(self):
        trials = [make_trial(1, 270), make_trial(2, 300), make_trial(3, 330), make_trial(4, 30, "incomplete", ["stalled"])]
        b = perf_lab.load_bundle(self.write_bundle("run", trials))
        r = perf_lab.analyse(b)
        self.assertFalse(r["partial"])
        self.assertEqual(r["stats"]["source_unique_fps"]["median"], 60.0)
        self.assertEqual(r["stats"]["source_unique_fps"]["n"], 3)
        text = perf_lab.render_report(b, r)
        self.assertIn("T4 6.00 (incomplete)", text)
        self.assertIn("| 4 | incomplete | stalled |", text)
        self.assertIn("`run/trial-04.json`", text)
        self.assertNotIn(self.tmp, text, "no local absolute paths in reports")
        self.assertIn("### Benchmark run: 2026-11-17 / run — Extend, frame counter", text)
        for line in ("- Status:", "- Objective/hypothesis:", "- Trials (n >= 3)", "- Results:", "- Subjective observations",
                     "- Limitations", "- How another tester reproduces:", "- Evidence:"):
            self.assertIn(line, text)


class PartialAndValidationTests(BundleFixture):
    def test_fewer_complete_trials_than_minimum_is_refused(self):
        trials = [make_trial(1, 300), make_trial(2, 300), make_trial(3, 0, "failed", ["noSession"])]
        b = perf_lab.load_bundle(self.write_bundle("run", trials))
        with self.assertRaises(perf_lab.RefusedError):
            perf_lab.analyse(b)
        r = perf_lab.analyse(b, allow_partial=True)
        self.assertTrue(r["partial"])
        text = perf_lab.render_report(b, r)
        self.assertIn("[PARTIAL]", text)
        self.assertIn("PARTIAL: 2 complete trial(s)", text)
        self.assertIn("| 3 | failed | noSession |", text)

    def test_cli_refuses_partial_with_exit_code_2(self):
        trials = [make_trial(1, 300), make_trial(2, 0, "failed"), make_trial(3, 0, "failed")]
        path = self.write_bundle("run", trials)
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(perf_lab.main(["report", path]), 2)
        self.assertIn("--allow-partial", err.getvalue())
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(perf_lab.main(["report", path, "--allow-partial"]), 0)
        self.assertIn("[PARTIAL]", out.getvalue())

    def test_missing_trial_file_is_listed_as_failed_not_dropped(self):
        trials = [make_trial(1, 300), make_trial(2, 300), make_trial(3, 300)]
        path = self.write_bundle("run", trials)
        os.remove(os.path.join(path, "trial-02.json"))
        b = perf_lab.load_bundle(path)
        self.assertEqual([t["status"] for t in b.trials], ["complete", "failed", "complete"])
        self.assertEqual(b.trials[1]["issues"], ["missingTrialData"])

    def test_unsupported_schema_and_wrong_format_are_rejected(self):
        trials = [make_trial(1, 300)]
        m = make_manifest(trials)
        m["schemaVersion"] = 2
        with self.assertRaisesRegex(perf_lab.BundleError, "unsupported run schema"):
            perf_lab.load_bundle(self.write_bundle("v2", trials, m))
        m = make_manifest(trials)
        m["format"] = "something-else"
        with self.assertRaises(perf_lab.BundleError):
            perf_lab.load_bundle(self.write_bundle("fmt", trials, m))

    def test_status_mismatch_and_bad_histogram_are_rejected(self):
        t = make_trial(1, 300)
        m = make_manifest([t])
        m["trials"][0]["status"] = "incomplete"
        with self.assertRaisesRegex(perf_lab.BundleError, "differs from the manifest"):
            perf_lab.load_bundle(self.write_bundle("status", [t], m))
        bad = make_trial(1, 300)
        bad["stages"][0]["p95"] = 1.0
        with self.assertRaisesRegex(perf_lab.BundleError, "does not match its buckets"):
            perf_lab.load_bundle(self.write_bundle("hist", [bad]))

    def test_privacy_lint_rejects_personal_looking_keys(self):
        for bad_key in ("deviceName", "hostAddress", "windowTitle", "ssid", "filePath"):
            t = make_trial(1, 300)
            t["receiverSummaries"][0]["summary"][bad_key] = "x"
            with self.assertRaisesRegex(perf_lab.BundleError, "looks like"):
                perf_lab.load_bundle(self.write_bundle("priv-" + bad_key, [t]))
        ok = make_trial(1, 300)
        ok["windows"][0]["snapshot"]["context"] = {"pathExpensive": False, "presentationPath": "metal"}
        perf_lab.load_bundle(self.write_bundle("ok", [ok]))


class CompareTests(BundleFixture):
    def test_overlap_logic(self):
        def s(vals):
            return perf_lab.summarize(vals)
        self.assertEqual(perf_lab.compare_verdict(s([54.0, 60.0, 66.0]), s([70.0, 72.0, 75.0])), "B higher")
        self.assertEqual(perf_lab.compare_verdict(s([54.0, 60.0, 66.0]), s([40.0, 45.0, 50.0])), "B lower")
        self.assertEqual(perf_lab.compare_verdict(s([54.0, 60.0, 66.0]), s([64.0, 65.0, 80.0])), "not distinguishable (ranges overlap)")
        self.assertEqual(perf_lab.compare_verdict(s([54.0, 60.0, 66.0]), s([66.0, 70.0, 71.0])), "not distinguishable (ranges overlap)",
                         "touching ranges overlap")
        self.assertTrue(perf_lab.compare_verdict(s([]), s([1.0])).startswith("n/a"))

    def test_compare_report_deltas_and_environment_differences(self):
        a = [make_trial(i + 1, u) for i, u in enumerate((270, 300, 330))]
        b = [make_trial(i + 1, u) for i, u in enumerate((350, 360, 375))]
        pa = self.write_bundle("run-a", a)
        mb = make_manifest(b)
        mb["environment"]["context"]["codec"] = "h264"
        mb["plan"]["variant"] = "beta-on"
        pb = self.write_bundle("run-b", b, mb)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(perf_lab.main(["compare", pa, pb]), 0)
        text = out.getvalue()
        self.assertIn("codec: A=hevc, B=h264", text)
        self.assertIn("B = beta-on", text)
        row = next(l for l in text.splitlines() if "`source_unique_fps`" in l)
        self.assertIn("60.00 [54.00–66.00] (3)", row)
        self.assertIn("72.00 [70.00–75.00] (3)", row)
        self.assertIn("| 12.00 | 20.0% | B higher |", row)
        row = next(l for l in text.splitlines() if "`payload_mbps`" in l)
        self.assertIn("not distinguishable", row)

    def test_compare_flags_different_scenarios_and_refuses_partial(self):
        a = [make_trial(i + 1, 300) for i in range(3)]
        mb = make_manifest(a)
        mb["plan"]["scenario"] = dict(SCENARIO, id="mirror.high-motion")
        for t in a:
            pass
        b = copy.deepcopy(a)
        for t in b:
            t["scenarioID"] = "mirror.high-motion"
        pa, pb = self.write_bundle("a", a), self.write_bundle("b", b, mb)
        ra = perf_lab.analyse(perf_lab.load_bundle(pa))
        rb = perf_lab.analyse(perf_lab.load_bundle(pb))
        text = perf_lab.render_compare(perf_lab.load_bundle(pa), ra, perf_lab.load_bundle(pb), rb)
        self.assertIn("NOT COMPARABLE", text)
        partial = [make_trial(1, 300), make_trial(2, 0, "failed"), make_trial(3, 0, "failed")]
        pp = self.write_bundle("p", partial)
        with redirect_stderr(io.StringIO()):
            self.assertEqual(perf_lab.main(["compare", pa, pp]), 2)


class StartRequestTests(unittest.TestCase):
    def test_request_is_validated_against_the_catalog(self):
        self.assertEqual(perf_lab.build_start_request("extend.idle", 4, "Beta ON", "4C0E8067"),
                         "scenario=extend.idle;trials=4;variant=betaon;commit=4c0e8067")
        with self.assertRaises(ValueError):
            perf_lab.build_start_request("nope", 3)
        with self.assertRaises(ValueError):
            perf_lab.build_start_request("extend.idle", 2)
        with self.assertRaises(ValueError):
            perf_lab.build_start_request("extend.idle", 3, commit="main")

    def test_dry_run_prints_the_two_commands(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(perf_lab.main(["start", "extend.idle", "--dry-run"]), 0)
        lines = out.getvalue().splitlines()
        self.assertEqual(lines[0], "defaults write com.raisecaterror.meowdisplay.mac.debug performanceLabStartRequest "
                                   "-string scenario=extend.idle;trials=3")
        self.assertEqual(lines[1], "notifyutil -p com.raisecaterror.meowdisplay.performance-lab.start")


class CatalogAndGoldenTests(unittest.TestCase):
    """Cross-checks with the Swift side (files the Swift tests generate)."""

    def test_metric_keys_match_the_app(self):
        catalog = perf_lab.load_scenarios()
        self.assertEqual(set(catalog["analysisMetrics"]), set(perf_lab.METRICS))
        for s in catalog["scenarios"] + [catalog["synthetic"]]:
            self.assertTrue(set(s["primaryMetrics"]) <= set(perf_lab.METRICS), s["id"])
            self.assertGreaterEqual(s["trialWindows"], 3)
        self.assertEqual(catalog["minimumTrials"], 3)

    def test_golden_bundle_edges_match(self):
        b = perf_lab.load_bundle(perf_lab.GOLDEN_BUNDLE)
        self.assertEqual(b.manifest["histogramUpperEdgesMs"], EDGES)

    def test_selftest_golden_report(self):
        b = perf_lab.load_bundle(perf_lab.GOLDEN_BUNDLE)
        self.assertTrue(b.synthetic)
        text = perf_lab.render_report(b, perf_lab.analyse(b))
        with open(perf_lab.GOLDEN_REPORT, encoding="utf-8") as f:
            self.assertEqual(text, f.read())
        self.assertIn("[SYNTHETIC]", text.splitlines()[0])
        self.assertIn(perf_lab.SYNTHETIC_BANNER, text)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(perf_lab.main(["selftest"]), 0)
        self.assertIn("SYNTHETIC", out.getvalue())

    def test_golden_synthetic_values_follow_the_script(self):
        b = perf_lab.load_bundle(perf_lab.GOLDEN_BUNDLE)
        r = perf_lab.analyse(b)
        # The script submits 60 frames/s with one duplicate in 30 and stalls 300 ms once in trial 3.
        t3 = r["per_trial"][3]
        self.assertEqual(t3["submit_gaps_over_250ms"], 1)
        self.assertEqual(r["per_trial"][1]["submit_gaps_over_250ms"], 0)
        for idx in (1, 2):
            self.assertAlmostEqual(r["per_trial"][idx]["submitted_fps"], 60.0, delta=0.5)
            self.assertAlmostEqual(r["per_trial"][idx]["duplicate_submit_fps"], 2.0, delta=0.2)
        self.assertEqual(r["stats"]["frame_id_unique_fps"]["n"], 3)


if __name__ == "__main__":
    unittest.main()
