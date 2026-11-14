#!/usr/bin/env python3
"""Which of the receiver's CI UI test classes a pull request into dev needs.

Pull requests get fast feedback: the iPhone Duo UI tests run only for what a
change can reach. Pushes to dev (the integration gate), pull requests into
main or release/* and every push other than to dev still run every CI UI test
class; classify_pr_paths.py only calls this for pull requests into dev or a
feature branch, and only once its own rules already selected ios_ui.

What a change reaches:
  iOSUITests/ files   the CI classes the file defines or extends; a file
                      that defines only test classes CI doesn't run is
                      compiled but runs nothing ("build-only"); anything
                      else there (helpers, new kinds of file) runs them all.
  iOS/*.swift,        by line coverage, per class, from the dev integration
  Shared/*.swift      run (ui_coverage.py): a class runs if it executed a
                      line a hunk changes, or one of the two lines around a
                      hunk that only adds lines. A change no class reaches
                      runs no Duo job (the mac job compiles the app), unless
                      the file has simulator-only code ("build-only").
                      Lines that aren't executable count by their kind:
                      blank, comment and brace lines by the executable lines
                      around them; declarations (properties, cases,
                      attributes) by the whole file. A hunk that adds or
                      removes an extension, protocol, operator or global
                      function can change overload resolution anywhere, so
                      it runs every class.
  anything else       every class (string catalogs, assets, the project,
                      Info.plist, entitlements, privacy manifest).

Fail closed: no coverage, a file the coverage doesn't know, lines that
changed on dev since the coverage was recorded, or any error means every
class. This is a fast-feedback heuristic, never the last word: the dev push
after the merge runs every class.
"""
from __future__ import annotations

import re
from typing import Callable, Optional

# The receiver UI test classes CI runs (the iPhone Duo job). tests.yml lists
# the same classes for when it can't use a selection; the tests check both.
CI_CLASSES = ("DemoModeSmokeTests", "AdaptiveLayoutTests", "LocalCalculatorTourTests")
ALL_CLASSES = frozenset(CI_CLASSES)
BUILD_ONLY = "build-only"

TEST_DIR = "iOSUITests/"
SIMULATOR_ONLY = "targetEnvironment(simulator)"
COVERED_DIRS = ("iOS/", "Shared/")

CLASS_DECL = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.M)
EXTENSION_DECL = re.compile(r"^\s*extension\s+(\w+)\b", re.M)
# Added or removed lines that can change overload resolution or dispatch
# outside the code around them.
GLOBAL_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|fileprivate\s+|private\s+)?"
                         r"(?:extension|protocol|(?:prefix\s+|postfix\s+|infix\s+)?operator|precedencegroup)\b")
TOP_LEVEL_FUNC = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|fileprivate\s+|private\s+)?func\b")
TRIVIAL = re.compile(r"^\s*(?://.*|/\*.*|\*.*|\*/|[{}()\[\],;]*\s*(?://.*)?)?$")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class Coverage:
    """Line coverage from one integration run, for the commit it ran on.

    data: {"commit": sha, "executable": {file: [[first, last], ...]},
           "classes": {class: {file: [[first, last], ...]}}} (executed ranges)."""

    def __init__(self, data: dict):
        if not isinstance(data, dict) or not isinstance(data.get("commit"), str):
            raise ValueError("coverage: no commit")
        self.commit = data["commit"]
        self.executable = {f: self._lines(r) for f, r in data["executable"].items()}
        classes = data["classes"]
        if set(classes) != ALL_CLASSES:
            raise ValueError("coverage: needs exactly the CI classes")
        self.executed = {c: {f: self._lines(r) for f, r in files.items()} for c, files in classes.items()}

    @staticmethod
    def _lines(ranges) -> frozenset:
        lines = set()
        for first, last in ranges:
            if not (isinstance(first, int) and isinstance(last, int) and 0 < first <= last):
                raise ValueError("coverage: bad range")
            lines.update(range(first, last + 1))
        return frozenset(lines)

    def knows(self, file: str) -> bool:
        return file in self.executable

    def runs_file(self, cls: str, file: str) -> bool:
        return bool(self.executed[cls].get(file))


def parse_hunks(diff: str) -> list[tuple[int, int, int, int, list[str], list[str]]]:
    """(old start, old count, new start, new count, removed lines, added lines)
    per hunk of a -U0 diff."""
    hunks = []
    current = None
    for line in diff.splitlines():
        m = HUNK.match(line)
        if m:
            current = (int(m.group(1)), int(m.group(2) or "1"), int(m.group(3)), int(m.group(4) or "1"), [], [])
            hunks.append(current)
        elif current is not None and line[:1] == "-" and not line.startswith("---"):
            current[4].append(line[1:])
        elif current is not None and line[:1] == "+" and not line.startswith("+++"):
            current[5].append(line[1:])
    return hunks


def line_map(diff: str) -> Callable[[int], Optional[int]]:
    """For a -U0 diff from the coverage commit (old) to the base (new): base line
    -> coverage line, or None where the base line is new or changed since then."""
    hunks = [(new_start, new_count, old_count - new_count)
             for _os, old_count, new_start, new_count, _r, _a in parse_hunks(diff)]

    def mapped(line: int) -> Optional[int]:
        delta = 0
        for new_start, new_count, change in hunks:
            if new_count:
                if line < new_start:
                    break
                if line < new_start + new_count:
                    return None
            elif line <= new_start:  # lines removed after new_start
                break
            delta += change
        return line + delta

    return mapped


