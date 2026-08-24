#!/usr/bin/env bash
# Prose in an unquoted heredoc must not be executed (#873)
# =======================================================
#
# THE INPUT THIS TEST REPLAYS
#
# Andy's v1.0.43 walk transcript carried, in front of the customer:
#
#     install.sh: line 9979: convert: command not found
#
# There is no ImageMagick in this product. Line 9979 of the v1.0.43
# install.sh is
#
#     cat > "${CONFIG_DIR}/.env" <<ENVEOF
#
# and 34 lines into that heredoc sat an explanatory COMMENT:
#
#     # So `convert --source apple_notes` exits non-zero on an unknown ...
#
# The delimiter is UNQUOTED, and an unquoted heredoc performs command
# substitution on its body as well as parameter expansion. So the backticks
# were not punctuation. They were a command, and bash ran it. It reports a
# failed substitution at the line of the enclosing command -- the `cat` --
# which is why the customer's error names 9979 and not the line of the prose.
#
# TWO SEPARATE HARMS, both measured:
#   1. Raw shell noise on a customer's screen for a binary the product has
#      never called.
#   2. The substitution's output REPLACED the backticked text, so the .env
#      written to the customer's disk read "# So  exits non-zero on an
#      unknown source". On a developer machine that HAS ImageMagick,
#      `convert` runs for real against the words in the sentence.
#
# WHY A GATE AND NOT JUST THE FIX
#
# The fix is four backslashes. It is re-armed by anyone who writes a
# backtick, or a $(...), anywhere in one of install.sh's 25 unquoted
# heredoc bodies -- and it re-arms SILENTLY, because the file still parses,
# still passes `bash -n`, and only misbehaves at run time on a customer's
# machine. Escaping cannot be left as folklore.
#
# WHAT THIS TEST ASSERTS
#
#   A  ORIGINAL FAILING INPUT. install.sh contains ZERO live command
#      substitutions inside unquoted heredoc bodies.
#   B  POSITIVE CONTROL, MUST BE PRESENT. A planted live substitution in a
#      COPY of install.sh is FOUND. Without this, A passes just as well
#      against a scanner that parses nothing, and "found none" would be
#      indistinguishable from "could not look".
#   C  NEGATIVE CONTROL -- escaped. A BACKSLASH-escaped backtick in an
#      unquoted body is inert and must NOT be reported. install.sh has three
#      of these today (they are correct); a gate that fires on them is a
#      gate someone deletes.
#   D  NEGATIVE CONTROL -- quoted delimiter. A live backtick inside
#      <<'EOF' is inert and must NOT be reported.
#   E  DENOMINATOR. The scanner must report a non-zero number of unquoted
#      heredocs in install.sh. A uniform zero everywhere means the parser
#      is broken, not that the file is clean.
#
# Synthetic fixtures only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

[ -f "$INSTALL_SH" ] || { printf 'FATAL: install.sh not found at %s\n' "$INSTALL_SH" >&2; exit 1; }

# CANNOT-RUN is not a pass. Say so and refuse.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'CANNOT-RUN: python3 is not on PATH, so the heredoc scanner never executed.\n' >&2
    printf 'This is NOT a pass: nothing was measured.\n' >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/heredoc-subst.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SCANNER="${WORK}/scan.py"
# The delimiter IS quoted. In a file about unquoted heredocs, that is not
# a joke -- this body is full of backticks and $( ).
cat > "$SCANNER" <<'SCANNER_EOF'
#!/usr/bin/env python3
"""Report command substitutions that are LIVE inside an unquoted heredoc.

Prints one line per finding, then a machine-readable summary line:
    SUMMARY heredocs=<n> unquoted=<n> findings=<n>
Exit 0 always -- the caller decides what the numbers mean.
"""
import re
import sys

# <<DELIM | <<-DELIM | <<'DELIM' | <<"DELIM" | <<\DELIM
# The three quoted forms make the body literal; the bare form does not.
OPEN_RE = re.compile(r"<<(-?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3")

def scan(path):
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    heredocs = unquoted = findings = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("#"):
            i += 1
            continue
        m = OPEN_RE.search(line)
        if not m:
            i += 1
            continue
        dash, backslash, quote, delim = m.groups()
        literal_body = bool(quote) or bool(backslash)
        heredocs += 1
        if not literal_body:
            unquoted += 1
        opened_at = i + 1
        j = i + 1
        while j < len(lines):
            term = lines[j].strip() if dash else lines[j]
            if term == delim:
                break
            if not literal_body:
                # A backslash-escaped backtick (or \$( ) is INERT. Strip
                # every escaped pair first, then look at what survives.
                live = re.sub(r"\\.", "", lines[j])
                if re.search(r"`[^`]+`", live) or re.search(r"\$\(", live):
                    findings += 1
                    print("%s:%d: LIVE command substitution in unquoted "
                          "heredoc <<%s (opened line %d): %s"
                          % (path, j + 1, delim, opened_at,
                             lines[j].strip()[:110]))
            j += 1
        i = j + 1
    print("SUMMARY heredocs=%d unquoted=%d findings=%d"
          % (heredocs, unquoted, findings))

for p in sys.argv[1:]:
    scan(p)
