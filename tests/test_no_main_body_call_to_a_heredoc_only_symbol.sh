#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# A MAIN-BODY CALL SITE MUST NOT REFERENCE A SYMBOL WHOSE ONLY
# DEFINITION LIVES INSIDE A HEREDOC.  (#568, #1207, #636)
#
# install.sh writes many standalone scripts out of SINGLE-QUOTED
# heredocs. Their contents are DATA to this shell -- never parsed, never
# executed here. A function or variable defined only in there does not
# exist in install.sh's own shell, so a main-body reference to it is:
#
#     a function  -> rc=127 `command not found`
#     a variable  -> unbound, and under this file's `set -Eeuo pipefail`
#                    that is a FATAL abort, not an empty string
#
# THIS HAS BITTEN THREE TIMES AND THE FILE ALREADY WARNS ABOUT IT TWICE
# IN PROSE:
#
#   #1207  a "de-duplicating" fix called install.sh's helper from inside
#          a quoted heredoc. Byte-identical to a working fix. Inert.
#   #636   the same shape, shipped, and the feature was dark.
#   #568   the INVERSE -- the main body called a helper that only the
#          heredoc defined. Every install died at duplicate-contact
#          merging, and the recovery agent 76 lines later never ran.
#
# The DCUEOF block says it in capitals. It bit anyway. Prose cannot
# enforce; this can.
#
# ⚠️ DIRECTION MATTERS. #1207 is heredoc-code calling a main-body symbol;
# that is guarded elsewhere. THIS gate is the other direction: main-body
# code calling a heredoc-only symbol. Do not merge the two -- they have
# different fixes (there, duplicate deliberately; here, define in the
# body before first use).
# ─────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass() { echo "ok: $*"; }

