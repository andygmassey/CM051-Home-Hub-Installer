#!/usr/bin/env bash
#
# tests/test_licence_plan_reaches_the_gate.sh
#
# THE SIGNED LICENCE PLAN, FROM THE VERIFIER TO THE INCLUDED-PRO GATE (133).
#
# WHY
# ----
# Archie's ruling (option c): the licence's signed `plan` (founding | ff |
# standard) must reach activate_first_month_free's `included_plan` kwarg. It
# is read by a SEPARATE plan-mode call of the shipped verifier, on the same
# signed file, and only a valid signature may carry it. Anything else must
# print nothing, and nothing may default to a plan.
#
# WHAT THIS PINS, against the REAL install.sh (or PLAN_TEST_INSTALL_SH, a
# mutant copy, used only by the mutation runs):
#   1. the plan read from the signed payload for founding / ff / standard
#   2. no plan field, unknown value, tampered payload, garbage file -> empty
#   3. an expired licence -> empty, and the expiry DATE does not leak
#   4. the tier line is unchanged (each case asserts its exact literal line)
#   5. a failing plan call never aborts install.sh under set -e, with an
#      ERR trap armed (the install's own shape)
#   6. the call site passes OSTLER_LICENCE_PLAN as included_plan: a value
#      reaches the gate, "" reaches it as None
#   7. MERGE ORDER: the call site's included_plan is accepted by the VENDORED
#      gate that install.sh actually imports. This is RED on any tree whose
#      vendored subscription_gate predates CM051 #3574 (CM052 #21). That is
#      deliberate: a wrong merge order must be visibly red, not silently
#      drop the first-month activation inside the non-fatal block.
#
# SYNTHETIC DATA ONLY. Keys come from fixed non-secret seeds and exist for
# one run. Nothing real is read or written: HOME is a scratch directory.
#
# Exit 0 on pass, 1 on any failure. Portable to bash 3.2 (macOS /bin/bash).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${PLAN_TEST_INSTALL_SH:-${REPO_ROOT}/install.sh}"
VENDOR_GATE_DIR="${REPO_ROOT}/vendor/cm041/assistant_api"

WORK="$(mktemp -d -t ostler-licence-plan.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "CANNOT RUN: install.sh not found at ${INSTALL_SH}" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "CANNOT RUN: python3 unavailable; cannot mint synthetic licences." >&2
    echo "            This is not a pass -- nothing was verified." >&2
    exit 1
fi

# ── The verifier, extracted exactly as tests/test_licence_gate.sh does it ──
VERIFIER="${WORK}/verifier.py"
sed -n "/_lic_py_src=.*<<'OSTLER_LICENCE_VERIFY_PY'\$/,/^OSTLER_LICENCE_VERIFY_PY\$/p" \
    "$INSTALL_SH" | sed '1d;$d' > "$VERIFIER"
if [[ ! -s "$VERIFIER" ]] || ! grep -q 'def ed25519_verify' "$VERIFIER"; then
    echo "CANNOT RUN: the verifier heredoc could not be extracted from install.sh" >&2
    exit 1
fi

# ── Minting: Ed25519 signing built on the SHIPPED point arithmetic ────────
MINT_PY="${WORK}/mint.py"
cat > "$MINT_PY" <<'MINT_SRC'
import base64, hashlib, json, sys

verifier_src = open(sys.argv[1]).read()
entry = "# === entrypoint ==="
ns = {"__name__": "shipped_verifier_for_minting"}
exec(compile(verifier_src.split(entry)[0], "shipped_verifier", "exec"), ns)
G, q, _point_mul, _sha512_modq = ns["G"], ns["q"], ns["_point_mul"], ns["_sha512_modq"]
p, _modp_inv = ns["p"], ns["_modp_inv"]


def encode(P):
    X, Y, Z, _ = P
    zinv = _modp_inv(Z)
    x, y = X * zinv % p, Y * zinv % p
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def sign(seed, msg):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    prefix = h[32:]
    A = encode(_point_mul(a, G))
    r = _sha512_modq(prefix + msg)
    R = encode(_point_mul(r, G))
    k = _sha512_modq(R + A + msg)
    S = (r + k * a) % q
    return R + S.to_bytes(32, "little")


