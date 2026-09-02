#!/usr/bin/env bash
# ============================================================================
# E1 (#599): THE T+0 SOURCE-STATUS READOUT MUST ACTUALLY EMIT A LINE (G5/E1)
#
# WHY THIS TEST EXISTS, and why "bash -n clean" was never enough.
#
# The first cut of E1 called `log "..."`. In install.sh's MAIN BODY `log` is not
# defined -- the four `log()` definitions live INSIDE heredocs that write OTHER
# scripts. Under `set -uo pipefail` a command-not-found is not fatal, so the two
# readout calls resolved to nothing, wrote nothing, and aborted nothing. The
# install log would have carried NO source-status line on every install and the
# whole feature would have been silently absent -- and `bash -n`, the nounset
# test, and "it did not crash" would all still be green. The heredoc-only-symbol
# gate caught the symbol; this test catches the CONSEQUENCE: does a line emit?
#
# HOW IT PROVES EMISSION WITHOUT A LIVE BOX.
#   - It extracts the REAL info()/gui_log()/gui_active() from install.sh's main
#     body and the REAL E1 block (anchored on `# E1 (#599):`). No reimplementation.
#   - It stubs `curl` so the block's $(curl .../api/v1/sources) returns a chosen
#     body, and drives the two branches: a served artefact, and an unreachable
#     endpoint (curl -> empty).
#   - It reads what landed on stdout, which is the stream install.sh tees to
#     install.log via `gui_active || echo` in the default (non-GUI) path.
#
# THE ANTI-VACUITY LIMB is the point of the whole file: it reverts `info`->`log`
# in the extracted block, leaves `log` undefined exactly as the main body does,
# and asserts NOTHING emits. If that limb also emitted, this test would be blind
# to the very defect it was written for.
#
# SCOPE, stated honestly: this proves emission on the stdout/install.log path
# (gui_active default returns 1, so info() echoes). The GUI path routes the same
# string through gui_log(); that destination is not exercised here.
#
# Exit: 0 emits correctly | 1 does not | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note()   { printf '        %s\n' "$1"; }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$INSTALL" ] || cannot "install.sh not readable at ${INSTALL}"
command -v python3 >/dev/null 2>&1 || cannot "python3 not on PATH; the E1 summariser needs it"

echo "== E1 (#599): the T+0 source-status readout emits a line =="

WORK=""
cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }
trap cleanup EXIT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-e1emit-XXXXXX")" || cannot "could not create a work directory"

# ── EXTRACT THE REAL LOGGING PRIMITIVES (main-body defaults). ───────────
# info() at ~1252, and the gui_log()/gui_active() defaults it depends on.
{
  grep -m1 '^gui_log()' "$INSTALL"
  grep -m1 '^gui_active()' "$INSTALL"
  grep -m1 '^info()' "$INSTALL"
} > "${WORK}/logging.sh"
_have="$(grep -c '() ' "${WORK}/logging.sh" || true)"
[ "${_have:-0}" -eq 3 ] || cannot "expected to extract gui_log + gui_active + info (3), got ${_have:-0}. They moved or were renamed; every verdict below would be about the wrong code."
grep -q '^info()' "${WORK}/logging.sh" || cannot "info() not extracted"
note "extracted gui_log() + gui_active() + info() from install.sh main body"

# ── EXTRACT THE REAL E1 BLOCK (anchored, not reimplemented). ────────────
awk '
    /^# E1 \(#599\):/ { grab = 1 }
    grab && /^_sources_json=/ { emit = 1 }
    emit { print }
    emit && /^fi$/ { exit }
' "$INSTALL" > "${WORK}/e1_block.sh"
[ -s "${WORK}/e1_block.sh" ] || cannot "E1 block not found (anchor '# E1 (#599):' + _sources_json= .. fi). It moved or was renamed."
grep -q 'api/v1/sources' "${WORK}/e1_block.sh" || cannot "extracted block does not curl /api/v1/sources; anchor caught the wrong region"
note "extracted the real E1 block ($(wc -l < "${WORK}/e1_block.sh" | tr -d ' ') lines)"

# ── PREMISE: the block reaches the log via a symbol that EXISTS. ────────
# If someone regresses info -> log, the block's log lines resolve to nothing;
# the GOOD-path assertion below would then fail for real. This premise makes
# the reason legible rather than leaving it to a mysterious empty stdout.
if grep -qE '(^|[^_[:alnum:]])log[[:space:]]+"Source status' "${WORK}/e1_block.sh"; then
    bad "PREMISE BROKEN: the E1 block calls \`log\` for the readout, and \`log\` is heredoc-only in install.sh's body. The readout would be silently absent on every install. This is the exact defect #1351 fixed."
    finish
