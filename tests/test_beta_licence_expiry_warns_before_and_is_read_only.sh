#!/usr/bin/env bash
#
# tests/test_beta_licence_expiry_warns_before_and_is_read_only.sh
#
# HR015 #929: "Time-limited beta licences for early testers."
#
# THE TWO RULES ANDY CALLED NON-NEGOTIABLE, AND THEY ARE WHAT THIS TESTS
# ----------------------------------------------------------------------
#   1. Expiry degrades to READ-ONLY, never destructive. A lapsed tester
#      keeps their data and loses the product working. "Deleting a
#      tester's life because a date passed is unrecoverable
#      reputationally."
#   2. They are warned BEFORE it happens, in the product, not after.
#
# WHAT WAS MEASURED ON origin/main BEFORE ANY OF THIS
# ---------------------------------------------------
# The issue's own prerequisite ("does the Hub enforce expiry today, and
# what does it do at lapse") measured as:
#
#   at INSTALL time     yes. An update_window_expires_at in the past
#                       returns rc 14 and install.sh refuses with
#                       ERR-02-LICENCE-REQUIRED, naming the date.
#   on a RUNNING Hub    NO. Nothing re-opens the licence file after
#                       install. The only thing that pauses a Hub is
#                       subscription_state.json, whose expires_at comes
#                       from the 30-day free month or an iOS receipt and
#                       NEVER from the licence.
#
# So a beta tester got 30 days of Ostler Pro whatever their beta licence
# said. A 90-day tester lost the product on day 31 with their beta still
# running; a 14-day tester kept it a fortnight after their beta ended.
# Neither is what the licence they were given says.
#
# And the date left install.sh's verifier ONLY on the rc-14 path, which
# is to say only once the licence had already lapsed -- the one moment it
# is too late to warn anybody.
#
# WHAT THIS TEST PINS
# -------------------
#   Limb A  the beta window IS the entitlement window, end to end from a
#           signed licence through the real install.sh.
#   Limb B  the warning fires BEFORE, at a dozen fixed instants either
#           side of a fixed expiry, with the clock injected.
#   Limb C  lapse is READ-ONLY. Files a customer owns are byte-identical
#           across the lapse, and the paused surface says "paused", never
#           "locked".
#   Limb D  the warning reaches a surface a PERSON looks at: the Doctor
#           panel, and the --check the five shipped tick wrappers already
#           make on every tick.
#   Limb E  the two copies of the warn-window constant agree. The Doctor
#           is vendored separately and staged into its own DOCTOR_DIR, so
#           it cannot import the gate; the number is duplicated on
#           purpose and pinned here, the same way test_licence_gate.sh
#           pins install.sh's public key to the Swift one.
#
# CLOCK, AND WHY THIS FILE WOULD OTHERWISE ROT. A window is exactly the
# thing whose tests rot, because every interesting instant is defined
# relative to a moment. Limb B therefore passes `now` explicitly to
# subscription_gate.expiry_warning at each instant and never consults the
# wall clock. Limbs A, C and D use dates computed relative to whenever
# the run happens, so they are stable on any date but never assert a
# calendar value. No fixture carries a hardcoded "today".
#
# SYNTHETIC DATA ONLY. Keys generated in-run from a fixed non-secret
# seed; example.invalid addresses; obviously fake ids. Nothing real.
#
# Exit 0 on pass, 1 on failure, 99 on CANNOT-RUN. Bash 3.2 portable.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
GATE_SRC="${REPO_ROOT}/vendor/cm041/assistant_api/subscription_gate.py"
DOCTOR_RULES="${REPO_ROOT}/vendor/doctor/agent/diagnostic_rules.py"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

cannot_run() {
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was checked. This is not a pass." >&2
    exit 99
}

# A SINGLE ARM that could not run, as distinct from the whole suite. It is
# counted, printed, and it makes the suite exit non-zero, because an arm that
# was not evaluated is not an arm that passed. It is NOT counted as a FAIL,
# because "the thing is broken" and "I could not look at the thing" send a
# reader to two different places.
CANNOT=0
cannot_run_arm() { printf '  CANNOT-RUN  %s\n' "$1" >&2; CANNOT=$((CANNOT + 1)); }

