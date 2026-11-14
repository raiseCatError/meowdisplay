"""Tests for ui_selection.py: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ui_selection import (  # noqa: E402
    ALL_CLASSES, BUILD_ONLY, CI_CLASSES, Coverage, catalog_change, classes_in_test_file, line_map, select,
)

ROOT = Path(__file__).resolve().parents[2]
SMOKE, ADAPTIVE, CALC = CI_CLASSES
EVERY = " ".join(CI_CLASSES)

# A small file with executed, unexecuted and non-executable lines.
SOURCE = """\
import SwiftUI

struct Panel: View {
    @State private var shown = false
    var body: some View {
        Text("demo")
            .padding()
    }

    // Live sessions only.
    func live() {
        connect()
        retry()
    }
}
"""
EXECUTABLE = [[6, 7], [12, 13]]


def coverage(executed_by=None, commit="c" * 40, files=None):
    executed_by = executed_by if executed_by is not None else {SMOKE: [[6, 7]]}
    files = files or {"iOS/Panel.swift": EXECUTABLE}
    return Coverage({
        "commit": commit,
        "executable": files,
        "classes": {c: ({"iOS/Panel.swift": executed_by[c]} if c in executed_by else {}) for c in CI_CLASSES},
    })


def unified(old: str, new: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "a").write_text(old)
        Path(tmp, "b").write_text(new)
        return subprocess.run(["git", "diff", "--no-index", "-U0", f"{tmp}/a", f"{tmp}/b"],
                              capture_output=True, text=True).stdout


def run(paths, head, base, cov, coverage_diffs=None):
    return select(paths, head.get, base.get, lambda p: unified(base[p], head[p]),
                  lambda commit, p: (coverage_diffs or {}).get(p, ""), cov)


def edit(text, old, new):
    assert old in text
    return text.replace(old, new, 1)


class SwiftSources(unittest.TestCase):
    def test_an_executed_line_runs_the_classes_that_executed_it(self):
        head = {"iOS/Panel.swift": edit(SOURCE, 'Text("demo")', 'Text("Demo")')}
        tests, _ = run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": SOURCE}, coverage())
        self.assertEqual(tests, SMOKE)

    def test_code_no_ui_test_reaches_runs_no_duo_job(self):
        head = {"iOS/Panel.swift": edit(SOURCE, "        retry()\n", "        retry()\n        log()\n")}
        tests, why = run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": SOURCE}, coverage())
        self.assertEqual(tests, "", why)

    def test_simulator_only_code_still_builds_for_the_simulator(self):
        source = SOURCE.replace("        retry()\n", "        #if targetEnvironment(simulator)\n        retry()\n        #endif\n")
        cov = coverage({SMOKE: [[6, 7]]}, files={"iOS/Panel.swift": [[6, 7], [12, 12], [14, 14]]})
        head = {"iOS/Panel.swift": edit(source, "        retry()\n", "        retry(1)\n")}
        self.assertEqual(run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": source}, cov)[0], BUILD_ONLY)

    def test_a_comment_takes_its_neighbours(self):
        inside = edit(SOURCE, '        Text("demo")\n', '        // A note.\n        Text("demo")\n')
        tests, _ = run(["iOS/Panel.swift"], {"iOS/Panel.swift": inside}, {"iOS/Panel.swift": SOURCE}, coverage())
        self.assertEqual(tests, SMOKE)
        live = edit(SOURCE, "// Live sessions only.", "// Live sessions only, never the demo.")
        tests, _ = run(["iOS/Panel.swift"], {"iOS/Panel.swift": live}, {"iOS/Panel.swift": SOURCE},
                       coverage({SMOKE: [[6, 7]], CALC: [[12, 13]]}))
        self.assertEqual(tests, f"{SMOKE} {CALC}")  # between the body (Smoke) and live() (Calc)

    def test_a_declaration_takes_every_class_that_runs_the_file(self):
        head = {"iOS/Panel.swift": edit(SOURCE, "shown = false", "shown = true")}
        tests, why = run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": SOURCE},
                         coverage({SMOKE: [[6, 6]], ADAPTIVE: [[7, 7]]}))
        self.assertEqual(tests, f"{SMOKE} {ADAPTIVE}")
        self.assertIn("declaration", why)

    def test_extensions_protocols_operators_and_global_functions_run_everything(self):
        for added in ["extension View {\n    func padding() -> some View { self }\n}\n", "protocol P {}\n",
                      "infix operator <~>\n", "func helper() {}\n", "@MainActor\nextension Panel {}\n"]:
            with self.subTest(added=added):
                tests, _ = run(["iOS/Panel.swift"], {"iOS/Panel.swift": SOURCE + added},
                               {"iOS/Panel.swift": SOURCE}, coverage())
                self.assertEqual(tests, EVERY)

    def test_lines_changed_on_dev_since_the_coverage_take_the_whole_file(self):
        # Line 6 of the base is new since the coverage commit: its coverage is unknown.
        diff = "@@ -5,0 +6 @@\n+        Text(\"new\")\n"
        base = edit(SOURCE, '        Text("demo")\n', '        Text("new")\n        Text("demo")\n')
        head = {"iOS/Panel.swift": edit(base, 'Text("new")', 'Text("newer")')}
        tests, why = run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": base},
                         coverage({SMOKE: [[6, 7]], CALC: [[12, 13]]}), {"iOS/Panel.swift": diff})
        self.assertEqual(tests, f"{SMOKE} {CALC}")
        self.assertIn("changed on dev", why)

    def test_lines_moved_on_dev_since_the_coverage_are_followed(self):
        # Two lines added at the top on dev: the coverage's line 12 is the base's line 14.
        diff = "@@ -1,0 +2,2 @@\n+import Foundation\n+import Combine\n"
        base = edit(SOURCE, "import SwiftUI\n", "import SwiftUI\nimport Foundation\nimport Combine\n")
        head = {"iOS/Panel.swift": edit(base, "        connect()\n", "        connect(now: true)\n")}
        tests, _ = run(["iOS/Panel.swift"], head, {"iOS/Panel.swift": base},
                       coverage({SMOKE: [[6, 7]], CALC: [[12, 13]]}), {"iOS/Panel.swift": diff})
        self.assertEqual(tests, CALC)

    def test_fail_closed(self):
        changed = {"iOS/Panel.swift": edit(SOURCE, "retry()", "retry(1)")}
        base = {"iOS/Panel.swift": SOURCE}
        self.assertEqual(run(["iOS/Panel.swift"], changed, base, None)[0], EVERY)  # no coverage
        other = coverage(files={"iOS/Other.swift": [[1, 1]]})
        self.assertEqual(run(["iOS/Panel.swift"], changed, base, other)[0], EVERY)  # file unknown to it
        self.assertEqual(run(["iOS/New.swift"], {"iOS/New.swift": "x"}, {}, coverage())[0], EVERY)  # added
        self.assertEqual(run(["iOS/Panel.swift"], {}, base, coverage())[0], EVERY)  # deleted
        for path in ["iOS/Localizable.xcstrings", "iOS/Info.plist", "iOS/Assets.xcassets/x.json", "project.yml",
                     "iOS/PrivacyInfo.xcprivacy", "iOS/OpenSidecariOS.entitlements"]:
            with self.subTest(path=path):
                self.assertEqual(run([path], {path: "a"}, {path: "b"}, coverage())[0], EVERY)

    def test_shared_sources_use_the_coverage_too(self):
        cov = Coverage({"commit": "c" * 40, "executable": {"Shared/Panel.swift": EXECUTABLE},
                        "classes": {c: {} for c in CI_CLASSES}})
        head = {"Shared/Panel.swift": edit(SOURCE, "retry()", "retry(1)")}
        self.assertEqual(run(["Shared/Panel.swift"], head, {"Shared/Panel.swift": SOURCE}, cov)[0], "")


class UITestSources(unittest.TestCase):
    def test_a_ci_class_runs_alone(self):
        text = (ROOT / "iOSUITests/AdaptiveLayoutTests.swift").read_text()
        head = {"iOSUITests/AdaptiveLayoutTests.swift": text.replace("sleep(1)", "sleep(2)", 1)}
        tests, _ = run(list(head), head, {"iOSUITests/AdaptiveLayoutTests.swift": text}, None)
        self.assertEqual(tests, ADAPTIVE)

    def test_extensions_of_a_ci_class_count_as_that_class(self):
        self.assertEqual(classes_in_test_file("final class A: XCTestCase {}\nextension A {}\n"), {"A"})
        self.assertEqual(classes_in_test_file(f"extension {SMOKE} {{}}\n"), {SMOKE})

    def test_test_classes_ci_does_not_run_only_build(self):
        text = (ROOT / "iOSUITests/LiveSessionHomeTests.swift").read_text()
        head = {"iOSUITests/LiveSessionHomeTests.swift": text + "\n"}
        tests, _ = run(list(head), head, {"iOSUITests/LiveSessionHomeTests.swift": text}, None)
        self.assertEqual(tests, BUILD_ONLY)

    def test_shared_helpers_new_and_deleted_files_run_everything(self):
        helper = (ROOT / "iOSUITests/DemoDesktopWakePoint.swift").read_text()
        self.assertEqual(run(["iOSUITests/DemoDesktopWakePoint.swift"],
                             {"iOSUITests/DemoDesktopWakePoint.swift": helper + "\n"},
                             {"iOSUITests/DemoDesktopWakePoint.swift": helper}, None)[0], EVERY)
        self.assertEqual(run(["iOSUITests/New.swift"], {"iOSUITests/New.swift": "class N: XCTestCase {}"}, {},
                             None)[0], EVERY)
        self.assertEqual(run(["iOSUITests/Info.plist"], {"iOSUITests/Info.plist": "a"},
                             {"iOSUITests/Info.plist": "b"}, None)[0], EVERY)

    def test_moving_a_test_out_of_a_ci_class_still_runs_that_class(self):
        base = f"final class {CALC}: XCTestCase {{ func testA() {{}} }}\n"
        head = "final class Elsewhere: XCTestCase { func testA() {} }\n"
        self.assertEqual(run(["iOSUITests/X.swift"], {"iOSUITests/X.swift": head}, {"iOSUITests/X.swift": base},
                             None)[0], CALC)


class StringCatalogs(unittest.TestCase):
    CATALOG = "iOS/Localizable.xcstrings"

    @staticmethod
    def catalog(strings, **settings):
        import json
        return json.dumps({"sourceLanguage": "en", "version": "1.0", **settings, "strings": strings})

    def test_entries_without_text_of_their_own_change_nothing(self):
        base = self.catalog({"Done": {}, "Old": {"comment": "gone"}})
        head = self.catalog({"Done": {"comment": "now explained", "extractionState": "manual"},
                             "%@ for Arrows": {"comment": "new"}, "Back": {}})
        self.assertIsNone(catalog_change(head, base))
        # With a Swift change no UI test reaches, the pull request runs no Duo job.
        heads = {self.CATALOG: head, "iOS/Panel.swift": SOURCE.replace("retry()", "retry(1)")}
        bases = {self.CATALOG: base, "iOS/Panel.swift": SOURCE}
        tests, _ = select(list(heads), heads.get, bases.get,
                          lambda p: unified(bases[p], heads[p]), lambda c, p: "", coverage())
        self.assertEqual(tests, "")

    def test_text_the_app_shows_runs_everything(self):
        text = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Close"}}}}
        cases = [
            ({"Done": {}}, {"Done": text}),                      # a key gets its own text
            ({"Done": text}, {}),                                # a key with text is removed
            ({"Done": text}, {"Done": {**text, "comment": "c"}}),  # an entry with text changes at all
            ({}, {"%lld apps": {"variations": {}}}),             # plural or device variations
            ({"Done": {}}, {"Done": {"shouldTranslate": False}}),  # a field this check doesn't know
            ({"Done": {}}, {"Done": "Done"}),                    # not an entry
        ]
        for before, after in cases:
            with self.subTest(after=after):
                self.assertIsNotNone(catalog_change(self.catalog(after), self.catalog(before)))
                tests, _ = run([self.CATALOG], {self.CATALOG: self.catalog(after)},
                               {self.CATALOG: self.catalog(before)}, coverage())
                self.assertEqual(tests, EVERY)

    def test_catalog_settings_and_broken_files_run_everything(self):
        base = self.catalog({})
        for head in (self.catalog({}, sourceLanguage="de"), self.catalog({}, version="1.1"), "{", "[]",
                     '{"strings": []}'):
            with self.subTest(head=head):
                self.assertEqual(run([self.CATALOG], {self.CATALOG: head}, {self.CATALOG: base}, coverage())[0], EVERY)
        self.assertEqual(run([self.CATALOG], {self.CATALOG: base}, {}, coverage())[0], EVERY)  # added
        self.assertEqual(run([self.CATALOG], {}, {self.CATALOG: base}, coverage())[0], EVERY)  # deleted

    def test_other_catalogs_and_resources_still_run_everything(self):
        for path in ("iOS/InfoPlist.xcstrings.bak", "iOS/Assets.xcassets/x.json", "project.yml"):
            with self.subTest(path=path):
                self.assertEqual(run([path], {path: "{}"}, {path: "{}"}, coverage())[0], EVERY)


class Tiers(unittest.TestCase):
    """classify_pr_paths.py --github with --ui-coverage, in a real repository."""

    def setUp(self):
        import os
        self.os = os
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "dev")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI")
        self.adaptive = (ROOT / "iOSUITests/AdaptiveLayoutTests.swift").read_text()
        self.commit({"iOS/Panel.swift": SOURCE, "iOSUITests/AdaptiveLayoutTests.swift": self.adaptive,
                     "README.md": "r\n"})
        self.cov_commit = self.git("rev-parse", "HEAD")
        self.cov = Path(self.tmp.name) / "cov.json"
        self.cov.write_text(__import__("json").dumps({
            "commit": self.cov_commit, "executable": {"iOS/Panel.swift": EXECUTABLE},
            "classes": {SMOKE: {"iOS/Panel.swift": [[6, 7]]}, ADAPTIVE: {}, CALC: {}}}))

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files):
        for name, text in files.items():
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name).write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")

    def pull_request(self, files, base_ref="dev", coverage=True, event="pull_request", ref="refs/pull/1/merge"):
        base = self.cov_commit
        self.git("checkout", "-q", "--detach", base)
        self.git("checkout", "-q", "-b", f"topic{len(self.git('branch').splitlines())}")
        self.commit(files)
        topic = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "--detach", base)
        self.git("merge", "-q", "--no-ff", "-m", "merge", topic)
        out = Path(self.tmp.name) / "out"
        out.unlink(missing_ok=True)
        env = {**self.os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref, "GITHUB_BASE_REF": base_ref,
               "PUSH_BEFORE": base}
        env.pop("GITHUB_STEP_SUMMARY", None)
        args = [sys.executable, "-I", str(ROOT / "scripts/ci/classify_pr_paths.py"), "--github", str(out)]
        if coverage:
            args += ["--ui-coverage", str(self.cov) if coverage is True else coverage]
        subprocess.run(args, cwd=self.repo, env=env, check=True, capture_output=True)
        values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return values["ios_ui"], values["ios_ui_tests"]

    def test_a_change_no_ui_test_reaches_skips_the_duo_job(self):
        ios_ui, tests = self.pull_request({"iOS/Panel.swift": edit(SOURCE, "retry()", "retry(1)")})
        self.assertEqual((ios_ui, tests), ("false", ""))

    def test_a_reached_change_runs_only_its_classes(self):
        self.assertEqual(self.pull_request({"iOS/Panel.swift": edit(SOURCE, '"demo"', '"Demo"')}), ("true", SMOKE))

    def test_a_ui_test_change_runs_its_class(self):
        changed = self.adaptive.replace("sleep(1)", "sleep(2)", 1)
        self.assertEqual(self.pull_request({"iOSUITests/AdaptiveLayoutTests.swift": changed}), ("true", ADAPTIVE))

    def test_documentation_needs_no_duo_job(self):
        self.assertEqual(self.pull_request({"README.md": "more\n"}), ("false", ""))

    def test_documentation_beside_a_change_does_not_widen_it(self):
        change = {"iOS/Panel.swift": edit(SOURCE, '"demo"', '"Demo"'), "README.md": "more\n"}
        self.assertEqual(self.pull_request(change), ("true", SMOKE))
        change = {"iOS/Panel.swift": edit(SOURCE, "retry()", "retry(1)"), "README.md": "more\n"}
        self.assertEqual(self.pull_request(change), ("false", ""))

    def test_integration_and_release_run_every_class(self):
        change = {"iOS/Panel.swift": edit(SOURCE, "retry()", "retry(1)")}
        self.assertEqual(self.pull_request(change, base_ref="main"), ("true", EVERY))
        self.assertEqual(self.pull_request(change, event="push", ref="refs/heads/dev", base_ref=""), ("true", EVERY))

    def test_without_usable_coverage_every_class_runs(self):
        change = {"iOS/Panel.swift": edit(SOURCE, "retry()", "retry(1)")}
        self.assertEqual(self.pull_request(change, coverage=str(Path(self.tmp.name) / "missing.json")),
                         ("true", EVERY))
        self.assertEqual(self.pull_request(change, coverage=False), ("true", EVERY))
        # Coverage of a commit that isn't an ancestor of the base (or unknown here).
        data = __import__("json").loads(self.cov.read_text())
        data["commit"] = "f" * 40
        self.cov.write_text(__import__("json").dumps(data))
        self.assertEqual(self.pull_request(change), ("true", EVERY))


class Repository(unittest.TestCase):
    def test_ci_classes_exist_and_match_tests_yml(self):
        found = set()
        for path in (ROOT / "iOSUITests").glob("*.swift"):
            found |= set(re.findall(r"class (\w+)\s*:\s*XCTestCase", path.read_text()))
        self.assertLessEqual(ALL_CLASSES, found)
        text = (ROOT / ".github/workflows/tests.yml").read_text()
        fallback = re.search(r"^\s*all_classes=\"([\w ]+)\"$", text, re.M)
        self.assertIsNotNone(fallback, "tests.yml lists every CI class for when it has no selection")
        self.assertEqual(fallback.group(1).split(), list(CI_CLASSES))

    def test_the_duo_job_narrows_only_pull_requests_and_proves_each_class_ran(self):
        text = (ROOT / ".github/workflows/tests.yml").read_text()
        job = text[text.index("\n  ios-duo:\n"):]
        # Never narrower on the integration gate, after a failed changes job or with unknown names.
        self.assertIn('GATE: ${{ github.event_name == \'push\' && github.ref == \'refs/heads/dev\' }}', job)
        self.assertIn('if [[ "$CHANGES" == success && "$GATE" != true && -n "$SELECTED" ]]; then', job)
        self.assertIn('[[ " $all_classes " == *" $c "* ]] || known=false', job)
        # Each class runs alone and must have started and passed a test.
        self.assertIn('-only-testing:"OpenSidecariOSUITests/$class"', job)
        self.assertIn("grep -q \"Test Suite '$class' started\" \"$log\"", job)
        # The gate's coverage needs every class and only comes from a passing run.
        self.assertIn("for class in DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests; do", job)
        coverage = job[job.index("Keep the UI coverage"):job.index("\n  integration-report:\n")]
        self.assertNotIn("always()", coverage)

    def test_line_map_follows_git(self):
        old = "".join(f"l{i}\n" for i in range(1, 30))
        new = old.replace("l3\n", "").replace("l10\n", "x\nl10\n").replace("l20\n", "y\n")
        mapped = line_map(unified(old, new))
        new_lines = new.splitlines()
        for n, text in enumerate(new_lines, 1):
            target = mapped(n)
            if text.startswith("l"):
                self.assertEqual(old.splitlines()[target - 1], text)
            else:
                self.assertIsNone(target)


if __name__ == "__main__":
    unittest.main()