SEED = b"OSTLER-SYNTHETIC-PLAN-SEED-1" + b"\x00" * 4


def canonical(doc):
    return json.dumps(doc, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def pubkey_hex():
    h = hashlib.sha512(SEED).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return encode(_point_mul(a, G)).hex()


# mint <out> <expires> <plan|-> [tamper]
#   plan "-" omits the field. tamper edits the plan AFTER signing, so the
#   signature no longer covers the body.
if sys.argv[2] == "pubkey":
    sys.stdout.write(pubkey_hex())
    raise SystemExit(0)
out, expires, plan = sys.argv[2], sys.argv[3], sys.argv[4]
tamper = len(sys.argv) > 5 and sys.argv[5] == "tamper"
doc = {
    "version": 1,
    "license_id": "00000000-0000-4000-8000-0000000000aa",
    "issued_to_email": "synthetic-tester@example.invalid",
    "purchased_at": "2026-01-01T00:00:00Z",
    "update_window_expires_at": expires,
    "max_hardware_fingerprints": 3,
    "stripe_payment_id": "pi_SYNTHETIC_PLAN_0000000000",
    "signature_algorithm": "Ed25519",
    "tier": "beta",
}
if plan != "-":
    doc["plan"] = plan
doc["signature"] = base64.b64encode(sign(SEED, canonical(
    {k: v for k, v in doc.items() if k != "signature"}))).decode()
if tamper:
    doc["plan"] = "founding" if plan != "founding" else "ff"
with open(out, "w") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
MINT_SRC

PUB="$(python3 "$MINT_PY" "$VERIFIER" pubkey "" "" 2>"${WORK}/pub.err")" || {
    echo "CANNOT RUN: could not derive the synthetic public key" >&2
    cat "${WORK}/pub.err" >&2
    exit 1
}

FUTURE="2099-01-01T00:00:00Z"
PAST="2001-01-01T00:00:00Z"
TIER_LINE_FUTURE="known ${FUTURE} beta"

mint() { python3 "$MINT_PY" "$VERIFIER" "$@"; }

# plan_call <licence> -> stdout of the plan-mode call (exactly as install.sh runs it)
plan_call() {
    local src
    src="$(cat "$VERIFIER")"
    python3 -c "$src" "$1" "$PUB" plan
}

# tier_call <licence> -> stdout of the ordinary call (the tier line)
tier_call() {
    local src
    src="$(cat "$VERIFIER")"
    python3 -c "$src" "$1" "$PUB"
}

# ── Case table ─────────────────────────────────────────────────────────────
# Each case: label, licence builder, expected plan output, expected tier line.
# An empty expected tier line means "the tier call prints this exact text"
# is not asserted; the expired case asserts the date instead.
echo "==> Plan read, signed payload"
for plan in founding ff standard; do
    lic="${WORK}/lic-${plan}.json"
    mint "$lic" "$FUTURE" "$plan" >/dev/null
    got="$(plan_call "$lic")"; rc=$?
    if [[ "$got" == "$plan" && "$rc" == "0" ]]; then
        ok "signed plan '${plan}' is read (rc 0, output '${got}')"
    else
        bad "signed plan '${plan}' not read: rc=${rc} output='${got}'"
    fi
    tgot="$(tier_call "$lic")"
    if [[ "$tgot" == "$TIER_LINE_FUTURE" ]]; then
        ok "tier line unchanged for '${plan}' ('${tgot}')"
    else
        bad "tier line changed for '${plan}': '${tgot}' (want '${TIER_LINE_FUTURE}')"
    fi
done

echo "==> Nothing valid, nothing printed"
lic="${WORK}/lic-noplan.json"; mint "$lic" "$FUTURE" "-" >/dev/null
got="$(plan_call "$lic")"; rc=$?
[[ -z "$got" && "$rc" == "0" ]] && ok "no plan field -> empty (rc 0)" \
    || bad "no plan field printed '${got}' (rc ${rc}); a default would read as a plan"
tgot="$(tier_call "$lic")"
[[ "$tgot" == "$TIER_LINE_FUTURE" ]] && ok "no plan field: tier line unchanged" \
    || bad "no plan field: tier line '${tgot}' (want '${TIER_LINE_FUTURE}')"

lic="${WORK}/lic-gold.json"; mint "$lic" "$FUTURE" "gold" >/dev/null
got="$(plan_call "$lic")"; rc=$?
[[ -z "$got" && "$rc" == "0" ]] && ok "unknown plan 'gold' -> empty (rc 0)" \
    || bad "unknown plan 'gold' printed '${got}' (rc ${rc})"
tgot="$(tier_call "$lic")"
[[ "$tgot" == "$TIER_LINE_FUTURE" ]] && ok "unknown plan: tier line unchanged" \
    || bad "unknown plan: tier line '${tgot}'"

lic="${WORK}/lic-tampered.json"; mint "$lic" "$FUTURE" "standard" tamper >/dev/null
got="$(plan_call "$lic")"; rc=$?
[[ -z "$got" && "$rc" != "0" ]] && ok "tampered plan (edited after signing) -> empty, refused (rc ${rc})" \
    || bad "tampered plan printed '${got}' (rc ${rc}); signature must cover the plan"
tgot="$(tier_call "$lic")"; trc=$?
[[ -z "$tgot" && "$trc" != "0" ]] && ok "tampered: tier call also refuses (rc ${trc})" \
    || bad "tampered: tier call printed '${tgot}' (rc ${trc})"

lic="${WORK}/garbage.json"; printf 'not a licence at all\n' > "$lic"
got="$(plan_call "$lic")"; rc=$?
[[ -z "$got" && "$rc" != "0" ]] && ok "garbage file -> empty, refused (rc ${rc})" \
    || bad "garbage file printed '${got}' (rc ${rc})"

echo "==> Expired licence: the date must not leak into the plan"
lic="${WORK}/lic-expired.json"; mint "$lic" "$PAST" "founding" >/dev/null
got="$(plan_call "$lic")"; rc=$?
case "$got" in
    *2001*) bad "expired licence leaked the expiry date into plan mode: '${got}'" ;;
    "")     ok "expired licence -> plan mode prints nothing (rc ${rc})" ;;
    *)      bad "expired licence plan mode printed '${got}' (rc ${rc})" ;;
