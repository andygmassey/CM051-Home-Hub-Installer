#!/usr/bin/env bash
#
# test_installer_authenticates_to_qdrant.sh
#
# #550 -- THE INSTALLER MUST BE ABLE TO AUTHENTICATE TO **QDRANT**, NOT JUST
# OXIGRAPH.
#
# WHAT WENT WRONG, AND WHY NO EXISTING TEST SAW IT.
#
# The two stores hold two DIFFERENT per-install secrets, both minted by
# _seed_store_secret as independent `openssl rand -hex 32`:
#
#     secrets/oxigraph_token   -> presented as  Authorization: Bearer <tok>
#     secrets/qdrant_api_key   -> presented as  api-key: <key>
#
# The shell credential file (`secrets/store-curl.conf`, consumed via `curl -K`)
# carried ONLY the Oxigraph bearer. Every shell caller therefore presented the
# WRONG secret in the WRONG header to Qdrant. While enforcement was default-OFF
# that was invisible: Qdrant was keyless, so a wrong credential and no
# credential both returned 200. #1222 flipped the default ON and the same code
# started returning 401.
#
# The consequence is not a degraded probe, it is a TERMINATED INSTALL:
# install.sh's post-boot Qdrant check reads a 401 on /collections as proof of a
# credential leak and calls fail_with_code ERR-06-STORE-AUTH-LEAK -> fail() ->
# exit 1.
#
# MEASURED against the pinned image the compose uses
# (qdrant/qdrant@sha256:d774e7bb..., v1.12.1) with QDRANT__SERVICE__API_KEY set:
#
#     /readyz       bare                            200   readiness PASSES,
#                                                         so the gate opens
#     /collections  Bearer <oxigraph token>         401   <- the defect
#     /collections  bare                            401   <- fresh-install case
#     /collections  api-key: <qdrant key>           200   control
#     /collections  Bearer <wrong> + api-key <ok>   200   control: both headers
#                                                         together are SAFE
#     /collections  bare, KEYLESS qdrant            200   control: pre-flip
#
# Those last three are what make the 401s a real result rather than a broken
# probe -- the same request shape succeeds when the credential is right.
#
# TWO INVARIANTS, AND THE SECOND IS THE ONE THAT ACTUALLY SHIPPED BROKEN:
#
#   1. CONTENT  -- the conf must carry a Qdrant credential, not only a bearer.
#   2. ORDERING -- the writer must run AFTER the secrets are seeded. Its first
#      call sits ~4,800 lines earlier, before secrets/ exists, where it
#      correctly fails closed and leaves the array EMPTY. Content alone is not
#      enough: with only that call, a fresh install still goes out bare.
#
# Both are asserted. Ordering is checked by BRACE DEPTH, not by comparing line
# numbers: a call nested inside a function defined early but invoked late is
# not governed by source order, and a naive line compare gets that backwards.
# Depth 0 == top level == source order is execution order.
#
# Assertions use `grep -c` and NEVER `... | grep -q`: under pipefail a piped
# `grep -q` exits on first match, SIGPIPEs the producer, and the pipeline
# reports FAILURE for a needle that IS present.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

fails=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

