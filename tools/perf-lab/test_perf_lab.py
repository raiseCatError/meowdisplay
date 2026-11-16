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


# Fixtures use only strings the app writes (the tool's privacy check
# rejects anything else): a real scenario from the catalog, and the metric
# entries and limitations of the golden bundle.
CATALOG = perf_lab.load_scenarios()
SCENARIO = dict(next(s for s in CATALOG["scenarios"] if s["id"] == "extend.frame-counter"), trialWindows=1,
                primaryMetrics=["source_unique_fps", "payload_mbps"])
with open(os.path.join(perf_lab.GOLDEN_BUNDLE, "manifest.json"), encoding="utf-8") as _f:
    _GOLDEN_MANIFEST = json.load(_f)
METRIC_ENTRIES = [m for m in _GOLDEN_MANIFEST["metrics"] if m["id"] == "sender.submit_interval_ms"]
LIMITATIONS = _GOLDEN_MANIFEST["limitations"][:1]


def summary(series=None, sequence=None, marker=None, **fields):
    s = {"side": "receiver"}
    if series is not None:
        s["windowSeriesID"] = series
    if sequence is not None:
        s["windowSequence"] = sequence
    if marker is not None:
        s["peerWindowSequenceAtStart"] = marker
    s.update(fields)
    return s


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
        "receiverSummaries": [{"offsetSeconds": 5 + i, "summary": summary(7, i + 1, 2, arrivalFPS=a, rttMs=4)}
                              for i, a in enumerate(arrival)],
        "receiverAlignment": "aligned", "receiverCounting": "perWindow", "receiverWindowsMissed": 0,
    }


