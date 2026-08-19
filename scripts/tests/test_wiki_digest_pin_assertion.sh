#!/usr/bin/env bash
#
# scripts/tests/test_wiki_digest_pin_assertion.sh
#
# PROVES the two standing wiki-image rows in cut-manifests/permanent.yaml
# (perm-wiki-site-pinned-by-digest, perm-wiki-compiler-pinned-by-digest) can
# actually go red, and that each one is blind to the other's mutations.
#
# WHY
# ---
# Those rows exist because the wiki image pin had NO standing assertion. It was
# covered by nine consecutive per-cut manifests (v1.0.16 .. v1.0.24) and by
# nothing since; verify_cut_manifest.py reads permanent.yaml plus ONE per-cut
# file, so v1.0.25 and v1.0.26 shipped with nothing asserting that install.sh
# carries a usable wiki image reference at all.
#
# A replacement gate with no evidence it can fail is the same non-instrument
# wearing a newer date. So the controls below mutate install.sh along the axis
# the verifier actually reads -- a regex over the file -- and run the REAL
# verifier, not a re-implementation of its predicate:
#
#   1  unmodified                        both PASS   (not vacuous)
#   2  site moved to the wrong namespace  site FAIL
#   3  site digest degraded to :latest    site FAIL
#   4  compiler digest truncated          compiler FAIL
#   5  compiler pin deleted entirely      compiler FAIL
#
# Controls 2 and 3 are the ones that matter in practice. A pin in the wrong
# namespace is exactly the mistake permanent.yaml's own note invited for
# months by naming ghcr.io/ostler-ai, a namespace install.sh has never used.
# A pin degraded from a digest to `:latest` still pulls, still looks fine in a
# diff, and quietly removes the reproducibility the pin exists to give.
#
# Each control also asserts the OTHER row stays PASS. The pair are asserted
# separately precisely so one can move without the other, and a control that
# failed both would not prove that.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/verify_cut_manifest.py"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || {
    echo "test_wiki_digest_pin_assertion: CANNOT RUN -- python3 unavailable." >&2
    echo "                                Nothing was exercised. This is not a pass." >&2
    exit 2
}
[ -f "$VERIFIER" ] || {
    echo "test_wiki_digest_pin_assertion: CANNOT RUN -- verifier missing at $VERIFIER" >&2
    exit 2
}

# Pick the newest per-cut manifest by version order rather than naming one.
# A hard-coded version would silently stop covering the current cut.
NEWEST="$(ls "$REPO_ROOT"/cut-manifests/v*.yaml 2>/dev/null \
          | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//' | sort -V | tail -1)"
[ -n "${NEWEST:-}" ] || {
    echo "test_wiki_digest_pin_assertion: CANNOT RUN -- no cut-manifests/v*.yaml found." >&2
    exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cm051" "$WORK/manifests"
cp "$REPO_ROOT/cut-manifests/permanent.yaml" "$WORK/manifests/"
cp "$REPO_ROOT/cut-manifests/${NEWEST}.yaml" "$WORK/manifests/"

cat > "$WORK/rows.py" <<'PYEOF'
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("PARSE_ERROR"); sys.exit()
rows = {r["id"]: r["status"] for r in d.get("results", []) if "pinned-by-digest" in r.get("id", "")}
if len(rows) != 2:
    # Neither row present means the mutation was never judged. Say so rather
    # than letting an absent row read as a passing one.
    print("MISSING_ROWS:%d" % len(rows)); sys.exit()
print("%s %s" % (rows.get("perm-wiki-site-pinned-by-digest", "?"),
                 rows.get("perm-wiki-compiler-pinned-by-digest", "?")))
PYEOF

verdict() {
    python3 "$VERIFIER" --version "$NEWEST" --cm051-dir "$WORK/cm051" \
        --manifest-dir "$WORK/manifests" --skip-source-at-sha --json 2>/dev/null \
        | python3 "$WORK/rows.py"
}

# $1 label, $2 expected "SITE COMPILER"
check() {
    local label="$1" want="$2" got
    got="$(verdict)"
    if [ "$got" = "$want" ]; then
        pass "$label -> $got"
    else
        fail "$label -> got '$got', expected '$want'"
    fi
}

echo "wiki digest pin: can the standing assertion go red? (manifest $NEWEST)"

cp "$REPO_ROOT/install.sh" "$WORK/cm051/install.sh"
check "control 1: unmodified tree" "PASS PASS"

sed 's#creativemachines-ai/ostler-wiki-site@#ostler-ai/ostler-wiki-site@#' \
    "$REPO_ROOT/install.sh" > "$WORK/cm051/install.sh"
check "control 2: site pin moved to the wrong namespace" "FAIL PASS"

sed -E 's#(ostler-wiki-site)@sha256:[0-9a-f]{64}#\1:latest#' \
    "$REPO_ROOT/install.sh" > "$WORK/cm051/install.sh"
check "control 3: site pin degraded from digest to :latest" "FAIL PASS"

sed -E 's#(ostler-wiki-compiler@sha256:[0-9a-f]{20})[0-9a-f]{44}#\1#' \
    "$REPO_ROOT/install.sh" > "$WORK/cm051/install.sh"
check "control 4: compiler digest truncated" "PASS FAIL"

grep -v 'ostler-wiki-compiler@sha256' "$REPO_ROOT/install.sh" > "$WORK/cm051/install.sh"
check "control 5: compiler pin deleted entirely" "PASS FAIL"

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mwiki digest pin: %d control(s) FAILED\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mwiki digest pin: 5/5 -- both rows fail on their own defect and ignore the other\033[0m\n'
