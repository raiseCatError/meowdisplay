#!/usr/bin/env python3
"""Decide which Tests jobs a change needs, from the files it changes.

Used by the `changes` job in .github/workflows/tests.yml, which runs the copy
of this file from the base branch (the PR's base, or dev before the push), so
a change can't reclassify itself by editing it. Tested by
scripts/ci/test_classify_pr_paths.py, which also checks the rules below
against project.yml, the Android Gradle build and the macOS tests' file reads.

Outputs (key=true|false lines, appended to $GITHUB_OUTPUT), one per job:
  mac              the `mac` job: macOS tests and the Mac receiver build
  ios_build        the `mac` job's generic iOS receiver build and SDK gate
  ios_ui           the `ios-duo` job: the receiver's UI tests on a simulator
  android          the `android` job
  release_tooling  the `release-tooling` job
  press_kit        the `press-kit` job
and `reason`, one line saying why.

What each area needs (from the build graph, not from directory names):
  Mac/, MacReceiver/, MacTests/  mac. No iOS target compiles them.
  iOS/                           mac and both iOS jobs: the macOS tests read
                                 iOS sources, string catalogs and the privacy
                                 manifest (PrivacyManifestTests,
                                 StringCatalogTests, ProjectLinksTests).
  iOSUITests/                    ios_ui.
  Shared/                        every app job: every Apple target compiles
                                 it, and it holds the wire protocol, pairing,
                                 identity pinning and encryption, so Android
                                 runs too.
  fixtures/                      mac and android: both replay the vectors.
  project.yml, .xcode-version    every Apple job.
  AndroidReceiver/               android.
  release and repository tooling release_tooling only: scripts/release,
                                 scripts/reference, the listed workflows,
                                 rulesets, fastlane config, Gemfile, versions.
  documentation, README images,  nothing, apart from the cheap press-kit
  issue forms, PR template,      job for press-kit paths.
  FUNDING.yml, press kit
release_tooling also runs for every change that isn't documentation or media:
it is cheap, and it runs the dependency checks in the tests.

Fail closed: full CI for any path not listed above (new top-level paths,
assets, tools, Prototypes, other .github files), for tests.yml and scripts/ci/
(this classifier), for a .gitignore change that isn't limited to press-kit or
documentation entries, for every push other than a single commit on dev's
previous head, for pull requests into main or release/*, and whenever git or
this script fails. A changed file containing the upstream App Store listing ID
also gets the mac job, wherever it is (MacTests/AppStoreTests scans for it).

Usage:
  classify_pr_paths.py --github OUTPUT    tests.yml: reads GITHUB_EVENT_NAME,
                                          GITHUB_REF, GITHUB_BASE_REF and
                                          PUSH_BEFORE, diffs HEAD^1..HEAD
  classify_pr_paths.py CHANGED_PATHS_NUL GITIGNORE_DIFF [GITHUB_OUTPUT]
                                          the interface earlier tests.yml
                                          copies call; also writes the
                                          docs_media_only, workflow_only and
                                          press_kit keys they read
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional

JOBS = ("mac", "ios_build", "ios_ui", "android", "release_tooling", "press_kit")
ALL = frozenset(JOBS)
APPLE = frozenset({"mac", "ios_build", "ios_ui"})
APPS = APPLE | {"android"}
NOTHING: frozenset = frozenset()

# MacTests/AppStoreTests fails if the upstream listing ID appears in the
# repository. A changed file containing it must get the Mac job. Built from a
# number so this file never holds the literal.
UPSTREAM_ID = str(6_780_264_891)

# Markdown that nothing builds, bundles or tests (apart from the scan above).
MARKDOWN_DIRS = ("docs/", "handoff-2.0/", "launch/", "ux-review/")
# Markdown directly inside these directories (not their subdirectories, which
# can hold build or test resources).
MARKDOWN_SHALLOW_DIRS = ("fastlane/", "AndroidReceiver/")

# GitHub's issue forms and chooser: read only by GitHub's "New issue" page (and
# the upstream-ID scan). Listed by exact path: a new form, another .github file
# or a nested path still means full CI.
ISSUE_FORMS = frozenset(f".github/ISSUE_TEMPLATE/{name}.yml" for name in (
    "bug_report", "config", "device_testing", "documentation", "feature_request", "idea",
))
# Other files only GitHub's web pages read (the PR form, the Sponsor button).
GITHUB_PAGES = frozenset({".github/pull_request_template.md", ".github/FUNDING.yml"})

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg")
README_IMAGES = "assets/readme/"
PRESS_KIT_PREVIEW = "assets/press-kit-preview.png"

# Press-kit media and its build tooling. Neither is part of any app; the
# press-kit job validates both.
PRESS_KIT_DIRS = ("press-kit/", "tools/press-kit/")

# .gitignore lines that may change without full CI: generated press-kit output
# and documentation paths only.
SAFE_GITIGNORE_LINE = re.compile(r"/?(press\.html|press-kit(/\S*)?|docs(/\S*)?)")

# The Tests workflow and this classifier: full CI, always.
TESTS_WORKFLOW = ".github/workflows/tests.yml"
CI_DIR = "scripts/ci/"

# Workflows other than tests.yml. tests.yml calls none of them (the tests
# check that), so changing one can't change what the Tests jobs build or run;
# release-tooling checks they stay fail-closed. Listed by name: a new workflow
# means full CI until it is added here.
RELEASE_WORKFLOWS = frozenset(f".github/workflows/{name}.yml" for name in (
    "pr-title", "reference-intake", "reference-sync", "release-android", "release-candidate",
    "release-dry-run", "release-ios", "release-mac", "release-monitor", "release-pr",
    "release-preflight", "release-publish", "release-state-access", "repository-guard",
))
# Read by the release workflows, scripts/release and its tests; no app build
# or app test reads them.
RELEASE_FILES = frozenset({
    ".github/release-config.json", "Gemfile", "Gemfile.lock", "version.txt",
    "release-please-config.json", ".release-please-manifest.json",
    "fastlane/Appfile", "fastlane/Fastfile", "fastlane/Matchfile",
})
RELEASE_DIRS = ("scripts/release/", "scripts/reference/", ".github/rulesets/")

# App areas: path prefix (or exact file) -> the jobs that build or read it.
AREAS: tuple[tuple[str, frozenset], ...] = (
    ("Mac/", frozenset({"mac"})),
    ("MacReceiver/", frozenset({"mac"})),
    ("MacTests/", frozenset({"mac"})),
    ("iOS/", APPLE),
    ("iOSUITests/", frozenset({"ios_ui"})),
    ("Shared/", APPS),
    ("fixtures/", frozenset({"mac", "android"})),
    ("AndroidReceiver/", frozenset({"android"})),
)
AREA_FILES: dict[str, frozenset] = {
    "project.yml": APPLE,
    ".xcode-version": APPLE,
}


def is_documentation(path: str) -> bool:
    if not path.endswith(".md"):
        return False
    if "/" not in path:
        return True
    if path.startswith(MARKDOWN_DIRS):
        return True
    return any(path.startswith(d) and "/" not in path[len(d):] for d in MARKDOWN_SHALLOW_DIRS)


def is_press_kit(path: str) -> bool:
    return path.startswith(PRESS_KIT_DIRS) or path == PRESS_KIT_PREVIEW


def is_readme_image(path: str) -> bool:
    return path.startswith(README_IMAGES) and path.lower().endswith(IMAGE_SUFFIXES)


def gitignore_change_is_safe(diff: str) -> bool:
    """True when every added or removed .gitignore line is blank, a comment or a safe entry."""
    changed = [
        line[1:].strip()
        for line in diff.splitlines()
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
    ]
    if not changed:
        return False  # .gitignore is listed but no readable diff: run everything
    return all(not line or line.startswith("#") or SAFE_GITIGNORE_LINE.fullmatch(line) for line in changed)


def path_jobs(path: str, gitignore_diff: str = "") -> Optional[frozenset]:
    """The jobs one changed path needs, or None for full CI."""
    if is_documentation(path) or path in ISSUE_FORMS or path in GITHUB_PAGES or is_readme_image(path):
        return NOTHING
    if is_press_kit(path):
        return frozenset({"press_kit"})
    if path == ".gitignore":
        return NOTHING if gitignore_change_is_safe(gitignore_diff) else None
    if path == TESTS_WORKFLOW or path.startswith(CI_DIR):
        return None
    if path in RELEASE_WORKFLOWS or path in RELEASE_FILES or path.startswith(RELEASE_DIRS):
        return frozenset({"release_tooling"})
    if path in AREA_FILES:
        return AREA_FILES[path] | {"release_tooling"}
    for prefix, jobs in AREAS:
        if path.startswith(prefix):
            return jobs | {"release_tooling"}
    return None


def select_jobs(
    paths: Iterable[str],
    read_bytes: Callable[[str], Optional[bytes]],
    gitignore_diff: str = "",
) -> tuple[frozenset, str]:
    """The jobs a set of changed paths needs, and why. read_bytes returns a
    file's content, or None if it was deleted."""
    paths = list(paths)
    if not paths:
        return ALL, "no changed files"
    jobs: set[str] = set()
    for path in paths:
        needed = path_jobs(path, gitignore_diff)
        if needed is None:
            return ALL, f"{path} needs full CI"
        jobs |= needed
    if "mac" not in jobs:
        for path in paths:
            data = read_bytes(path)
            if data is not None and UPSTREAM_ID.encode() in data:
                jobs.add("mac")
                break
    # The macOS tests read iOS sources, so the iOS build never runs without them.
    if "ios_build" in jobs:
        jobs.add("mac")
    return frozenset(jobs), f"{len(paths)} changed files"


