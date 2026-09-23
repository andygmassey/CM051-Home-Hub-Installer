#!/usr/bin/env bash
#
# scripts/record_walk.sh -- THE JOIN BETWEEN A WALK AND ITS RECORD.
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────
#
# The launch directive makes walks/v1.0.NN.tsv with `verdict CLEAN` THE
# deliverable. scripts/verify_walk_record.sh reads it and
# scripts/publish_release.sh refuses to repoint ostler.ai/install.dmg without
# it. scripts/post_walk_qa.sh writes it, correctly, and has since 2026-08-21.
#
# NOTHING EVER CALLED IT. Measured on origin/main 2026-09-23, the predicate
# being "an executable invocation of post_walk_qa.sh":
#
#   whole repo, excluding tests/        0 hits
#   CONTROL, same predicate in tests/   8 files
#
# A uniform zero with a live control is a real absence, not a broken grep. The
# writer was BUILT AND DARK -- the same defect shape post_walk_qa.sh's own
# header describes about the suite it wraps, one layer up, unnoticed for a
# month because the artefact it produces is committed by hand and nobody
# notices a file that is merely never added.
#
# WHAT THAT COST, measured on the driver (Andy's MacBook Pro, NOT the walk box
# -- post_walk_qa.sh writes its probe log to the DRIVER's $HOME):
#
#   ~/.ostler/walks, entries dated on or after 2026-09-18   0
#   CONTROL, same find, cutoff 2026-09-16                   4
#
# So the last time the writer ran at all was the v1.0.100 walk on 2026-09-17.
# Two full thin walks ran on real hardware on 2026-09-23 and produced no
# record, because the command the directive mandates -- scripts/ttywalk.sh --
# names post_walk_qa.sh exactly twice, both times in prose.
#
# This file is the join, and ttywalk.sh invokes it. A completed walk now lands
# its record without anybody remembering a second command.
#
# ── THREE OUTCOMES, AND THE THIRD IS THE POINT ───────────────────────────
#
# A walk that could not complete must not silently produce a record, and must
# not silently produce nothing either. It says which:
#
#   0  RECORDED    a record was written for this walk, and it is NEW
#   2  CANNOT-RUN  no record, and there should have been one
#   3  DECLINED    no record, and that is correct (a precondition is absent)
#
# 🔴 THE EXIT CODE IS ABOUT THE RECORDING, NEVER ABOUT THE WALK. post_walk_qa.sh
# exits 1 on a real FAIL and 2 on lost coverage, and it writes a record in BOTH
# cases -- walks/v1.0.100.tsv says `verdict FAILED` and is one of the most
# useful files in this repo. Collapsing the recorder's exit into this one would
# turn "the walk found defects" into "the walk was not recorded", which is the
# inversion scripts/verify_walk_record.sh warns about at _require_console_walk:
# it converts evidence of badness into absence of evidence. A FAILED walk that
# recorded itself exits 0 HERE and says so.
#
# ── THE CONTROL ──────────────────────────────────────────────────────────
#
# A record that already existed before this run is not proof this run wrote
# one. Records are committed to the repo, so walks/v1.0.101.tsv can be sitting
# in the tree from someone else's walk, and a bare `[[ -f ]]` would call a dead
# recorder green. So a marker file is stamped BEFORE the recorder runs and the
# record must be NEWER than it. If the recorder exits 0 and the file is stale,
# that is CANNOT-RUN and it is named as such.
#
# ── USAGE ────────────────────────────────────────────────────────────────
#
#   scripts/record_walk.sh --host <ssh-target> [--version vX.Y.Z]
#                          [--walk-verdict <0|1|2>] [--console "<who, when>"]
#
# --version is read off the box when not given: ~/.walk-artefact-version, which
# ttywalk.sh writes from the mounted bundle's CFBundleShortVersionString. A
# repo walk has no artefact and therefore no release to record -- that is
# DECLINED, not a failure.
#
# --walk-verdict is ttywalk.sh's own adjudication of the INSTALL. 0 or 1 mean
# install.sh reached a conclusion and the box is in a state the probes can
# describe. 2 (CANNOT-RUN) means it did not, and grading a half-installed box
# would produce a record that looks like evidence and is not. Absent, the
# recording proceeds: a human running this by hand has already decided.
#
# --console passes OSTLER_CONSOLE_WALK through to post_walk_qa.sh, which is
# what makes walk_kind=console and what verify_walk_record.sh requires before a
# record may repoint the customer download. An ssh walk records walk_kind=thin
# and says, in the record itself, that it does not authorise a promote.
#
# ⚠️ THE PROBE SUITE WRITES. post_walk_qa.sh seeds a synthetic person into the
# LIVE store (#829). That is unchanged by being invoked automatically, which is
# why ttywalk.sh's --no-record exists.

