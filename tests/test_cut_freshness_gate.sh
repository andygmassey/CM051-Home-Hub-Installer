#!/usr/bin/env bash
#
# test_cut_freshness_gate.sh
#
# Self-test for scripts/verify_cut_freshness.sh -- the live-HEAD pre-cut
# freshness gate that plugs the "built but not in the cut" leak.
#
# The gate talks to the GitHub API. To make this hermetic + deterministic we
# inject a MOCK `gh` (via FRESHNESS_GH_BIN) that answers `gh api` calls from a
# per-scenario fixture, and we point the gate at a MINIMAL fixture manifest +
# fixture install.sh / gui-Makefile / provenance ledger so the exact set of
# inputs under test is controlled.
#
# Scenarios proven (the mission's acceptance set):
#   (a) everything fresh                          -> exit 0, GATE GREEN
#   (b) a vendor pin behind live HEAD, no hold_ack -> exit 1, names tree + delta
#   (c) a stale daemon (tag predates integ)       -> exit 1, names the daemon
#   (d) a stale wiki image (CM044 lag)            -> exit 1, names the image
#   (e) GitHub unreachable                        -> exit 3 CANNOT-VERIFY (no false pass)
#   (f) a repinned wiki digest with NO provenance -> exit 1 (fail-closed)
# The hardening set (this rev):
#   (g) verify=skip tree that is FETCHABLE + stale -> exit 1 (WARN hole CLOSED)
#   (h) exempt WITH a reason                       -> exit 0, EXEMPT (non-fatal)
#   (i) exempt WITHOUT a reason                    -> exit 1 (fail-closed)
#   (j) stale tree, hold_ack covers WHOLE delta    -> exit 0, HELD (non-fatal)
#   (k) stale tree, hold_ack MISSING one delta sha -> exit 1, names the un-acked sha
#   (l) hold_ack covers delta but grafted!=true    -> exit 1 (assertion required)
#
# British English; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/verify_cut_freshness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- canonical SHAs used across scenarios (40-hex, arbitrary but distinct) ---
SHA_FRESH="1111111111111111111111111111111111111111"   # == live head (fresh)
SHA_OLD="2222222222222222222222222222222222222222"     # behind live head (a pin)
LIVE_HEAD="1111111111111111111111111111111111111111"
DAEMON_TAG_FRESH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DAEMON_TAG_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
INTEG_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CM044_FRESH="3333333333333333333333333333333333333333"
CM044_OLD="4444444444444444444444444444444444444444"
CM044_HEAD="3333333333333333333333333333333333333333"
# delta commits (pin SHA_OLD .. live SHA_FRESH), newest-first
D1="d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"
D2="d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"
D3="d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3"

# ---------------------------------------------------------------------------
# Mock `gh`: implements `gh api ...` deterministically from env.
#   MOCK_UNREACH=1                     -> every call exits 2 (network down)
#   MOCK_HEAD_<repo>_<ref>=<sha>       -> commits/<ref> or per_page=1 path head
#   MOCK_CMP_<base8>_<head8>=...       -> "status ahead behind" for a compare
#   MOCK_DELTA_<repo>_<path>=<list>    -> per_page=100 path-commit list (multiline)
# Keys are sanitised to A-Za-z0-9_ (non-alnum -> _). ":" in a ref -> "_".
# ---------------------------------------------------------------------------
make_mock_gh() {
    cat > "$WORK/gh" <<'MOCK'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "auth" ] && exit 0
[ "${1:-}" != "api" ] && { echo "mock gh: unsupported: $*" >&2; exit 99; }
shift
if [ "${MOCK_UNREACH:-0}" = "1" ]; then exit 2; fi

path=""
for a in "$@"; do case "$a" in --*|-*) ;; *) path="$a"; break ;; esac; done
san() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