[[ -f "$INSTALL_SH" ]]    || cannot_run "install.sh not found at ${INSTALL_SH}"
[[ -f "$GATE_SRC" ]]      || cannot_run "subscription_gate.py not vendored at ${GATE_SRC}"
[[ -f "$DOCTOR_RULES" ]]  || cannot_run "diagnostic_rules.py not vendored at ${DOCTOR_RULES}"
command -v python3 >/dev/null 2>&1 \
    || cannot_run "no python3 on PATH; cannot mint synthetic licences"

WORK="$(mktemp -d -t ostler-beta-expiry.XXXXXX)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Reuse the mint side from the tier test rather than carrying a second
# copy of an Ed25519 signer. Extracted from the file, so a change there
# cannot leave a stale duplicate here.
TIER_TEST="${REPO_ROOT}/tests/test_licence_tier_reaches_the_hub.sh"
[[ -f "$TIER_TEST" ]] || cannot_run "tests/test_licence_tier_reaches_the_hub.sh not found; its mint side is this test's signer"
# TWO STEPS, NOT A PIPE. The pipefail ratchet counts a pipe into sed as a
# short-circuit risk, and it is right to count shapes rather than reason about
# each one: a consumer that can stop early SIGPIPEs its producer, and under
# `set -o pipefail` that turns a correct extraction into a failed one. This
# particular pair would not short-circuit, because `$d` forces the second sed
# to read to EOF, but arguing the exception in a ratchet is how exceptions
# accumulate. A temporary file costs nothing here and the output is identical.
sed -n "/^cat > \"\${WORK}\/mint.py\" <<'MINT_PY'\$/,/^MINT_PY\$/p" "$TIER_TEST" \
    > "${WORK}/mint.raw"
sed '1d;$d' "${WORK}/mint.raw" > "${WORK}/mint.py"
[[ -s "${WORK}/mint.py" ]] || cannot_run "could not extract the minting side from ${TIER_TEST}"

if python3 "${WORK}/mint.py" selftest >"${WORK}/selftest.out" 2>&1; then
    ok "mint side reproduces the RFC 8032 7.1 known-answer vector"
else
    bad "mint side FAILED the RFC 8032 vector -- every licence it mints below is meaningless"
    sed 's/^/        /' "${WORK}/selftest.out"
fi

PUBKEY="$(python3 "${WORK}/mint.py" pubkey)"
[[ "${#PUBKEY}" -eq 64 ]] || cannot_run "synthetic public key is not 64 hex chars"

# Dates relative to the run, never a hardcoded calendar value.
ninety_days_out="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=90)).replace(microsecond=0).isoformat().replace('+00:00','Z'))")"
three_days_out="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=3)).replace(microsecond=0).isoformat().replace('+00:00','Z'))")"

# ───────────────────────────────────────────────────────────────────
# Limb A. The beta window IS the entitlement window.
# ───────────────────────────────────────────────────────────────────
#
# Through the REAL install.sh gate, with a sandboxed HOME, then through
# the SAME activation call install.sh makes. Never hand-write the state
# file: a fixture that writes expires_at is testing the fixture.
HUB="${WORK}/hub"
mkdir -p "${HUB}/services/ical-server" "${HUB}/state"
cp "$GATE_SRC" "${HUB}/services/ical-server/subscription_gate.py"
GATE="${HUB}/services/ical-server/subscription_gate.py"
STATE="${HUB}/state/subscription_state.json"

# gate_fields <licence-file> -> echoes the gate's own "<state> <expiry> <tier>"
# line as install.sh parses it, by running the REAL script and reading
# back what it exported. Proves the shell parse, not just the verifier.
gate_fields() {
    local licence="$1" sandbox
    sandbox="$(mktemp -d "${WORK}/home.XXXXXX")"
    mkdir -p "${sandbox}/.ostler/license"
    cp "$licence" "${sandbox}/.ostler/license/license.json"
    env -i \
        PATH="$PATH" \
        HOME="$sandbox" \
        TERM="dumb" \
        OSTLER_GUI=1 \
        OSTLER_TEST_STOP_AFTER_LICENCE_GATE=1 \
        OSTLER_LICENSE_PUBKEY_OVERRIDE="$PUBKEY" \
        /bin/bash "$INSTALL_SH" >"${WORK}/gate.out" 2>&1
}

