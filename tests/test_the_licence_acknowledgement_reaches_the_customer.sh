#!/usr/bin/env bash
# Row 969, the consumer-side half.
#
# THE SUBJECT OF EVERY ASSERTION IS A PERSON AND WHAT THEY CAN SEE.
# A customer re-installs, chooses "use previous answers", and has no prior
# personal-use record. Three things must then be true, and the third is the one
# nothing checked:
#
#   1. they are SHOWN the licence terms and asked,
#   2. their answer LANDS in the durable registry at
#      $OSTLER_HOME/posture/consent.json, written by the real consent CLI,
#   3. it is VISIBLE, and CHECKABLE, in the Doctor consent tile.
#
# (3) was false on origin/main c4d4b5af, measured by driving exactly this path.
# The tile enumerates the registry, so the record did appear, but the tile's
# wording-drift check runs off a HAND-WRITTEN map of five ConsentStrings while
# install.sh records six and ostler_security.consent_cli knows six. The sixth is
# personal_use_only. So the acknowledgement rendered grey "unknown wording" with
# a "?", which dashboard_components' own docstring calls "an honest-looking
# state that happens to be exactly what a genuinely unrecognised tickbox_id
# renders". The customer's licence acknowledgement was indistinguishable from a
# bogus record, and the drift check the install screen says the record exists to
# enable could never run on it.
#
# NOTHING HERE ASSERTS ON THE PRESENCE OF A STRING IN A FILE. The shell under
# test is EXTRACTED FROM install.sh at run time, the consent CLI that writes the
# record is the real vendored one, the registry is a real file on disk, and the
# tile is rendered by the real vendored Doctor function the web UI calls.
#
# THREE STATES. CANNOT-RUN is not PASS and is not FAIL, and it exits non-zero.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
INSTALL_SH="$REPO/install.sh"
DOCTOR_AGENT="$REPO/vendor/doctor/agent"

