#!/usr/bin/env bash
# Fails unless a new Mac CFBundleVersion is newer than every sparkle:version
# in the live feed. Sparkle only offers an update with a higher build number,
# so a release built with an unchanged build (1.20.0 shipped as build "1")
# would reach no installed copy.
# Usage: check-build-number.sh <new CFBundleVersion> <feed URL or file>
# Build numbers must be dot-separated integers; components compare
# numerically, and missing ones count as 0, so "1" and "1.0" are equal (and fail).
set -euo pipefail
new=${1:?usage: check-build-number.sh <new CFBundleVersion> <feed URL or file>}
feed=${2:?usage: check-build-number.sh <new CFBundleVersion> <feed URL or file>}

numeric='^[0-9]+(\.[0-9]+)*$'
if ! [[ $new =~ $numeric ]]; then
  echo "::error::Build number '$new' is not dot-separated integers"
  exit 1
fi

if [ -f "$feed" ]; then xml=$(cat "$feed"); else xml=$(curl -fsSL "$feed"); fi
published=$(printf '%s\n' "$xml" | sed -n 's:.*<sparkle\:version>\([^<]*\)</sparkle\:version>.*:\1:p')
if [ -z "$published" ]; then
  echo "::error::No sparkle:version found in $feed"
  exit 1
fi

# Prints -1, 0 or 1 for a < b, a = b, a > b.
compare() {
  local IFS=.
  local -a a=($1) b=($2)
  local i n=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
  for (( i = 0; i < n; i++ )); do
    local x=$(( 10#${a[i]:-0} )) y=$(( 10#${b[i]:-0} ))
    if (( x < y )); then echo -1; return; fi
    if (( x > y )); then echo 1; return; fi
  done
  echo 0
}

while read -r old; do
  if ! [[ $old =~ $numeric ]]; then
    echo "::error::Published build '$old' is not dot-separated integers; compare by hand"
    exit 1
  fi
  if [ "$(compare "$new" "$old")" != 1 ]; then
    echo "::error::Build $new is not newer than published build $old; Sparkle would not offer it"
    exit 1
  fi
done <<< "$published"
echo "Build $new is newer than published build(s): $(echo $published)"
