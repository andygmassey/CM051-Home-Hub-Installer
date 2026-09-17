#!/usr/bin/env bash
#
# tests/test_licence_tier_reaches_the_hub.sh
#
# HR015 #928: "Every licence carries a tier, and the Hub reads it."
#
# WHAT WAS WRONG, MEASURED ON origin/main BEFORE THIS TEST EXISTED
# ----------------------------------------------------------------
# The licence body is Ed25519-signed and verified twice on every install --
# once by the GUI (LicenseVerifier.swift) and once by install.sh's own
# verifier, before anything at all touches the customer's Mac. Neither read a
# tier, because the schema had no tier field:
#
#     tier in the licence surface (LicenseVerifier.swift, LicensePersistence,
#          LicenseEntryView and their three test files)            0 hits
#     update_window_expires_at, same files, as the CONTROL         present
#          in all of them, so the zero is a real absence and not a
#          grep that cannot see the file
#
# And a tier was ALREADY signature-covered, which is the part that makes this
# cheap now and expensive later. Measured against the shipped verifier
# extracted from install.sh, on origin/main, before any change:
#
#     synthetic licence carrying tier=beta   -> rc 0, printed NOTHING
#     synthetic licence carrying no tier     -> rc 0, printed NOTHING
#     tier hand-edited hub -> pro AFTER signing -> rc 13, bad signature
#
# So the field verified, could not be forged, and went nowhere. Verified is
# not the same as read.
#
# WHAT THIS TEST PINS, AND WHY IT IS SHAPED LIKE THIS
# ---------------------------------------------------
# The subject of every assertion below is a PERSON holding a licence, not a
# function returning a field. A parser that returns "beta" proves nothing
# about a beta tester, which is the failure this whole area keeps producing.
# So the chain is walked end to end, through the REAL install.sh gate and the
# REAL shipped gate module:
#
#   Limb A  the four tier STATES are four states, and the verifier keeps them
#           apart: absent, known, unknown, and malformed. An expired licence,
#           an absent tier and an unverifiable install must never collapse.
#   Limb B  the real install.sh, run with a sandboxed HOME, tells the customer
#           their tier at the gate -- and for an unrecognised tier, installs
#           anyway rather than refusing.
#   Limb C  the tier the gate read reaches the Hub's own state file, through
#           the same activation call install.sh makes.
#   Limb D  the customer-visible surface names it. This is the consumer-side
#           proof: the pause message a paused customer's Hub prints says which
#           licence they hold, and `--tier` answers for the Doctor.
#   Limb E  an UNVERIFIED install (the --allow-unlicensed escape hatch) must
#           not overwrite a tier a previous verified install established, and
#           must never be recorded as "hub". "We did not check" is not a tier.
#   Limb F  the two verifiers agree about `tier`. They are separate
#           implementations of one schema and the repo's own comments say they
#           will drift; this limb is the thing that notices.
#
# Limb F is the one that stops the rest being theatre. Limbs A to E all run
# the SHELL verifier. If Swift and shell disagree about what a tier is, the
# customer is told their licence is fine by the GUI and then watched the
# install abort on it, and every limb above stays green.
#
# SYNTHETIC DATA ONLY. Keys are generated inside this run from fixed
# non-secret seeds; licence bodies use example.invalid addresses and obviously
# fake ids. Nothing real is committed and nothing real is needed to run it.
#
# CLOCK: every licence minted here carries an explicit far-future or long-past
# expiry, and no assertion below depends on what today's date is.
#
# Exit 0 on pass, 1 on any failure, 99 on CANNOT-RUN. Bash 3.2 portable.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
SWIFT_VERIFIER="${REPO_ROOT}/gui/OstlerInstaller/Auth/LicenseVerifier.swift"
GATE_SRC="${REPO_ROOT}/vendor/cm041/assistant_api/subscription_gate.py"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

cannot_run() {
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was checked. This is not a pass." >&2
    exit 99
}

[[ -f "$INSTALL_SH" ]]      || cannot_run "install.sh not found at ${INSTALL_SH}"
[[ -f "$SWIFT_VERIFIER" ]]  || cannot_run "LicenseVerifier.swift not found at ${SWIFT_VERIFIER}"
[[ -f "$GATE_SRC" ]]        || cannot_run "subscription_gate.py not vendored at ${GATE_SRC}"
command -v python3 >/dev/null 2>&1 \
    || cannot_run "no python3 on PATH; cannot mint synthetic licences"

