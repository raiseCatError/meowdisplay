#!/usr/bin/env bash
# Reports which of the named environment variables (the workflow maps
# secrets and variables into them) are empty, by NAME only: no value is ever
# printed. Writes `missing=<names>` to GITHUB_OUTPUT when available.
# Usage: report-missing.sh [--fail] NAME...   (--fail: exit 1 if any is missing)
set -euo pipefail
fail_on_missing=false
if [ "${1:-}" = --fail ]; then fail_on_missing=true; shift; fi
missing=()
for name in "$@"; do
  [[ $name =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "::error::bad variable name '$name'"; exit 1; }
  if [ -z "${!name:-}" ]; then
    echo "::warning::$name is not set"
    missing+=("$name")
  fi
done
[ -z "${GITHUB_OUTPUT:-}" ] || echo "missing=${missing[*]:-}" >> "$GITHUB_OUTPUT"
if [ ${#missing[@]} -eq 0 ]; then
  echo "all set: $*"
elif $fail_on_missing; then
  echo "::error::missing: ${missing[*]}"
  exit 1
fi
