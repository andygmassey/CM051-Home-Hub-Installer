#!/usr/bin/env bash
#
# tests/test_manifest_ack_expiry.sh
#
# Drives scripts/verify_manifest_ack_expiry.sh against synthetic manifests so the
# predicate is proven in a second, without depending on the state of the real
# vendor manifest. The real-manifest RED is D1's proof that the gate is pointed
# at the genuine article; THIS is the proof that each arm of the predicate
# actually fires, and fires for the reason claimed.
#
# EVERY negative fixture is a SINGLE-PROPERTY mutation of the compliant one, and
# the compliant baseline is asserted GREEN first -- so a RED cannot be passed off
# as caused by something other than the property under test. A gate that goes
# red on a fixture that is broken in two ways has proven nothing about either.
#
# `today` is pinned via OSTLER_ACK_TODAY so "past" and ">30 days out" are
# deterministic and this test does not rot as the calendar moves.
#
# Exit 0 all checks pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_manifest_ack_expiry.sh"

[[ -f "$GATE" ]] || { echo "CANNOT-RUN: gate not found at $GATE (exit 2)" >&2; exit 2; }

TODAY="2026-09-02"          # pinned; fixtures are relative to this
FUTURE_OK="2026-09-12"      # today + 10  -> inside the 30-day window
PAST="2026-09-01"           # today - 1   -> expired
TOO_FAR="2026-11-02"        # today + 61  -> beyond the 30-day cap

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ackgate-XXXXXX")" || { echo "CANNOT-RUN: mktemp (exit 2)" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  [pass] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# run_gate <fixture-file> -> echoes the exit code
run_gate() {
    OSTLER_ACK_MANIFEST="$1" OSTLER_ACK_TODAY="$TODAY" bash "$GATE" >/dev/null 2>&1
    echo $?
}

# expect <label> <fixture> <want-rc>
expect() {
    local label="$1" fixture="$2" want="$3" got
    got="$(run_gate "$fixture")"
    if [[ "$got" == "$want" ]]; then ok "$label (rc=$got)"; else bad "$label: want rc=$want got rc=$got"; fi
}

# A compliant ack tree: dated inside the window, owned by a name in the set.
cat > "$TMP/compliant.toml" <<EOF
[[tree]]
name = "fixture_ack"
verify = "skip"
unverifiable_ack = true
expires = "$FUTURE_OK"
owner = "andy"
EOF

# --- BASELINE FIRST: compliant must be GREEN, or every RED below is suspect ---
expect "compliant baseline is GREEN" "$TMP/compliant.toml" 0

# Mutation 1: drop `expires` (single property) -> RED
sed '/^expires = /d' "$TMP/compliant.toml" > "$TMP/no_expires.toml"
expect "missing expires -> RED" "$TMP/no_expires.toml" 1

# Mutation 2: owner is a ROLE, everything else compliant -> RED
sed 's/^owner = "andy"/owner = "ORM, with the CM048 source-repo owner"/' "$TMP/compliant.toml" > "$TMP/role_owner.toml"
expect "role owner -> RED" "$TMP/role_owner.toml" 1

# Mutation 3: expires in the PAST -> RED  (D2: a past ack REFUSES the cut)
sed "s/^expires = .*/expires = \"$PAST\"/" "$TMP/compliant.toml" > "$TMP/past.toml"
expect "past expiry -> RED (D2 refusal)" "$TMP/past.toml" 1

# Mutation 4: expires beyond the 30-day cap -> RED
sed "s/^expires = .*/expires = \"$TOO_FAR\"/" "$TMP/compliant.toml" > "$TMP/too_far.toml"
expect "expiry >30d out -> RED (max life)" "$TMP/too_far.toml" 1

# Mutation 5: owner missing entirely -> RED
sed '/^owner = /d' "$TMP/compliant.toml" > "$TMP/no_owner.toml"
expect "missing owner -> RED" "$TMP/no_owner.toml" 1

# NEGATIVE CONTROL: a tree with NO ack at all must NOT be required to carry
# expires/owner -- the gate governs ack rows only, not every tree.
cat > "$TMP/no_ack.toml" <<EOF
[[tree]]
name = "fixture_plain"
verify = "full"
EOF
# add a compliant ack alongside so the file is not "zero acks" (that is exit 2)
cat "$TMP/compliant.toml" >> "$TMP/no_ack.toml"
expect "non-ack tree needs no expires/owner (GREEN)" "$TMP/no_ack.toml" 0

# CANNOT-RUN guard 1: a manifest with trees but ZERO acks -> exit 2, NOT 0.
cat > "$TMP/zero_acks.toml" <<EOF
[[tree]]
name = "a"
verify = "full"
[[tree]]
name = "b"
verify = "full"
EOF
expect "zero ack rows -> CANNOT-RUN (exit 2, not a clean pass)" "$TMP/zero_acks.toml" 2

# CANNOT-RUN guard 2: an unparseable file -> exit 2.
printf 'this is not = valid toml [[[\n' > "$TMP/garbage.toml"
expect "unparseable manifest -> CANNOT-RUN (exit 2)" "$TMP/garbage.toml" 2

# CANNOT-RUN guard 3: a missing file -> exit 2.
expect "missing manifest -> CANNOT-RUN (exit 2)" "$TMP/does_not_exist.toml" 2

# an empty hold_ack_shas is NOT an ack (it must not be dragged into the gate)
cat > "$TMP/empty_hold.toml" <<EOF
[[tree]]
name = "fixture_empty_hold"
verify = "full"
hold_ack_shas = ""
hold_ack_reason = ""
EOF
cat "$TMP/compliant.toml" >> "$TMP/empty_hold.toml"
expect "empty hold_ack_shas is not an ack (GREEN)" "$TMP/empty_hold.toml" 0

echo
echo "manifest-ack-expiry gate self-test: ${pass} passed, ${fail} failed."
[[ "$fail" -eq 0 ]] || exit 1
exit 0
