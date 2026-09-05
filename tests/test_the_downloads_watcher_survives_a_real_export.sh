#!/usr/bin/env bash
# The Downloads export watcher must survive an export actually being there.
#
# WHY THIS EXISTS. MEASURED on a v1.0.71 box, 2026-09-05, by running the
# SHIPPED scanner after planting one synthetic export in ~/Downloads:
#
#     /Users/<u>/.ostler/bin/ostler-scan-exports: line 18:
#         OSTLER_OSASCRIPT_TIMEOUT_S: unbound variable
#     rc=1
#
# ostler-scan-exports is written from a QUOTED heredoc, so it shares no scope
# with install.sh. `_notify` called install.sh's `_ostler_run_with_deadline`
# with install.sh's `$OSTLER_OSASCRIPT_TIMEOUT_S`; neither name exists in the
# generated file, and it runs under `set -u`, where an unbound variable is
# fatal.
#
# THE SHAPE OF THE ZERO, WHICH IS THE REASON THIS WENT UNSEEN. `_notify` is
# reached only AFTER an export is found, and is called BEFORE the importer.
# On an empty Downloads the script returns 0 at the `FOUND -eq 0` guard, so
# launchd recorded `runs = 1, last exit code = 0` and wrote a 0-byte log --
# indistinguishable from a healthy run, because it WAS a healthy run of a
# scanner with nothing to do. Every customer with a real export got nothing
# imported, silently.
#
# THE TEST IS RUNTIME AND HAS TO BE. The defect is a shell fatal under an
# option, and the fixed and broken files are equally plausible to a reader.
# So: extract the generated scanner, give it a fixture HOME with one synthetic
# export, stub the importer, and assert THE IMPORTER WAS CALLED.
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

# Extract the generated scanner from a tree. The heredoc is QUOTED, so the
# body is literal and needs no expansion.
_extract_scanner() {
    awk "/cat > .*ostler-scan-exports\" <<'SCANEOF'/ { f = 1; next }
         f && /^SCANEOF\$/ { exit }
         f { print }" "$1"
}

# Build a fixture HOME, run the scanner in it, and report what happened.
# Echoes "<rc>|<importer_calls>|<stderr first line>".
_run_scanner() {
    local scanner_src="$1" plant="$2"
    local H="${WORK}/home"; rm -rf "$H"; mkdir -p "$H/Downloads" "$H/.ostler/bin" "$H/.ostler/state"

    # One synthetic export. Fictional names, example.com addresses: nothing
    # here belongs to a real person.
    if [ "$plant" = "plant" ]; then
        mkdir -p "$H/Downloads/Basic_LinkedInDataExport_fixture"
        printf 'First Name,Last Name,Email Address\nTestcase,Alpha,testcase.alpha@example.com\n' \
            > "$H/Downloads/Basic_LinkedInDataExport_fixture/Connections.csv"
    fi

    # Stub the importer: it records that it was called, and with what.
    cat > "$H/.ostler/bin/ostler-import" <<'IMP'
#!/usr/bin/env bash
echo "$@" >> "${HOME}/.ostler/importer_calls"
exit 0
IMP
    chmod +x "$H/.ostler/bin/ostler-import"

    # Stub osascript so a test never posts a real notification, and so the
    # deadline helper has something bounded to run.
    mkdir -p "${WORK}/stub"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/stub/osascript"
    chmod +x "${WORK}/stub/osascript"

    printf '%s\n' "$scanner_src" > "${WORK}/scan.sh"
    local err rc calls
    err="$(HOME="$H" PATH="${WORK}/stub:${PATH}" bash "${WORK}/scan.sh" 2>&1 >/dev/null)"; rc=$?
    calls=0
    [ -f "$H/.ostler/importer_calls" ] && calls=$(wc -l < "$H/.ostler/importer_calls" | tr -d ' ')
    printf '%s|%s|%s' "$rc" "$calls" "$(printf '%s' "$err" | head -1)"
}

echo "== subject: this tree =="
_SRC="$(_extract_scanner "$SUBJECT")"
[ -n "$_SRC" ] || { echo "CANNOT-RUN: no SCANEOF scanner found in ${SUBJECT}" >&2; exit 2; }

