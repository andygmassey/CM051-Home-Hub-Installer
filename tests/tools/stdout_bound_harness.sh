#!/usr/bin/env bash
#
# stdout_bound_harness.sh -- DRIVE the shipped stdout accumulator with a real
# \r-only producer and REPORT what the buffer actually does.
#
#   This is a TOOL, not a test. It prints measurements and exits 0 whatever it
#   finds. Deliberately: the assertions belong in the test that adopts it, and
#   a tool that also judges gets adopted for its verdict and then trusted for
#   its measurement.
#
#   It is not named test_*.sh, so it trips no wiring gate by existing. If you
#   wire it, wire the caller.
#
# ============================================================================
# WHY A RUNTIME HARNESS AT ALL
# ============================================================================
#
# The v1.0.42 walk found the Installer holding 4.27 GB AFTER a successful
# install. `docker pull` writes layer progress with CARRIAGE RETURNS and no
# newline; the drain loop is newline-only; so for the length of a multi-GB pull
# the loop never runs once and every byte is retained.
#
# The fix is right. The first test written for it was SOURCE-TEXT ONLY -- it
# asserted that a cap is declared, that it is consulted, and that the buffer is
# reassigned. A decoy satisfying all three was built in twenty minutes:
#
#     test says   PASS=6 FAIL=0
#     buffer at   11,844,000 bytes and climbing
#
# No source-text predicate can hold this line, because the property is "the
# number stops going up", and that is a fact about execution.
#
# ============================================================================
# THE BLOCK IS EXTRACTED, NEVER RETYPED, AND NEVER BY LINE NUMBER
# ============================================================================
#
# The reviewer's first version of this pulled lines 1490-1538 out of the Swift
# file. That works exactly until someone adds a line above it, and then it
# compiles a neighbouring function and reports on code nobody asked about --
# a green with no relationship to the shipped behaviour.
#
# So the accumulator is found by its CODE and bounded by BRACE MATCHING: from
# `stdoutBuffer.append(chunk)` through the closing brace of the drain loop,
# whatever sits between them. It is deliberately NOT the whole enclosing
# function -- handleIncoming() also does watchdog bookkeeping against half the
# class, and stubbing all of that would put more of this file's behaviour in
# the harness than in the thing being measured.
#
# If either anchor is missing, this exits 2 CANNOT-RUN rather than measuring
# something else and calling it clean. Writing this the naive way cost a real
# false CANNOT-RUN: the first draft searched for `func ingest(chunk:`, which is
# what the reviewer had NAMED the extracted block, not what the file calls it.
# The shipped function is handleIncoming(data:fromStderr:).
#
# EXIT  0 measured (see stdout)   2 CANNOT-RUN (no swiftc, no file, no func)
set -uo pipefail

SWIFT_FILE="${1:-}"
if [ -z "$SWIFT_FILE" ]; then
    HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
    SWIFT_FILE="${HERE}/../../gui/OstlerInstaller/InstallerCoordinator.swift"
fi