case "$path" in
  repos/*/compare/*)
    spec="${path#*/compare/}"; base="${spec%%...*}"; head="${spec#*...}"
    key="MOCK_CMP_$(san "${base:0:8}")_$(san "${head:0:8}")"
    val="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$val" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
    echo "$val"; exit 0 ;;
  repos/*/commits*)
    repo="${path%%/commits*}"; repo="${repo#repos/}"
    case "$path" in
      *"/commits?"*)
        q="${path#*\?}"
        b="$(printf '%s\n' "$q" | tr '&' '\n' | sed -n 's/^sha=//p')"
        p="$(printf '%s\n' "$q" | tr '&' '\n' | sed -n 's/^path=//p')"
        # per_page=100 => the path-scoped DELTA list (multiline). Else a head.
        if printf '%s' "$q" | grep -q 'per_page=100'; then
          key="MOCK_DELTA_$(san "$repo")_$(san "$p")"
          val="$(eval "printf '%s' \"\${$key:-}\"")"
          if [ -z "$val" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
          printf '%s\n' "$val"; exit 0
        fi
        ref="${b}::${p}" ;;
      *"/commits/"*) ref="${path##*/commits/}" ;;
    esac
    key="MOCK_HEAD_$(san "$repo")_$(san "$ref")"
    val="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$val" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
    echo "$val"; exit 0 ;;
esac
echo "{\"message\":\"unmatched: $path\"}"; exit 1
MOCK
    chmod +x "$WORK/gh"
}

# ---------------------------------------------------------------------------
# Fixture estate. Tree 1 = cm041/contact_syncer (source $CM041 -> CM041-People-
# Graph, path contact_syncer). Tree 2 = a second tree over $CM048 whose extra
# manifest fields are configurable. Globals drive the build:
#   T1_PIN T1_EXTRA  T2_PIN T2_EXTRA  DAEMON_PIN COMP_DIGEST COMP_PROV
# ---------------------------------------------------------------------------
FIXROOT="$WORK/estate"
build_fixture() {
    rm -rf "$FIXROOT"; mkdir -p "$FIXROOT/scripts" "$FIXROOT/gui" "$FIXROOT/vendor"
    {
      echo '[[tree]]'
      echo 'name             = "cm041/contact_syncer"'
      echo 'vendor_path      = "vendor/cm041/contact_syncer"'
      echo 'source_repo      = "$CM041"'
      echo 'source_path      = "contact_syncer"'
      echo "pinned_sha       = \"$T1_PIN\""
      echo 'verify           = "full"'
      printf '%s\n' "$T1_EXTRA"
      echo
      echo '[[tree]]'
      echo 'name             = "cm048_pipeline"'
      echo 'vendor_path      = "vendor/cm048_pipeline"'
      echo 'source_repo      = "$CM048"'
      echo 'source_path      = "."'
      echo "pinned_sha       = \"$T2_PIN\""
      echo 'verify           = "skip"'
      printf '%s\n' "$T2_EXTRA"
    } > "$FIXROOT/vendor/VENDOR_MANIFEST.toml"

    cat > "$FIXROOT/install.sh" <<EOF
#!/usr/bin/env bash
OSTLER_ASSISTANT_VERSION="\${OSTLER_ASSISTANT_VERSION:-$DAEMON_PIN}"
    image: ghcr.io/ostler-ai/ostler-wiki-site@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    image: ghcr.io/ostler-ai/ostler-wiki-compiler@$COMP_DIGEST
EOF
    cat > "$FIXROOT/gui/Makefile" <<EOF
DAEMON_VERSION       ?= $DAEMON_PIN
EOF
    {
      echo "# fixture ledger"
      echo -e "wiki-site\tsha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t$CM044_FRESH"
      if [ "$COMP_PROV" != "MISSING" ]; then
        echo -e "wiki-compiler\t$COMP_DIGEST\t$COMP_PROV"
      fi
    } > "$FIXROOT/scripts/wiki_image_provenance.tsv"
    cp "$REPO_ROOT/scripts/_vendor_lib.sh" "$FIXROOT/scripts/_vendor_lib.sh"
}

