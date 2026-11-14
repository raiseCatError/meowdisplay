"""Tests for ui_selection.py: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ui_selection import ALL_CLASSES, CI_CLASSES, FOLD_GEOMETRY, classes_in_test_file, select  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SMOKE, ADAPTIVE, CALC = CI_CLASSES
EVERY = " ".join(CI_CLASSES)
NEW_TOUR = "import XCTest\n\nfinal class NewTourTests: XCTestCase {\n    func testIt() {}\n}\n"


def run(paths, head, base):
    classes, _ = select(paths, head.get, base.get)
    return " ".join(c for c in CI_CLASSES if c in classes)


class UITestSources(unittest.TestCase):
    def test_a_ci_class_runs_alone(self):
        text = (ROOT / "iOSUITests/AdaptiveLayoutTests.swift").read_text()
        path = "iOSUITests/AdaptiveLayoutTests.swift"
        self.assertEqual(run([path], {path: text.replace("sleep(1)", "sleep(2)", 1)}, {path: text}), ADAPTIVE)

    def test_extensions_of_a_ci_class_count_as_that_class(self):
        more = "import XCTest\nextension DemoModeSmokeTests {\n    func testMore() {}\n}\n"
        self.assertEqual(classes_in_test_file(more), frozenset({SMOKE}))
        self.assertEqual(run(["iOSUITests/More.swift"], {"iOSUITests/More.swift": more}, {}), SMOKE)   # added
        self.assertEqual(run(["iOSUITests/More.swift"], {}, {"iOSUITests/More.swift": more}), SMOKE)   # deleted

    def test_test_classes_ci_does_not_run_need_no_duo_job(self):
        self.assertEqual(run(["iOSUITests/New.swift"], {"iOSUITests/New.swift": NEW_TOUR}, {}), "")

    def test_moving_a_test_out_of_a_ci_class_still_runs_that_class(self):
        before = "import XCTest\nfinal class DemoModeSmokeTests: XCTestCase {}\n"
        self.assertEqual(run(["iOSUITests/X.swift"], {"iOSUITests/X.swift": NEW_TOUR}, {"iOSUITests/X.swift": before}),
                         SMOKE)

    def test_anything_shared_runs_every_class(self):
        helper = (ROOT / "iOSUITests/DemoDesktopWakePoint.swift").read_text()
        path = "iOSUITests/DemoDesktopWakePoint.swift"
        self.assertEqual(run([path], {path: helper + "\n"}, {path: helper}), EVERY)
        self.assertEqual(run(["iOSUITests/Info.plist"], {"iOSUITests/Info.plist": "a"}, {"iOSUITests/Info.plist": "b"}),
                         EVERY)
        self.assertEqual(run(["iOSUITests/Gone.swift"], {}, {}), EVERY)
        for shared in ("func tapTwice(_ e: XCUIElement) {}", "protocol Tour {}", "infix operator <~>",
                       "@MainActor func settle() {}", "extension XCUIElement { func x() {} }"):
            with self.subTest(shared=shared):
                text = "import XCTest\n" + shared + "\n" + NEW_TOUR
                self.assertEqual(run(["iOSUITests/New.swift"], {"iOSUITests/New.swift": text}, {}), EVERY)
                self.assertEqual(run(["iOSUITests/New.swift"], {"iOSUITests/New.swift": NEW_TOUR},
                                     {"iOSUITests/New.swift": text}), EVERY)


class AppSources(unittest.TestCase):
    def test_fold_geometry_runs_the_adaptive_layout_tests(self):
        for path in FOLD_GEOMETRY:
            with self.subTest(path=path):
                self.assertEqual(run([path], {path: "a"}, {path: "b"}), ADAPTIVE)

    def test_other_app_code_waits_for_the_integration_gate(self):
        for path in ("iOS/OpenSidecarPhoneApp.swift", "Shared/WorkspaceViews.swift", "iOS/Localizable.xcstrings",
                     "project.yml"):
            with self.subTest(path=path):
                classes, why = select([path], {path: "a"}.get, {path: "b"}.get)
                self.assertEqual(classes, frozenset())
                self.assertIn("dev integration gate", why)


class Tiers(unittest.TestCase):
    """classify_pr_paths.py --github in a real repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "dev")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI")
        self.adaptive = (ROOT / "iOSUITests/AdaptiveLayoutTests.swift").read_text()
        self.commit({"iOS/Panel.swift": "struct Panel {}\n", "Shared/ControlFoldGeometry.swift": "enum Fold {}\n",
                     "iOSUITests/AdaptiveLayoutTests.swift": self.adaptive, "README.md": "r\n"})
        self.base = self.git("rev-parse", "HEAD")

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

    def classify(self, files, base_ref="dev", event="pull_request", ref="refs/pull/1/merge"):
        self.git("checkout", "-q", "--detach", self.base)
        self.git("checkout", "-q", "-b", f"topic{len(self.git('branch').splitlines())}")
        self.commit(files)
        topic = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "--detach", self.base)
        self.git("merge", "-q", "--no-ff", "-m", "merge", topic)
        out = Path(self.tmp.name) / "out"
        out.unlink(missing_ok=True)
        env = {**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref, "GITHUB_BASE_REF": base_ref,
               "PUSH_BEFORE": self.base}
        env.pop("GITHUB_STEP_SUMMARY", None)
        subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/classify_pr_paths.py"), "--github", str(out)],
                       cwd=self.repo, env=env, check=True, capture_output=True)
        values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return values["ios_ui"], values["ios_ui_tests"], values["mac"]

    def test_app_code_runs_no_duo_job_but_still_the_mac_job(self):
        self.assertEqual(self.classify({"iOS/Panel.swift": "struct Panel { var x = 1 }\n"}), ("false", "", "true"))

    def test_a_ui_test_change_runs_its_class(self):
        changed = self.adaptive.replace("sleep(1)", "sleep(2)", 1)
        self.assertEqual(self.classify({"iOSUITests/AdaptiveLayoutTests.swift": changed}), ("true", ADAPTIVE, "true"))

    def test_a_ui_test_no_ci_class_runs_is_still_compiled_by_the_mac_job(self):
        self.assertEqual(self.classify({"iOSUITests/NewTourTests.swift": NEW_TOUR}), ("false", "", "true"))

    def test_fold_geometry_runs_the_adaptive_layout_tests(self):
        self.assertEqual(self.classify({"Shared/ControlFoldGeometry.swift": "enum Fold { case hinge }\n"})[:2],
                         ("true", ADAPTIVE))

    def test_documentation_needs_no_duo_job(self):
        self.assertEqual(self.classify({"README.md": "more\n"})[:2], ("false", ""))

    def test_promotion_and_other_pushes_run_every_class(self):
        change = {"iOS/Panel.swift": "struct Panel { var x = 1 }\n"}
        self.assertEqual(self.classify(change, base_ref="main")[:2], ("true", EVERY))
        self.assertEqual(self.classify(change, base_ref="release/2.2.0")[:2], ("true", EVERY))
        self.assertEqual(self.classify(change, event="push", ref="refs/heads/release/2.2.0", base_ref="")[:2],
                         ("true", EVERY))
        self.assertEqual(self.classify(change, event="workflow_dispatch", ref="refs/heads/topic", base_ref="")[:2],
                         ("true", EVERY))


