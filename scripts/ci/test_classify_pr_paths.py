"""Tests for classify_pr_paths.py: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classify_pr_paths import UPSTREAM_ID, classify  # noqa: E402

FULL = {"docs_media_only": False, "workflow_only": False}


def run(paths, contents=None, gitignore_diff=""):
    contents = contents or {}
    return classify(paths, lambda p: contents.get(p, b"text"), gitignore_diff)


def assert_full_ci(case, result):
    case.assertFalse(result["docs_media_only"])
    case.assertFalse(result["workflow_only"])


class DocumentationOnly(unittest.TestCase):
    def test_top_level_and_docs_markdown(self):
        r = run(["README.md", "docs/guide/setup.md", "launch/SOCIAL_POSTS.md"])
        self.assertTrue(r["docs_media_only"])
        self.assertFalse(r["press_kit"])

    def test_shallow_markdown_only_directly_in_directory(self):
        self.assertTrue(run(["fastlane/APP_STORE_LISTING.md", "AndroidReceiver/README.md"])["docs_media_only"])
        # Deeper Markdown can be a build or test resource.
        assert_full_ci(self, run(["AndroidReceiver/core/src/test/resources/video/README.md"]))
        assert_full_ci(self, run(["fastlane/metadata/en-US/description.md"]))

    def test_markdown_elsewhere_runs_full_ci(self):
        assert_full_ci(self, run(["Shared/NOTES.md"]))
        assert_full_ci(self, run([".github/pull_request_template.md"]))

    def test_non_markdown_docs_files_run_full_ci(self):
        assert_full_ci(self, run(["docs/diagram.html"]))

    def test_upstream_listing_id_runs_full_ci(self):
        doc = f"See apps.apple.com/app/id{UPSTREAM_ID}".encode()
        assert_full_ci(self, run(["README.md"], {"README.md": doc}))

    def test_deleted_documentation(self):
        r = classify(["OLD_NOTES.md"], lambda p: None)
        self.assertTrue(r["docs_media_only"])


class PressKitOnly(unittest.TestCase):
    def test_media_and_tooling(self):
        r = run([
            "press-kit/Screenshots/iPhone/MeowDisplay-iPhone-Stage-Peek.png",
            "press-kit/README.txt",
            "tools/press-kit/build.py",
            "tools/press-kit/approved-assets.json",
            "assets/press-kit-preview.png",
        ])
        self.assertTrue(r["docs_media_only"])
        self.assertTrue(r["press_kit"])

    def test_readme_images(self):
        r = run(["assets/readme/hero.webp", "README.md"])
        self.assertTrue(r["docs_media_only"])
        self.assertFalse(r["press_kit"])

    def test_other_assets_run_full_ci(self):
        # The app icon sources feed the builds.
        assert_full_ci(self, run(["assets/AppIcon-master.png"]))
        assert_full_ci(self, run(["assets/readme/generate.sh"]))

    def test_other_tools_run_full_ci(self):
        assert_full_ci(self, run(["tools/prerender.mjs"]))

    def test_upstream_listing_id_in_press_kit_runs_full_ci(self):
        assert_full_ci(self, run(["tools/press-kit/build.py"], {"tools/press-kit/build.py": UPSTREAM_ID.encode()}))


class MixedAndUnknown(unittest.TestCase):
    def test_code_with_media_runs_full_ci(self):
        r = run(["press-kit/README.txt", "Shared/QUICReceiverSession.swift"])
        assert_full_ci(self, r)
        self.assertTrue(r["press_kit"])  # the press-kit job also runs

    def test_each_code_area_runs_full_ci(self):
        for path in [
            "Mac/AppDelegate.swift",
            "iOS/ContentView.swift",
            "MacReceiver/Info.plist",
            "Shared/Protocol.swift",
            "AndroidReceiver/app/src/main/kotlin/Main.kt",
            "AndroidReceiver/gradle/libs.versions.toml",
            "project.yml",
            "package.json",
            "pnpm-lock.yaml",
            "fastlane/Fastfile",
            "scripts/release/lib/release.rb",
            "scripts/ci/classify_pr_paths.py",
            ".xcode-version",
            "version.txt",
        ]:
            with self.subTest(path=path):
                assert_full_ci(self, run([path]))

    def test_unknown_paths_run_full_ci(self):
        assert_full_ci(self, run(["something-new/file.bin"]))
        assert_full_ci(self, run(["README.md", "LICENSE"]))

    def test_no_paths_runs_full_ci(self):
        self.assertEqual(run([]), {**FULL, "press_kit": False})


class Workflows(unittest.TestCase):
    def test_tests_workflow_runs_full_ci(self):
        assert_full_ci(self, run([".github/workflows/tests.yml"]))
        assert_full_ci(self, run([".github/workflows/tests.yml", "README.md"]))

    def test_other_workflows_run_full_ci(self):
        assert_full_ci(self, run([".github/workflows/release-mac.yml"]))
        assert_full_ci(self, run([".github/rulesets/dev.json"]))

    def test_pr_title_workflow_alone(self):
        r = run([".github/workflows/pr-title.yml"])
        self.assertTrue(r["workflow_only"])
        self.assertFalse(r["docs_media_only"])
        assert_full_ci(self, run([".github/workflows/pr-title.yml", "Mac/AppDelegate.swift"]))


class Gitignore(unittest.TestCase):
    SAFE = "--- a/.gitignore\n+++ b/.gitignore\n@@ -1,0 +2,4 @@\n+\n+# Generated press kit\n+press.html\n+press-kit/*.zip\n+/press-kit/Previews/\n"

    def test_safe_entries(self):
        self.assertTrue(run([".gitignore", "press-kit/README.txt"], gitignore_diff=self.SAFE)["docs_media_only"])

    def test_removing_safe_entry(self):
        diff = "@@ -3 +2,0 @@\n-docs/_build/\n"
        self.assertTrue(run([".gitignore"], gitignore_diff=diff)["docs_media_only"])

    def test_other_entries_run_full_ci(self):
        for line in ["+*.xcodeproj", "+Shared/Generated/", "-build/", "+press-kit-other", "+!press-kit/x"]:
            with self.subTest(line=line):
                assert_full_ci(self, run([".gitignore"], gitignore_diff=f"@@ -1 +1 @@\n{line}\n"))

    def test_missing_diff_runs_full_ci(self):
        assert_full_ci(self, run([".gitignore"]))


class CommandLine(unittest.TestCase):
    def test_writes_github_output(self):
        script = Path(__file__).resolve().parent / "classify_pr_paths.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "README.md").write_text("docs")
            (tmp / "paths").write_bytes(b"README.md\0press-kit/a b.png\0")
            (tmp / "gitignore.diff").write_text("")
            out = tmp / "out"
            subprocess.run([sys.executable, str(script), "paths", "gitignore.diff", str(out)],
                           cwd=tmp, check=True, capture_output=True, env={**os.environ})
            self.assertEqual(out.read_text(), "docs_media_only=true\nworkflow_only=false\npress_kit=true\n")


if __name__ == "__main__":
    unittest.main()