run_gate() { # extra env assignments passed as args
    env \
      FRESHNESS_GH_BIN="$WORK/gh" \
      VENDOR_MANIFEST="$FIXROOT/vendor/VENDOR_MANIFEST.toml" \
      WIKI_PROVENANCE_FILE="$FIXROOT/scripts/wiki_image_provenance.tsv" \
      DAEMON_INTEGRATION_BRANCH="integration/hub-v1.0.9" \
      CM044_BRANCH="main" \
      GH_API_TIMEOUT=5 \
      INSTALL_SH_OVERRIDE="$FIXROOT/install.sh" \
      GUI_MAKEFILE_OVERRIDE="$FIXROOT/gui/Makefile" \
      "$@" \
      bash "$GATE"
}

# Defaults: everything fresh, tree2 fresh + no extra fields.
reset_defaults() {
    T1_PIN="$SHA_FRESH"; T1_EXTRA=""
    T2_PIN="$SHA_FRESH"; T2_EXTRA=""
    DAEMON_PIN="0.9.9"
    COMP_DIGEST="sha256:cafe00000000000000000000000000000000000000000000000000000000cafe"
    COMP_PROV="$CM044_FRESH"
}

# The full estate's "everything else fresh" mock env (daemon + wiki + tree2 fresh).
FULL_FRESH_ENV=(
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD"
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD"
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH"
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD"
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD"
)

make_mock_gh

# ===========================================================================
# (a) ALL FRESH -> exit 0
# ===========================================================================
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "GATE: GREEN"; then
    ok "(a) all fresh -> exit 0, GATE GREEN"
else
    bad "(a) all fresh: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (b) STALE VENDOR PIN, no hold_ack -> exit 1, names the tree + delta commits
# ===========================================================================
reset_defaults; T1_PIN="$SHA_OLD"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_CMP_22222222_11111111="ahead 3 0" \
  MOCK_DELTA_andygmassey_CM041_People_Graph_contact_syncer="$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$SHA_OLD")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "vendor:cm041/contact_syncer" \
   && printf '%s' "$OUT" | grep -qE "RED STALE:\+3" \
   && printf '%s' "$OUT" | grep -q "d1d1d1d1d1d1"; then
    ok "(b) stale vendor pin, no hold_ack -> exit 1, names tree + un-acked delta"
else
    bad "(b) stale vendor: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (c) STALE DAEMON -> exit 1
# ===========================================================================
reset_defaults; DAEMON_PIN="0.9.8"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_8="$DAEMON_TAG_OLD" \
  MOCK_CMP_bbbbbbbb_aaaaaaaa="ahead 12 0" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE "daemon .* RED STALE:\+12"; then
    ok "(c) stale daemon -> exit 1, names daemon + '+12'"
else
    bad "(c) stale daemon: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (d) STALE WIKI IMAGE -> exit 1
# ===========================================================================
reset_defaults; COMP_PROV="$CM044_OLD"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_CMP_44444444_33333333="ahead 7 0" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE "wiki:wiki-compiler .* RED STALE:\+7"; then
    ok "(d) stale wiki image -> exit 1, names image + '+7'"
else
    bad "(d) stale wiki image: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (e) GITHUB UNREACHABLE -> exit 3 CANNOT-VERIFY
# ===========================================================================
reset_defaults; build_fixture
OUT="$(run_gate MOCK_UNREACH=1 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q "GATE: CANNOT VERIFY"; then
    ok "(e) github unreachable -> exit 3 CANNOT-VERIFY (no false pass)"
else
    bad "(e) unreachable: rc=$RC (expected 3)"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (f) REPINNED WIKI DIGEST WITH NO PROVENANCE ROW -> exit 1 (fail-closed)
# ===========================================================================
reset_defaults; COMP_PROV="MISSING"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED unrecorded-provenance"; then
    ok "(f) wiki repin w/o provenance row -> exit 1, fail-closed"
else
    bad "(f) unrecorded provenance: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (g) verify=skip tree that is FETCHABLE + stale -> exit 1 (WARN HOLE CLOSED)