python3 "${WORK}/mint.py" mint "${WORK}/beta90.json" "$ninety_days_out" beta
if gate_fields "${WORK}/beta90.json"; then
    if grep -qF "Licence tier: beta" "${WORK}/gate.out"; then
        ok "A1 a 90-day beta licence passes the real gate and is named as beta"
    else
        bad "A1 the gate passed but did not name the tier"
        sed 's/^/        /' "${WORK}/gate.out" | tail -12
    fi
    # A1b. THE SHELL PARSE, WHICH IS NEW AND IS ITS OWN FAILURE MODE.
    # The verifier now emits three fields where it emitted two, and
    # install.sh splits them with parameter expansion. If that split is
    # off by one field, the tier line above still prints (it takes the
    # remainder) while the DATE is silently the tier or the state. The
    # only way to see it is to assert the date install.sh actually read.
    if grep -qF "Your beta runs until ${ninety_days_out}." "${WORK}/gate.out"; then
        ok "A1b install.sh parsed the expiry out of the gate line and told the tester their window"
    else
        bad "A1b install.sh did not report the beta window as ${ninety_days_out} -- the three-field parse is wrong"
        sed 's/^/        /' "${WORK}/gate.out" | tail -12
    fi
    # A1c. The read-only promise is made at INSTALL time too, not only
    # at lapse. A tester agreeing to a time-limited licence should know
    # what happens at the end of it before it happens.
    if grep -qF "keeps everything you give it" "${WORK}/gate.out"; then
        ok "A1c the installer tells a beta tester, up front, that nothing is taken away at the end"
    else
        bad "A1c the installer never promises the tester their data survives the window"
    fi
else
    bad "A1 the real install.sh refused a valid 90-day beta licence"
    sed 's/^/        /' "${WORK}/gate.out" | tail -12
fi

# A1d. The negative control for A1b and A1c. A PRO licence must not be
# shown a window at all: its update window is about updates, and printing
# it would read as an expiry date on a one-off purchase. Without this,
# A1b/A1c would pass on an unconditional pair of lines.
python3 "${WORK}/mint.py" mint "${WORK}/pro90.json" "$ninety_days_out" pro
if gate_fields "${WORK}/pro90.json" && ! grep -qF "runs until" "${WORK}/gate.out"; then
    ok "A1d a pro licence is shown no window (the beta lines are conditional)"
else
    bad "A1d a pro licence was shown a beta window, or the gate refused it"
    sed 's/^/        /' "${WORK}/gate.out" | tail -12
fi

# A2. The whole point. Activate exactly as install.sh does, and assert the
# Hub's own window follows the LICENCE, not a calendar month.
activate() {
    # activate <tier> <tier-state> <licence-expiry-or-empty>
    OSTLER_SUBSCRIPTION_STATE="$STATE" python3 - "$GATE" "$1" "$2" "${3:-}" <<'ACTIVATE_PY'
import importlib.util
import sys
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location("subscription_gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
gate.activate_first_month_free(
    datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    licence_tier=sys.argv[2] or None,
    licence_tier_state=sys.argv[3],
    licence_expires_at=sys.argv[4] or None,
)
ACTIVATE_PY
}

read_field() {
    python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))" "$STATE" "$1"
}

rm -f "$STATE"
activate beta known "$ninety_days_out"
if [[ "$(read_field expires_at)" == "$ninety_days_out" ]]; then
    ok "A2 a 90-day beta tester's Pro window is their BETA window, not 30 days"
else
    bad "A2 the beta window was ignored: state expires_at is $(read_field expires_at), licence says ${ninety_days_out}"
fi

# A3. The other direction, and the one a clamp would get wrong. A beta
# SHORTER than a month must not be stretched to 30 days either.
rm -f "$STATE"
activate beta known "$three_days_out"
if [[ "$(read_field expires_at)" == "$three_days_out" ]]; then
    ok "A3 a 3-day beta window is not stretched to the 30-day free month"
else
    bad "A3 a 3-day beta window became $(read_field expires_at)"
fi

# A4. THE CONTROL THAT STOPS A2 AND A3 BEING VACUOUS. A hub or pro
# licence must keep the 30-day free month. Their update window is about
# UPDATES, not about whether the product runs, and reading it as an
# entitlement would cut off paying customers. If A2/A3 passed by making
# every licence's window authoritative, this fails.
rm -f "$STATE"
activate pro known "$three_days_out"
if [[ "$(read_field expires_at)" == "$three_days_out" ]]; then
    bad "A4 a PRO licence's update window was read as its entitlement -- a paying customer would be cut off in 3 days"
else
    ok "A4 a pro licence keeps the 30-day free month; only beta reads its licence window"
fi

