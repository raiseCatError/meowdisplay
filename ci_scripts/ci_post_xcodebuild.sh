#!/bin/zsh
# Xcode Cloud: after the UI tests run, put their screenshots in the build log as small named
# JPEGs. The result bundle keeps them, but reading it needs a download and Xcode; the log is plain
# text that review tooling can read from the artifacts page. docs/ci/xcode-cloud-duo.md
# describes the format. This never fails the build: a missing tool or bundle only logs a note.
set -uo pipefail

[[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]] || exit 0
bundle="${CI_RESULT_BUNDLE_PATH:-}"
if [[ -z "$bundle" || ! -d "$bundle" ]]; then
    echo "note: no result bundle, no screenshots"
    exit 0
fi

out="${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/meow-shots"
rm -rf "$out" && mkdir -p "$out"
if ! xcrun xcresulttool export attachments --path "$bundle" --output-path "$out" >/dev/null; then
    echo "note: xcresulttool could not export attachments"
    exit 0
fi

xcrun python3 - "$out" <<'PY' || echo "note: screenshot log failed"
import base64, json, os, subprocess, sys

out = sys.argv[1]
small = os.path.join(out, "small.jpg")
with open(os.path.join(out, "manifest.json")) as f:
    manifest = json.load(f)
count = 0
for test in manifest:
    name_of_test = test.get("testIdentifier", "?")
    for item in test.get("attachments", []):
        file = item.get("exportedFileName", "")
        if not file.lower().endswith((".png", ".jpg", ".jpeg")):
            continue
        name = item.get("suggestedHumanReadableName", file).replace("\t", " ")
        # About 560 points on the long side at medium quality: enough to judge layout, ~30 kB each.
        result = subprocess.run(["sips", "-Z", "560", "-s", "format", "jpeg", "-s", "formatOptions", "60",
                                 os.path.join(out, file), "--out", small], capture_output=True)
        if result.returncode != 0:
            continue
        with open(small, "rb") as f:
            data = base64.b64encode(f.read()).decode()
        count += 1
        # Short lines, so no log viewer wraps or truncates them.
        parts = [data[i:i + 4000] for i in range(0, len(data), 4000)]
        print(f"MEOWSHOT-BEGIN\t{count}\t{name_of_test}\t{name}\t{len(parts)}")
        for part in parts:
            print(f"MEOWSHOT-DATA\t{count}\t{part}")
print(f"MEOWSHOT-COUNT\t{count}")
PY
exit 0
