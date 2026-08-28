#!/usr/bin/env bash
# =============================================================================
# install.sh diagnostics must go to a PRIVATE, PER-RUN directory (board #910)
# =============================================================================
#
# WHAT BROKE. Andy's first-ever walk of install.sh died in three minutes and
# showed him a different session's pip error. One root cause, two defects,
# both measured on /bin/bash 3.2.57 -- the shell that runs install.sh:
#
#   1. BASH ABORTS A COMMAND WHOSE REDIRECTION CANNOT BE OPENED. With a fixed
#      sink at /tmp/ostler-pip-install.log owned by someone else,
#          if pip install ... 2>/tmp/ostler-pip-install.log; then
#      takes the ELSE branch for a pip run THAT NEVER EXECUTED, and the
#      installer says "the package failed to install".
#
#   2. The else branch then seds that path to the screen. The failed redirect
#      never truncated it, so the customer reads the previous owner's text.
#
# WHY THIS FILE IS SHAPED THE WAY IT IS. Arm 7 deliberately re-creates the OLD
# shape and proves it still misbehaves. That is not redundant: it is the
# control for arms 5 and 6. Without it, a future change that made the whole
# mechanism impossible to trigger would leave arms 5/6 passing vacuously and
# nobody would know the test had stopped testing anything.
#
# Usage:  bash tests/test_diag_sink_per_run.sh
# Exit:   0 all arms pass · 1 an arm failed · 2 CANNOT-RUN (never a pass)
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0; fail=0
ok()   { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  [FAIL] %s\n' "$*" >&2; fail=$((fail+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*" >&2; exit 2; }

[ -r "$INSTALL_SH" ] || cant "install.sh not readable at ${INSTALL_SH}"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/diagsink-test-XXXXXX")" || cant "could not create sandbox"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

echo "== install.sh diagnostic sink: private + per-run (#910) =="

# -- ARM 1: no fixed /tmp sink survives anywhere in install.sh ---------------
# Counts PATHS, not redirect sites, because a read-back or a warn string that
# still names /tmp/ostler-*.log is just as wrong as a redirect: it would tell
# the customer to go and read a file we no longer write.
n_fixed="$(/usr/bin/grep -cE '/tmp/ostler-[a-z0-9.-]+\.log' "$INSTALL_SH")"
if [ "$n_fixed" -eq 0 ]; then
    ok "arm 1: zero fixed /tmp/ostler-*.log paths remain (denominator: whole file)"
else
    bad "arm 1: ${n_fixed} fixed /tmp/ostler-*.log path(s) still present"
    /usr/bin/grep -nE '/tmp/ostler-[a-z0-9.-]+\.log' "$INSTALL_SH" | head -5 >&2
fi

# -- ARM 2: the sink is created by mktemp -d with an EXPLICIT template -------
if /usr/bin/grep -qE 'OSTLER_DIAG_DIR="\$\(mktemp -d "\$\{TMPDIR:-/tmp\}/ostler-diag-XXXXXX"\)"' "$INSTALL_SH"; then
    ok "arm 2: OSTLER_DIAG_DIR uses mktemp -d with an explicit \${TMPDIR:-/tmp} template"
else
    bad "arm 2: no mktemp -d with an explicit \${TMPDIR:-/tmp} template found"
fi

# -- ARM 3: NOT `mktemp -t` --------------------------------------------------
# BSD mktemp -t IGNORES TMPDIR and always uses the system default, so -t would
# put the sink straight back into the shared /tmp this change exists to leave.
# install.sh:2388 already carries that measurement; this arm keeps it true.
#
# 🔴 COMMENTS ARE STRIPPED FIRST, AND THAT IS NOT COSMETIC. The first version
# of this arm grepped the raw file and FAILED -- on the comment in install.sh
# that says DO NOT simplify this to `mktemp -d -t`. The warning against the
# bug scored as the bug. That is boards #757/#688/#808 (a predicate that
# counts MENTIONS instead of INVOCATIONS), reproduced inside the very suite
# meant to guard this change. Strip comments, then score code.
# 🔴 AND THE OPERAND IS A HERE-STRING, NOT A PIPE. `printf "%s" "$BIG" |
# grep -q ...` is INERT under `set -o pipefail`, which this file sets: grep
# exits 0 on the FIRST match and closes the pipe, printf dies of SIGPIPE
# (141), and pipefail returns the rightmost NON-ZERO status -- so the `if`
# sees 141 and takes the else branch. MEASURED here: PIPESTATUS was
# `141 0` and the arm reported PASS against a file that DID contain the
# forbidden form. It is size-dependent, which is what makes it vicious:
# with a small operand printf finishes before grep exits and the same code
# works. install.sh is 563 KB, so this arm was silently unable to fail.
CODE_ONLY="$(/usr/bin/sed -e 's/[[:space:]]*#.*$//' "$INSTALL_SH")"
if /usr/bin/grep -qE 'mktemp -d -t .*ostler-diag' <<< "$CODE_ONLY"; then
    bad "arm 3: OSTLER_DIAG_DIR uses 'mktemp -d -t', which ignores TMPDIR on BSD"
else
    ok "arm 3: no 'mktemp -d -t' INVOCATION for the diag dir (comments stripped first)"
fi

# -- ARM 4: creation failure REFUSES, it does not fall back to /tmp ----------
blk="$(/usr/bin/sed -n '/^if ! OSTLER_DIAG_DIR=/,/^fi$/p' "$INSTALL_SH")"
if [ -z "$blk" ]; then
    bad "arm 4: could not locate the OSTLER_DIAG_DIR creation block"
elif /usr/bin/grep -q 'exit 1' <<< "$blk" \
     && ! /usr/bin/grep -qE 'OSTLER_DIAG_DIR=.*(/tmp|/var/tmp)"?$' <<< "$blk"; then
    ok "arm 4: creation failure exits rather than falling back to a shared path"
else
    bad "arm 4: creation-failure path does not refuse, or falls back to a shared dir"
fi

# -- ARM 5 (BEHAVIOURAL): run the real block; per-run and private ------------
# Extract the shipped block and execute it, twice, rather than re-typing it.
extract_block() { /usr/bin/sed -n '/^if ! OSTLER_DIAG_DIR=/,/^export OSTLER_DIAG_DIR$/p' "$INSTALL_SH"; }
BLOCK="$(extract_block)"
if [ -z "$BLOCK" ]; then
    cant "arm 5: could not extract the OSTLER_DIAG_DIR block from install.sh"
fi

d1="$(TMPDIR="$SANDBOX" /bin/bash -c "$BLOCK"'; printf "%s" "$OSTLER_DIAG_DIR"')" || d1=""
d2="$(TMPDIR="$SANDBOX" /bin/bash -c "$BLOCK"'; printf "%s" "$OSTLER_DIAG_DIR"')" || d2=""

if [ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ]; then
    ok "arm 5a: two runs get DIFFERENT directories (${d1##*/} vs ${d2##*/})"
else
    bad "arm 5a: runs did not get distinct directories (d1='${d1}' d2='${d2}')"
fi

case "$d1" in
    "$SANDBOX"/*) ok "arm 5b: the sink honours TMPDIR (landed under the sandbox)" ;;
    *)            bad "arm 5b: sink ignored TMPDIR — landed at '${d1}', not under ${SANDBOX}" ;;
esac

if [ -d "$d1" ]; then
    perms="$(/usr/bin/stat -f '%Lp' "$d1" 2>/dev/null || echo '?')"
    if [ "$perms" = "700" ]; then
        ok "arm 5c: sink is mode 700 — another user cannot pre-create our log files"
    else
        bad "arm 5c: sink is mode ${perms}, expected 700"
    fi
else
    bad "arm 5c: sink directory '${d1}' does not exist"
fi

# -- ARM 6 (THE CONTROL ARCHIE REQUIRED): a GENUINE failure still reports RED
# A fix that silenced real failures would be worse than the bug. Under the new
# scheme the sink is writable, so the command RUNS; when it fails on its own
# merits we must take the else branch AND show ITS OWN stderr.
sink="${d1}/genuine.log"
verdict="$( /bin/bash -c '
    if /bin/sh -c "printf \"pip: could not resolve dependency zzz\n\" >&2; exit 1" 2>"'"$sink"'"; then
        echo THEN
    else
        echo ELSE
    fi' )"
saw="$(cat "$sink" 2>/dev/null)"
if [ "$verdict" = "ELSE" ] && /usr/bin/grep -q 'could not resolve dependency zzz' <<< "$saw"; then
    ok "arm 6: a genuine failure STILL reports RED, and shows its OWN stderr"
else
    bad "arm 6: genuine failure not reported correctly (verdict=${verdict}, sink content='${saw}')"
fi

# -- ARM 7 (ANTI-VACUITY CONTROL): the old shape still misbehaves ------------
# Proves the mechanism arms 5/6 defend against is real and reachable on THIS
# host and THIS shell. If this arm ever passes-by-not-failing, arms 5 and 6
# have stopped meaning anything and this file must be re-thought.
oldsink="${SANDBOX}/fixed-shared.log"
printf 'ERROR: a different session left this here\n' > "$oldsink"
chmod 0444 "$oldsink"
marker="${SANDBOX}/old-shape-ran.marker"
rm -f "$marker"
oldverdict="$( /bin/bash -c '
    if /usr/bin/touch "'"$marker"'" 2>"'"$oldsink"'"; then echo THEN; else echo ELSE; fi' 2>/dev/null )"
if [ "$oldverdict" = "ELSE" ] && [ ! -e "$marker" ]; then
    ok "arm 7: old fixed-path shape still fails closed on this host (control is live)"
else
    bad "arm 7: CONTROL DID NOT REPRODUCE — the redirect-abort mechanism did not fire here, so arms 5/6 may be vacuous (verdict=${oldverdict}, marker exists=$([ -e "$marker" ] && echo yes || echo no))"
fi
chmod 0644 "$oldsink" 2>/dev/null

echo
printf '== %s pass / %s fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