WORK="$(mktemp -d -t ostler-licence-tier.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── The minting side ───────────────────────────────────────────────
#
# A SEPARATE implementation from the verifier under test: this one signs, the
# shipped one only verifies. Both are pinned to the RFC 8032 section 7.1
# known-answer vector, so a shared bug cannot quietly agree with itself and
# call it a pass.
cat > "${WORK}/mint.py" <<'MINT_PY'
import base64
import binascii
import hashlib
import json
import sys

p = 2 ** 255 - 19
# Curve25519 group order L in hex, for the reason spelled out beside the same
# constant in install.sh: the decimal form is a 38-digit run and
# .github/scripts/ci-pii-shape-scan.sh refuses 15+ digit runs on shape alone.
q = 0x1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED


def modp_inv(x):
    return pow(x, p - 2, p)


d = -121665 * modp_inv(121666) % p
modp_sqrt_m1 = pow(2, (p - 1) // 4, p)


def recover_x(y, sign_bit):
    if y >= p:
        return None
    x2 = (y * y - 1) * modp_inv(d * y * y + 1) % p
    if x2 == 0:
        return None if sign_bit else 0
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * modp_sqrt_m1 % p
    if (x * x - x2) % p != 0:
        return None
    if (x & 1) != sign_bit:
        x = p - x
    return x


g_y = 4 * modp_inv(5) % p
g_x = recover_x(g_y, 0)
G = (g_x, g_y, 1, g_x * g_y % p)


def point_add(P, Q):
    a = (P[1] - P[0]) * (Q[1] - Q[0]) % p
    b = (P[1] + P[0]) * (Q[1] + Q[0]) % p
    c = 2 * P[3] * Q[3] * d % p
    e = 2 * P[2] * Q[2] % p
    return ((b - a) * (e - c) % p, (e + c) * (b + a) % p,
            (e - c) * (e + c) % p, (b - a) * (b + a) % p)


def point_mul(s, P):
    Q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            Q = point_add(Q, P)
        P = point_add(P, P)
        s >>= 1
    return Q


def point_compress(P):
    zinv = modp_inv(P[2])
    x = P[0] * zinv % p
    y = P[1] * zinv % p
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def sha512_modq(s):
    return int.from_bytes(hashlib.sha512(s).digest(), "little") % q


def secret_expand(secret):
    h = hashlib.sha512(secret).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= (1 << 254)
    return (a, h[32:])


def public_key(secret):
    a, _ = secret_expand(secret)
    return point_compress(point_mul(a, G))


def sign(secret, msg):
    a, prefix = secret_expand(secret)
    A = point_compress(point_mul(a, G))
    r = sha512_modq(prefix + msg)
    R = point_mul(r, G)
    Rs = point_compress(R)
    h = sha512_modq(Rs + A + msg)
    s = (r + h * a) % q
    return Rs + int.to_bytes(s, 32, "little")


def canonical(body_dict):
    return json.dumps(body_dict, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def self_test():
    seed = binascii.unhexlify(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    want_pk = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    want_sig = ("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015"
                "55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a10"
                "0b")
    if binascii.hexlify(public_key(seed)).decode() != want_pk:
        raise SystemExit("KAT FAIL: public key")
    if binascii.hexlify(sign(seed, b"")).decode() != want_sig:
        raise SystemExit("KAT FAIL: signature")
    print("mint self-test: RFC 8032 7.1 vector reproduced")


# Synthetic seed. Non-secret, deterministic, used only to sign licences that
# exist for the length of one test run.
SEED = b"OSTLER-SYNTHETIC-TIER-SEED-A" + b"\x00" * 4


def body(expires):
    return {
        "version": 1,
        "license_id": "00000000-0000-4000-8000-000000000000",
        "issued_to_email": "synthetic-tester@example.invalid",
        "purchased_at": "2026-01-01T00:00:00Z",
        "update_window_expires_at": expires,
        "max_hardware_fingerprints": 3,
        "stripe_payment_id": "pi_SYNTHETIC_0000000000",
        "signature_algorithm": "Ed25519",
    }


def main():
    cmd = sys.argv[1]
    if cmd == "selftest":
        self_test()
        return
    if cmd == "pubkey":
        sys.stdout.write(binascii.hexlify(public_key(SEED)).decode())
        return
    if cmd == "mint":
        # mint <out-path> <expires> <tier-or-OMIT-or-NULL>
        out, expires, tier = sys.argv[2], sys.argv[3], sys.argv[4]
        doc = body(expires)
        if tier == "NULL":
            doc["tier"] = None
        elif tier != "OMIT":
            doc["tier"] = tier
        doc["signature"] = base64.b64encode(sign(SEED, canonical(doc))).decode()
        with open(out, "w") as handle:
            json.dump(doc, handle, indent=2, sort_keys=True)
        return
    raise SystemExit("unknown command: %s" % cmd)


main()
MINT_PY

if python3 "${WORK}/mint.py" selftest >"${WORK}/selftest.out" 2>&1; then
    ok "mint side reproduces the RFC 8032 7.1 known-answer vector"
else
    bad "mint side FAILED the RFC 8032 vector -- every licence it mints below is meaningless"
    sed 's/^/        /' "${WORK}/selftest.out"
fi

PUBKEY="$(python3 "${WORK}/mint.py" pubkey)"
[[ "${#PUBKEY}" -eq 64 ]] || cannot_run "synthetic public key is not 64 hex chars"

FAR_FUTURE="2099-01-01T00:00:00Z"

# ───────────────────────────────────────────────────────────────────
# Limb A. The verifier keeps the four states apart.
# ───────────────────────────────────────────────────────────────────
#
# Run against the verifier EXTRACTED FROM install.sh, not a copy of it. A copy
# is a different artefact and would keep passing after install.sh regressed.
sed -n "/^[[:space:]]*_lic_detail=.*<<'OSTLER_LICENCE_VERIFY_PY'\$/,/^OSTLER_LICENCE_VERIFY_PY\$/p" \
    "$INSTALL_SH" | sed '1d;$d' > "${WORK}/shipped_verifier.py"

if [[ ! -s "${WORK}/shipped_verifier.py" ]]; then
    bad "could not extract the verifier heredoc from install.sh -- nothing below limb A was checked"
elif ! grep -q 'def resolve_tier' "${WORK}/shipped_verifier.py"; then
    bad "the extracted verifier has no resolve_tier -- install.sh is not reading a tier at all"
else
    ok "the verifier extracted from install.sh carries a tier resolver"

    # a_case <label> <tier-arg> <expected-rc> <expected-stdout>
    a_case() {
        local label="$1" tier="$2" want_rc="$3" want_out="$4"
        local lic="${WORK}/a.json" rc=0 out
        python3 "${WORK}/mint.py" mint "$lic" "$FAR_FUTURE" "$tier"
        out="$(python3 "${WORK}/shipped_verifier.py" "$lic" "$PUBKEY" 2>/dev/null)" || rc=$?
        if [[ "$rc" != "$want_rc" ]]; then
            bad "${label}: exit ${rc}, expected ${want_rc}"
            return
        fi
        if [[ -n "$want_out" && "$out" != "$want_out" ]]; then
            bad "${label}: printed '${out}', expected '${want_out}'"
            return
        fi
        ok "${label}"
    }

    # The pass line is "<state> <expiry> <tier>". The expiry joined it for
    # HR015 #929: before that the date left this verifier only on the rc-14
    # path, which is to say only once the licence had already lapsed. FAR_FUTURE
    # is the stamp every licence below is minted with.
    a_case "A1 no tier field -> ABSENT, treated as hub"        OMIT       0 "absent ${FAR_FUTURE} hub"
    a_case "A2 tier null -> ABSENT, same as omitted"           NULL       0 "absent ${FAR_FUTURE} hub"
    a_case "A3 tier hub -> KNOWN"                              hub        0 "known ${FAR_FUTURE} hub"
    a_case "A4 tier pro -> KNOWN"                              pro        0 "known ${FAR_FUTURE} pro"
    a_case "A5 tier beta -> KNOWN"                             beta       0 "known ${FAR_FUTURE} beta"
    a_case "A6 tier HUB -> KNOWN, case folded"                 HUB        0 "known ${FAR_FUTURE} hub"
    # The future-tier case. An installer that refused this would turn every
    # tier CM050 invents after this build into a support incident on every Mac
    # already in the field.
    a_case "A7 unrecognised tier -> UNKNOWN, verbatim, NOT refused" enterprise 0 "unknown ${FAR_FUTURE} enterprise"
    # Not a tier at all. A separate state from "unrecognised", and the reason
    # the tier can be handed to the shell on one line at all.
    a_case "A8 tier with a space -> MALFORMED, not unknown"     "beta x"  12 ""
    a_case "A9 empty tier -> MALFORMED"                         ""        12 ""

    # A10. The tier is inside the SIGNED body, so a customer cannot promote
    # themselves by editing the file. Without this, everything above is a
    # statement about a field anybody could rewrite.
    python3 - "${WORK}/mint.py" "${WORK}/a10.json" "$FAR_FUTURE" <<'PROMOTE_PY'
import json
import subprocess
import sys

mint, out, expires = sys.argv[1], sys.argv[2], sys.argv[3]
subprocess.check_call([sys.executable, mint, "mint", out, expires, "hub"])
with open(out) as fh:
    doc = json.load(fh)
doc["tier"] = "pro"          # edited AFTER signing
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
PROMOTE_PY
    a10_rc=0
    python3 "${WORK}/shipped_verifier.py" "${WORK}/a10.json" "$PUBKEY" >/dev/null 2>&1 || a10_rc=$?
    if [[ "$a10_rc" == "13" ]]; then
        ok "A10 tier edited hub -> pro after signing: REFUSED, bad signature"
    else
        bad "A10 a self-promoted tier was accepted (exit ${a10_rc}, expected 13) -- the tier is not signature-covered"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Limb B. The real install.sh, at the real gate, tells the customer.
# ───────────────────────────────────────────────────────────────────
#
# OSTLER_GUI=1 for the same reason test_licence_gate.sh sets it: install.sh
# redirects stdin from /dev/tty unless the GUI is driving, and there is no
# controlling terminal on a CI runner. It does not change gate behaviour.
#
# env -i so an OSTLER_* var in the developer's shell cannot decide the result.
run_gate() {
    local licence="$1"; shift
    local sandbox rc=0
    sandbox="$(mktemp -d "${WORK}/home.XXXXXX")"
    if [[ "$licence" != "NONE" ]]; then
        mkdir -p "${sandbox}/.ostler/license"
        cp "$licence" "${sandbox}/.ostler/license/license.json"
    fi
    env -i \
        PATH="$PATH" \
        HOME="$sandbox" \
        TERM="dumb" \
        OSTLER_GUI=1 \
        OSTLER_TEST_STOP_AFTER_LICENCE_GATE=1 \
        OSTLER_LICENSE_PUBKEY_OVERRIDE="$PUBKEY" \
        "$@" \
        /bin/bash "$INSTALL_SH" >"${WORK}/gate.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

b_case() {
    local label="$1" tier="$2" want_phrase="$3"
    local lic="${WORK}/b.json" rc
    python3 "${WORK}/mint.py" mint "$lic" "$FAR_FUTURE" "$tier"
    rc="$(run_gate "$lic")"
    if [[ "$rc" != "0" ]]; then
        bad "${label}: the gate refused a valid licence (exit ${rc})"
        sed 's/^/        /' "${WORK}/gate.out" | tail -15
        return
    fi
    if ! grep -qF "$want_phrase" "${WORK}/gate.out"; then
        bad "${label}: the gate passed but never said '${want_phrase}'"
        sed 's/^/        /' "${WORK}/gate.out" | tail -15
        return
    fi
    ok "${label}"
}

b_case "B1 a beta tester is told their tier at the gate"  beta       "Licence tier: beta"
b_case "B2 a Pro licence is told its tier"                pro        "Licence tier: pro"
b_case "B3 a legacy licence is told it reads as Hub"      OMIT       "not stated, treating this as a Hub licence"
b_case "B4 an unrecognised tier INSTALLS, loudly"         enterprise "is not one this installer knows"

# B5. The negative control for limb B. If install.sh printed the tier line
# unconditionally, B1 to B4 would pass on a gate that reads nothing. A licence
# the gate REFUSES must print no tier at all.
b5_lic="${WORK}/b5.json"
python3 "${WORK}/mint.py" mint "$b5_lic" "2020-01-01T00:00:00Z" beta
b5_rc="$(run_gate "$b5_lic")"
if [[ "$b5_rc" == "0" ]]; then
    bad "B5 an EXPIRED beta licence installed -- expiry and tier were collapsed into one answer"
elif grep -q 'Licence tier:' "${WORK}/gate.out"; then
    bad "B5 a refused licence still reported a tier -- the tier line is unconditional, so limb B proves nothing"
elif ! grep -q 'ERR-02-LICENCE-REQUIRED' "${WORK}/gate.out"; then
    bad "B5 refused (exit ${b5_rc}) but not with ERR-02-LICENCE-REQUIRED -- wrong failure"
else
    ok "B5 an expired licence is refused and reports NO tier (expired and tiered are different states)"
fi

# ───────────────────────────────────────────────────────────────────
# Limb C + D. The tier reaches the Hub, and a person can see it.
# ───────────────────────────────────────────────────────────────────
#
# Staged the way the wrappers find it: install.sh copies the whole of
# assistant_api/ to ${OSTLER_DIR}/services/ical-server/, a sibling of every
# services/<source> dir. Run the SHIPPED file, never a reimplementation.
HUB="${WORK}/hub"
mkdir -p "${HUB}/services/ical-server" "${HUB}/state"
cp "$GATE_SRC" "${HUB}/services/ical-server/subscription_gate.py"
GATE="${HUB}/services/ical-server/subscription_gate.py"
STATE="${HUB}/state/subscription_state.json"

# activate_keep <tier> <tier-state>  -- through the SAME call install.sh
# makes, against whatever state is already on disk. Never hand-write the state
# file: a fixture that writes the field is testing the fixture.
activate_keep() {
    OSTLER_SUBSCRIPTION_STATE="$STATE" python3 - "$GATE" "$1" "$2" <<'ACTIVATE_PY'
import importlib.util
import sys
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location("subscription_gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
tier = sys.argv[2] or None
gate.activate_first_month_free(
    datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    licence_tier=tier,
    licence_tier_state=sys.argv[3],
)
ACTIVATE_PY
}

# activate <tier> <tier-state>  -- a FRESH Hub. The state file is removed
# first, and it matters: the tier carry-over below is deliberate behaviour,
# so leaving a previous scenario's tier on disk would let a case pass on a
# value it never wrote.
activate() {
    rm -f "$STATE"
    activate_keep "$1" "$2"
}

c_case() {
    local label="$1" tier="$2" tier_state="$3" want_tier="$4" want_state="$5"
    if ! activate "$tier" "$tier_state" >"${WORK}/act.out" 2>&1; then
        bad "${label}: activation raised"
        sed 's/^/        /' "${WORK}/act.out"
        return
    fi
    local got
    got="$(OSTLER_SUBSCRIPTION_STATE="$STATE" python3 - "$GATE" <<'READ_PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("subscription_gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
tier, state = gate.licence_tier()
print("%s %s" % (state, tier if tier else "none"))
READ_PY
)"
    if [[ "$got" == "${want_state} ${want_tier}" ]]; then
        ok "${label}"
    else
        bad "${label}: the Hub reads '${got}', expected '${want_state} ${want_tier}'"
    fi
}

#      label                                              tier  tier-state  want-tier   want-state
c_case "C1 a beta tester's tier reaches the Hub state"     beta       known    beta       known
c_case "C2 a Pro licence's tier reaches the Hub state"     pro        known    pro        known
c_case "C3 a legacy licence is recorded ABSENT, as hub"    hub        absent   hub        absent
c_case "C4 an unrecognised tier survives the round trip"   enterprise unknown  enterprise unknown
# C5. "We did not check" must never be readable as a tier. This is the one
# that stops the whole chain degrading into "everybody is on hub".
c_case "C5 an unverified install reports NO tier"          ""         unverified none    unverified

# C6. A state value that is not one of the four is not a fifth state, it is a
# bad write, and it must not be stored as though it were an answer. Without
# this, any typo at the call site becomes a tier the reader trusts.
c_case "C6 a state outside the four reads as unverified"   beta       gold     none       unverified

# C7. C6 ALONE DOES NOT TEST THE WRITER, and this was measured rather than
# assumed. Mutating activate_first_month_free to accept any truthy state left
# C6 green, because the READER validates too and turned the bad value back
# into "unverified" on the way out. Both halves validate on purpose, so the
# only way to see the writer's half is to look at what landed on disk.
if grep -qF 'gold' "$STATE" 2>/dev/null; then
    bad "C7 an invalid tier-state was WRITTEN to the state file -- only the reader is validating, so a bad write survives on disk for anything that reads the JSON directly"
else
    ok "C7 an invalid tier-state never reaches the state file"
fi

# D1. The customer-visible pause message names the licence. This is the
# consumer-side proof: a paused customer's Hub says which licence they hold,
# so they and support are looking at the same fact.
#
# Drive it to PAUSED through the shipped CLI, by walking a never-paid trial
# past its own expiry -- the same path a real day-31 trialist takes.
activate beta known >/dev/null 2>&1
python3 - "$STATE" <<'AGE_PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)
past = (datetime.now(timezone.utc) - timedelta(days=400)).isoformat().replace("+00:00", "Z")
# Only the DATES move. status, source, has_ever_paid and the tier are left
# exactly as the installer wrote them, so the gate still has to decide.
state["expires_at"] = past
state["last_validated_at"] = past
state["grace_period_end"] = past
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
AGE_PY

d_rc=0
OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --check >"${WORK}/check.out" 2>&1 || d_rc=$?
if [[ "$d_rc" != "3" ]]; then
    bad "D1 a lapsed beta tester was not paused (exit ${d_rc}, expected 3) -- nothing below is about a paused customer"
    sed 's/^/        /' "${WORK}/check.out"
elif grep -qF "licence=beta" "${WORK}/check.out"; then
    ok "D1 the pause message a lapsed beta tester sees names their licence"
else
    bad "D1 the customer was paused but not told which licence they hold"
    sed 's/^/        /' "${WORK}/check.out"
fi

# D2. The negative control for D1. If the message hardcoded the word, D1 would
# pass on a Hub that reads nothing. A Hub with no tier on file must NOT say
# "beta", and must not say "hub" either.
activate "" unverified >/dev/null 2>&1
python3 - "$STATE" <<'AGE_PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)
past = (datetime.now(timezone.utc) - timedelta(days=400)).isoformat().replace("+00:00", "Z")
state["expires_at"] = past
state["last_validated_at"] = past
state["grace_period_end"] = past
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
AGE_PY
d2_rc=0
OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --check >"${WORK}/check2.out" 2>&1 || d2_rc=$?
if [[ "$d2_rc" != "3" ]]; then
    bad "D2 control did not pause (exit ${d2_rc}) -- D1 has no negative control"
elif grep -qF "licence=beta" "${WORK}/check2.out"; then
    bad "D2 an unverified Hub reported licence=beta -- the message is hardcoded and D1 proves nothing"
elif grep -qF "licence=hub" "${WORK}/check2.out"; then
    bad "D2 an unverified Hub reported licence=hub -- 'we did not check' was turned into a tier"
elif grep -qF "licence=unverified" "${WORK}/check2.out"; then
    ok "D2 an unverified Hub says so, and does not invent a tier"
else
    bad "D2 the pause message named no licence state at all"
    sed 's/^/        /' "${WORK}/check2.out"
fi

# D3. The Doctor seam. Exits 0 whatever the tier: asking what licence a
# customer holds is not the same question as whether they may keep ingesting,
# and a non-zero here would make a Hub-tier customer look like a failure.
activate pro known >/dev/null 2>&1
d3_rc=0
d3_out="$(OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --tier 2>&1)" || d3_rc=$?
if [[ "$d3_rc" == "0" && "$d3_out" == "known pro" ]]; then
    ok "D3 --tier answers 'known pro' and exits 0"
else
    bad "D3 --tier printed '${d3_out}' exit ${d3_rc}, expected 'known pro' exit 0"
fi

# ───────────────────────────────────────────────────────────────────
# Limb E. An unverified re-install must not cost a customer their tier.
# ───────────────────────────────────────────────────────────────────
activate beta known >/dev/null 2>&1
if ! activate_keep "" unverified >/dev/null 2>&1; then
    bad "E1 the second activation raised"
else
    e_out="$(OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --tier 2>&1)"
    if [[ "$e_out" == "known beta" ]]; then
        ok "E1 re-running the installer unlicensed keeps the tier the verified install established"
    else
        bad "E1 an unlicensed re-run changed the tier to '${e_out}' (expected 'known beta')"
    fi
fi

# E2. The same property across an iOS receipt push. refresh_from_companion
# builds a FRESH state dict, so without an explicit carry it erases the tier
# on the customer's first subscription -- silently, and on the happy path.
activate beta known >/dev/null 2>&1
if OSTLER_SUBSCRIPTION_STATE="$STATE" python3 - "$GATE" <<'RECEIPT_PY' >"${WORK}/receipt.out" 2>&1
import importlib.util
import sys
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("subscription_gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
future = (datetime.now(timezone.utc) + timedelta(days=30)).isoformat().replace("+00:00", "Z")
# Synthetic, and not a receipt: the gate stores whatever string it is handed.
gate.refresh_from_companion("SYNTHETIC-RECEIPT-NOT-A-REAL-ONE", future)
RECEIPT_PY
then
    e2_out="$(OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --tier 2>&1)"
    if [[ "$e2_out" == "known beta" ]]; then
        ok "E2 an iOS receipt push does not erase the licence tier"
    else
        bad "E2 the tier became '${e2_out}' after a receipt push (expected 'known beta')"
    fi
else
    bad "E2 the receipt push raised"
    sed 's/^/        /' "${WORK}/receipt.out"
fi

# ───────────────────────────────────────────────────────────────────
# Limb F. The two verifiers agree about `tier`.
# ───────────────────────────────────────────────────────────────────
#
# They are separate implementations of one frozen schema, on two languages,
# and install.sh's own comments already record one place they diverge ON
# PURPOSE. This limb watches the place they must NOT.
#
# Read the Swift SOURCE rather than running it: building the GUI target needs
# a macOS runner, a pinned Xcode, python-build-standalone and a signed Safari
# extension, none of which exist where this test runs. A source assertion is
# weaker than an execution and is said to be: swift-tests.yml runs the
# executable half (LicenseVerifierTests), and this half exists so that a
# shell-only change cannot silently walk away from it.
f_fail=0
f_check() {
    local what="$1" pattern="$2"
    if grep -qE "$pattern" "$SWIFT_VERIFIER"; then
        return 0
    fi
    bad "F: the Swift verifier ${what}"
    f_fail=1
}

f_check "has no 'tier' coding key"                'case tier'
f_check "does not declare tier as an optional String" 'let tier: String\?'
f_check "has no tier well-formedness check"       'isWellFormedTier'
f_check "does not know the three tiers"           'case "beta": self = \.beta'

# The character class must be the SAME class. Two schema rules written
# differently in two languages is how they drift, and a tier accepted by one
# side and refused by the other aborts an install the GUI called fine.
if grep -qE '"a"\.\.\."z", "A"\.\.\."Z", "0"\.\.\."9", "_", "\.", "-"' "$SWIFT_VERIFIER" \
   && grep -qF 'abcdefghijklmnopqrstuvwxyz' "$INSTALL_SH" \
   && grep -qF '0123456789_.-' "$INSTALL_SH"; then
    ok "F1 both verifiers constrain the tier to the same character class"
else
    bad "F1 the two verifiers' tier character classes do not match -- one will accept what the other refuses"
    f_fail=1
fi

# The null rule. This one has already bitten inside this change: the first
# version of the shell check refused an explicit null that Swift accepts, so a
# licence carrying "tier": null passed the GUI and aborted the install.
if grep -qF 'doc.get("tier") is not None' "$INSTALL_SH"; then
    ok "F2 the shell verifier treats an explicit null tier as absent, as Swift does"
else
    bad "F2 the shell verifier no longer treats 'tier': null as absent -- it now diverges from Swift, which cannot see the difference"
    f_fail=1
fi

[[ "$f_fail" -eq 0 ]] && ok "F3 the Swift verifier carries the whole tier contract"

# ───────────────────────────────────────────────────────────────────
printf '\n%s\n' "----------------------------------------------------------"
printf 'licence tier reaches the Hub: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
