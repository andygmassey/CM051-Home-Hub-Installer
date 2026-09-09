#!/usr/bin/env bash
# scripts/box_walk_probes/lib/usage_seed.sh
# ============================================================================
# THE USAGE SEED. Run the installer's OWN people sweep once, by hand, before
# the probes read the usage journal, so the cm051_ostler_fda_ingest producer
# has had a chance to write and its absence means something.
#
# WHY THIS FILE EXISTS, MEASURED
#
# usage_journal_producers declares five required producers in
# scripts/usage_journal_producers.tsv and reads the journal the daemon writes.
# On v1.0.81 cm051_ostler_fda_ingest was ABSENT from a journal that held 557
# parsed rows, and the reason was not the writer:
#
#   - the writer IS vendored. vendor/ostler_fda/pwg_ingest.py:50 mints
#     _USAGE_SESSION_ID = "ostler-fda-ingest-<hex>" once per process, and
#     tests/test_vendored_fda_writes_the_usage_journal.sh proves the write BY
#     EXECUTION rather than by grep.
#   - the row is written ONLY on a MEASURED embedding call.
#     _record_embed_usage (pwg_ingest.py:53-73) returns without writing when
#     tokens_from_ollama yields neither count (:64-66), and record_usage
#     (usage_journal.py:200-203) writes nothing when both counts are absent or
#     zero. That is the contract's hard rule, not a bug.
#   - of the nine _INGEST_DISPATCH entries only four reach the embedder, and
#     ingest_people_to_qdrant (pwg_ingest.py:2515) is the one with guaranteed
#     input on a wiped box: it reads pwg:Person out of Oxigraph, not the FDA
#     JSON that ttywalk's --reset removes.
#   - on the v1.0.81 walk that leg was SKIPPED. ttywalk --reset cleared
#     ~/.ostler/imports but not ~/.ostler/state, so the previous install's
#     status=ok hydrate sentinels survived and _hydrate_sentinel_fresh
#     (install.sh:26392-26413) skipped the people leg at install.sh:29374 for
#     seven days.
#
# So the probe was reading a journal from an install that never made the call.
# A producer that was never exercised and a producer that is broken print the
# same thing, which is the same one-face-three-faults shape grounding_seed.sh
# and preference_seed.sh were each built to break.
#
# WHAT IT RUNS. Byte-for-byte the command install.sh runs at :29420-29424,
# under the same interpreter (install.sh:29372,
# ~/.ostler/services/email-ingest/.venv/bin/python) and as the same user the
# rest of the walk reaches the box as. Nothing synthetic is written: the sweep
# is the product's own, the embeddings are real, the rows are real, and the
# point ids derive from the person URI (pwg_ingest.py:2533) so re-running it
# is idempotent.
#
# ⚠️ THE GOLDEN-CASE HAZARD, IN THE ROSTER'S OWN WORDS. This step converts the
# probe from "the install exercises the ingest" to "the ingest CAN write when
# run by hand". scripts/usage_journal_producers.tsv:10-24 records why that
# distinction is the whole point of the roster, and its cm051 row says it
# outright: ABSENT means "no measured call happened", NOT "the writer is
# missing". So this step SAYS SO IN ITS OWN OUTPUT, every time it runs, and
# the walk record must be read knowing it.
#
# THE MEASUREMENT ORDER, AND WHY THE ASSUMPTION IS STILL MEASURED FIRST
#
# The field HAS been observed, once, and the observation is what this paragraph
# used to deny. Measured on the walk box as archie, 2026-09-09T17:42:35Z,
# Ollama 0.33.3: the install healthcheck body returns prompt_eval_count 5 as an
# int, and a three-item batch returns 15. Before that the only valued
# occurrence anywhere in this repo was a hand-written dict in
# tests/test_vendored_fda_writes_the_usage_journal.sh.
#
# ONE OBSERVATION ON ONE BOX IS NOT A PROPERTY OF EVERY BOX, so the step still
# measures it on every walk rather than citing the line above. The model, the
# Ollama build and the endpoint can all move under us, and when they do the
# consequence is total: if this runtime does not report a USABLE count,
# pwg_ingest.py:65-66 fires and NO seed, fixture or code change can make ANY
# embed-based producer write a row. That is a fact about the runtime, not a
# product defect and not a walk failure, so it is measured BEFORE anything else
# and reported as a named CANNOT-RUN.
#
# The request POSTed is the one install.sh:18760-18763 already sends on every
# install: same endpoint, same model, same body. Only the RESPONSE KEY LIST is
# printed. The vector never is.
#
# THE VERDICT IS THE JOURNAL DELTA, NEVER THE SWEEP'S EXIT CODE. install.sh
# wraps the same call in a #640-class guard (:29417, :29429) precisely because
# an in-subshell crash there must degrade rather than abort, so its rc is a
# statement about the harness. The rows counted before and after are the
# measurement.
#
# THE RULE THIS FILE OBEYS, THE SAME ONE THE OTHER TWO SEEDS OBEY: A SEED THAT
# DID NOT WORK MUST NOT LOOK LIKE A PRODUCT DEFECT. Every return-1 path prints
# a line beginning CANNOT-RUN or FINDING, so a reader never has to infer which
# of the two it was.
#
# ENV
#   OSTLER_USAGE_SEED_SKIP=1   do not run the sweep. Prints that it was
#                              skipped, and that skipping is not a pass.
#   OSTLER_USAGE_JOURNAL       honoured because the journal path is resolved by
#                              the PROBE, not by a second copy of its resolver.
#   OSTLER_BOX_HOST            unset means this machine, per the suite contract.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile. Every remote
# program is POSIX sh: it is run by /bin/sh here and by the box's login shell
# over ssh, and neither is guaranteed to be bash.
# ============================================================================

