#!/usr/bin/env bash
# THE LICENCE FILE IS 0600 ON THE BOX, NOT IN A COMMENT.
#
# WHAT IS IN THE FILE, because this is a privacy defect and not a tidiness
# one. A v1 CM050 licence REQUIRES the fields `issued_to_email` and
# `stripe_payment_id` (STRING_FIELDS, in install.sh's own verifier heredoc).
# A world-readable licence therefore hands every other local account on the
# Mac the customer's email address and the id of their payment.
#
# WHAT WAS MEASURED, 2026-09-16, before the fix.
#
#   gui/.../LicensePersistence.swift:4 promises "mode 0600 ... atomic
#   rename". It chmodded its temp sibling to 0600 and then swapped it in with
#   `FileManager.replaceItem`, which exists to replace a DOCUMENT and so
#   carries the ORIGINAL item's metadata -- POSIX mode included -- onto the
#   replacement. Three cases, one standalone Swift program mirroring write():
#
#       destination ABSENT, temp 0600, replaceItem -> 600
#       destination 0644,   temp 0600, replaceItem -> 644   <- the defect
#       destination 0644,   temp 0600, rename(2)   -> 600   <- the fix
#
#   The first row is why the Swift suite's own testWriteSetsFileMode0600
#   passed for the life of the file: it only ever wrote to a fresh path.
#
#   install.sh's refusal message tells the customer to
#   `cp ~/Downloads/ostler-licence.json ~/.ostler/license/license.json`,
#   and `cp` creates at the default umask, which is 0644 on a stock macOS
#   account.
#
#   Nothing chmodded it on either path: a search for chmod against the
#   licence path returned ZERO hits. CONTROL, same file, same command shape:
#   `chmod 600` returned 20. The search worked; the chmod did not exist.
#
# WHAT THIS TEST DOES. It runs install.sh's REAL repair limb, extracted by
# content, against a REAL file created at 0644, and reads the mode back off
# the filesystem with stat. It does not grep install.sh for the word chmod.
#
# The Swift half is pinned separately by LicensePersistenceTests'
# testWriteOverAWorldReadableFileEndsAt0600, which needs a macOS runner.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- extract the repair limb BY CONTENT, so a moved block still tests --------
LIMB="${WORK}/limb.sh"
awk '
    /^_ostler_licence_restrict_mode\(\) \{$/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) exit }
' "$SUBJECT" > "$LIMB"

if ! /usr/bin/grep -q 'chmod 600' "$LIMB"; then
    echo "CANNOT-RUN: could not extract _ostler_licence_restrict_mode from ${SUBJECT}." >&2
    echo "  Scanning nothing must not read as a passing test." >&2
    exit 2
fi
if ! bash -n "$LIMB" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted limb does not parse; the extraction is wrong." >&2
    exit 2
fi

# Read a mode as octal, on the host that runs this. BSD stat and GNU stat
# disagree about their own flags, so ask both and refuse rather than guess.
_mode() {
    local p="$1" m
    m="$(/usr/bin/stat -f '%Lp' "$p" 2>/dev/null)" || m=""
    if [ -z "$m" ]; then m="$(/usr/bin/stat -c '%a' "$p" 2>/dev/null)" || m=""; fi
    if [ -z "$m" ]; then m="$(stat -c '%a' "$p" 2>/dev/null)" || m=""; fi
    printf '%s' "$m"
}

# A harness that supplies the two things the limb reads from install.sh:
# the licence path, and `warn`. Nothing else is stubbed.
_run_limb() { # $1 = licence file path
    local lic="$1" w="${WORK}/run.sh"
    { printf 'warn() { printf "WARN: %%s\\n" "$*"; }\n'
      printf 'OSTLER_LICENCE_FILE=%q\n' "$lic"
      cat "$LIMB"
      printf '_ostler_licence_restrict_mode\n'
    } > "$w"
    bash "$w" 2>&1
}

printf 'THE LICENCE A CUSTOMER PAID FOR IS OWNER-ONLY\n\n'

# --- 0. the instrument works before anything is asserted with it -------------
echo "-- 0. CONTROL: the mode reader can tell 0644 from 0600 --"
CTL="${WORK}/ctl"
: > "$CTL"
chmod 644 "$CTL"; CTL_644="$(_mode "$CTL")"
chmod 600 "$CTL"; CTL_600="$(_mode "$CTL")"
if [ "$CTL_644" = "644" ] && [ "$CTL_600" = "600" ]; then
    ok "stat reports 644 and 600 distinctly on this host"
else
    echo "CANNOT-RUN: the mode reader returned '${CTL_644}' and '${CTL_600}'." >&2
    echo "  Every assertion below would be comparing against noise." >&2
    exit 2
fi

# --- 1. the measured defect: a file the customer cp'd in at 0644 -------------
echo "-- 1. MUST PASS: the licence the customer copied in at 0644 ends 0600 --"
H="${WORK}/home_cp"
mkdir -p "${H}/.ostler/license"
LIC="${H}/.ostler/license/license.json"
# Synthetic, and deliberately shaped like the real thing so the reason this
# matters is legible in the fixture itself. No real address, no real payment.
printf '%s\n' '{"version":1,"issued_to_email":"someone@example.invalid","stripe_payment_id":"pi_synthetic_fixture"}' > "$LIC"
chmod 644 "$LIC"
chmod 755 "${H}/.ostler/license"