def classify(
    paths: Iterable[str],
    read_bytes: Callable[[str], Optional[bytes]],
    gitignore_diff: str = "",
) -> dict[str, bool]:
    jobs, _ = select_jobs(paths, read_bytes, gitignore_diff)
    return {job: job in jobs for job in JOBS}


def full_ci_reason(event: str, ref: str, base_ref: str, before: str, parent: str) -> Optional[str]:
    """Why this event gets full CI whatever its files, or None to classify them."""
    if event == "pull_request":
        if base_ref == "main" or base_ref.startswith("release/"):
            return f"a pull request into {base_ref}"
        return None
    if event == "push" and ref == "refs/heads/dev":
        if not before or before != parent:
            return "the push to dev is not a single commit on its previous head"
        return None
    return f"a {event or 'unknown event'} to {ref or 'an unknown ref'}: not a pull request or a single-commit push to dev"


def git(*args: str) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def read_worktree(path: str) -> Optional[bytes]:
    file = Path(path)
    return file.read_bytes() if file.is_file() else None


def select_from_git(env: dict[str, str]) -> tuple[frozenset, str]:
    """Selection for the checked-out commit, whose first parent is the PR's
    base (the synthetic merge commit's) or dev's previous head."""
    try:
        parent = git("rev-parse", "--verify", "--quiet", "HEAD^1^{commit}").decode().strip()
    except subprocess.CalledProcessError:
        return ALL, "no base commit"
    reason = full_ci_reason(env.get("GITHUB_EVENT_NAME", ""), env.get("GITHUB_REF", ""),
                            env.get("GITHUB_BASE_REF", ""), env.get("PUSH_BEFORE", ""), parent)
    if reason:
        return ALL, reason
    # --no-renames lists both sides of a rename, so code can't leave as a doc.
    raw = git("diff", "--no-renames", "--name-only", "-z", "HEAD^1", "HEAD")
    paths = [part.decode("utf-8") for part in raw.split(b"\0") if part]
    diff = git("diff", "--no-renames", "-U0", "HEAD^1", "HEAD", "--", ".gitignore").decode("utf-8", "replace")
    return select_jobs(paths, read_worktree, diff)