PASS=0; FAIL=0; CANTRUN=0
ok()   { PASS=$((PASS+1));    echo "  ok          $1"; }
bad()  { FAIL=$((FAIL+1));    echo "  FAIL        $1"; }
cant() { CANTRUN=$((CANTRUN+1)); echo "  CANNOT-RUN  $1"; }
verdict() {
    echo ""
    echo "PASS=$PASS FAIL=$FAIL CANNOT-RUN=$CANTRUN"
    [ "$FAIL" -eq 0 ] && [ "$CANTRUN" -eq 0 ] && [ "$PASS" -ge 14 ] && exit 0
    exit 1
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PY="${PYTHON:-python3}"

echo "=== preflight ==="
echo "EXAMINED: $INSTALL_SH, $DOCTOR_AGENT/dashboard_components.py,"
echo "          $REPO/vendor/ostler_security/consent_cli.py, $REPO/vendor/legal/"

[ -r "$INSTALL_SH" ] || { cant "install.sh unreadable"; verdict; }

# The two imports this test cannot substitute for. A missing dependency is a
# CANNOT-RUN, never a green: an unimportable Doctor would make every tile
# assertion below vacuous.
if ! env -u PYTHONPATH "$PY" -c "
import sys
sys.path.insert(0, '$REPO/vendor')
sys.path.insert(0, '$DOCTOR_AGENT')
import dashboard_components, legal
from ostler_security import consent, consent_cli
" >"$WORK/pre.log" 2>&1; then
    cant "cannot import the real Doctor tile + consent registry:"
    sed 's/^/              /' "$WORK/pre.log" | tail -5
    cant "install with: python3 -m pip install cryptography httpx"
    verdict
fi
ok "the real Doctor tile, the real consent CLI and the real legal package all import"

# ─────────────────────────────────────────────────────────────────────
#  PART 1. DENOMINATORS: who can record, who can check
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== part 1: denominators ==="

# M(install.sh) - every tickbox id install.sh actually persists. Enumerated by
# reading the SECOND argument of every _consent_cli_record call, which is where
# the id goes, rather than by grepping for ids we already know.
INSTALL_IDS="$WORK/install_ids.txt"
awk '
  /_consent_cli_record (blocking|declined) \\$/ { want=1; next }
  want { gsub(/^[ \t]+/, ""); sub(/\\$/, ""); gsub(/[ \t]+$/, ""); print; want=0 }
' "$INSTALL_SH" | sort -u > "$INSTALL_IDS"
M_INSTALL=$(/usr/bin/grep -c . "$INSTALL_IDS" || true)

env -u PYTHONPATH "$PY" - > "$WORK/denoms.txt" 2>>"$WORK/pre.log" <<PYEOF
import sys
sys.path.insert(0, "$REPO/vendor")
sys.path.insert(0, "$DOCTOR_AGENT")
import legal
from ostler_security import consent_cli
import dashboard_components as dc
open("$WORK/cli_ids.txt", "w").write(
    "\n".join(sorted(consent_cli.TICKBOX_REGISTRY)) + "\n")
open("$WORK/doctor_ids.txt", "w").write(
    "\n".join(sorted(dc._resolve_bundled_consents())) + "\n")
open("$WORK/legal_ids.txt", "w").write(
    "\n".join(sorted(getattr(legal, n).tickbox_id for n in legal.__all__
                     if isinstance(getattr(legal, n), legal.ConsentString))) + "\n")
PYEOF
M_CLI=$(/usr/bin/grep -c . "$WORK/cli_ids.txt" || true)
M_DOCTOR=$(/usr/bin/grep -c . "$WORK/doctor_ids.txt" || true)
M_LEGAL=$(/usr/bin/grep -c . "$WORK/legal_ids.txt" || true)

echo "  M(install.sh _consent_cli_record call sites, 2nd arg)   = $M_INSTALL"
echo "  M(ostler_security.consent_cli.TICKBOX_REGISTRY)         = $M_CLI"
echo "  M(legal package ConsentString exports)                  = $M_LEGAL"
echo "  M(Doctor _resolve_bundled_consents, the drift check)    = $M_DOCTOR"
echo "  install.sh ids: $(tr '\n' ' ' < "$INSTALL_IDS")"
echo "  Doctor ids    : $(tr '\n' ' ' < "$WORK/doctor_ids.txt")"

if [ "$M_INSTALL" -lt 4 ] || [ "$M_CLI" -lt 4 ] || [ "$M_DOCTOR" -lt 4 ]; then
    cant "a denominator came back under 4; every arm below would pass vacuously"
    verdict
fi

# POSITIVE CONTROL, same method, same file: an id we know install.sh records.
# If the awk above were broken it would return a clean empty set and every
# subset check would pass.
if /usr/bin/grep -qx 'third_party_data_personal_records' "$INSTALL_IDS"; then
    ok "POSITIVE CONTROL: the enumerator finds third_party_data_personal_records, so a clean zero would be a real zero"
else
    cant "the enumerator missed an id known to be recorded; its answers cannot be trusted"
    verdict
fi

# NEGATIVE CONTROL: a fabricated id must NOT be found by the same method.
if /usr/bin/grep -qx 'synthetic_tickbox_that_cannot_exist' "$INSTALL_IDS"; then
    cant "the enumerator matched an id that does not exist; it is not reading what it claims"
    verdict
else
    ok "NEGATIVE CONTROL: a fabricated id is absent from the same enumeration"
fi

UNCHECKABLE=""
while read -r id; do
    [ -n "$id" ] || continue
    /usr/bin/grep -qx "$id" "$WORK/cli_ids.txt" || UNCHECKABLE="$UNCHECKABLE cli:$id"
    /usr/bin/grep -qx "$id" "$WORK/doctor_ids.txt" || UNCHECKABLE="$UNCHECKABLE doctor:$id"
done < "$INSTALL_IDS"
if [ -z "$UNCHECKABLE" ]; then
    ok "all $M_INSTALL ids install.sh records are known to the CLI ($M_CLI) AND checkable by Doctor ($M_DOCTOR)"
else
    bad "recordable but not checkable:$UNCHECKABLE"
fi

# ─────────────────────────────────────────────────────────────────────
#  PART 2. THE PERSON: drive the real reuse path into the real registry
# ─────────────────────────────────────────────────────────────────────
#
# run_reuse_install <install.sh to drive> <dashboard_components.py to render>
#                   <"empty"|"prior-accepted"> <output dir>
#
# Writes three files into the output dir:
#   transcript  - what the customer's terminal did, incl. SCREEN_SHOWN
#   registry    - the real consent.json, or absent
#   tile        - the real rendered Doctor consent tile HTML
run_reuse_install() {
    src_install="$1"; src_doctor="$2"; prior="$3"; out="$4"
    mkdir -p "$out"
    home="$out/ostler"
    mkdir -p "$home/.venv/bin"

    # The python install.sh will find. On a reuse install OSTLER_PYTHON is not
    # yet assigned (Phase 3 does that, below this point in the file), so the
    # discovery loop falls to the previous install's venv - exactly the
    # candidate this shim occupies. PYTHONPATH carries the vendored packages
    # the same way the Hub venv carries them on a customer Mac.
    {
        echo '#!/bin/sh'
        echo "PYTHONPATH=\"$REPO/vendor\" exec $PY \"\$@\""
    } > "$home/.venv/bin/python3"
    chmod +x "$home/.venv/bin/python3"

    # The four real constructs, extracted from the install.sh under test. An
    # extraction that comes back empty is the mutation for MUT-A, so emptiness
    # is reported rather than refused here; PART 2's own pristine run asserts
    # the sizes.
    awk '$0=="_ostler_ask_personal_use_terms() {"{f=1} f{print} f&&$0=="}"{exit}' \
        "$src_install" > "$out/fn.sh"
    awk '$0=="if [[ -z \"${OSTLER_CONSENT_PERSONAL_USE_DECISION:-}\" ]]; then"{f=1} f{print} f&&$0=="fi"{exit}' \
        "$src_install" > "$out/reuse.sh"
    awk '$0=="    _consent_cli_record() {"{f=1} f{print} f&&$0=="    }"{exit}' \
        "$src_install" > "$out/recorder_fn.sh"
    awk '$0=="    if [[ -n \"$OSTLER_CONSENT_PERSONAL_USE_DECISION\" ]]; then"{f=1} f{print} f&&$0=="    fi"{exit}' \
        "$src_install" > "$out/recorder_call.sh"

    if [ "$prior" = "prior-accepted" ]; then
        # PYTHONPATH is SET here, not unset: this is the one place the test
        # wants the vendored packages on the path, the same way install.sh runs
        # the CLI from the Hub venv with the vendor root on PYTHONPATH. An
        # explicit assignment overrides whatever the caller inherited, so it
        # does the isolating job `env -u` does elsewhere. It is written as a
        # plain assignment rather than `env -u PYTHONPATH PYTHONPATH=...`
        # because the order in which env applies an unset and an assignment to
        # the SAME name is not something to bet a gate on across BSD and GNU.
        env PYTHONPATH="$REPO/vendor" OSTLER_HOME="$home" "$PY" \
            -m ostler_security.consent_cli record \
            --tickbox personal_use_only --decision accepted \
            --region row --user-id synthetic-prior-user \
            >/dev/null 2>&1 || true
    fi

    {
        echo 'set -uo pipefail'
        echo 'BOLD=""; NC=""; DIM=""'
        # Every MSG_* the screen reads, non-empty so "a screen a person can
        # read" is observable. A screen that renders only empty strings is a
        # screen nobody can read.
        echo 'for v in MSG_TERMS_PERSONAL_USE_HEADING MSG_TERMS_PERSONAL_USE_INTRO \
               MSG_TERMS_PERSONAL_USE_BUSINESS MSG_TERMS_PERSONAL_USE_RECORDER \
               MSG_TERMS_PERSONAL_USE_ASK_HEADING MSG_TERMS_PERSONAL_USE_ASK_1 \
               MSG_TERMS_PERSONAL_USE_ASK_2 MSG_TERMS_PERSONAL_USE_ASK_3 \
               MSG_TERMS_PERSONAL_USE_LEGAL MSG_PROMPT_TERMS_PERSONAL_USE_TITLE \
               MSG_PROMPT_TERMS_PERSONAL_USE_HELP MSG_INFO_TERMS_PERSONAL_USE_DECLINED \
               MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS; do
               eval "$v=\"[${v}]\""; done'
        # gui_read IS the moment a person is asked. Its invocation is the
        # consumer-side event, and "OK" is the person pressing the button.
        echo 'gui_read() { echo "SCREEN_SHOWN" >&2; echo "OK"; }'
        echo 'gui_cancelled() { :; }'
        echo 'ok()   { echo "OK_CALLED:$1" >&2; }'
        echo 'warn() { echo "WARN:$1" >&2; }'
        echo "OSTLER_DIR='$home'"
        echo "OSTLER_HOME='$home'"
        echo "export OSTLER_HOME"
        echo "OSTLER_REGION=row"
        echo "USER_ID=synthetic-reuse-customer"
        echo "OSTLER_CONSENT_PERSONAL_USE_DECISION=''"
        echo 'SKIP_PHASE2=true'
        cat "$out/fn.sh"
        cat "$out/reuse.sh"
        echo 'echo "DECISION=[$OSTLER_CONSENT_PERSONAL_USE_DECISION]" >&2'
        # Phase 3 assigns OSTLER_PYTHON, then the recorder runs. Both halves
        # below are install.sh's own text.
        echo "OSTLER_PYTHON='$home/.venv/bin/python3'"
        cat "$out/recorder_fn.sh"
        cat "$out/recorder_call.sh"
    } > "$out/drive.sh"

    ( cd "$out" && env -u PYTHONPATH OSTLER_HOME="$home" bash "$out/drive.sh" ) \
        > "$out/transcript" 2>&1

    if [ -f "$home/posture/consent.json" ]; then
        cp "$home/posture/consent.json" "$out/registry"
    else
        : > "$out/registry"
    fi

    # The real Doctor tile, rendered by the real vendored function the web UI
    # calls, against the registry the run above actually produced. src_doctor
    # may be a mutant, so it goes FIRST on sys.path.
    env -u PYTHONPATH OSTLER_HOME="$home" "$PY" - > "$out/tile" 2>"$out/tile.err" <<PYEOF
import sys, os
sys.path.insert(0, "$REPO/vendor")
sys.path.insert(0, "$DOCTOR_AGENT")
sys.path.insert(0, os.path.dirname("$src_doctor"))
import dashboard_components as dc
assert os.path.realpath(dc.__file__) == os.path.realpath("$src_doctor"), (
    "rendered the wrong dashboard_components: " + dc.__file__)
sys.stdout.write(dc.render_consent_status())
PYEOF
}

# personal_use_line <tile file> - the tile is HTML; pull the status-detail line
# that belongs to the personal_use_only card.
personal_use_state() {
    awk '/personal_use_only</{f=1; next} f&&/status-detail/{print; exit}' "$1"
}

echo ""
echo "=== part 2: a real reuse install, no prior record ==="
run_reuse_install "$INSTALL_SH" "$DOCTOR_AGENT/dashboard_components.py" empty "$WORK/pristine"
P="$WORK/pristine"

fn_lines=$(/usr/bin/grep -c . "$P/fn.sh" || true)
reuse_lines=$(/usr/bin/grep -c . "$P/reuse.sh" || true)
rec_lines=$(/usr/bin/grep -c . "$P/recorder_fn.sh" || true)
call_lines=$(/usr/bin/grep -c . "$P/recorder_call.sh" || true)
echo "  EXTRACTED from install.sh: screen $fn_lines lines, reuse resolver $reuse_lines, recorder fn $rec_lines, recorder call $call_lines"
if [ "$fn_lines" -lt 10 ] || [ "$reuse_lines" -lt 10 ] || [ "$rec_lines" -lt 10 ] || [ "$call_lines" -lt 4 ]; then
    cant "extraction from the pristine install.sh came back short; the subject is empty"
    verdict
fi

if /usr/bin/grep -q 'SCREEN_SHOWN' "$P/transcript"; then
    ok "(1) THE PERSON IS ASKED: reuse install with no prior record renders the terms"
else
    bad "(1) the customer was never shown the licence terms on the reuse path"
    sed 's/^/                /' "$P/transcript" | tail -8
fi

missing=0
for v in HEADING INTRO BUSINESS RECORDER ASK_1 ASK_2 ASK_3 LEGAL; do
    /usr/bin/grep -q "\[MSG_TERMS_PERSONAL_USE_${v}\]" "$P/transcript" || missing=$((missing+1))
done
if [ "$missing" -eq 0 ]; then
    ok "(2) all 8 of 8 terms strings reach the screen, so it is a screen a person can read"
else
    bad "(2) $missing of 8 terms strings never rendered"
fi

if [ -s "$P/registry" ]; then
    ok "(3) THE ANSWER LANDS: the real consent CLI created a durable registry file"
else
    bad "(3) nothing was written to the durable registry"
fi

if env -u PYTHONPATH "$PY" -c "
import json, sys
r = json.load(open('$P/registry'))['records'].get('personal_use_only')
sys.exit(0 if r and r.get('decision') == 'accepted' else 1)
" 2>/dev/null; then
    ok "(4) and the stored record for personal_use_only reads decision=accepted"
else
    bad "(4) the registry holds no accepted personal_use_only record"
fi

if env -u PYTHONPATH "$PY" -c "
import json, sys
sys.path.insert(0, '$REPO/vendor')
from legal import PERSONAL_USE_ONLY as p
r = json.load(open('$P/registry'))['records']['personal_use_only']
sys.exit(0 if r['wording_hash'] == p.sha256() else 1)
" 2>/dev/null; then
    ok "(5) the stored wording hash is this build's bundled wording, so the record is renewable rather than opaque"
else
    bad "(5) the stored wording hash does not match the bundled PERSONAL_USE_ONLY wording"
fi

STATE="$(personal_use_state "$P/tile")"
if [ -z "$STATE" ]; then
    bad "(6) the Doctor consent tile shows no personal_use_only card at all"
    head -5 "$P/tile.err" | sed 's/^/                /'
else
    echo "  TILE SAYS: $(echo "$STATE" | sed 's/<[^>]*>//g' | sed 's/^ *//')"
    ok "(6) IT IS VISIBLE: the Doctor consent tile carries a personal_use_only card"
fi

case "$STATE" in
    *"current ("*)
        ok "(7) AND IT IS CHECKABLE: the tile reports the acknowledgement CURRENT against the bundled wording" ;;
    *"unknown wording"*)
        bad "(7) the tile renders the licence acknowledgement as 'unknown wording': Doctor cannot check drift on it" ;;
    *)
        bad "(7) the tile reports an unexpected state for personal_use_only: $STATE" ;;
