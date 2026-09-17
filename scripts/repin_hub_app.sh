#!/usr/bin/env bash
# scripts/repin_hub_app.sh <new-daemon-version>   e.g. 0.4.81
# ============================================================================
# MOVE THE DAEMON PIN AS ONE OPERATION, OR REFUSE.
#
# WHY THIS EXISTS. v1.0.80 was tagged and built NOTHING, and the ledger row
# names two causes that are both this file's job:
#
#   1. `gui/Makefile:428` HUB_APP_SHA256 still held the PREVIOUS version's
#      digest, because the bump moved DAEMON_VERSION and left the digest
#      behind. download-hub-app verifies fail-closed, so publishing the new
#      hub app only moves the failure from the FETCH to the CHECKSUM.
#   2. DAEMON_RELEASE_TAG names a release in TWO repos -- DAEMON_REPO
#      (ostler-releases) and HUB_APP_REPO (ostler-assistant) -- and only one
#      of them had been published. "Publish hub-v0.4.76" was ambiguous between
#      them and was resolved one way only.
#
# The sweep that missed cause 1 searched for the outgoing SHA and the outgoing
# VERSION. A digest does not contain its version, so it was outside that search
# BY CONSTRUCTION. That is why this is a script and not a checklist item.
#
# 🔴 A DAEMON RE-PIN IS SIX VALUES IN TWO FILES, NOT ONE. Measured 2026-09-17,
# and the first version of this script moved only the first two:
#
#   gui/Makefile  DAEMON_VERSION                      0.4.80
#   gui/Makefile  DAEMON_SHA256                       <daemon tarball digest>
#   gui/Makefile  HUB_APP_SHA256                      <hub app digest>
#   install.sh    OSTLER_ASSISTANT_VERSION            0.4.80
#   install.sh    DEFAULT_ASSISTANT_TARBALL_SHA256    <daemon tarball digest>
#   install.sh    OSTLER_KNOWLEDGE_READER_VERSION     0.4.80
#
# THE TWO DIGESTS ARE DIFFERENT ARTEFACTS and mixing them is silent: the daemon
# tarball and the hub app tarball are separate downloads with separate hashes.
# install.sh's comment at the reader-version line states the coupling in its own
# words: it "MUST equal the default of OSTLER_ASSISTANT_VERSION ... that coupling
# is the whole anti-rot mechanism".
#
# tests/test_daemon_pins_agree.sh enforces the version and the daemon digest
# across both files, so a partial bump is caught -- but being caught at cut time
# is what spending a version number looks like. This script does all six.
#
# WHAT IT DOES, in this order, refusing at the first failure:
#   - both releases exist, are NOT drafts, and carry the expected asset
#   - the hub-app tarball is DOWNLOADED and its sha256 COMPUTED from bytes,
#     never copied from a release note or a build log
#   - DAEMON_VERSION and HUB_APP_SHA256 are written TOGETHER
#   - the result is read back and both values re-asserted
#
# It writes nothing until every check has passed, so a refusal leaves the tree
# exactly as it found it.
#
# NO PIPE INTO grep -q ANYWHERE: that construct SIGPIPEs its producer and under
# `set -o pipefail` reports failure for a pattern it found. Counted form only.
# ============================================================================
set -Eeuo pipefail

NEW="${1:-}"
[ -n "$NEW" ] || { echo "usage: $0 <new-daemon-version>   e.g. 0.4.81" >&2; exit 2; }
case "$NEW" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "ERROR: '$NEW' is not a bare version like 0.4.81 (no leading v)." >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MK="$REPO/gui/Makefile"
[ -f "$MK" ] || { echo "ERROR: $MK not found." >&2; exit 2; }

