#!/usr/bin/env bash
#
# test_imessage_self_handles_fallback.sh
#
# Regression test for #646 part 2 (v1.0.10 box-walk, 2026-07-24): the
# assistant's self-echo guard (OSTLER_IMESSAGE_SELF_HANDLES) shipped EMPTY
# on a fresh install whose Contacts "my card" resolved a name but carried no
# phone/email entry. USER_PHONE + USER_EMAIL both landed empty, the
# me-card-only builder produced an empty value, and the gateway logged
# "no self-handle (OSTLER_IMESSAGE_SELF_HANDLES empty); skipping intro" --
# the warm-intro iMessage never fired even though the operator HAD supplied
# their handle at the iMessage "who can message me" prompt
# (CHANNEL_IMESSAGE_ALLOWED, which correctly populated allowed_contacts).
#
# The fix factors the computation into _compute_imessage_self_handles and
# adds a fallback: when the me-card yields nothing, derive the self-handles
# from the operator-confirmed CHANNEL_IMESSAGE_ALLOWED list.
#
# Axes:
#   1. install.sh defines _compute_imessage_self_handles.
#   2. It is invoked (gated on CHANNEL_IMESSAGE_ENABLED).
#   3. Behaviour (carve + run):
#      a. me-card populated              -> uses phone+email (fallback dormant)
#      b. me-card empty, allowed set     -> falls back to allowed list  (the bug)
#      c. me-card + allowed both empty   -> empty (guard inactive, as designed)
#      d. me-card populated, allowed set -> STILL only me-card (invariant held:
#         other allowed contacts never leak into self-handles on the common path)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_imessage_self_handles_fallback: FAILED" >&2
    exit 1
fi

# Axis 1: the function exists.
if ! grep -q '_compute_imessage_self_handles()' "$INSTALL_SH"; then
    failure "install.sh never defines _compute_imessage_self_handles"
fi

# Axis 2: it is invoked to populate ASSISTANT_SELF_HANDLES.
if ! grep -q 'ASSISTANT_SELF_HANDLES="\$(_compute_imessage_self_handles)"' "$INSTALL_SH"; then
    failure "_compute_imessage_self_handles is defined but never invoked into ASSISTANT_SELF_HANDLES"
fi

# ---------------------------------------------------------------------------
# Axis 3: carve the function body and exercise it.
# ---------------------------------------------------------------------------
FUNC_BLOCK="$(awk '/_compute_imessage_self_handles\(\) \{/{p=1} p{print} p&&/^    \}$/{exit}' "$INSTALL_SH")"
if [[ -z "$FUNC_BLOCK" ]]; then
    failure "could not carve the _compute_imessage_self_handles function body"
    echo "test_imessage_self_handles_fallback: FAILED" >&2
    exit 1
fi

# Run the carved function with a given (USER_PHONE, USER_EMAIL,
# CHANNEL_IMESSAGE_ALLOWED) and echo its stdout.
run_fn() {
    local phone="$1" email="$2" allowed="$3"
    bash --noprofile --norc -c '
        set -uo pipefail
        USER_PHONE="'"$phone"'"
        USER_EMAIL="'"$email"'"
        CHANNEL_IMESSAGE_ALLOWED="'"$allowed"'"
        '"$FUNC_BLOCK"'
        _compute_imessage_self_handles
    '
}

# (a) me-card populated -> phone + email, fallback dormant.
res="$(run_fn "+12025550142" "me@example.com" "")"
[[ "$res" == "+12025550142,me@example.com" ]] || \
    failure "populated me-card should yield phone,email (got: '$res')"

# (b) THE BUG: me-card empty, operator typed their handle at the allowed
#     prompt -> fall back to the allowed list (guard armed, intro can fire).
res="$(run_fn "" "" "+12025550142, me@example.com")"
[[ "$res" == "+12025550142,me@example.com" ]] || \
    failure "empty me-card should fall back to CHANNEL_IMESSAGE_ALLOWED (got: '$res')"

# (b2) me-card empty, single typed handle.
res="$(run_fn "" "" "me@example.com")"
[[ "$res" == "me@example.com" ]] || \
    failure "empty me-card single allowed handle should fall back (got: '$res')"

# (c) both empty -> empty (guard inactive by design, not a crash).
res="$(run_fn "" "" "")"
[[ -z "$res" ]] || \
    failure "both sources empty should yield empty (got: '$res')"

# (d) INVARIANT: me-card populated AND allowed names other people ->
#     self-handles stay me-card only; other contacts never leak in.
res="$(run_fn "+12025550142" "me@example.com" "+12025550142, friend@example.com")"
[[ "$res" == "+12025550142,me@example.com" ]] || \
    failure "populated me-card must NOT pull other allowed contacts into self-handles (got: '$res')"

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_imessage_self_handles_fallback: FAILED" >&2
    exit 1
fi
echo "test_imessage_self_handles_fallback: PASSED"
