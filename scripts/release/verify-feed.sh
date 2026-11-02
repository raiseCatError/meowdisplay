#!/usr/bin/env bash
# Verifies a signed Sparkle feed and its DMG before anything is published,
# the way Sparkle 2.10.0 does (SPUExtractSignedFeed.m, SUAppcastDriver.m):
#  - feed: the bytes before the LAST "<!-- sparkle-signatures:\n" block are
#    signed, and the block's "length:" must equal their count;
#  - DMG: sparkle:edSignature over the whole file; enclosure length == size;
# both against <public key> (pass the PUBLISHED key, published-baseline.sh),
# with CryptoKit. Also: exactly one item, the planned version and build, the
# exact enclosure URL, every URL https, and no channel, phased-rollout,
# critical, informational or minimum-version attributes that would change who
# is offered the update. Needs no secrets; macOS (swift, python3).
# Usage: verify-feed.sh <feed> <dmg> <public key> <version> <build> <enclosure URL>
set -euo pipefail
feed=${1:?usage: verify-feed.sh <feed> <dmg> <public key> <version> <build> <enclosure URL>}
dmg=${2:?}; key=${3:?}; version=${4:?}; build=${5:?}; url=${6:?}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$feed" "$dmg" "$version" "$build" "$url" "$work" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, dmg, version, build, url, work = sys.argv[1:7]
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
data = open(feed, "rb").read()
problems = []
start = data.rfind(b"<!-- sparkle-signatures:\n")
if start < 0:
    sys.exit("::error::%s has no sparkle-signatures block (unsigned feed)" % feed)
block = data[start:].decode()
fields = dict(line.split(":", 1) for line in block.splitlines()[1:] if ":" in line)
signature = fields.get("edSignature", "").strip()
length = fields.get("length", "").strip()
if length != str(start):
    problems.append("signed length %r != bytes before the signing block (%d)" % (length, start))
open(os.path.join(work, "feed.signed"), "wb").write(data[:start])
open(os.path.join(work, "feed.sig"), "w").write(signature)
root = ET.fromstring(data[:start])
items = root.findall("./channel/item")
if len(items) != 1:
    sys.exit("::error::expected exactly one item, found %d" % len(items))
item = items[0]
got = (item.findtext(SP + "shortVersionString"), item.findtext(SP + "version"))
print("item: %s (%s)" % got)
if got != (version, build):
    problems.append("item is %s (%s), expected %s (%s)" % (got + (version, build)))
enc = item.find("enclosure")
if enc is None:
    sys.exit("::error::no enclosure")
print("enclosure: %s length=%s" % (enc.get("url"), enc.get("length")))
if enc.get("url") != url:
    problems.append("enclosure URL is %s, expected %s" % (enc.get("url"), url))
if enc.get("length") != str(os.path.getsize(dmg)):
    problems.append("enclosure length != DMG size %d" % os.path.getsize(dmg))
dmg_signature = enc.get(SP + "edSignature") or ""
if not dmg_signature:
    problems.append("the enclosure has no sparkle:edSignature (generate_appcast did not sign the DMG)")
open(os.path.join(work, "dmg.sig"), "w").write(dmg_signature)
for tag in ("channel", "phasedRolloutInterval", "criticalUpdate", "informationalUpdate",
            "minimumAutoupdateVersion", "minimumUpdateVersion", "maximumSystemVersion"):
    if item.find(SP + tag) is not None:
        problems.append("unexpected sparkle:%s" % tag)
for el in root.iter():
    for value in list(el.attrib.values()) + [el.text or ""]:
        if "://" in value and not value.strip().startswith("https://"):
            problems.append("non-https URL: %s" % value.strip())
for p in problems:
    print("::error::" + p)
sys.exit(1 if problems else 0)
PY

swift "$here/verify-ed25519.swift" "$key" "$work/feed.signed" "$(cat "$work/feed.sig")" ||
  { echo "::error::feed signature does not verify against $key"; exit 1; }
echo "ok   feed signature verifies against $key"
swift "$here/verify-ed25519.swift" "$key" "$dmg" "$(cat "$work/dmg.sig")" ||
  { echo "::error::DMG signature does not verify against $key"; exit 1; }
echo "ok   DMG signature verifies against $key"
echo "verify-feed: PASS ($(basename "$feed"))"