# A5. An unreadable beta window must not become an unlimited one. Three
# states: a window, no window, and a window we cannot read.
rm -f "$STATE"
activate beta known "not-a-date"
a5="$(read_field expires_at)"
if [[ -z "$a5" || "$a5" == "not-a-date" ]]; then
    bad "A5 an unparseable beta window produced expires_at='${a5}'"
else
    ok "A5 an unparseable beta window falls back to the 30-day month, never to no window at all"
fi

# ───────────────────────────────────────────────────────────────────
# Limb B. Warned BEFORE, with the clock injected.
# ───────────────────────────────────────────────────────────────────
#
# Twelve fixed instants either side of a fixed expiry. `now` is passed
# explicitly, so this limb cannot rot on a date nobody chose, and no
# environment variable can move it either: a clock the launching process
# can set is a clock an unpaid install can set to last year.
if OSTLER_SUBSCRIPTION_STATE="$STATE" python3 - "$GATE" >"${WORK}/limbB.out" 2>&1 <<'LIMB_B_PY'
import importlib.util
import sys
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("subscription_gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

EXPIRY = datetime(2026, 6, 1, 12, 0, 0, tzinfo=timezone.utc)
state = {
    "status": "active",
    "expires_at": EXPIRY.isoformat().replace("+00:00", "Z"),
    "source": "first_month_free",
    "has_ever_paid": False,
    "licence_tier": "beta",
    "licence_tier_state": "known",
}

# (days before expiry, expected kind or None)
CASES = [
    (365, None),
    (60,  None),
    (30,  None),
    (9,   None),
    (8,   None),
    (7.5, "ending_soon"),   # 7 whole days left
    (7,   "ending_soon"),
    (3,   "ending_soon"),
    (1,   "ending_soon"),
    (0.5, "ending_soon"),   # today
    (-0.5, "ended"),
    (-30,  "ended"),
]

problems = []
for days, want in CASES:
    now = EXPIRY - timedelta(days=days)
    got = gate.expiry_warning(now=now, state=state)
    kind = got["kind"] if got else None
    if kind != want:
        problems.append("at %+g days: got %r, expected %r" % (days, kind, want))
        continue
    if got:
        msg = got["message"]
        # The copy carries the read-only promise, or the warning is only
        # half of what Andy asked for.
        if "deleted" not in msg:
            problems.append("at %+g days: the message never says nothing is deleted" % days)
        for banned in ("locked", "lost", "erased", "wiped"):
            if banned in msg.lower():
                problems.append("at %+g days: the message says %r" % (days, banned))

# The boundary is a boundary in BOTH directions, and one that had drifted
# would still pass every case above if the cases were all on one side.
just_outside = gate.expiry_warning(now=EXPIRY - timedelta(days=8, seconds=1), state=state)
just_inside = gate.expiry_warning(now=EXPIRY - timedelta(days=7, hours=23), state=state)
if just_outside is not None:
    problems.append("the warn window reaches further than %d days" % gate.WARN_BEFORE_EXPIRY_DAYS)
if just_inside is None:
    problems.append("the warn window does not reach %d days" % gate.WARN_BEFORE_EXPIRY_DAYS)

if problems:
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("12 instants plus both sides of the boundary: correct")
LIMB_B_PY
then
    ok "B1 the warning fires from the declared warn window and not before, at 12 fixed instants either side (clock injected)"
    ok "B2 every warning states that nothing is deleted, and none of them says locked / lost / erased / wiped"
else
    bad "B1/B2 the warning window is wrong"
    sed 's/^/        /' "${WORK}/limbB.out"
fi

# ───────────────────────────────────────────────────────────────────
# Limb C. Lapse is READ-ONLY.
# ───────────────────────────────────────────────────────────────────
#
# The claim under test is about a PERSON's files, so the subject is a
# directory of their data, not a function's return value. Everything the
# gate might plausibly reach is staged, hashed, walked past its expiry,
# and hashed again.
DATA="${HUB}/customer-data"
mkdir -p "${DATA}/Conversations" "${DATA}/Wiki"
printf 'a conversation the tester recorded\n' > "${DATA}/Conversations/one.md"
printf 'a wiki page about a person\n'         > "${DATA}/Wiki/person.md"
printf 'an export they dropped in\n'          > "${DATA}/export.json"
before_hash="$(find "$DATA" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')"
before_count="$(find "$DATA" -type f | wc -l | tr -d ' ')"

rm -f "$STATE"
activate beta known "$three_days_out"
# Walk the tester past the end of their beta. ONLY the dates move: status,
# source, has_ever_paid and the tier are left exactly as the installer
# wrote them, so the gate still has to decide rather than being told.
python3 - "$STATE" <<'AGE_PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)
past = (datetime.now(timezone.utc) - timedelta(days=5)).isoformat().replace("+00:00", "Z")
state["expires_at"] = past
state["last_validated_at"] = past
state["grace_period_end"] = past
state["licence_expires_at"] = past
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
AGE_PY

c_rc=0
OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --check >"${WORK}/lapsed.out" 2>&1 || c_rc=$?
after_hash="$(find "$DATA" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')"
after_count="$(find "$DATA" -type f | wc -l | tr -d ' ')"

if [[ "$c_rc" != "3" ]]; then
    bad "C1 a lapsed beta tester was not paused (exit ${c_rc}, expected 3) -- nothing below is about a lapsed customer"
    sed 's/^/        /' "${WORK}/lapsed.out"
else
    ok "C1 a beta tester past their window is PAUSED (exit 3, the gate's distinct 'not paying' code)"
fi

if [[ "$before_hash" == "$after_hash" && "$before_count" == "$after_count" && "$before_count" == "3" ]]; then
    ok "C2 the tester's ${before_count} files are byte-identical across the lapse: nothing deleted, nothing rewritten"
else
    bad "C2 customer data CHANGED across the lapse (${before_count} files -> ${after_count}, hash ${before_hash} -> ${after_hash})"
fi

# C3. The words. Apple restraint is a product requirement here, not a
# style note: "locked" is the sentence that makes a tester think their
# data is gone.
if grep -qiE 'locked|deleted your|erased|wiped|lost' "${WORK}/lapsed.out"; then
    bad "C3 the pause message uses destructive language"
    sed 's/^/        /' "${WORK}/lapsed.out"
elif grep -qF "stays" "${WORK}/lapsed.out" && grep -qF "paused" "${WORK}/lapsed.out"; then
    ok "C3 the pause message says paused and says the data stays"
else
    bad "C3 the pause message neither promises the data stays nor says paused"
    sed 's/^/        /' "${WORK}/lapsed.out"
fi

# C4. The negative control for C2. If the gate could not write at all,
# C2 would pass for the wrong reason. Prove the run actually exercised a
# writer by checking the state file itself moved forward to inactive.
if [[ "$(read_field status)" == "inactive" ]]; then
    ok "C4 the gate DID write during the lapse (status walked to inactive), so C2 is not a pass-by-paralysis"
else
    bad "C4 status is '$(read_field status)' after the lapse -- the gate wrote nothing, so C2 proves nothing"
fi

# ───────────────────────────────────────────────────────────────────
# Limb D. It reaches a surface a person looks at.
# ───────────────────────────────────────────────────────────────────
#
# D1: the --check the five shipped tick wrappers already make on every
# tick. Printing on the PASS path is the point: a message that only
# appears once the product has stopped is an obituary, not a warning.
rm -f "$STATE"
activate beta known "$three_days_out"
d1_rc=0
OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --check >"${WORK}/warn.out" 2>&1 || d1_rc=$?
if [[ "$d1_rc" != "0" ]]; then
    bad "D1 a tester with 3 days left was paused (exit ${d1_rc}) -- the warning must not cost them the product early"
# ONE grep WITH ALTERNATION, NOT THREE JOINED BY ||.
# The pipefail ratchet's pattern looks for a pipe followed by a
# short-circuiting consumer, and it cannot tell `||` from `|`: the second
# bar of a logical OR, followed by ` grep -q`, matches it exactly. There is
# no pipe on this line and never was, so it was a false positive, and the
# remedy the ratchet prints would have had someone rewrite correct code.
# Filed separately. This form sidesteps it and reads better anyway: the
# three needles are plain text with no regex metacharacters.
elif grep -qE "ends in|ends tomorrow|ends today" "${WORK}/warn.out"; then
    ok "D1 a still-running tester is TOLD their window is closing, and keeps running (exit 0)"
else
    bad "D1 the tick check said nothing about the window closing"
    sed 's/^/        /' "${WORK}/warn.out"
fi

# D2. The negative control. A tester with three MONTHS left must be told
# nothing, or D1 passes on a message that is always printed.
rm -f "$STATE"
activate beta known "$ninety_days_out"
d2_rc=0
OSTLER_SUBSCRIPTION_STATE="$STATE" python3 "$GATE" --check >"${WORK}/quiet.out" 2>&1 || d2_rc=$?
if [[ "$d2_rc" != "0" ]]; then
    bad "D2 a tester with 90 days left was paused (exit ${d2_rc})"
elif [[ -s "${WORK}/quiet.out" ]]; then
    bad "D2 a tester with 90 days left was warned anyway -- the message is unconditional, so D1 proves nothing"
    sed 's/^/        /' "${WORK}/quiet.out"
else
    ok "D2 a tester with 90 days left is told nothing (the warning is conditional)"
fi

# D3. The Doctor panel. Doctor already runs every rule in ALL_RULES on
# every status poll, so this needs no new scheduler -- and a scheduler is
# a thing that can fail to be loaded.
python3 - "$REPO_ROOT" "$HUB" >"${WORK}/doctor.out" 2>&1 <<'DOCTOR_PY'
import json
import os
import sys

repo, hub = sys.argv[1], sys.argv[2]
home = os.path.join(hub, "doctor-home")
os.makedirs(os.path.join(home, ".ostler", "state"), exist_ok=True)
os.environ["HOME"] = home
sys.path.insert(0, os.path.join(repo, "vendor", "doctor", "agent"))
# ── AN ABSENT LIBRARY HAS NOT FAILED ──────────────────────────────────
# diagnostic_rules imports httpx transitively. On a runner without it the
# import raises ModuleNotFoundError, and this arm used to report "D3 the
# Doctor rule is wrong". The rule had not been evaluated at all. That is a
# harness failure wearing a content verdict, which is the exact defect
# this whole test exists to remove from the product.
#
# Exit 78 (EX_CONFIG) so the shell can tell the two apart. The arm is
# still NOT a pass: it prints CANNOT-RUN and counts as unmeasured.
try:
    import diagnostic_rules as dr
except ImportError as e:
    # ImportError, not just ModuleNotFoundError. A transitive dependency can
    # fail to load for reasons other than being absent, and both mean the same
    # thing here: the rule was not evaluated. The exception text is PRINTED so
    # a genuinely broken module cannot hide behind this branch looking like a
    # missing one.
    print("CANNOT-RUN: diagnostic_rules could not be imported: %r" % (e,))
    print("            The Doctor rule was NOT evaluated. This is not a pass")
    print("            and it is not evidence that the rule is wrong.")
    raise SystemExit(78)

if dr.check_licence_expiry not in dr.ALL_RULES:
    raise SystemExit("check_licence_expiry is not in ALL_RULES -- Doctor never runs it")

state_path = os.path.join(home, ".ostler", "state", "subscription_state.json")
from datetime import datetime, timedelta, timezone


def write(**kw):
    with open(state_path, "w") as fh:
        json.dump(kw, fh)


def iso(days):
    return (datetime.now(timezone.utc) + timedelta(days=days)) \
        .replace(microsecond=0).isoformat().replace("+00:00", "Z")


problems = []

# Quiet on everything it cannot read. A brand new customer, an upgrade
# from a build before this field existed, and a corrupt file must all
# produce NO row: telling a new customer their access is ending is both
# false and the worst first impression available.
if os.path.exists(state_path):
    os.remove(state_path)
if dr.check_licence_expiry(None):
    problems.append("fired with no state file at all")
write(status="active", source="first_month_free")
if dr.check_licence_expiry(None):
    problems.append("fired on a state with no expires_at")
write(status="active", expires_at="not-a-date")
if dr.check_licence_expiry(None):
    problems.append("fired on an unparseable expires_at")
with open(state_path, "w") as fh:
    fh.write("{ this is not json")
if dr.check_licence_expiry(None):
    problems.append("fired on malformed JSON")

# Warned BEFORE.
write(status="active", expires_at=iso(3), licence_tier="beta",
      licence_tier_state="known", has_ever_paid=False)
rows = dr.check_licence_expiry(None)
if len(rows) != 1 or rows[0]["severity"] != "warning":
    problems.append("3 days out gave %r" % [(r["severity"], r["title"]) for r in rows])
elif "beta" not in rows[0]["title"]:
    problems.append("the row does not name the tier: %r" % rows[0]["title"])
elif "deleted" not in rows[0]["detail"]:
    problems.append("the warning row never says nothing is deleted")
elif "T" in rows[0]["detail"] and "Z" in rows[0]["detail"]:
    problems.append("the row shows a raw ISO stamp to the customer: %r" % rows[0]["detail"])

# Quiet well before.
write(status="active", expires_at=iso(90), licence_tier="beta",
      licence_tier_state="known")
if dr.check_licence_expiry(None):
    problems.append("fired 90 days out -- the row is unconditional")

# After: an INFO row that explains, and promises.
write(status="inactive", expires_at=iso(-4), licence_tier="beta",
      licence_tier_state="known", has_ever_paid=False)
rows = dr.check_licence_expiry(None)
if len(rows) != 1 or rows[0]["severity"] != "info":
    problems.append("after lapse gave %r" % [(r["severity"], r["title"]) for r in rows])
elif "deleted" not in rows[0]["detail"]:
    problems.append("the ended row never says nothing has been deleted")

# A paying customer inside their post-lapse grace is NOT ended.
write(status="grace", expires_at=iso(-4), licence_tier="pro",
      licence_tier_state="known", has_ever_paid=True,
      grace_period_end=iso(10))
if dr.check_licence_expiry(None):
    problems.append("told a customer in grace that their access had ended")

# Never a tier it made up.
write(status="active", expires_at=iso(3))
rows = dr.check_licence_expiry(None)
if not rows:
    problems.append("said nothing for a Hub with no tier recorded")
elif "hub" in rows[0]["title"].lower():
    problems.append("invented a tier for a Hub that never verified one: %r" % rows[0]["title"])

if problems:
    for p in problems:
        print("  " + p)
    raise SystemExit(1)
print("Doctor rule: 9 states correct, and it is in ALL_RULES")
DOCTOR_PY
_d3_rc=$?
if [ "$_d3_rc" -eq 0 ]; then
    ok "D3 the Doctor panel warns before, explains after, and stays quiet on everything it cannot read"
elif [ "$_d3_rc" -eq 78 ]; then
    # Three outcomes, three branches. The rule could not be loaded, so it was
    # neither right nor wrong here.
    cannot_run_arm "D3 the Doctor rule could not be LOADED, so it was not graded"
    sed 's/^/        /' "${WORK}/doctor.out"
else
    bad "D3 the Doctor rule is wrong"
    sed 's/^/        /' "${WORK}/doctor.out"
fi

# ───────────────────────────────────────────────────────────────────
# Limb E. The duplicated constant agrees with its authority.
# ───────────────────────────────────────────────────────────────────
gate_days="$(python3 -c "
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^WARN_BEFORE_EXPIRY_DAYS = (\d+)', src, re.M)
print(m.group(1) if m else 'MISSING')" "$GATE_SRC")"
doctor_days="$(python3 -c "
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^LICENCE_WARN_BEFORE_EXPIRY_DAYS = (\d+)', src, re.M)
print(m.group(1) if m else 'MISSING')" "$DOCTOR_RULES")"

if [[ "$gate_days" == "MISSING" || "$doctor_days" == "MISSING" ]]; then
    bad "E1 could not read one of the warn-window constants (gate=${gate_days}, doctor=${doctor_days}) -- nothing was compared"
elif [[ "$gate_days" == "$doctor_days" ]]; then
    ok "E1 the gate and the Doctor agree the warn window is ${gate_days} days"
else
    bad "E1 the warn window disagrees: subscription_gate says ${gate_days}, the Doctor says ${doctor_days}. A customer would be warned on two different days by two surfaces."
fi

# E2. The two vendored copies of the gate must stay identical, because
# CM052's wire imports the other one.
if diff -q "$GATE_SRC" "${REPO_ROOT}/vendor/cm052_ai_conversations/src/cm052/subscription_gate.py" >/dev/null 2>&1; then
    ok "E2 the cm041 and cm052 copies of the gate are identical"
else
    bad "E2 the two vendored copies of subscription_gate.py have diverged"
fi

# ───────────────────────────────────────────────────────────────────
printf '\n%s\n' "----------------------------------------------------------"
printf 'beta licence expiry warns before and is read-only: %d passed, %d failed, %d could not run\n' \
    "$PASS" "$FAIL" "$CANNOT"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
if [[ "$CANNOT" -gt 0 ]]; then
    printf '  REFUSING: %d arm(s) were not evaluated. That is not a pass.\n' "$CANNOT" >&2
    exit 1
fi
exit 0
