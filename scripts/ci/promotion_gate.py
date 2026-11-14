#!/usr/bin/env python3
"""The promotion gate: every Tests job, the complete iPhone Duo UI suite
included, passed on the exact commit being promoted or published.

  promotion_gate.py job
      The `promotion-gate` job of tests.yml, after every other job (always runs).
      On a pull request into main or release/*, or a push to main or release/*,
      it fails unless every job succeeded and ios-duo ran every CI class. A
      skipped, cancelled or failed job is never a pass: GitHub counts a skipped
      required check as passing, so the main and release/* rulesets require
      this job, which always runs, rather than the jobs themselves. Anywhere
      else it passes and says the complete suite isn't required there (the dev
      gate is tests.yml's integration-report).
      Reads RESULTS (toJSON(needs)), GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_BASE_REF.

  promotion_gate.py verify SHA BRANCH
      release-publish.yml, before anything is published: the newest Tests run
      for a push of SHA to BRANCH finished and succeeded, and every required
      job of it, promotion-gate and ios-duo included, succeeded on its latest
      attempt. A run still in progress, a newer run that failed after an older
      one passed, another commit, branch, event or repository: all fail.
      Reads GH_TOKEN, GITHUB_REPOSITORY and GITHUB_API_URL.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request
from typing import Callable, Optional

# The Duo classes the complete suite runs (ui_selection.CI_CLASSES; the tests check they agree).
FULL_SUITE = ("DemoModeSmokeTests", "AdaptiveLayoutTests", "LocalCalculatorTourTests")
# Every Tests job a promoted commit must have passed (all but the dev-only integration-report).
REQUIRED_JOBS = ("changes", "release-tooling", "press-kit", "android", "mac", "ios-duo", "promotion-gate")
WORKFLOW = ".github/workflows/tests.yml"
SHA = re.compile(r"[0-9a-f]{40}")
RELEASE_BRANCH = re.compile(r"release/[0-9]+\.[0-9]+\.[0-9]+")


def is_promotion(event: str, ref: str, base_ref: str) -> bool:
    if event == "pull_request":
        return base_ref == "main" or base_ref.startswith("release/")
    if event == "push":
        return ref == "refs/heads/main" or ref.startswith("refs/heads/release/")
    return False


def judge(results: dict, event: str, ref: str, base_ref: str) -> tuple[bool, str]:
    """(passed, why) for the jobs this run's promotion-gate job needs."""
    if not is_promotion(event, ref, base_ref):
        return True, "not a promotion into main or release/*: the complete suite is not required here"
    problems = []
    for job in REQUIRED_JOBS:
        if job == "promotion-gate":
            continue
        result = (results.get(job) or {}).get("result", "missing")
        if result != "success":
            problems.append(f"{job} is {result}")
    duo = ((results.get("ios-duo") or {}).get("outputs") or {}).get("classes", "")
    if duo.split() != list(FULL_SUITE):
        problems.append(f"ios-duo ran {duo or 'no classes'}, not the complete suite")
    if problems:
        return False, "; ".join(problems)
    return True, "every Tests job passed, the complete Duo UI suite included"


def verify(sha: str, branch: str, repository: str, api: Callable[[str], dict]) -> tuple[bool, str]:
    """(passed, why) for publishing SHA from BRANCH."""
    if not SHA.fullmatch(sha):
        return False, "the commit must be a full SHA"
    if not RELEASE_BRANCH.fullmatch(branch):
        return False, "only release/X.Y.Z is published"
    runs = api(f"/repos/{repository}/actions/workflows/tests.yml/runs"
               f"?head_sha={sha}&branch={branch}&event=push&per_page=50")["workflow_runs"]
    runs = [r for r in runs
            if r.get("head_sha") == sha and r.get("head_branch") == branch and r.get("event") == "push"
            and r.get("path") == WORKFLOW
            and (r.get("repository") or {}).get("full_name") == repository
            and (r.get("head_repository") or {}).get("full_name") == repository]
    if not runs:
        return False, f"no Tests run for a push of {sha[:12]} to {branch}"
    newest = max(runs, key=lambda r: (r.get("created_at", ""), r.get("run_attempt", 0), r.get("id", 0)))
    where = f"Tests run {newest.get('id')}"
    if newest.get("status") != "completed":
        return False, f"{where} for {sha[:12]} has not finished"
    if newest.get("conclusion") != "success":
        return False, f"{where} for {sha[:12]} is {newest.get('conclusion')}"
    jobs = api(f"/repos/{repository}/actions/runs/{int(newest['id'])}/jobs?filter=latest&per_page=100")["jobs"]
    by_name = {j.get("name"): j for j in jobs}
    problems = []
    for job in REQUIRED_JOBS:
        j = by_name.get(job)
        if j is None:
            problems.append(f"{job} is missing")
        elif j.get("head_sha", sha) != sha:
            problems.append(f"{job} ran on another commit")
        elif j.get("status") != "completed" or j.get("conclusion") != "success":
            problems.append(f"{job} is {j.get('conclusion') or j.get('status')}")
    if problems:
        return False, f"{where}: " + "; ".join(problems)
    return True, f"{where} passed on {sha[:12]}: every required job, the complete Duo UI suite included"


def github_api(path: str) -> dict:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request(base + path, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main(argv: list[str]) -> int:
    try:
        if argv[1:] == ["job"]:
            passed, why = judge(json.loads(os.environ["RESULTS"]), os.environ.get("GITHUB_EVENT_NAME", ""),
                                os.environ.get("GITHUB_REF", ""), os.environ.get("GITHUB_BASE_REF", ""))
        elif len(argv) == 4 and argv[1] == "verify":
            passed, why = verify(argv[2], argv[3], os.environ["GITHUB_REPOSITORY"], github_api)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Exception as error:  # any failure to establish the result is a failed gate
        passed, why = False, f"the gate could not be evaluated: {error}"
    print(("Promotion gate passed: " if passed else "::error::Promotion gate failed: ") + why)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