fi

# runner: <curl-body> -> stdout the E1 block produced, given that curl body.
_run_block() {
    local body="$1"
    (
      set +u
      . "${WORK}/logging.sh"
      # Stub curl so the real block's $(curl ...) returns our chosen body.
      curl() { printf '%s' "$OSTLER_E1_CURL_BODY"; }
      OSTLER_E1_CURL_BODY="$body"
      . "${WORK}/e1_block.sh"
    ) 2>/dev/null
}

# ── 1. SERVED ARTEFACT -> a real summary line emits. ───────────────────
good='{"sources": ['
for i in $(seq 1 11); do good="${good}{\"source\":\"s$i\",\"status\":\"not_run\",\"item_count\":null},"; done
good="${good}{\"source\":\"people\",\"status\":\"ok\",\"item_count\":5},{\"source\":\"places\",\"status\":\"ok\",\"item_count\":3}]}"
out="$(_run_block "$good")"
if grep -q 'Source status (T+0):' <<< "$out"; then
    ok "a served artefact emits a 'Source status (T+0):' line"
else
    bad "SERVED artefact produced NO 'Source status (T+0):' line on stdout. The readout does not emit. Got: $(printf '%s' "$out" | head -1)"
fi
if grep -q '13 sources reporting, 2 landed at install, 11 not yet run' <<< "$out"; then
    ok "the emitted summary is accurate (13 sources, 2 landed, 11 not yet run)"
else
    bad "the summary is wrong. Expected '13 sources reporting, 2 landed at install, 11 not yet run', got: $(printf '%s' "$out" | grep 'Source status' || printf '(none)')"
fi

# ── 2. UNREACHABLE endpoint -> the not-reachable note emits. ───────────
# curl -> empty is exactly what `|| true` yields when the endpoint is down.
out="$(_run_block "")"
if grep -q 'Source status (T+0):' <<< "$out"; then
    ok "an unreachable endpoint still emits a 'Source status (T+0):' line (the note)"
else
    bad "UNREACHABLE endpoint emitted no line at all; the install log would be silent on a Doctor that is still starting."
fi
if grep -q 'not reachable at install end' <<< "$out"; then
    ok "the unreachable branch emits the not-reachable note, not a fabricated summary"
else
    bad "unreachable endpoint did not emit the 'not reachable' note. Got: $(printf '%s' "$out" | grep 'Source status' || printf '(none)')"
fi

# ── 3. A 404 error body is NOT read as the artefact. ───────────────────
# {"detail":"Not Found"} has no `sources` list; the summariser sys.exit(0)s with
# no line, so the block falls to the not-reachable note rather than "1 sources".
out="$(_run_block '{"detail":"Not Found"}')"
if grep -q 'not reachable at install end' <<< "$out"; then
    ok "a 404 error body falls to the not-reachable note, not a bogus count"
else
    bad "a 404 body was read as the artefact: $(printf '%s' "$out" | grep 'Source status' || printf '(none)')"
fi

# ── 4. ANTI-VACUITY: revert info->log and prove NOTHING emits. ─────────
# This is the pre-fix shape: `log` undefined in the main body, command-not-found
# is non-fatal under set -uo pipefail, so the readout writes nothing. If this
# limb ALSO emitted, every pass above would be meaningless.
sed 's/info "Source status/log "Source status/' "${WORK}/e1_block.sh" > "${WORK}/e1_prefix.sh"
grep -q 'log "Source status' "${WORK}/e1_prefix.sh" || cannot "anti-vacuity setup failed: could not rewrite info->log in the extracted block"
# ( ... ) 2>/dev/null so the pre-fix `log` misfire (it invokes /usr/bin/log,
# the macOS system logger, with a garbage subcommand -> usage on STDERR) does
# not pollute this test's output. The point is only what reaches STDOUT.
out="$( (
    set +u
    . "${WORK}/logging.sh"
    curl() { printf '%s' "$OSTLER_E1_CURL_BODY"; }
    OSTLER_E1_CURL_BODY="$good"
    . "${WORK}/e1_prefix.sh"
  ) 2>/dev/null )"
if grep -q 'Source status (T+0):' <<< "$out"; then
    bad "ANTI-VACUITY FAILED: the pre-fix \`log\` shape ALSO emitted a line. This test cannot tell emit from silent no-op and proves nothing above."
else
    ok "anti-vacuity: the pre-fix \`log\` shape emits NOTHING, so this test genuinely distinguishes info (emits) from log (silent)"
fi

finish