[ -f "${INSTALL_SH}" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-qdrant-auth.XXXXXX")" || {
    echo "FAIL: cannot create work dir -- CANNOT-RUN" >&2; exit 1; }
cleanup() { [ -n "${WORK:-}" ] && rm -rf "${WORK}"; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────
# Harness: extract the writer from a given install.sh and exercise it.
#
# The sed range is VALIDATED -- an unterminated range silently swallows
# thousands of lines and every assertion below would then be measuring the
# wrong text.
# ─────────────────────────────────────────────────────────────────────
extract_writer() {   # $1 = install.sh path, $2 = out file
    local src="$1" out="$2" opens closes
    opens="$(/usr/bin/grep -cE '^_ostler_write_store_curl_config\(\) \{' "${src}")"
    [ "${opens}" = "1" ] || { echo "CANNOT-RUN: writer definition found ${opens} times" >&2; return 3; }
    /usr/bin/sed -n '/^_ostler_write_store_curl_config() {/,/^}/p' "${src}" > "${out}"
    closes="$(/usr/bin/grep -cE '^\}' "${out}")"
    [ "${closes}" = "1" ] || { echo "CANNOT-RUN: sed range unterminated (closes=${closes})" >&2; return 3; }
    return 0
}

# Run the extracted writer against a sandbox OSTLER_DIR. Echoes the conf path.
run_writer() {   # $1 = writer file, $2 = sandbox dir, $3 = seed-oxigraph, $4 = seed-qdrant
    local wf="$1" dir="$2" seed_ox="$3" seed_qd="$4"
    mkdir -p "${dir}/secrets"
    [ "${seed_ox}" = "yes" ] && printf 'OXTOKENVALUE111' > "${dir}/secrets/oxigraph_token"
    [ "${seed_qd}" = "yes" ] && printf 'QDKEYVALUE222'   > "${dir}/secrets/qdrant_api_key"
    OSTLER_DIR="${dir}" bash -c '
        set -uo pipefail
        _OSTLER_STORE_CURL_ARGS=()
        . "$1"
        _ostler_write_store_curl_config
        rc=$?
        printf "RC=%s ARGC=%s\n" "$rc" "${#_OSTLER_STORE_CURL_ARGS[@]}"
    ' _ "${wf}" 2>&1
}

# ─────────────────────────────────────────────────────────────────────
# ARM 1-4: CONTENT -- both credentials land, with the right header names.
# ─────────────────────────────────────────────────────────────────────
W="${WORK}/writer.sh"
if ! extract_writer "${INSTALL_SH}" "${W}"; then
    echo "FAIL: cannot extract writer -- CANNOT-RUN" >&2; exit 1
fi

SB="${WORK}/sb_both"
OUT="$(run_writer "${W}" "${SB}" yes yes)"
CONF="${SB}/secrets/store-curl.conf"

if [ -f "${CONF}" ]; then
    pass "arm1: writer produced ${CONF##*/}"
else
    fail "arm1: no store-curl.conf produced (writer said: ${OUT})"
fi

n_bearer="$(/usr/bin/grep -cE '^header = "Authorization: Bearer ' "${CONF}" 2>/dev/null || true)"
n_apikey="$(/usr/bin/grep -cE '^header = "api-key: ' "${CONF}" 2>/dev/null || true)"

if [ "${n_apikey}" = "1" ]; then
    pass "arm2: conf carries a QDRANT api-key header (the defect this test exists for)"
else
    fail "arm2: conf has ${n_apikey} api-key headers, expected 1 -- shell callers cannot authenticate to Qdrant, and install.sh will abort at ERR-06-STORE-AUTH-LEAK"
fi

if [ "${n_bearer}" = "1" ]; then
    pass "arm3: conf still carries the OXIGRAPH bearer (no regression)"
else
    fail "arm3: conf has ${n_bearer} bearer headers, expected 1"
fi

# The secret must never reach argv. -K is the whole point.
if [ "$(/usr/bin/grep -cE 'ARGC=2' <<<"${OUT}")" = "1" ]; then
    pass "arm4: writer armed _OSTLER_STORE_CURL_ARGS as exactly ( -K <path> )"
else
    fail "arm4: expected ARGC=2 ( -K <path> ), got: ${OUT}"
fi

# ─────────────────────────────────────────────────────────────────────
# ARM 5: MODE -- 0600. A credential file another account can read is the
# #550 threat model with the secret as the payload.
# ─────────────────────────────────────────────────────────────────────
if [ -f "${CONF}" ]; then
    mode="$(/usr/bin/stat -f '%Lp' "${CONF}" 2>/dev/null || /usr/bin/stat -c '%a' "${CONF}" 2>/dev/null)"
    if [ "${mode}" = "600" ]; then
        pass "arm5: conf mode is 600"
    else
        fail "arm5: conf mode is ${mode}, expected 600"
    fi
else
    fail "arm5: CANNOT-RUN, no conf to stat"
fi

# ─────────────────────────────────────────────────────────────────────
# ARM 6-7: FAIL CLOSED with no secrets, and PARTIAL when only one exists.
# ─────────────────────────────────────────────────────────────────────
OUT_NONE="$(run_writer "${W}" "${WORK}/sb_none" no no)"
if [ "$(/usr/bin/grep -cE 'RC=1 ARGC=0' <<<"${OUT_NONE}")" = "1" ]; then
    pass "arm6: no secrets -> fails closed, array empty (this is the FIRST call on a fresh install)"
else
    fail "arm6: expected RC=1 ARGC=0 with no secrets, got: ${OUT_NONE}"
fi

SB_Q="${WORK}/sb_qdrant_only"
run_writer "${W}" "${SB_Q}" no yes >/dev/null
if [ "$(/usr/bin/grep -cE '^header = "api-key: ' "${SB_Q}/secrets/store-curl.conf" 2>/dev/null || true)" = "1" ]; then
    pass "arm7: qdrant secret alone still arms the api-key header"
else
    fail "arm7: qdrant-only seeding produced no api-key header"
fi

# ─────────────────────────────────────────────────────────────────────
# ARM 8-9: ORDERING -- a top-level invocation must follow the seeding.
#
# Brace depth, not line-number-vs-line-number. Depth 0 after a statement means
# it is not nested inside any function, so source order == execution order.
# ─────────────────────────────────────────────────────────────────────
depth_report="$(/usr/bin/awk '
  { d=0; n=split($0,c,""); for(i=1;i<=n;i++){ if(c[i]=="{") d++; else if(c[i]=="}") d-- }
    depth += d
    if ($0 ~ /^_seed_store_secret "qdrant_api_key"/ && depth == 0) seed = NR
    if ($0 ~ /^_ostler_write_store_curl_config \|\| true/ && depth == 0) { calls = calls " " NR; if (seed && NR > seed && !after) after = NR }
  }
  END { printf "seed=%s calls=%s after=%s\n", (seed?seed:0), (calls?calls:"none"), (after?after:0) }
' "${INSTALL_SH}")"

seed_line="$(/usr/bin/sed -E 's/.*seed=([0-9]+).*/\1/' <<<"${depth_report}")"
after_line="$(/usr/bin/sed -E 's/.*after=([0-9]+).*/\1/' <<<"${depth_report}")"

if [ "${seed_line}" != "0" ]; then
    pass "arm8: found the top-level qdrant_api_key seeding at line ${seed_line} (predicate is live)"
else
    fail "arm8: CANNOT-RUN -- no top-level _seed_store_secret \"qdrant_api_key\" found; the ordering arm below would be vacuous"
fi

if [ "${after_line}" != "0" ]; then
    pass "arm9: a top-level writer invocation runs AFTER the seeding, at line ${after_line} (${depth_report})"
else
    fail "arm9: NO top-level writer invocation after line ${seed_line} -- the conf is written before either secret exists, so it is empty for the whole run and every shell store caller goes out bare (${depth_report})"
fi

# ─────────────────────────────────────────────────────────────────────
# ARM 10-11: MUTATION. A test that cannot go red proves nothing. Each arm
# reintroduces the exact defect and asserts THIS test would have caught it.
# ─────────────────────────────────────────────────────────────────────
MUT_CONTENT="${WORK}/install_mut_content.sh"
# BSD sed (this is /usr/bin/sed on macOS) has no `addr,+N` form -- that is GNU
# only, and using it here silently produced an UNMUTATED copy on the first run
# of this test. The arm reported an empty count rather than a red, which is
# precisely the "mutation that did not mutate" failure it exists to avoid. So:
# a plain line-delete, and the delta is ASSERTED below before anything is read
# off the mutant.
MUT_PAT='printf .header = .api-key: '
/usr/bin/sed "/${MUT_PAT}/d" "${INSTALL_SH}" > "${MUT_CONTENT}"
before="$(/usr/bin/grep -cE "${MUT_PAT}" "${INSTALL_SH}" || true)"
after="$(/usr/bin/grep -cE "${MUT_PAT}" "${MUT_CONTENT}" || true)"
removed="$(( before - after ))"
if [ "${removed}" -lt 1 ]; then
    fail "arm10: CANNOT-RUN -- the mutation did not mutate (removed=${removed}); a mutation test that did not mutate proves nothing"
else
    MW="${WORK}/writer_mut.sh"
    if extract_writer "${MUT_CONTENT}" "${MW}"; then
        run_writer "${MW}" "${WORK}/sb_mut" yes yes >/dev/null
        m_apikey="$(/usr/bin/grep -cE '^header = "api-key: ' "${WORK}/sb_mut/secrets/store-curl.conf" 2>/dev/null || true)"
        # An absent conf yields an EMPTY count, not "0" -- and empty would read
        # as "not equal to 0" and report a confusing pass/fail either way.
        m_apikey="${m_apikey:-0}"
        if [ "${m_apikey}" = "0" ]; then
            pass "arm10: MUTATION RED -- dropping the api-key line yields a conf with 0 api-key headers, which arm2 fails on"
        else
            fail "arm10: mutation still produced ${m_apikey} api-key headers -- arm2 is not actually guarding this"
        fi
    else
        fail "arm10: CANNOT-RUN -- could not extract writer from the mutant"
    fi
fi

MUT_ORDER="${WORK}/install_mut_order.sh"
# Delete every top-level invocation that follows the seeding, leaving only the
# early one -- i.e. restore the pre-fix ordering.
/usr/bin/awk -v seed="${seed_line}" '
  { d=0; n=split($0,c,""); for(i=1;i<=n;i++){ if(c[i]=="{") d++; else if(c[i]=="}") d-- }
    depth += d
    if (NR > seed && depth == 0 && $0 ~ /^_ostler_write_store_curl_config \|\| true/) next
    print
  }' "${INSTALL_SH}" > "${MUT_ORDER}"
delta="$(( $(/usr/bin/wc -l < "${INSTALL_SH}") - $(/usr/bin/wc -l < "${MUT_ORDER}") ))"
if [ "${delta}" -lt 1 ]; then
    fail "arm11: CANNOT-RUN -- ordering mutation removed ${delta} lines; it did not mutate"
else
    mut_after="$(/usr/bin/awk -v seed="${seed_line}" '
      { d=0; n=split($0,c,""); for(i=1;i<=n;i++){ if(c[i]=="{") d++; else if(c[i]=="}") d-- }
        depth += d
        if (NR > seed && depth == 0 && $0 ~ /^_ostler_write_store_curl_config \|\| true/) { print NR; exit }
      }' "${MUT_ORDER}")"
    if [ -z "${mut_after}" ]; then
        pass "arm11: MUTATION RED -- with the late invocation removed, arm9 finds no post-seed call and fails (${delta} line(s) removed)"
    else
        fail "arm11: ordering mutation left a post-seed call at ${mut_after} -- arm9 is not guarding this"
    fi
fi

# ─────────────────────────────────────────────────────────────────────
echo
if [ "${fails}" -eq 0 ]; then
    echo "GATE OK: the installer can authenticate to Qdrant, and the credential is written after the secrets exist."
    exit 0
fi
echo "GATE FAILED: ${fails} assertion(s)." >&2
exit 1
