#!/usr/bin/env bash
#
# test_cut_freshness_hotfix_mode.sh
#
# Hotfix mode of scripts/verify_cut_freshness.sh and of the
# pinned_artefact_freshness proof in scripts/verify_cut_manifest.py
# (Archie, 2026-10-26, v1.0.118).
#
# A hotfix cut (cuts/<v>/cut.env CUT_KIND=hotfix, HOTFIX_BASE_TAG=<tag>) must
# carry its base tag's inputs BYTE FOR BYTE. Both gates CHECK that against the
# base tag in git rather than accepting a hold_ack, whose
# shipping_bugfixes_grafted=true would be a false statement for a hotfix.
#
# Arms:
#   1. hotfix, nothing changed            -> exit 0, FROZEN, gh never called
#   2. hotfix, one vendored byte changed  -> exit 1, the tree is NAMED
#   3. hotfix, a new untracked vendor file-> exit 1
#   4. hotfix, daemon pin moved           -> exit 1
#   5. hotfix, no HOTFIX_BASE_TAG         -> exit 1
#   6. NOT a hotfix                       -> the live-HEAD path runs (no FROZEN
#      row, gh IS called); with gh unreachable that is exit 3, never a pass.
#      The normal path's hold_ack rules are proven by test_cut_freshness_gate.sh.
#   7-9. manifest gate: hotfix pin == base PASS, moved FAIL, no base FAIL.
#
# British English; " -- " not em-dashes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

for f in scripts/verify_cut_freshness.sh scripts/_vendor_lib.sh scripts/verify_cut_manifest.py; do
    [ -r "$REPO_ROOT/$f" ] || { echo "CANNOT-RUN: no $f" >&2; exit 2; }
done
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A gh that records every call and always fails. In hotfix mode it must never
# be called; in normal mode it must be.
cat > "$WORK/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALL_LOG:?}"
exit 2
GH
chmod +x "$WORK/gh"

FIX="$WORK/repo"
mkdir -p "$FIX/scripts" "$FIX/vendor/t1" "$FIX/gui/OstlerInstaller" "$FIX/cuts/v9.9.9"
cp "$REPO_ROOT/scripts/verify_cut_freshness.sh" "$REPO_ROOT/scripts/_vendor_lib.sh" "$REPO_ROOT/scripts/verify_cut_manifest.py" "$FIX/scripts/"
git -C "$FIX" init -q .
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name Test
cat > "$FIX/vendor/VENDOR_MANIFEST.toml" <<'TOML'
[[tree]]
name             = "t1"
vendor_path      = "vendor/t1"
source_repo      = "$NOWHERE"
source_path      = "t1"
pinned_sha       = "abcdef1"
verify           = "full"
TOML
printf 'vendored content\n' > "$FIX/vendor/t1/a.py"
# The fixture sha256 is COMPOSED, not a literal: a long digit run reads as an
# account number to ci-pii-shape-scan, which is right not to make exceptions.
FAKE_SHA="$(printf 'ab%.0s' $(seq 1 32))"
printf 'DAEMON_VERSION       ?= 0.5.28\nDAEMON_SHA256        ?= %s\n' "$FAKE_SHA" > "$FIX/gui/Makefile"
cat > "$FIX/install.sh" <<'SH'
OSTLER_ASSISTANT_VERSION="${OSTLER_ASSISTANT_VERSION:-0.5.28}"
    image: ghcr.io/example-ns/ostler-wiki-site@sha256:aaaa
    image: ghcr.io/example-ns/ostler-wiki-compiler@sha256:bbbb
SH
git -C "$FIX" add -A && git -C "$FIX" commit -qm base && git -C "$FIX" tag v9.9.8
# The hotfix's own product change, outside vendor/.
printf 'gui change\n' > "$FIX/gui/OstlerInstaller/Fix.swift"
git -C "$FIX" add -A && git -C "$FIX" commit -qm "the hotfix"