command -v swiftc >/dev/null 2>&1 || {
    echo "stdout-bound-harness: CANNOT-RUN -- no swiftc on this runner." >&2
    echo "  This needs a macOS runner. On ubuntu it is CANNOT-RUN, never a pass." >&2
    exit 2
}
[ -f "$SWIFT_FILE" ] || {
    echo "stdout-bound-harness: CANNOT-RUN -- no such file: $SWIFT_FILE" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- extract func ingest(chunk:...) by brace matching ----------------------
SWIFT_FILE="$SWIFT_FILE" python3 - "$TMP/body.swift" <<'PYEOF'
import io, os, sys
src = io.open(os.environ["SWIFT_FILE"], encoding="utf-8").read()

start = src.find("stdoutBuffer.append(chunk)")
if start < 0:
    sys.stderr.write("CANNOT-RUN: no 'stdoutBuffer.append(chunk)' in the file\n"); sys.exit(2)
# back up to the start of that line so indentation survives
start = src.rfind("\n", 0, start) + 1

w = src.find("while let", start)
if w < 0 or "stdoutBuffer.firstIndex" not in src[w:w+120]:
    sys.stderr.write("CANNOT-RUN: no drain loop after the append\n"); sys.exit(2)
j = src.find("{", w)
depth, k = 0, j
while k < len(src):
    if src[k] == "{": depth += 1
    elif src[k] == "}":
        depth -= 1
        if depth == 0: break
    k += 1
if depth != 0:
    sys.stderr.write("CANNOT-RUN: braces never balanced\n"); sys.exit(2)

body = src[start:k+1]
# Both anchors must survive into the extract, or the match found something else.
for must in ("stdoutBuffer.append(chunk)", "firstIndex(of:"):
    if must not in body:
        sys.stderr.write("CANNOT-RUN: extract lost %s -- wrong block\n" % must); sys.exit(2)
io.open(sys.argv[1], "w", encoding="utf-8").write(body)
sys.stderr.write("extracted %d bytes, %d lines, from offset %d\n"
                 % (len(body), body.count("\n") + 1, start))
PYEOF
rc=$?; [ "$rc" -eq 0 ] || exit 2

# --- build a program around it ---------------------------------------------
# MUTATE=1 strips the cap block, producing the pre-fix behaviour. That is the
# negative control: without it, a harness that measures nothing at all reports
# a small number and reads as a pass.
build() {
    out="$1"; mutate="$2"
    body="$TMP/body.swift"
    if [ "$mutate" = "1" ]; then
        MUT_IN="$TMP/body.swift" python3 - "$TMP/body_mut.swift" <<'PYEOF'
import io, os, re, sys
b = io.open(os.environ["MUT_IN"], encoding="utf-8").read()
# Remove the whole `if stdoutBuffer.utf8.count > ... { ... }` cap statement by
# brace matching from its `if`, so the mutant differs by the FIX and nothing else.
m = re.search(r"[ \t]*if stdoutBuffer\.utf8\.count", b)
if not m:
    sys.stderr.write("MUTANT CANNOT-RUN: no cap statement to remove\n"); sys.exit(2)
j = b.find("{", m.start()); depth, k = 0, j
while k < len(b):
    if b[k] == "{": depth += 1
    elif b[k] == "}":
        depth -= 1
        if depth == 0: break
    k += 1
out = b[:m.start()] + b[k+1:]
sys.stderr.write("mutant removed %d bytes\n" % (len(b) - len(out)))
io.open(sys.argv[1], "w", encoding="utf-8").write(out)
PYEOF
        [ $? -eq 0 ] || return 2
        body="$TMP/body_mut.swift"
    fi
    {
        printf 'import Foundation\n'
        printf 'struct InstallerEvent { let line: String }\n'
        printf 'enum ProgressDecoder { static func decode(line: String) -> InstallerEvent { InstallerEvent(line: line) } }\n'
        printf 'final class Harness {\n'
        printf '    var stdoutBuffer = ""\n'
        printf '    var linesEmitted = 0\n'
        printf '    var peakBytes = 0\n'
        printf '    static let stdoutBufferCapBytes = 64 * 1024\n'
        printf '    func apply(event: InstallerEvent, fromStderr: Bool) { linesEmitted += 1 }\n'
        printf '    func ingest(chunk: String, fromStderr: Bool) {\n'
        cat "$body"
        printf '\n    }\n'
        printf '    func note() { peakBytes = max(peakBytes, stdoutBuffer.utf8.count) }\n'
        printf '}\n'
        printf 'let h = Harness()\n'
        printf 'let CHUNKS = 400\n'
        printf 'var progress = ""\n'
        printf 'for i in 0..<2048 { progress += "layer \\(i) 1234567890abcdef 45%%\\r" }\n'
        printf 'for _ in 0..<CHUNKS { h.ingest(chunk: progress, fromStderr: false); h.note() }\n'
        printf 'print("fed_bytes=\\(CHUNKS * progress.utf8.count)")\n'
        printf 'print("peak_buffer_bytes=\\(h.peakBytes)")\n'
        printf 'print("final_buffer_bytes=\\(h.stdoutBuffer.utf8.count)")\n'
        printf 'print("lines_emitted=\\(h.linesEmitted)")\n'
    } > "$out.swift"
    swiftc -O -o "$out" "$out.swift" 2>"$TMP/swiftc.err" || {
        echo "stdout-bound-harness: CANNOT-RUN -- swiftc failed:" >&2
        head -20 "$TMP/swiftc.err" >&2
        return 2
    }
    return 0
}

echo "== SHIPPED =="
build "$TMP/shipped" 0 || exit 2
"$TMP/shipped"

echo
echo "== MUTANT (cap block removed) -- the negative control =="
if build "$TMP/mutant" 1; then
    "$TMP/mutant"
else
    echo "  mutant could not be built -- no cap block present in this tree." >&2
    echo "  That is itself the answer: there is nothing bounding the buffer." >&2
fi

echo
echo "Read it this way: a bound exists only if SHIPPED peak stays far below"
echo "fed_bytes WHILE the mutant's peak tracks fed_bytes. One number alone"
echo "proves nothing -- a harness that feeds nothing also reports a small peak."