# ── the region scanner ───────────────────────────────────────────────
# Emits: REGION <delim> <open>..<close>
#
# 🔴 TWO TRAPS, BOTH WALKED INTO WHILE BUILDING THIS:
#   (a) `<<` inside a COMMENT is not a heredoc. An earlier version of
#       this scanner matched `# <<< SOME_MARKER` and reported EVERY line
#       as inside a heredoc -- a uniform answer, which is the signature
#       of a dead predicate rather than a finding.
#   (b) `<<<` is a HERESTRING, not a heredoc. Stripped before matching.
scan_regions() {
    /usr/bin/awk '
        { if (indoc) { s=$0; sub(/^[[:space:]]+/,"",s)
                       if (s == delim) { printf "REGION %s %d..%d\n", delim, opened, NR; indoc=0 }
                       next }
          line=$0; st=line; sub(/^[[:space:]]+/,"",st)
          if (substr(st,1,1)=="#") next
          tmp=line; gsub(/<<</,"",tmp)
          if (match(tmp, /<<-?[[:space:]]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/)) {
              d=substr(tmp,RSTART,RLENGTH)
              gsub(/^<<-?[[:space:]]*/,"",d); gsub(/[\x27"]/,"",d)
              indoc=1; delim=d; opened=NR } }
    ' "$1"
}

# in_heredoc <line> <regionfile> -> prints delim, or nothing for main body
in_heredoc() {
    /usr/bin/awk -v L="$1" '$1=="REGION"{ split($3,r,"\\.\\.")
        if (L > r[1] && L < r[2]) { print $2; exit } }' "$2"
}

analyse() {
    local file="$1" regions defs_h defs_m sym line reg refs verdict=0
    regions="$(mktemp)"; scan_regions "$file" > "$regions"

    [ "$(/usr/bin/grep -c '^REGION' "$regions")" -gt 0 ] \
        || cannot_run "no heredoc regions found in ${file} -- the scanner is broken, every verdict below would be vacuous"

    defs_h="$(mktemp)"; defs_m="$(mktemp)"
    # Function definitions and top-level variable assignments.
    /usr/bin/grep -nE '^[A-Za-z_][A-Za-z0-9_]*(\(\)[[:space:]]*\{|=)' "$file" \
    | while IFS=: read -r line rest; do
        sym="$(printf '%s' "$rest" | /usr/bin/sed -E 's/^([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
        case "$rest" in
            "${sym}"'()'*) kind=f ;;
            *)             kind=v ;;
        esac
        reg="$(in_heredoc "$line" "$regions")"
        if [ -n "$reg" ]; then printf '%s\t%s\t%s\t%s\n' "$sym" "$line" "$reg" "$kind" >> "$defs_h"
        else                   printf '%s\n' "$sym" >> "$defs_m"; fi
    done
    touch "$defs_h" "$defs_m"

    # A symbol is AT RISK if it is defined inside a heredoc and NEVER in
    # the main body. Definitions in BOTH places are the correct pattern
    # (#568's fix, and DCUEOF's deliberate duplicate) -- not a finding.
    while IFS="$(printf '\t')" read -r sym dline dreg kind; do
        [ -n "${sym:-}" ] || continue

        # ⛔ SCOPE BOUND, STATED RATHER THAN QUIETLY EXCLUDED: FUNCTIONS ONLY.
        #
        # The variable half was built, measured, and DROPPED as unsound. Two
        # reasons, both structural, neither fixable by tightening a regex:
        #
        #   1. Many heredocs write CONFIG FILES, not shell. `ENVEOF` emits a
        #      .env: USER_NAME=, OXIGRAPH_URL=, QDRANT_URL=. Those are data
        #      lines, not definitions, and the main body legitimately reads
        #      the same names FROM THE ENVIRONMENT. The gate flagged 6 of
        #      them on origin/main. Every one a false positive.
        #   2. Main-body variables arrive by many forms this scan cannot
        #      enumerate -- `: "${X:=...}"`, export, local, read, for-in, or
        #      simply inherited. "Not assigned at column 0" is not "undefined".
        #
        # A gate that cries wolf on six shipping config keys would be
        # switched off within a week, and then it would be guarding nothing.
        # Functions are the tractable half AND the half that actually bit:
        # #568, #1207 and #636 were all a FUNCTION that did not exist where
        # it was called.
        #
        # 🔴 SO THIS GATE DOES NOT COVER heredoc-only VARIABLES. #568's
        # OSTLER_PRIVATE_ARTEFACTS_DIR is exactly that class, and it is
        # caught here only because its sibling FUNCTION is. Do not read a
        # green from this file as "no heredoc-scope defects".
        [ "$kind" = "f" ] || continue

        /usr/bin/grep -qxF "$sym" "$defs_m" && continue

        # 🔴 COUNT USES, NOT MENTIONS. The first draft of this gate matched
        # the bare word anywhere on a line and reported `log` as called from
        # 100+ main-body sites -- every one of them the string "install.log"
        # inside a filename or a message. That is the same mention-vs-use
        # error this repo has a scar for, committed by the gate written to
        # catch a different one.
        #
        #   a FUNCTION is used only in COMMAND POSITION
        #   a VARIABLE is used only as $NAME / ${NAME}
        #
        # Anything else -- a filename, a log line, a word inside a string --
        # is a mention and must not raise a finding.
        if [ "$kind" = "f" ]; then
            use_re="(^|[;&|(]|&&|\|\||\\\$\()[[:space:]]*${sym}([[:space:]]|;|\)|&|$)"
        else
            use_re="\\\$\{?${sym}(\}|[^A-Za-z0-9_]|$)"
        fi
        refs="$(/usr/bin/grep -nE "$use_re" "$file" \
                | while IFS=: read -r rl _; do
                      st="$(/usr/bin/sed -n "${rl}p" "$file" | /usr/bin/sed -E 's/^[[:space:]]+//')"
                      [ "${st:0:1}" = "#" ] && continue
                      [ "$rl" = "$dline" ] && continue
                      # ⛔ EXEMPT: a call that CANNOT produce rc=127.
                      # `command -v foo && foo` is the defensive form -- if the
                      # symbol is absent the guard is false and the call never
                      # runs. install.sh uses it at :11173 for a function whose
                      # generated lib it SOURCES two lines earlier (:11172), so
                      # the symbol genuinely exists at runtime and no static
                      # scan of this file can see that. Flagging it would be a
                      # false positive on correct, careful code -- and a gate
                      # that cries wolf on the good pattern trains people to
                      # ignore it.
                      _w=$((rl - 4)); [ "$_w" -lt 1 ] && _w=1
                      /usr/bin/sed -n "${_w},${rl}p" "$file" \
                        | /usr/bin/grep -qE "(command -v|type -t|declare -F)[[:space:]]+${sym}" && continue
                      [ -z "$(in_heredoc "$rl" "$regions")" ] && printf '%s ' "$rl"
                  done)"
        if [ -n "${refs// /}" ]; then
            echo "FAIL: '${sym}' is defined ONLY inside heredoc ${dreg} (line ${dline})," >&2
            echo "      yet the MAIN BODY references it at: ${refs}" >&2
            echo "      That heredoc is written to a file; its contents never run in" >&2
            echo "      this shell. A function reference is rc=127; a variable" >&2
            echo "      reference is an unbound-variable ABORT under set -u." >&2
            echo "      FIX: define it in the main body before first use and KEEP" >&2
            echo "      the heredoc copy -- the generated script needs its own." >&2
            verdict=1
        fi
    done < "$defs_h"

    rm -f "$regions" "$defs_h" "$defs_m"
    return "$verdict"
}