_r="$(_run_scanner "$_SRC" plant)"
_rc="${_r%%|*}"; _rest="${_r#*|}"; _calls="${_rest%%|*}"; _err="${_rest#*|}"
case "${_rc}|${_calls}" in
    "0|1") ok "an export in Downloads reaches the importer: rc 0, importer called once" ;;
    *"|0") bad "THE IMPORTER WAS NEVER CALLED (rc ${_rc}). This is the measured defect. stderr: ${_err}" ;;
    *)     bad "rc ${_rc}, importer called ${_calls} time(s). Expected rc 0 and exactly 1. stderr: ${_err}" ;;
esac

case "$_err" in
    *"unbound variable"*) bad "the scanner still dies on an unbound variable: ${_err}" ;;
    *)                    ok "no unbound-variable fatal on the path that finds an export" ;;
esac

# CONTROL: an EMPTY Downloads must still be a clean no-op. If this breaks, the
# fix has traded one failure for another.
_r="$(_run_scanner "$_SRC" none)"
case "$_r" in
    "0|0|"*) ok "CONTROL: an empty Downloads is a clean no-op -- rc 0, importer not called" ;;
    *)       bad "an empty Downloads now gives '${_r}', expected rc 0 with no importer call" ;;
esac

# The two names must be resolvable INSIDE the generated file, not in install.sh.
# This is the class, not the instance: the heredoc is quoted, so nothing from
# install.sh's scope is available at runtime.
_missing=0
printf '%s\n' "$_SRC" | /usr/bin/grep -q '^OSTLER_OSASCRIPT_TIMEOUT_S=' || _missing=$((_missing+1))
printf '%s\n' "$_SRC" | /usr/bin/grep -q '^_ostler_run_with_deadline()' || _missing=$((_missing+1))
if [ "$_missing" -eq 0 ]; then
    ok "both names _notify depends on are DEFINED INSIDE the generated scanner"
else
    bad "${_missing} of 2 names _notify depends on are still borrowed from install.sh's scope"
fi

# The bound must survive. A bare osascript with no deadline would pass every
# arm above and would reintroduce the 23h56m wedge.
if printf '%s\n' "$_SRC" | /usr/bin/grep -q '_ostler_run_with_deadline "\$OSTLER_OSASCRIPT_TIMEOUT_S"'; then
    ok "the notification is still BOUNDED, so a hung Apple Event cannot wedge the import chain"
else
    bad "the notification is no longer routed through the deadline helper"
fi

# -- NEGATIVE CONTROL, pinned to the tree that shipped the defect ------------
# 2fb58d1e is origin/main at the time the fix was written -- the tree whose
# generated scanner produced the rc=1 quoted at the top of this file. Pinned to
# a sha, never a branch: a control that reads origin/main inverts on merge.
_CONTROL_SHA="2fb58d1e"
echo "== negative control: ${_CONTROL_SHA} (the tree that shipped the defect) =="
_ctl="${WORK}/control_install.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read as" >&2
    echo "  a passing control." >&2
    exit 2
fi
_CSRC="$(_extract_scanner "$_ctl")"
if [ -z "$_CSRC" ]; then
    echo "CANNOT-RUN: no SCANEOF scanner in the control blob." >&2; exit 2
fi

_r="$(_run_scanner "$_CSRC" plant)"
_rc="${_r%%|*}"; _rest="${_r#*|}"; _calls="${_rest%%|*}"; _err="${_rest#*|}"
case "$_calls" in
    0) ok "control ${_CONTROL_SHA}: with an export present the importer is NEVER called (rc ${_rc}) -- the defect reproduces" ;;
    *) bad "control ${_CONTROL_SHA}: the importer was called ${_calls} time(s) there too, so this harness is not measuring the defect" ;;
esac
case "$_err" in
    *"unbound variable"*) ok "control ${_CONTROL_SHA}: dies on the unbound variable, which is the exact mechanism measured on the box" ;;
    *)                    bad "control ${_CONTROL_SHA} failed for some OTHER reason (${_err}); the control proves nothing about this defect" ;;
esac

# And the control must be FINE when Downloads is empty, or its failure above
# could be any old breakage rather than this one.
_r="$(_run_scanner "$_CSRC" none)"
case "$_r" in
    "0|0|"*) ok "CONTROL ON THE CONTROL: the pre-fix tree is clean on an EMPTY Downloads, so the presence of an export is the discriminator" ;;
    *)       bad "the pre-fix tree also fails with an empty Downloads (${_r}); the discriminator is not what this test claims" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