def make_manifest(trials, synthetic=False, minimum=3):
    return {
        "format": perf_lab.RUN_FORMAT, "schemaVersion": 1, "synthetic": synthetic, "createdAt": "2026-11-17T09:30:00Z",
        "plan": {"scenario": SCENARIO, "trials": len(trials), "synthetic": synthetic},
        "minimumTrials": minimum, "workloadSignature": "frame-counter@1:counter/60", "frameIDVersion": 1,
        "metricDictionaryVersion": CATALOG["metricDictionaryVersion"],
        "environment": {"sender": {"appVersion": "2.0 (300)", "osMajor": 26, "osMinor": 1, "osPatch": 0,
                                   "platform": "macOS", "deviceClass": "mac"},
                        "commit": "4c0e8067", "context": {"displayMode": "extend", "codec": "hevc", "route": "usb"}},
        "metrics": copy.deepcopy(METRIC_ENTRIES),
        "histogramUpperEdgesMs": EDGES, "windowSeconds": 5,
        "trials": [{"index": t["trialIndex"], "status": t["status"], "issues": t["issues"]} for t in trials],
        "limitations": list(LIMITATIONS),
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
            t["receiverSummaries"][0]["summary"][bad_key] = 1
            with self.assertRaisesRegex(perf_lab.BundleError, "looks like"):
                perf_lab.load_bundle(self.write_bundle("priv-" + bad_key, [t]))
        ok = make_trial(1, 300)
        ok["windows"][0]["snapshot"]["context"] = {"pathExpensive": False, "presentationPath": "metal"}
        perf_lab.load_bundle(self.write_bundle("ok", [ok]))

    def test_privacy_lint_walks_string_values_with_the_apps_allow_list(self):
        """B14 (reproduced): personal text in a value, or a key the bundle
        declares as a metric id, used to pass."""
        t = make_trial(1, 300)
        m = make_manifest([t])
        m["environment"]["sender"]["appVersion"] = "Jane Doe MacBook 192.168.1.20"
        with self.assertRaisesRegex(perf_lab.BundleError, "not one the app writes"):
            perf_lab.load_bundle(self.write_bundle("value", [t], m))
        m = make_manifest([t])
        m["metrics"] = m["metrics"] + [dict(m["metrics"][0], id="hostName")]
        m["environment"]["hostName"] = 1
        with self.assertRaisesRegex(perf_lab.BundleError, "key 'hostName' looks like a "):
            perf_lab.load_bundle(self.write_bundle("declared-key", [t], m))
        nested = make_trial(1, 300)
        nested["windows"][0]["snapshot"]["context"] = {"route": ["usb", {"deep": "Jane's iPad"}]}
        with self.assertRaisesRegex(perf_lab.BundleError, "not one the app writes"):
            perf_lab.load_bundle(self.write_bundle("nested", [nested]))
        for field, bad in (("commit", "main"), ("variant", "Jane Doe")):
            m = make_manifest([t])
            if field == "commit":
                m["environment"]["commit"] = bad
            else:
                m["plan"]["variant"] = bad
            with self.assertRaisesRegex(perf_lab.BundleError, "not one the app writes"):
                perf_lab.load_bundle(self.write_bundle("fmt-" + field, [t], m))


class GateTests(BundleFixture):
    """B4 (reproduced): the minimum comes from the tool, every planned trial
    is listed once, and zero complete trials is always an error."""

    def test_bundle_cannot_lower_the_minimum(self):
        trials = [make_trial(1, 300), make_trial(2, 0, "failed", ["noSession"]), make_trial(3, 0, "failed", ["noSession"])]
        path = self.write_bundle("min0", trials, make_manifest(trials, minimum=0))
        b = perf_lab.load_bundle(path)
        self.assertEqual(b.minimum_trials, perf_lab.MINIMUM_TRIALS)
        with self.assertRaises(perf_lab.RefusedError):
            perf_lab.analyse(b)
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(perf_lab.main(["report", path]), 2)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(perf_lab.main(["report", path, "--allow-partial"]), 0)
        self.assertIn("[PARTIAL]", out.getvalue().splitlines()[0])
        higher = make_manifest(trials, minimum=5)
        self.assertEqual(perf_lab.load_bundle(self.write_bundle("min5", trials, higher)).minimum_trials, 5)

    def test_zero_complete_trials_is_always_refused(self):
        trials = [make_trial(i, 0, "failed", ["noSession"]) for i in (1, 2, 3)]
        path = self.write_bundle("none", trials, make_manifest(trials, minimum=0))
        for argv in (["report", path], ["report", path, "--allow-partial"]):
            err = io.StringIO()
            with redirect_stderr(err):
                self.assertEqual(perf_lab.main(argv), 2)
            self.assertIn("no complete trial", err.getvalue())

    def test_duplicate_and_out_of_range_indices_are_rejected(self):
        t = make_trial(1, 300)
        m = make_manifest([t, t, t])
        with self.assertRaisesRegex(perf_lab.BundleError, "more than once"):
            perf_lab.load_bundle(self.write_bundle("dup", [t], m))
        m = make_manifest([t])
        m["trials"][0]["index"] = 4
        with self.assertRaisesRegex(perf_lab.BundleError, "outside"):
            perf_lab.load_bundle(self.write_bundle("range", [t], m))

    def test_planned_trials_that_are_not_listed_are_failed(self):
        trials = [make_trial(1, 300), make_trial(2, 300), make_trial(3, 300)]
        m = make_manifest(trials)
        m["plan"]["trials"] = 4
        b = perf_lab.load_bundle(self.write_bundle("unlisted", trials, m))
        self.assertEqual([t["trialIndex"] for t in b.trials], [1, 2, 3, 4])
        self.assertEqual(b.trials[3]["status"], "failed")
        self.assertEqual(b.trials[3]["issues"], ["missingTrialData"])


class MalformedBundleTests(BundleFixture):
    """B15 (reproduced): exit 2 with one line, never a traceback."""

    def assert_exit_2(self, path, *extra):
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(perf_lab.main(["report", path] + list(extra)), 2)
        lines = err.getvalue().strip().splitlines()
        self.assertEqual(len(lines), 1, err.getvalue())
        self.assertTrue(lines[0].startswith("perf_lab: "), lines[0])
        self.assertNotIn("Traceback", err.getvalue())

    def test_missing_fields_and_wrong_types(self):
        trials = [make_trial(i, 300) for i in (1, 2, 3)]
        m = make_manifest(trials)
        del m["metrics"][0]["id"]
        self.assert_exit_2(self.write_bundle("no-id", trials, m))
        bad = [make_trial(i, 300) for i in (1, 2, 3)]
        bad[1]["stages"] = "x"
        self.assert_exit_2(self.write_bundle("stages", bad))
        m = make_manifest(trials)
        m["plan"] = []
        self.assert_exit_2(self.write_bundle("plan", trials, m))
        m = make_manifest(trials)
        m["trials"] = [{"index": "1", "status": "complete", "issues": []}]
        self.assert_exit_2(self.write_bundle("index", trials, m))
        path = self.write_bundle("array", trials)
        with open(os.path.join(path, "manifest.json"), "w") as f:
            f.write("[1, 2]")
        self.assert_exit_2(path)
        self.assert_exit_2(os.path.join(self.tmp, "does-not-exist"))

    def test_oversized_file_is_refused(self):
        trials = [make_trial(i, 300) for i in (1, 2, 3)]
        path = self.write_bundle("big", trials)
        old = perf_lab.MAX_FILE_BYTES
        perf_lab.MAX_FILE_BYTES = 100
        try:
            self.assert_exit_2(path)
        finally:
            perf_lab.MAX_FILE_BYTES = old

    def test_trial_file_outside_the_bundle_is_refused(self):
        trials = [make_trial(i, 300) for i in (1, 2, 3)]
        path = self.write_bundle("link", trials)
        outside = os.path.join(self.tmp, "outside.json")
        shutil.move(os.path.join(path, "trial-02.json"), outside)
        os.symlink(outside, os.path.join(path, "trial-02.json"))
        with self.assertRaisesRegex(perf_lab.BundleError, "outside the bundle"):
            perf_lab.load_bundle(path)

    def test_start_commit_auto_failure_is_exit_2(self):
        def fail(*args, **kwargs):
            raise perf_lab.subprocess.CalledProcessError(128, args[0])
        old = perf_lab.subprocess.run
        perf_lab.subprocess.run = fail
        try:
            err = io.StringIO()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                self.assertEqual(perf_lab.main(["start", "extend.idle", "--commit", "auto", "--dry-run"]), 2)
            self.assertIn("--commit", err.getvalue())
        finally:
            perf_lab.subprocess.run = old


class ReceiverCountingTests(BundleFixture):
    """B1: each receiver window once; older receivers are labelled."""

    def test_repeated_receiver_windows_count_once(self):
        t = make_trial(1, 300)
        t["receiverSummaries"] = [
            {"offsetSeconds": 6, "summary": summary(7, 1, 2, arrivalGapsOver250ms=1, rttJitterMs=1)},
            {"offsetSeconds": 8, "summary": summary(7, 1, 2, arrivalGapsOver250ms=1, rttJitterMs=2)},
            {"offsetSeconds": 10, "summary": summary(7, 2, 3, arrivalGapsOver250ms=0)},
            {"offsetSeconds": 12, "summary": summary(9, 1, 4, arrivalGapsOver250ms=1)},  # reconnect: new series
        ]
        self.assertEqual(perf_lab.trial_metrics(t)["receiver_gaps_over_250ms"], 2)
        self.assertFalse(perf_lab.possibly_double_counted(t))

    def test_legacy_receiver_sums_are_labelled(self):
        trials = [make_trial(i, 300) for i in (1, 2, 3)]
        for t in trials:
            t["receiverSummaries"] = [{"offsetSeconds": 10, "summary": {"side": "receiver", "arrivalGapsOver250ms": 1}}] * 2
            t["receiverCounting"] = "possiblyDoubleCounted"
            t["receiverAlignment"] = "partial"
            del t["receiverWindowsMissed"]
        b = perf_lab.load_bundle(self.write_bundle("legacy", trials))
        text = perf_lab.render_report(b, perf_lab.analyse(b))
        self.assertIn(perf_lab.DOUBLE_COUNTED_NOTE, text)
        self.assertIn("| 2 (possibly double counted, alignment partial) |", text)

    def test_mode_specific_counters_are_not_measured_elsewhere(self):
        """B12: n/a, not 0, for a counter the display mode cannot produce."""
        t = make_trial(1, 300)
        t["windows"][0]["snapshot"]["context"] = {"displayMode": "window"}
        m = perf_lab.trial_metrics(t)
        self.assertIsNone(m["capture_complete_fps"])
        self.assertIsNone(m["source_unique_fps"])
        self.assertIsNone(m["duplicate_submit_fps"])
        self.assertEqual(m["composites_fps"], 0.0)
        t["windows"][0]["snapshot"]["context"] = {"displayMode": "extend"}
        m = perf_lab.trial_metrics(t)
        self.assertIsNone(m["composites_fps"])
        self.assertEqual(m["source_unique_fps"], 60.0)


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


class PropertyTests(unittest.TestCase):
    """Cheap property checks with a fixed seed."""

    def test_histogram_percentiles_are_monotone_bounded_and_conserve_counts(self):
        import random
        rng = random.Random(1234)
        for _ in range(300):
            values = [round(rng.random() * rng.choice([5, 50, 500, 20000]), 3) for _ in range(rng.randint(1, 300))]
            rec = histogram("x", values)
            self.assertEqual(sum(rec["buckets"]), rec["count"])
            ps = [perf_lab.hist_percentile(p / 20, rec["buckets"], rec["count"], rec["min"], rec["max"], EDGES) for p in range(21)]
            self.assertEqual(ps, sorted(ps), "monotone in p")
            self.assertTrue(rec["min"] <= rec["p50"] <= rec["p95"] <= rec["p99"] <= rec["max"])
            # The true nearest-rank value is in (previous edge, reported value].
            true95 = perf_lab.nearest_rank(values, 0.95)
            self.assertLessEqual(true95, rec["p95"] + 1e-9)

    def test_receiver_metrics_are_idempotent_under_repeated_summaries(self):
        import random
        rng = random.Random(99)
        for _ in range(100):
            base = make_trial(1, 300)
            windows = [{"offsetSeconds": 5 + i, "summary": summary(rng.choice([7, 9]), i + 1, 2,
                                                                     arrivalGapsOver250ms=rng.randint(0, 2),
                                                                     frameIDMissing=rng.randint(0, 5), arrivalFPS=55 + i)}
                       for i in range(rng.randint(1, 8))]
            base["receiverSummaries"] = windows
            repeated = copy.deepcopy(base)
            noisy = []
            for w in windows:
                for _ in range(rng.randint(1, 4)):
                    dup = copy.deepcopy(w)
                    dup["summary"]["rttJitterMs"] = rng.random()   # a session value: differs on every send
                    noisy.append(dup)
            repeated["receiverSummaries"] = noisy
            a, b = perf_lab.trial_metrics(base), perf_lab.trial_metrics(repeated)
            for key in ("receiver_gaps_over_250ms", "frame_id_skipped", "receiver_arrival_fps"):
                self.assertEqual(a[key], b[key], key)


class CatalogAndGoldenTests(unittest.TestCase):
    """Cross-checks with the Swift side (files the Swift tests generate)."""

    def test_metric_keys_match_the_app(self):
        catalog = perf_lab.load_scenarios()
        self.assertEqual(set(catalog["analysisMetrics"]), set(perf_lab.METRICS))
        for s in catalog["scenarios"] + [catalog["synthetic"]]:
            self.assertTrue(set(s["primaryMetrics"]) <= set(perf_lab.METRICS), s["id"])
            self.assertGreaterEqual(s["trialWindows"], 3)
        self.assertEqual(catalog["minimumTrials"], perf_lab.MINIMUM_TRIALS)

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
        # Its receiver sends each 5 s window two or three times; the one
        # stall is counted once (it read 3 before window numbering).
        self.assertEqual(t3["receiver_gaps_over_250ms"], 1)
        for t in b.trials:
            self.assertFalse(perf_lab.possibly_double_counted(t))
            keys = [(o["summary"]["windowSeriesID"], o["summary"]["windowSequence"]) for o in t["receiverSummaries"]]
            self.assertEqual(len(keys), len(set(keys)))
        for idx in (1, 2):
            self.assertAlmostEqual(r["per_trial"][idx]["submitted_fps"], 60.0, delta=0.5)
            self.assertAlmostEqual(r["per_trial"][idx]["duplicate_submit_fps"], 2.0, delta=0.2)
        self.assertEqual(r["stats"]["frame_id_unique_fps"]["n"], 3)


if __name__ == "__main__":
    unittest.main()
