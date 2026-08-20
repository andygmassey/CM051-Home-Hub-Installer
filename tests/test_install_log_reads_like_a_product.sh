#!/usr/bin/env bash
#
# The install log a CUSTOMER reads must not contain our scaffolding.
#
# WHY THIS EXISTS, AND WHY THE EXISTING GATE DID NOT CATCH IT.
#
# tests/test_no_internal_codenames_in_customer_strings.sh already guards
# internal codenames -- but it reads install.sh.strings.en-GB.sh, the string
# CATALOGUE. On 2026-08-20 Andy walked the v1.0.37 DMG on a Mac Mini. The
# install SUCCEEDED (exit 0, 42 minutes, 8/8 health checks) and he was angry
# anyway, because the log read like a debugger someone forgot to switch off:
#
#     12:40:17  [INFO ] CX-37 probe: entering
#     12:40:17  [INFO ] CX-37 probe: exiting          (x14 lines)
#     13:00:39  [INFO ] $MSG_OK_ENRICH_AGENT_LOADED   (the literal, unexpanded)
#
# None of that lives in the catalogue. It is emitted from install.sh itself, so
# the catalogue gate was green the whole time. Instrument and defect on
# different surfaces: a guard watching the wrong OBJECT is green forever and
# never self-corrects. This gate watches install.sh's own emission sites.
#
# Controls are listed at the bottom and every one of them must run; a gate with
# an unproven predicate is not a gate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

# Establish the precondition BEFORE measuring. A missing file must be named as
# a missing file, not reported as "0 violations found" -- that is the shape of
# zero this repo has been bitten by repeatedly.
if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "CANNOT RUN: install.sh not found at ${INSTALL_SH}" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "CANNOT RUN: python3 is required to walk heredocs" >&2
    exit 2
