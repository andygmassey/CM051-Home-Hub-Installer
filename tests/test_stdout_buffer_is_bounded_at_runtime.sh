#!/usr/bin/env bash
#
# THE STDOUT ACCUMULATOR MUST BE BOUNDED -- PROVEN BY RUNNING IT.
# ==============================================================
#
# WHY THIS EXISTS, AND WHY THE SOURCE-TEXT TEST BESIDE IT IS NOT ENOUGH.
#
# `test_stdout_buffer_is_bounded_without_newlines.sh` asserts that a named cap
# exists, is consulted at the growth site, and that the oversize path reassigns
# the buffer. ORM defeated all three at once with a decoy that a reviewer would
# wave through:
#
#     if stdoutBuffer.utf8.count > Self.stdoutBufferCapBytes,
#        !stdoutBuffer.contains("\n") {
#         if stdoutBuffer.isEmpty {                 // <-- never true
#             stdoutBuffer = ""
#         }
#     }
#
#     source-text test:  PASS=6 FAIL=0
#     actual buffer:     11,844,000 bytes and climbing
#
# Cap declared. Cap consulted. Buffer reassigned. Every predicate satisfied,
# defect fully intact. No amount of cleverness in a text predicate fixes that,
# because the property is about what the code DOES, and text is not behaviour.
#
# So this test runs it. It extracts the ingest body FROM THE SHIPPED FILE --
# not a copy, not a paraphrase -- compiles it against stubs, feeds it a
# carriage-return-only producer of the shape `docker pull` actually emits, and
# measures the buffer.
#
# THE DEFECT IT GUARDS. On the v1.0.42 upgrade walk, 2026-08-23, the installer
# held 4.27 GB after a SUCCESSFUL install. `stdoutBuffer` drains only on "\n";
# `docker pull` writes layer progress with "\r" and no newline, so during a
# multi-gigabyte pull the drain loop never executes once.
#
# 🔴 AND IT IS NOT A COSMETIC LEAK. On the walk box that retention drove macOS
# into memory pressure; five JetsamEvent reports landed on 2026-08-23 between
# 16:13:35 and 17:33:51, jetsam killed the 4 GB Colima VM, and the wiki and
# store went dark for about a day. This buffer is the first link in that chain.
#
# ── WHAT MAKES THIS TEST HONEST ───────────────────────────────────────────
#
# A runtime test can lie in a way a text test cannot: it can pass because the
# harness never reproduced the condition. So the ANTI-VACUITY LIMB IS THE
# POINT -- the same harness is built from origin/main's version of the same
# function and MUST come out unbounded. If the control does not blow up, the
# producer is not producing and the green above it means nothing.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_REL="gui/OstlerInstaller/InstallerCoordinator.swift"
SRC="${REPO_ROOT}/${SRC_REL}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

# Bytes to feed, with NO newline anywhere. Large enough that an unbounded
# buffer is unmistakable, small enough to run in CI in a second.
FEED_MB=4

echo
echo "== the stdout accumulator must be bounded AT RUNTIME, not in source text =="
echo

# ── 0. CANNOT-RUN FIRST, AND LOUDLY ───────────────────────────────────────
if [[ ! -r "$SRC" ]]; then
    echo "CANNOT-RUN: ${SRC} is not readable." >&2
    echo "  Nothing was measured. This is NOT a pass -- exit 2." >&2
    exit 2
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "CANNOT-RUN: swiftc is not on PATH." >&2
    echo "  A runtime test that cannot compile has measured NOTHING." >&2
    echo "  This is NOT a pass -- exit 2. Wire this on a macOS runner." >&2
    exit 2
fi
ok "CANNOT-RUN check: source readable and swiftc present"

# ── EXTRACT THE SHIPPED BODY ──────────────────────────────────────────────
# From `stdoutBuffer.append(chunk)` to the close of the newline-drain loop.
# Taking it from the file is what makes this a test OF THE PRODUCT rather
# than a test of a snippet somebody kept in sync by hand.
extract_body() {  # $1 = swift source path
    awk '
        /stdoutBuffer\.append\(chunk\)/ { grab=1 }
        grab && /^    \}$/              { exit }
        grab                            { print }
    ' "$1"
}

# The cap constant, if the tree has one. main does not, and its body does not
# reference it, so its absence there is correct rather than a failure.
extract_cap() { grep -E 'static let stdoutBufferCapBytes' "$1" || true; }