mkvar() { sed -n "s/^$1  *?*:*= *//p" "$MK" | head -1 | tr -d ' '; }
OLD="$(mkvar DAEMON_VERSION)"
OLD_SHA="$(mkvar HUB_APP_SHA256)"
OLD_DSHA="$(mkvar DAEMON_SHA256)"
INSTALL="$REPO/install.sh"
[ -f "$INSTALL" ] || { echo "ERROR: $INSTALL not found." >&2; exit 2; }
shvar() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$INSTALL" | head -1; }
OLD_IVER="$(sed -n 's/^OSTLER_ASSISTANT_VERSION="\${OSTLER_ASSISTANT_VERSION:-\([^}]*\)}"$/\1/p' "$INSTALL" | head -1)"
OLD_IDSHA="$(shvar DEFAULT_ASSISTANT_TARBALL_SHA256)"
OLD_KVER="$(shvar OSTLER_KNOWLEDGE_READER_VERSION)"
[ -n "$OLD_DSHA" ] && [ -n "$OLD_IVER" ] && [ -n "$OLD_IDSHA" ] && [ -n "$OLD_KVER" ] || {
    echo "ERROR: could not read all six pins. Nothing written." >&2
    echo "  DAEMON_SHA256='${OLD_DSHA:0:12}' install-ver='$OLD_IVER' install-sha='${OLD_IDSHA:0:12}' reader-ver='$OLD_KVER'" >&2
    exit 2; }
# The two files must AGREE before a re-pin, or this is not a re-pin, it is a
# repair of a drift nobody has adjudicated.
[ "$OLD_IVER" = "$OLD" ] || { echo "ERROR: install.sh says $OLD_IVER, gui/Makefile says $OLD. They already disagree; fix that first. Nothing written." >&2; exit 1; }
[ "$OLD_KVER" = "$OLD" ] || { echo "ERROR: OSTLER_KNOWLEDGE_READER_VERSION is $OLD_KVER, not $OLD, and install.sh says it MUST equal the assistant version. Nothing written." >&2; exit 1; }
[ "$OLD_IDSHA" = "$OLD_DSHA" ] || { echo "ERROR: the daemon digest already differs between the two files. Nothing written." >&2; exit 1; }
DAEMON_REPO="$(mkvar DAEMON_REPO)"
HUB_APP_REPO="$(mkvar HUB_APP_REPO)"
TARGET="$(mkvar DAEMON_TARGET)"
[ -n "$OLD" ] && [ -n "$OLD_SHA" ] && [ -n "$DAEMON_REPO" ] && [ -n "$HUB_APP_REPO" ] || {
    echo "ERROR: could not read the current pins out of gui/Makefile." >&2
    echo "  DAEMON_VERSION='$OLD' HUB_APP_SHA256='${OLD_SHA:0:12}' DAEMON_REPO='$DAEMON_REPO' HUB_APP_REPO='$HUB_APP_REPO'" >&2
    exit 2; }
[ -n "$TARGET" ] || TARGET="aarch64-apple-darwin"

if [ "$NEW" = "$OLD" ]; then
    echo "[repin] DAEMON_VERSION is already ${NEW}. Nothing to do, nothing written."
    exit 0
fi

TAG="hub-v${NEW}"
HUB_ASSET="ostler-hub-app-${TARGET}-v${NEW}.tar.gz"
DAEMON_ASSET="ostler-assistant-${TARGET}-v${NEW}.tar.gz"

echo "[repin] ${OLD} -> ${NEW}   tag=${TAG}"
echo "[repin] hub asset:    ${HUB_ASSET}   in ${HUB_APP_REPO}"
echo "[repin] daemon asset: ${DAEMON_ASSET} in ${DAEMON_REPO}"

# ── BOTH REPOS. This is cause 2, and it is checked before anything is written.
for spec in "${HUB_APP_REPO}|${HUB_ASSET}" "${DAEMON_REPO}|${DAEMON_ASSET}"; do
    r="${spec%%|*}"; a="${spec##*|}"
    meta="$(gh release view "$TAG" --repo "$r" --json isDraft,assets 2>/dev/null || true)"
    if [ -z "$meta" ]; then
        echo "ERROR: ${r} has no release ${TAG}. DAEMON_RELEASE_TAG names a release in BOTH" >&2
        echo "       repos and publishing one is not publishing the other. That ambiguity" >&2
        echo "       spent v1.0.80. Nothing written." >&2
        exit 1
    fi
    draft="$(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin)["isDraft"])')"
    if [ "$draft" != "False" ]; then
        echo "ERROR: ${r} ${TAG} is a DRAFT. A draft 404s to the read token the build uses," >&2
        echo "       which reads as 'does not exist'. Publish it first. Nothing written." >&2
        exit 1
    fi
    n="$(printf '%s' "$meta" | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin)["assets"] if x["name"]=="'"$a"'"))')"
    if [ "$n" -lt 1 ]; then
        echo "ERROR: ${r} ${TAG} exists but carries no asset named ${a}." >&2
        echo "       A release without its asset is a fetch failure at build time. Nothing written." >&2
        exit 1
    fi
    echo "  [ok] ${r} ${TAG} is published and carries ${a}"