fi

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# The predicate, as a reusable program.
#
# It walks install.sh tracking heredocs, because text inside `cat <<EOF` is
# written into a GENERATED script and resolves at that script's runtime -- a
# `\$MSG_` there is correct, not a defect. Getting this wrong in either
# direction makes the gate useless.
#
# ⚠️ A `<<NAME` appearing inside a COMMENT is not a heredoc opener. install.sh
# line 8695 contains the text `cat > ostler-uninstall <<'UNINSTALLEOF'` inside
# a comment; a naive scanner treats that as an opener, never finds its
# terminator, and then reports every subsequent line as "inside a heredoc" --
# which is exactly how this defect stayed invisible to a first-pass sweep.
# ---------------------------------------------------------------------------
scan() {
    # scan <file> <mode>   mode = literal_msg | cx_probe
    python3 - "$1" "$2" <<'PYEOF'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
term = None
out = []
for n, line in enumerate(lines, 1):
    if term is None:
        stripped = line.lstrip()
        if not stripped.startswith('#'):
            m = re.search(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1', line)
            if m:
                term = m.group(2)
        # live line -- test it
        if stripped.startswith('#'):
            continue
        if mode == 'literal_msg':
            # a backslash-escaped MSG_ reference prints the variable NAME
            if re.search(r'\\\$\{?MSG_', line):
                out.append((n, line.strip()))
        elif mode == 'cx_probe':
            # a customer-visible emitter carrying an internal CX-nnn tag
            if re.match(r'\s*(info|ok|warn|err)\s+"[^"]*CX-\d', line) or \
               re.match(r'\s*gui_log\s+\w+\s+"[^"]*CX-\d', line):
                out.append((n, line.strip()))
    else:
        if line.strip() == term:
            term = None
for n, l in out:
    print(f"{n}\t{l[:150]}")
PYEOF
}

echo "install.sh customer-log hygiene"
echo

# --- 1. no live line prints a literal $MSG_ -------------------------------
hits="$(scan "${INSTALL_SH}" literal_msg)"
if [[ -z "$hits" ]]; then
    ok "no live line emits an unexpanded \$MSG_ reference"
else
    bad "live lines emit the literal text of a MSG_ variable name:"
    printf '%s\n' "$hits" | sed 's/^/          /'
fi

# --- 2. no customer-visible emitter carries a CX-nnn tag ------------------
hits="$(scan "${INSTALL_SH}" cx_probe)"
if [[ -z "$hits" ]]; then
    ok "no info/ok/warn/gui_log emits an internal CX-nnn probe tag"
else
    bad "customer-visible emitters carry internal CX-nnn tags:"
    printf '%s\n' "$hits" | sed 's/^/          /'
fi

# --- 3. ANTI-VACUITY: the predicate must find a seeded violation ----------
# Without this, a broken regex reports a clean file and the gate is decorative.
seed="$(mktemp)"; trap 'rm -f "$seed"' EXIT
cat > "$seed" <<'SEEDEOF'
#!/bin/bash
ok "\$MSG_OK_SOMETHING"
info "CX-37 probe: entering"
# ok "\$MSG_IN_A_COMMENT"        <- must NOT count
cat > /tmp/generated <<GEN
ok "\$MSG_INSIDE_A_HEREDOC"
info "CX-99 probe: inside heredoc"
GEN
SEEDEOF
seeded_msg="$(scan "$seed" literal_msg | wc -l | tr -d ' ')"
seeded_cx="$(scan "$seed" cx_probe   | wc -l | tr -d ' ')"
if [[ "$seeded_msg" == "1" ]]; then
    ok "anti-vacuity: finds the seeded \$MSG_ leak, and only it (comment + heredoc excluded)"
else
    bad "anti-vacuity: expected exactly 1 seeded \$MSG_ hit, got ${seeded_msg}"
fi
if [[ "$seeded_cx" == "1" ]]; then
    ok "anti-vacuity: finds the seeded CX probe, and only it (heredoc excluded)"
else
    bad "anti-vacuity: expected exactly 1 seeded CX hit, got ${seeded_cx}"
fi

# --- 4. the enrichment loader must observe, not assume --------------------
# `launchctl load` exits 0 even for a plist that does not exist (measured,
# macOS 26.5.2), so branching on its status makes the success message
# unconditional and the failure branch unreachable. The only trustworthy
# answer comes from asking launchd what is registered.
# ⚠️ DO NOT bound this with `awk '/^_install_enrichment_agent\(\) \{/,/^\}/'`.
# That was the first version and it was WRONG: the function contains a NESTED
# definition (enriched_count) whose closing brace sits at column 0, so the
# range ended ~80 lines early, never reached the launchctl block, and fed both
# checks an empty region. One check then failed for the wrong reason and its
# sibling PASSED VACUOUSLY -- a gate reporting green on nothing at all.
#
# Anchor on the message instead. The property is local by nature: whatever
# decides MSG_OK_ENRICH_AGENT_LOADED must be an observation of launchd.
verify_window() {
    local ln
    # Anchor on the EMITTER, not on any line mentioning the key. The comment
    # block above the fix quotes the key by name, and a first version of this
    # filter used `grep -v '^\s*#'` -- `\s` is a GNU extension that BSD grep's
    # BRE does not honour, so the comment was never excluded and the window
    # landed 14 lines short of the code it was meant to inspect.
    ln="$(grep -nE '^[[:space:]]*ok[[:space:]]+"\$(\{)?MSG_OK_ENRICH_AGENT_LOADED' "${INSTALL_SH}" | head -1 | cut -d: -f1)"
    [[ -n "$ln" ]] || return 1
    local from=$(( ln > 14 ? ln - 14 : 1 ))
    sed -n "${from},${ln}p" "${INSTALL_SH}"
}

if ! win="$(verify_window)"; then
    bad "cannot locate the enrichment success message -- predicate needs updating"
elif grep -q 'launchctl print' <<<"$win"; then
    ok "the enrichment success message is decided by launchctl print (an observation)"
else
    bad "the enrichment success message is not preceded by a launchctl print check -- \
it cannot be trusted, because launchctl load returns 0 on failure"
fi

# A check fed an empty window must FAIL, not pass. On the pre-fix tree the
# window could not be located, and the first version of this check answered
# "does not branch on launchctl load" -- a green verdict on nothing at all,
# which is precisely the vacuity the block above exists to prevent.
if [[ -z "${win:-}" ]]; then
    bad "cannot judge the launchctl branch: the window is empty (see previous failure)"
elif grep -qE 'if +launchctl +(bootstrap|load)' <<<"${win}"; then
    bad "the enrichment message still branches on a launchctl invocation's exit status"
else
    ok "the enrichment message does not branch on launchctl load's exit status"
fi

# --- 5. the consent decision must reach disk ------------------------------
# #794: the answer used to be exported and nothing else, under a comment
# claiming it was recorded.
if grep -q 'enrichment-decision.json' "${INSTALL_SH}"; then
    ok "the background-enrichment decision is written to disk, not just exported"
else
    bad "the background-enrichment decision never reaches disk (#794)"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
