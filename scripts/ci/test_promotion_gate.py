"""Tests for promotion_gate.py: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import copy
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import promotion_gate as gate  # noqa: E402
from ui_selection import CI_CLASSES  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPO = "owner/repo"
SHA = "a" * 40
OTHER = "b" * 40
BRANCH = "release/2.2.0"
FULL = " ".join(gate.FULL_SUITE)


def needs(**overrides):
    results = {job: {"result": "success", "outputs": {}} for job in gate.REQUIRED_JOBS if job != "promotion-gate"}
    results["ios-duo"]["outputs"] = {"classes": FULL}
    for job, value in overrides.items():
        job = job.replace("_", "-")
        if value is None:
            results.pop(job)
        else:
            results[job] = value
    return results


PROMOTIONS = [("pull_request", "refs/pull/9/merge", "main"), ("pull_request", "refs/pull/9/merge", "release/2.2.0"),
              ("push", "refs/heads/main", ""), ("push", "refs/heads/release/2.2.0", "")]


class Job(unittest.TestCase):
    def test_every_job_passed_with_the_complete_suite(self):
        for event, ref, base in PROMOTIONS:
            with self.subTest(event=event, base=base or ref):
                self.assertTrue(gate.judge(needs(), event, ref, base)[0])

    def test_a_failed_cancelled_skipped_or_missing_job_fails(self):
        for job in [j for j in gate.REQUIRED_JOBS if j != "promotion-gate"]:
            for broken in ({"result": "failure"}, {"result": "cancelled"}, {"result": "skipped"}, None):
                with self.subTest(job=job, broken=broken):
                    results = needs()
                    if broken is None:
                        results.pop(job)
                    else:
                        results[job] = {**broken, "outputs": results[job]["outputs"]}
                    passed, why = gate.judge(results, "pull_request", "refs/pull/9/merge", "main")
                    self.assertFalse(passed)
                    self.assertIn(job, why)

    def test_a_narrowed_or_unknown_duo_run_fails(self):
        for classes in ("AdaptiveLayoutTests", "", "DemoModeSmokeTests AdaptiveLayoutTests", FULL + " Extra"):
            with self.subTest(classes=classes):
                results = needs(ios_duo={"result": "success", "outputs": {"classes": classes}})
                self.assertFalse(gate.judge(results, "push", "refs/heads/release/2.2.0", "")[0])

    def test_elsewhere_the_complete_suite_is_not_required(self):
        broken = needs(ios_duo={"result": "skipped", "outputs": {}})
        for event, ref, base in [("pull_request", "refs/pull/9/merge", "dev"), ("push", "refs/heads/dev", ""),
                                 ("workflow_dispatch", "refs/heads/topic", ""),
                                 ("pull_request", "refs/pull/9/merge", "feature/x")]:
            with self.subTest(event=event, base=base or ref):
                passed, why = gate.judge(broken, event, ref, base)
                self.assertTrue(passed)
                self.assertIn("not a promotion", why)

    def test_the_cli_fails_closed(self):
        env = {**os.environ, "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_BASE_REF": ""}
        script = str(ROOT / "scripts/ci/promotion_gate.py")
        import json
        ok = subprocess.run([sys.executable, "-I", script, "job"], env={**env, "RESULTS": json.dumps(needs())},
                            capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        for results in ("not json", "", json.dumps(needs(mac={"result": "failure"}))):
            with self.subTest(results=results):
                bad = subprocess.run([sys.executable, "-I", script, "job"], env={**env, "RESULTS": results},
                                     capture_output=True, text=True)
                self.assertEqual(bad.returncode, 1, bad.stdout)
        missing = subprocess.run([sys.executable, "-I", script, "job"], env=env, capture_output=True, text=True)
        self.assertEqual(missing.returncode, 1)


def run(run_id=1, sha=SHA, branch=BRANCH, event="push", status="completed", conclusion="success",
        created="2026-11-14T10:00:00Z", attempt=1, path=gate.WORKFLOW, repo=REPO, head_repo=REPO):
    return {"id": run_id, "head_sha": sha, "head_branch": branch, "event": event, "status": status,
            "conclusion": conclusion, "created_at": created, "run_attempt": attempt, "path": path,
            "repository": {"full_name": repo}, "head_repository": {"full_name": head_repo}}


def jobs(sha=SHA, **overrides):
    out = [{"name": name, "status": "completed", "conclusion": "success", "head_sha": sha}
           for name in gate.REQUIRED_JOBS]
    for name, change in overrides.items():
        name = name.replace("_", "-")
        out = [j for j in out if j["name"] != name] + ([{**next(j for j in jobs(sha) if j["name"] == name), **change}]
                                                       if change is not None else [])
    return out


class FakeAPI:
    def __init__(self, runs, jobs_by_run):
        self.runs, self.jobs_by_run, self.paths = runs, jobs_by_run, []

    def __call__(self, path):
        self.paths.append(path)
        if "/actions/workflows/tests.yml/runs?" in path:
            return {"workflow_runs": copy.deepcopy(self.runs)}
        m = re.search(r"/actions/runs/(\d+)/jobs\?filter=latest", path)
        if m:
            return {"jobs": copy.deepcopy(self.jobs_by_run[int(m.group(1))])}
        raise AssertionError(f"unexpected API path {path}")


def verify(runs, jobs_by_run, sha=SHA, branch=BRANCH):
    api = FakeAPI(runs, jobs_by_run)
    return gate.verify(sha, branch, REPO, api), api


class Verify(unittest.TestCase):
    def test_a_passing_run_on_the_exact_commit_passes(self):
        (passed, why), api = verify([run()], {1: jobs()})
        self.assertTrue(passed, why)
        self.assertIn(f"head_sha={SHA}&branch={BRANCH}&event=push", api.paths[0])
        self.assertIn("filter=latest", api.paths[1])

    def test_no_run_for_that_commit_fails(self):
        self.assertFalse(verify([], {})[0][0])

    def test_runs_for_another_commit_branch_event_workflow_or_repository_are_ignored(self):
        for other in (run(sha=OTHER), run(branch="release/2.1.0"), run(branch="dev"), run(event="pull_request"),
                      run(event="workflow_dispatch"), run(path=".github/workflows/other.yml"),
                      run(repo="fork/repo"), run(head_repo="fork/repo")):
            with self.subTest(other=other):
                (passed, why), _ = verify([other], {1: jobs()})
                self.assertFalse(passed)
                self.assertIn("no Tests run", why)

    def test_the_newest_run_decides_so_an_old_pass_cannot_stand_in(self):
        old_pass = run(run_id=1, created="2026-11-14T09:00:00Z")
        for newer in (run(run_id=2, conclusion="failure"), run(run_id=2, conclusion="cancelled"),
                      run(run_id=2, status="in_progress", conclusion=None), run(run_id=2, conclusion="timed_out")):
            with self.subTest(newer=newer["conclusion"] or newer["status"]):
                (passed, _), _ = verify([old_pass, newer], {1: jobs(), 2: jobs()})
                self.assertFalse(passed)
        (passed, _), _ = verify([run(run_id=1, created="2026-11-14T09:00:00Z", conclusion="failure"), run(run_id=2)],
                                {1: jobs(mac={"conclusion": "failure"}), 2: jobs()})
        self.assertTrue(passed, "a newer passing run, on the same commit, is the result")

    def test_a_re_run_attempt_that_failed_decides(self):
        (passed, why), _ = verify([run(attempt=2, conclusion="failure")], {1: jobs()})
        self.assertFalse(passed, why)

    def test_a_failed_cancelled_skipped_or_missing_required_job_fails(self):
        for job in gate.REQUIRED_JOBS:
            for change in ({"conclusion": "failure"}, {"conclusion": "cancelled"}, {"conclusion": "skipped"},
                           {"status": "in_progress", "conclusion": None}, None):
                with self.subTest(job=job, change=change):
                    (passed, why), _ = verify([run()], {1: jobs(**{job: change})})
                    self.assertFalse(passed)
                    self.assertIn(job, why)

    def test_a_job_from_another_commit_fails(self):
        (passed, why), _ = verify([run()], {1: jobs(ios_duo={"head_sha": OTHER})})
        self.assertFalse(passed)
        self.assertIn("another commit", why)

    def test_bad_inputs_fail_before_any_api_call(self):
        for sha, branch in (("abc", BRANCH), (SHA.upper(), BRANCH), (SHA, "dev"), (SHA, "main"),
                            (SHA, "release/2.2"), (SHA, "release/2.2.0-rc1")):
            with self.subTest(sha=sha, branch=branch):
                (passed, _), api = verify([run()], {1: jobs()}, sha=sha, branch=branch)
                self.assertFalse(passed)
                self.assertEqual(api.paths, [])

    def test_an_api_failure_fails_the_cli(self):
        env = {**os.environ, "GITHUB_REPOSITORY": REPO, "GH_TOKEN": "x", "GITHUB_API_URL": "http://127.0.0.1:9"}
        out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/promotion_gate.py"), "verify", SHA, BRANCH],
                             env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 1)
        self.assertIn("could not be evaluated", out.stdout)


class Workflows(unittest.TestCase):
    tests = (ROOT / ".github/workflows/tests.yml").read_text()
    publish = (ROOT / ".github/workflows/release-publish.yml").read_text()

    def test_the_gate_job_always_runs_after_every_other_job(self):
        jobs_section = self.tests[self.tests.index("\njobs:\n"):]
        all_jobs = set(re.findall(r"^  ([\w-]+):\n", jobs_section, re.M))
        job = self.tests[self.tests.index("\n  promotion-gate:\n"):]
        listed = re.search(r"needs: \[([^\]]*)\]", job).group(1).split(", ")
        self.assertEqual(set(listed), all_jobs - {"promotion-gate", "integration-report"})
        self.assertEqual(set(listed) | {"promotion-gate"}, set(gate.REQUIRED_JOBS))
        self.assertIn("if: ${{ always() }}", job)
        self.assertIn("RESULTS: ${{ toJSON(needs) }}", job)
        self.assertIn("python3 -I scripts/ci/promotion_gate.py job", job)

    def test_only_a_promotion_reports_the_required_check_name(self):
        # A dev push (or PR into dev) on the commit a dev -> main PR has as its head must not
        # report "promotion-gate": GitHub matches required checks by name on the commit.
        job = self.tests[self.tests.index("\n  promotion-gate:\n"):]
        expression = re.search(r"^    name: \$\{\{ (.*) \}\}$", job, re.M).group(1)
        python = re.sub(r"startsWith\(([\w.]+), ('[^']*')\)", r"\1.startswith(\2)", expression)
        python = python.replace("&&", " and ").replace("||", " or ").replace("github.", "g_")
        contexts = PROMOTIONS + [("pull_request", "refs/pull/9/merge", "dev"), ("push", "refs/heads/dev", ""),
                                 ("pull_request", "refs/pull/9/merge", "feature/main"),
                                 ("push", "refs/heads/feature/release/x", ""),
                                 ("workflow_dispatch", "refs/heads/main", ""),
                                 ("workflow_dispatch", "refs/heads/release/2.2.0", "")]
        for event, ref, base in contexts:
            with self.subTest(event=event, ref=ref, base=base):
                name = eval(python, {}, {"g_event_name": event, "g_ref": ref, "g_base_ref": base})
                expected = "promotion-gate" if gate.is_promotion(event, ref, base) else "promotion-gate (not a promotion)"
                self.assertEqual(name, expected)

    def test_the_duo_job_reports_its_classes_and_never_narrows_a_promotion(self):
        duo = self.tests[self.tests.index("\n  ios-duo:\n"):self.tests.index("\n  integration-report:\n")]
        self.assertIn("classes: ${{ steps.select.outputs.classes }}", duo)
        self.assertIn('"$EVENT" == pull_request && "$BASE" != main && "$BASE" != release/*', duo)
        self.assertEqual(list(gate.FULL_SUITE), list(CI_CLASSES))

    def test_publication_checks_tests_on_the_candidate_first(self):
        guard = self.publish[self.publish.index("\n  guard:\n"):self.publish.index("\n  verify-stores:\n")]
        self.assertIn("actions: read", guard)
        self.assertIn("ref: ${{ inputs.sha }}", guard)
        self.assertIn('python3 -I scripts/ci/promotion_gate.py verify "$SHA" "release/$VERSION"', guard)


if __name__ == "__main__":
    unittest.main()
