#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch_daemon_buildinfo.sh -- carry the daemon's COMMIT across the DMG boundary.
#
# WHY THIS EXISTS
# ---------------
# Measured on Andy's Mini 2026-08-13: the installed daemon carries no commit
# identifier at all. No build-info.json in the bundle, none under ~/.ostler,
# and Info.plist + --version both report 0.4.1 for a binary built 2026-08-10.
# There is no way, on a customer box, to say which daemon is installed.
#
# That is the shared root under three defect rows that were each investigated
# separately: v1018-D038 (fix not running), D011 (needs a recompile), D014c
# (merged in CM051, absent from the installed cm048). Every one of them stalls
# at the same stage, and none of them can be settled without this file.
#
# check_daemon_recency() in verify_cut_freshness.sh already reads the commit
# from build-info.json -- as a RELEASE ASSET, over the API. The cut downloads
# the daemon tarball from that same release and walks straight past its
# sibling, so provenance stops dead at the release boundary.
#
# This script fetches the sibling and hands it to stage-daemon, which copies it
# into ../assistant-agent/ -> Contents/Resources/assistant-agent/ in the DMG.
# install.sh already reads the daemon from that directory, so the install side
# needs no new path knowledge.
#
# FAIL CLOSED, WITH A NAMED ESCAPE
# --------------------------------
# A missing sibling is a hard failure. Releases older than build-info.json are
# blocked, deliberately: they are exactly the ones that produce an anonymous
# install. The escape is a row in the waiver file -- a loud decision with a tag
# and a reason on it, matching the hold_ack pattern the vendor trees, wiki
# images and daemon recency already use.
#
# It is NOT a silent WARN. A warn bucket here reproduces the precise defect this
# script exists to fix, and "the gate was noisy so we softened it" is how the
# previous daemon-recency check died at v1.0.16.
#
# Exit codes are distinct on purpose:
#   0  build-info.json written to DEST (or a waiver applied and recorded)
#   1  no build-info.json on the release and no waiver -- cut must not proceed
#   2  could not run (bad args, no acquisition method available)
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIVER_FILE="${DAEMON_BUILDINFO_WAIVER_FILE:-$SCRIPT_DIR/daemon_buildinfo_waiver.tsv}"

usage() {
    echo "usage: $0 <release-tag> <repo> <dest-path>" >&2
    echo "  e.g. $0 hub-v0.4.55 ostler-ai/ostler-releases ../assistant-agent/build-info.json" >&2
}

TAG="${1:-}"
REPO="${2:-}"
DEST="${3:-}"

if [ -z "$TAG" ] || [ -z "$REPO" ] || [ -z "$DEST" ]; then
    usage
    exit 2
fi