def output_lines(jobs: frozenset, reason: str) -> list[str]:
    return [f"{job}={str(job in jobs).lower()}" for job in JOBS] + ["reason=" + " ".join(reason.splitlines())]


def append(path: str, lines: list[str]) -> None:
    with open(path, "a", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--github":
        jobs, reason = select_from_git(dict(os.environ))
        lines = output_lines(jobs, reason)
        append(argv[2], lines)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            selected = ", ".join(job for job in JOBS if job in jobs) or "none"
            append(os.environ["GITHUB_STEP_SUMMARY"], [f"Selected Tests jobs: {selected}", "", f"Why: {reason}"])
        print(", ".join(lines))
        return 0
    if len(argv) not in (3, 4) or argv[1].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    # The earlier interface. tests.yml copies from before the per-job outputs
    # read docs_media_only (skip every app job and release-tooling),
    # workflow_only (skip the app jobs) and press_kit.
    raw = Path(argv[1]).read_bytes()
    paths = [part.decode("utf-8") for part in raw.split(b"\0") if part]
    diff = Path(argv[2]).read_text(encoding="utf-8", errors="replace")
    jobs, reason = select_jobs(paths, read_worktree, diff)
    docs_media_only = not jobs & (APPS | {"release_tooling"})
    workflow_only = "release_tooling" in jobs and not jobs & APPS
    lines = [
        f"docs_media_only={str(docs_media_only).lower()}",
        f"workflow_only={str(workflow_only).lower()}",
        f"press_kit={str('press_kit' in jobs).lower()}",
    ] + output_lines(jobs, reason)
    if len(argv) == 4:
        append(argv[3], lines)
    print(f"{len(paths)} files: " + ", ".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
