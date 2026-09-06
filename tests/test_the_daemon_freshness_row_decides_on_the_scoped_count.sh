#!/usr/bin/env bash
# The daemon-freshness row must decide on the SCOPED count, not `ahead_by`.
# ============================================================================
# WHY THIS EXISTS. scripts/pre_tag_live_checks.sh computed how many changed
# files reach the built binary, and then went RED on ahead_by REGARDLESS. Its
# own comment said "decide on the scoped one". So ANY commit to ostler-assistant
# main -- a README, a CI workflow, a release script -- blocked the tag and
# demanded a re-pin, and a re-pin is a full sign-and-notarise cycle that
# produces a BYTE-IDENTICAL daemon. Measured on the v1.0.73 cut: ahead_by 3,
# files reaching the binary 0.
#
# Every arm stubs `gh` on PATH, so there is no network, no auth, and the
# compare payload is a fixture rather than whatever the remote holds today.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$HERE/scripts/pre_tag_live_checks.sh"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }
cant() { echo "  [CANNOT-RUN] $*" >&2; exit 2; }

[[ -f "$SUBJECT" ]] || cant "no subject at ${SUBJECT}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── build a throwaway repo holding ONLY what the row under test reads ────────
mk() {   # $1 = files the compare should report, one per line ("" = no file list)
    local files="$1" d="$WORK/r"; rm -rf "$d"
    mkdir -p "$d/scripts" "$d/cuts/v9.9.9" "$d/gui" "$d/bin"
    cp "$SUBJECT" "$d/scripts/"
    printf 'CUT_VERSION=9.9.9\nDAEMON_COMMIT=aaaaaaaa\n' > "$d/cuts/v9.9.9/cut.env"
    printf 'DAEMON_VERSION ?= 9.9.9\nDAEMON_REPO ?= ostler-ai/ostler-releases\n' > "$d/gui/Makefile"
    : > "$d/cut-deferrals.yaml"
    printf '%s\n' "$files" > "$d/FILES"
    cat > "$d/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Only the calls the daemon-freshness row makes are answered. Everything else
# exits non-zero so any OTHER row lands in its own CANNOT-RUN branch and cannot
# be mistaken for this row's verdict.
args="$*"
case "$args" in
  # The subject REFUSES to run unauthenticated, which is correct: every live
  # row would otherwise report a false absence. The stub must satisfy that
  # preflight or all rows vanish and every arm reads identically -- which is
  # exactly how this test failed 5/5 on its first run.
  "auth status"*)    exit 0 ;;
  *"commits/main"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *compare*"files[].filename"*) cat "${STUB_FILES}" ;;
  *compare*)         printf '{"ahead_by":3,"commits":[{"sha":"c1"},{"sha":"c2"},{"sha":"c3"}]}\n' ;;
  *)                 exit 1 ;;
esac
GHSTUB
    chmod +x "$d/bin/gh"
    echo "$d"
}

run() {   # $1 = repo dir -> ROW holds the daemon-freshness line
    local d="$1"
    ROW="$(cd "$d" && PATH="$d/bin:$PATH" STUB_FILES="$d/FILES" \
            bash scripts/pre_tag_live_checks.sh v9.9.9 2>&1 \
          | grep 'daemon pin vs oa/main' || true)"
}

# ── ARM 1: a changed file under crates/ REACHES the binary -> must be RED ────
d="$(mk 'crates/zeroclaw-runtime/src/lib.rs
.github/workflows/ci.yml')"; run "$d"
case "$ROW" in *RED*) ok "crates/** change is RED" ;;
               *)     bad "crates/** change did not go RED: ${ROW}" ;; esac

# ── ARM 2: only CI + release tooling -> must be GREEN (this is the defect) ───
d="$(mk '.github/workflows/ci.yml
release/test_cut_release_tag_can_actually_cut_a_tag.sh
scripts/release/cut_release_tag.sh')"; run "$d"
case "$ROW" in *GREEN*) ok "non-binary changes are GREEN despite ahead_by 3" ;;
               *)       bad "non-binary changes did not go GREEN: ${ROW}" ;; esac

# ── ARM 3: root Cargo.lock -> RED. The gate this row PREDICTS counts crates/**
#          alone and is blind to it; this row is deliberately wider. ──────────
d="$(mk 'Cargo.lock')"; run "$d"
case "$ROW" in *RED*) ok "root Cargo.lock is RED (wider than permanent-daemon-freshness)" ;;
               *)     bad "root Cargo.lock did not go RED: ${ROW}" ;; esac

# ── ARM 4: NO file list at all -> CANNOT-RUN, never GREEN. A zero here must
#          not read as "nothing reaches the binary". ─────────────────────────
d="$(mk '')"; run "$d"
case "$ROW" in *CANNOT-RUN*) ok "empty file list is CANNOT-RUN, not GREEN" ;;
               *)            bad "empty file list was not CANNOT-RUN: ${ROW}" ;; esac

# ── CONTROL: the arms must not all be answering the same way. If ARM 2 and
#    ARM 1 produced the same verdict the stub is not discriminating at all. ──
d="$(mk 'crates/x.rs')"; run "$d"; A="$ROW"
d="$(mk 'docs/x.md')";   run "$d"; B="$ROW"
if [ "$A" = "$B" ]; then bad "CONTROL: crates/ and docs/ produced the IDENTICAL row -- the stub is not discriminating"
else ok "CONTROL: crates/ and docs/ produce different verdicts"; fi

echo
echo "daemon-freshness row: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
