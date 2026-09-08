#!/usr/bin/env bash
# scripts/box_walk_probes/lib/grounding_seed.sh
# ============================================================================
# THE GROUNDING SEED. Put a known person into the box's graph before the
# blocking probe asks about one.
#
# WHY THIS FILE EXISTS, MEASURED
#
# assistant_answers_grounded is BLOCKING. Its content assertion, the only arm
# that catches a confident wrong answer, exists only when the probe is given
# a person and a fact to expect:
#
#     EXPECT_FACT="${OSTLER_GATE_EXPECT_FACT:-}"      (the probe, ~line 128)
#     KNOWN_PERSON="${OSTLER_GATE_KNOWN_PERSON:-}"
#     [ -n "$EXPECT_FACT" ] && printf ... >> "$_qfile"  (the seeded turn)
#
# Nothing set those. A bare `ttywalk.sh --reset` installs a box with an empty
# graph and then runs the probe against it with no fixture, so the probe asks
# its three unseeded questions, none of which can reach a person who is not
# there. That is not a hypothesis: it is the configuration recorded FAILED in
# walks/v1.0.74.tsv, and the probe has passed exactly once, on v1.0.75, when
# the seed was run by hand first.
#
# So the walk seeds the box itself, in the one place that knows both the box
# and the probes: the runner, immediately before it measures anything.
#
# WHAT IT RUNS. OS003 gates/seed/load_seed.py, which is the seed oracle of
# record. It writes through the product's own route (POST /api/v1/memory/assert
# on the people API) and then PROVES the fact is readable on the route the
# daemon reads (GET /api/v1/people/context). It is not a fixture written into
# a store behind the product's back.
#
# WHY IT RUNS ON THE BOX. The people API binds 127.0.0.1 and rejects a
# non-loopback Host header as rebind defence, so it cannot be driven from the
# operator's machine. Both files are shipped to the box and run there, the
# same way every other probe reaches the box.
#
# THE RULE THIS FILE OBEYS: A SEED THAT DID NOT WORK MUST NOT LOOK LIKE A
# PRODUCT DEFECT. The gate variables are exported ONLY when the loader exits 0,
# which is its "seeded AND proven readable" code. On exit 1 (the person is
# there, the fact is not readable) or exit 2 (CANNOT-RUN: no token, 401,
# transport) nothing is exported and the loader's own reason is printed. The
# probe then runs unseeded, exactly as it does today, and the walk carries a
# visible line saying why rather than a silent skip. Exporting a fact the box
# cannot serve would convert a harness failure into a FAIL against the product.
#
# ENV
#   OSTLER_SEED_DIR          path to the OS003 gates/seed directory. Set this
#                            when the search below cannot find it.
#   OSTLER_SEED_SKIP=1       do not seed at all. Prints that it was skipped.
#   OSTLER_SEED_KEEP=1       leave the synthetic person on the box afterwards.
#   OSTLER_GATE_KNOWN_PERSON already set, with OSTLER_GATE_EXPECT_FACT: the
#   OSTLER_GATE_EXPECT_FACT  operator is keying the probe off a real contact.
#                            Both are honoured and nothing is seeded.
#   OSTLER_BOX_HOST          unset means this machine, per the suite contract.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

# Set by grounding_seed_apply so the caller and the forget step can read what
# happened without re-deriving it.
GROUNDING_SEED_STATE="unrun"   # unrun | seeded | skipped | absent | failed
GROUNDING_SEED_DIR=""

