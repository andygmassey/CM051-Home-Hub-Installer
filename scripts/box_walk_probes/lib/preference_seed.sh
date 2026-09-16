#!/usr/bin/env bash
# scripts/box_walk_probes/lib/preference_seed.sh
# ============================================================================
# THE PREFERENCE SEED. Put a known PREFERENCE PAIR into the box's graph, then
# read the interest profile that the box's own compiler builds from it.
#
# WHY THIS FILE EXISTS, MEASURED
#
# grounding_seed.sh seeds a PERSON, because assistant_answers_grounded had no
# content assertion without one. The preference side had the same hole and
# nobody could see it, because a preference failure and an empty box print the
# same thing.
#
# On v1.0.81 the A/B run measured pwg_preferences answering from a POPULATED
# store (830 Qdrant points) while pwg_topics had a data explanation
# (conversations stored 0). The preferences root cause turned out to be that
# THE INGEST NEVER RAN: cm019_setup logged "already set up" with elapsed_s=0
# and there is no ingest-dir, no "Files processed" and no `enrich --all`
# anywhere in install.log. The install installs the code and prints the
# `ostler-import` command; nothing runs it.
#
# So on a cold box an empty preference wiki, an absent ingest and a broken
# write route were three different faults wearing one face. This step gives
# the walk a fixture whose absence is distinguishable from its failure.
#
# WHAT IT RUNS. OS003 gates/seed/load_preference_seed.py, the preference seed
# oracle of record. It ingests two synthetic export files through the
# INSTALLER'S OWN preference leg and then COUNTS THE ROWS BACK OUT OF THE
# GRAPH. It never reads the ingest's exit code as a verdict, because
# services/ingest/src/loaders/oxigraph_loader.py returns False on a refused
# INSERT and its caller neither raises nor propagates: a lost write and a
# clean run exit identically.
#
# WHAT THIS STEP ADDS ON TOP OF THE LOADER. The loader owns the WRITE side.
# This step owns the READ side, and it is here rather than in OS003 because
# the compiler is CM051's:
#
#   1. THE STAGED TREE IS CURRENT. Compares the cm019 code STAGED UNDER
#      ~/.ostler/services/cm019/ against this checkout's vendor copy, by
#      content. NOT the venv mtime: cm019's guard used to test its own
#      DESTINATION, so a box that had ever installed skipped the refresh and
#      kept old code under a fresh-looking venv (CM051 #1874). A stale staged
#      tree changes what the seed is measuring, so it is a CANNOT-RUN and
#      never a product FAIL.
#   2. THE SCREEN STILL SCREENS. Runs the box's own staged interest-profile
#      compiler and asserts BOTH arms: at least one interest cleared the
#      confidence floor, and at least one row was suppressed by it. One arm
#      alone cannot tell a working screen from an absent one.
#   3. THE ARTEFACT THE TOOL READS IS RECOMPILED, AND READ BACK THROUGH THE
#      API THE TOOL READS. Measured on the v1.0.82 walk, 2026-09-09: steps 1
#      and 2 both passed ("graph post-count for the seed subjects: 2",
#      "SEEDED AND ASSERTED: 1 interest(s) cleared the floor") and the
#      grounded probe still reported [tool_found_nothing:pwg_preferences].
#      The daemon's pwg_preferences tool (ostler-assistant
#      crates/zeroclaw-tools/src/pwg_preferences.rs, preferences_url) GETs
#      /api/v1/preferences, and the vendored API serves that endpoint
#      READ-ONLY from a compiled file (vendor/cm041/assistant_api/
#      ical-server.py:454-470 resolves it, api_preferences at :6650 reads
#      it, the handler at :7648 serves it): ~/.ostler/preferences/
#      interest_profile.json. That file is written by the CM059 front-page
#      LaunchAgent (install.sh 3.14d-editor block at :23798 sources
#      vendor/cm059_editor/INSTALL_SNIPPET.sh, which renders
#      ~/.ostler/bin/editor-frontpage-tick.sh and bootstraps
#      com.creativemachines.ostler.editor-frontpage with RunAtLoad and
#      StartInterval 3600). Its RunAtLoad tick fires at the END OF THE
#      INSTALL, before any seed exists, and on that walk it left
#      {"interests": [], "count": 0, "generated_at": "2026-09-09T18:17:09Z"}
#      which nothing rewrote for an hour. So the seed wrote to the store,
#      the tool read the artefact, and the two never met inside a walk.
#
#      Step 2 in-process runs compiler.interest_profile.build_from_live(),
#      the same function compiler/emit_artefact.py:134 calls, so a step-2
#      pass already proves the compiler CAN see the rows. What was missing
#      was the EMIT. This step triggers the installer's own tick (launchctl
#      kickstart, so it runs under the agent's own launchd environment; the
#      installed tick script directly only if kickstart is refused), waits
#      for generated_at in the artefact to ADVANCE past the value read
#      before the trigger, then GETs the endpoint with the box's own
#      service token and asserts the fixture's clearing subject is served
#      at or above the floor: once unfiltered, once with the domain the
#      compiled row carries and min_confidence at the floor.
#
# THE RULE THIS FILE OBEYS, THE SAME ONE grounding_seed.sh OBEYS: A SEED THAT
# DID NOT WORK MUST NOT LOOK LIKE A PRODUCT DEFECT. Every path where we could
# not look prints a NAMED CANNOT-RUN and changes no verdict. The one path that
# is a real finding -- the rows are in the graph and the screen no longer
# behaves -- is printed as a finding and says so in those words.
#
# WHAT A GREEN HERE DOES AND DOES NOT MEAN. It means an export file reaches
# the graph as a preference row and the confidence floor still holds. IT DOES
# NOT CLEAR CM051 #1872. Nothing here runs the install, so nothing here says
# whether a real install ever ingests the exports a customer actually has.
#
# ENV
#   OSTLER_SEED_DIR            path to the OS003 gates/seed directory, shared
#                              with grounding_seed.sh.
#   OSTLER_PREF_SEED_SKIP=1    do not seed at all. Prints that it was skipped.
#   OSTLER_PREF_SEED_KEEP=1    leave the synthetic rows on the box afterwards.
#   OSTLER_PREF_COMPILE_SKIP=1 seed and assert the screen, but do not trigger
#                              the compile or read the API. A named
#                              CANNOT-RUN, never a pass.
#   OSTLER_PREF_COMPILE_BUDGET_S  seconds to wait for generated_at to advance
#                              after the trigger (default 180).
#   OSTLER_PREF_COMPILE_POLL_S seconds between polls (default 2).
#   OSTLER_PREF_API_BASE       the Assistant API the tool reads
#                              (default http://127.0.0.1:8090).
#   OSTLER_PREF_LAUNCHCTL      launchctl on the box (default /bin/launchctl).
#                              Exists ONLY so the trigger is testable without
#                              kickstarting a real agent on the test machine.
#   OSTLER_BOX_HOST            unset means this machine, per the suite contract.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile. Every remote
# program is POSIX sh: it is run by /bin/sh here and by the box's login shell
# over ssh. Inside it, $HOME is written bare or double-quoted and is expanded
# ON THE BOX; a single-quoted literal $HOME hands the box a path it cannot
# open (people_seed_and_retrieval.sh, the v1.0.51 walk).
# ============================================================================