SCANNER_EOF

summary_field() {
    # summary_field <output-file> <key>
    grep '^SUMMARY ' "$1" | tail -n 1 | tr ' ' '\n' | grep "^$2=" | cut -d= -f2
}

# ── A: the original failing input, against the real file ───────────────
python3 "$SCANNER" "$INSTALL_SH" > "${WORK}/real.txt" 2>&1
A_FIND="$(summary_field "${WORK}/real.txt" findings)"
A_UNQ="$(summary_field "${WORK}/real.txt" unquoted)"
A_TOT="$(summary_field "${WORK}/real.txt" heredocs)"

# ── E: denominator first, so A's zero cannot be a broken parser ────────
if [ -z "$A_TOT" ] || [ "$A_TOT" -eq 0 ] || [ -z "$A_UNQ" ] || [ "$A_UNQ" -eq 0 ]; then
    fail "E denominator: the scanner found ${A_TOT:-<none>} heredocs and ${A_UNQ:-<none>} unquoted ones in install.sh. A zero here means the parser is broken, so assertion A below would be measuring nothing."
else
    pass "E denominator: ${A_TOT} heredocs in install.sh, ${A_UNQ} of them unquoted -- there is something to scan"
fi

if [ "${A_FIND:-1}" -eq 0 ]; then
    pass "A: no live command substitution in any unquoted heredoc body in install.sh"
else
    fail "A: ${A_FIND} live command substitution(s) inside unquoted heredoc bodies. Prose in an unquoted heredoc is EXECUTED and its output replaces the text (#873). Escape the backtick / \$( with a backslash:
$(grep 'LIVE command substitution' "${WORK}/real.txt" | sed 's/^/        /')"
fi

# ── B: positive control -- plant one and prove it is found ─────────────
#
# Planted into a COPY of the real file, inside the real ENVEOF body, so the
# control exercises the same parse path as the subject rather than a
# convenient miniature.
PLANTED="${WORK}/install_planted.sh"
cp "$INSTALL_SH" "$PLANTED"
python3 - "$PLANTED" <<'PLANT_EOF'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
for i, l in enumerate(lines):
    if 'cat > "${CONFIG_DIR}/.env" <<ENVEOF' in l:
        lines.insert(i + 1, "# planted by the positive control `id`")
        break
else:
    sys.exit("could not find the ENVEOF heredoc to plant into")
open(p, "w", encoding="utf-8").write("\n".join(lines))
PLANT_EOF

python3 "$SCANNER" "$PLANTED" > "${WORK}/planted.txt" 2>&1
B_FIND="$(summary_field "${WORK}/planted.txt" findings)"
if [ "${B_FIND:-0}" -ge 1 ]; then
    pass "B control: a planted live substitution in a copy of install.sh IS found (${B_FIND}), so A's zero is a measurement"
else
    fail "B control: the scanner did NOT find a live substitution planted into the real ENVEOF body. It is blind, and assertion A above proves nothing."
fi

# ── C: negative control -- an escaped backtick must be ignored ─────────
cat > "${WORK}/escaped.sh" <<'FIXTURE_EOF'
cat > /dev/null <<CFG
# see \`some-command --flag\` for the reason
value="${SOMETHING}"
CFG
FIXTURE_EOF
python3 "$SCANNER" "${WORK}/escaped.sh" > "${WORK}/escaped.txt" 2>&1
C_FIND="$(summary_field "${WORK}/escaped.txt" findings)"
C_UNQ="$(summary_field "${WORK}/escaped.txt" unquoted)"
if [ "${C_UNQ:-0}" -ge 1 ] && [ "${C_FIND:-1}" -eq 0 ]; then
    pass "C control: a BACKSLASH-escaped backtick in an unquoted body is correctly ignored"
else
    fail "C control: the scanner reported ${C_FIND:-<none>} finding(s) on an escaped backtick (unquoted heredocs seen: ${C_UNQ:-<none>}). It would fire on the three correct sites already in install.sh, and get switched off."
fi

# ── D: negative control -- a quoted delimiter must be ignored ──────────
cat > "${WORK}/quoted.sh" <<'FIXTURE_EOF'
cat > /dev/null <<'CFG'
# this `really is` inert because the delimiter is quoted
literal $(also inert)
CFG
FIXTURE_EOF
python3 "$SCANNER" "${WORK}/quoted.sh" > "${WORK}/quoted.txt" 2>&1
D_FIND="$(summary_field "${WORK}/quoted.txt" findings)"
D_TOT="$(summary_field "${WORK}/quoted.txt" heredocs)"
if [ "${D_TOT:-0}" -ge 1 ] && [ "${D_FIND:-1}" -eq 0 ]; then
    pass "D control: a live backtick inside a QUOTED heredoc is correctly ignored"
else
    fail "D control: the scanner reported ${D_FIND:-<none>} finding(s) inside a quoted heredoc (heredocs seen: ${D_TOT:-<none>}), where nothing can execute."
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'PASS: no prose is executed out of an unquoted heredoc in %s\n' "$INSTALL_SH"
    exit 0
fi
printf 'FAIL: %s assertion(s) failed against %s\n' "$FAILURES" "$INSTALL_SH"
exit 1
