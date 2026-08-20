#!/usr/bin/env bash
#
# verify_appcast_published.sh -- prove a cut's release actually REACHED the
# auto-update feed, by asking the feed the same question the customer's Hub
# asks it.
#
# WHY THIS EXISTS
#
# `ostler-release publish` exiting 0 is a statement about a subprocess. It is
# not evidence that the feed changed. Nothing in this estate has ever asked
# the feed, and the result is the worst available shape:
#
#     MEASURED 2026-08-19, the live production feed:
#       curl 'https://appcast.ostler.ai/appcast.xml?current_version=1.0.0'
#       -> HTTP 200, valid Sparkle RSS, <channel> present, ZERO <item>
#
# Valid-and-empty. Every installed Hub polls, is correctly told there is
# nothing newer, and can never upgrade. No error, no log line, nothing red,
# on any surface, for 36 cuts. A bug that ships is permanent for whoever
# installed it, because the road back to them was never verified.
#
# This is the instrument-and-defect-on-different-surfaces shape: the publish
# step watched a PROCESS, and the defect lives in a FEED. A guard watching
# the wrong object is green forever and never self-corrects.
#
# WHAT IT ASKS
#
# The feed filters to releases NEWER than `current_version`, so the probe asks
# with 0.0.0 to obtain every item, then requires an EXACT match on
# sparkle:shortVersionString (and sparkle:version when --build is given).
#
# Field names are taken from the generator, not from Sparkle's documentation:
#   CM050 appcast-server/src/appcast.ts:345  <sparkle:version>          = build
#   CM050 appcast-server/src/appcast.ts:346  <sparkle:shortVersionString> = version
#
# THE PARSER CANARY IS NOT OPTIONAL. "0 items found" is produced both by an
# empty feed and by a parser that has stopped matching. Those are different
# facts and they must not share an exit code, so every run first parses a
# built-in known-good fixture and REFUSES to report on the live feed unless
# the parser recovers the fixture's item. A zero whose shape has not been
# checked is not a measurement.
#
# EXIT CODES
#   0  the version is present in the feed
#   1  the feed answered and the version is NOT there  (the real finding)
#   2  CANNOT-RUN -- unreachable, malformed, or the parser canary failed
#
# 1 and 2 are deliberately distinct. "the release did not publish" and "I
# could not tell" are different facts, and collapsing them is how a dead
# network gets recorded as a clean bill of health.
set -uo pipefail

FEED_DEFAULT="https://appcast.ostler.ai/appcast.xml"
VERSION=""
BUILD=""
FEED="${OSTLER_APPCAST_FEED:-$FEED_DEFAULT}"
PROBE_VERSION="0.0.0"
FIXTURE=""

usage() {
    cat >&2 <<'USAGE'
usage: verify_appcast_published.sh --version X.Y.Z [--build N] [--feed URL]

  --version   the sparkle:shortVersionString this cut published (required)
  --build     the sparkle:version (CFBundleVersion) to require as well
  --feed      appcast URL (default https://appcast.ostler.ai/appcast.xml,
              or $OSTLER_APPCAST_FEED)
  --fixture   read a local XML file instead of the network (self-test only)

exit: 0 published | 1 absent from the feed | 2 cannot-run
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --build)   BUILD="${2:-}";   shift 2 ;;
        --feed)    FEED="${2:-}";    shift 2 ;;
        --fixture) FIXTURE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify-appcast: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "verify-appcast: CANNOT RUN -- --version is required." >&2
    usage
    exit 2
fi

# ---------------------------------------------------------------------------
# The parser. One function, used for BOTH the canary and the live feed, so the
# canary tests the thing that actually runs. A canary exercising a different
# code path proves nothing about the path that matters.
#
# `tr` first: the generator emits one element per line today, but an XML
# producer is allowed to reflow whitespace at any time, and a parser that
# silently depends on the current line breaks is a gate that goes dark on a
# formatting change. Normalising to one tag per line makes that irrelevant.
# ---------------------------------------------------------------------------
extract_field() {
    # $1 = xml text, $2 = local element name (without the sparkle: prefix)
    printf '%s' "$1" \
        | tr '>' '>\n' \
        | grep -o "<sparkle:$2[^<]*" \
        | sed "s/^<sparkle:$2>*//" \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$' || true
}

# ---------------------------------------------------------------------------
# CANARY. A fixture with exactly one item, parsed by the SAME function, before
# any verdict about the live feed is permitted.
# ---------------------------------------------------------------------------
CANARY_XML='<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>canary</title>
    <item>
      <sparkle:version>9999</sparkle:version>
      <sparkle:shortVersionString>99.99.99</sparkle:shortVersionString>
    </item>
  </channel>
