#!/usr/bin/env python3
"""Which receiver UI test classes (the iPhone Duo job) a pull request runs.

The complete Duo UI suite runs where its coverage matters:
  - every push to dev: the integration gate, on the combined commit. Each job
    is judged against the last dev commit it passed on, so a later change can't
    skip past a failure;
  - pull requests into main or release/*, and pushes to main and release/*;
  - any branch, on request: run the Tests workflow by hand (workflow_dispatch).

Pull requests into dev or a feature branch run only the UI tests that target
their change:
  iOSUITests/*.swift  the CI classes the file defines or extends, before or
                      after (a new file counts as empty before, a deleted one
                      as empty after). Every class for anything shared:
                      helpers, extensions of other types, top-level functions,
                      protocols or operators (they can change what other tests
                      call), and files that aren't Swift.
  fold geometry       AdaptiveLayoutTests: the Duo's hinge and reserved
                      regions are only real on the Duo (FOLD_GEOMETRY).
  anything else       no UI test on the pull request. The required mac job
                      still compiles the receiver and its UI tests for iOS and
                      unit-tests the shared logic. The dev gate runs every
                      class once the change is merged.

classify_pr_paths.py only calls this for pull requests whose rules already
selected ios_ui, and never when they need full CI (CI files, unknown paths).
"""
from __future__ import annotations

import re
from typing import Callable, Optional

# The receiver UI test classes CI runs. tests.yml lists the same classes for
# when it has no selection; the tests check both.
CI_CLASSES = ("DemoModeSmokeTests", "AdaptiveLayoutTests", "LocalCalculatorTourTests")
ALL_CLASSES = frozenset(CI_CLASSES)

TEST_DIR = "iOSUITests/"
# Code whose result only the Duo shows: the hinge, the camera and the
# reserved regions the controls keep clear of.
FOLD_GEOMETRY = {
    "Shared/ControlFoldGeometry.swift": frozenset({"AdaptiveLayoutTests"}),
    "Shared/ControlTrayGeometry.swift": frozenset({"AdaptiveLayoutTests"}),
}

CLASS_DECL = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.M)
EXTENSION_DECL = re.compile(r"^\s*extension\s+(\w+)\b", re.M)
GLOBAL_DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|fileprivate\s+|private\s+)?"
                         r"(?:func|protocol|(?:prefix\s+|postfix\s+|infix\s+)?operator|precedencegroup)\b")


def classes_in_test_file(text: str) -> Optional[frozenset]:
    """The test classes a UI test file defines or extends; None if anything in
    it can affect other test files."""
    defined = set(CLASS_DECL.findall(text))
    extended = set(EXTENSION_DECL.findall(text))
    if not defined and not extended:
        return None  # a helper
    if extended - defined - ALL_CLASSES:
        return None  # extends something else (XCUIApplication helpers): shared by every class
    if any(GLOBAL_DECL.match(line) for line in text.splitlines()):
        return None  # a top-level function, protocol or operator
    return frozenset(defined | extended)


def select(paths: list[str], read_head: Callable[[str], Optional[str]],
           read_base: Callable[[str], Optional[str]]) -> tuple[frozenset, str]:
    """The CI classes a pull request runs, and why. Only paths that select
    ios_ui need to be given."""
    classes: set[str] = set()
    reasons: list[str] = []
    for path in paths:
        if path in FOLD_GEOMETRY:
            classes |= FOLD_GEOMETRY[path]
            reasons.append(f"{path} is fold geometry")
        elif path.startswith(TEST_DIR):
            head, base = read_head(path), read_base(path)
            found = [classes_in_test_file(text) for text in (head, base) if text is not None]
            if not path.endswith(".swift") or not found or None in found:
                classes |= ALL_CLASSES
                reasons.append(f"{path} is shared by the UI tests")
            else:
                ci = frozenset().union(*found) & ALL_CLASSES
                classes |= ci
                reasons.append(f"{path}: {' '.join(sorted(ci)) or 'no CI class (compiled by the mac job)'}")
    if not classes:
        return frozenset(), "; ".join(reasons + ["the Duo UI tests run at the dev integration gate"])
    return frozenset(classes), "; ".join(reasons)