# The ssh invocation the probes use. Kept identical on purpose: a seed that
# reaches a different box than the probes measure would be worse than no seed.
_gs_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# Same, with a payload on stdin. Separate because the probes' box_exec has no
# `ssh -n` and consumes stdin, which is a trap this suite has already paid for
# once; here the consumption is deliberate and is the transport.
_gs_box_exec_stdin() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# A CHECKOUT ON THE WRONG BRANCH IS THE TRAP HERE, not a missing file.
#
# Until 2026-09-08 load_seed.py wrote a markdown person-note into a vault
# nothing on the product reads, and verified it by polling an endpoint that
# answers 401 without a token. It could not succeed on any recent build, and
# it failed by TIMING OUT, which reads like a slow box rather than a wrong
# tool. OS003 #237 replaced it with the product write route. So a candidate
# qualifies only if its loader carries that route: the marker is content the
# working loader must have, not a filename or a version string that a stale
# copy would also carry.
_gs_loader_is_current() {
    grep -q 'api/v1/memory/assert' "$1"
}

# Where the OS003 seed oracle lives. Explicit env first, then the places a
# working checkout actually sits, and then nothing: a guess that finds the
# wrong file is worse than an honest miss. ~/Developer is tried before
# ~/Documents/Projects because the latter is under iCloud on this estate and
# an evicted file reads as empty rather than as missing.
GROUNDING_SEED_STALE=""
# SETS GROUNDING_SEED_DIR, rather than echoing it. It must not be called in a
# command substitution: GROUNDING_SEED_STALE is set on the reject path, and a
# subshell would discard it, so a stale checkout would report as a missing one
# and the operator would be told to set a variable that is already correct.
# Caught by this file's own test.
_gs_find_seed_dir() {
    GROUNDING_SEED_DIR=""
    GROUNDING_SEED_STALE=""
    if [ -n "${OSTLER_SEED_DIR:-}" ]; then
        if [ -f "${OSTLER_SEED_DIR}/load_seed.py" ] \
            && [ -f "${OSTLER_SEED_DIR}/seed_fixture.json" ]; then
            if _gs_loader_is_current "${OSTLER_SEED_DIR}/load_seed.py"; then
                GROUNDING_SEED_DIR="${OSTLER_SEED_DIR}"
                return 0
            fi
            GROUNDING_SEED_STALE="${OSTLER_SEED_DIR}"
        fi
        return 1
    fi
    _gs_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _gs_repo="$(cd "${_gs_here}/../../.." && pwd)"
    for _gs_c in \
        "${_gs_repo}/../OS003-Ostler-Release/gates/seed" \
        "${_gs_repo}/../OS003 - Ostler Release/gates/seed" \
        "${HOME}/Developer/OS003-Ostler-Release/gates/seed" \
        "${HOME}/Documents/Projects/OS003 - Ostler Release/gates/seed"
    do
        if [ -f "${_gs_c}/load_seed.py" ] && [ -f "${_gs_c}/seed_fixture.json" ]; then
            if _gs_loader_is_current "${_gs_c}/load_seed.py"; then
                GROUNDING_SEED_DIR="$(cd "${_gs_c}" && pwd)"
                return 0
            fi
            [ -n "${GROUNDING_SEED_STALE}" ] || GROUNDING_SEED_STALE="${_gs_c}"
        fi
    done
    return 1
}

# One value out of the fixture, by JSON parse rather than by grep, so a
# reformatted fixture cannot quietly yield an empty gate variable.
_gs_fixture_value() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
    print(doc["gate"][sys.argv[2]])
except Exception:
    sys.exit(1)
PY
}

# Run the loader on the box. $1 = seed dir, $2... = loader arguments.
# Prints the loader's own output. Returns the loader's own exit code, or 2
# when the transport itself failed, which is the loader's CANNOT-RUN code and
# is the correct reading of "we could not ask".
_gs_run_loader() {
    _gs_dir="$1"; shift
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        python3 "${_gs_dir}/load_seed.py" "$@" "${_gs_dir}/seed_fixture.json"
        return $?
    fi

    # Both files travel as ONE base64 JSON blob on stdin. Not scp, so no second
    # credential path; not `base64 -d`, whose decode flag differs between the
    # BSD and GNU spellings; python3 is already a hard requirement of the
    # loader itself, so decoding with it adds no new dependency to the box.
    _gs_payload="$(python3 - "${_gs_dir}/load_seed.py" "${_gs_dir}/seed_fixture.json" <<'PY'
import base64, json, sys
files = {}
for path, name in ((sys.argv[1], "load_seed.py"), (sys.argv[2], "seed_fixture.json")):
    with open(path, encoding="utf-8") as fh:
        files[name] = fh.read()
print(base64.b64encode(json.dumps(files).encode("utf-8")).decode("ascii"))
PY
)" || return 2

    _gs_args=""
    for _gs_a in "$@"; do _gs_args="${_gs_args} ${_gs_a}"; done

    printf '%s' "${_gs_payload}" | _gs_box_exec_stdin '