esac
# Control: the ordinary call DOES print the date for an expired licence, so
# the absence above is a real absence and not a broken predicate.
tgot="$(tier_call "$lic")"
case "$tgot" in
    *2001-01-01T00:00:00Z*) ok "control: ordinary call prints the expiry for the same licence" ;;
    *) bad "control failed: ordinary call printed '${tgot}', so the leak check proves nothing" ;;
esac

# ── The plan line, as install.sh runs it, under set -e with an ERR trap ──
echo "==> Plan call cannot abort install.sh (set -e, ERR trap armed)"
PLAN_LINE_COUNT="$(grep -c -F 'OSTLER_LICENCE_PLAN="$("' "$INSTALL_SH")"
if [[ "$PLAN_LINE_COUNT" != "1" ]]; then
    bad "expected exactly one plan-read line in install.sh, found ${PLAN_LINE_COUNT}"
else
    PLAN_LINE="$(grep -F 'OSTLER_LICENCE_PLAN="$("' "$INSTALL_SH" | sed 's/^[[:space:]]*//')"
    for label in founding tampered expired garbage; do
        case "$label" in
            founding) lic="${WORK}/lic-founding.json" ;;
            tampered) lic="${WORK}/lic-tampered.json" ;;
            expired)  lic="${WORK}/lic-expired.json" ;;
            garbage)  lic="${WORK}/garbage.json" ;;
        esac
        {
            printf '%s\n' '#!/bin/bash' 'set -e' "trap 'echo ERRTRAP_FIRED' ERR"
            printf '%s\n' "_lic_python=python3" "_lic_pubkey='${PUB}'" \
                "OSTLER_LICENCE_FILE='${lic}'" "OSTLER_LICENCE_PLAN=''"
            printf '%s\n' "_lic_py_src=\"\$(cat '${VERIFIER}')\""
            printf '%s\n' "$PLAN_LINE"
            printf '%s\n' 'echo "AFTER_PLAN=[${OSTLER_LICENCE_PLAN}]"'
        } > "${WORK}/plan-${label}.sh"
        out="$(/bin/bash "${WORK}/plan-${label}.sh" 2>&1)"; rc=$?
        if [[ "$out" == *ERRTRAP_FIRED* ]]; then
            bad "${label}: the ERR trap fired on the plan call"
        elif [[ "$out" != *AFTER_PLAN=* ]]; then
            bad "${label}: the script aborted before the next line (rc ${rc}): ${out}"
        else
            want=""; [[ "$label" == founding ]] && want="founding"
            if [[ "$out" == *"AFTER_PLAN=[${want}]"* ]]; then
                ok "${label}: no abort, plan='${want}' (rc ${rc})"
            else
                bad "${label}: unexpected plan (want '${want}'): ${out}"
            fi
        fi
    done
