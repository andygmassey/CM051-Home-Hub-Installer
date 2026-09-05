#!/usr/bin/env bash
# NO TOP-LEVEL CALL MAY PRECEDE ITS FUNCTION DEFINITION.
#
# WHY THIS EXISTS. MEASURED 2026-09-04 on walk 10, archie@192.168.1.240, the
# first walk ever to reach step 21 of 40:
#
#     #OSTLER STEP_END id=email_ingest status=error elapsed_s=5 rc=127
#     Install aborted unexpectedly at line 21445 (step email_ingest):
#         _OSTLER_CONSENT_TP_EMAIL="$(_ostler_consent_state ...)"
#     #OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L21445
#
# install.sh is a linear script. Its step bodies are top-level statements in
# file order, so a top-level call runs the moment the interpreter reaches it
# and the name must already be bound. #1439 relocated that one definition.
#
# THE POINT OF THIS FILE IS THE CLASS, NOT THAT ONE SITE. #1439 fixed the
# instance. Nothing stopped the next one, and the sweep that found it was me
# READING 161 definitions, which is not a thing that can be re-run.
#
# WHAT IS AND IS NOT A DEFECT:
#   top level, call before definition ....... DEFECT (rc=127 at runtime)
#   inside a function body, defined later ... FINE (resolved at invocation)
#   inside a single-quoted string ........... FINE (never executed)
#   inside a heredoc writing another file ... FINE (a different script)
#
# TWO BLINDNESSES THIS INSTRUMENT WAS BUILT WITH AND HAD TO HAVE REMOVED. Both
# were caught by controls, before either produced a number worth quoting:
#
#   1. Stripping double-quoted spans as "text" deleted "$(_ostler_consent_state
#      ...)" -- a COMMAND SUBSTITUTION, i.e. code inside quotes, and the exact
#      shape of the defect. The known positive scored CLEAN.
#   2. `# <<< WORD` in a comment is a here-STRING. Treating it as a heredoc
#      opened one that never closed and swallowed 5,700 lines to EOF, and a
#      heredoc opener written `<<'WORD'` was invisible when searched for in the
#      masked line, because masking ate the quotes.
#
# So this file runs FIVE synthetic controls -- two that must FLAG and three
# that must MISS -- before it is allowed to report anything about install.sh.
# A zero from an instrument that has not proved it can see is not a pass.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || {
    echo "CANNOT-RUN: python3 is absent; the analyser cannot run and a" >&2
    echo "  skipped scan must never be reported as a clean one." >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
AN="${WORK}/callorder.py"

cat > "$AN" <<'ANALYSER_EOF'
#!/usr/bin/env python3
"""Top-level calls to functions defined LATER in a linear bash script.

install.sh executes top to bottom. A call at TOP LEVEL runs when the
interpreter reaches it, so the name must already be bound. A call inside a
function body resolves at INVOCATION, so ordering there does not matter.
Telling those apart is the entire job.

TWO BLINDNESSES THIS CODE EXISTS TO AVOID, both measured on 2026-09-04:

  1. A naive quote-stripper deletes double-quoted spans. But
     "$(_ostler_consent_state ...)" is CODE inside quotes, and that is the
     exact shape of the #1439 defect. Stripping it scored the known
     positive as CLEAN.
  2. `# <<< WORD` in a comment is a here-STRING, not a heredoc. Matching it
     opened a heredoc that never closed and swallowed 5,700 lines to EOF.
"""
import re, sys