build_harness() {  # $1 = swift source path, $2 = output dir
    local src="$1" out="$2"
    mkdir -p "$out"
    local body cap
    body="$(extract_body "$src")"
    cap="$(extract_cap "$src")"
    [[ -n "$body" ]] || return 1
    {
        echo 'import Foundation'
        echo 'enum StubEvent { case noop }'
        echo 'enum ProgressDecoder { static func decode(line: String) -> StubEvent { .noop } }'
        echo 'final class Harness {'
        echo '    var stdoutBuffer = ""'
        echo '    var linesOut = 0'
        echo '    var peak = 0'
        [[ -n "$cap" ]] && echo "    ${cap}"
        echo '    func apply(event: StubEvent, fromStderr: Bool) { linesOut += 1 }'
        echo '    func ingest(chunk: String, fromStderr: Bool) {'
        echo "$body"
        echo '        peak = max(peak, stdoutBuffer.utf8.count)'
        echo '    }'
        echo '}'
        echo 'let h = Harness()'
        echo "let mb = ${FEED_MB}"
        # A \r-delimited producer of the shape `docker pull` emits. NOT ONE \n.
        #
        # ⚠️ CHUNK SIZE IS A TEST-DESIGN CONSTRAINT, NOT A DETAIL. The unfixed
        # drain loop calls firstIndex(of: "\n") over the WHOLE accumulator on
        # every chunk, and never finds one -- so the control is QUADRATIC in
        # chunk count. Swift Strings compare by grapheme cluster, which makes
        # that scan far slower than the byte count suggests: 1 KB chunks over
        # 2 MB did not finish in four minutes. Feeding the same bytes as ~32 KB
        # chunks cuts the number of full scans ~30x and the control lands in
        # seconds. The defect being measured is TOTAL RETENTION, which is
        # independent of how the bytes are diced.
        #
        # (That quadratic is itself a real property of the unfixed code and is
        # very likely why the installer appeared hung rather than merely fat.)
        echo 'let line = "a1b2c3d4: Downloading [====>      ]  128MB/512MB\r"'
        echo 'let unit = String(repeating: line, count: max(1, 32_768 / line.utf8.count))'
        echo 'let chunks = max(1, mb * (1_048_576 / unit.utf8.count))'
        echo 'for _ in 0..<chunks { h.ingest(chunk: unit, fromStderr: false) }'
        echo 'let fed = chunks * unit.utf8.count'
        echo 'print("fed=\(fed) peak=\(h.peak) final=\(h.stdoutBuffer.utf8.count) lines=\(h.linesOut) chunks=\(chunks)")'
    } > "${out}/main.swift"
    ( cd "$out" && swiftc -O -o harness main.swift ) >"${out}/build.log" 2>&1
}

# ── 1. THE CONTROL, BUILT FIRST AND IT MUST BLOW UP ───────────────────────
# Without this the green below could mean "bounded" or "never reproduced".
# origin/main is the tree that produced 4.27 GB on real hardware.
if ! git -C "$REPO_ROOT" show "origin/main:${SRC_REL}" > "${WORK}/main_src.swift" 2>/dev/null; then
    bad "CANNOT-RUN: could not read origin/main:${SRC_REL}" \
        "without the unfixed tree there is no proof the producer reproduces the defect"
else
    if build_harness "${WORK}/main_src.swift" "${WORK}/ctrl"; then
        CTRL_OUT="$("${WORK}/ctrl/harness")"
        CTRL_FED="$(sed -n 's/.*fed=\([0-9]*\).*/\1/p'   <<< "$CTRL_OUT")"
        CTRL_FIN="$(sed -n 's/.*final=\([0-9]*\).*/\1/p' <<< "$CTRL_OUT")"
        echo "        control (origin/main): ${CTRL_OUT}"
        # Unbounded means it retains essentially everything it was fed.
        if [[ -n "$CTRL_FIN" && -n "$CTRL_FED" && "$CTRL_FIN" -ge $(( CTRL_FED / 2 )) ]]; then
            ok "CONTROL: origin/main retains ${CTRL_FIN} of ${CTRL_FED} bytes -- the producer reproduces the defect"
        else
            bad "CONTROL FAILED: origin/main retained only ${CTRL_FIN:-?} of ${CTRL_FED:-?} bytes" \
                "the \\r-only producer is not reproducing the leak, so a pass below would be vacuous"
        fi
    else
        bad "CONTROL FAILED: could not build the origin/main harness" \
            "$(tail -3 "${WORK}/ctrl/build.log" 2>/dev/null)"
    fi