USAGE_SEED_STATE="unrun"   # unrun|skipped|no-counts|cannot-run|finding|seeded
USAGE_SEED_BEFORE=""
USAGE_SEED_AFTER=""
USAGE_SEED_DELTA=""
USAGE_SEED_JOURNAL=""
USAGE_SEED_SWEEP=""

# The producer's session_id prefix, from vendor/ostler_fda/pwg_ingest.py:50 and
# declared in scripts/usage_journal_producers.tsv column match_value. Written
# here as a literal rather than parsed out of the roster so that a roster edit
# and this step cannot silently agree with each other about a prefix neither
# producer uses.
_US_SESSION_PREFIX="ostler-fda-ingest-"

# The ssh invocation the probes and the other two seeds use. Kept identical on
# purpose: a seed that reaches a different box than the probes measure would be
# worse than no seed.
_us_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# ---------------------------------------------------------------------------
# 1. THE UNMEASURED ASSUMPTION, MEASURED.
#
# POST the healthcheck install.sh:18760-18763 already sends, and read the KEY
# LIST off the response. The predicate is not "prompt_eval_count appears" but
# the one usage_journal.py:257-264 actually applies: a count is usable only
# when it is a positive int and not a bool, so a present-but-zero field is
# reported as present AND unusable rather than as a pass.
#
# stderr is NOT suppressed. A probe that hides the transport's own complaint
# turns "could not ask" into "asked and got nothing", which is the difference
# between a CANNOT-RUN and a finding.
# ---------------------------------------------------------------------------
USAGE_SEED_EMBED=""
_us_measure_embed() {
    USAGE_SEED_EMBED=""
    _us_out="$(_us_box_exec '
b=$(mktemp) || { echo "USEED-NO-MKTEMP"; exit 2; }
c=$(curl -s --max-time 90 -o "$b" -w "%{http_code}" \
    -X POST http://localhost:11434/api/embed \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"nomic-embed-text\",\"input\":\"healthcheck\"}")
rc=$?
echo "CURL_RC $rc"
echo "HTTP $c"
if [ "$rc" -ne 0 ]; then
    rm -f "$b"
    exit 0
fi
python3 -c "
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception as exc:
    print(\"KEYS unreadable \" + type(exc).__name__)
    sys.exit(0)
if not isinstance(doc, dict):
    print(\"KEYS not-a-json-object\")
    sys.exit(0)
print(\"KEYS \" + \",\".join(sorted(doc.keys())))
def usable(k):
    v = doc.get(k)
    return isinstance(v, int) and not isinstance(v, bool) and v > 0
for k in (\"prompt_eval_count\", \"eval_count\"):
    print(\"FIELD \" + k + \" \" + (\"present\" if k in doc else \"absent\") + \" \" + (\"usable\" if usable(k) else \"unusable\"))
print(\"MEASURABLE \" + (\"yes\" if (usable(\"prompt_eval_count\") or usable(\"eval_count\")) else \"no\"))
" "$b"
rm -f "$b"
' 2>&1)"
    _us_rc=$?
    USAGE_SEED_EMBED="${_us_out}"
    return ${_us_rc}
}

# ---------------------------------------------------------------------------
# THE JOURNAL PATH IS RESOLVED BY THE PROBE, NOT BY A SECOND RESOLVER.
#
# probes/usage_journal_producers.sh carries the four-branch resolver that
# mirrors zeroclaw-config/src/schema.rs::resolve_runtime_config_dirs, and it
# exposes it as `--print-journal-path` for exactly this reason. Copying it here
# would make two resolvers that can disagree, and a seed that counted rows in a
# different file than the probe reads would be worse than no seed: it would
# report SEEDED while the probe still saw nothing.
# ---------------------------------------------------------------------------
_us_resolve_journal() {
    _us_probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/probes/usage_journal_producers.sh"
    [ -f "${_us_probe}" ] || return 2
    bash "${_us_probe}" --print-journal-path
}

# ---------------------------------------------------------------------------
# COUNT THE PRODUCER'S OWN ROWS, ON THE BOX.
#
# Prints "<rows> <unparseable>", and "-1 0" when the file does not exist --
# an absent journal and an empty one are different facts and must not print
# identically. Counted by JSON parse rather than by grep, because a record is
# written by json.dumps and a grep for a quoted key would depend on separator
# spacing that nothing pins.
#
# No `grep -c` anywhere: it prints its count AND exits 1 on zero, so the
# obvious `grep -c ... || echo 0` yields "0\n0" and the caller reads the wrong
# number.
# ---------------------------------------------------------------------------
_us_count_rows() {
    _us_box_exec 'p="'"${1}"'"
python3 -c "
import json, sys
try:
    fh = open(sys.argv[1])
except Exception:
    print(-1, 0)
    sys.exit(0)
n = 0
bad = 0
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        bad += 1
        continue
    if not isinstance(rec, dict):
        bad += 1
        continue
    sid = rec.get(sys.argv[2])
    if isinstance(sid, str) and sid.startswith(sys.argv[3]):
        n += 1
print(n, bad)
" "$p" session_id '"${_US_SESSION_PREFIX}"'
'
}

# ---------------------------------------------------------------------------
# THE INSTALLER'S OWN COMMAND, BYTE FOR BYTE.
#
# install.sh:29420-29424, under the interpreter it resolves at :29372. The
# python body below is the installer's, character for character; only the
# shell variable holding the interpreter path is named differently, because
# _HYDRATE_PEOPLE_PY is a local of that install step and does not exist here.
#
# Exits 3 with USEED-NO-VENV when the interpreter is absent, which is the
# same test install.sh makes at :29376 before it will run the leg at all.
# ---------------------------------------------------------------------------
_us_run_sweep() {
    _us_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
PY="$O/services/email-ingest/.venv/bin/python"
if [ ! -x "$PY" ]; then
    echo "USEED-NO-VENV $PY"
    exit 3
fi
"$PY" -c "
import json
from ostler_fda.pwg_ingest import ingest_people_to_qdrant
result = ingest_people_to_qdrant()
print(json.dumps(result))
"
'
}

# Read the counts-only dict the sweep printed. Prints "<status> <sent> <total>".
# Local, so a heredoc-free single-quoted python is safe here.
_us_read_dict() {
    printf '%s' "${1}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print("unparseable - -")
    sys.exit(0)
if not isinstance(d, dict):
    print("not-an-object - -")
    sys.exit(0)
print("%s %s %s" % (d.get("status", "-"), d.get("sent", "-"), d.get("total", "-")))
'
}

# ---------------------------------------------------------------------------
# THE STEP. Sourced and called by run_box_walk.sh in the caller's own shell,
# beside the other two seeds and for the same reason: this is the last moment
# before anything is measured, and ttywalk.sh does not invoke this runner at
# all (measured: zero references), so a step wired there would never reach it.
#
# Returns 0 only on a positive journal delta. Returns 1 otherwise, and EVERY
# return-1 path prints a line beginning CANNOT-RUN or FINDING.
# ---------------------------------------------------------------------------
usage_seed_apply() {
    printf -- '--- USAGE SEED: the people sweep, run once by hand, before the journal is read ---\n'

    # SAID EVERY TIME, INCLUDING ON THE PATHS THAT MEASURE NOTHING. The record
    # this walk produces is read by people who were not here, and the roster
    # (scripts/usage_journal_producers.tsv:10-24) exists because a golden case
    # cannot give a denominator.
    printf '  THIS STEP RE-RUNS THE PRODUCT OWN PEOPLE SWEEP BY HAND, and the record\n'
    printf '  must be read knowing it: a row from this seed proves the producer CAN\n'
    printf '  write on this runtime, NOT that the install exercised it unaided.\n'

    if [ "${OSTLER_USAGE_SEED_SKIP:-0}" = "1" ]; then
        USAGE_SEED_STATE="skipped"
        printf '  CANNOT-RUN: skipped by OSTLER_USAGE_SEED_SKIP=1. The sweep was not run\n'
        printf '  and no journal row was measured. That is not a pass.\n\n'
        return 1
    fi

    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        printf '  target: this machine (OSTLER_BOX_HOST unset)\n'
    else
        printf '  target: %s\n' "${OSTLER_BOX_HOST}"
    fi

    # -- 1. the assumption, before anything is built on it --------------------
    _us_measure_embed
    _us_erc=$?
    printf '%s\n' "${USAGE_SEED_EMBED}" | sed 's/^/    /'
    if [ "${_us_erc}" -ne 0 ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: the embed healthcheck could not be made at all (transport\n'
        printf '  exit %s). Nothing was swept and nothing was measured.\n' "${_us_erc}"
        printf '\n'
        return 1
    fi
    # THREE DIFFERENT ABSENCES, THREE DIFFERENT ANSWERS. A missing curl, a
    # refused connection and a runtime that answers without counts all end with
    # no MEASURABLE line, and reading them as one would report "this runtime
    # cannot measure" about a box nobody asked. Each is named separately.
    _us_curl_rc="$(printf '%s\n' "${USAGE_SEED_EMBED}" | sed -n 's/^CURL_RC \(.*\)$/\1/p' | head -1)"
    _us_http="$(printf '%s\n' "${USAGE_SEED_EMBED}" | sed -n 's/^HTTP \(.*\)$/\1/p' | head -1)"
    if [ -z "${_us_curl_rc}" ] || [ "${_us_curl_rc}" != "0" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: the embed request itself did not complete (curl exit\n'
        printf '  [%s]). 127 means no curl on the box; 7 means nothing is listening on\n' "${_us_curl_rc}"
        printf '  11434. Either way the runtime was not asked, so nothing here says\n'
        printf '  whether it can report token counts. Nothing was swept.\n\n'
        return 1
    fi
    if [ "${_us_http}" != "200" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: /api/embed answered HTTP %s, not 200. install.sh:18765\n' "${_us_http}"
        printf '  hard-fails an install on exactly this, so a box in this state has\n'
        printf '  more wrong with it than the usage journal. Nothing was swept.\n\n'
        return 1
    fi
    case "${USAGE_SEED_EMBED}" in
        *"KEYS "*) : ;;
        *)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the response came back 200 and could not be READ, so no\n'
            printf '  key list exists to judge. The usual cause is no python3 on the box,\n'
            printf '  and that is a statement about the harness, not the runtime.\n\n'
            return 1
            ;;
    esac
    case "${USAGE_SEED_EMBED}" in
        *"MEASURABLE yes"*) : ;;
        *)
            USAGE_SEED_STATE="no-counts"
            printf '  CANNOT-RUN: this runtime returned NO USABLE TOKEN COUNT on\n'
            printf '  /api/embed. usage_journal.py:257-264 accepts a count only when it\n'
            printf '  is a positive int, and pwg_ingest.py:65-66 returns without writing\n'
            printf '  when neither count survives that test. So NO embed-based producer\n'
            printf '  can write a row on this runtime -- not this seed, not the install,\n'
            printf '  not the launchd tick. The key list above is the evidence.\n'
            printf '  This is a fact about the runtime, NOT a product defect and NOT a\n'
            printf '  walk failure. Nothing was swept.\n\n'
            return 1
            ;;
    esac
    printf '  the runtime reports a usable token count, so a row is possible here\n'

    # -- 2. the journal, before ----------------------------------------------
    USAGE_SEED_JOURNAL="$(_us_resolve_journal)"
    _us_jrc=$?
    # A MISSING PROBE AND A SILENT RESOLVER ARE DIFFERENT FACTS. Both end with
    # no path, and printing one message for the pair would send the reader to
    # debug a resolver that is not there.
    if [ "${_us_jrc}" -eq 2 ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: probes/usage_journal_producers.sh is not beside this lib,\n'
        printf '  so there is no resolver to ask. That is a checkout problem, not a box\n'
        printf '  problem. Nothing was swept.\n\n'
        return 1
    fi
    if [ -z "${USAGE_SEED_JOURNAL}" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: the probe own resolver returned no journal path, so no\n'
        printf '  file was even named. Nothing was swept.\n\n'
        return 1
    fi
    printf '  journal on box : %s\n' "${USAGE_SEED_JOURNAL}"

    _us_before_raw="$(_us_count_rows "${USAGE_SEED_JOURNAL}")"
    _us_brc=$?
    if [ "${_us_brc}" -ne 0 ] || [ -z "${_us_before_raw}" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: could not count the journal BEFORE the sweep (exit %s).\n' "${_us_brc}"
        printf '  A delta needs both ends. Nothing was swept.\n'
        printf '%s\n' "${_us_before_raw}" | sed 's/^/    /'
        printf '\n'
        return 1
    fi
    USAGE_SEED_BEFORE="${_us_before_raw%% *}"
    _us_before_bad="${_us_before_raw##* }"
    case "${USAGE_SEED_BEFORE}" in
        -1) printf '  before : the journal does not exist yet on the box\n'; _us_before_n=0 ;;
        ''|*[!0-9]*)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the BEFORE count came back as [%s], which is not a\n' "${USAGE_SEED_BEFORE}"
            printf '  number. Nothing was swept.\n\n'
            return 1
            ;;
        *) printf '  before : %s row(s) with session_id starting %s (%s unparseable line(s))\n' \
               "${USAGE_SEED_BEFORE}" "${_US_SESSION_PREFIX}" "${_us_before_bad}"
           _us_before_n="${USAGE_SEED_BEFORE}" ;;
    esac

    # -- the sweep ------------------------------------------------------------
    printf '  running install.sh:29420-29424 verbatim (ingest_people_to_qdrant)\n'
    _us_sweep_out="$(_us_run_sweep 2>&1)"
    _us_src=$?
    printf '%s\n' "${_us_sweep_out}" | sed 's/^/    /'

    case "${_us_sweep_out}" in
        *USEED-NO-VENV*)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the email-ingest venv interpreter is absent on the box,\n'
            printf '  which is the same condition install.sh:29376 tests before it will\n'
            printf '  run this leg at all. The sweep did not run, so the journal says\n'
            printf '  nothing about the producer either way.\n\n'
            return 1
            ;;
    esac

    # install.sh reads the LAST line of this command (:29425, `| tail -n 1`),
    # because the interpreter may print warnings first. Same reading here.
    _us_json="$(printf '%s\n' "${_us_sweep_out}" | tail -n 1)"
    USAGE_SEED_SWEEP="$(_us_read_dict "${_us_json}")"
    _us_status="$(printf '%s' "${USAGE_SEED_SWEEP}" | cut -d' ' -f1)"
    _us_sent="$(printf '%s' "${USAGE_SEED_SWEEP}" | cut -d' ' -f2)"
    _us_total="$(printf '%s' "${USAGE_SEED_SWEEP}" | cut -d' ' -f3)"
    printf '  sweep  : exit %s, status %s, sent %s, total %s\n' \
        "${_us_src}" "${_us_status}" "${_us_sent}" "${_us_total}"

    if [ "${_us_status}" = "unparseable" ] || [ "${_us_status}" = "not-an-object" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: the sweep printed no counts-only dict, so it did not reach\n'
        printf '  its own return statement. An import failure, a missing module or a\n'
        printf '  crash reads exactly like this; the output above is the reason.\n'
        printf '  THE EXIT CODE IS NOT THE VERDICT and is not being read as one: there\n'
        printf '  is simply nothing to compare, because the sweep produced no result.\n\n'
        return 1
    fi

    # -- 3. the journal, after ------------------------------------------------
    _us_after_raw="$(_us_count_rows "${USAGE_SEED_JOURNAL}")"
    _us_arc=$?
    if [ "${_us_arc}" -ne 0 ] || [ -z "${_us_after_raw}" ]; then
        USAGE_SEED_STATE="cannot-run"
        printf '  CANNOT-RUN: could not count the journal AFTER the sweep (exit %s), so\n' "${_us_arc}"
        printf '  the delta has only one end. The sweep DID run; what it wrote is\n'
        printf '  unmeasured.\n\n'
        return 1
    fi
    USAGE_SEED_AFTER="${_us_after_raw%% *}"
    _us_after_bad="${_us_after_raw##* }"
    case "${USAGE_SEED_AFTER}" in
        -1) _us_after_n=0; printf '  after  : the journal still does not exist\n' ;;
        ''|*[!0-9]*)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the AFTER count came back as [%s], which is not a\n' "${USAGE_SEED_AFTER}"
            printf '  number. The sweep ran and its effect is unmeasured.\n\n'
            return 1
            ;;
        *) _us_after_n="${USAGE_SEED_AFTER}"
           printf '  after  : %s row(s) with session_id starting %s (%s unparseable line(s))\n' \
               "${USAGE_SEED_AFTER}" "${_US_SESSION_PREFIX}" "${_us_after_bad}" ;;
    esac

    USAGE_SEED_DELTA=$(( _us_after_n - _us_before_n ))
    printf '  delta  : %s row(s)\n' "${USAGE_SEED_DELTA}"

    # THE DELTA IS THE MEASUREMENT. The sweep's exit code is reported above and
    # is deliberately not consulted here: install.sh wraps the identical call in
    # a #640-class guard so that an in-subshell crash degrades instead of
    # aborting, which makes its rc a statement about the harness.
    if [ "${USAGE_SEED_DELTA}" -gt 0 ]; then
        USAGE_SEED_STATE="seeded"
        printf '  SEEDED AND MEASURED: the producer wrote %s row(s) into the journal on\n' "${USAGE_SEED_DELTA}"
        printf '  a real embedding call. cm051_ostler_fda_ingest is present for\n'
        printf '  usage_journal_producers to find.\n'
        printf '  READ IT WITH THE CAVEAT AT THE TOP OF THIS BLOCK: this proves the\n'
        printf '  producer CAN write on this runtime, not that the install did it.\n\n'
        return 0
    fi

    if [ "${USAGE_SEED_DELTA}" -lt 0 ]; then
        USAGE_SEED_STATE="finding"
        printf '  FINDING: the journal LOST %s row(s) across the sweep. Something\n' "${USAGE_SEED_DELTA}"
        printf '  truncated or rotated the file while the product was writing to it,\n'
        printf '  which is a finding about the journal and not about the producer.\n\n'
        return 1
    fi

    case "${_us_status}" in
        ok)
            USAGE_SEED_STATE="finding"
            printf '  FINDING: THE SWEEP RAN AND THE PRODUCER DID NOT WRITE. It reported\n'
            printf '  status ok with sent %s of total %s, the runtime returns a usable\n' "${_us_sent}" "${_us_total}"
            printf '  token count (measured above, on this box, minutes ago), and the\n'
            printf '  journal gained zero rows carrying %s.\n' "${_US_SESSION_PREFIX}"
            printf '  That is the one outcome here that is a real finding rather than a\n'
            printf '  coverage gap, and it belongs to the writer path: pwg_ingest.py:1451\n'
            printf '  records per CHUNK before Qdrant is touched, so a store failure\n'
            printf '  cannot explain it.\n\n'
            return 1
            ;;
        no_data)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the sweep found NO people to embed (status no_data), so\n'
            printf '  it made no model call and owed no row. pwg_ingest.py:2553-2555\n'
            printf '  returns this when Oxigraph holds no pwg:Person with a display name.\n'
            printf '  Nothing is measured about the producer; the box has nothing for it\n'
            printf '  to work on.\n\n'
            return 1
            ;;
        *)
            USAGE_SEED_STATE="cannot-run"
            printf '  CANNOT-RUN: the sweep reported status %s, so it did not complete\n' "${_us_status}"
            printf '  the embedding pass that would have written a row. Its own output is\n'
            printf '  above. Nothing is measured about the producer.\n\n'
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# NOTHING TO FORGET, AND THAT IS ITSELF WORTH PRINTING.
#
# The other two seeds remove what they wrote, because they wrote a synthetic
# person and a synthetic preference pair. This one wrote neither. It ran the
# product's own sweep over the box's own graph; the Qdrant points are the ones
# the install would have made, keyed on the person URI so a re-run overwrites
# rather than duplicates (pwg_ingest.py:2533), and the journal rows are real
# measurements of real model calls. Deleting them would be falsifying the
# journal, which is the exact thing the contract's measured-never-estimated
# rule exists to prevent.
#
# Called after phase 2 beside the other two forgets, and never fails the walk.
# ---------------------------------------------------------------------------
usage_seed_forget() {
    case "${USAGE_SEED_STATE}" in
        seeded|finding) : ;;
        *) return 0 ;;
    esac
    printf -- '--- USAGE SEED: nothing to remove ---\n'
    printf '  The sweep is idempotent and the rows it wrote are real measurements of\n'
    printf '  real model calls, so there is nothing synthetic to take back. Deleting\n'
    printf '  them would falsify the journal the customer panel is compiled from.\n\n'
    return 0
}