set -uo pipefail

RECORDED=0
CANNOT_RUN=2
DECLINED=3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST=""
VERSION=""
WALK_VERDICT=""
CONSOLE=""

say() { printf '%s\n' "$*"; }

# ONE MACHINE-READABLE LINE, ALWAYS, ON EVERY PATH. The whole reason this file
# exists is that a missing record was invisible. A status line that is printed
# only on the happy path would reproduce that exactly: absence would once again
# look like nothing having happened.
status() { printf 'walk-record: %s\n' "$*"; }

# PRINTED ONCE, ON STDOUT, on both paths. Not duplicated to stderr: two copies
# of one verdict is how a reader starts counting two events, and this line is
# the thing a caller greps for.
decline() { status "DECLINED -- $*"; exit "$DECLINED"; }
cannot()  { status "CANNOT-RUN -- $*"; exit "$CANNOT_RUN"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)          HOST="${2:-}"; shift 2 ;;
        --version)       VERSION="${2:-}"; shift 2 ;;
        --walk-verdict)  WALK_VERDICT="${2:-}"; shift 2 ;;
        --console)       CONSOLE="${2:-}"; shift 2 ;;
        -h|--help)       sed -n '2,84p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               cannot "unknown argument: $1" ;;
    esac
done

[[ -n "$HOST" ]] || cannot "--host is required (the ssh target the walk ran against)"

# ── PRECONDITION: DID THE WALK REACH A CONCLUSION ────────────────────────
#
# Only 2 declines. An empty value means nobody told us, and a human invoking
# this by hand has already made the judgement -- refusing them would be a gate
# guessing at intent it was never given.
if [[ "$WALK_VERDICT" == "2" ]]; then
    decline "the install walk adjudicated CANNOT-RUN, so the box is not in a state any probe can describe. Grading it would write a record that looks like evidence about ${VERSION:-this build} and is not."
fi

# ── THE RECORDER MUST EXIST ──────────────────────────────────────────────
#
# Overridable so the suite can substitute a stub and exercise every branch
# below without a box, credentials, or a 40-minute probe run.
QA="${OSTLER_POST_WALK_QA:-${REPO_ROOT}/scripts/post_walk_qa.sh}"
[[ -f "$QA" ]] || cannot "the writer is absent: ${QA} does not exist. Nothing can record this walk."
[[ -r "$QA" ]] || cannot "the writer is present but unreadable: ${QA}."

# ── THE VERSION ──────────────────────────────────────────────────────────
#
# 🔴 READ IT OFF THE BOX, NEVER ASSUME IT. This mirrors post_walk_qa.sh's own
# rule, which exists because walks/v1.0.42.tsv attributes real measurements to
# a version that box never ran. Here the value comes from the file ttywalk.sh
# wrote from the bundle it actually mounted.
#
# post_walk_qa.sh re-measures the version itself and REFUSES to write a record
# that disagrees with the box. That is the real guard; this is the argument it
# checks against, so a wrong value here produces a refusal, never a false
# record.
if [[ -z "$VERSION" ]]; then
    # 🔴 AN UNREACHABLE BOX IS NOT AN ABSENT VERSION, AND THE FIRST VERSION OF
    # THIS FILE CONFLATED THEM. Measured against 192.0.2.1 (TEST-NET-1, which
    # cannot answer): ssh timed out, the substitution yielded "", and this
    # reported DECLINED -- "a repo walk ... is not evidence about any release".
    # Every word of that was false. The walk may well have been an artefact
    # walk; we simply could not ask. A confident wrong REASON sends the next
    # person to the wrong problem, which is the same defect class as reporting
    # CANNOT-RUN as a pass, one field over.
    #
    # ssh exits 255 for its OWN failures and otherwise propagates the remote
    # command's code, so 255 is the discriminator between "could not look" and
    # "looked, found nothing". `cat` on an absent file exits 1, which is a real
    # measurement: the file is not there.
    _ssh_rc=0
    VERSION="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
        'cat ~/.walk-artefact-version 2>/dev/null' 2>/dev/null)" || _ssh_rc=$?
    VERSION="$(printf '%s' "$VERSION" | tr -d '[:space:]')"
    if [[ "$_ssh_rc" -eq 255 ]]; then
        cannot "could not reach ${HOST} to read the artefact version (ssh exited 255). This walk is unrecorded and the reason is the network, NOT an absent version. Re-run: scripts/record_walk.sh --host ${HOST} --version <vX.Y.Z>"
    fi
fi

if [[ -z "$VERSION" ]]; then
    decline "no artefact version is known for this walk (~/.walk-artefact-version on the box is present-but-empty or absent, and the box WAS reachable). A repo walk exercises install.sh from a checkout and is not evidence about any release, so there is no release to record."
