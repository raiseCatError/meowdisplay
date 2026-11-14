#!/usr/bin/env python3
"""The UI coverage that ui_selection.py selects pull requests' UI tests with.

  ui_coverage.py build OUTPUT COMMIT CLASS=LINES.jsonl ...
      The ios-duo job on a push to dev (the integration gate), after running
      every CI UI test class on its own with coverage: turns each class's line
      export (scripts/ci/export-coverage.sh) into one compact file,
      {"commit", "executable": {file: ranges}, "classes": {class: {file: ranges}}}.
      Every CI class must be given, and must have run some code.

  ui_coverage.py fetch OUTPUT
      The changes job of a pull request: downloads the newest such file from
      a dev push run in which ios-duo passed, and checks it names that run's
      commit. Exits non-zero without writing OUTPUT on any error, and the
      pull request then runs every UI test class.
      Reads GH_TOKEN, GITHUB_REPOSITORY and GITHUB_API_URL.
"""
from __future__ import annotations

import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# python3 -I leaves this file's directory off sys.path; ui_selection.py lives beside it.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ui_selection import ALL_CLASSES, Coverage  # noqa: E402

ARTIFACT = "ui-coverage"
FILE = "ui_coverage.json"
WORKFLOW = ".github/workflows/tests.yml"
SHA = re.compile(r"[0-9a-f]{40}")
RUNS = 20
MAX_BYTES = 20 * 1024 * 1024


def ranges(lines) -> list[list[int]]:
    out: list[list[int]] = []
    for n in sorted(set(lines)):
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return out


def build(commit: str, exports: dict[str, list[dict]]) -> dict:
    if not SHA.fullmatch(commit):
        raise ValueError("build: commit must be a SHA")
    if set(exports) != ALL_CLASSES:
        raise ValueError(f"build: needs exactly {sorted(ALL_CLASSES)}")
    executable: dict[str, set] = {}
    classes: dict[str, dict] = {}
    for cls, records in exports.items():
        files = {}
        for record in records:
            path = record["file"]
            if not path.startswith(("iOS/", "Shared/")) or not path.endswith(".swift"):
                raise ValueError(f"build: unexpected file {path}")
            executable.setdefault(path, set()).update(n for n, count in record["lines"] if count is not None)
            executed = [n for n, count in record["lines"] if count]
            if executed:
                files[path] = ranges(executed)
        if not files:
            raise ValueError(f"build: {cls} ran no app code")
        classes[cls] = files
    data = {"commit": commit, "executable": {f: ranges(v) for f, v in sorted(executable.items())},
            "classes": classes}
    Coverage(data)  # it must load
    return data


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(url: str, auth: bool = True):
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if auth:
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    return urllib.request.Request(url, headers=headers)


def api(path: str) -> dict:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    with urllib.request.urlopen(request(base + path), timeout=30) as response:
        return json.load(response)


def download(artifact_id: int) -> bytes:
    """The artifact's zip. The API answers with a redirect to a signed URL,
    which must not get the token."""
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    repository = os.environ["GITHUB_REPOSITORY"]
    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(request(f"{base}/repos/{repository}/actions/artifacts/{artifact_id}/zip"), timeout=30)
        raise RuntimeError("fetch: expected a redirect")
    except urllib.error.HTTPError as redirect:
        if redirect.code not in (301, 302, 303, 307, 308):
            raise
        location = redirect.headers["Location"]
    with urllib.request.urlopen(request(location, auth=False), timeout=60) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise RuntimeError("fetch: artifact too large")
    return data


def passed_ios_duo(jobs: list) -> bool:
    return any(j.get("name") == "ios-duo" and j.get("status") == "completed" and j.get("conclusion") == "success"
               for j in jobs)


def fetch(output: str) -> int:
    repository = os.environ["GITHUB_REPOSITORY"]
    runs = api(f"/repos/{repository}/actions/workflows/tests.yml/runs?branch=dev&event=push&per_page={RUNS}")
    for run in runs["workflow_runs"]:
        if run.get("path") != WORKFLOW or (run.get("repository") or {}).get("full_name") != repository \
                or (run.get("head_repository") or {}).get("full_name") != repository:
            continue
        artifacts = api(f"/repos/{repository}/actions/runs/{int(run['id'])}/artifacts?name={ARTIFACT}")["artifacts"]
        artifacts = [a for a in artifacts if a.get("name") == ARTIFACT and not a.get("expired")]
        if not artifacts:
            continue
        jobs = api(f"/repos/{repository}/actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100")["jobs"]
        if not passed_ios_duo(jobs):
            continue
        with zipfile.ZipFile(io.BytesIO(download(int(artifacts[0]["id"])))) as archive:
            data = json.loads(archive.read(FILE))
        Coverage(data)
        if data["commit"] != run["head_sha"]:
            raise RuntimeError("fetch: the coverage names another commit than its run")
        with open(output, "w", encoding="utf-8") as out:
            json.dump(data, out)
        print(f"UI coverage of {data['commit'][:12]} from run {run['id']}")
        return 0
    print("no UI coverage from a passing dev run", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if len(argv) >= 5 and argv[1] == "build":
        exports = {}
        for arg in argv[4:]:
            cls, _, path = arg.partition("=")
            with open(path, encoding="utf-8") as lines:
                exports[cls] = [json.loads(line) for line in lines if line.strip()]
        data = build(argv[3], exports)
        with open(argv[2], "w", encoding="utf-8") as out:
            json.dump(data, out, separators=(",", ":"))
        print(f"{len(data['executable'])} files; " + ", ".join(
            f"{c}: {sum(len(r) for r in data['classes'][c].values())} ranges" for c in sorted(data["classes"])))
        return 0
    if len(argv) == 3 and argv[1] == "fetch":
        return fetch(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