fi

# ── The call site: env value reaches included_plan ────────────────────────
echo "==> Call site: OSTLER_LICENCE_PLAN reaches included_plan"
# Extract the python -c block that calls activate_first_month_free: from the
# opening `if python3 -c "` line to the `" 2>&1; then` line.
CALLSITE_PY="${WORK}/callsite.py"
python3 - "$INSTALL_SH" "$CALLSITE_PY" "$REPO_ROOT" <<'EXTRACT_PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [i for i, l in enumerate(lines)
        if l.strip() == "from subscription_gate import activate_first_month_free"]
if len(hits) != 1:
    raise SystemExit("expected one call site, found %d" % len(hits))
start = max(i for i in range(hits[0]) if lines[i].startswith('if python3 -c "'))
end = next(i for i in range(hits[0], len(lines)) if lines[i] == '" 2>&1; then')
body = "\n".join(lines[start:end]).split('"', 1)[1]
body = body.replace("${SCRIPT_DIR}", "@@SCRIPT_DIR@@")
open(sys.argv[2], "w", encoding="utf-8").write(body + "\n")
EXTRACT_PY
if [[ ! -s "$CALLSITE_PY" ]]; then
    bad "could not extract the activate_first_month_free call site from install.sh"
fi

# A recording stub stands in for the gate, so this test isolates the CALL SITE.
STUB_DIR="${WORK}/stub"
mkdir -p "$STUB_DIR"
cat > "${STUB_DIR}/subscription_gate.py" <<'STUB_PY'
import json, os
def activate_first_month_free(purchase_date_iso, **kwargs):
    with open(os.environ["PLAN_STUB_OUT"], "w") as handle:
        json.dump(kwargs, handle, sort_keys=True)
STUB_PY

# SCRIPT_DIR points at a root that does not exist, so the block can only import
# the stub. The real gate would otherwise be imported from the vendor path.
callsite_body() { sed "s|@@SCRIPT_DIR@@|$1|g" "$CALLSITE_PY"; }

run_callsite() {  # run_callsite <label> <env-value|UNSET>  -> writes stub output, prints rc
    local label="$1" value="$2" home rc=0
    home="$(mktemp -d "${WORK}/home.XXXXXX")"
    rm -f "${WORK}/stub-out.json"
    if [[ "$value" == "UNSET" ]]; then
        env -i PATH="$PATH" HOME="$home" PYTHONPATH="$STUB_DIR" \
            PLAN_STUB_OUT="${WORK}/stub-out.json" \
            OSTLER_LICENCE_TIER=beta OSTLER_LICENCE_TIER_STATE=known \
            OSTLER_LICENCE_EXPIRES_AT="$FUTURE" \
            python3 -c "$(callsite_body "${WORK}/no-such-root")" >"${WORK}/cs-${label}.out" 2>&1 || rc=$?
    else
        env -i PATH="$PATH" HOME="$home" PYTHONPATH="$STUB_DIR" \
            PLAN_STUB_OUT="${WORK}/stub-out.json" \
            OSTLER_LICENCE_TIER=beta OSTLER_LICENCE_TIER_STATE=known \
            OSTLER_LICENCE_EXPIRES_AT="$FUTURE" OSTLER_LICENCE_PLAN="$value" \
            python3 -c "$(callsite_body "${WORK}/no-such-root")" >"${WORK}/cs-${label}.out" 2>&1 || rc=$?
    fi
    printf '%s' "$rc"
}

