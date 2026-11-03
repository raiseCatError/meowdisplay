#!/usr/bin/env python3
"""Decide which Tests jobs a pull request needs, from the files it changes.

Used by the `changes` job in .github/workflows/tests.yml, which runs the copy
of this file from the base branch, so a pull request can't reclassify itself
by editing it. Tested by scripts/ci/test_classify_pr_paths.py.

Outputs (key=value lines, appended to $GITHUB_OUTPUT):
  docs_media_only  every path is documentation, press-kit media or press-kit
                   tooling: the Mac, iPhone Duo, Android and release-tooling
                   jobs are skipped.
  workflow_only    only .github/workflows/pr-title.yml changed: release-tooling
                   runs, app builds are skipped.
  press_kit        the press kit, its tooling or its preview image changed:
                   the press-kit validation job runs.

Fail closed: an unknown path, an unreadable input or a .gitignore change that
isn't limited to press-kit/documentation entries means full CI.

Usage: classify_pr_paths.py CHANGED_PATHS_NUL GITIGNORE_DIFF [GITHUB_OUTPUT]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional

# MacTests/AppStoreTests fails if the upstream listing ID appears in the
# repository. A changed file containing it must get the Mac job. Built from a
# number so this file never holds the literal.
UPSTREAM_ID = str(6_780_264_891)

# Markdown that nothing builds, bundles or tests (apart from the scan above).
MARKDOWN_DIRS = ("docs/", "handoff-2.0/", "launch/", "ux-review/")
# Markdown directly inside these directories (not their subdirectories, which
# can hold build or test resources).
MARKDOWN_SHALLOW_DIRS = ("fastlane/", "AndroidReceiver/")

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg")
README_IMAGES = "assets/readme/"
PRESS_KIT_PREVIEW = "assets/press-kit-preview.png"

# Press-kit media and its build tooling. Neither is part of any app; the
# press-kit job validates both.
PRESS_KIT_DIRS = ("press-kit/", "tools/press-kit/")

# .gitignore lines that may change without full CI: generated press-kit output
# and documentation paths only.
SAFE_GITIGNORE_LINE = re.compile(r"/?(press\.html|press-kit(/\S*)?|docs(/\S*)?)")


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


def classify(
    paths: Iterable[str],
    read_bytes: Callable[[str], Optional[bytes]],
    gitignore_diff: str = "",
) -> dict[str, bool]:
    """Classify changed paths. read_bytes returns a file's content, or None if it was deleted."""
    paths = list(paths)
    result = {"docs_media_only": False, "workflow_only": False, "press_kit": False}
    if not paths:
        return result
    result["press_kit"] = any(is_press_kit(p) for p in paths)
    result["workflow_only"] = all(p == ".github/workflows/pr-title.yml" for p in paths)

    def non_code(path: str) -> bool:
        if path == ".gitignore":
            return gitignore_change_is_safe(gitignore_diff)
        return is_documentation(path) or is_press_kit(path) or is_readme_image(path)

    if not all(non_code(p) for p in paths):
        return result
    for path in paths:
        data = read_bytes(path)
        if data is not None and UPSTREAM_ID.encode() in data:
            return result
    result["docs_media_only"] = True
    return result


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    raw = Path(argv[1]).read_bytes()
    paths = [part.decode("utf-8") for part in raw.split(b"\0") if part]
    diff = Path(argv[2]).read_text(encoding="utf-8", errors="replace")

    def read_bytes(path: str) -> Optional[bytes]:
        file = Path(path)
        return file.read_bytes() if file.is_file() else None

    result = classify(paths, read_bytes, diff)
    lines = [f"{key}={str(value).lower()}" for key, value in result.items()]
    if len(argv) == 4:
        with open(argv[3], "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
    print(f"{len(paths)} files: " + ", ".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