d=$(mktemp -d) || exit 2
python3 -c "
import base64, json, os, sys
files = json.loads(base64.b64decode(sys.stdin.read()))
for name, body in files.items():
    with open(os.path.join(sys.argv[1], name), \"w\", encoding=\"utf-8\") as fh:
        fh.write(body)
" "$d" || { rm -rf "$d"; exit 2; }
python3 "$d/load_seed.py"'"${_gs_args}"' "$d/seed_fixture.json"
rc=$?
rm -rf "$d"
exit $rc
'
}

# ---------------------------------------------------------------------------
# THE STEP. Sourced and called by run_box_walk.sh in the caller's own shell,
# because its whole purpose is to export into the environment the probes
# inherit. Returns 0 when the gate variables are exported, 1 otherwise.
# ---------------------------------------------------------------------------
grounding_seed_apply() {
    printf -- '--- GROUNDING SEED: a known person, before the grounded probe asks ---\n'

    if [ "${OSTLER_SEED_SKIP:-0}" = "1" ]; then
        GROUNDING_SEED_STATE="skipped"
        printf '  SKIPPED by OSTLER_SEED_SKIP=1.\n'
        printf '  assistant_answers_grounded will run UNSEEDED: three questions, no\n'
        printf '  content assertion. That is the v1.0.74 configuration.\n\n'
        return 1
    fi

    if [ -n "${OSTLER_GATE_EXPECT_FACT:-}" ] && [ -n "${OSTLER_GATE_KNOWN_PERSON:-}" ]; then
        GROUNDING_SEED_STATE="skipped"
        printf '  Gate values were already set by the operator, so nothing was seeded.\n'
        printf '    OSTLER_GATE_KNOWN_PERSON = %s\n' "${OSTLER_GATE_KNOWN_PERSON}"
        printf '    OSTLER_GATE_EXPECT_FACT  = %s\n' "${OSTLER_GATE_EXPECT_FACT}"
        printf '  The probe will assert that fact against whatever this box holds.\n\n'
        return 0
    fi

    _gs_find_seed_dir
    if [ -z "${GROUNDING_SEED_DIR}" ] && [ -n "${GROUNDING_SEED_STALE}" ]; then
        GROUNDING_SEED_STATE="absent"
        printf '  CANNOT-RUN: the seed oracle found is the PRE-FIX loader.\n'
        printf '    %s\n' "${GROUNDING_SEED_STALE}"
        printf '  Its load_seed.py does not use the product write route\n'
        printf '  (POST /api/v1/memory/assert), so it writes a vault note nothing on\n'
        printf '  this build reads and then times out. Pull that checkout to OS003\n'
        printf '  main, or point OSTLER_SEED_DIR at one that is current.\n'
        printf '  Nothing was seeded and no gate value was exported.\n\n'
        return 1
    fi
    if [ -z "${GROUNDING_SEED_DIR}" ]; then
        GROUNDING_SEED_STATE="absent"
        printf '  CANNOT-RUN: no OS003 seed oracle found.\n'
        printf '  Looked for load_seed.py and seed_fixture.json beside this checkout,\n'
        printf '  under ~/Developer and under ~/Documents/Projects. Set OSTLER_SEED_DIR\n'
        printf '  to the OS003 gates/seed directory and run the walk again.\n'
        printf '  NOT a product defect, and NOT a pass: the grounded probe will run\n'
        printf '  unseeded and its content assertion will not exist.\n\n'
        return 1
    fi
    printf '  seed oracle: %s\n' "${GROUNDING_SEED_DIR}"

    _gs_kp="$(_gs_fixture_value "${GROUNDING_SEED_DIR}/seed_fixture.json" known_person)"
    _gs_ef="$(_gs_fixture_value "${GROUNDING_SEED_DIR}/seed_fixture.json" expect_fact)"
    if [ -z "${_gs_kp}" ] || [ -z "${_gs_ef}" ]; then
        GROUNDING_SEED_STATE="absent"
        printf '  CANNOT-RUN: the fixture has no gate.known_person / gate.expect_fact.\n'
        printf '  Read from %s\n' "${GROUNDING_SEED_DIR}/seed_fixture.json"
        printf '  Nothing was seeded and no gate value was exported.\n\n'
        return 1
    fi

    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        printf '  target: this machine (OSTLER_BOX_HOST unset)\n'
    else
        printf '  target: %s\n' "${OSTLER_BOX_HOST}"
    fi

    _gs_out="$(_gs_run_loader "${GROUNDING_SEED_DIR}" 2>&1)"
    _gs_rc=$?
    printf '%s\n' "${_gs_out}" | sed 's/^/    /'

    if [ "${_gs_rc}" -eq 0 ]; then
        export OSTLER_GATE_KNOWN_PERSON="${_gs_kp}"
        export OSTLER_GATE_EXPECT_FACT="${_gs_ef}"
        GROUNDING_SEED_STATE="seeded"
        printf '  SEEDED. The grounded probe gets its content assertion:\n'
        printf '    OSTLER_GATE_KNOWN_PERSON = %s\n' "${OSTLER_GATE_KNOWN_PERSON}"
        printf '    OSTLER_GATE_EXPECT_FACT  = %s\n\n' "${OSTLER_GATE_EXPECT_FACT}"
        return 0
    fi

    GROUNDING_SEED_STATE="failed"
    if [ "${_gs_rc}" -eq 1 ]; then
        printf '  NOT SEEDED (loader exit 1): the person reached the graph but the\n'
        printf '  fact was not readable back on /api/v1/people/context. That is a\n'
        printf '  finding about the box, and the loader named it above.\n'
    else
        printf '  NOT SEEDED (loader exit %s): CANNOT-RUN. No service token, a 401, or\n' "${_gs_rc}"
        printf '  no answer from the people API. The loader named which, above.\n'
    fi
    printf '  No gate value was exported, ON PURPOSE: asserting a fact this box\n'
    printf '  cannot serve would report a harness failure as a product FAIL.\n'
    printf '  assistant_answers_grounded will run unseeded.\n\n'
    return 1
}

# ---------------------------------------------------------------------------
# Remove the synthetic person once the probes have finished with it. Called
# after phase 2. Never fails the walk: by this point every measurement is
# already taken, so a tidy-up that could change a verdict would be worse than
# leaving the row.
# ---------------------------------------------------------------------------
grounding_seed_forget() {
    [ "${GROUNDING_SEED_STATE}" = "seeded" ] || return 0
    if [ "${OSTLER_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- GROUNDING SEED: kept on the box (OSTLER_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- GROUNDING SEED: removing the synthetic person ---\n'
    _gs_fout="$(_gs_run_loader "${GROUNDING_SEED_DIR}" --forget 2>&1)"
    _gs_frc=$?
    printf '%s\n' "${_gs_fout}" | sed 's/^/    /'
    if [ "${_gs_frc}" -ne 0 ]; then
        printf '  Left on the box (forget exited %s). Every measurement above was\n' "${_gs_frc}"
        printf '  already taken, so this changes no verdict in this run.\n'
    fi
    printf '\n'
    return 0
}
