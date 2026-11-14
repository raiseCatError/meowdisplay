#!/usr/bin/env python3
"""List, for each Tests job, the dev commits on which that job last passed.

Used by the `changes` job in .github/workflows/tests.yml for pushes to dev,
which runs the copy of this file from dev before the push. It writes a JSON
object to OUTPUT: job key (classify_pr_paths.JOBS) -> up to five commit SHAs,
newest first, of earlier Tests runs for pushes to dev in which that job
passed. classify_pr_paths.py --anchors then picks, per job, the newest of
them that is an ancestor of the pushed commit, and runs the job only if
something it needs changed since. It never decides anything itself.

Only completed jobs that passed count: a job that was skipped, failed,
cancelled or is still running is no evidence. The iOS build is two steps of
the mac job, so it counts only where both of those steps passed. Runs from
another repository or another workflow file never count. Any API error exits
non-zero without writing OUTPUT, and tests.yml then runs full CI.

Usage: dev_anchors.py OUTPUT   (reads GH_TOKEN, GITHUB_REPOSITORY,
                                GITHUB_RUN_ID and GITHUB_API_URL)
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from typing import Callable, Iterable

WORKFLOW = ".github/workflows/tests.yml"
# Job name in tests.yml -> the classifier keys it proves.
JOB_KEYS = {
    "mac": ("mac",),
    "ios-duo": ("ios_ui",),
    "android": ("android",),
    "release-tooling": ("release_tooling",),
    "press-kit": ("press_kit",),
}
# The mac job's steps that are the iOS build (ios_build). Both must have passed.
IOS_BUILD_STEPS = ("Build iOS receiver app", "Check reserved-region SDK gate")
KEYS = ("mac", "ios_build", "ios_ui", "android", "release_tooling", "press_kit")
PER_KEY = 5
RUNS = 30


def proves(job: dict) -> tuple[str, ...]:
    """The classifier keys one finished job proves passed (none unless it passed)."""
    if job.get("status") != "completed" or job.get("conclusion") != "success":
        return ()
    keys = JOB_KEYS.get(job.get("name", ""), ())
    if job.get("name") == "mac":
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}
        if all(steps.get(name) == "success" for name in IOS_BUILD_STEPS):
            keys = keys + ("ios_build",)
    return keys


def anchors_from(runs: Iterable[dict], jobs_of: Callable[[dict], list], repository: str,
                 current_run: int) -> dict[str, list[str]]:
    """runs: newest first, as the API lists them. jobs_of(run) -> that run's latest jobs."""
    found: dict[str, list[str]] = {key: [] for key in KEYS}
    for run in runs:
        if run.get("id") == current_run:
            continue
        if run.get("event") != "push" or run.get("head_branch") != "dev" or run.get("path") != WORKFLOW:
            continue
        if (run.get("repository") or {}).get("full_name") != repository:
            continue
        if (run.get("head_repository") or {}).get("full_name") != repository:
            continue
        sha = run.get("head_sha", "")
        for job in jobs_of(run):
            for key in proves(job):
                if sha not in found[key] and len(found[key]) < PER_KEY:
                    found[key].append(sha)
        if all(len(shas) >= PER_KEY for shas in found.values()):
            break
    return found


def api(path: str) -> dict:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request(base + path, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    repository = os.environ["GITHUB_REPOSITORY"]
    current_run = int(os.environ["GITHUB_RUN_ID"])
    runs = api(f"/repos/{repository}/actions/workflows/tests.yml/runs"
               f"?branch=dev&event=push&per_page={RUNS}")["workflow_runs"]

    def jobs_of(run: dict) -> list:
        return api(f"/repos/{repository}/actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100")["jobs"]

    found = anchors_from(runs, jobs_of, repository, current_run)
    with open(argv[1], "w", encoding="utf-8") as out:
        json.dump(found, out)
    for key, shas in found.items():
        print(f"{key}: {', '.join(sha[:12] for sha in shas) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