# ── SELF-TEST: prove the gate can FAIL ───────────────────────────────
# A gate with no demonstrated red branch is decoration.
if [ "$SELF_TEST" = "1" ]; then
    tmp="$(mktemp)"
    cat > "$tmp" <<'FIXTURE'
#!/usr/bin/env bash
set -Eeuo pipefail
cat > /dev/null <<'GENERATED'
_zz_probe_only_here() { echo hi; }
ZZ_PROBE_VAR="value"
GENERATED
_zz_probe_only_here
echo "${ZZ_PROBE_VAR}"
FIXTURE
    if analyse "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "--self-test: the gate PASSED a fixture that defines two symbols only
      inside a quoted heredoc and calls both from the main body. It cannot
      detect the defect it exists for. CANNOT-RUN dressed as green."
    fi
    pass "self-test: the gate REJECTS a heredoc-only symbol called from the main body"

    # Negative half: the same fixture with the symbols ALSO defined in the
    # body must PASS -- otherwise the gate would forbid #568's own fix.
    cat > "$tmp" <<'FIXTURE'
#!/usr/bin/env bash
set -Eeuo pipefail
_zz_probe_only_here() { echo hi; }
ZZ_PROBE_VAR="value"
cat > /dev/null <<'GENERATED'
_zz_probe_only_here() { echo hi; }
ZZ_PROBE_VAR="value"
GENERATED
_zz_probe_only_here
echo "${ZZ_PROBE_VAR}"
FIXTURE
    if ! analyse "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "--self-test: the gate REJECTED the correct pattern -- symbol defined in
      BOTH the main body and the heredoc. That is exactly #568's fix and
      DCUEOF's deliberate duplicate. A gate that forbids the remedy is worse
      than no gate."
    fi
    pass "self-test: the gate ACCEPTS a symbol defined in both places (the remedy)"
    rm -f "$tmp"
    echo ""
    echo "heredoc-only-symbol gate: self-test 2/2"
    exit 0
fi

# ── the real run ─────────────────────────────────────────────────────
[ -f "$TARGET" ] || cannot_run "install.sh not found at ${TARGET}"
pass "control: target is ${TARGET} ($(wc -c < "$TARGET" | tr -d ' ') bytes)"

if analyse "$TARGET"; then
    echo ""
    echo "heredoc-only-symbol gate: PASS"
else
    echo "" >&2
    echo "heredoc-only-symbol gate: FAIL" >&2
    exit 1
fi