# LEADING WHITESPACE ALLOWED. Anchored at column 0 this regex could not see
# 40 of install.sh's own 159 function definitions -- 25%, including gui_log,
# gui_done, settling_report and the whole _upg_* upgrade path -- because they
# are defined inside `if` blocks and so are indented. A definition it cannot
# see is a name it never puts in `defs`, and a name not in `defs` can never be
# reported as called-before-defined. The scan's zero covered a quarter of the
# file. Measured 2026-09-05: widening this lifts defs from 119 to 146 and the
# subject still grades 0, so nothing was being hidden -- but a future indented
# definition with an early call would have shipped unseen.
DEF_RE = re.compile(r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')
# A heredoc opener: << or <<- but NOT <<< (here-string).
HD_RE = re.compile(r"<<-(?!<)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1|<<(?!<)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3")


def strip_comment(line):
    """Drop a trailing # comment, respecting quotes. Quotes are KEPT, because
    a heredoc terminator is frequently quoted: <<'EOF'. Masking it away made
    every quoted heredoc invisible, which is fixture E."""
    q = None
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c == '\\':
            i += 2; continue
        if q:
            if c == q:
                q = None
        elif c in ('"', "'"):
            q = c
        elif c == '#' and (i == 0 or line[i-1].isspace()):
            return line[:i]
        i += 1
    return line


def code_mask(line):
    """Return the line with comments and LITERAL text removed, but with
    command substitutions -- $( ) and backticks -- KEPT, including when they
    sit inside double quotes."""
    out = []
    i, n = 0, len(line)
    # stack of contexts: 'dq' double quote, 'sub' command substitution
    stack = []
    while i < n:
        c = line[i]
        top = stack[-1] if stack else None
        if c == '\\' and top != 'sq':
            i += 2
            continue
        if top == 'sq':
            if c == "'":
                stack.pop()
            i += 1
            continue
        if c == '#' and top is None and (not out or out[-1].isspace()):
            break
        if c == "'" and top != 'dq':
            stack.append('sq'); i += 1; continue
        if c == '"':
            if top == 'dq':
                stack.pop()
            else:
                stack.append('dq')
            i += 1
            continue
        if c == '$' and i + 1 < n and line[i+1] == '(':
            stack.append('sub'); out.append(' '); i += 2; continue
        if c == '`':
            if top == 'sub':
                stack.pop()
            else:
                stack.append('sub')
            out.append(' '); i += 1; continue
        if c == ')' and top == 'sub':
            stack.pop(); out.append(' '); i += 1; continue
        # emit if we are in real code, or inside a command substitution
        if top is None or top == 'sub':
            out.append(c)
        else:
            out.append(' ')          # keep column count stable-ish
        i += 1
    return ''.join(out)


def analyse(path):
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    defs, spans, open_stack = {}, [], []
    depth, in_hd = 0, None
    toplevel, hd_lines = [], 0

    for idx, raw in enumerate(lines, start=1):
        if in_hd is not None:
            hd_lines += 1
            if raw.strip() == in_hd:
                in_hd = None
            continue
        s = code_mask(raw)
        at0 = raw[:1] not in (' ', '\t')
        m = DEF_RE.match(raw)

        if depth == 0:
            toplevel.append(idx)
        # `at0` was the second half of the same column-0 restriction.
        if m:
            if m.group(1) not in defs:
                defs[m.group(1)] = idx
            open_stack.append((m.group(1), idx))

        nd = depth + s.count('{') - s.count('}')
        if nd < 0:
            nd = 0
        if depth > 0 and nd == 0 and open_stack:
            name, start = open_stack.pop()
            spans.append((name, start, idx))
            open_stack.clear()
        depth = nd

        hm = HD_RE.search(strip_comment(raw))
        if hm:
            in_hd = hm.group(2) or hm.group(4)
    return lines, defs, set(toplevel), spans, hd_lines, in_hd


def find_bad(path):
    lines, defs, toplevel, spans, hd_lines, dangling = analyse(path)
    if not defs:
        return defs, toplevel, spans, None, hd_lines, dangling
    names = sorted(defs, key=len, reverse=True)
    pat = re.compile(r'(?:^|[\s;&|(){}=])(' + '|'.join(map(re.escape, names)) + r')(?=[\s;&|)}]|$)')
    bad = []
    for ln in sorted(toplevel):
        raw = lines[ln-1]
        if DEF_RE.match(raw):
            continue
        s = code_mask(raw)
        if not s.strip():
            continue
        for m in pat.finditer(s):
            name = m.group(1)
            if ln < defs[name]:
                bad.append((ln, name, defs[name], raw.strip()[:88]))
    return defs, toplevel, spans, bad, hd_lines, dangling


if __name__ == '__main__':
    p = sys.argv[1]
    defs, toplevel, spans, bad, hd_lines, dangling = find_bad(p)
    print(f"  defs={len(defs)}  toplevel_lines={len(toplevel)}  spans_closed={len(spans)}"
          f"  heredoc_lines_skipped={hd_lines}  dangling_heredoc={dangling!r}")
    print(f"  CALL-BEFORE-DEFINITION AT TOP LEVEL: {len(bad)}")
    for ln, name, d, txt in bad[:25]:
        print(f"    L{ln} calls {name}() defined at L{d}\n         | {txt}")
ANALYSER_EOF

# Echoes the finding count, or "ERR".
_count() {
    local out
    out="$(python3 "$AN" "$1" 2>/dev/null)" || { printf 'ERR'; return; }
    printf '%s' "$out" | awk -F': ' '/CALL-BEFORE/{print $2}'
}

echo "── controls: the instrument must prove it can SEE and can ABSTAIN ──"

# MUST FLAG: the plain shape.
cat > "${WORK}/a.sh" <<'FIX'
#!/usr/bin/env bash
echo start
later_fn arg1
later_fn() {
    echo hi
}
FIX
[ "$(_count "${WORK}/a.sh")" = "1" ] \
    && ok "MUST-FLAG: a bare top-level call before its definition is caught" \
    || bad "MUST-FLAG: the plain shape was MISSED. The scan is blind; every zero below is meaningless."

# MUST FLAG: the #1439 shape -- a command substitution inside double quotes.
cat > "${WORK}/d.sh" <<'FIX'
#!/usr/bin/env bash
VALUE="$(later_fn some_id "$OTHER")"
later_fn() {
    echo hi
}
FIX
[ "$(_count "${WORK}/d.sh")" = "1" ] \
    && ok "MUST-FLAG: a call inside \"\$( )\" is code, not text, and is caught" \
    || bad "MUST-FLAG: the measured #1439 shape was MISSED -- quoted command substitution treated as a string."

# MUST FLAG: an INDENTED definition. This is the arm the column-0 DEF_RE could
# not have: 40 of install.sh's own definitions are indented because they sit
# inside `if` blocks, and a definition the scan cannot see is a name that can
# never be reported. Without this limb the widening is untested and a revert to
# `^(` would go green.
cat > "${WORK}/e.sh" <<'FIX'
#!/usr/bin/env bash
echo start
_indented_fn
if true; then
    _indented_fn() {
        echo hi
    }
fi
FIX
[ "$(_count "${WORK}/e.sh")" = "1" ] \
    && ok "MUST-FLAG: a call before an INDENTED definition is caught (the 40 the column-0 scan could not see)" \
    || bad "MUST-FLAG: an indented definition is invisible again. 25% of install.sh's own functions are unscanned and every zero below covers them."

# BY EXECUTION, so the limb above is anchored to a real consequence rather than
# to a regex: the same shape is fatal ONLY because install.sh sets -e. Measured
# 2026-09-05 -- with `set -Eeuo pipefail` (install.sh:29) rc=127 and the script
# never reaches its end; without it rc=0 and execution continues past the
# missing function. If install.sh ever drops -e this gate still matters, but
# the failure it prevents changes shape, and that should be noticed here.
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\necho start\n_indented_fn\nif true; then\n    _indented_fn() { echo hi; }\nfi\necho reached_the_end\n' > "${WORK}/f.sh"
_f_out="$(bash "${WORK}/f.sh" 2>&1)"; _f_rc=$?
_f_reached="$(printf '%s' "$_f_out" | grep -c reached_the_end || true)"
if [ "$_f_rc" = "127" ] && [ "${_f_reached:-0}" -eq 0 ]; then
    ok "BY EXECUTION: the flagged shape aborts with rc=127 under install.sh's own 'set -Eeuo pipefail'"
else
    bad "BY EXECUTION: expected rc=127 and no end-of-script, got rc=${_f_rc} reached=${_f_reached}. Either bash changed or -e is not doing what this gate assumes."
fi

# MUST MISS: legal bash. Resolved at invocation.
cat > "${WORK}/b.sh" <<'FIX'
#!/usr/bin/env bash
caller_fn() {
    later_fn arg1
}
later_fn() {
    echo hi
}
caller_fn
FIX
[ "$(_count "${WORK}/b.sh")" = "0" ] \
    && ok "MUST-MISS: a call inside a function body is not flagged; ordering is irrelevant there" \
    || bad "MUST-MISS: flagged legal bash. The scan is loud, not right, and its findings cannot be trusted."

# MUST MISS: a mention, not a call.
cat > "${WORK}/c.sh" <<'FIX'
#!/usr/bin/env bash
echo 'later_fn is only mentioned here'
later_fn() {
    echo hi
}
FIX
[ "$(_count "${WORK}/c.sh")" = "0" ] \
    && ok "MUST-MISS: the name inside a single-quoted string is not a call" \
    || bad "MUST-MISS: a single-quoted mention was read as a call."

# MUST MISS: install.sh writes other scripts with heredocs. Those are not its scope.
cat > "${WORK}/e.sh" <<'FIX'
#!/usr/bin/env bash
cat > /tmp/generated.sh <<'GEN_EOF'
later_fn
later_fn() { echo hi; }
GEN_EOF
later_fn() {
    echo hi
}
FIX
[ "$(_count "${WORK}/e.sh")" = "0" ] \
    && ok "MUST-MISS: a heredoc that writes ANOTHER script is out of scope" \
    || bad "MUST-MISS: heredoc content was scanned as install.sh's own code."

# ── NEGATIVE CONTROL, pinned to the tree whose walk actually aborted ──────
_CONTROL_SHA="7b2130ac"
echo "── negative control: ${_CONTROL_SHA} (the v1.0.65 cut that aborted at step 21) ──"
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
_c="$(_count "$_ctl")"
if [ "$_c" = "ERR" ]; then
    echo "CANNOT-RUN: the analyser failed on the control blob." >&2; exit 2
elif [ "$_c" -ge 1 ] 2>/dev/null; then
    ok "control ${_CONTROL_SHA}: ${_c} finding(s), reproducing the abort that killed walk 10"
else
    bad "control ${_CONTROL_SHA}: 0 findings. That tree DID abort on a real box at line 21445, so this harness is not measuring the defect."
fi

# ── THE SUBJECT ──────────────────────────────────────────────────────────
echo "── subject: this tree ──"
_s="$(_count "$SUBJECT")"
if [ "$_s" = "ERR" ]; then
    echo "CANNOT-RUN: the analyser failed on ${SUBJECT}." >&2; exit 2
elif [ "$_s" = "0" ]; then
    ok "no top-level call precedes its definition in install.sh"
else
    bad "${_s} top-level call(s) precede their definition. Every one aborts the install with rc=127 when reached:"
    python3 "$AN" "$SUBJECT" 2>/dev/null | sed -n '/CALL-BEFORE/,$p' | sed '1d;s/^/   /'
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