</rss>'

canary_versions="$(extract_field "$CANARY_XML" "shortVersionString")"
if ! printf '%s\n' "$canary_versions" | grep -Fxq "99.99.99"; then
    echo "verify-appcast: CANNOT RUN -- the parser canary failed." >&2
    echo "  A known-good one-item fixture did not yield its version, so this" >&2
    echo "  script can no longer read an appcast. Any 'not published' verdict" >&2
    echo "  from here would be a parser bug wearing a finding's clothes." >&2
    exit 2
fi
canary_builds="$(extract_field "$CANARY_XML" "version")"
if ! printf '%s\n' "$canary_builds" | grep -Fxq "9999"; then
    echo "verify-appcast: CANNOT RUN -- the parser canary failed on sparkle:version." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Fetch.
# ---------------------------------------------------------------------------
if [ -n "$FIXTURE" ]; then
    if [ ! -f "$FIXTURE" ]; then
        echo "verify-appcast: CANNOT RUN -- fixture not found: $FIXTURE" >&2
        exit 2
    fi
    XML="$(cat "$FIXTURE")"
    SOURCE="fixture $FIXTURE"
else
    SEP="?"; case "$FEED" in *\?*) SEP="&" ;; esac
    URL="${FEED}${SEP}current_version=${PROBE_VERSION}"
    if ! XML="$(curl -fsSL --max-time 30 --retry 2 "$URL" 2>/dev/null)"; then
        echo "verify-appcast: CANNOT RUN -- the feed did not answer." >&2
        echo "  URL: $URL" >&2
        echo "  This is NOT 'the release is unpublished'. It is 'I could not" >&2
        echo "  tell', and the two must not share an exit code." >&2
        exit 2
    fi
    SOURCE="$URL"
fi

if [ -z "${XML//[[:space:]]/}" ]; then
    echo "verify-appcast: CANNOT RUN -- the feed returned an empty body." >&2
    echo "  Source: $SOURCE" >&2
    exit 2
fi

# A feed that is not even an RSS document is a broken endpoint, not an empty
# one. Distinguishing them matters: the first is an outage, the second is the
# defect this gate exists to catch.
if ! printf '%s' "$XML" | grep -q "<rss"; then
    echo "verify-appcast: CANNOT RUN -- the response is not an RSS document." >&2
    echo "  Source: $SOURCE" >&2
    echo "  First 200 bytes: $(printf '%s' "$XML" | head -c 200)" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# The verdict.
# ---------------------------------------------------------------------------
versions="$(extract_field "$XML" "shortVersionString")"
item_count="$(printf '%s' "$XML" | grep -c "<item>" || true)"

echo "verify-appcast: source   $SOURCE"
echo "verify-appcast: items    $item_count"
echo "verify-appcast: versions $(printf '%s' "$versions" | tr '\n' ' ')"

if [ "$item_count" -eq 0 ]; then
    echo "" >&2
    echo "verify-appcast: NOT PUBLISHED -- the feed is VALID AND EMPTY." >&2
    echo "  Expected version $VERSION to be listed; the feed carries no items" >&2
    echo "  at all. Every installed Hub polling this feed is being correctly" >&2
    echo "  told there is nothing newer, and can never upgrade." >&2
    echo "  The publish step reported success and the feed did not change." >&2
    exit 1
fi

# Exact match, never a substring: 1.0.3 must not be satisfied by 1.0.36.
if ! printf '%s\n' "$versions" | grep -Fxq "$VERSION"; then
    echo "" >&2
    echo "verify-appcast: NOT PUBLISHED -- version $VERSION is absent." >&2
    echo "  The feed lists $item_count item(s), so the endpoint works and other" >&2
    echo "  releases are reachable -- THIS release is the one that did not land." >&2
    echo "  Present: $(printf '%s' "$versions" | tr '\n' ' ')" >&2
    exit 1
fi

if [ -n "$BUILD" ]; then
    builds="$(extract_field "$XML" "version")"
    if ! printf '%s\n' "$builds" | grep -Fxq "$BUILD"; then
        echo "" >&2
        echo "verify-appcast: NOT PUBLISHED CORRECTLY -- version $VERSION is" >&2
        echo "  present but build $BUILD is not. Sparkle compares on" >&2
        echo "  sparkle:version, so a wrong build is an entry that silently" >&2
        echo "  reaches nobody -- the same invisible failure as no entry." >&2
        echo "  Present builds: $(printf '%s' "$builds" | tr '\n' ' ')" >&2
        exit 1
    fi
fi

echo "verify-appcast: OK -- version $VERSION${BUILD:+ (build $BUILD)} is live on the feed."
exit 0