esac

echo ""
echo "=== part 2b: a reuse install that DOES have a current accepted record ==="
run_reuse_install "$INSTALL_SH" "$DOCTOR_AGENT/dashboard_components.py" prior-accepted "$WORK/carry"
C="$WORK/carry"
if /usr/bin/grep -q 'SCREEN_SHOWN' "$C/transcript"; then
    bad "(8) a current accepted record was re-asked; the resolver is not reading the registry at all"
else
    ok "(8) a current accepted record carries forward without re-asking, so arm (1) is not 'always ask'"
fi
if /usr/bin/grep -q 'DECISION=\[accepted\]' "$C/transcript"; then
    ok "(9) and the decision is re-asserted in memory, so THIS run is recorded too"
else
    bad "(9) carried forward but left the decision empty, so this run went unrecorded"
fi

# ─────────────────────────────────────────────────────────────────────
#  PART 3. MUTANTS. Each is APPLIED to a copy, the mutation is ASSERTED
#  PRESENT in the mutated text before anything runs, and only then is the
#  arm re-driven. A mutant that did not apply looks exactly like one that
#  was not caught.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== part 3: mutants (applied, asserted, then driven) ==="

# ---- MUT-A: put the terms back inside the SKIP_PHASE2 guard only ------
# i.e. delete the post-guard reuse resolver. That is the pre-fix world: the
# screen exists, but only the Phase-2 batch reaches it, and the Phase-2 batch
# does not run on a re-install.
MA="$WORK/mutA_install.sh"
awk '
  $0=="if [[ -z \"${OSTLER_CONSENT_PERSONAL_USE_DECISION:-}\" ]]; then" {skip=1}
  skip && $0=="fi" {skip=0; next}
  !skip {print}