done

# ── THE DIGEST IS COMPUTED FROM BYTES. This is cause 1. Never transcribed.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gh release download "$TAG" --repo "$HUB_APP_REPO" --pattern "$HUB_ASSET" --dir "$TMP" --clobber >/dev/null 2>&1 || {
    echo "ERROR: could not download ${HUB_ASSET} from ${HUB_APP_REPO} ${TAG}." >&2
    echo "       Cross-org reads may need OSTLER_RELEASES_TOKEN. Nothing written." >&2
    exit 1; }
NEW_SHA="$(shasum -a 256 "$TMP/$HUB_ASSET" | cut -d' ' -f1)"
[ "${#NEW_SHA}" -eq 64 ] || { echo "ERROR: computed digest is not 64 hex chars. Nothing written." >&2; exit 1; }
echo "  [ok] hub-app sha256 computed from ${HUB_ASSET} bytes"

# THE DAEMON TARBALL IS A DIFFERENT ARTEFACT WITH A DIFFERENT DIGEST, and it
# lives in a different repo. Mixing the two is silent: both are 64 hex chars.
gh release download "$TAG" --repo "$DAEMON_REPO" --pattern "$DAEMON_ASSET" --dir "$TMP" --clobber >/dev/null 2>&1 || {
    echo "ERROR: could not download ${DAEMON_ASSET} from ${DAEMON_REPO} ${TAG}. Nothing written." >&2; exit 1; }
NEW_DSHA="$(shasum -a 256 "$TMP/$DAEMON_ASSET" | cut -d' ' -f1)"
[ "${#NEW_DSHA}" -eq 64 ] || { echo "ERROR: daemon digest is not 64 hex chars. Nothing written." >&2; exit 1; }
[ "$NEW_DSHA" != "$NEW_SHA" ] || { echo "ERROR: the daemon and hub-app digests are IDENTICAL, which means the same file was downloaded twice. Nothing written." >&2; exit 1; }
echo "  [ok] daemon sha256 computed from ${DAEMON_ASSET} bytes, and it differs from the hub-app digest"

if [ "$NEW_SHA" = "$OLD_SHA" ] && [ "$NEW" != "$OLD" ]; then
    echo "ERROR: the new version's asset has the SAME digest as the old pin." >&2
    echo "       Either the release was rebuilt from identical inputs, or the wrong" >&2
    echo "       asset was downloaded. Refusing rather than writing a pin that cannot" >&2
    echo "       have been verified. Nothing written." >&2
    exit 1
fi

# ── WRITE BOTH, OR NEITHER ─────────────────────────────────────────────────
python3 - "$MK" "$INSTALL" "$OLD" "$NEW" "$OLD_SHA" "$NEW_SHA" "$OLD_DSHA" "$NEW_DSHA" <<'PY'
import io, re, sys
mk, ins, old, new, olds, news, oldd, newd = sys.argv[1:9]

def sub1(text, pat, rep, label, counts):
    out, n = re.subn(pat, rep, text)
    counts.append((label, n))
    return out

counts = []
m = io.open(mk, encoding="utf-8").read()
m = sub1(m, r'(?m)^(DAEMON_VERSION[ \t]+\??=[ \t]*)%s[ \t]*$' % re.escape(old), r'\g<1>%s' % new, "Makefile DAEMON_VERSION", counts)
m = sub1(m, r'(?m)^(HUB_APP_SHA256[ \t]+\??=[ \t]*)%s[ \t]*$' % re.escape(olds), r'\g<1>%s' % news, "Makefile HUB_APP_SHA256", counts)
m = sub1(m, r'(?m)^(DAEMON_SHA256[ \t]+\??=[ \t]*)%s[ \t]*$' % re.escape(oldd), r'\g<1>%s' % newd, "Makefile DAEMON_SHA256", counts)

i = io.open(ins, encoding="utf-8").read()
i = sub1(i, r'(?m)^(OSTLER_ASSISTANT_VERSION="\$\{OSTLER_ASSISTANT_VERSION:-)%s(\}")$' % re.escape(old), r'\g<1>%s\g<2>' % new, "install.sh OSTLER_ASSISTANT_VERSION", counts)
i = sub1(i, r'(?m)^(DEFAULT_ASSISTANT_TARBALL_SHA256=")%s(")$' % re.escape(oldd), r'\g<1>%s\g<2>' % newd, "install.sh DEFAULT_ASSISTANT_TARBALL_SHA256", counts)
i = sub1(i, r'(?m)^(OSTLER_KNOWLEDGE_READER_VERSION=")%s(")$' % re.escape(old), r'\g<1>%s\g<2>' % new, "install.sh OSTLER_KNOWLEDGE_READER_VERSION", counts)