class Repository(unittest.TestCase):
    text = (ROOT / ".github/workflows/tests.yml").read_text()

    def test_ci_classes_and_fold_geometry_exist(self):
        found = set()
        for path in (ROOT / "iOSUITests").glob("*.swift"):
            found |= set(re.findall(r"class (\w+)\s*:\s*XCTestCase", path.read_text()))
        self.assertLessEqual(ALL_CLASSES, found)
        for path in FOLD_GEOMETRY:
            self.assertTrue((ROOT / path).is_file(), path)

    def test_the_duo_job_runs_every_class_unless_a_pull_request_narrows_it(self):
        job = self.text[self.text.index("\n  ios-duo:\n"):self.text.index("\n  integration-report:\n")]
        fallback = re.search(r"^\s*all_classes=\"([\w ]+)\"$", job, re.M)
        self.assertEqual(fallback.group(1).split(), list(CI_CLASSES))
        self.assertIn("if [[ \"$CHANGES\" == success && \"$EVENT\" == pull_request && -n \"$SELECTED\" ]]; then", job)
        self.assertIn('[[ " $all_classes " == *" $c "* ]] || known=false', job)
        # Each class must have started and passed a test; a class that ran nothing fails.
        self.assertIn("grep -q \"Test Suite '$class' started\" \"$log\"", job)

    def test_the_mac_job_compiles_the_ui_tests_on_every_ios_change(self):
        mac = self.text[self.text.index("\n  mac:\n"):self.text.index("\n  ios-duo:\n")]
        step = mac[mac.index("- name: Build iOS receiver app\n"):]
        self.assertIn("xcodebuild build-for-testing", step[:step.index("- name:", 10)])

    def test_the_suite_can_be_run_on_request(self):
        self.assertRegex(self.text, r"\non:\n(?:.*\n)*?  workflow_dispatch:\n")


if __name__ == "__main__":
    unittest.main()