hotfix_env() { printf 'CUT_VERSION=9.9.9\nCUT_KIND=hotfix\n%s' "${1:-}" > "$FIX/cuts/v9.9.9/cut.env"; }
run_gate() {
    : > "$WORK/calls"
    ( cd "$FIX" && env GH_CALL_LOG="$WORK/calls" FRESHNESS_GH_BIN="$WORK/gh" GH_API_TIMEOUT=2 \
        FRESHNESS_CUT_VERSION=v9.9.9 bash scripts/verify_cut_freshness.sh >"$WORK/out" 2>&1; echo $? )
}
squash() { tr '\n' ' ' < "$WORK/out" | cut -c1-160; }

echo "-- 1. hotfix, nothing changed --"
hotfix_env 'HOTFIX_BASE_TAG=v9.9.8'
rc="$(run_gate)"
if [ "$rc" = "0" ] && grep -q 'FROZEN identical to base' "$WORK/out" && [ ! -s "$WORK/calls" ]; then
    ok "unchanged hotfix passes as FROZEN and never asks upstream"
else
    bad "unchanged hotfix gave rc=${rc}, gh calls $(wc -l < "$WORK/calls"): $(squash)"
fi

echo "-- 2. hotfix, one vendored byte changed --"
printf 'vendored contenT\n' > "$FIX/vendor/t1/a.py"
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q 'vendor:t1 .*RED hotfix' "$WORK/out"; then
    ok "one changed vendored byte is RED and names the tree"
else
    bad "a changed vendored byte gave rc=${rc}: $(squash)"
fi
git -C "$FIX" checkout -q -- vendor/t1/a.py

echo "-- 3. hotfix, a new untracked file in vendor/ --"
printf 'new\n' > "$FIX/vendor/stray.py"
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'vendor/ (whole directory).*RED' "$WORK/out" \
    && ok "an untracked file anywhere in vendor/ is RED" \
    || bad "an untracked vendor file gave rc=${rc}: $(squash)"
rm -f "$FIX/vendor/stray.py"

echo "-- 4. hotfix, daemon pin moved --"
sed -i.bak 's/0\.5\.28/0.5.29/' "$FIX/gui/Makefile" && rm -f "$FIX/gui/Makefile.bak"
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'daemon pin (gui/Makefile).*RED' "$WORK/out" \
    && ok "a moved daemon pin is RED" \
    || bad "a moved daemon pin gave rc=${rc}: $(squash)"
git -C "$FIX" checkout -q -- gui/Makefile

echo "-- 5. hotfix with no HOTFIX_BASE_TAG --"
hotfix_env ''
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'without HOTFIX_BASE_TAG' "$WORK/out" \
    && ok "CUT_KIND=hotfix without a base tag is RED, not the normal path" \
    || bad "a baseless hotfix gave rc=${rc}: $(squash)"

echo "-- 6. NOT a hotfix: the live-HEAD path runs --"
printf 'CUT_VERSION=9.9.9\n' > "$FIX/cuts/v9.9.9/cut.env"
rc="$(run_gate)"
if [ "$rc" != "0" ] && ! grep -q 'FROZEN' "$WORK/out" && [ -s "$WORK/calls" ]; then
    ok "a non-hotfix cut asks upstream (rc=${rc}, $(wc -l < "$WORK/calls" | tr -d ' ') gh calls) and is not FROZEN"
else
    bad "a non-hotfix cut gave rc=${rc} with $(wc -l < "$WORK/calls" | tr -d ' ') gh calls: $(squash)"
fi

echo "-- 6b. declared wiki-site delta (HOTFIX_DECLARED_DELTAS=wiki-site) --"
mkdir -p "$FIX/scripts"
printf 'wiki-site\tsha256:aaaa\tbase\n' > "$FIX/scripts/wiki_image_provenance.tsv"
git -C "$FIX" add -A >/dev/null 2>&1
sed -i.bak 's/ostler-wiki-site@sha256:aaaa/ostler-wiki-site@sha256:cccc/' "$FIX/install.sh" && rm -f "$FIX/install.sh.bak"
hotfix_env 'HOTFIX_BASE_TAG=v9.9.8'
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'wiki-site image (install.sh).*RED' "$WORK/out" \
    && ok "an UNdeclared wiki-site change is RED" || bad "undeclared wiki-site change gave rc=${rc}: $(squash)"