bad = [(l, n) for l, n in counts if n != 1]
if bad:
    sys.stderr.write("ERROR: each pin must match EXACTLY ONCE. These did not, and nothing was written:\n")
    for l, n in bad:
        sys.stderr.write("    %-46s matched %d\n" % (l, n))
    sys.exit(1)
io.open(mk, "w", encoding="utf-8").write(m)
io.open(ins, "w", encoding="utf-8").write(i)
PY

# ── READ BACK. A write that is not re-read is a claim, not a change. ────────
GOT_V="$(mkvar DAEMON_VERSION)"
GOT_S="$(mkvar HUB_APP_SHA256)"
GOT_D="$(mkvar DAEMON_SHA256)"
GOT_IV="$(sed -n 's/^OSTLER_ASSISTANT_VERSION="\${OSTLER_ASSISTANT_VERSION:-\([^}]*\)}"$/\1/p' "$INSTALL" | head -1)"
GOT_ID="$(shvar DEFAULT_ASSISTANT_TARBALL_SHA256)"
GOT_KV="$(shvar OSTLER_KNOWLEDGE_READER_VERSION)"
_bad=""
[ "$GOT_D"  = "$NEW_DSHA" ] || _bad="$_bad Makefile-DAEMON_SHA256"
[ "$GOT_IV" = "$NEW" ]      || _bad="$_bad install-ASSISTANT_VERSION"
[ "$GOT_ID" = "$NEW_DSHA" ] || _bad="$_bad install-TARBALL_SHA256"
[ "$GOT_KV" = "$NEW" ]      || _bad="$_bad install-KNOWLEDGE_READER_VERSION"
if [ -n "$_bad" ]; then
    echo "ERROR: read-back failed on:$_bad" >&2
    exit 1
fi
if [ "$GOT_V" != "$NEW" ] || [ "$GOT_S" != "$NEW_SHA" ]; then
    echo "ERROR: read-back disagrees with what was written." >&2
    echo "  DAEMON_VERSION  want ${NEW}      got ${GOT_V}" >&2
    echo "  HUB_APP_SHA256  want ${NEW_SHA}  got ${GOT_S}" >&2
    exit 1
fi

# The outgoing digest must be GONE. A sweep for the version would not have
# found it, which is exactly how v1.0.80 shipped half a bump.
# THE OUTGOING VALUES MUST BE GONE FROM BOTH FILES. A sweep for the VERSION
# would not have found the digests, which is exactly how v1.0.80 shipped half a
# bump: a digest does not contain its version.
LEFT=0
for f in "$MK" "$INSTALL"; do
    for v in "$OLD_SHA" "$OLD_DSHA"; do
        n="$(grep -c -- "$v" "$f" || true)"
        if [ "$n" -gt 0 ]; then
            echo "ERROR: an OUTGOING digest still appears ${n} time(s) in ${f##*/}." >&2
            LEFT=$((LEFT + n))
        fi
    done
done
[ "$LEFT" -eq 0 ] || exit 1

echo "[repin] all SIX pins moved, in two files:"
echo "  gui/Makefile DAEMON_VERSION                   ${OLD} -> ${NEW}"
echo "  gui/Makefile DAEMON_SHA256                    ${OLD_DSHA:0:12} -> ${NEW_DSHA:0:12}"
echo "  gui/Makefile HUB_APP_SHA256                   ${OLD_SHA:0:12} -> ${NEW_SHA:0:12}"
echo "  install.sh   OSTLER_ASSISTANT_VERSION         ${OLD} -> ${NEW}"
echo "  install.sh   DEFAULT_ASSISTANT_TARBALL_SHA256 ${OLD_DSHA:0:12} -> ${NEW_DSHA:0:12}"
echo "  install.sh   OSTLER_KNOWLEDGE_READER_VERSION  ${OLD} -> ${NEW}"
echo "[repin] both written and read back. cuts/<version>/cut.env DAEMON_COMMIT is NOT touched by this script."
