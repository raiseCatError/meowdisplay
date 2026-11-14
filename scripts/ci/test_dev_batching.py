"""Batched dev pushes: classify_pr_paths.py --anchors and dev_anchors.py.

python3 -m unittest discover -s scripts/ci -p 'test_*.py'
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_anchors  # noqa: E402
from classify_pr_paths import JOBS  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CLASSIFIER = Path(__file__).resolve().parent / "classify_pr_paths.py"
TESTS_YML = ROOT / ".github/workflows/tests.yml"
RT = "release_tooling"
REPO = "owner/repo"


class AnchoredDevPush(unittest.TestCase):
    """classify_pr_paths.py --github OUT --anchors FILE against real repositories."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "dev")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI")
        self.base = self.commit({"README.md": "readme\n", "Mac/A.swift": "a\n", "iOS/B.swift": "b\n",
                                 "Shared/P.swift": "p\n", "AndroidReceiver/app/M.kt": "m\n"})

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files):
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def run_cli(self, anchors, event="push", ref="refs/heads/dev", raw=None):
        out = Path(self.tmp.name) / "out"
        out.unlink(missing_ok=True)
        anchors_file = Path(self.tmp.name) / "anchors.json"
        anchors_file.write_text(raw if raw is not None else json.dumps(anchors))
        env = {**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref, "GITHUB_BASE_REF": "",
               "PUSH_BEFORE": ""}
        env.pop("GITHUB_STEP_SUMMARY", None)
        result = subprocess.run([sys.executable, "-I", str(CLASSIFIER), "--github", str(out), "--anchors",
                                 str(anchors_file)], cwd=self.repo, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            self.assertFalse(out.exists(), "a failure writes no selection")
            return None
        values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.assertEqual(set(values), set(JOBS) | {"reason"})
        self.reason = values["reason"]
        return {job for job in JOBS if values[job] == "true"}

    def all_at(self, sha):
        return {job: [sha] for job in JOBS}

    def test_one_merge_after_a_fully_passed_commit(self):
        self.commit({"Mac/A.swift": "changed\n"})
        self.assertEqual(self.run_cli(self.all_at(self.base)), {"mac", RT})

    def test_docs_after_a_cancelled_ios_run_still_tests_ios(self):
        # The iOS merge's run was cancelled by the docs merge: nothing passed on it,
        # so the anchors stay on base and the docs push covers the iOS change too.
        self.commit({"iOS/B.swift": "changed\n"})
        self.commit({"README.md": "more\n"})
        self.assertEqual(self.run_cli(self.all_at(self.base)), {"mac", "ios_build", "ios_ui", RT})

    def test_each_job_against_its_own_anchor(self):
        android_change = self.commit({"AndroidReceiver/app/M.kt": "changed\n"})
        # Android's run on that commit was cancelled before android passed; the others passed.
        anchors = {**self.all_at(android_change), "android": [self.base]}
        self.commit({"Mac/A.swift": "changed\n"})
        self.assertEqual(self.run_cli(anchors), {"mac", "android", RT})
        self.assertIn(f"android: changed since {self.base[:12]}", self.reason)

    def test_newest_ancestor_anchor_wins(self):
        mac_change = self.commit({"Mac/A.swift": "changed\n"})
        self.commit({"README.md": "more\n"})
        # Newest first: mac passed on mac_change, so the docs commit after it needs nothing.
        anchors = {job: [mac_change, self.base] for job in JOBS}
        self.assertEqual(self.run_cli(anchors), set())

    def test_a_job_without_an_anchor_runs(self):
        self.commit({"README.md": "more\n"})
        anchors = self.all_at(self.base)
        del anchors["android"]
        anchors["press_kit"] = []
        self.assertEqual(self.run_cli(anchors), {"android", "press_kit"})
        self.assertIn("android: no earlier pass", self.reason)

    def test_anchors_that_are_not_ancestors_are_ignored(self):
        self.git("checkout", "-q", "-b", "side")
        side = self.commit({"Mac/A.swift": "side\n"})
        self.git("checkout", "-q", "dev")
        self.commit({"README.md": "more\n"})
        unknown = "f" * 40
        anchors = {job: [unknown, side] for job in JOBS}
        self.assertEqual(self.run_cli(anchors), set(JOBS))
        anchors = {job: [side, self.base] for job in JOBS}
        self.assertEqual(self.run_cli(anchors), set())

    def test_a_rerun_of_the_anchor_commit_runs_everything(self):
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.run_cli(self.all_at(head)), set(JOBS))

    def test_shared_changes_since_any_anchor_run_every_app_job(self):
        self.commit({"Shared/P.swift": "changed\n"})
        self.commit({"Mac/A.swift": "changed\n"})
        self.assertEqual(self.run_cli(self.all_at(self.base)), set(JOBS) - {"press_kit"})

    def test_ci_changes_since_an_anchor_run_full_ci(self):
        self.commit({"scripts/ci/x.py": "x\n"})
        self.commit({"README.md": "more\n"})
        self.assertEqual(self.run_cli(self.all_at(self.base)), set(JOBS))

    def test_the_ios_build_brings_the_mac_job(self):
        ios_change = self.commit({"iOS/B.swift": "changed\n"})
        anchors = {**self.all_at(ios_change), "ios_build": [self.base]}
        self.commit({"README.md": "more\n"})
        self.assertEqual(self.run_cli(anchors), {"ios_build", "mac"})

    def test_malformed_anchors_fail_without_a_selection(self):
        self.commit({"README.md": "more\n"})
        for raw in ["", "[]", "{\"mac\": \"abc\"}", json.dumps({"mac": ["xyz"]}), json.dumps({"other": []}),
                    json.dumps({"mac": [self.base.upper()]})]:
            with self.subTest(raw=raw):
                self.assertIsNone(self.run_cli(None, raw=raw))

    def test_anchors_for_anything_but_a_dev_push_run_full_ci(self):
        self.commit({"README.md": "more\n"})
        for event, ref in [("pull_request", "refs/pull/1/merge"), ("push", "refs/heads/main"),
                           ("push", "refs/heads/release/2.1.0")]:
            with self.subTest(event=event, ref=ref):
                self.assertEqual(self.run_cli(self.all_at(self.base), event=event, ref=ref), set(JOBS))


