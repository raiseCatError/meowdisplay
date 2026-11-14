"""Tests for classify_pr_paths.py: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import glob
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classify_pr_paths import (  # noqa: E402
    ALL, APPLE, APPS, GITHUB_PAGES, ISSUE_FORMS, JOBS, RELEASE_WORKFLOWS, UPSTREAM_ID, classify, full_ci_reason, select_jobs,
)

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).resolve().parent / "classify_pr_paths.py"
RT = "release_tooling"


def jobs(paths, contents=None, gitignore_diff=""):
    contents = contents or {}
    return select_jobs(paths, lambda p: contents.get(p, b"text"), gitignore_diff)[0]


class Base(unittest.TestCase):
    def assertFull(self, selected):
        self.assertEqual(selected, ALL)

    def assertJobs(self, paths, expected, **kwargs):
        self.assertEqual(jobs(paths, **kwargs), frozenset(expected), paths)


class DocumentationOnly(Base):
    def test_top_level_and_docs_markdown(self):
        self.assertJobs(["README.md", "docs/guide/setup.md", "launch/SOCIAL_POSTS.md", "SECURITY.md"], [])

    def test_shallow_markdown_only_directly_in_directory(self):
        self.assertJobs(["fastlane/APP_STORE_LISTING.md", "AndroidReceiver/README.md"], [])
        # Deeper Markdown can be a build or test resource.
        self.assertJobs(["AndroidReceiver/core/src/test/resources/video/README.md"], ["android", RT])
        self.assertFull(jobs(["fastlane/metadata/en-US/description.md"]))

    def test_markdown_in_an_app_area_runs_that_area(self):
        self.assertJobs(["Shared/NOTES.md"], APPS | {RT})
        self.assertJobs(["Mac/NOTES.md"], ["mac", RT])

    def test_markdown_elsewhere_runs_full_ci(self):
        self.assertFull(jobs([".github/NOTES.md"]))
        self.assertFull(jobs(["Prototypes/NOTES.md"]))

    def test_github_pages_files(self):
        for path in sorted(GITHUB_PAGES):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())
                self.assertJobs([path], [])
        path = ".github/FUNDING.yml"
        self.assertJobs([path], ["mac"], contents={path: UPSTREAM_ID.encode()})

    def test_non_markdown_docs_files_run_full_ci(self):
        self.assertFull(jobs(["docs/diagram.html"]))

    def test_upstream_listing_id_runs_mac(self):
        doc = f"See apps.apple.com/app/id{UPSTREAM_ID}".encode()
        self.assertJobs(["README.md"], ["mac"], contents={"README.md": doc})

    def test_deleted_documentation(self):
        self.assertEqual(select_jobs(["OLD_NOTES.md"], lambda p: None)[0], frozenset())


class PressKitOnly(Base):
    def test_media_and_tooling(self):
        self.assertJobs([
            "press-kit/Screenshots/iPhone/MeowDisplay-iPhone-Stage-Peek.png",
            "press-kit/README.txt",
            "tools/press-kit/build.py",
            "tools/press-kit/approved-assets.json",
            "assets/press-kit-preview.png",
        ], ["press_kit"])

    def test_readme_images(self):
        self.assertJobs(["assets/readme/hero.webp", "README.md"], [])

    def test_other_assets_run_full_ci(self):
        # The app icon sources feed the builds.
        self.assertFull(jobs(["assets/AppIcon-master.png"]))
        self.assertFull(jobs(["assets/readme/generate.sh"]))

    def test_other_tools_run_full_ci(self):
        self.assertFull(jobs(["tools/prerender.mjs"]))

    def test_upstream_listing_id_in_press_kit_runs_mac(self):
        self.assertJobs(["tools/press-kit/build.py"], ["press_kit", "mac"],
                        contents={"tools/press-kit/build.py": UPSTREAM_ID.encode()})


class Platforms(Base):
    def test_mac_sender_and_receiver(self):
        for path in ["Mac/AppDelegate.swift", "Mac/Info.plist", "Mac/OpenSidecarMac.entitlements",
                     "Mac/Localizable.xcstrings", "MacReceiver/Info.plist", "MacReceiver/ReceiverOwnership.swift",
                     "MacTests/AppStoreTests.swift"]:
            with self.subTest(path=path):
                self.assertJobs([path], ["mac", RT])

    def test_mac_changes_skip_ios_and_android(self):
        selected = jobs(["Mac/MacSender.swift", "MacReceiver/ReceiverInputForwarding.swift", "MacTests/X.swift"])
        self.assertNotIn("ios_build", selected)
        self.assertNotIn("ios_ui", selected)
        self.assertNotIn("android", selected)

    def test_ios_receiver_runs_mac_too(self):
        # The macOS tests compile iOS/DemoSession.swift and read iOS sources.
        for path in ["iOS/ContentView.swift", "iOS/Info.plist", "iOS/PrivacyInfo.xcprivacy",
                     "iOS/Localizable.xcstrings", "iOS/ReceiverSettings.swift"]:
            with self.subTest(path=path):
                self.assertJobs([path], APPLE | {RT})

    def test_ios_ui_tests_only(self):
        self.assertJobs(["iOSUITests/AdaptiveLayoutTests.swift"], ["ios_ui", RT])

    def test_android_only(self):
        for path in ["AndroidReceiver/app/src/main/kotlin/Main.kt",
                     "AndroidReceiver/core/src/main/kotlin/com/raisecaterror/meowdisplay/core/pairing/Pairing.kt",
                     "AndroidReceiver/gradle/libs.versions.toml", "AndroidReceiver/gradle/wrapper/gradle-wrapper.jar",
                     "AndroidReceiver/app/build.gradle.kts", "AndroidReceiver/settings.gradle.kts"]:
            with self.subTest(path=path):
                self.assertJobs([path], ["android", RT])

    def test_mixed_platforms_take_the_union(self):
        self.assertJobs(["Mac/AppDelegate.swift", "AndroidReceiver/app/src/main/kotlin/Main.kt"], ["mac", "android", RT])
        self.assertJobs(["iOSUITests/X.swift", "Mac/AppDelegate.swift"], ["mac", "ios_ui", RT])
        self.assertJobs(["iOS/X.swift", "README.md", "press-kit/README.txt"], APPLE | {RT, "press_kit"})


class SharedAndSecurity(Base):
    def test_shared_swift_runs_every_app_job(self):
        for path in ["Shared/Protocol.swift", "Shared/QUICReceiverSession.swift", "Shared/StagePeekDockLayout.swift"]:
            with self.subTest(path=path):
                self.assertJobs([path], APPS | {RT})

    def test_pairing_identity_and_encryption_run_every_platform(self):
        for path in ["Shared/PairingSession.swift", "Shared/TrustStore.swift", "Shared/StreamReceiver.swift",
                     "Shared/RemoteEndpointValidation.swift", "Shared/Inbox/NewFile.swift"]:
            with self.subTest(path=path):
                self.assertTrue(APPS <= jobs([path]), path)

    def test_cross_platform_fixtures_run_mac_and_android(self):
        self.assertJobs(["fixtures/receiver-protocol/control-chunks.json"], ["mac", "android", RT])
        self.assertJobs(["fixtures/new-area/vectors.json"], ["mac", "android", RT])

    def test_shared_deleted_or_renamed_into_docs_still_runs_everything(self):
        # --no-renames lists both sides: the old Shared/ path keeps the app jobs.
        selected = select_jobs(["Shared/Old.swift", "docs/Old.md"], lambda p: None if p.startswith("Shared") else b"x")[0]
        self.assertTrue(APPS <= selected)


class BuildConfiguration(Base):
    def test_xcode_project_and_toolchain(self):
        self.assertJobs(["project.yml"], APPLE | {RT})
        self.assertJobs([".xcode-version"], APPLE | {RT})
        self.assertNotIn("android", jobs(["project.yml"]))

    def test_android_build_configuration(self):
        self.assertJobs(["AndroidReceiver/gradle/wrapper/gradle-wrapper.properties"], ["android", RT])

    def test_ci_scripts_run_full_ci(self):
        for path in ["scripts/ci/select-xcode.sh", "scripts/ci/duo-simulator.sh", "scripts/ci/new.py"]:
            with self.subTest(path=path):
                self.assertFull(jobs([path]))

    def test_unknown_build_inputs_run_full_ci(self):
        for path in ["package.json", "pnpm-lock.yaml", "generate.sh", "run.sh", "Prototypes/CrashSafeShield/x.swift",
                     "LICENSE", "something-new/file.bin", "Package.resolved", "MeowDisplay.xcodeproj/project.pbxproj",
                     "scripts/other/tool.sh"]:
            with self.subTest(path=path):
                self.assertFull(jobs([path]))

    def test_unknown_with_anything_runs_full_ci(self):
        self.assertFull(jobs(["README.md", "LICENSE"]))
        self.assertFull(jobs(["Mac/AppDelegate.swift", "something-new/file.bin"]))

    def test_no_paths_runs_full_ci(self):
        self.assertFull(jobs([]))


class ReleaseTooling(Base):
    def test_release_scripts_and_config(self):
        for path in ["scripts/release/lib/release.rb", "scripts/release/check-website-app-access.sh",
                     "scripts/release/verify-ed25519.swift", "scripts/reference/intake.rb",
                     ".github/rulesets/dev.json", ".github/release-config.json", "fastlane/Fastfile",
                     "fastlane/Matchfile", "fastlane/Appfile", "Gemfile", "Gemfile.lock", "version.txt",
                     "release-please-config.json", ".release-please-manifest.json"]:
            with self.subTest(path=path):
                self.assertJobs([path], [RT])

    def test_pr_146_shape(self):
        # ci(release): check the website App's token and installation in the dry run
        self.assertJobs([".github/workflows/release-dry-run.yml", "RELEASE.md",
                         "scripts/release/check-release-workflows.rb", "scripts/release/check-website-app-access.sh",
                         "scripts/release/test/website_app_access_test.rb",
                         "scripts/release/test/workflow_checks_test.rb"], [RT])

    def test_each_listed_workflow(self):
        for path in sorted(RELEASE_WORKFLOWS):
            with self.subTest(path=path):
                self.assertJobs([path], [RT])

    def test_release_tooling_with_code_takes_the_union(self):
        self.assertJobs([".github/workflows/release-mac.yml", "Mac/AppDelegate.swift"], ["mac", RT])

    def test_upstream_listing_id_in_release_tooling_runs_mac(self):
        path = "fastlane/Fastfile"
        self.assertJobs([path], ["mac", RT], contents={path: UPSTREAM_ID.encode()})

    def test_other_fastlane_files_run_full_ci(self):
        self.assertFull(jobs(["fastlane/Pluginfile"]))
        self.assertFull(jobs(["fastlane/metadata/en-US/name.txt"]))


class Workflows(Base):
    def test_tests_workflow_and_classifier_run_full_ci(self):
        for path in [".github/workflows/tests.yml", "scripts/ci/classify_pr_paths.py",
                     "scripts/ci/test_classify_pr_paths.py"]:
            with self.subTest(path=path):
                self.assertFull(jobs([path]))
                self.assertFull(jobs([path, "README.md"]))

    def test_unlisted_workflows_and_github_files_run_full_ci(self):
        for path in [".github/workflows/new.yml", ".github/workflows/release-mac.yaml", ".github/FUNDING.yaml",
                     ".github/dependabot.yml", ".github/actions/setup/action.yml", ".github/CODEOWNERS",
                     ".github/PULL_REQUEST_TEMPLATE/feature.md"]:
            with self.subTest(path=path):
                self.assertFull(jobs([path]))

    def test_listed_workflows_exist_and_cover_every_workflow(self):
        actual = {str(p.relative_to(ROOT)) for p in (ROOT / ".github/workflows").glob("*.y*ml")}
        self.assertEqual(actual, set(RELEASE_WORKFLOWS) | {".github/workflows/tests.yml"},
                         "list a new workflow in RELEASE_WORKFLOWS only if tests.yml doesn't depend on it")

    def test_tests_workflow_uses_every_output_fail_closed(self):
        text = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")
        outputs = re.findall(r"^      (\w+): \$\{\{ steps\.classify\.outputs\.(\w+) \}\}$", text, re.M)
        self.assertEqual([a for a, b in outputs if a == b], [a for a, _ in outputs])
        # Every job key, and the UI test classes (not a job: the ios-duo job reads it, and
        # runs every class when it is empty, unknown or the changes job failed).
        self.assertEqual({a for a, _ in outputs}, set(JOBS) | {"ios_ui_tests"})
        full_ci = re.search(r"for job in ([\w ]+); do echo \"\$job=true\"", text)
        self.assertEqual(full_ci.group(1).split(), list(JOBS))
        # Each job (or step) is skipped only on an explicit 'false', and runs if classification failed.
        uses = re.findall(r"if: \$\{\{ (.*?) \}\}", text)
        expected = {"release-tooling": "release_tooling", "press-kit": "press_kit", "android": "android",
                    "mac": "mac", "ios-duo": "ios_ui"}
        for job, key in expected.items():
            with self.subTest(job=job):
                block = re.search(rf"^  {job}:\n    needs: changes\n    if: \$\{{\{{ (.*?) \}}\}}$", text, re.M)
                self.assertEqual(block.group(1), "!cancelled() && (needs.changes.result != 'success' || "
                                                 f"needs.changes.outputs.{key} != 'false')")
        steps = [u for u in uses if "ios_build" in u]
        self.assertEqual(steps, ["needs.changes.result != 'success' || needs.changes.outputs.ios_build != 'false'"] * 2)
        for use in uses:
            for key in re.findall(r"needs\.changes\.outputs\.(\w+)", use):
                self.assertIn(key, JOBS)
                self.assertIn(f"outputs.{key} != 'false'", use)

    def test_tests_workflow_calls_no_local_workflow_or_action(self):
        # If it did, changing that file would change the Tests jobs.
        text = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")
        self.assertNotRegex(text, r"uses:\s*\./")


class IssueForms(Base):
    FORMS = sorted(ISSUE_FORMS)

    def test_listed_forms_exist(self):
        for form in ISSUE_FORMS:
            with self.subTest(form=form):
                self.assertTrue((ROOT / form).is_file())

    def test_each_form_and_the_chooser(self):
        for form in self.FORMS:
            with self.subTest(form=form):
                self.assertJobs([form], [])

    def test_forms_with_documentation(self):
        self.assertJobs(self.FORMS + ["CONTRIBUTING.md", "docs/ISSUE_TRIAGE.md"], [])

    def test_forms_with_code_or_workflows(self):
        self.assertJobs([".github/ISSUE_TEMPLATE/bug_report.yml", "Mac/AppDelegate.swift"], ["mac", RT])
        self.assertJobs([".github/ISSUE_TEMPLATE/bug_report.yml", ".github/workflows/pr-title.yml"], [RT])
        for other in [".github/workflows/tests.yml", "scripts/ci/classify_pr_paths.py",
                      "scripts/ci/test_classify_pr_paths.py"]:
            with self.subTest(other=other):
                self.assertFull(jobs([".github/ISSUE_TEMPLATE/bug_report.yml", other]))

    def test_other_github_and_yaml_paths_run_full_ci(self):
        for path in [
            ".github/ISSUE_TEMPLATE/new_form.yml",          # a form not on the list
            ".github/ISSUE_TEMPLATE/bug_report.yaml",       # another extension
            ".github/ISSUE_TEMPLATE/old/bug_report.yml",    # nested
            ".github/ISSUE_TEMPLATE.md",
            "fastlane/bug_report.yml",
            "bug_report.yml",
        ]:
            with self.subTest(path=path):
                self.assertFull(jobs([path]))

    def test_upstream_listing_id_in_a_form_runs_mac(self):
        form = ".github/ISSUE_TEMPLATE/config.yml"
        self.assertJobs([form], ["mac"], contents={form: f"url: https://apps.apple.com/app/id{UPSTREAM_ID}".encode()})

    def test_forms_with_an_unsafe_gitignore_change_run_full_ci(self):
        self.assertFull(jobs([".github/ISSUE_TEMPLATE/idea.yml", ".gitignore"],
                             gitignore_diff="@@ -1 +1 @@\n+Shared/Generated/\n"))
        self.assertFull(jobs([".github/ISSUE_TEMPLATE/idea.yml", ".gitignore"]))


class Gitignore(Base):
    SAFE = "--- a/.gitignore\n+++ b/.gitignore\n@@ -1,0 +2,4 @@\n+\n+# Generated press kit\n+press.html\n+press-kit/*.zip\n+/press-kit/Previews/\n"

    def test_safe_entries(self):
        self.assertJobs([".gitignore", "press-kit/README.txt"], ["press_kit"], gitignore_diff=self.SAFE)

    def test_removing_safe_entry(self):
        self.assertJobs([".gitignore"], [], gitignore_diff="@@ -3 +2,0 @@\n-docs/_build/\n")

    def test_other_entries_run_full_ci(self):
        for line in ["+*.xcodeproj", "+Shared/Generated/", "-build/", "+press-kit-other", "+!press-kit/x"]:
            with self.subTest(line=line):
                self.assertFull(jobs([".gitignore"], gitignore_diff=f"@@ -1 +1 @@\n{line}\n"))

    def test_missing_diff_runs_full_ci(self):
        self.assertFull(jobs([".gitignore"]))


class Events(unittest.TestCase):
    """Which events are classified at all (full_ci_reason)."""

    def test_pull_requests_into_dev_and_feature_branches_are_classified(self):
        self.assertIsNone(full_ci_reason("pull_request", "refs/pull/9/merge", "dev", "", "abc"))
        self.assertIsNone(full_ci_reason("pull_request", "refs/pull/9/merge", "feature/x", "", "abc"))

    def test_pull_requests_into_main_or_release_run_full_ci(self):
        self.assertIsNotNone(full_ci_reason("pull_request", "refs/pull/9/merge", "main", "", "abc"))
        self.assertIsNotNone(full_ci_reason("pull_request", "refs/pull/9/merge", "release/2.1.0", "", "abc"))

    def test_single_commit_dev_push_is_classified(self):
        self.assertIsNone(full_ci_reason("push", "refs/heads/dev", "", "abc", "abc"))

    def test_other_dev_pushes_run_full_ci(self):
        self.assertIsNotNone(full_ci_reason("push", "refs/heads/dev", "", "old", "abc"))  # several commits / force
        self.assertIsNotNone(full_ci_reason("push", "refs/heads/dev", "", "", ""))
        self.assertIsNotNone(full_ci_reason("push", "refs/heads/dev", "", "0" * 40, "abc"))

    def test_main_release_and_other_events_run_full_ci(self):
        for event, ref in [("push", "refs/heads/main"), ("push", "refs/heads/release/2.1.0"),
                           ("push", "refs/heads/feature/x"), ("workflow_dispatch", "refs/heads/dev"),
                           ("schedule", "refs/heads/dev"), ("merge_group", "refs/heads/gh-readonly-queue/dev/x"),
                           ("", "")]:
            with self.subTest(event=event, ref=ref):
                self.assertIsNotNone(full_ci_reason(event, ref, "", "abc", "abc"))


class GitHubMode(unittest.TestCase):
    """The --github interface against real repositories, as tests.yml runs it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "dev")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI")
        self.commit({"README.md": "readme\n", "Mac/A.swift": "a\n", "Shared/P.swift": "p\n"})

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files, delete=()):
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for name in delete:
            (self.repo / name).unlink()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def run_cli(self, event, ref, base_ref="", before="", path=None):
        out = Path(self.tmp.name) / "out"
        out.unlink(missing_ok=True)
        env = {**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref, "GITHUB_BASE_REF": base_ref,
               "PUSH_BEFORE": before}
        env.pop("GITHUB_STEP_SUMMARY", None)
        if path is not None:
            env["PATH"] = path
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--github", str(out)], cwd=self.repo, env=env,
                                capture_output=True, text=True)
        if result.returncode != 0:
            return result.returncode, None
        values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return 0, values

    def selected(self, values):
        self.assertEqual(set(values), set(JOBS) | {"reason", "ios_ui_tests"})
        return {job for job in JOBS if values[job] == "true"}

    def test_single_commit_dev_push(self):
        before = self.git("rev-parse", "HEAD")
        self.commit({"Mac/A.swift": "b\n"})
        _, values = self.run_cli("push", "refs/heads/dev", before=before)
        self.assertEqual(self.selected(values), {"mac", RT})

    def test_single_docs_commit_on_dev(self):
        before = self.git("rev-parse", "HEAD")
        self.commit({"README.md": "more\n"})
        _, values = self.run_cli("push", "refs/heads/dev", before=before)
        self.assertEqual(self.selected(values), set())

    def test_multi_commit_dev_push_runs_full_ci(self):
        before = self.git("rev-parse", "HEAD")
        self.commit({"README.md": "one\n"})
        self.commit({"README.md": "two\n"})
        _, values = self.run_cli("push", "refs/heads/dev", before=before)
        self.assertEqual(self.selected(values), set(JOBS))
        self.assertIn("not a single commit", values["reason"])

    def test_pull_request_merge_commit(self):
        base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "-b", "topic")
        self.commit({"AndroidReceiver/app/Main.kt": "k\n"})
        self.commit({"docs/x.md": "d\n"})
        self.git("checkout", "-q", "--detach", base)
        self.git("merge", "-q", "--no-ff", "-m", "merge", "topic")  # like refs/pull/N/merge
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        self.assertEqual(self.selected(values), {"android", RT})
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="main")
        self.assertEqual(self.selected(values), set(JOBS))

    def test_deleted_and_renamed_files(self):
        (self.repo / "docs").mkdir()
        self.git("mv", "Shared/P.swift", "docs/P.md")
        self.git("commit", "-q", "-m", "rename")
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        # Into dev, the Duo UI tests wait for the dev integration gate (ui_selection.py).
        self.assertTrue(APPS - {"ios_ui"} <= self.selected(values))
        self.assertEqual(values["ios_ui_tests"], "")
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="main")
        self.assertTrue(APPS <= self.selected(values))
        self.assertEqual(values["ios_ui_tests"], "DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests")
        self.commit({}, delete=["Mac/A.swift"])
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        self.assertEqual(self.selected(values), {"mac", RT})

    def test_new_file_in_an_unknown_place(self):
        self.commit({"NewThing/x.bin": "x\n"})
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        self.assertEqual(self.selected(values), set(JOBS))

    def test_main_and_release_pushes_run_full_ci(self):
        before = self.git("rev-parse", "HEAD")
        self.commit({"README.md": "x\n"})
        every = "DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests"
        for ref in ["refs/heads/main", "refs/heads/release/2.1.0"]:
            with self.subTest(ref=ref):
                _, values = self.run_cli("push", ref, before=before)
                self.assertEqual(self.selected(values), set(JOBS))
                # A docs-only commit can't skip anything: the complete Duo suite runs again.
                self.assertEqual(values["ios_ui_tests"], every)
        for base_ref in ["main", "release/2.1.0"]:
            with self.subTest(base_ref=base_ref):
                _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref=base_ref)
                self.assertEqual(self.selected(values), set(JOBS))
                self.assertEqual(values["ios_ui_tests"], every)

    def test_missing_history_runs_full_ci(self):
        # A shallow or root commit: there is no HEAD^1 to compare with.
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        self.assertEqual(self.selected(values), set(JOBS))
        self.assertEqual(values["reason"], "no base commit")

    def test_upstream_listing_id_in_the_tree(self):
        self.commit({"docs/x.md": f"id{UPSTREAM_ID}\n"})
        _, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev")
        self.assertEqual(self.selected(values), {"mac"})

    def test_failure_writes_nothing_and_exits_non_zero(self):
        # tests.yml then runs full CI. Without git the classifier can't decide.
        self.commit({"README.md": "x\n"})
        code, values = self.run_cli("pull_request", "refs/pull/1/merge", base_ref="dev", path="/nonexistent")
        self.assertNotEqual(code, 0)
        self.assertIsNone(values)
        self.assertFalse((Path(self.tmp.name) / "out").exists())