# check_included <want: plan|NONE> -> 0 if the stub recorded that included_plan
included_is() {
    python3 - "${WORK}/stub-out.json" "$1" <<'CHECK_PY'
import json, sys
try:
    kw = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit(2)
want = None if sys.argv[2] == "NONE" else sys.argv[2]
if "included_plan" not in kw:
    raise SystemExit(3)
raise SystemExit(0 if kw["included_plan"] == want else 4)
CHECK_PY
}

for plan in founding ff standard; do
    rc="$(run_callsite "p-${plan}" "$plan")"
    if [[ "$rc" == "0" ]] && included_is "$plan"; then
        ok "env '${plan}' reaches the gate as included_plan='${plan}'"
    else
        bad "env '${plan}' did not reach included_plan (rc ${rc}, stub-out: $(cat "${WORK}/stub-out.json" 2>/dev/null || echo none))"
    fi
done

rc="$(run_callsite "empty" "")"
if [[ "$rc" == "0" ]] && included_is NONE; then
    ok "empty env reaches the gate as included_plan=None"
else
    bad "empty env did not map to None (rc ${rc}, stub-out: $(cat "${WORK}/stub-out.json" 2>/dev/null || echo none))"
fi

rc="$(run_callsite "unset" "UNSET")"
if [[ "$rc" == "0" ]] && included_is NONE; then
    ok "unset env reaches the gate as included_plan=None"
else
    bad "unset env did not map to None (rc ${rc})"
fi

# ── MERGE ORDER: the vendored gate must accept the kwarg the call site passes ─
echo "==> Merge order: the vendored gate accepts included_plan"
# Real gate, not the stub: the block exactly as install.sh runs it, imported
# from this tree's vendor directory, against a sandboxed HOME.
gate_home="$(mktemp -d "${WORK}/gate-home.XXXXXX")"
gate_rc=0
gate_out="$(env -i PATH="$PATH" HOME="$gate_home" OSTLER_LICENCE_PLAN=founding \
    OSTLER_LICENCE_TIER=beta OSTLER_LICENCE_TIER_STATE=known \
    OSTLER_LICENCE_EXPIRES_AT="$FUTURE" \
    python3 -c "$(callsite_body "$REPO_ROOT")" 2>&1)" || gate_rc=$?
if [[ "$gate_rc" == "0" ]]; then
    ok "vendored gate accepts the call site's included_plan (rc 0)"
else
    last="$(printf '%s\n' "$gate_out" | tail -n 1)"
    bad "vendored gate REFUSES included_plan (rc ${gate_rc}: ${last}). The call site needs CM051 #3574 (CM052 #21) merged first. Merge order: CM052 #21, then #3574, then this PR."
fi
# Control: the gate's own signature, read with inspect, so the red above can
# be read as a fact about the vendored file and not as a flaky call.
sig_has="$(python3 -c "import inspect,sys; sys.path.insert(0, sys.argv[1]); from subscription_gate import activate_first_month_free as f; print('included_plan' in inspect.signature(f).parameters)" "$VENDOR_GATE_DIR" 2>/dev/null)"
if [[ "$sig_has" == "True" ]]; then
    ok "control: vendored activate_first_month_free has an included_plan parameter (inspect)"
else
    bad "control: vendored activate_first_month_free has no included_plan parameter (inspect said '${sig_has:-nothing}')"
fi

# ── PRODUCTION SHAPE: a signed licence with NO tier field (133 Box finding) ──
# CM050 mintLicense emits no `tier`. The verifier's PASS path reports tier_state
# "absent" and the plan. The gate must grant the window from the signed plan,
# through the real install.sh verifier, its three env fields, and the real call
# site. Everything below runs the shipped code; nothing is re-typed.
echo "==> Production shape: signed, no tier field"
MINT_NOTIER_PY="${WORK}/mint-notier.py"
sed '/"tier": "beta",/d' "$MINT_PY" > "$MINT_NOTIER_PY"
mint_notier() { python3 "$MINT_NOTIER_PY" "$VERIFIER" "$@"; }