' "$INSTALL_SH" > "$MA"
before=$(/usr/bin/grep -c 'OSTLER_CONSENT_PERSONAL_USE_DECISION:-' "$INSTALL_SH" || true)
after=$(/usr/bin/grep -c 'OSTLER_CONSENT_PERSONAL_USE_DECISION:-' "$MA" || true)
echo "  MUT-A applied? reuse-guard occurrences $before -> $after; bytes $(wc -c < "$INSTALL_SH") -> $(wc -c < "$MA")"
if [ "$after" -lt "$before" ] && [ "$(wc -c < "$MA")" -lt "$(wc -c < "$INSTALL_SH")" ]; then
    ok "(10) MUT-A APPLIED: the post-guard reuse resolver is gone from the mutant"
    run_reuse_install "$MA" "$DOCTOR_AGENT/dashboard_components.py" empty "$WORK/mutA"
    A="$WORK/mutA"
    if /usr/bin/grep -q 'SCREEN_SHOWN' "$A/transcript" || [ -s "$A/registry" ]; then
        bad "(11) MUT-A NOT CAUGHT: with the terms back inside the guard the test still went green"
    else
        astate="$(personal_use_state "$A/tile")"
        ok "(11) MUT-A CAUGHT: no screen, empty registry, tile card absent (state='${astate:-none}')"
    fi
