#!/usr/bin/env bash
# lib_identity_lookalike.sh -- make an INVISIBLE identity mismatch visible.
#
# ttywalk.sh:119 refuses when the host's ComputerName is not the expected one,
# and prints:
#
#     IDENTITY MISMATCH. Expected ComputerName 'Andrew's Mac mini',
#     the host at <host> answers 'Andrew's Mac mini'. DHCP moves this address.
#     Refusing rather than acting on the wrong machine.
#
# MEASURED 2026-09-07: the walk box's ComputerName contains U+2019 (a curly
# apostrophe). ttywalk.sh's own usage example at line 41 contains U+0027 (a
# straight one) -- confirmed byte-exact with `od -c`. Copy the documented
# example and the walk refuses.
#
# 🔴 THE DIAGNOSTIC CANNOT EXPRESS THE DIFFERENCE THAT CAUSED IT. Both quoted
# strings render identically in a terminal, so the operator reads
# "Expected X, got X" and has nothing to act on. Worse, the next sentence says
# "DHCP moves this address", which sends them to the network -- the one place
# the fault is not. It cost a real walk attempt tonight.
#
# A refusal that cannot be acted on is a refusal that gets worked around, which
# is the same failure mode as a gate that cannot go green.
#
# WHAT THIS ADDS: when two identity strings differ, say whether they differ ONLY
# by look-alike punctuation, and print the bytes either way. No bash 4 features
# (this estate has met bash 3.2), no python dependency on the local side.

# Normalise the look-alikes that actually occur in macOS ComputerNames:
# U+2019 right single quote, U+2018 left single quote, U+201C/U+201D double
# quotes. Everything else is left alone -- this is a HINT, never a comparison
# the gate acts on.
_identity_normalise() {
    printf '%s' "${1:-}" | LC_ALL=C sed \
        -e "s/$(printf '\342\200\231')/'/g" \
        -e "s/$(printf '\342\200\230')/'/g" \
        -e "s/$(printf '\342\200\234')/\"/g" \
        -e "s/$(printf '\342\200\235')/\"/g"
}

# identity_lookalike_verdict <expected> <actual>
#   IDENTICAL   the two strings are byte-equal (caller should not be here)
#   LOOKALIKE   they differ ONLY by look-alike punctuation
#   DIFFERENT   they genuinely differ
identity_lookalike_verdict() {
    local _e="${1:-}" _a="${2:-}"
    if [ "$_e" = "$_a" ]; then
        printf 'IDENTICAL\n'
        return
    fi
    if [ "$(_identity_normalise "$_e")" = "$(_identity_normalise "$_a")" ]; then
        printf 'LOOKALIKE\n'
        return
    fi
    printf 'DIFFERENT\n'
}

# identity_bytes <string> -> lowercase hex, space separated
identity_bytes() {
    printf '%s' "${1:-}" | od -An -tx1 | tr -s ' ' | tr -d '\n' | sed 's/^ //; s/ $//'
}

# identity_mismatch_hint <expected> <actual> -> the lines to append to the die
identity_mismatch_hint() {
    local _e="${1:-}" _a="${2:-}"
    case "$(identity_lookalike_verdict "$_e" "$_a")" in
        LOOKALIKE)
            printf '%s\n' \
"   🔴 THESE DIFFER ONLY BY LOOK-ALIKE PUNCTUATION. They render the same in a" \
"      terminal, so read the bytes, not the glyphs. This is NOT a DHCP or a" \
"      wrong-machine problem; it is the apostrophe." \
"        expected bytes: $(identity_bytes "$_e")" \
"        host bytes:     $(identity_bytes "$_a")" \
"      macOS ComputerName commonly uses U+2019 (e2 80 99), while a typed" \
"      apostrophe is U+0027 (27). Pass the name as the host reports it:" \
"        --expect-name \"\$(ssh <host> scutil --get ComputerName)\""
            ;;
        DIFFERENT)
            printf '%s\n' \
"        expected bytes: $(identity_bytes "$_e")" \
"        host bytes:     $(identity_bytes "$_a")"
            ;;
    esac
}