def run(run_id, sha, **overrides):
    value = {"id": run_id, "head_sha": sha, "event": "push", "head_branch": "dev",
             "path": ".github/workflows/tests.yml", "repository": {"full_name": REPO},
             "head_repository": {"full_name": REPO}}
    value.update(overrides)
    return value


def job(name, conclusion="success", status="completed", steps=None):
    return {"name": name, "status": status, "conclusion": conclusion, "steps": steps or []}


IOS_STEPS = [{"name": n, "conclusion": "success"} for n in dev_anchors.IOS_BUILD_STEPS]


class Anchors(unittest.TestCase):
    """dev_anchors.anchors_from: which earlier jobs count as passes."""

    def anchors(self, runs, jobs, current=999):
        return dev_anchors.anchors_from(runs, lambda r: jobs.get(r["id"], []), REPO, current)

    def test_keys_are_the_classifier_jobs(self):
        self.assertEqual(dev_anchors.KEYS, JOBS)

    def test_only_passed_jobs_count(self):
        a, b = "a" * 40, "b" * 40
        runs = [run(2, b), run(1, a)]
        jobs = {2: [job("mac", "failure"), job("android", "skipped"), job("ios-duo", "cancelled"),
                    job("release-tooling", status="in_progress", conclusion=None), job("press-kit")],
                1: [job("mac", steps=IOS_STEPS), job("android"), job("ios-duo"), job("release-tooling")]}
        found = self.anchors(runs, jobs)
        self.assertEqual(found, {"mac": [a], "ios_build": [a], "ios_ui": [a], "android": [a],
                                 "release_tooling": [a], "press_kit": [b]})

    def test_the_ios_build_needs_both_of_its_steps(self):
        a = "a" * 40
        for steps in ([], IOS_STEPS[:1], [IOS_STEPS[0], {"name": IOS_STEPS[1]["name"], "conclusion": "skipped"}]):
            with self.subTest(steps=steps):
                found = self.anchors([run(1, a)], {1: [job("mac", steps=steps)]})
                self.assertEqual(found["mac"], [a])
                self.assertEqual(found["ios_build"], [])

    def test_other_runs_never_count(self):
        a = "a" * 40
        runs = [run(999, a), run(5, a, event="pull_request"), run(6, a, head_branch="main"),
                run(7, a, path=".github/workflows/other.yml"), run(8, a, repository={"full_name": "x/y"}),
                run(9, a, head_repository={"full_name": "fork/repo"})]
        jobs = {i: [job("mac", steps=IOS_STEPS), job("android")] for i in (999, 5, 6, 7, 8, 9)}
        self.assertEqual(self.anchors(runs, jobs), {key: [] for key in JOBS})

    def test_newest_first_without_repeats_and_capped(self):
        shas = [f"{i:040x}" for i in range(8)]
        runs = [run(100 - i, sha) for i, sha in enumerate(shas)] + [run(50, shas[0])]
        jobs = {r["id"]: [job("android")] for r in runs}
        self.assertEqual(self.anchors(runs, jobs)["android"], shas[:dev_anchors.PER_KEY])


