#!/usr/bin/env bash
#
# tests/test_licence_gate.sh
#
# PROOF THAT THE SHELL INSTALL PATH REFUSES TO INSTALL WITHOUT A LICENCE.
#
# WHY (2026-08-16, Andy directive)
# --------------------------------
# install.sh is a PUBLIC script advertised as
#   curl -fsSL https://ostler.ai/install.sh | bash
# and until today it contained no licence enforcement at all. Measured on
# origin/main that morning:
#
#     ERR-02-LICENCE-REQUIRED    0 hits
#     allow-unlicensed           0 hits
#     OSTLER_DEV                 0 hits
#     OSTLER_ASSISTANT_VERSION  19 hits   <- control, proving the grep worked
#
# One command installed the entire paid product for free. The only Ed25519
# verification in the repo lived in the Swift GUI, which the shell path never
# runs.
#
# WHAT THIS TEST PINS
# -------------------
# Black box, against the REAL install.sh, five outcomes:
#
#   1. no licence file            -> REFUSES, non-zero, ERR-02-LICENCE-REQUIRED
#   2. malformed / empty licence  -> REFUSES (zero-byte, non-JSON, and a
#                                    hand-edited body whose signature no
#                                    longer covers it)
#   3. licence signed by the WRONG key -> REFUSES. This is the case that
#      separates real verification from a file-exists check: the file is
#      present, well-formed, schema-valid, and signed -- just not by us.
#   4. valid licence              -> PROCEEDS. Without this the gate has only
#      ever been observed failing, and a gate never observed passing is not
#      known to be able to pass.
#   5. escape hatch set           -> PROCEEDS, loudly (OSTLER_DEV=1 and
#      --allow-unlicensed, each asserted to print the unlicensed banner).
#
# Plus the checks that keep the above honest:
#   6. the SHIPPED verifier (extracted from install.sh) reproduces the
#      RFC 8032 section 7.1 known-answer vector, and rejects a tampered
#      message. A stub that returned True would pass cases 1-5 and fail here.
#   7. the test hook OSTLER_TEST_STOP_AFTER_LICENCE_GATE cannot be used to
#      skip the gate -- with no licence it still refuses.
#   8. an expired licence refuses (matching the GUI, which refuses .expired).
#   9. install.sh's public key constant still equals productionPublicKeyHex in
#      gui/OstlerInstaller/Auth/LicenseVerifier.swift. If the Swift key rotates
#      and this copy does not, every real licence would fail at the gate.
#
# SYNTHETIC DATA ONLY. Keys are generated inside this test from fixed
# non-secret seeds, licence bodies use example.invalid addresses and obviously
# fake ids. Nothing real is committed, and nothing real is needed to run it.
#
# Hermetic: no network, no Homebrew, no install. Each case runs install.sh
# with a sandboxed HOME and stops at the gate.
#
# OSTLER_GUI=1 is set on every invocation for one reason only: install.sh
# redirects stdin from /dev/tty unless the GUI is driving, and there is no
# controlling terminal on a CI runner. It does not change gate behaviour --
# the real progress emitter is not sourced until ~1000 lines later, so the
# no-op gui_* stubs are still in place and every message still prints.
#
# Exit 0 on pass, 1 on any failure. Portable to bash 3.2 (macOS /bin/bash).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
SWIFT_VERIFIER="${REPO_ROOT}/gui/OstlerInstaller/Auth/LicenseVerifier.swift"

WORK="$(mktemp -d -t ostler-licence-gate.XXXXXX)"
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

# ── The minting side: Ed25519 sign, RFC 8032 reference construction ──
#
# Deliberately a SEPARATE implementation from the verifier under test (this
# one signs; the shipped one only verifies), and both are pinned to the RFC
# 8032 known-answer vector below, so a shared bug cannot quietly agree with
# itself and call it a pass.
cat > "${WORK}/mint.py" <<'MINT_PY'
import base64
import binascii
import hashlib
import json
import sys

