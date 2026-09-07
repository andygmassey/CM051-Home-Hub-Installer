#!/usr/bin/env bash
# An absent config key must not abort the install.
#
# WHY THIS EXISTS. MEASURED on a cold account, 2026-09-04, walk 5 of v1.0.65.
# The shipped uninstaller leaves config/.env behind, so a re-install offers
# "We found your previous answers", takes the reuse path, and reaches the
# channel restore. Then:
#
#     STEP_END id=config_save status=error rc=1
#     Install aborted unexpectedly at line 12720 (step config_save):
#         _v="$(_ostler_config_list_first "$_cfg" whatsapp allowed_numbers)"
#     #OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L12720
#
# THE MECHANISM IS pipefail, NOT THE LAST COMMAND OF THE CHAIN. install.sh
# runs under `set -Eeuo pipefail`. `grep -oE` exits 1 when it matches nothing,
# and pipefail promotes that to the whole pipeline even though `sed` -- the
# last command -- exits 0. The assignment then trips `set -e`.
#
# WHO HITS IT: every customer re-running the installer whose config has no
# `[channels.whatsapp] allowed_numbers`, i.e. everyone who did not choose
# WhatsApp. The sibling call asks for `imessage allowed_contacts` and fails
# identically when that is absent.
#
# THE TEST IS RUNTIME AND IT HAS TO BE. The defect is an EXIT STATUS produced
# by a pipeline under a shell option. Nothing about the source text
# distinguishes the broken form from the fixed one to a reader looking for a
# pattern -- both are a pipeline ending in sed.
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

# Two fixtures. Synthetic throughout: the number is the RFC-reserved UK drama
# range, so nothing here is a real contact.
cat > "${WORK}/absent.toml" <<'TOML'
[channels.imessage]
enabled = true
allowed_contacts = ["+447700900000"]
TOML
cat > "${WORK}/present.toml" <<'TOML'
[channels.whatsapp]
enabled = true
allowed_numbers = ["+447700900000"]
TOML

# ── Extract the reader from a tree and run it under the SHIPPED options ──
_extract() {
    awk '
        /^_ostler_config_list_first\(\) \{/ { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}

# Echoes "<exit>|<value>". The `set -Eeuo pipefail` line is the one install.sh
# itself uses; without it this test cannot see the defect at all.
_run() {
    local file="$1" toml="$2" key="$3" sect="$4"
    local fn r="${WORK}/r"; rm -rf "$r"; mkdir -p "$r"
    fn="$(_extract "$file")"
    [ -n "$fn" ] || { printf 'NOFN|'; return; }
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "$fn"
        printf '_v="$(_ostler_config_list_first %s %s %s)"\n' \
            "$(printf '%q' "$toml")" "$sect" "$key"
        printf '%s\n' 'printf "%s" "$_v"'
    } > "${r}/run.sh"
    local out rc
    out="$(bash "${r}/run.sh" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "── subject: this tree ──"

_r="$(_run "$SUBJECT" "${WORK}/absent.toml" allowed_numbers whatsapp)"
case "$_r" in
    NOFN*) echo "CANNOT-RUN: _ostler_config_list_first was not found in ${SUBJECT}." >&2; exit 2 ;;
    "0|")  ok "an ABSENT key returns empty and exit 0, so the install continues" ;;
    0\|*)  bad "an absent key returned a VALUE (${_r#0|}). It should read as empty." ;;
    *)     bad "an absent key exits ${_r%%|*} -- the install aborts here. This is the measured defect." ;;
esac

_r="$(_run "$SUBJECT" "${WORK}/present.toml" allowed_numbers whatsapp)"
case "$_r" in
    "0|+447700900000") ok "CONTROL: a PRESENT key still returns its value, so the fix did not blind the reader" ;;
    0\|*)              bad "a present key returned '${_r#0|}', expected the first array element. The reader is broken." ;;
    *)                 bad "a present key exits ${_r%%|*}" ;;
esac

# The OTHER call site, which fails the same way and is easy to forget.
_r="$(_run "$SUBJECT" "${WORK}/present.toml" allowed_contacts imessage)"
case "$_r" in
    "0|") ok "the imessage call site is safe too: absent allowed_contacts returns empty, exit 0" ;;
    *)    bad "absent imessage allowed_contacts gives ${_r} -- the second call site still aborts" ;;
esac

# ── The blanket fix must NOT have been used ──────────────────────────────
# A trailing `|| true` on the whole pipeline would pass every limb above and
# would also swallow an awk failure, an unreadable file and a broken sed. The
# function would become incapable of reporting anything at all.
_fn="$(_extract "$SUBJECT")"
case "$_fn" in
    *"' \"\$1\" | grep"*"|| true; }"*|*"{ grep"*"|| true; }"*)
        ok "absence is neutralised AT THE GREP, not with a blanket || true on the pipeline" ;;
    *"| head -1 | sed"*"|| true"*)
        bad "the pipeline ends with a blanket '|| true', which also hides awk, file and sed failures" ;;
    *)
        bad "could not confirm where absence is neutralised; a reader must be able to fail for real reasons" ;;
esac

# ── NEGATIVE CONTROL, pinned to the tree that SHIPPED the abort ──────────
# 7b2130ac is the v1.0.65 cut -- the artefact whose walk produced the log line
# quoted at the top of this file. Pinned to a fixed sha, never a branch: a
# control that reads origin/main inverts the moment this fix merges.
_CONTROL_SHA="7b2130ac"
echo "── negative control: ${_CONTROL_SHA} (the cut whose walk aborted) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

_r="$(_run "$_ctl" "${WORK}/absent.toml" allowed_numbers whatsapp)"
case "$_r" in
    NOFN*) echo "CANNOT-RUN: the reader was not found in the control blob." >&2; exit 2 ;;
    0\|*)  bad "control ${_CONTROL_SHA}: an absent key exits 0 there too. That tree DID abort on a real box, so this harness is not measuring the defect." ;;
    *)     ok "control ${_CONTROL_SHA}: an absent key exits ${_r%%|*}, reproducing the abort that killed walk 5" ;;
esac

# And the control must still WORK when the key is present, or its non-zero
# above could be any old breakage rather than this one.
_r="$(_run "$_ctl" "${WORK}/present.toml" allowed_numbers whatsapp)"
case "$_r" in
    "0|+447700900000") ok "CONTROL ON THE CONTROL: the pre-fix tree is fine when the key EXISTS, so absence is the discriminator" ;;
    *)                 bad "the pre-fix tree also fails with the key present (${_r}); the control proves nothing about absence" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