class Workflow(unittest.TestCase):
    """tests.yml and dev_anchors.py agree, and batching stays fail-closed."""

    text = TESTS_YML.read_text(encoding="utf-8")

    def test_job_and_step_names_match_tests_yml(self):
        jobs = set(re.findall(r"^  ([\w-]+):\n", self.text, re.M))
        self.assertLessEqual(set(dev_anchors.JOB_KEYS), jobs)
        mac = re.search(r"^  mac:\n(.*?)(?=^  [\w-]+:\n)", self.text, re.M | re.S).group(1)
        for step in dev_anchors.IOS_BUILD_STEPS:
            self.assertIn(f"- name: {step}\n", mac)
        # Every job the classifier can skip is one dev_anchors can anchor.
        keys = {key for keys in dev_anchors.JOB_KEYS.values() for key in keys} | {"ios_build"}
        self.assertEqual(keys, set(JOBS))

    def test_dev_pushes_use_dev_copies_and_fall_back_to_full_ci(self):
        self.assertIn("git show 'HEAD^1:scripts/ci/dev_anchors.py'", self.text)
        self.assertIn("full_ci \"the base branch's classifier predates batched dev pushes\"", self.text)
        self.assertIn("full_ci \"the anchors could not be read\"", self.text)
        self.assertIn("args+=(--anchors \"$RUNNER_TEMP/anchors.json\")", self.text)
        self.assertRegex(self.text, r"concurrency:\n  group: tests-\$\{\{ github\.ref \}\}\n  cancel-in-progress: true\n")

    def test_a_failed_gate_is_reported_on_every_dev_push(self):
        jobs = re.findall(r"^  ([\w-]+):\n", self.text[self.text.index("\njobs:\n"):], re.M)
        report = self.text[self.text.index("\n  integration-report:\n"):]
        needs = re.search(r"needs: \[([^\]]*)\]", report).group(1).split(", ")
        # It waits for every other job, so none can fail unreported.
        self.assertEqual(set(needs), set(jobs) - {"integration-report"})
        self.assertIn("if: ${{ always() && github.event_name == 'push' && github.ref == 'refs/heads/dev' }}", report)
        self.assertIn('map(select(.value.result == "failure"))', report)
        # A run cancelled for a newer push never closes the issue.
        self.assertIn('if [[ "$cancelled" == 0 && -n "$issue" ]]; then', report)


if __name__ == "__main__":
    unittest.main()