def classes_in_test_file(text: Optional[str]) -> Optional[frozenset]:
    """The test classes a UI test file defines or extends; None if it isn't a test file."""
    if text is None:
        return None
    defined = set(CLASS_DECL.findall(text))
    extended = set(EXTENSION_DECL.findall(text))
    if not defined and not extended:
        return None
    if extended - defined - ALL_CLASSES:
        return None  # extends something else (XCUIApplication helpers): shared by every class
    return frozenset(defined | extended)


class Selection:
    def __init__(self):
        self.classes: set[str] = set()
        self.build = False
        self.reasons: list[str] = []

    def everything(self, why: str):
        self.classes = set(ALL_CLASSES)
        self.reasons.append(why)

    @property
    def complete(self) -> bool:
        return self.classes == ALL_CLASSES


def hunk_classes(cov: Coverage, file: str, hunk, base_lines: list[str],
                 to_cov: Callable[[int], Optional[int]]) -> tuple[frozenset, str]:
    """The classes one hunk of a pull request can reach. A hunk that changes or
    removes lines is judged by those lines; a hunk that only adds lines by the
    two lines around the insertion."""
    old_start, old_count, _new_start, _new_count, removed, added = hunk
    if any(GLOBAL_DECL.match(t) or TOP_LEVEL_FUNC.match(t) for t in removed + added):
        return ALL_CLASSES, f"{file}:{old_start} declares an extension, protocol, operator or global function"
    file_classes = frozenset(c for c in CI_CLASSES if cov.runs_file(c, file))
    changed = old_count > 0
    lines = range(old_start, old_start + old_count) if changed else range(old_start, old_start + 2)
    hit: set[str] = set()
    for n in (n for n in lines if 1 <= n <= len(base_lines)):
        m = to_cov(n)
        if m is None:
            return file_classes, f"{file}:{n} changed on dev since the coverage"
        if m in cov.executable[file]:
            hit |= {c for c in CI_CLASSES if m in cov.executed[c].get(file, ())}
        elif changed and not TRIVIAL.match(base_lines[n - 1]):
            return file_classes, f"{file}:{n} is a declaration"
        else:
            for neighbour in nearest_executable(cov, file, m):
                hit |= {c for c in CI_CLASSES if neighbour in cov.executed[c].get(file, ())}
    return frozenset(hit), f"{file}:{old_start}"


def nearest_executable(cov: Coverage, file: str, line: int) -> list[int]:
    executable = sorted(cov.executable[file])
    above = [n for n in executable if n < line]
    below = [n for n in executable if n > line]
    return ([above[-1]] if above else []) + ([below[0]] if below else [])


def select(paths: list[str], read_head: Callable[[str], Optional[str]], read_base: Callable[[str], Optional[str]],
           pr_diff: Callable[[str], str], coverage_diff: Callable[[str, str], str],
           coverage: Optional[Coverage]) -> tuple[str, str]:
    """The ios_ui_tests output for a pull request: space-separated classes,
    BUILD_ONLY, or "" for none; and why. Only paths the classifier already
    sent to ios_ui need to be given; others are ignored."""
    sel = Selection()
    for path in paths:
        if sel.complete:
            break
        if path.startswith(TEST_DIR):
            if not path.endswith(".swift"):
                sel.everything(f"{path} is not a Swift test file")
                continue
            head, base = read_head(path), read_base(path)
            if head is None or base is None:
                sel.everything(f"{path} is added or deleted")
                continue
            found = classes_in_test_file(head)
            before = classes_in_test_file(base)
            if found is None or before is None:
                sel.everything(f"{path} is shared by the UI tests")
                continue
            ci = (found | before) & ALL_CLASSES
            sel.classes |= ci
            sel.build = True
            sel.reasons.append(f"{path}: {' '.join(sorted(ci)) or 'no CI class'}")
            continue
        if not (path.startswith(COVERED_DIRS) and path.endswith(".swift")):
            sel.everything(f"{path} can change any UI")
            continue
        if coverage is None:
            sel.everything("no UI coverage")
            continue
        head, base = read_head(path), read_base(path)
        if head is None or base is None or not coverage.knows(path):
            sel.everything(f"{path} is new, deleted or not in the UI coverage")
            continue
        to_cov = line_map(coverage_diff(coverage.commit, path))
        base_lines = base.splitlines()
        # The mac job builds the app for devices; code only a simulator compiles
        # still needs the simulator build.
        if SIMULATOR_ONLY in head or SIMULATOR_ONLY in base:
            sel.build = True
            sel.reasons.append(f"{path} has simulator-only code")
        for hunk in parse_hunks(pr_diff(path)):
            classes, why = hunk_classes(coverage, path, hunk, base_lines, to_cov)
            if classes:
                sel.reasons.append(f"{why}: {' '.join(sorted(classes))}")
            sel.classes |= classes
    if sel.classes:
        return " ".join(c for c in CI_CLASSES if c in sel.classes), "; ".join(sel.reasons)
    if sel.build:
        return BUILD_ONLY, "; ".join(sel.reasons) or "no UI test reaches the change"
    return "", "no UI test reaches the change"