fi

# ── 2. THE TREE UNDER TEST MUST STAY BOUNDED ──────────────────────────────
if build_harness "$SRC" "${WORK}/head"; then
    ok "the shipped ingest body compiles in isolation (tested text IS shipped text)"
    HEAD_OUT="$("${WORK}/head/harness")"
    HEAD_FED="$(sed -n 's/.*fed=\([0-9]*\).*/\1/p'   <<< "$HEAD_OUT")"
    HEAD_PEAK="$(sed -n 's/.*peak=\([0-9]*\).*/\1/p' <<< "$HEAD_OUT")"
    HEAD_FIN="$(sed -n 's/.*final=\([0-9]*\).*/\1/p' <<< "$HEAD_OUT")"
    echo "        head: ${HEAD_OUT}"

    # The declared ceiling, read from the source rather than repeated here --
    # a hard-coded number would drift the day someone retunes the cap.
    CAP="$(sed -n 's/.*stdoutBufferCapBytes *= *\([0-9]* \* [0-9]*\).*/\1/p' "$SRC")"
    CAP_BYTES=$(( ${CAP:-0} ))
    [[ "$CAP_BYTES" -gt 0 ]] || CAP_BYTES=$((64 * 1024))
    # Allow generous headroom: the guard fires AFTER an append, so the peak can
    # legitimately exceed the cap by one chunk. Anything within a small
    # multiple is bounded; unbounded growth is orders of magnitude away.
    LIMIT=$(( CAP_BYTES * 4 ))

    if [[ -n "$HEAD_PEAK" && "$HEAD_PEAK" -le "$LIMIT" ]]; then
        ok "PEAK bounded: ${HEAD_PEAK} bytes <= ${LIMIT} after feeding ${HEAD_FED}"
    else
        bad "PEAK UNBOUNDED: ${HEAD_PEAK:-?} bytes after feeding ${HEAD_FED:-?}" \
            "a \\r-only producer must not grow the accumulator past ~${LIMIT} bytes"
    fi
    if [[ -n "$HEAD_FIN" && "$HEAD_FIN" -le "$LIMIT" ]]; then
        ok "FINAL bounded: ${HEAD_FIN} bytes retained after the stream ends"
    else
        bad "FINAL UNBOUNDED: ${HEAD_FIN:-?} bytes still retained after the stream ends" \
            "this is the 4.27 GB defect -- retention AFTER completion, not a transient spike"
    fi
else
    bad "could not build the harness from ${SRC_REL}" \
        "$(tail -5 "${WORK}/head/build.log" 2>/dev/null)"
fi

# ── 3. THE NEWLINE PATH MUST STILL WORK ───────────────────────────────────
# A cap that became the only drain would bound the buffer by mangling every
# ordinary line -- green on both assertions above, product broken. Feed a
# newline-terminated stream to the SAME harness and require lines come out.
if [[ -x "${WORK}/head/harness" ]]; then
    # Same generated harness, one line swapped: the producer now terminates
    # every record with \n instead of \r. Rewriting rather than regenerating
    # keeps the ingest body byte-identical to the one measured above, so any
    # difference in outcome is attributable to the input and nothing else.
    awk '
        /^let line = / { print "let line = \"STEP_BEGIN id=x\\n\""; next }
        { print }
    ' "${WORK}/head/main.swift" > "${WORK}/head/nl_main.swift"
    if ( cd "${WORK}/head" && swiftc -O -o harness_nl nl_main.swift ) >/dev/null 2>&1; then
        NL_OUT="$("${WORK}/head/harness_nl")"
        NL_LINES="$(sed -n 's/.*lines=\([0-9]*\).*/\1/p' <<< "$NL_OUT")"
        echo "        newline path: ${NL_OUT}"
        if [[ -n "$NL_LINES" && "$NL_LINES" -gt 1000 ]]; then
            ok "the newline drain still emits lines (${NL_LINES}) -- the cap supplements, not replaces"
        else
            bad "the newline drain emitted only ${NL_LINES:-0} lines" \
                "bounding the buffer by breaking ordinary line parsing is not a fix"
        fi
    else
        bad "could not build the newline-path harness" "assertion 3 measured nothing"
    fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
