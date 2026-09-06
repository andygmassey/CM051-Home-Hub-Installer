#!/usr/bin/env bash
# A URL with a query string, sent unquoted over ssh, is GLOBBED by the remote
# shell and never runs.
#
# MEASURED 2026-09-07, and it had been broken the whole time. scripts/ttywalk.sh
# dumped the graph before --wipe-stores with:
#
#     curl ... http://127.0.0.1:7878/store?default > "$_dump"
#
# The walk box login shell is zsh. Unquoted, zsh treats the question mark as a
# single-character glob, finds no matching file, and ABORTS THE COMMAND:
#
#     zsh:23: no matches found: http://127.0.0.1:7878/store?default
#
# curl therefore never ran, the dump was empty, and the guard downstream said
# "CANNOT-WIPE: the graph did not dump". That message is correct and it is also
# a trap: it points at Oxigraph, and the defect is in the shell. --wipe-stores
# had NEVER succeeded against this box.
#
# bash does not glob a bare question mark this way, so the same line works when
# tested locally and fails over ssh. THE REMOTE SHELL IS NOT YOURS TO CHOOSE,
# which is why this is a lint and not a runtime check.
#
# WHAT IT CHECKS, AND WHY SINGLE QUOTES ARE NOT ENOUGH.
#
# In the harness scripts that talk to a box, every http(s) URL containing a `?`
# must be wrapped in DOUBLE quotes.
#
# That is stricter than "quoted", and the extra strictness is the whole point.
# These remote blocks are passed as ONE SINGLE-QUOTED bash string to ssh. A
# single quote inside such a string CLOSES it, so the shell concatenates the
# pieces and the quotes are stripped before ssh transmits anything -- the remote
# receives a bare URL and globs it exactly as before. Measured:
#
#   nested single quotes  ->  curl http://...:7878/store?default   (stripped)
#   nested double quotes  ->  curl "http://...:7878/store?default" (survives)
#
# The first fix for this defect used single quotes. It looked right in the
# source, passed the first version of THIS lint, and changed nothing about what
# was transmitted; the walk failed identically, at the same site, with the line
# number shifted only by the comment I had added. A lint over source text cannot
# see quote-stripping by an enclosing quote layer, so the rule has to forbid the
# form that does not survive rather than accept anything that merely looks
# quoted.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECTS=(
    "scripts/ttywalk.sh"
    "scripts/post_walk_qa.sh"
    "bin/rollforward_gate.sh"
)

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

# An UNQUOTED url-with-query: a http(s) URL containing ? whose character
# immediately before the scheme is neither a single nor a double quote.
# A query URL that will NOT survive transmission: anything whose scheme is not
# immediately preceded by a DOUBLE quote. That flags both the bare form and the
# single-quoted form, which is the one that fooled the first version of this gate.
unquoted_query_urls() {
    /usr/bin/grep -nE "(^|[^\"])https?://[^ \"']*\?" "$1" 2>/dev/null || true
}

echo "== a remote URL with a query string is quoted against zsh globbing =="

examined=0
for rel in "${SUBJECTS[@]}"; do
    f="${REPO}/${rel}"
    if [ ! -r "$f" ]; then
        cant "${rel} is not readable -- NOT a pass, the file list is stale"
        continue
    fi
    examined=$((examined+1))
    hits="$(unquoted_query_urls "$f")"
    if [ -n "$hits" ]; then
        bad "${rel} has an UNQUOTED URL with a query string; zsh will glob the ? and the command will never run:"
        printf '           %s\n' "$hits"
    else
        ok "${rel}: no unquoted query-string URL"
    fi
done

if [ "$examined" -eq 0 ]; then
    cant "ZERO subject files examined. A clean sweep over nothing is not a pass."
fi

# ── CONTROL THAT MUST FIRE ────────────────────────────────────────────────
# Without this, a detector that silently matched nothing would report a clean
# tree and look identical to a correct one.
CTRL="$(mktemp)"; trap 'rm -f "$CTRL"' EXIT
printf 'curl -fsS http://127.0.0.1:7878/store?default > out\n' > "$CTRL"
if [ -n "$(unquoted_query_urls "$CTRL")" ]; then
    ok "CONTROL: the detector DOES flag a bare unquoted query-string URL"
else
    bad "CONTROL FAILED: the detector cannot see an unquoted query-string URL, so every PASS above is meaningless"
fi

# ── CONTROL THAT MUST NOT FIRE ────────────────────────────────────────────
# A quoted URL is the fix, so it must read clean -- otherwise the gate would
# demand a change that does not help.
printf 'curl -fsS "http://127.0.0.1:7878/store?default" > out\n' > "$CTRL"
if [ -z "$(unquoted_query_urls "$CTRL")" ]; then
    ok "CONTROL: a DOUBLE-quoted URL reads clean, so this gate does not reject its own fix"
else
    bad "CONTROL FAILED: a double-quoted URL is still flagged, so this gate would reject its own fix"
fi

# ── CONTROL: THE FORM THAT FOOLED THE FIRST VERSION OF THIS GATE ──────────
# A SINGLE-quoted URL must be flagged, because nested inside the single-quoted
# ssh block its quotes are stripped and the remote globs it anyway.
printf "curl -fsS 'http://127.0.0.1:7878/store?default' > out\n" > "$CTRL"
if [ -n "$(unquoted_query_urls "$CTRL")" ]; then
    ok "CONTROL: a SINGLE-quoted URL is flagged -- it does not survive nesting inside a single-quoted ssh block"
else
    bad "CONTROL FAILED: a single-quoted URL reads clean, which is exactly the hole that let the first fix ship broken"
fi

echo
printf '== %d pass / %d fail / %d cannot-run, %d file(s) examined ==\n' \
    "$PASS" "$FAIL" "$CANT" "$examined"
[ "$CANT" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