#   Tree2 (cm048) is verify=skip but has a GitHub source; it is stale by +4.
#   Old behaviour: WARN, exit 0. New behaviour: RED, exit 1.
#   Isolate with FRESHNESS_ONLY so only tree2 runs.
# ===========================================================================
reset_defaults; T2_PIN="$SHA_OLD"; build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm048_pipeline" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 4 0" \
  MOCK_DELTA_andygmassey_CM048_PWG_Conversation_Processing_="$(printf '%s\n%s' "$D1" "$SHA_OLD")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "vendor:cm048_pipeline" \
   && printf '%s' "$OUT" | grep -qE "RED STALE:\+4"; then
    ok "(g) fetchable verify=skip tree, stale -> exit 1 (WARN hole closed)"
else
    bad "(g) skip-hole: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (h) EXEMPT WITH a reason -> exit 0, EXEMPT (non-fatal)
# ===========================================================================
reset_defaults
T2_EXTRA=$'verify_exempt    = true\nexempt_reason    = "CM019 is not a git repo -- genuinely unverifiable"'
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm048_pipeline" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "EXEMPT" \
   && printf '%s' "$OUT" | grep -q "GATE: GREEN"; then
    ok "(h) exempt WITH reason -> exit 0, EXEMPT non-fatal"
else
    bad "(h) exempt-with-reason: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (i) EXEMPT WITHOUT a reason -> exit 1 (fail-closed)
# ===========================================================================
reset_defaults
T2_EXTRA=$'verify_exempt    = true'
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm048_pipeline" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED exempt-without-reason"; then
    ok "(i) exempt WITHOUT reason -> exit 1, fail-closed"
else
    bad "(i) exempt-without-reason: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (j) STALE tree, hold_ack covers the WHOLE delta + grafted=true -> exit 0 HELD
# ===========================================================================
reset_defaults; T1_PIN="$SHA_OLD"
T1_EXTRA=$'hold_ack_shas    = "d1d1d1d1 d2d2d2d2 d3d3d3d3"\nhold_ack_reason  = "v1.1 features deferred; bugfixes grafted"\nshipping_bugfixes_grafted = true'
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm041/contact_syncer" \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 3 0" \
  MOCK_DELTA_andygmassey_CM041_People_Graph_contact_syncer="$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$SHA_OLD")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE "HELD STALE:\+3" \
   && printf '%s' "$OUT" | grep -q "GATE: GREEN"; then
    ok "(j) stale + hold_ack covers whole delta -> exit 0, HELD"
else
    bad "(j) fully-acked: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (k) STALE tree, hold_ack MISSING one delta sha -> exit 1, names the un-acked
# ===========================================================================
reset_defaults; T1_PIN="$SHA_OLD"
T1_EXTRA=$'hold_ack_shas    = "d1d1d1d1 d2d2d2d2"\nhold_ack_reason  = "partial"\nshipping_bugfixes_grafted = true'
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm041/contact_syncer" \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 3 0" \
  MOCK_DELTA_andygmassey_CM041_People_Graph_contact_syncer="$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$SHA_OLD")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "unacked" \
   && printf '%s' "$OUT" | grep -q "d3d3d3d3d3d3" \
   && ! printf '%s' "$OUT" | grep -q "d1d1d1d1d1d1 "; then
    ok "(k) stale + hold_ack missing a delta sha -> exit 1, names ONLY the un-acked d3"
else
    bad "(k) partial-ack: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (l) hold_ack covers delta but shipping_bugfixes_grafted != true -> exit 1
# ===========================================================================
reset_defaults; T1_PIN="$SHA_OLD"
T1_EXTRA=$'hold_ack_shas    = "d1d1d1d1 d2d2d2d2 d3d3d3d3"\nhold_ack_reason  = "held"'
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm041/contact_syncer" \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 3 0" \
  MOCK_DELTA_andygmassey_CM041_People_Graph_contact_syncer="$(printf '%s\n%s\n%s\n%s' "$D1" "$D2" "$D3" "$SHA_OLD")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "no-grafted-assert"; then
    ok "(l) hold_ack without shipping_bugfixes_grafted=true -> exit 1"
else
    bad "(l) grafted-assert: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

echo
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
