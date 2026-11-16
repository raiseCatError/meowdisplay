#!/usr/bin/env python3
"""MeowDisplay Performance Lab analysis tool (issue #123).

Python 3 standard library only. Reads run bundles written by the Mac app's
Performance Lab (manifest.json + trial-NN.json), validates them, computes
per-trial and across-trial statistics and writes the issue's standard report
template as Markdown. `compare` puts two runs side by side and says "not
distinguishable" when their trial ranges overlap.

Commands:
  validate BUNDLE                      check schema, files and privacy keys
  report BUNDLE [--allow-partial] [--out FILE]
  compare BUNDLE_A BUNDLE_B [--allow-partial] [--out FILE]
  selftest                             SYNTHETIC: analyse the golden bundle, diff the golden report
  list                                 scenarios this tool knows (scenarios.json)
  start SCENARIO [--trials N] [--variant V] [--commit SHA|auto] [--bundle-id ID] [--dry-run]
                                       ask a running QA build to open the lab with SCENARIO

Every planned trial is always listed. Statistics use complete trials only;
fewer complete trials than MINIMUM_TRIALS (this tool's own constant; a bundle
cannot lower it) is refused with exit 2 unless --allow-partial, which marks
every output PARTIAL. No complete trial at all is always refused. SYNTHETIC
bundles are labelled in every output: they validate the harness, not
performance.

Receiver sums count each receiver window once, by its (series, sequence).
Bundles from receivers that sent no window numbers are labelled "possibly
double counted".

Exit codes: 0 done, 1 selftest failure, 2 unusable bundle or refused report
(always a one-line message, never a traceback).
"""

import argparse
import json
import math
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCENARIOS_JSON = os.path.join(HERE, "scenarios.json")
GOLDEN_BUNDLE = os.path.join(HERE, "tests", "golden", "synthetic-run")
GOLDEN_REPORT = os.path.join(HERE, "tests", "golden", "synthetic-report.md")

RUN_FORMAT = "meowdisplay-performance-lab-run"
TRIAL_FORMAT = "meowdisplay-performance-lab-trial"
SUPPORTED_SCHEMA = 1
START_NOTIFICATION = "com.raisecaterror.meowdisplay.performance-lab.start"
START_REQUEST_KEY = "performanceLabStartRequest"
DEFAULT_BUNDLE_ID = "com.raisecaterror.meowdisplay.mac.debug"

# Same rule as the app's export privacy test: no key may look like one of
# these, except the listed numeric/enum fields.
FORBIDDEN_KEY_FRAGMENTS = [
    "title", "name", "path", "file", "ssid", "host", "address", "addr", "ip", "endpoint", "serial", "pair",
    "spki", "key", "token", "secret", "screenshot", "image", "pixel", "input", "text", "url", "user", "bundle",
]
KEY_EXCEPTIONS = {"pathExpensive", "pathConstrained", "context", "presentationPath"}

SYNTHETIC_BANNER = "SYNTHETIC: scripted events, not a measurement. This validates the harness, not performance."
PARTIAL_BANNER = "PARTIAL: fewer complete trials than the minimum of %d. Not a valid benchmark result."
DOUBLE_COUNTED_NOTE = ("Receiver sums are possibly double counted: the receiver sent no window numbers (an older build), "
                       "so a window reported more than once may be counted more than once.")

# The minimum number of complete trials for a report. Matches
# PerformanceLabRunPlan.minimumTrials; a bundle's own value can only raise it.
MINIMUM_TRIALS = 3
# Bounds on what a bundle may contain.
MAX_TRIALS = 999
MAX_FILE_BYTES = 64 * 1024 * 1024
APP_VERSION_RE = re.compile(r"[0-9][0-9a-z.]*( \([0-9a-z.-]+\))?|synthetic|dev|unknown")
COMMIT_RE = re.compile(r"[0-9a-f]{7,40}")
VARIANT_RE = re.compile(r"[a-z0-9-]{1,24}")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z")


class BundleError(Exception):
    """The bundle cannot be used (schema, files or privacy)."""


class RefusedError(Exception):
    """The request would report from too little evidence."""


# ---------------------------------------------------------------- loading