# CONTROL: the precondition really is permissive, or arm 1 passes vacuously.
if [ "$(_mode "$LIC")" != "644" ] || [ "$(_mode "${H}/.ostler/license")" != "755" ]; then
    bad "the 0644/0755 precondition did not take; this arm would prove nothing"
else
    ok "precondition set: the file is 0644 and its directory 0755"
    OUT="$(_run_limb "$LIC")"
    M="$(_mode "$LIC")"
    D="$(_mode "${H}/.ostler/license")"
    case "$M" in
        600) ok "the licence file is 0600 after the limb ran (read back with stat)" ;;
        *)   bad "the licence is mode ${M}; another local account can read the customer's email address and payment id. Output: ${OUT}" ;;
    esac
    case "$D" in
        700) ok "the licence directory is 0700, so its contents are not even listable" ;;
        *)   bad "the licence directory is mode ${D}, not 700" ;;
    esac
    # The bytes must be untouched: a repair that corrupted the licence would
    # trade one refusal for another.
    if /usr/bin/grep -q 'pi_synthetic_fixture' "$LIC"; then
        ok "the licence content is unchanged; only the mode moved"
    else
        bad "the limb altered the licence content"
    fi
fi

# --- 2. idempotent: a file already at 0600 stays there, silently -------------
echo "-- 2. a licence already at 0600 is left alone and says nothing --"
H2="${WORK}/home_ok"
mkdir -p "${H2}/.ostler/license"
LIC2="${H2}/.ostler/license/license.json"
printf '{"version":1}\n' > "$LIC2"
chmod 600 "$LIC2"
OUT2="$(_run_limb "$LIC2")"
if [ "$(_mode "$LIC2")" = "600" ] && [ -z "$(printf '%s' "$OUT2" | tr -d '[:space:]')" ]; then
    ok "already-correct mode is a no-op with no output to worry a customer"
else
    bad "a correct file produced mode $(_mode "$LIC2") and output: ${OUT2}"
fi

# --- 3. an absent licence must not be invented --------------------------------
echo "-- 3. no licence file: the limb does not create one --"
H3="${WORK}/home_none"
mkdir -p "${H3}/.ostler/license"
LIC3="${H3}/.ostler/license/license.json"
_run_limb "$LIC3" >/dev/null 2>&1
if [ -e "$LIC3" ]; then
    bad "a licence file appeared where none existed"
else
    ok "an absent licence stays absent"
fi

# --- 4. the refusal message tells the customer to set the mode themselves ----
echo "-- 4. the cp instructions carry the chmod, or they teach 0644 --"
REFUSE="${WORK}/refuse.sh"
awk '
    /^_ostler_licence_refuse\(\) \{$/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) exit }
' "$SUBJECT" > "$REFUSE"
if ! /usr/bin/grep -q 'ostler-licence.json' "$REFUSE"; then
    bad "CANNOT-CHECK: the refusal limb did not extract, so arm 4 proves nothing"
else
    _cp_line="$(/usr/bin/grep -c 'cp ~/Downloads/ostler-licence.json' "$REFUSE")"
    _chmod_600="$(/usr/bin/grep -c 'chmod 600 ~/.ostler/license/license.json' "$REFUSE")"
    _chmod_700="$(/usr/bin/grep -c 'chmod 700 ~/.ostler/license' "$REFUSE")"
    if [ "$_cp_line" -lt 1 ]; then
        bad "CANNOT-CHECK: the cp instruction is gone; this arm is aimed at nothing"
    elif [ "$_chmod_600" -ge 1 ] && [ "$_chmod_700" -ge 1 ]; then
        ok "the instructions the customer pastes set 0600 on the file and 0700 on its directory"
    else
        bad "the refusal tells the customer to cp the licence in and never to chmod it (file:${_chmod_600} dir:${_chmod_700})"
    fi
fi

# --- 5. MUTATION: without the chmod, arm 1 MUST fail -------------------------
echo "-- 5. MUTATION: with the repair removed, the 0644 file stays 0644 --"
MUT="${WORK}/limb_mutant.sh"
sed 's|if chmod 600 "${OSTLER_LICENCE_FILE}"; then|if true; then|' "$LIMB" > "$MUT"
if [ "$(/usr/bin/grep -c 'if true; then' "$MUT")" -lt 1 ]; then
    bad "MUTATION DID NOT APPLY, so the arm below proves nothing"
else
    ok "the mutant really has the file chmod disabled (the injection landed)"
    H4="${WORK}/home_mut"
    mkdir -p "${H4}/.ostler/license"
    LIC4="${H4}/.ostler/license/license.json"
    printf '{"version":1}\n' > "$LIC4"
    chmod 644 "$LIC4"
    _w="${WORK}/run_mut.sh"
    { printf 'warn() { printf "WARN: %%s\\n" "$*"; }\n'
      printf 'OSTLER_LICENCE_FILE=%q\n' "$LIC4"
      cat "$MUT"
      printf '_ostler_licence_restrict_mode\n'
    } > "$_w"
    bash "$_w" >/dev/null 2>&1
    if [ "$(_mode "$LIC4")" = "600" ]; then
        bad "the file reached 0600 with the chmod removed; arm 1 is not testing the chmod"
    else
        ok "MUST-FAIL: without the chmod the licence stays $(_mode "$LIC4"), so the repair is load-bearing"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