# install_activation <licence> <state-file> [script-dir]
#   Takes the verifier exactly as install.sh does: rc 0 gives the three fields
#   and the plan, anything else gives tier_state "unverified" and no plan. Then
#   runs the real call site with the installed env and a sandboxed state file.
install_activation() {
    local lic="$1" state="$2" sdir="${3:-$REPO_ROOT}"
    local detail vrc st exp tier plan_out rest
    detail="$(tier_call "$lic")"; vrc=$?
    if (( vrc == 0 )); then
        st="${detail%% *}"; rest="${detail#* }"
        exp="${rest%% *}"; tier="${rest#* }"
        plan_out="$(plan_call "$lic")" || plan_out=""
    else
        st="unverified"; exp=""; tier=""; plan_out=""
    fi
    env -i PATH="$PATH" HOME="$WORK" OSTLER_SUBSCRIPTION_STATE="$state" \
        OSTLER_LICENCE_PLAN="$plan_out" OSTLER_LICENCE_TIER="$tier" \
        OSTLER_LICENCE_TIER_STATE="$st" OSTLER_LICENCE_EXPIRES_AT="$exp" \
        python3 -c "$(callsite_body "$sdir")" >/dev/null 2>&1
}

# window_days <state-file> -> "<source> <plan> <days>", or "none"
window_days() {
    python3 - "$1" <<'WIN_PY'
import json, sys
from datetime import datetime
try:
    st = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("none"); raise SystemExit(0)
if st.get("source") != "first_month_free":
    print("none"); raise SystemExit(0)
exp = datetime.fromisoformat(st["expires_at"].replace("Z", "+00:00"))
start = datetime.fromisoformat(st["included_from"].replace("Z", "+00:00"))
print("%s %s %d" % (st["source"], st.get("included_plan"), round((exp - start).total_seconds() / 86400)))
WIN_PY
}

lic="${WORK}/notier-probe.json"; mint_notier "$lic" "$FUTURE" "founding" >/dev/null
tline="$(tier_call "$lic")"
if [[ "$tline" == "absent ${FUTURE} hub" ]]; then
    ok "verifier PASS on a no-tier licence: tier line '${tline}'"
else
    bad "no-tier licence: tier line is '${tline}', want 'absent ${FUTURE} hub'"
fi

for plan in founding ff standard; do
    lic="${WORK}/notier-${plan}.json"; mint_notier "$lic" "$FUTURE" "$plan" >/dev/null
    want_days=180; [[ "$plan" == standard ]] && want_days=90
    state="${WORK}/state-notier-${plan}.json"; rm -f "$state"
    install_activation "$lic" "$state"
    got="$(window_days "$state")"
    if [[ "$got" == "first_month_free ${plan} ${want_days}" ]]; then
        ok "production ${plan} licence, no tier: ${want_days}-day included window (${got})"
    else
        bad "production ${plan} licence, no tier: window '${got}', want 'first_month_free ${plan} ${want_days}'"
    fi
done

# Fail closed: nothing that is not a verifier PASS may grant a window, plan or no plan.
lic="${WORK}/notier-tampered.json"; mint_notier "$lic" "$FUTURE" "founding" tamper >/dev/null
state="${WORK}/state-tampered.json"; rm -f "$state"; install_activation "$lic" "$state"
[[ "$(window_days "$state")" == "none" ]] && ok "tampered no-tier founding licence: no window" \
    || bad "tampered no-tier founding licence granted a window: $(window_days "$state")"

lic="${WORK}/notier-expired.json"; mint_notier "$lic" "$PAST" "founding" >/dev/null
state="${WORK}/state-expired.json"; rm -f "$state"; install_activation "$lic" "$state"
[[ "$(window_days "$state")" == "none" ]] && ok "expired no-tier founding licence: no new window" \
    || bad "expired no-tier founding licence granted a window: $(window_days "$state")"

state="${WORK}/state-nolicence.json"; rm -f "$state"
install_activation "${WORK}/no-such-licence.json" "$state"
[[ "$(window_days "$state")" == "none" ]] && ok "no licence file: no window (0 days)" \
    || bad "no licence file granted a window: $(window_days "$state")"

echo
echo "licence plan reaches the gate: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