fi

# NORMALISE THE LEADING v, AND ONLY THAT. post_walk_qa.sh requires ^v[0-9.]+$
# and ttywalk.sh writes the bare CFBundleShortVersionString (1.0.101), so an
# un-normalised hand-off would fail the usage check on every single walk. Only
# a leading v is added; anything else is left alone so a malformed value is
# refused by the writer rather than massaged into looking valid.
[[ "$VERSION" == v* ]] || VERSION="v${VERSION}"

if ! [[ "$VERSION" =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
    cannot "the version read for this walk is '${VERSION}', which is not a release version. A diagnostic wearing a value's clothes must not become a filename."
fi

WALK_DIR="${OSTLER_WALK_RECORD_DIR:-${REPO_ROOT}/walks}"
RECORD="${WALK_DIR}/${VERSION}.tsv"

# ── THE CONTROL, TAKEN BEFORE THE ACT ────────────────────────────────────
#
# A control for a destructive-or-creative act has to be taken BEFORE it, or it
# cannot distinguish "this run wrote it" from "it was already there". Records
# are tracked files: walks/${VERSION}.tsv may well exist in the checkout
# already, from a previous walk or from git.
mkdir -p "$WALK_DIR" 2>/dev/null || cannot "cannot create ${WALK_DIR}; there is nowhere to put a record."
MARKER="${WALK_DIR}/.record_walk.marker.$$"
if ! : > "$MARKER" 2>/dev/null; then
    cannot "cannot write into ${WALK_DIR}; a record could not be verified even if one appeared."
fi
trap 'rm -f "$MARKER"' EXIT

PRE_EXISTED=no
[[ -f "$RECORD" ]] && PRE_EXISTED=yes

say ""
printf -- '---- RECORD THE WALK ----\n'
say "  writer : ${QA}"
say "  box    : ${HOST}"
say "  version: ${VERSION}"
say "  record : ${RECORD}  (existed before this run: ${PRE_EXISTED})"
say ""

# ── RUN THE WRITER ───────────────────────────────────────────────────────
#
# Its exit code is CAPTURED, not propagated, and not put in an && chain: 1 and
# 2 are ordinary outcomes of a walk that found something, and both still write
# a record. See the header.
qa_rc=0
if [[ -n "$CONSOLE" ]]; then
    OSTLER_CONSOLE_WALK="$CONSOLE" "$QA" "$HOST" "$VERSION" || qa_rc=$?
else
    "$QA" "$HOST" "$VERSION" || qa_rc=$?
fi

say ""

# ── ADJUDICATE THE RECORDING, NOT THE WALK ───────────────────────────────
if [[ ! -f "$RECORD" ]]; then
    cannot "${QA} exited ${qa_rc} and ${RECORD} does not exist. The walk is unrecorded. Do not read the probe output above as a verdict on the release: nothing downstream can see it."
fi

# THE CONTROL FIRES HERE. A file older than the marker is somebody else's
# evidence, and a recorder that exited 0 over it is dead.
if [[ ! "$RECORD" -nt "$MARKER" ]]; then
    cannot "${RECORD} exists but is NOT newer than this run (writer exited ${qa_rc}). That file is a PREVIOUS walk's record and this walk wrote nothing. A green from a dead writer is the exact failure this control exists to catch."
fi

# The verdict is read back out of the record, so what is reported is what was
# written rather than what was intended. Tab-separated, first field is the key.
REC_VERDICT="$(awk -F'\t' '$1 == "verdict" { print $2; exit }' "$RECORD" 2>/dev/null)"
REC_KIND="$(awk -F'\t' '$1 == "walk_kind" { print $2; exit }' "$RECORD" 2>/dev/null)"

if [[ -z "$REC_VERDICT" ]]; then
    cannot "${RECORD} was written by this run but carries no verdict field. scripts/verify_walk_record.sh treats a record with no verdict as no record at all, so this is an unrecorded walk with a file in the way."
fi

status "RECORDED ${RECORD#${REPO_ROOT}/} verdict=${REC_VERDICT} walk_kind=${REC_KIND:-<absent>} writer_exit=${qa_rc}"
say ""
say "  The walk is recorded. It is NOT committed: ${RECORD#${REPO_ROOT}/} is a"
say "  tracked file and landing it is a PR, the same as every walk record"
say "  before it. Nothing downstream can read it until that PR merges."
if [[ "$REC_KIND" != "console" ]]; then
    say ""
    say "  walk_kind=${REC_KIND:-<absent>}, so this record does NOT authorise repointing"
    say "  the customer download. Only a console walk does. That is a statement"
    say "  about which evidence this is, not a defect."
fi
exit "$RECORDED"