p = 2 ** 255 - 19
# Curve25519 group order L in hex, for the reason spelled out beside the
# same constant in install.sh: the decimal form is a 38-digit run and
# .github/scripts/ci-pii-shape-scan.sh refuses 15+ digit runs on shape
# alone. Value unchanged, RFC 8032 s5.1.
q = 0x1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED


def modp_inv(x):
    return pow(x, p - 2, p)


d = -121665 * modp_inv(121666) % p
modp_sqrt_m1 = pow(2, (p - 1) // 4, p)


def recover_x(y, sign):
    if y >= p:
        return None
    x2 = (y * y - 1) * modp_inv(d * y * y + 1) % p
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * modp_sqrt_m1 % p
    if (x * x - x2) % p != 0:
        return None
    if (x & 1) != sign:
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
    return a, h[32:]


def public_key(secret):
    a, _ = secret_expand(secret)
    return point_compress(point_mul(a, G))


def sign(secret, msg):
    a, prefix = secret_expand(secret)
    A = point_compress(point_mul(a, G))
    r = sha512_modq(prefix + msg)
    Rs = point_compress(point_mul(r, G))
    h = sha512_modq(Rs + A + msg)
    return Rs + int.to_bytes((r + h * a) % q, 32, "little")


def canonical(body):
    return json.dumps(body, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


# RFC 8032 section 7.1, TEST 1. The signer has to reproduce this byte for
# byte or the licences it mints prove nothing about Ed25519.
def self_test():
    seed = binascii.unhexlify(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    want_pk = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    want_sig = ("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015"
                "55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a10"
                "0b")
    got_pk = binascii.hexlify(public_key(seed)).decode()
    got_sig = binascii.hexlify(sign(seed, b"")).decode()
    if got_pk != want_pk:
        raise SystemExit("KAT FAIL: public key %s != %s" % (got_pk, want_pk))
    if got_sig != want_sig:
        raise SystemExit("KAT FAIL: signature %s != %s" % (got_sig, want_sig))
    print("mint self-test: RFC 8032 7.1 vector reproduced")


# Synthetic seeds. Non-secret, deterministic, and used only to sign licences
# that exist for the length of one test run.
SEEDS = {
    "ours": b"OSTLER-SYNTHETIC-TEST-SEED-A" + b"\x00" * 4,
    "theirs": b"OSTLER-SYNTHETIC-TEST-SEED-B" + b"\x00" * 4,
}


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
        sys.stdout.write(binascii.hexlify(public_key(SEEDS[sys.argv[2]])).decode())
        return
    if cmd == "mint":
        # mint <seed-name> <out-path> <expires> [tamper]
        seed, out, expires = SEEDS[sys.argv[2]], sys.argv[3], sys.argv[4]
        doc = body(expires)
        doc["signature"] = base64.b64encode(sign(seed, canonical(doc))).decode()
        if len(sys.argv) > 5 and sys.argv[5] == "tamper":
            # Hand-edited after signing: still valid JSON, still schema
            # correct, signature no longer covers the body.
            doc["max_hardware_fingerprints"] = 99
        with open(out, "w") as handle:
            json.dump(doc, handle, indent=2, sort_keys=True)
        return
    raise SystemExit("unknown command: %s" % cmd)


main()
MINT_PY

# ── Case 6 (run first: it validates the instruments) ────────────────
#
# The minting side reproduces the RFC vector...
if python3 "${WORK}/mint.py" selftest >"${WORK}/selftest.out" 2>&1; then
    ok "mint side reproduces the RFC 8032 7.1 known-answer vector"
else
    bad "mint side FAILED the RFC 8032 known-answer vector -- every licence it mints below is meaningless"
    sed 's/^/        /' "${WORK}/selftest.out"
fi

# ...and so does the verifier that actually ships inside install.sh. Extract
# it from the heredoc and run the vector through the shipped functions. A
# verifier that always returned true would sail through cases 1-5 (they only
# watch it refuse) and die here.
sed -n "/^[[:space:]]*_lic_detail=.*<<'OSTLER_LICENCE_VERIFY_PY'$/,/^OSTLER_LICENCE_VERIFY_PY$/p" \
    "$INSTALL_SH" | sed '1d;$d' > "${WORK}/shipped_verifier.py"

if [[ ! -s "${WORK}/shipped_verifier.py" ]]; then
    bad "could not extract the verifier heredoc from install.sh -- extraction produced nothing, so nothing below was checked"
elif ! grep -q 'def ed25519_verify' "${WORK}/shipped_verifier.py"; then
    bad "extracted heredoc has no ed25519_verify -- install.sh is not carrying a signature verifier"
else
    if python3 - "${WORK}/shipped_verifier.py" <<'KAT_PY' >"${WORK}/kat.out" 2>&1
import binascii
import sys

src = open(sys.argv[1]).read()
marker = "# === entrypoint ==="
if marker not in src:
    raise SystemExit("entrypoint marker missing -- cannot load definitions safely")
namespace = {"__name__": "ostler_shipped_verifier"}
exec(compile(src.split(marker)[0], "shipped_verifier", "exec"), namespace)
verify = namespace["ed25519_verify"]
pk = binascii.unhexlify(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
sig = binascii.unhexlify(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
if verify(pk, b"", sig) is not True:
    raise SystemExit("shipped verifier REJECTED the RFC 8032 7.1 vector")
if verify(pk, b"tampered", sig) is not False:
    raise SystemExit("shipped verifier ACCEPTED a tampered message")
other = binascii.unhexlify(
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
if verify(other, b"", sig) is not False:
    raise SystemExit("shipped verifier ACCEPTED a signature from another key")
print("shipped verifier: RFC 8032 7.1 accepted, tamper rejected, wrong key rejected")
KAT_PY
    then
        ok "shipped verifier is a real Ed25519 verifier (RFC vector accepted, tamper + wrong key rejected)"
    else
        bad "shipped verifier failed the RFC 8032 known-answer check"
        sed 's/^/        /' "${WORK}/kat.out"
    fi
fi

# ── Keys + licences for the black-box cases ────────────────────────
OUR_PUBKEY="$(python3 "${WORK}/mint.py" pubkey ours)"
if [[ "${#OUR_PUBKEY}" -ne 64 ]]; then
    echo "CANNOT RUN: synthetic public key is not 64 hex chars." >&2
    exit 1
fi

FAR_FUTURE="2099-01-01T00:00:00Z"
LONG_PAST="2020-01-01T00:00:00Z"

python3 "${WORK}/mint.py" mint ours   "${WORK}/valid.json"   "$FAR_FUTURE"
python3 "${WORK}/mint.py" mint ours   "${WORK}/tampered.json" "$FAR_FUTURE" tamper
python3 "${WORK}/mint.py" mint theirs "${WORK}/wrongkey.json" "$FAR_FUTURE"
python3 "${WORK}/mint.py" mint ours   "${WORK}/expired.json"  "$LONG_PAST"
: > "${WORK}/empty.json"
printf 'this is not a licence, it is a sentence.\n' > "${WORK}/garbage.json"

# run_case <licence-file-or-NONE> <extra-env-pairs-or-empty> [install.sh args...]
#
# Echoes the REAL exit code to stdout and leaves combined output in
# ${WORK}/last.out. Every invocation gets a fresh sandbox HOME and a scrubbed
# environment (env -i), so an OSTLER_* var in the developer's shell cannot
# quietly decide the result.
#
# /bin/bash on purpose: on macOS that is bash 3.2, the interpreter a
# customer's Mac actually runs install.sh under.
run_case() {
    local licence="$1"; shift
    local env_extra="$1"; shift
    local sandbox
    sandbox="$(mktemp -d "${WORK}/home.XXXXXX")"
    if [[ "$licence" != "NONE" ]]; then
        mkdir -p "${sandbox}/.ostler/license"
        cp "$licence" "${sandbox}/.ostler/license/license.json"
    fi
    local rc=0
    # env_extra is deliberately unquoted: it carries zero or more VAR=VALUE
    # pairs and needs word splitting. Values never contain spaces.
    # shellcheck disable=SC2086
    env -i \
        PATH="$PATH" \
        HOME="$sandbox" \
        TERM="dumb" \
        OSTLER_GUI=1 \
        OSTLER_TEST_STOP_AFTER_LICENCE_GATE=1 \
        OSTLER_LICENSE_PUBKEY_OVERRIDE="$OUR_PUBKEY" \
        $env_extra \
        /bin/bash "$INSTALL_SH" "$@" >"${WORK}/last.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# assert_refused <label> <rc>
assert_refused() {
    local label="$1" rc="$2"
    if [[ "$rc" == "0" ]]; then
        bad "${label}: install.sh EXITED 0 -- it did not refuse"
        sed 's/^/        /' "${WORK}/last.out" | tail -20
        return
    fi
    if ! grep -q 'ERR-02-LICENCE-REQUIRED' "${WORK}/last.out"; then
        bad "${label}: refused (exit ${rc}) but without ERR-02-LICENCE-REQUIRED -- wrong failure, so this proves nothing"
        sed 's/^/        /' "${WORK}/last.out" | tail -20
        return
    fi
    if grep -q 'OSTLER_TEST: licence gate passed' "${WORK}/last.out"; then
        bad "${label}: refused AND passed the gate -- contradictory output"
        return
    fi
    ok "${label}: refused, exit ${rc}, ERR-02-LICENCE-REQUIRED"
}

# assert_proceeded <label> <rc>
assert_proceeded() {
    local label="$1" rc="$2"
    if [[ "$rc" != "0" ]]; then
        bad "${label}: expected the gate to pass, got exit ${rc}"
        sed 's/^/        /' "${WORK}/last.out" | tail -20
        return
    fi
    if grep -q 'ERR-02-LICENCE-REQUIRED' "${WORK}/last.out"; then
        bad "${label}: exit 0 but the refusal code is in the output"
        return
    fi
    if ! grep -q 'OSTLER_TEST: licence gate passed' "${WORK}/last.out"; then
        bad "${label}: exit 0 but the past-the-gate marker never printed -- install.sh stopped somewhere else"
        sed 's/^/        /' "${WORK}/last.out" | tail -20
        return
    fi
    ok "${label}: proceeded past the gate, exit 0"
}

echo "==> Case 1: no licence file"
RC="$(run_case NONE "")"
assert_refused "no licence file" "$RC"

echo "==> Case 2: malformed / empty licence"
RC="$(run_case "${WORK}/empty.json" "")"
assert_refused "zero-byte licence" "$RC"
RC="$(run_case "${WORK}/garbage.json" "")"
assert_refused "non-JSON licence" "$RC"
RC="$(run_case "${WORK}/tampered.json" "")"
assert_refused "hand-edited licence body" "$RC"

echo "==> Case 3: licence signed by the WRONG key"
RC="$(run_case "${WORK}/wrongkey.json" "")"
assert_refused "wrong-key licence" "$RC"
# The distinguishing assertion: this file is present, parses, and matches the
# schema. Only the signature is foreign. If the gate were an existence check
# it would have said yes.
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['version']==1 and d['signature_algorithm']=='Ed25519' and d['signature'] else 1)" "${WORK}/wrongkey.json"; then
    ok "wrong-key licence was well-formed and schema-valid -- refusal came from the signature, not the shape"
else
    bad "wrong-key fixture is not schema-valid, so case 3 did not test what it claims"
fi

echo "==> Case 4: valid licence (positive control)"
RC="$(run_case "${WORK}/valid.json" "")"
assert_proceeded "valid licence" "$RC"
if grep -q 'Licence verified' "${WORK}/last.out"; then
    ok "valid licence: gate printed its verified line"
else
    bad "valid licence: gate did not print the verified line"
fi

echo "==> Case 5: escape hatch"
RC="$(run_case NONE "OSTLER_DEV=1")"
assert_proceeded "OSTLER_DEV=1 with no licence" "$RC"
BANNERS="$(grep -c 'RUNNING UNLICENSED' "${WORK}/last.out")" || BANNERS=0
if [[ "$BANNERS" -ge 3 ]]; then
    ok "OSTLER_DEV=1: unlicensed banner printed ${BANNERS} times (loud)"
else
    bad "OSTLER_DEV=1: unlicensed banner printed ${BANNERS} times -- a quiet escape hatch is how this defect comes back"
fi

RC="$(run_case NONE "" --allow-unlicensed)"
assert_proceeded "--allow-unlicensed with no licence" "$RC"
BANNERS="$(grep -c 'RUNNING UNLICENSED' "${WORK}/last.out")" || BANNERS=0
if [[ "$BANNERS" -ge 3 ]]; then
    ok "--allow-unlicensed: unlicensed banner printed ${BANNERS} times (loud)"
else
    bad "--allow-unlicensed: unlicensed banner printed ${BANNERS} times -- expected a loud banner"
fi

echo "==> Case 7: the test hook cannot skip the gate"
# run_case always sets OSTLER_TEST_STOP_AFTER_LICENCE_GATE=1, and case 1
# refused with it set. Restate the claim explicitly so the invariant is
# named where a future reader looks for it.
RC="$(run_case NONE "")"
assert_refused "stop-hook set, no licence" "$RC"

echo "==> Case 8: expired licence"
RC="$(run_case "${WORK}/expired.json" "")"
assert_refused "expired licence" "$RC"
if grep -q '2020-01-01T00:00:00Z' "${WORK}/last.out"; then
    ok "expired licence: refusal names the expiry date"
else
    bad "expired licence: refusal did not name the expiry date"
fi

echo "==> Case 9: install.sh public key still matches the Swift verifier"
SHELL_KEY="$(grep -E '^OSTLER_LICENCE_PUBKEY="[0-9a-f]{64}"$' "$INSTALL_SH" | sed -E 's/^OSTLER_LICENCE_PUBKEY="([0-9a-f]{64})"$/\1/')"
if [[ -f "$SWIFT_VERIFIER" ]]; then
    SWIFT_KEY="$(grep -oE '"[0-9a-f]{64}"' "$SWIFT_VERIFIER" | head -1 | tr -d '"')"
else
    SWIFT_KEY=""
fi
if [[ -z "$SHELL_KEY" || -z "$SWIFT_KEY" ]]; then
    bad "could not read both public keys (shell='${SHELL_KEY:-<none>}' swift='${SWIFT_KEY:-<none>}') -- a missing key reads identical to a matching one, so this is a failure"
elif [[ "$SHELL_KEY" == "$SWIFT_KEY" ]]; then
    ok "install.sh and LicenseVerifier.swift carry the same production public key"
else
    bad "public key drift: install.sh has ${SHELL_KEY}, LicenseVerifier.swift has ${SWIFT_KEY}. Every real licence would fail the shell gate."
fi

# ── Result ─────────────────────────────────────────────────────────
echo
echo "passed: ${PASS}   failed: ${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: the shell install path does not enforce the licence as specified." >&2
    exit 1
fi
if [[ "$PASS" -lt 18 ]]; then
    echo "FAIL: only ${PASS} assertions ran; expected 18. A shrinking assertion count is how this gate goes quiet." >&2
    exit 1
fi
echo "PASS: install.sh requires a valid licence, and says so when it refuses."
exit 0