else
    cant "(10) MUT-A did not apply; a mutant that did not apply looks exactly like one that was not caught"
fi

# ---- MUT-B: the resolver reports accepted for an unknown record ------
# Exactly the upgrade the fix refuses: treat "we could not find a record" as
# "they accepted". The registry stays empty and the person is never asked.
MB="$WORK/mutB_install.sh"
sed 's/^    _pu_state="unknown"$/    _pu_state="accepted"/' "$INSTALL_SH" > "$MB"
if /usr/bin/grep -q '^    _pu_state="accepted"$' "$MB" && ! /usr/bin/grep -q '^    _pu_state="unknown"$' "$MB"; then
    echo "  MUT-B applied? the resolver's initial state is now 'accepted' at $(/usr/bin/grep -c '^    _pu_state="accepted"$' "$MB") site(s), 'unknown' at 0"
    ok "(12) MUT-B APPLIED: unknown is upgraded to accepted in the mutant"
    run_reuse_install "$MB" "$DOCTOR_AGENT/dashboard_components.py" empty "$WORK/mutB"
    B="$WORK/mutB"
    if /usr/bin/grep -q 'SCREEN_SHOWN' "$B/transcript"; then
        bad "(13) MUT-B NOT CAUGHT: the mutant still asked, so arm (1) is not sensitive to the resolver"
    else
        ok "(13) MUT-B CAUGHT: an unknown record read as accepted means the person is never asked, which arm (1) turns RED"
    fi