def _read_json(path, root=None):
    """One bundle file: inside the bundle folder, at most MAX_FILE_BYTES."""
    name = os.path.basename(path)
    if root is not None:
        real_root = os.path.realpath(root)
        if os.path.commonpath([real_root, os.path.realpath(path)]) != real_root:
            raise BundleError("%s points outside the bundle folder" % name)
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            raise BundleError("%s is larger than %d MB" % (name, MAX_FILE_BYTES // (1024 * 1024)))
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        raise BundleError("missing %s" % name)
    except json.JSONDecodeError as e:
        raise BundleError("%s is not valid JSON (%s)" % (name, e))
    except (UnicodeDecodeError, RecursionError, IsADirectoryError, PermissionError) as e:
        raise BundleError("%s cannot be read (%s)" % (name, type(e).__name__))


_CATALOG = None


def load_scenarios():
    global _CATALOG
    if _CATALOG is None:
        with open(SCENARIOS_JSON, "r", encoding="utf-8") as f:
            _CATALOG = json.load(f)
    return _CATALOG


def _string_allowed(value, key, constants):
    """Same rule as the app's bundle privacy test: every string is a
    constant from code, except four fields with strict formats."""
    if value in constants:
        return True
    pattern = {"appVersion": APP_VERSION_RE, "commit": COMMIT_RE, "variant": VARIANT_RE, "createdAt": DATE_RE}.get(key)
    return bool(pattern and pattern.fullmatch(value))


def _privacy_lint(obj, where):
    """Raise on any key that looks like personal data and on any string
    value outside the app's constants. Walks every nested value. The
    allowed metric ids and strings ship with this tool (scenarios.json,
    generated from the app), never from the bundle being checked."""
    catalog = load_scenarios()
    allowed_keys = set(catalog["metricIDs"]) | set(catalog["classifierThresholdNames"]) | KEY_EXCEPTIONS
    constants = set(catalog["bundleStringConstants"])
    stack = [(obj, None)]
    # Every key is checked before a value error is raised: a personal-data
    # key is the clearer message.
    value_error = None
    while stack:
        value, key = stack.pop()
        if isinstance(value, dict):
            for k, v in value.items():
                if not isinstance(k, str):
                    raise BundleError("%s: a non-text key" % where)
                if k not in allowed_keys:
                    low = k.lower()
                    for bad in FORBIDDEN_KEY_FRAGMENTS:
                        if bad in low:
                            raise BundleError("%s: key %r looks like a %s field" % (where, k, bad))
                stack.append((v, k))
        elif isinstance(value, list):
            stack.extend((v, key) for v in value)
        elif isinstance(value, str):
            if value_error is None and not _string_allowed(value, key, constants):
                shown = value if len(value) <= 40 else value[:37] + "..."
                value_error = "%s: string %r in %r is not one the app writes" % (where, shown, key)
    if value_error is not None:
        raise BundleError(value_error)


def trial_file_name(index):
    return "trial-%02d.json" % index


class Bundle:
    def __init__(self, path, manifest, trials):
        self.path = path
        self.manifest = manifest
        self.trials = trials

    @property
    def label(self):
        """The bundle folder name only: never a local absolute path."""
        return os.path.basename(os.path.normpath(self.path))

    @property
    def synthetic(self):
        return bool(self.manifest.get("synthetic"))

    @property
    def scenario(self):
        return self.manifest["plan"]["scenario"]

    @property
    def minimum_trials(self):
        """MINIMUM_TRIALS, or the bundle's own minimum if that is higher."""
        own = self.manifest.get("minimumTrials")
        return max(MINIMUM_TRIALS, own) if isinstance(own, int) and not isinstance(own, bool) and own <= MAX_TRIALS else MINIMUM_TRIALS

    def complete_trials(self):
        return [t for t in self.trials if t.get("status") == "complete"]


def _missing_trial(index, issue="missingTrialData"):
    return {"trialIndex": index, "status": "failed", "issues": [issue], "measuredSeconds": 0,
            "windows": [], "stages": [], "counters": {}, "gaps": {}, "receiverSummaries": [], "missing": True}


def load_bundle(path):
    """Loads and checks a bundle. Anything malformed is a BundleError."""
    try:
        return _load_bundle(path)
    except BundleError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError, IndexError, OverflowError) as e:
        raise BundleError("malformed bundle (%s: %s)" % (type(e).__name__, e))


def _load_bundle(path):
    if not os.path.isdir(path):
        raise BundleError("%s is not a bundle folder" % os.path.basename(os.path.normpath(path)))
    manifest = _read_json(os.path.join(path, "manifest.json"), path)
    if not isinstance(manifest, dict):
        raise BundleError("manifest.json is not an object")
    if manifest.get("format") != RUN_FORMAT:
        raise BundleError("manifest.json is not a Performance Lab run (format %r)" % manifest.get("format"))
    if manifest.get("schemaVersion") != SUPPORTED_SCHEMA:
        raise BundleError("unsupported run schema version %r (this tool reads %d)" % (manifest.get("schemaVersion"), SUPPORTED_SCHEMA))
    for field in ("plan", "trials", "environment", "metrics", "histogramUpperEdgesMs", "windowSeconds"):
        if field not in manifest:
            raise BundleError("manifest.json lacks %r" % field)
    catalog = load_scenarios()
    if manifest.get("metricDictionaryVersion") != catalog["metricDictionaryVersion"]:
        raise BundleError("written with metric dictionary version %r; this tool reads version %d (use tools/perf-lab from "
                          "the same build)" % (manifest.get("metricDictionaryVersion"), catalog["metricDictionaryVersion"]))
    _privacy_lint(manifest, "manifest.json")
    scenario_id = manifest["plan"]["scenario"]["id"]
    planned = manifest["plan"]["trials"]
    if not isinstance(planned, int) or isinstance(planned, bool) or not 1 <= planned <= MAX_TRIALS:
        raise BundleError("manifest.json plans %r trials (1 to %d expected)" % (planned, MAX_TRIALS))
    listed = {}
    for entry in manifest["trials"]:
        index = entry["index"]
        if not isinstance(index, int) or isinstance(index, bool) or not 1 <= index <= planned:
            raise BundleError("manifest.json lists trial %r, outside 1-%d" % (index, planned))
        if index in listed:
            raise BundleError("manifest.json lists trial %d more than once" % index)
        listed[index] = entry
    trials = []
    for index in range(1, planned + 1):
        entry = listed.get(index)
        if entry is None:
            # Planned but not listed: shown as failed, never silently dropped.
            trials.append(_missing_trial(index, "missingTrialData"))
            continue
        name = trial_file_name(index)
        try:
            trial = _read_json(os.path.join(path, name), path)
        except BundleError as e:
            if not str(e).startswith("missing "):
                raise
            # Listed but missing: keep it visible as failed, never drop it.
            trials.append(_missing_trial(index))
            continue
        if not isinstance(trial, dict):
            raise BundleError("%s is not an object" % name)
        if trial.get("format") != TRIAL_FORMAT or trial.get("schemaVersion") != SUPPORTED_SCHEMA:
            raise BundleError("%s: unsupported trial format/schema" % name)
        if trial.get("scenarioID") != scenario_id or trial.get("trialIndex") != index:
            raise BundleError("%s does not belong to this run" % name)
        if trial.get("status") != entry.get("status"):
            raise BundleError("%s status %r differs from the manifest (%r)" % (name, trial.get("status"), entry.get("status")))
        _privacy_lint(trial, name)
        _check_histograms(trial, manifest["histogramUpperEdgesMs"], name)
        trials.append(trial)
    return Bundle(path, manifest, trials)


def hist_percentile(p, buckets, count, lo, hi, edges):
    """DiagnosticsHistogram's rule: bucket upper edge, clamped to [min, max]."""
    if count <= 0:
        return 0.0
    rank = max(1, int(math.ceil(count * min(max(p, 0.0), 1.0))))
    seen = 0
    for i, n in enumerate(buckets):
        seen += n
        if seen >= rank:
            edge = edges[i] if i < len(edges) else hi
            return max(min(edge, hi), lo)
    return hi


def _check_histograms(trial, edges, name):
    for st in trial.get("stages", []):
        buckets = st["buckets"]
        if len(buckets) != len(edges) + 1 or sum(buckets) != st["count"]:
            raise BundleError("%s: histogram %s is inconsistent" % (name, st["id"]))
        for p, key in ((0.5, "p50"), (0.95, "p95"), (0.99, "p99")):
            if abs(hist_percentile(p, buckets, st["count"], st["min"], st["max"], edges) - st[key]) > 1e-9:
                raise BundleError("%s: %s %s does not match its buckets" % (name, st["id"], key))


# ---------------------------------------------------------------- statistics

def nearest_rank(values, p):
    """Nearest-rank percentile of raw values (p in 0..1)."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, int(math.ceil(p * len(ordered))))
    return ordered[rank - 1]


def summarize(values):
    """Across-trial statistics. `values` may contain None (not measured)."""
    vals = [v for v in values if v is not None]
    n = len(vals)
    if n == 0:
        return {"n": 0, "median": None, "p95": None, "p99": None, "min": None, "max": None, "spread": None, "cv": None}
    mean = statistics.fmean(vals)
    cv = None
    if n >= 2 and mean != 0:
        cv = statistics.stdev(vals) / abs(mean)
    return {
        "n": n,
        "median": statistics.median(vals),
        "p95": nearest_rank(vals, 0.95),
        "p99": nearest_rank(vals, 0.99),
        "min": min(vals),
        "max": max(vals),
        "spread": max(vals) - min(vals),
        "cv": cv,
    }


def _stage(trial, stage_id):
    for st in trial.get("stages", []):
        if st["id"] == stage_id:
            return st
    return None


def _stage_value(stage_id, key):
    def f(trial):
        st = _stage(trial, stage_id)
        return st[key] if st and st["count"] > 0 else None
    return f


def _seconds(trial):
    s = trial.get("measuredSeconds") or 0
    return s if s > 0 else None


def _display_mode(trial):
    for w in trial.get("windows", []):
        mode = ((w.get("snapshot") or {}).get("context") or {}).get("displayMode")
        if mode:
            return mode
    return None


def _rate(*counter_ids, modes=None):
    """Per second over the trial; None when nothing was measured, or when
    the trial's display mode cannot produce the counter (`modes`)."""
    def f(trial):
        sec = _seconds(trial)
        if sec is None:
            return None
        mode = _display_mode(trial)
        if modes is not None and mode is not None and mode not in modes:
            return None
        return sum(trial.get("counters", {}).get(c, 0) for c in counter_ids) / sec
    return f


def _count(counter_id):
    def f(trial):
        if _seconds(trial) is None:
            return None
        return trial.get("counters", {}).get(counter_id, 0)
    return f


def _gap(stage_id, i):
    def f(trial):
        if _seconds(trial) is None:
            return None
        g = trial.get("gaps", {}).get(stage_id)
        return g[i] if g else 0
    return f


def receiver_windows(trial):
    """The trial's receiver summaries, each receiver window once: by
    (series, sequence) when the receiver numbered its windows. Summaries
    without numbers (older receivers) are kept as listed."""
    seen = set()
    out = []
    for o in trial.get("receiverSummaries", []):
        summary = o["summary"]
        key = (summary.get("windowSeriesID"), summary.get("windowSequence"))
        if key[0] is not None and key[1] is not None:
            if key in seen:
                continue
            seen.add(key)
        out.append(summary)
    return out


def possibly_double_counted(trial):
    """True when any receiver summary carries no window number."""
    if trial.get("receiverCounting") == "possiblyDoubleCounted":
        return True
    return any(o["summary"].get("windowSequence") is None for o in trial.get("receiverSummaries", []))


def _receiver(field, how):
    def f(trial):
        vals = [summary.get(field) for summary in receiver_windows(trial)]
        vals = [v for v in vals if v is not None]
        if not vals:
            return None
        if how == "median":
            return statistics.median(vals)
        if how == "max":
            return max(vals)
        return sum(vals)
    return f


def _payload_mbps(trial):
    sec = _seconds(trial)
    if sec is None:
        return None
    return trial.get("counters", {}).get("sender.send.bytes", 0) * 8 / sec / 1e6


def _stage_max(stage_id):
    def f(trial):
        if _seconds(trial) is None:
            return None
        st = _stage(trial, stage_id)
        return st["max"] if st and st["count"] > 0 else None
    return f


def _fixture_fps(trial):
    fx = trial.get("fixture")
    if not fx or not fx.get("seconds"):
        return None
    return fx["drawnFrames"] / fx["seconds"]


def _resources(field):
    vals = lambda trial: [w["snapshot"].get("resources", {}).get(field)
                          for w in trial.get("windows", []) if w["snapshot"].get("resources")]
    return lambda trial: [v for v in vals(trial) if v is not None]


def _cpu_median(trial):
    v = _resources("processCPUPercent")(trial)
    return statistics.median(v) if v else None


def _mem_max(trial):
    v = _resources("memoryFootprintMB")(trial)
    return max(v) if v else None


def _mem_delta(trial):
    v = _resources("memoryFootprintMB")(trial)
    return v[-1] - v[0] if len(v) >= 2 else None


DISPLAY_CAPTURE = ("mirror", "extend")   # display capture: complete frames and capture PTS exist
WINDOW_VIEW = ("window",)

SUBMIT_COUNTERS = ("sender.submit.live", "sender.submit.held_retry", "sender.submit.drop_replay",
                   "sender.submit.reconnect_replay", "sender.submit.window_composite")

# key -> (honest label, unit, function). Keys match the app's
# PerformanceLabAnalysisMetric (checked against scenarios.json by the tests).
METRICS = {
    "source_unique_fps": ("Sender: source-unique submissions (new capture PTS)", "frames/s", _rate("sender.submit.source_unique", modes=DISPLAY_CAPTURE)),
    "capture_complete_fps": ("Sender: ScreenCaptureKit complete frames", "frames/s", _rate("sender.capture.complete", modes=DISPLAY_CAPTURE)),
    "submitted_fps": ("Sender: encoder submissions, all origins", "frames/s", _rate(*SUBMIT_COUNTERS)),
    "encoded_fps": ("Sender: encoder outputs", "frames/s", _rate("sender.encode.completed")),
    "sent_fps": ("Sender: video sends completed (local stack accepted)", "frames/s", _rate("sender.send.completed")),
    "duplicate_submit_fps": ("Sender: duplicate submissions (same capture PTS)", "frames/s", _rate("sender.submit.duplicate", modes=DISPLAY_CAPTURE)),
    "capture_interval_p95_ms": ("Sender: complete-capture interval p95", "ms", _stage_value("sender.capture.complete_interval_ms", "p95")),
    "submit_interval_p50_ms": ("Sender: frame time at encoder submission, p50", "ms", _stage_value("sender.submit_interval_ms", "p50")),
    "submit_interval_p95_ms": ("Sender: frame time at encoder submission, p95", "ms", _stage_value("sender.submit_interval_ms", "p95")),
    "submit_interval_p99_ms": ("Sender: frame time at encoder submission, p99", "ms", _stage_value("sender.submit_interval_ms", "p99")),
    "submit_gaps_over_100ms": ("Sender: submission gaps over 100 ms (may be idle source)", "gaps", _gap("sender.submit_interval_ms", 0)),
    "submit_gaps_over_250ms": ("Sender: submission gaps over 250 ms (may be idle source)", "gaps", _gap("sender.submit_interval_ms", 1)),
    "submit_gaps_over_500ms": ("Sender: submission gaps over 500 ms (may be idle source)", "gaps", _gap("sender.submit_interval_ms", 2)),
    "source_age_p95_ms": ("Sender: capture PTS to encoder submit, p95", "ms", _stage_value("sender.source_age_at_submit_ms", "p95")),
    "encode_p50_ms": ("Sender: encode, submit to output, p50", "ms", _stage_value("sender.encode_ms", "p50")),
    "encode_p95_ms": ("Sender: encode, submit to output, p95", "ms", _stage_value("sender.encode_ms", "p95")),
    "encode_p99_ms": ("Sender: encode, submit to output, p99", "ms", _stage_value("sender.encode_ms", "p99")),
    "send_p95_ms": ("Sender: send, handed to transport to completion, p95", "ms", _stage_value("sender.send_ms", "p95")),
    "encoder_busy_holds": ("Sender: frames held because the encoder was busy", "frames", _count("sender.admission.held_encoder_busy")),
    "send_backpressure_drops": ("Sender: frames dropped for send backpressure", "frames", _count("sender.admission.dropped_pending_sends")),
    "payload_mbps": ("Sender: video payload sent (app bytes, no transport overhead)", "Mbit/s", _payload_mbps),
    "compose_p95_ms": ("Sender: Window view compose p95 (CPU side)", "ms", _stage_value("sender.window.compose_ms", "p95")),
    "composites_fps": ("Sender: Window view composites", "frames/s", _rate("sender.window.composites", modes=WINDOW_VIEW)),
    "receiver_arrival_fps": ("Receiver: frame arrivals (median of its 5 s windows)", "frames/s", _receiver("arrivalFPS", "median")),
    "receiver_arrival_p95_ms": ("Receiver: arrival interval p95 (median of its 5 s windows)", "ms", _receiver("arrivalP95Ms", "median")),
    "receiver_gaps_over_250ms": ("Receiver: arrival gaps over 250 ms (sum over its distinct windows)", "gaps", _receiver("arrivalGapsOver250ms", "sum")),
    "receiver_enqueue_fps": ("Receiver: enqueued for presentation, not presented (median)", "frames/s", _receiver("enqueueFPS", "median")),
    "presenter_queue_age_p95_ms": ("Receiver: presenter queue age p95 (worst window)", "ms", _receiver("presenterQueueAgeP95Ms", "max")),
    "frame_id_unique_fps": ("Receiver: unique fixture frame IDs at decode handoff, Metal path (median)", "frames/s", _receiver("frameIDUniqueFPS", "median")),
    "frame_id_skipped": ("Receiver: fixture frame IDs provably missing between two read IDs (sum over its distinct windows)", "frames", _receiver("frameIDMissing", "sum")),
    "frame_id_duplicates": ("Receiver: repeated fixture frame IDs (sum over its distinct windows)", "frames", _receiver("frameIDDuplicates", "sum")),
    "frame_id_unreadable": ("Receiver: unreadable frame-ID strips (sum over its distinct windows)", "frames", _receiver("frameIDUnreadable", "sum")),
    "frame_id_unexamined": ("Receiver: frames not read while the reader searched for the strip again (sum)", "frames", _receiver("frameIDUnexamined", "sum")),
    "frame_id_interval_p95_ms": ("Receiver: interval between unique fixture frames p95 (median)", "ms", _receiver("frameIDIntervalP95Ms", "median")),
    "fixture_drawn_fps": ("Fixture: frames the fixture window drew", "frames/s", _fixture_fps),
    "sender_cpu_percent_median": ("Sender: process CPU, % of one core (median of 5 s samples)", "%", _cpu_median),
    "sender_memory_mb_max": ("Sender: process memory footprint, max", "MB", _mem_max),
    "sender_memory_mb_delta": ("Sender: memory footprint, last minus first sample", "MB", _mem_delta),
    "generation_resets": ("Capture/presentation restarts", "events", _count("session.generation_resets")),
    "restart_frame_gap_max_ms": ("Sender: last frame before a restart to the first after it, max", "ms", _stage_max("sender.restart.frame_gap_ms")),
    "route_changes": ("Route class changes", "events", _count("session.route_changes")),
}

# Sender stages reported as latency/timing ranges, with the dictionary's caveat.
STAGE_ORDER = [
    "sender.capture.complete_interval_ms", "sender.source_age_at_submit_ms", "sender.submit_interval_ms",
    "sender.encode_ms", "sender.send_ms", "sender.window.compose_ms", "sender.window.compose_interval_ms",
    "sender.restart.frame_gap_ms",
]


def trial_metrics(trial):
    return {key: fn(trial) for key, (_, _, fn) in METRICS.items()}


def analyse(bundle, allow_partial=False):
    complete = bundle.complete_trials()
    if not complete:
        raise RefusedError("no complete trial out of %d; there is nothing to report, even as PARTIAL." % len(bundle.trials))
    partial = len(complete) < bundle.minimum_trials
    if partial and not allow_partial:
        raise RefusedError(
            "only %d complete trial(s) of %d; the minimum is %d. Rerun the missing trials, or pass "
            "--allow-partial to write a report marked PARTIAL." % (len(complete), len(bundle.trials), bundle.minimum_trials))
    per_trial = {t["trialIndex"]: trial_metrics(t) for t in bundle.trials}
    stats = {key: summarize([per_trial[t["trialIndex"]][key] for t in complete]) for key in METRICS}
    return {"partial": partial, "complete": complete, "per_trial": per_trial, "stats": stats}


# ---------------------------------------------------------------- formatting

def fmt(v):
    if v is None:
        return "n/a"
    if isinstance(v, int) or (isinstance(v, float) and v.is_integer() and abs(v) >= 1000):
        return "%d" % v
    if abs(v) >= 100:
        return "%.1f" % v
    return "%.2f" % v


def fmt_cv(v):
    return "n/a" if v is None else "%.1f%%" % (v * 100)


def _env_lines(bundle):
    env = bundle.manifest["environment"]
    sender = env["sender"]
    ctx = env.get("context") or {}
    return env, sender, ctx


def _metric_rows(bundle, result, keys):
    rows = ["| metric | unit | median | p95 | min–max | spread | CV | n | per trial (all, in order) |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for key in keys:
        label, unit, _ = METRICS[key]
        s = result["stats"][key]
        per = ", ".join("T%d %s%s" % (t["trialIndex"], fmt(result["per_trial"][t["trialIndex"]][key]),
                                      "" if t.get("status") == "complete" else " (%s)" % t.get("status"))
                        for t in bundle.trials)
        rows.append("| %s (`%s`) | %s | %s | %s | %s–%s | %s | %s | %d | %s |" % (
            label, key, unit, fmt(s["median"]), fmt(s["p95"]), fmt(s["min"]), fmt(s["max"]),
            fmt(s["spread"]), fmt_cv(s["cv"]), s["n"], per))
    return rows


def _receiver_cell(trial):
    """Distinct receiver windows, and how they were tied to the trial."""
    n = len(receiver_windows(trial))
    if n == 0:
        return "0"
    notes = []
    if possibly_double_counted(trial):
        notes.append("possibly double counted")
    elif trial.get("receiverWindowsMissed"):
        notes.append("%d not reported" % trial["receiverWindowsMissed"])
    if trial.get("receiverAlignment") == "partial" or (trial.get("receiverAlignment") is None and possibly_double_counted(trial)):
        notes.append("alignment partial")
    return "%d%s" % (n, " (%s)" % ", ".join(notes) if notes else "")


def render_report(bundle, result):
    m = bundle.manifest
    sc = bundle.scenario
    env, sender, ctx = _env_lines(bundle)
    date = m["createdAt"][:10]
    tags = (" [SYNTHETIC]" if bundle.synthetic else "") + (" [PARTIAL]" if result["partial"] else "")
    out = []
    out.append("### Benchmark run: %s / %s — %s%s" % (date, bundle.label, sc["caption"], tags))
    if bundle.synthetic:
        out.append("")
        out.append("> " + SYNTHETIC_BANNER)
    if result["partial"]:
        out.append("")
        out.append("> PARTIAL: %d complete trial(s), fewer than the minimum of %d. Not a valid benchmark result."
                   % (len(result["complete"]), bundle.minimum_trials))
    if any(possibly_double_counted(t) for t in bundle.trials):
        out.append("")
        out.append("> " + DOUBLE_COUNTED_NOTE)
    out.append("")
    n_complete = len(result["complete"])
    status = "completed" if not result["partial"] else "completed (partial)"
    out.append("- Status: %s — %d of %d trials complete" % (status, n_complete, len(bundle.trials)))
    out.append("- Objective/hypothesis: %s (operator: state the hypothesis)" % sc["purpose"])
    out.append("- Apps/versions/commit SHAs + comparator links/licenses: MeowDisplay %s, commit %s; no comparator in this bundle"
               % (sender.get("appVersion"), env.get("commit") or "not recorded (pass --commit to `start`)"))
    out.append("- Sender Mac / receiver hardware and OS: sender %s %d.%d.%d (%s); Mac model, receiver model and OS: not in the bundle (operator to fill)"
               % (sender.get("platform"), sender.get("osMajor", 0), sender.get("osMinor", 0), sender.get("osPatch", 0), sender.get("deviceClass")))
    out.append("- Test scenes + script/reference link + duration/warm-up: scenario `%s` v%d, fixture workload `%s`, frame ID v%d; "
               "warm-up %s s, then %d × %s s windows per trial (docs/performance/performance-lab.md)"
               % (sc["id"], sc["version"], m["workloadSignature"], m["frameIDVersion"], fmt(sc["warmUpSeconds"]),
                  sc["trialWindows"], fmt(m["windowSeconds"])))
    out.append("- Display mode; stream resolution/refresh/FPS/bitrate/codec/audio: %s; raster %sx%s; target %s FPS; codec %s; "
               "encoder in-flight limit %s; source refresh %s; bitrate: see payload below; audio: not recorded"
               % (ctx.get("displayMode", "unknown"), ctx.get("rasterWidth", "?"), ctx.get("rasterHeight", "?"), ctx.get("targetFPS", "?"),
                  ctx.get("codec", "unknown"), ctx.get("encoderInFlightLimit", "n/a"),
                  fmt(ctx.get("sourceRefreshHz")) + " Hz" if ctx.get("sourceRefreshHz") else "not read by this build"))
    rtts = [s.get("rttMs") for t in result["complete"] for s in receiver_windows(t) if s.get("rttMs") is not None]
    out.append("- Transport: route class %s, %s, expensive=%s, constrained=%s; control RTT p50 median %s ms (receiver windows); "
               "AP/infrastructure, loss and bandwidth: operator to fill"
               % (ctx.get("route", "unknown"), ctx.get("networkProtocol", "unknown"), ctx.get("pathExpensive"), ctx.get("pathConstrained"),
                  fmt(statistics.median(rtts)) if rtts else "n/a"))
    thermal = sorted({w["snapshot"]["resources"]["thermalState"] for t in bundle.trials for w in t.get("windows", [])
                      if w["snapshot"].get("resources")})
    out.append("- Controls: sender thermal states seen: %s; power, background apps, shaper: operator to fill"
               % (", ".join(thermal) if thermal else "not sampled"))
    out.append("- Trials (n >= %d): all trials listed, raw evidence below" % bundle.minimum_trials)
    out.append("")
    out.append("| trial | status | issues | measured s | windows | receiver windows | raw evidence |")
    out.append("| --- | --- | --- | --- | --- | --- | --- |")
    for t in bundle.trials:
        out.append("| %d | %s | %s | %s | %d | %s | `%s/%s` |" % (
            t["trialIndex"], t.get("status"), ", ".join(t.get("issues", [])) or "none", fmt(t.get("measuredSeconds")),
            len(t.get("windows", [])), _receiver_cell(t), bundle.label, trial_file_name(t["trialIndex"])))
    out.append("")
    out.append("- Results: statistics over complete trials only (median; p95/p99 are nearest-rank over trials, so with "
               "fewer than 20 trials p95 is the maximum; spread = max − min; CV = sample stdev / mean). Per-trial values list every trial.")
    out.append("")
    primary = [k for k in sc["primaryMetrics"] if k in METRICS]
    out.append("Primary metrics:")
    out.append("")
    out.extend(_metric_rows(bundle, result, primary))
    out.append("")
    out.append("All metrics:")
    out.append("")
    out.extend(_metric_rows(bundle, result, [k for k in METRICS if k not in primary]))
    out.append("")
    out.append("Sender stage timings, exact to the histogram bucket over each trial's windows (p50 / p95 / p99 / max, ms):")
    out.append("")
    defs = {d["id"]: d for d in bundle.manifest["metrics"]}
    out.append("| stage | what it measures | " + " | ".join("T%d" % t["trialIndex"] for t in bundle.trials) + " |")
    out.append("| --- | --- | " + " | ".join("---" for _ in bundle.trials) + " |")
    for sid in STAGE_ORDER:
        cells = []
        any_data = False
        for t in bundle.trials:
            st = _stage(t, sid)
            if st and st["count"] > 0:
                any_data = True
                cells.append("%s / %s / %s / %s (n=%d)" % (fmt(st["p50"]), fmt(st["p95"]), fmt(st["p99"]), fmt(st["max"]), st["count"]))
            else:
                cells.append("n/a")
        if any_data:
            d = defs.get(sid, {})
            out.append("| `%s` | %s. %s | %s |" % (sid, d.get("source", ""), d.get("caveat", ""), " | ".join(cells)))
    out.append("")
    out.append("Stalls/freezes (gaps between successive events, counted per interval stage; on a still source a gap can be idle, not a stall):")
    out.append("")
    out.append("| stage | " + " | ".join("T%d >100/250/500 ms" % t["trialIndex"] for t in bundle.trials) + " |")
    out.append("| --- | " + " | ".join("---" for _ in bundle.trials) + " |")
    # Only the sender's own interval stages (older bundles also listed
    # receiver stages the sender never measures, always 0).
    gap_ids = sorted({k for t in bundle.trials for k in t.get("gaps", {}) if k.startswith("sender.")})
    for gid in gap_ids:
        out.append("| `%s` | %s |" % (gid, " | ".join(
            "/".join(str(x) for x in t.get("gaps", {}).get(gid, [0, 0, 0])) for t in bundle.trials)))
    out.append("")
    verdicts = {}
    for t in bundle.trials:
        for w in t.get("windows", []):
            v = w.get("verdict", {})
            key = "%s (%s)" % (v.get("cause"), v.get("confidence"))
            verdicts[key] = verdicts.get(key, 0) + 1
    out.append("Bottleneck classifier verdicts per sender window: " +
               (", ".join("%s × %d" % (k, verdicts[k]) for k in sorted(verdicts)) or "none"))
    out.append("")
    out.append("Not measured by this bundle: capture-to-photon and input-to-photon (need external camera/photodiode "
               "measurement), presentation on glass on the default display-layer path, GPU/encoder/decoder utilisation, "
               "network bytes billed, receiver CPU/memory (in the receiver's own diagnostics export only), audio.")
    out.append("")
    out.append("- Subjective observations (separate): operator to fill; keep apart from the numbers above")
    out.append("- Limitations / unexpected behavior / non-equivalences:")
    for lim in m.get("limitations", []):
        out.append("  - %s" % lim)
    issues = sorted({i for t in bundle.trials for i in t.get("issues", [])})
    if issues:
        out.append("  - Trial issues in this run: %s" % ", ".join(issues))
    out.append("- How another tester reproduces:")
    for step in sc["steps"]:
        when = step["timing"] if step.get("atSecond") is None else "%s at %s s" % (step["timing"], fmt(step["atSecond"]))
        out.append("  - (%s) %s" % (when, step["instruction"]))
    out.append("  - Start: Settings → System → Streaming Diagnostics → Performance Lab…, or "
               "`python3 tools/perf-lab/perf_lab.py start %s --trials %d`" % (sc["id"], m["plan"]["trials"]))
    out.append("  - Analyse: `python3 tools/perf-lab/perf_lab.py report %s`" % bundle.label)
    out.append("- Code/feature follow-up issue(s): operator to fill")
    out.append("- Evidence: `%s/manifest.json` and %s (aggregate numbers only; no names, addresses or screen content)"
               % (bundle.label, ", ".join("`%s/%s`" % (bundle.label, trial_file_name(t["trialIndex"])) for t in bundle.trials)))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- compare

ENV_FIELDS = [("sender", "appVersion"), ("sender", "osMajor"), ("sender", "osMinor"), ("", "commit"),
              ("context", "displayMode"), ("context", "codec"), ("context", "rasterWidth"), ("context", "rasterHeight"),
              ("context", "targetFPS"), ("context", "encoderInFlightLimit"), ("context", "route"),
              ("context", "networkProtocol"), ("context", "pathExpensive"), ("context", "pathConstrained")]


def _env_value(bundle, section, field):
    env = bundle.manifest["environment"]
    if not section:
        return env.get(field)
    return (env.get(section) or {}).get(field)


def compare_verdict(a, b):
    """'not distinguishable' when the trial ranges overlap, else which is higher."""
    if a["n"] == 0 or b["n"] == 0:
        return "n/a (no complete trials on one side)"
    if max(a["min"], b["min"]) <= min(a["max"], b["max"]):
        return "not distinguishable (ranges overlap)"
    return "B higher" if b["min"] > a["max"] else "B lower"


def render_compare(ba, ra, bb, rb):
    out = []
    tags = ""
    if ba.synthetic or bb.synthetic:
        tags += " [SYNTHETIC]"
    if ra["partial"] or rb["partial"]:
        tags += " [PARTIAL]"
    out.append("### Benchmark comparison: A = %s, B = %s%s" % (ba.label, bb.label, tags))
    out.append("")
    if ba.synthetic or bb.synthetic:
        out.append("> " + SYNTHETIC_BANNER)
        out.append("")
    for name, b, r in (("A", ba, ra), ("B", bb, rb)):
        if r["partial"]:
            out.append("> %s is %s" % (name, PARTIAL_BANNER % b.minimum_trials))
            out.append("")
    if any(possibly_double_counted(t) for b in (ba, bb) for t in b.trials):
        out.append("> " + DOUBLE_COUNTED_NOTE)
        out.append("")
    if ba.scenario["id"] != bb.scenario["id"] or ba.scenario["version"] != bb.scenario["version"]:
        out.append("> NOT COMPARABLE: different scenarios (%s v%d vs %s v%d). Deltas below are shown for reference only."
                   % (ba.scenario["id"], ba.scenario["version"], bb.scenario["id"], bb.scenario["version"]))
        out.append("")
    out.append("Variants: A = %s, B = %s. Change one thing at a time; randomise run order; same hardware and network."
               % (ba.manifest["plan"].get("variant") or "none", bb.manifest["plan"].get("variant") or "none"))
    out.append("")
    diffs = []
    for section, field in ENV_FIELDS:
        va, vb = _env_value(ba, section, field), _env_value(bb, section, field)
        if va != vb:
            diffs.append("%s: A=%s, B=%s" % (field, va, vb))
    out.append("Environment differences: " + ("; ".join(diffs) if diffs else "none recorded"))
    out.append("")
    out.append("Trials: A %d complete of %d, B %d complete of %d. Ranges are min–max over complete trials; "
               "\"not distinguishable\" when they overlap." % (len(ra["complete"]), len(ba.trials), len(rb["complete"]), len(bb.trials)))
    out.append("")
    out.append("| metric | unit | A median [min–max] (n) | B median [min–max] (n) | B − A | B − A % | result |")
    out.append("| --- | --- | --- | --- | --- | --- | --- |")
    primary = [k for k in ba.scenario["primaryMetrics"] if k in METRICS]
    for key in primary + [k for k in METRICS if k not in primary]:
        sa, sb = ra["stats"][key], rb["stats"][key]
        if sa["n"] == 0 and sb["n"] == 0:
            continue
        label, unit, _ = METRICS[key]
        delta = pct = None
        if sa["median"] is not None and sb["median"] is not None:
            delta = sb["median"] - sa["median"]
            pct = (delta / abs(sa["median"]) * 100) if sa["median"] else None
        out.append("| %s%s (`%s`) | %s | %s [%s–%s] (%d) | %s [%s–%s] (%d) | %s | %s | %s |" % (
            "**" if key in primary else "", label + ("**" if key in primary else ""), key, unit,
            fmt(sa["median"]), fmt(sa["min"]), fmt(sa["max"]), sa["n"],
            fmt(sb["median"]), fmt(sb["min"]), fmt(sb["max"]), sb["n"],
            fmt(delta), "n/a" if pct is None else "%.1f%%" % pct, compare_verdict(sa, sb)))
    out.append("")
    out.append("Primary metrics of the scenario are in bold. Every trial of both runs is in their own reports.")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- start


def build_start_request(scenario_id, trials, variant=None, commit=None):
    catalog = load_scenarios()
    ids = {s["id"] for s in catalog["scenarios"]} | {catalog["synthetic"]["id"]}
    if scenario_id not in ids:
        raise ValueError("unknown scenario %r; see `perf_lab.py list`" % scenario_id)
    if trials < catalog["minimumTrials"]:
        raise ValueError("at least %d trials are required" % catalog["minimumTrials"])
    parts = ["scenario=%s" % scenario_id, "trials=%d" % trials]
    if variant:
        clean = "".join(c for c in variant.lower() if c.isalnum() and c.isascii() or c == "-")[:24]
        if clean:
            parts.append("variant=%s" % clean)
    if commit:
        if not (7 <= len(commit) <= 40 and all(c in "0123456789abcdef" for c in commit.lower())):
            raise ValueError("commit must be 7-40 hex digits")
        parts.append("commit=%s" % commit.lower())
    return ";".join(parts)


def cmd_start(args):
    commit = args.commit
    if commit == "auto":
        try:
            commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=HERE, capture_output=True, text=True, check=True).stdout.strip()
        except (subprocess.CalledProcessError, OSError):
            raise ValueError("--commit auto: could not read the commit with git; pass --commit SHA")
    request = build_start_request(args.scenario, args.trials, args.variant, commit)
    commands = [["defaults", "write", args.bundle_id, START_REQUEST_KEY, "-string", request],
                ["notifyutil", "-p", START_NOTIFICATION]]
    for c in commands:
        print(" ".join(c))
        if not args.dry_run:
            try:
                subprocess.run(c, check=True)
            except (subprocess.CalledProcessError, OSError) as e:
                raise ValueError("%s failed (%s)" % (c[0], type(e).__name__))
    if not args.dry_run:
        print("Requested. The app opens the Performance Lab panel at the first operator step "
              "(only while Streaming Diagnostics are on).")
    return 0


# ---------------------------------------------------------------- CLI

def _write(text, out):
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


def cmd_selftest(_args):
    bundle = load_bundle(GOLDEN_BUNDLE)
    if not bundle.synthetic:
        print("selftest: the golden bundle is not marked synthetic", file=sys.stderr)
        return 1
    text = render_report(bundle, analyse(bundle))
    with open(GOLDEN_REPORT, "r", encoding="utf-8") as f:
        expected = f.read()
    if text != expected:
        print("selftest: FAILED — the report of the SYNTHETIC golden bundle differs from %s" % os.path.relpath(GOLDEN_REPORT), file=sys.stderr)
        return 1
    print("selftest: OK (SYNTHETIC golden bundle → report matches; validates the harness, not performance)")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="perf_lab.py", description="MeowDisplay Performance Lab analysis (#123)")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("validate"); p.add_argument("bundle")
    p = sub.add_parser("report"); p.add_argument("bundle"); p.add_argument("--allow-partial", action="store_true"); p.add_argument("--out")
    p = sub.add_parser("compare"); p.add_argument("bundle_a"); p.add_argument("bundle_b")
    p.add_argument("--allow-partial", action="store_true"); p.add_argument("--out")
    sub.add_parser("selftest")
    sub.add_parser("list")
    p = sub.add_parser("start"); p.add_argument("scenario"); p.add_argument("--trials", type=int, default=3)
    p.add_argument("--variant"); p.add_argument("--commit"); p.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            b = load_bundle(args.bundle)
            print("%s: valid%s — scenario %s, %d trials (%d complete)" % (
                b.label, " SYNTHETIC" if b.synthetic else "", b.scenario["id"], len(b.trials), len(b.complete_trials())))
            return 0
        if args.command == "report":
            b = load_bundle(args.bundle)
            _write(render_report(b, analyse(b, args.allow_partial)), args.out)
            return 0
        if args.command == "compare":
            ba, bb = load_bundle(args.bundle_a), load_bundle(args.bundle_b)
            _write(render_compare(ba, analyse(ba, args.allow_partial), bb, analyse(bb, args.allow_partial)), args.out)
            return 0
        if args.command == "selftest":
            return cmd_selftest(args)
        if args.command == "list":
            for s in load_scenarios()["scenarios"]:
                print("%-28s %s" % (s["id"], s["caption"]))
            return 0
        if args.command == "start":
            return cmd_start(args)
    except (BundleError, RefusedError, ValueError) as e:
        print("perf_lab: %s" % _one_line(e), file=sys.stderr)
        return 2
    except (KeyError, TypeError, AttributeError, IndexError, OverflowError, RecursionError) as e:
        # A bundle that passed loading but is still malformed somewhere.
        print("perf_lab: malformed bundle (%s: %s)" % (type(e).__name__, _one_line(e)), file=sys.stderr)
        return 2
    return 1


def _one_line(e):
    return " ".join(str(e).split())


if __name__ == "__main__":
    sys.exit(main())