class EarlierInterface(unittest.TestCase):
    """tests.yml copies from before the per-job outputs call the classifier with
    paths and read docs_media_only/workflow_only/press_kit; they must keep
    getting answers that are safe for them."""

    def run_legacy(self, paths, files=None):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for name, text in (files or {}).items():
                (tmp / name).parent.mkdir(parents=True, exist_ok=True)
                (tmp / name).write_text(text)
            (tmp / "paths").write_bytes(b"".join(p.encode() + b"\0" for p in paths))
            (tmp / "gitignore.diff").write_text("")
            out = tmp / "out"
            subprocess.run([sys.executable, str(SCRIPT), "paths", "gitignore.diff", str(out)],
                           cwd=tmp, check=True, capture_output=True, env={**os.environ})
            return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_documentation_and_press_kit(self):
        values = self.run_legacy(["README.md", "press-kit/a b.png"], {"README.md": "docs"})
        self.assertEqual((values["docs_media_only"], values["workflow_only"], values["press_kit"]),
                         ("true", "false", "true"))

    def test_release_tooling_only(self):
        values = self.run_legacy([".github/workflows/release-mac.yml"])
        self.assertEqual((values["docs_media_only"], values["workflow_only"]), ("false", "true"))

    def test_app_changes_get_full_ci_from_an_old_workflow(self):
        for path in ["Mac/A.swift", "AndroidReceiver/app/Main.kt", "iOSUITests/X.swift", "tools/x"]:
            with self.subTest(path=path):
                values = self.run_legacy([path])
                self.assertEqual((values["docs_media_only"], values["workflow_only"]), ("false", "false"))

    def test_bad_arguments(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--unknown"], capture_output=True)
        self.assertEqual(result.returncode, 2)


# The rules above must match what really builds and reads what. These checks
# read the repository, so a change to the build graph that the classifier
# doesn't know about fails here (release-tooling runs them for every change
# that isn't documentation or media).

TRACKED = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
TOP_DIRS = sorted({p.split("/")[0] for p in TRACKED if "/" in p}, key=len, reverse=True)
TOP_FILES = sorted({p for p in TRACKED if p and "/" not in p}, key=len, reverse=True)

# Xcode target -> the jobs that build or test it.
TARGET_JOBS = {
    "OpenSidecarMac": {"mac"},
    "OpenSidecarMacReceiver": {"mac"},
    "OpenSidecarMacTests": {"mac"},
    "OpenSidecariOS": {"ios_build", "ios_ui"},
    "OpenSidecariOSUITests": {"ios_ui"},
}


def project_targets(text):
    """{target: (repository roots it references, target dependencies)} from project.yml."""
    dir_ref = re.compile(r"(?<![\w./-])(%s)/" % "|".join(map(re.escape, TOP_DIRS)))
    source_item = re.compile(r"^\s*-\s*(?:path:\s*)?[\"']?(%s)[\"']?\s*$" % "|".join(map(re.escape, TOP_DIRS)))
    targets, outside, current, in_targets = {}, set(), None, False
    for line in text.splitlines():
        code = line.split("#", 1)[0]
        if line and not line[0].isspace():
            in_targets, current = line.startswith("targets:"), None
        elif in_targets and re.match(r"^  [A-Za-z][\w-]*:\s*$", line):
            current = line.strip()[:-1]
            targets[current] = (set(), set())
            continue
        found = {m.group(1) for m in dir_ref.finditer(code)}
        match = source_item.match(code)
        if match:
            found.add(match.group(1))
        dep = re.match(r"^\s*-\s*target:\s*(\S+)", code)
        if current:
            targets[current][0].update(found)
            if dep:
                targets[current][1].add(dep.group(1))
        else:
            outside.update(found)
    return targets, outside


def probes(path):
    """Paths whose change could change what reading `path` sees: the path itself
    and, in case it is a directory that is read whole, a document and a source
    file inside it."""
    path = path.rstrip("/")
    return [path] if path in TOP_FILES else [path, f"{path}/guard.md", f"{path}/guard.swift"]


class DependencyGraph(unittest.TestCase):
    def test_every_xcode_target_is_mapped_to_its_jobs(self):
        targets, _ = project_targets((ROOT / "project.yml").read_text(encoding="utf-8"))
        self.assertEqual(set(targets), set(TARGET_JOBS), "map a new Xcode target to the jobs that build it")

    def test_a_change_to_anything_a_target_compiles_selects_its_jobs(self):
        targets, outside = project_targets((ROOT / "project.yml").read_text(encoding="utf-8"))
        self.assertEqual(outside, set(), "project.yml references files outside its targets")
        for target, (roots, deps) in targets.items():
            needed = set(TARGET_JOBS[target])
            for dep in deps:
                roots = roots | targets[dep][0]
            self.assertTrue(roots, target)
            for root in roots:
                with self.subTest(target=target, root=root):
                    self.assertLessEqual(needed, jobs([f"{root}/Guard.swift"]))
        for path in ["project.yml", ".xcode-version"]:
            for needed in TARGET_JOBS.values():
                self.assertLessEqual(needed, jobs([path]))

    def test_mac_only_areas_are_compiled_by_no_ios_target(self):
        targets, _ = project_targets((ROOT / "project.yml").read_text(encoding="utf-8"))
        ios_roots = set()
        for target in ("OpenSidecariOS", "OpenSidecariOSUITests"):
            ios_roots |= targets[target][0]
        self.assertEqual(ios_roots, {"iOS", "Shared", "iOSUITests"})

    def test_android_reads_nothing_outside_its_directory_unclassified(self):
        refs = set()
        for name in glob.glob(str(ROOT / "AndroidReceiver/**/*"), recursive=True):
            if name.endswith((".kts", ".gradle", ".kt", ".properties")) and os.path.isfile(name):
                text = Path(name).read_text(encoding="utf-8", errors="replace")
                refs |= set(re.findall(r"\"\.\./([^\"$]+)\"", text))
        self.assertIn("fixtures/receiver-protocol", refs)  # the check can see the shared vectors
        for ref in refs:
            with self.subTest(ref=ref):
                for probe in probes(ref):
                    self.assertIn("android", jobs([probe]), probe)

    def test_every_repository_path_the_macos_tests_read_selects_mac(self):
        literal = re.compile(r"\"((?:%s)(?:/[^\"\\\s]*)?)\"" % "|".join(map(re.escape, TOP_DIRS + TOP_FILES)))
        seen = set()
        for name in sorted(glob.glob(str(ROOT / "MacTests/**/*.swift"), recursive=True)):
            for line in Path(name).read_text(encoding="utf-8").splitlines():
                # AppStoreTests' listing-ID scan of whole directories: the
                # classifier checks every changed file's content for the ID.
                if name.endswith("AppStoreTests.swift") and "for directory in" in line:
                    continue
                for value in literal.findall(line):
                    bare_dir = "/" not in value and value not in TOP_FILES
                    if bare_dir and not re.search(r"repoRoot|root\.appendingPathComponent|for directory in", line):
                        continue  # a word like "Mac" used as data, not a path
                    seen.add(value)
                    with self.subTest(path=value, file=os.path.basename(name)):
                        for probe in probes(value):
                            self.assertIn("mac", jobs([probe]), probe)
        self.assertTrue({"project.yml", "iOS/PrivacyInfo.xcprivacy"} <= seen, "the scan should find known reads")


if __name__ == "__main__":
    unittest.main()