else
    cant "(12) MUT-B did not apply; the anchor line has moved"
fi

# ---- MUT-C: Doctor's drift map goes back to the hand-written five ----
MC_DIR="$WORK/mutC_doctor"
mkdir -p "$MC_DIR"
MC="$MC_DIR/dashboard_components.py"
env -u PYTHONPATH "$PY" - <<PYEOF
src = open("$DOCTOR_AGENT/dashboard_components.py").read()
needle = "    bundled = {}\n"
assert needle in src, "MUT-C anchor missing"
patch = (
    "    bundled = {}\n"
    "    _MUTANT_FIVE = ('ARTICLE_9_EU_CONSENT', 'EU_VOICE_SPEAKER_ID_CONSENT',\n"
    "                    'SPOKEN_CAPTURE_RECORDING_CONSENT', 'THIRD_PARTY_DATA_NOTICE',\n"
    "                    'WHATSAPP_UNOFFICIAL_RISK_CONSENT')\n"
)
open("$MC", "w").write(src.replace(needle, patch, 1).replace(
    'for name in getattr(legal, "__all__", ()):',
    'for name in _MUTANT_FIVE:', 1))
PYEOF
if /usr/bin/grep -q '_MUTANT_FIVE' "$MC" && /usr/bin/grep -q 'for name in _MUTANT_FIVE:' "$MC"; then
    echo "  MUT-C applied? drift map now iterates a hand-written tuple of 5, not legal.__all__"
    ok "(14) MUT-C APPLIED: the Doctor drift map is back to five hand-written names"
    run_reuse_install "$INSTALL_SH" "$MC" empty "$WORK/mutC"
    Cm="$WORK/mutC"
    cstate="$(personal_use_state "$Cm/tile")"
    case "$cstate" in
        *"unknown wording"*)
            ok "(15) MUT-C CAUGHT: the licence acknowledgement renders 'unknown wording', which arm (7) turns RED" ;;
        *)
            bad "(15) MUT-C NOT CAUGHT: with the five-name map the tile still said '${cstate:-none}'" ;;
    esac
else
    cant "(14) MUT-C did not apply; the dashboard_components anchor has moved"
fi

verdict