hotfix_env 'HOTFIX_BASE_TAG=v9.9.8
HOTFIX_DECLARED_DELTAS=wiki-site'
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'declared delta without provenance' "$WORK/out" \
    && ok "a declared wiki-site delta with no provenance row is RED" || bad "declared delta without provenance gave rc=${rc}: $(squash)"
printf 'wiki-site\tsha256:cccc\tfixcommit\n' >> "$FIX/scripts/wiki_image_provenance.tsv"
rc="$(run_gate)"
[ "$rc" = "0" ] && grep -q 'DECLARED delta' "$WORK/out" \
    && ok "a declared wiki-site delta with provenance passes as DECLARED" || bad "declared delta with provenance gave rc=${rc}: $(squash)"
sed -i.bak 's/ostler-wiki-compiler@sha256:bbbb/ostler-wiki-compiler@sha256:dddd/' "$FIX/install.sh" && rm -f "$FIX/install.sh.bak"
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'wiki-compiler image (install.sh).*RED' "$WORK/out" \
    && ok "declaring wiki-site does not excuse a wiki-compiler change" || bad "compiler change under a site declaration gave rc=${rc}: $(squash)"
git -C "$FIX" checkout -q -- install.sh
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'declared delta but unchanged' "$WORK/out" \
    && ok "a declaration with no actual change is RED (stale declaration)" || bad "stale declaration gave rc=${rc}: $(squash)"
hotfix_env 'HOTFIX_BASE_TAG=v9.9.8
HOTFIX_DECLARED_DELTAS=daemon'
rc="$(run_gate)"
[ "$rc" = "1" ] && grep -q 'undeclarable delta' "$WORK/out" \
    && ok "a delta outside the closed set is RED" || bad "an undeclarable delta gave rc=${rc}: $(squash)"
rm -f "$FIX/scripts/wiki_image_provenance.tsv"; git -C "$FIX" checkout -q -- . 2>/dev/null

echo "-- 7-9. manifest gate pinned_artefact_freshness --"
cat > "$WORK/mf.py" <<'PY'
import importlib.util, sys
from pathlib import Path
fix = Path(sys.argv[1]); mode = sys.argv[2]
spec = importlib.util.spec_from_file_location("vcm", fix / "scripts" / "verify_cut_manifest.py")
vcm = importlib.util.module_from_spec(spec); spec.loader.exec_module(vcm)
entry = {"id": "permanent-daemon-freshness", "title": "t", "source_pr": "",
         "proof": {"kind": "pinned_artefact_freshness", "artefact": "daemon",
                   "pinned_version_source": {"file": "gui/Makefile",
                                             "pattern": r"DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)"},
                   "tag_format": "hub-v{version}", "source_repo": "example/none",
                   "source_paths": ["crates/**"]}}
ctx = {"cm051_dir": fix, "app_path": None, "extra_paths": {}, "require_runtime_proofs": False,
       "hotfix": vcm._hotfix_of(fix, "v9.9.9")}
r = vcm.check_pinned_artefact_freshness(entry, ctx)
print(r.status if hasattr(r, "status") else r[3])
PY
mf() { python3 -I "$WORK/mf.py" "$FIX" x 2>&1 | tail -1; }
hotfix_env 'HOTFIX_BASE_TAG=v9.9.8'
s="$(mf)"; [ "$s" = "PASS" ] && ok "manifest: hotfix daemon pin equal to the base passes" || bad "manifest: equal pin gave ${s}"
sed -i.bak 's/0\.5\.28/0.5.29/' "$FIX/gui/Makefile" && rm -f "$FIX/gui/Makefile.bak"
s="$(mf)"; [ "$s" = "FAIL" ] && ok "manifest: hotfix daemon pin moved from the base fails" || bad "manifest: moved pin gave ${s}"
git -C "$FIX" checkout -q -- gui/Makefile
hotfix_env ''
s="$(mf)"; [ "$s" = "FAIL" ] && ok "manifest: hotfix with no base tag fails" || bad "manifest: baseless hotfix gave ${s}"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