# unrun|skipped|absent|stale|failed|screen-moved|uncompiled|unserved|seeded
#   uncompiled  rows are in the graph and the screen holds, but the artefact
#               recompile or its read-back could not be measured (CANNOT-RUN)
#   unserved    the artefact was recompiled and the API still does not serve
#               the seed subject (FINDING, and it names the compiler)
PREFERENCE_SEED_STATE="unrun"
PREFERENCE_SEED_DIR=""
PREFERENCE_SEED_STALE=""

# The files the staged tree must match. Not the whole tree: these four are the
# ones this seed's expectations were measured against, so a difference in any
# of them changes what the post-count and the two floor arms mean.
_PS_CURRENCY_FILES="services/ingest/src/pipeline.py
services/ingest/src/filters.py
services/ingest/src/parsers/spotify.py
services/ingest/src/parsers/twitter.py"

_ps_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

_ps_box_exec_stdin() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# A STALE CHECKOUT IS THE TRAP, not a missing file, exactly as it is for the
# person seed. The marker is content the working loader MUST have: the graph
# read-back is the whole point of this loader, so a copy without it is a copy
# that would report the ingest's exit code and call that a pass.
_ps_loader_is_current() {
    grep -q 'COUNT(DISTINCT ?s)' "$1"
}

# SETS PREFERENCE_SEED_DIR, rather than echoing it, for the same reason
# _gs_find_seed_dir does: PREFERENCE_SEED_STALE is set on the reject path and
# a command substitution would discard it, so a stale checkout would report as
# a missing one and the operator would be told to set a variable that is
# already correct.
_ps_find_seed_dir() {
    PREFERENCE_SEED_DIR=""
    PREFERENCE_SEED_STALE=""
    _ps_ok() {
        [ -f "$1/load_preference_seed.py" ] \
            && [ -f "$1/preferences/preference_fixture.json" ] \
            && [ -f "$1/preferences/exports/StreamingHistory0.json" ] \
            && [ -f "$1/preferences/exports/personalization.js" ]
    }
    if [ -n "${OSTLER_SEED_DIR:-}" ]; then
        if _ps_ok "${OSTLER_SEED_DIR}"; then
            if _ps_loader_is_current "${OSTLER_SEED_DIR}/load_preference_seed.py"; then
                PREFERENCE_SEED_DIR="${OSTLER_SEED_DIR}"
                return 0
            fi
            PREFERENCE_SEED_STALE="${OSTLER_SEED_DIR}"
        fi
        return 1
    fi
    _ps_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _ps_repo="$(cd "${_ps_here}/../../.." && pwd)"
    for _ps_c in \
        "${_ps_repo}/../OS003-Ostler-Release/gates/seed" \
        "${_ps_repo}/../OS003 - Ostler Release/gates/seed" \
        "${HOME}/Developer/OS003-Ostler-Release/gates/seed" \
        "${HOME}/Documents/Projects/OS003 - Ostler Release/gates/seed"
    do
        if _ps_ok "${_ps_c}"; then
            if _ps_loader_is_current "${_ps_c}/load_preference_seed.py"; then
                PREFERENCE_SEED_DIR="$(cd "${_ps_c}" && pwd)"
                return 0
            fi
            [ -n "${PREFERENCE_SEED_STALE}" ] || PREFERENCE_SEED_STALE="${_ps_c}"
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 1. THE STAGED TREE IS THE TREE THE ARTEFACT DELIVERED -- BY CONTENT.
#
# install.sh re-stages cm019 only when its interpreter is ABSENT:
#
#     if [[ ! -x "$CM019_PY" ]]; then rm -rf "$CM019_DIR"; cp -R ...
#
# so on any box that had ever installed, the whole staging block is skipped and
# old code sits under a venv whose timestamp is honest and useless (#1874).
#
# THE COMPARISON IS AGAINST THE ARTEFACT, NEVER AGAINST THIS CHECKOUT. A
# checkout can agree with the DMG while the box lags, and it can move past the
# cut and refuse a good box. Only the bundle the box installed FROM is the cut.
#
# TWO INSTRUMENTS, ON PURPOSE, over the same two trees:
#   - the LOADER holds the gate: one whole-tree digest over every .py, and it
#     refuses to seed on a mismatch. It is in the loader because that is where
#     the stale code would actually run.
#   - THIS STEP holds the localiser: four named files, hashed one at a time, so
#     a mismatch says WHICH file rather than only THAT something differs.
#
# WHERE THE BUNDLE IS. /Applications/OstlerInstaller.app is NOT the default and
# must be asked for by name. On an artefact walk nothing is ever dragged to
# /Applications: install.sh is run in place inside the mounted DMG, so that
# path holds whatever an earlier run left. Measured 2026-09-04 after the
# v1.0.66 walk: the box held /Applications/OstlerInstaller.app at 1.0.63 from a
# run 13 hours earlier (ttywalk.sh, the STAGE_SRC block). A currency check that
# read a 13-hour-old app would be comparing the box against the wrong artefact
# and calling the answer a measurement.
# ---------------------------------------------------------------------------
PREFERENCE_SEED_BUNDLE=""
PREFERENCE_SEED_BUNDLE_SRC=""
_ps_find_bundle() {
    PREFERENCE_SEED_BUNDLE=""
    PREFERENCE_SEED_BUNDLE_SRC=""

    if [ -n "${OSTLER_CM019_BUNDLE:-}" ]; then
        if [ -d "${OSTLER_CM019_BUNDLE}" ]; then
            PREFERENCE_SEED_BUNDLE="${OSTLER_CM019_BUNDLE}"
            PREFERENCE_SEED_BUNDLE_SRC="OSTLER_CM019_BUNDLE"
            return 0
        fi
        return 1
    fi

    # A mounted artefact. The shape is the one ttywalk.sh insists on: an
    # <app>/Contents/Resources that carries install.sh, which is what makes it
    # the payload root rather than some other Resources directory.
    # The mount root is a variable ONLY so this branch is testable. A test
    # that had to mount a real DMG would not be run, and a branch nothing runs
    # is the same as a branch that is not there.
    for _ps_vol in "${OSTLER_PREF_SEED_VOLUMES_DIR:-/Volumes}"/*; do
        [ -d "${_ps_vol}" ] || continue
        _ps_res="$(/usr/bin/find "${_ps_vol}" -maxdepth 3 -type d -name Resources -path '*.app/Contents/*' 2>/dev/null | head -1)"
        [ -n "${_ps_res}" ] || continue
        [ -f "${_ps_res}/install.sh" ] || continue
        [ -d "${_ps_res}/cm019_preferences" ] || continue
        PREFERENCE_SEED_BUNDLE="${_ps_res}/cm019_preferences"
        PREFERENCE_SEED_BUNDLE_SRC="mounted artefact ${_ps_res}"
        return 0
    done

    # Last, and only when asked for by name. See the comment above.
    if [ "${OSTLER_ALLOW_INSTALLED_APP_BUNDLE:-0}" = "1" ]; then
        _ps_app="/Applications/OstlerInstaller.app/Contents/Resources/cm019_preferences"
        if [ -d "${_ps_app}" ]; then
            PREFERENCE_SEED_BUNDLE="${_ps_app}"
            PREFERENCE_SEED_BUNDLE_SRC="/Applications (allowed by OSTLER_ALLOW_INSTALLED_APP_BUNDLE=1, and it can be an EARLIER run's app)"
            return 0
        fi
    fi
    return 1
}

# The four files this seed's expectations were measured against. Hashed one at
# a time so a mismatch NAMES the file. Kept short on purpose: the loader's
# whole-tree digest is the gate, this is the localiser.
_ps_staged_tree_is_current() {
    if [ ! -d "${PREFERENCE_SEED_BUNDLE}" ]; then
        PREFERENCE_SEED_DRIFT="      no bundle to compare against"
        return 1
    fi

    _ps_bundle_hashes="$(
        for _ps_f in ${_PS_CURRENCY_FILES}; do
            if [ -f "${PREFERENCE_SEED_BUNDLE}/${_ps_f}" ]; then
                printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "${PREFERENCE_SEED_BUNDLE}/${_ps_f}" | cut -d' ' -f1)" "${_ps_f}"
            else
                printf 'MISSING  %s\n' "${_ps_f}"
            fi
        done
    )"

    # Computed ON THE BOX, so a transport that silently truncated a file
    # cannot pass for a match.
    _ps_remote="$(_ps_box_exec '
d="${OSTLER_DIR:-$HOME/.ostler}/services/cm019"
for f in '"$(printf '%s' "${_PS_CURRENCY_FILES}" | tr "\n" " ")"'; do
    if [ -f "$d/$f" ]; then
        printf "%s  %s\n" "$(/usr/bin/shasum -a 256 "$d/$f" | cut -d" " -f1)" "$f"
    else
        printf "MISSING  %s\n" "$f"
    fi
done
' 2>&1)"
    _ps_rc=$?
    if [ "${_ps_rc}" -ne 0 ]; then
        PREFERENCE_SEED_DRIFT="      could not read the staged tree on the box (exit ${_ps_rc}): ${_ps_remote}"
        return 1
    fi

    if [ "${_ps_bundle_hashes}" = "${_ps_remote}" ]; then
        return 0
    fi

    PREFERENCE_SEED_DRIFT="$(
        printf '%s\n' "${_ps_bundle_hashes}" > "/tmp/.ps_bundle.$$"
        printf '%s\n' "${_ps_remote}" > "/tmp/.ps_box.$$"
        while read -r _h _f; do
            _r="$(grep -E "  ${_f}\$" "/tmp/.ps_box.$$" | cut -d' ' -f1)"
            if [ -z "${_r}" ]; then
                printf '      %s  not reported by the box\n' "${_f}"
            elif [ "${_r}" != "${_h}" ]; then
                printf '      %s  bundle %s  box %s\n' "${_f}" "$(printf '%s' "${_h}" | cut -c1-12)" "$(printf '%s' "${_r}" | cut -c1-12)"
            fi
        done < "/tmp/.ps_bundle.$$"
        rm -f "/tmp/.ps_bundle.$$" "/tmp/.ps_box.$$"
    )"
    return 1
}

# ---------------------------------------------------------------------------
# Ship the seed to the box and run it. $1 = seed dir, $2... = loader arguments.
#
# FOUR files travel, not two: the loader, the fixture, and both export files,
# which must land in the preferences/exports/ shape the loader reads. One
# base64 JSON blob on stdin, for the same reasons grounding_seed.sh gives: no
# second credential path, and no dependence on whether this box's base64
# spells its decode flag -d or -D.
# ---------------------------------------------------------------------------
_ps_run_loader() {
    _ps_dir="$1"; shift
    # ONE DIGEST IMPLEMENTATION, NOT TWO. The expected digest is computed by
    # the loader's own --digest over the artefact bundle, so this step cannot
    # drift from the thing it is feeding. Its stdout is the digest alone.
    if [ -z "${PREFERENCE_SEED_DIGEST:-}" ] && [ -d "${PREFERENCE_SEED_BUNDLE}" ]; then
        PREFERENCE_SEED_DIGEST="$(python3 "${_ps_dir}/load_preference_seed.py" --digest "${PREFERENCE_SEED_BUNDLE}" 2>/dev/null)"
    fi
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        OSTLER_PREF_SEED_CM019_DIGEST="${PREFERENCE_SEED_DIGEST:-}" \
        OSTLER_PREF_SEED_CM019_DIGEST_SOURCE="${PREFERENCE_SEED_BUNDLE_SRC:-}" \
            python3 "${_ps_dir}/load_preference_seed.py" "$@"
        return $?
    fi

    _ps_payload="$(python3 - "${_ps_dir}" <<'PY'
import base64, json, os, sys
root = sys.argv[1]
names = [
    "load_preference_seed.py",
    "preferences/preference_fixture.json",
    "preferences/exports/StreamingHistory0.json",
    "preferences/exports/personalization.js",
]
files = {}
for name in names:
    with open(os.path.join(root, name), encoding="utf-8") as fh:
        files[name] = fh.read()
print(base64.b64encode(json.dumps(files).encode("utf-8")).decode("ascii"))
PY
)" || return 2

    _ps_args=""
    for _ps_a in "$@"; do _ps_args="${_ps_args} ${_ps_a}"; done

    # The two values below are embedded inside single quotes in the remote
    # command, so a SPACE is safe (a volume is routinely "/Volumes/Install
    # Ostler") but a single quote would close the quoting and the rest of the
    # label would be read as shell. The label is prose for a human, so the
    # quote is worth nothing and is dropped rather than escaped. The digest is
    # hex from our own --digest and is passed through unchanged.
    _ps_src_safe="$(printf '%s' "${PREFERENCE_SEED_BUNDLE_SRC:-}" | tr -d "'")"

    printf '%s' "${_ps_payload}" | _ps_box_exec_stdin '
d=$(mktemp -d) || exit 2
python3 -c "
import base64, json, os, sys
files = json.loads(base64.b64decode(sys.stdin.read()))
for name, body in files.items():
    p = os.path.join(sys.argv[1], name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, \"w\", encoding=\"utf-8\") as fh:
        fh.write(body)
" "$d" || { rm -rf "$d"; exit 2; }
OSTLER_PREF_SEED_CM019_DIGEST='"'${PREFERENCE_SEED_DIGEST:-}'"' \
OSTLER_PREF_SEED_CM019_DIGEST_SOURCE='"'${_ps_src_safe}'"' \
python3 "$d/load_preference_seed.py"'"${_ps_args}"'
rc=$?
rm -rf "$d"
exit $rc
'
}

# ---------------------------------------------------------------------------
# 2. THE SCREEN STILL SCREENS.
#
# Runs the box's OWN staged interest-profile compiler
# (~/.ostler/services/cm059-editor/compiler) under the interpreter the
# installer resolved for it, and reads two numbers off the profile:
#
#   interests                  >= 1    something cleared the 0.28 floor
#   suppressed_low_confidence  >= 1    something was screened by it
#
# BOTH ARMS OR NEITHER. A profile with interests and no suppressions cannot
# distinguish a working screen from an absent one, and a profile with
# suppressions and no interests cannot distinguish a working screen from one
# that rejects everything. The fixture seeds exactly one row on each side of
# the floor so both arms have a subject.
#
# THE INTERPRETER IS READ OUT OF THE RENDERED TICK, not guessed. install.sh
# substitutes __OSTLER_PYTHON__ into ~/.ostler/bin/editor-frontpage-tick.sh,
# and that interpreter is the one carrying the store-auth .pth. A bare
# `python3` here would reach Oxigraph with no credential, take the 401, and
# report an empty graph as an empty profile.
# ---------------------------------------------------------------------------
PREFERENCE_SEED_PROFILE=""
_ps_read_profile() {
    PREFERENCE_SEED_PROFILE=""
    _ps_out="$(_ps_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
T="$O/bin/editor-frontpage-tick.sh"
[ -f "$T" ] || { echo "NO-TICK $T"; exit 3; }
PY=$(sed -n "s/^PYTHON_BIN=\"\(.*\)\"$/\1/p" "$T" | head -1)
[ -n "$PY" ] || { echo "NO-PYTHON-IN-TICK $T"; exit 3; }
[ -x "$PY" ] || { echo "PYTHON-NOT-EXECUTABLE $PY"; exit 3; }
S="$O/services/cm059-editor"
[ -d "$S/compiler" ] || { echo "NO-COMPILER $S/compiler"; exit 3; }
PYTHONPATH="$S" "$PY" -c "
import json, sys
from compiler import interest_profile as ip
p = ip.build_from_live()
s = p[\"stats\"]
print(\"PROFILE interests=%d suppressed=%d dislikes=%d domains=%d raw_rows=%d\" % (
    s[\"interests\"], s[\"suppressed_low_confidence\"], s[\"dislikes\"],
    s[\"domains\"], s[\"raw_rows\"]))
print(\"FLOOR min_confidence=0.28\")
for b in p[\"domains\"]:
    for it in b[\"interests\"]:
        print(\"KEPT domain=%s confidence=%.4f subject=%s\" % (b[\"domain\"], it[\"confidence\"], it[\"subject\"]))
"
' 2>&1)"
    _ps_rc=$?
    PREFERENCE_SEED_PROFILE="${_ps_out}"
    return ${_ps_rc}
}

# ---------------------------------------------------------------------------
# 3. THE ARTEFACT IS RECOMPILED AND READ BACK THROUGH THE TOOL'S OWN ROUTE.
#
# Six small pieces, each measured on the box and each printing named lines
# that the step reads back, so no outcome is inferred from an exit code alone.
#
# THE SUBJECT AND THE FLOOR COME FROM THE FIXTURE, the oracle of record:
# expect_rows[clears_floor=true].subject and compiler.min_confidence in
# OS003 gates/seed/preferences/preference_fixture.json. Nothing here spells
# the subject or the floor a second time.
# ---------------------------------------------------------------------------
PREFERENCE_SEED_SUBJECT=""
PREFERENCE_SEED_FLOOR=""
PREFERENCE_SEED_TRIGGER=""      # kickstart|tick|"" : how the compile was started
PREFERENCE_SEED_BEFORE=""       # generated_at read before the trigger, or absent
_PS_LABEL="com.creativemachines.ostler.editor-frontpage"

_ps_fixture_target() {
    PREFERENCE_SEED_SUBJECT=""
    PREFERENCE_SEED_FLOOR=""
    _ps_ft="$(python3 - "${PREFERENCE_SEED_DIR}/preferences/preference_fixture.json" <<'PY'
import json, sys
try:
    fx = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    print("unreadable fixture: " + type(exc).__name__, file=sys.stderr)
    sys.exit(1)
rows = [r for r in fx.get("expect_rows", []) if isinstance(r, dict) and r.get("clears_floor") is True]
floor = (fx.get("compiler") or {}).get("min_confidence")
if not rows or not rows[0].get("subject") or floor is None:
    print("fixture names no clears_floor subject or no compiler.min_confidence", file=sys.stderr)
    sys.exit(1)
print(rows[0]["subject"])
print(floor)
PY
)" || return 1
    PREFERENCE_SEED_SUBJECT="$(printf '%s\n' "${_ps_ft}" | sed -n '1p')"
    PREFERENCE_SEED_FLOOR="$(printf '%s\n' "${_ps_ft}" | sed -n '2p')"
    [ -n "${PREFERENCE_SEED_SUBJECT}" ] && [ -n "${PREFERENCE_SEED_FLOOR}" ]
}

# The artefact's generated_at and mtime, read on the box. Prints
#   PATH <path>
#   STAMP <generated_at|absent|missing-field|unreadable:X> <mtime|absent>
# The path is the emitter's default (compiler/emit_artefact.py:57, the same
# default ical-server.py:459-468 reads), under OSTLER_DIR when the box sets
# it and $HOME/.ostler otherwise. Neither the LaunchAgent plist nor the API's
# plist sets OSTLER_INTEREST_PROFILE or OSTLER_PREFERENCES_DIR (measured:
# zero references in install.sh), so the default is the path both sides use.
_ps_profile_stamp() {
    _ps_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
P="$O/preferences/interest_profile.json"
python3 - "$P" <<"PY"
import json, os, sys
p = sys.argv[1]
print("PATH " + p)
if not os.path.exists(p):
    print("STAMP absent absent")
    sys.exit(0)
try:
    g = json.load(open(p, encoding="utf-8")).get("generated_at")
except Exception as exc:
    g = "unreadable:" + type(exc).__name__
print("STAMP %s %s" % (g if g else "missing-field", int(os.path.getmtime(p))))
PY
'
}

# Trigger the installer's own compile. Prints, in order:
#   PLIST present|absent <path>
#   LABEL loaded|not-loaded gui/<uid>/<label> [rc=N]
#   KICKSTART ok|refused rc=N|skipped ...
#   TICK ran rc=N <path> | TICK absent <path>      (fallback only)
#   TRIGGER kickstart|tick|none
# Exit 0 when something was started, 3 when nothing could be, 4 when the
# direct tick ran and failed.
#
# kickstart -k is preferred because it runs the tick under the agent's OWN
# launchd environment (the PATH and PYTHONPYCACHEPREFIX in the plist), which
# is the environment the hourly compile the customer depends on actually
# runs in. A direct run of the rendered tick is the same file launchd would
# run, and is used only when launchd will not (no GUI domain for the walk
# user over ssh, or an agent that was never bootstrapped). launchctl answers
# 113 for a label it cannot find (measured 2026-09-10).
_ps_trigger_compile() {
    _ps_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="'"${_PS_LABEL}"'"
LC="'"${OSTLER_PREF_LAUNCHCTL:-/bin/launchctl}"'"
PL="$HOME/Library/LaunchAgents/$L.plist"
T="$O/bin/editor-frontpage-tick.sh"
if [ ! -f "$PL" ]; then
    echo "PLIST absent $PL"
    echo "TRIGGER none"
    exit 3
fi
echo "PLIST present $PL"
U=$(id -u)
if "$LC" print "gui/$U/$L" >/dev/null 2>&1; then
    lrc=0
    echo "LABEL loaded gui/$U/$L"
else
    lrc=$?
    echo "LABEL not-loaded gui/$U/$L rc=$lrc"
fi
if [ "$lrc" -eq 0 ]; then
    "$LC" kickstart -k "gui/$U/$L" 2>&1
    krc=$?
    if [ "$krc" -eq 0 ]; then
        echo "KICKSTART ok gui/$U/$L"
        echo "TRIGGER kickstart"
        exit 0
    fi
    echo "KICKSTART refused rc=$krc"
else
    echo "KICKSTART skipped (label not loaded in gui/$U)"
fi
if [ ! -f "$T" ]; then
    echo "TICK absent $T"
    echo "TRIGGER none"
    exit 3
fi
b=$(mktemp) || { echo "TICK no-mktemp"; echo "TRIGGER none"; exit 3; }
/bin/bash "$T" >"$b" 2>&1
trc=$?
sed "s/^/TICK-LOG /" "$b" | tail -n 8
rm -f "$b"
echo "TICK ran rc=$trc $T"
if [ "$trc" -ne 0 ]; then
    echo "TRIGGER none"
    exit 4
fi
echo "TRIGGER tick"
exit 0
'
}

# Poll the artefact until generated_at ADVANCES past $1 (the value read
# before the trigger; "absent" when there was no file). Budget $2 seconds,
# step $3. Prints POLL lines as the file changes and ends with exactly one of
#   ADVANCED before=.. now=.. mtime=.. after=Ns        exit 0
#   NOT-ADVANCED before=.. now=.. mtime=.. after=Ns    exit 4
#   UNPARSEABLE generated_at=..                        exit 5
# Timestamps are PARSED, never string-compared: the emitter writes
# now.isoformat() (+00:00, microseconds) and a file written by another build
# can carry a Z. An equal value after a rewrite is NOT an advance, even
# though the mtime moved; that is the distinction the whole step rests on.
_ps_poll_profile() {
    _ps_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
P="$O/preferences/interest_profile.json"
python3 - "$P" "'"${1}"'" "'"${2}"'" "'"${3}"'" <<"PY"
import json, os, sys, time
from datetime import datetime, timezone
p, before, budget, step = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])

def parse(s):
    if not s or s in ("absent", "missing-field") or s.startswith("unreadable"):
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)

def stamp():
    if not os.path.exists(p):
        return "absent", "absent"
    try:
        g = json.load(open(p, encoding="utf-8")).get("generated_at") or "missing-field"
    except Exception as exc:
        g = "unreadable:" + type(exc).__name__
    return str(g), str(int(os.path.getmtime(p)))

b = parse(before)
t0 = time.time()
last = None
while True:
    g, m = stamp()
    now = parse(g)
    if now is not None and (b is None or now > b):
        print("ADVANCED before=%s now=%s mtime=%s after=%.1fs" % (before, g, m, time.time() - t0))
        sys.exit(0)
    if (g, m) != last:
        print("POLL generated_at=%s mtime=%s t=%.1fs" % (g, m, time.time() - t0))
        last = (g, m)
    if time.time() - t0 >= budget:
        if now is None and g != "absent":
            print("UNPARSEABLE generated_at=%s" % g)
            sys.exit(5)
        print("NOT-ADVANCED before=%s now=%s mtime=%s after=%.1fs" % (before, g, m, time.time() - t0))
        sys.exit(4)
    time.sleep(step)
PY
'
}

# GET the endpoint the tool reads, with the box's own service token, and look
# for the fixture subject. $1 = API base, $2 = subject (base64, so no quoting
# of the subject ever reaches a shell), $3 = floor.
#
# THE TOKEN NEVER LEAVES THE BOX. It is read into the python process on the
# box from the file install.sh writes (~/.ostler/secrets/service_token,
# install.sh:28207) and put in the Authorization header; nothing prints it
# and nothing carries it back over ssh. The people probe reads the same file
# (people_seed_and_retrieval.sh:134).
#
# Two GETs, both through urllib with an EMPTY proxy map: the operator shell
# routinely carries HTTP_PROXY, and a proxy will answer for 127.0.0.1 with
# its own error, which reads exactly like the service being down.
#   1  ?limit=200                               the tool's own unfiltered shape
#   2  ?domain=<row.domain>&min_confidence=<floor>&limit=200
#      with the domain READ OFF THE COMPILED ROW in GET 1, because the
#      endpoint matches domain case-sensitively (pwg_preferences.rs:217-219
#      measured Reading 3, reading 0) and a guessed case would be a wrong
#      answer wearing the shape of an empty profile.
# Prints URLn, HTTPn, COUNTn, GENERATEDn, MATCHn lines. Exit 0 both matched at
# or above the floor; 1 served without the subject (or below the floor);
# 2 transport or non-200; 3 no usable token.
_ps_api_readback() {
    _ps_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
T="$O/secrets/service_token"
if [ ! -r "$T" ]; then
    echo "NO-TOKEN $T"
    exit 3
fi
python3 - "$T" "'"${1}"'" "'"${2}"'" "'"${3}"'" <<"PY"
import base64, json, sys, urllib.error, urllib.parse, urllib.request
tok_path, base, subj_b64, floor_s = sys.argv[1:5]
tok = open(tok_path, encoding="utf-8").read().strip()
if not tok:
    print("EMPTY-TOKEN")
    sys.exit(3)
subject = base64.b64decode(subj_b64).decode("utf-8")
floor = float(floor_s)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def get(tag, query):
    url = base.rstrip("/") + "/api/v1/preferences?" + query
    print("URL%s %s" % (tag, url))
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + tok, "Accept": "application/json"})
    try:
        with opener.open(req, timeout=20) as resp:
            code = resp.status
            body = resp.read()
    except urllib.error.HTTPError as e:
        print("HTTP%s %s" % (tag, e.code))
        return None
    except Exception as exc:
        print("HTTP%s 000 %s" % (tag, type(exc).__name__))
        return None
    print("HTTP%s %s" % (tag, code))
    if code != 200:
        return None
    try:
        doc = json.loads(body.decode("utf-8"))
    except Exception as exc:
        print("BODY%s unreadable %s" % (tag, type(exc).__name__))
        return None
    items = doc.get("interests") if isinstance(doc, dict) else None
    if not isinstance(items, list):
        print("BODY%s no-interests-list" % tag)
        return None
    print("COUNT%s %d" % (tag, len(items)))
    print("GENERATED%s %s" % (tag, doc.get("generated_at")))
    hit = [it for it in items if isinstance(it, dict) and it.get("subject") == subject]
    if not hit:
        print("MATCH%s no" % tag)
        return {"match": False}
    it = hit[0]
    conf = float(it.get("confidence") or 0.0)
    print("MATCH%s yes subject=%s confidence=%.4f score=%.4f domain=%s polarity=%s" % (
        tag, subject, conf, float(it.get("score") or 0.0), it.get("domain"), it.get("polarity")))
    return {"match": True, "conf": conf, "domain": str(it.get("domain") or "")}

r1 = get("1", "limit=200")
if r1 is None:
    sys.exit(2)
if not r1["match"]:
    sys.exit(1)
if r1["conf"] < floor:
    print("BELOW-FLOOR confidence=%.4f floor=%.4f" % (r1["conf"], floor))
    sys.exit(1)
r2 = get("2", "domain=%s&min_confidence=%s&limit=200" % (
    urllib.parse.quote(r1["domain"], safe=""), floor_s))
if r2 is None:
    sys.exit(2)
if not r2["match"]:
    sys.exit(1)
sys.exit(0)
PY
'
}

# The orchestration. Called after the two floor arms passed. Returns 0 only
# when the compile was triggered, generated_at advanced, and BOTH GETs served
# the subject at or above the floor. Every return-1 path sets the state and
# prints a line beginning CANNOT-RUN or FINDING.
_ps_compile_and_serve() {
    printf '  --- 3. the artefact the tool reads: recompiled, then read back ---\n'

    if [ "${OSTLER_PREF_COMPILE_SKIP:-0}" = "1" ]; then
        PREFERENCE_SEED_STATE="uncompiled"
        printf '  CANNOT-RUN: OSTLER_PREF_COMPILE_SKIP=1. The rows are in the graph and\n'
        printf '  the screen holds, but the artefact was not recompiled and the API was\n'
        printf '  not read, so pwg_preferences will serve whatever the last hourly tick\n'
        printf '  left. That is not a pass.\n\n'
        return 1
    fi

    if ! _ps_fixture_target; then
        PREFERENCE_SEED_STATE="uncompiled"
        printf '  CANNOT-RUN: the fixture names no clears_floor subject or no\n'
        printf '  compiler.min_confidence, so there is nothing to look for in the API.\n'
        printf '    %s/preferences/preference_fixture.json\n\n' "${PREFERENCE_SEED_DIR}"
        return 1
    fi
    printf '  looking for : %s\n' "${PREFERENCE_SEED_SUBJECT}"
    printf '  floor       : min_confidence %s\n' "${PREFERENCE_SEED_FLOOR}"

    _ps_budget="${OSTLER_PREF_COMPILE_BUDGET_S:-180}"
    _ps_step="${OSTLER_PREF_COMPILE_POLL_S:-2}"
    _ps_base="${OSTLER_PREF_API_BASE:-http://127.0.0.1:8090}"

    # -- before -------------------------------------------------------------
    _ps_st="$(_ps_profile_stamp 2>&1)"
    _ps_strc=$?
    _ps_stamp_line="$(printf '%s\n' "${_ps_st}" | sed -n 's/^STAMP //p' | head -1)"
    if [ "${_ps_strc}" -ne 0 ] || [ -z "${_ps_stamp_line}" ]; then
        PREFERENCE_SEED_STATE="uncompiled"
        printf '  CANNOT-RUN: could not read the artefact before the trigger (exit %s),\n' "${_ps_strc}"
        printf '  so an advance would have nothing to be measured against.\n'
        printf '%s\n' "${_ps_st}" | sed 's/^/    /'
        printf '\n'
        return 1
    fi
    PREFERENCE_SEED_BEFORE="${_ps_stamp_line%% *}"
    printf '  artefact    : %s\n' "$(printf '%s\n' "${_ps_st}" | sed -n 's/^PATH //p' | head -1)"
    printf '  before      : generated_at %s (mtime %s)\n' "${PREFERENCE_SEED_BEFORE}" "${_ps_stamp_line##* }"

    # -- trigger ------------------------------------------------------------
    _ps_tr="$(_ps_trigger_compile 2>&1)"
    _ps_trrc=$?
    printf '%s\n' "${_ps_tr}" | sed 's/^/    /'
    PREFERENCE_SEED_TRIGGER="$(printf '%s\n' "${_ps_tr}" | sed -n 's/^TRIGGER //p' | tail -n 1)"
    case "${PREFERENCE_SEED_TRIGGER}" in
        kickstart)
            printf '  trigger     : launchctl kickstart -k, under the agent own launchd environment\n' ;;
        tick)
            printf '  trigger     : kickstart was refused, so the installed tick was run directly\n'
            printf '                (same file launchd runs, not the same environment)\n' ;;
        *)
            PREFERENCE_SEED_STATE="uncompiled"
            PREFERENCE_SEED_TRIGGER=""
            case "${_ps_tr}" in
                *"PLIST absent"*)
                    printf '  CANNOT-RUN: label absent. The installer did not leave\n'
                    printf '  %s in ~/Library/LaunchAgents, so\n' "${_PS_LABEL}"
                    printf '  there is no agent to kickstart and no hourly compile on this box.\n'
                    printf '  A hand-run compile would measure something the product never\n'
                    printf '  scheduled. Nothing was recompiled.\n\n' ;;
                *"TICK absent"*)
                    printf '  CANNOT-RUN: kickstart refused and no rendered tick to fall back\n'
                    printf '  to. Nothing was recompiled.\n\n' ;;
                *"TICK ran rc="*)
                    printf '  CANNOT-RUN: kickstart refused, and the installed tick run directly\n'
                    printf '  exited non-zero (exit %s from the trigger). Its output is above.\n' "${_ps_trrc}"
                    printf '  Nothing is asserted about the artefact.\n\n' ;;
                *)
                    printf '  CANNOT-RUN: the trigger could not be made (exit %s). Nothing was\n' "${_ps_trrc}"
                    printf '  recompiled.\n\n' ;;
            esac
            return 1 ;;
    esac

    # -- wait for generated_at to advance ----------------------------------
    _ps_po="$(_ps_poll_profile "${PREFERENCE_SEED_BEFORE}" "${_ps_budget}" "${_ps_step}" 2>&1)"
    _ps_porc=$?
    printf '%s\n' "${_ps_po}" | sed 's/^/    /'
    if [ "${_ps_porc}" -ne 0 ]; then
        PREFERENCE_SEED_STATE="uncompiled"
        case "${_ps_po}" in
            *"NOT-ADVANCED"*)
                printf '  CANNOT-RUN: budget of %ss exhausted and generated_at did not ADVANCE\n' "${_ps_budget}"
                printf '  past %s. A rewrite that leaves the same value is not a\n' "${PREFERENCE_SEED_BEFORE}"
                printf '  recompile, and an unchanged file means the tick never emitted. Read\n'
                printf '  ~/.ostler/logs/editor-frontpage.log and .err on the box for the tick\n'
                printf '  own account. Nothing is asserted about the artefact.\n\n' ;;
            *"UNPARSEABLE"*)
                printf '  CANNOT-RUN: the artefact generated_at could not be parsed as a\n'
                printf '  timestamp, so advance cannot be measured. Nothing is asserted.\n\n' ;;
            *)
                printf '  CANNOT-RUN: the poll itself failed (exit %s). Nothing is asserted.\n\n' "${_ps_porc}" ;;
        esac
        return 1
    fi

    # -- read back through the API the tool reads --------------------------
    _ps_b64="$(printf '%s' "${PREFERENCE_SEED_SUBJECT}" | base64 | tr -d '\n')"
    _ps_rb="$(_ps_api_readback "${_ps_base}" "${_ps_b64}" "${PREFERENCE_SEED_FLOOR}" 2>&1)"
    _ps_rbrc=$?
    printf '%s\n' "${_ps_rb}" | sed 's/^/    /'
    _ps_count1="$(printf '%s\n' "${_ps_rb}" | sed -n 's/^COUNT1 //p' | head -1)"
    _ps_count2="$(printf '%s\n' "${_ps_rb}" | sed -n 's/^COUNT2 //p' | head -1)"
    case "${_ps_rbrc}" in
        0) : ;;
        3)
            PREFERENCE_SEED_STATE="uncompiled"
            printf '  CANNOT-RUN: token absent. The artefact WAS recompiled (generated_at\n'
            printf '  advanced above), but the API fails closed with 401 without the\n'
            printf '  service token and none was readable on the box, so what it serves\n'
            printf '  could not be examined. Nothing is asserted about the read path.\n\n'
            return 1 ;;
        1)
            PREFERENCE_SEED_STATE="unserved"
            printf '  FINDING: THE COMPILE RAN AND THE API DOES NOT SERVE THE SEED SUBJECT.\n'
            printf '  generated_at advanced, the token was accepted, and the endpoint\n'
            printf '  returned %s interest(s) unfiltered' "${_ps_count1:-?}"
            if [ -n "${_ps_count2}" ]; then
                printf ' and %s with the domain and floor applied' "${_ps_count2}"
            fi
            printf ',\n  none of them "%s"\n' "${PREFERENCE_SEED_SUBJECT}"
            printf '  at or above %s. The rows are in the graph (step 1) and\n' "${PREFERENCE_SEED_FLOOR}"
            printf '  build_from_live() sees them in-process (step 2), so the gap is the\n'
            printf '  compiler as launchd runs it: vendor/cm059_editor/compiler/\n'
            printf '  emit_artefact.py (emit at :130-136, artefact_path at :61-74) under\n'
            printf '  bin/editor-frontpage-tick.sh:174-184, or api_preferences in\n'
            printf '  vendor/cm041/assistant_api/ical-server.py:6650 reading a different\n'
            printf '  path than the emitter wrote. Read the artefact and the tick log on the\n'
            printf '  box before calling this a walk failure.\n\n'
            return 1 ;;
        *)
            PREFERENCE_SEED_STATE="uncompiled"
            printf '  CANNOT-RUN: the API could not be read (exit %s): a non-200, a refused\n' "${_ps_rbrc}"
            printf '  connection or an unreadable body, named above. 401 with the box own\n'
            printf '  token is an auth fault, not a compiler fault. Nothing is asserted\n'
            printf '  about the read path.\n\n'
            return 1 ;;
    esac

    printf '  served      : %s interest(s) unfiltered, %s with domain and floor applied\n' \
        "${_ps_count1:-?}" "${_ps_count2:-?}"
    return 0
}

# ---------------------------------------------------------------------------
# THE STEP. Sourced and called by run_box_walk.sh in the caller's own shell,
# beside the grounding seed, for the same reason: this is the last moment
# before anything is measured, and ttywalk.sh does not invoke this runner at
# all (measured: zero references), so a seed wired there would never reach it.
#
# Returns 0 when both arms passed. Returns 1 otherwise, and EVERY return-1
# path prints a line beginning CANNOT-RUN or FINDING so a reader never has to
# infer which of the two it was.
# ---------------------------------------------------------------------------
preference_seed_apply() {
    printf -- '--- PREFERENCE SEED: a known preference pair, and the floor that screens one of them ---\n'

    if [ "${OSTLER_PREF_SEED_SKIP:-0}" = "1" ]; then
        PREFERENCE_SEED_STATE="skipped"
        printf '  SKIPPED by OSTLER_PREF_SEED_SKIP=1. Nothing was seeded and no\n'
        printf '  preference assertion was made. That is not a pass.\n\n'
        return 1
    fi

    _ps_find_seed_dir
    if [ -z "${PREFERENCE_SEED_DIR}" ] && [ -n "${PREFERENCE_SEED_STALE}" ]; then
        PREFERENCE_SEED_STATE="absent"
        printf '  CANNOT-RUN: the preference seed found is a PRE-READ-BACK loader.\n'
        printf '    %s\n' "${PREFERENCE_SEED_STALE}"
        printf '  Its load_preference_seed.py does not count rows out of the graph,\n'
        printf '  so it would report the ingest exit code and call that a pass. Pull\n'
        printf '  that checkout to OS003 main, or point OSTLER_SEED_DIR at one that\n'
        printf '  is current. Nothing was seeded.\n\n'
        return 1
    fi
    if [ -z "${PREFERENCE_SEED_DIR}" ]; then
        PREFERENCE_SEED_STATE="absent"
        printf '  CANNOT-RUN: no OS003 preference seed found.\n'
        printf '  Looked for load_preference_seed.py plus preferences/ beside this\n'
        printf '  checkout, under ~/Developer and under ~/Documents/Projects. Set\n'
        printf '  OSTLER_SEED_DIR to the OS003 gates/seed directory.\n'
        printf '  NOT a product defect, and NOT a pass.\n\n'
        return 1
    fi
    printf '  preference seed: %s\n' "${PREFERENCE_SEED_DIR}"

    if ! _ps_find_bundle; then
        PREFERENCE_SEED_STATE="absent"
        printf '  CANNOT-RUN: no cm019 bundle to compare the box against.\n'
        printf '  Set OSTLER_CM019_BUNDLE to the cm019_preferences directory inside\n'
        printf '  the artefact this box installed from, or mount that artefact.\n'
        printf '  NOT this checkout: a checkout can agree with the DMG while the box\n'
        printf '  lags, and can move past the cut and refuse a good box.\n'
        printf '  /Applications/OstlerInstaller.app is not used unless\n'
        printf '  OSTLER_ALLOW_INSTALLED_APP_BUNDLE=1, because on an artefact walk\n'
        printf '  nothing is dragged there and it holds an EARLIER run app\n'
        printf '  (measured 2026-09-04: 1.0.63 sitting beside a 1.0.66 walk).\n\n'
        return 1
    fi
    printf '  cm019 bundle:    %s\n' "${PREFERENCE_SEED_BUNDLE}"
    printf '  bundle read from %s\n' "${PREFERENCE_SEED_BUNDLE_SRC}"

    PREFERENCE_SEED_DRIFT=""
    if ! _ps_staged_tree_is_current; then
        PREFERENCE_SEED_STATE="stale"
        printf '  CANNOT-RUN: the cm019 code STAGED ON THE BOX is not the code the\n'
        printf '  artefact delivered, so its counts would not mean what the fixture\n'
        printf '  says they mean. Bundle: %s\n' "${PREFERENCE_SEED_BUNDLE_SRC}"
        printf '%s\n' "${PREFERENCE_SEED_DRIFT}"
        printf '  This is read from the staged tree under services/cm019/, NOT from\n'
        printf '  the venv mtime: a box that had ever installed used to skip the\n'
        printf '  refresh and keep old code under a fresh-looking venv (#1874).\n'
        printf '  Nothing was seeded.\n\n'
        return 1
    fi
    printf '  staged cm019 tree matches the artefact bundle on all four measured files\n'

    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        printf '  target: this machine (OSTLER_BOX_HOST unset)\n'
    else
        printf '  target: %s\n' "${OSTLER_BOX_HOST}"
    fi

    _ps_out="$(_ps_run_loader "${PREFERENCE_SEED_DIR}" 2>&1)"
    _ps_rc=$?
    printf '%s\n' "${_ps_out}" | sed 's/^/    /'

    if [ "${_ps_rc}" -ne 0 ]; then
        PREFERENCE_SEED_STATE="failed"
        if [ "${_ps_rc}" -eq 1 ]; then
            printf '  FINDING (loader exit 1): the ingest ran and the rows are not in\n'
            printf '  the graph, or landed with the wrong category or source. That is a\n'
            printf '  finding about the write route, and the loader named it above.\n'
        else
            printf '  CANNOT-RUN (loader exit %s): no store credential, a 401, a\n' "${_ps_rc}"
            printf '  transport failure, a non-zero pre-count, an excluded source or a\n'
            printf '  missing cm019 venv. The loader named which, above.\n'
        fi
        printf '  No preference assertion was made.\n\n'
        return 1
    fi

    # The rows are in the graph. Now ask the box's own compiler what it makes
    # of them. From here a failure is a FINDING, not a CANNOT-RUN, unless we
    # could not run the compiler at all.
    if ! _ps_read_profile; then
        PREFERENCE_SEED_STATE="failed"
        printf '  CANNOT-RUN: could not run the box own interest-profile compiler.\n'
        printf '%s\n' "${PREFERENCE_SEED_PROFILE}" | sed 's/^/    /'
        printf '  The rows ARE in the graph (the loader proved that above), so this\n'
        printf '  is about the reader, not the write route. Nothing is asserted.\n\n'
        return 1
    fi
    printf '%s\n' "${PREFERENCE_SEED_PROFILE}" | sed 's/^/    /'

    _ps_line="$(printf '%s\n' "${PREFERENCE_SEED_PROFILE}" | grep '^PROFILE ' | head -1)"
    if [ -z "${_ps_line}" ]; then
        PREFERENCE_SEED_STATE="failed"
        printf '  CANNOT-RUN: the compiler ran but printed no PROFILE line, so there\n'
        printf '  is no number to read. Not an empty profile: an unreadable one.\n\n'
        return 1
    fi

    # Words, not substrings, and never a bare grep -c: `grep -c` prints its
    # count AND exits 1 on zero, so `grep -c ... || echo 0` yields "0\n0".
    _ps_interests="$(printf '%s' "${_ps_line}" | sed -n 's/.*[[:space:]]interests=\([0-9][0-9]*\).*/\1/p')"
    _ps_suppressed="$(printf '%s' "${_ps_line}" | sed -n 's/.*[[:space:]]suppressed=\([0-9][0-9]*\).*/\1/p')"
    if [ -z "${_ps_interests}" ] || [ -z "${_ps_suppressed}" ]; then
        PREFERENCE_SEED_STATE="failed"
        printf '  CANNOT-RUN: the PROFILE line carried no interests= or suppressed=\n'
        printf '  number, so there is nothing to compare against the floor.\n\n'
        return 1
    fi

    _ps_bad=0
    if [ "${_ps_interests}" -lt 1 ]; then
        printf '  FINDING: interests=%s. Nothing cleared the 0.28 confidence floor,\n' "${_ps_interests}"
        printf '  and the seed put a row there on purpose (measured 0.2991, a margin\n'
        printf '  of +0.0191). Either the write route dropped it after the read-back,\n'
        printf '  or a trust constant moved. Read the KEPT lines above before calling\n'
        printf '  this a walk failure.\n'
        _ps_bad=1
    fi
    if [ "${_ps_suppressed}" -lt 1 ]; then
        printf '  FINDING: suppressed=%s. NOTHING was screened by the floor, and the\n' "${_ps_suppressed}"
        printf '  seed put a row below it on purpose (measured 0.1732). A screen that\n'
        printf '  never screens cannot be told from an absent screen, so this arm is\n'
        printf '  as load-bearing as the one above it.\n'
        _ps_bad=1
    fi
    if [ "${_ps_bad}" -ne 0 ]; then
        PREFERENCE_SEED_STATE="screen-moved"
        printf '\n'
        return 1
    fi

    printf '  SCREEN HOLDS: %s interest(s) cleared the floor and %s row(s) were\n' "${_ps_interests}" "${_ps_suppressed}"
    printf '  screened by it, in-process. That is what the tool WOULD see; what it\n'
    printf '  DOES see is the compiled artefact, measured next.\n'

    # The rows are in the graph and the screen holds. Now make the artefact
    # the tool reads say so, and read it back through the tool's own route.
    # Every return-1 path inside has already set the state and printed a
    # named CANNOT-RUN or FINDING.
    if ! _ps_compile_and_serve; then
        return 1
    fi

    PREFERENCE_SEED_STATE="seeded"
    printf '  SEEDED, COMPILED AND SERVED: %s interest(s) cleared the floor, %s row(s)\n' "${_ps_interests}" "${_ps_suppressed}"
    printf '  were screened by it, the artefact was recompiled (generated_at advanced\n'
    printf '  past %s) and /api/v1/preferences serves\n' "${PREFERENCE_SEED_BEFORE}"
    printf '  "%s" at or above %s, unfiltered\n' "${PREFERENCE_SEED_SUBJECT}" "${PREFERENCE_SEED_FLOOR}"
    printf '  and with the domain and floor applied. pwg_preferences has something\n'
    printf '  to find.\n'
    printf '  THIS DOES NOT CLEAR #1872: nothing here ran the install, so nothing\n'
    printf '  here says whether a real install ever ingests a customer own exports.\n\n'
    return 0
}

# ---------------------------------------------------------------------------
# Remove the synthetic rows once the probes have finished. Called after phase
# 2, beside grounding_seed_forget, and never fails the walk: every measurement
# is already taken by then, so a tidy-up that could change a verdict would be
# worse than leaving the rows.
# ---------------------------------------------------------------------------
preference_seed_forget() {
    case "${PREFERENCE_SEED_STATE}" in
        seeded|screen-moved|uncompiled|unserved) : ;;
        *) return 0 ;;
    esac
    if [ "${OSTLER_PREF_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- PREFERENCE SEED: kept on the box (OSTLER_PREF_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- PREFERENCE SEED: removing the synthetic rows ---\n'
    _ps_fout="$(_ps_run_loader "${PREFERENCE_SEED_DIR}" --forget 2>&1)"
    _ps_frc=$?
    printf '%s\n' "${_ps_fout}" | sed 's/^/    /'
    if [ "${_ps_frc}" -ne 0 ]; then
        printf '  Left on the box (forget exited %s). Every measurement above was\n' "${_ps_frc}"
        printf '  already taken, so this changes no verdict in this run. Run\n'
        printf '  load_preference_seed.py --forget by hand on any box that is not a\n'
        printf '  throwaway.\n'
        printf '\n'
        return 0
    fi

    # THE COMPILED ARTEFACT IS NOT THE GRAPH. --forget removes the rows; the
    # artefact under ~/.ostler/preferences/ still carries the seed subject
    # until the next hourly tick rewrites it. When this run triggered a
    # compile, trigger it once more the same way, and MEASURE it: generated_at
    # must advance again. Neither outcome changes a verdict; every measurement
    # was taken before this function was called.
    if [ -z "${PREFERENCE_SEED_TRIGGER}" ]; then
        printf '  The compiled artefact was not recompiled in this run, so it is left\n'
        printf '  as it was. If it carries the seed subject, the next hourly tick of\n'
        printf '  %s rewrites it.\n\n' "${_PS_LABEL}"
        return 0
    fi
    printf '  recompiling the artefact so it stops carrying the seed subject\n'
    _ps_fst="$(_ps_profile_stamp 2>&1)"
    _ps_fbefore="$(printf '%s\n' "${_ps_fst}" | sed -n 's/^STAMP //p' | head -1)"
    _ps_fbefore="${_ps_fbefore%% *}"
    _ps_ftr="$(_ps_trigger_compile 2>&1)"
    printf '%s\n' "${_ps_ftr}" | sed 's/^/    /'
    case "${_ps_ftr}" in
        *"TRIGGER kickstart"*|*"TRIGGER tick"*)
            _ps_fpo="$(_ps_poll_profile "${_ps_fbefore:-absent}" "${OSTLER_PREF_COMPILE_BUDGET_S:-180}" "${OSTLER_PREF_COMPILE_POLL_S:-2}" 2>&1)"
            _ps_fporc=$?
            printf '%s\n' "${_ps_fpo}" | sed 's/^/    /'
            if [ "${_ps_fporc}" -eq 0 ]; then
                printf '  recompiled: generated_at advanced past %s after the rows were removed.\n' "${_ps_fbefore:-absent}"
            else
                printf '  Left carrying the seed subject: the re-trigger ran but generated_at did\n'
                printf '  not advance (exit %s). The next hourly tick rewrites it.\n' "${_ps_fporc}"
            fi ;;
        *)
            printf '  Left carrying the seed subject: the re-trigger could not be made. The\n'
            printf '  next hourly tick rewrites it.\n' ;;
    esac
    printf '\n'
    return 0
}