say() { printf '[buildinfo] %s\n' "$*"; }
die_cannot_run() { printf '[buildinfo] CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR" 2>/dev/null || die_cannot_run "cannot create $DEST_DIR"

# --- acquisition -----------------------------------------------------------
# Three paths, mirroring download-daemon exactly. All three must be covered or
# the record is present or absent depending on which path a given cut happened
# to take, which is worse than absent everywhere.
TMP="$(mktemp -d 2>/dev/null)" || die_cannot_run "mktemp failed"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

FETCHED=""
METHOD=""

# Path 3 first: a pre-staged local cache is authoritative and needs no network.
LOCAL_CACHE_DIR="${DAEMON_LOCAL_CACHE_DIR:-$HOME/.ostler-release-artefacts}"
LOCAL_CANDIDATE="$LOCAL_CACHE_DIR/${TAG}-build-info.json"
if [ ! -f "$LOCAL_CANDIDATE" ]; then
    # A pre-staged cache holds the asset under its REAL published name,
    # ostler-assistant-<target>-v<ver>.build-info.json, not our tag-prefixed
    # convention. Measured on hub-v0.4.55 2026-08-13. Accept both.
    LOCAL_CANDIDATE="$(ls "$LOCAL_CACHE_DIR"/*build-info.json 2>/dev/null | head -1)"
fi
if [ -n "$LOCAL_CANDIDATE" ] && [ -f "$LOCAL_CANDIDATE" ]; then
    cp "$LOCAL_CANDIDATE" "$TMP/build-info.json" 2>/dev/null && {
        FETCHED="$TMP/build-info.json"; METHOD="local-cache"
    }
fi

# Path 1: gh CLI, when it is present AND authenticated.
if [ -z "$FETCHED" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh release download "$TAG" --repo "$REPO" --pattern "*build-info.json" \
            --dir "$TMP" --clobber >/dev/null 2>&1; then
        # gh writes the asset under its OWN name, which is
        # ostler-assistant-<target>-v<ver>.build-info.json, NOT build-info.json.
        GH_HIT="$(ls "$TMP"/*build-info.json 2>/dev/null | head -1)"
        [ -n "$GH_HIT" ] && { FETCHED="$GH_HIT"; METHOD="gh"; }
    fi
fi

# Path 2: curl + GH_TOKEN, resolving the asset id through the releases API.
if [ -z "$FETCHED" ] && [ -n "${GH_TOKEN:-}" ]; then
    API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
    ASSET_ID="$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" "$API" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in d.get("assets", []):
    if str(a.get("name", "")).endswith("build-info.json"):
        print(a["id"]); break' 2>/dev/null)"
    if [ -n "$ASSET_ID" ]; then
        if curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
                -H "Accept: application/octet-stream" \
                "https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}" \
                -o "$TMP/build-info.json" 2>/dev/null && [ -s "$TMP/build-info.json" ]; then
            FETCHED="$TMP/build-info.json"; METHOD="curl"
        fi
    fi
fi

if [ -z "$FETCHED" ] && ! command -v gh >/dev/null 2>&1 && [ -z "${GH_TOKEN:-}" ]; then
    # No way to reach the release at all. This is a cannot-run, NOT a verdict
    # that the asset is absent -- the distinction matters, because reporting
    # "absent" here would license a waiver for a release that has the file.
    die_cannot_run "no acquisition method: gh absent and GH_TOKEN unset"
fi

# --- verdict ---------------------------------------------------------------
if [ -n "$FETCHED" ]; then
    # Assert it actually carries a commit before declaring success. A file that
    # parses but has no commit is the same anonymous install with extra steps.
    COMMIT="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in ("commit_sha", "commit", "sha", "git_commit"):
    v = d.get(k)
    if v:
        print(v); break' "$FETCHED" 2>/dev/null)"
    if [ -z "$COMMIT" ]; then
        echo "[buildinfo] FAIL: ${TAG} build-info.json carries no commit field." >&2
        echo "            Looked for commit_sha / commit / sha / git_commit." >&2
        echo "            A record without a commit cannot identify an install." >&2
        exit 1
    fi
    cp "$FETCHED" "$DEST" || die_cannot_run "cannot write $DEST"
    say "OK ${TAG} commit=${COMMIT} via ${METHOD} -> ${DEST}"
    exit 0
fi

# --- absent: waiver or fail closed ----------------------------------------
if [ -f "$WAIVER_FILE" ]; then
    WROW="$(grep -v '^[[:space:]]*#' "$WAIVER_FILE" 2>/dev/null | awk -F'\t' -v t="$TAG" '$1 == t {print; exit}')"
    if [ -n "$WROW" ]; then
        WREASON="$(printf '%s' "$WROW" | awk -F'\t' '{print $2}')"
        if [ -z "$WREASON" ]; then
            echo "[buildinfo] FAIL: waiver row for ${TAG} has an EMPTY reason." >&2
            echo "            Record WHY this tag ships without provenance." >&2
            exit 1
        fi
        say "WAIVED ${TAG}: ${WREASON}"
        say "       no provenance record will exist for installs from this tag."
        exit 0
    fi
fi

echo "[buildinfo] FAIL: no build-info.json asset on ${REPO} ${TAG}." >&2
echo "            The cut is refusing, on purpose. Without this file the" >&2
echo "            installed daemon is anonymous: no commit, and the version" >&2
echo "            string is known-unreliable (task #254, box reports 0.4.1" >&2
echo "            for a 2026-08-10 build)." >&2
echo "            Either publish build-info.json on that release, or add a" >&2
echo "            row to ${WAIVER_FILE}:" >&2
echo "              <tag><TAB><reason>" >&2
exit 1
