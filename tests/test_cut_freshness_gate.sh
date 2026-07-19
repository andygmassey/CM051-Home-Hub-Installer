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
#   (a) everything fresh                      -> exit 0, GATE GREEN
#   (b) a vendor pin behind live HEAD         -> exit 1, names the tree, +N
#   (c) a stale daemon (tag predates integ)   -> exit 1, names the daemon
#   (d) a stale wiki image (CM044 lag)        -> exit 1, names the image
#   (e) GitHub unreachable                    -> exit 3 CANNOT-VERIFY (no false pass)
# Plus:
#   (f) a repinned wiki digest with NO provenance row -> exit 1 (fail-closed)
#   (g) a stale but verify=skip tree          -> exit 0 (WARN, not RED)
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
SHA_OLD="2222222222222222222222222222222222222222"     # behind live head
LIVE_HEAD="1111111111111111111111111111111111111111"
DAEMON_TAG_FRESH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DAEMON_TAG_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
INTEG_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CM044_FRESH="3333333333333333333333333333333333333333"
CM044_OLD="4444444444444444444444444444444444444444"
CM044_HEAD="3333333333333333333333333333333333333333"

# ---------------------------------------------------------------------------
# Build a mock `gh` that answers `gh api <path> --jq <expr>` deterministically.
# The mock ignores --jq and returns the FINAL value the gate expects for each
# call shape, driven by an env "database" the scenario exports:
#   MOCK_UNREACH=1               -> every call exits 2 with empty stdout (network down)
#   MOCK_HEAD_<key>=<sha>        -> commits/<ref> or path-scoped head for a repo
#   MOCK_CMP_<base8>_<head8>=... -> "status ahead behind" for a compare
# Keys are derived from the repo + ref, sanitised to A-Za-z0-9_.
# ---------------------------------------------------------------------------
make_mock_gh() {
    cat > "$WORK/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: only implements `gh api ...`. Reads canned answers from env.
set -u
[ "${1:-}" = "auth" ] && exit 0          # token_for is bypassed in mock mode anyway
[ "${1:-}" != "api" ] && { echo "mock gh: unsupported: $*" >&2; exit 99; }
shift
if [ "${MOCK_UNREACH:-0}" = "1" ]; then exit 2; fi   # simulate transport failure

# Find the api path (first non-flag arg).
path=""
for a in "$@"; do case "$a" in --*|-*) ;; *) path="$a"; break ;; esac; done

san() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

case "$path" in
  repos/*/compare/*)
    # repos/<owner>/<repo>/compare/<base>...<head>
    spec="${path#*/compare/}"; base="${spec%%...*}"; head="${spec#*...}"
    key="MOCK_CMP_$(san "${base:0:8}")_$(san "${head:0:8}")"
    val="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$val" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
    echo "$val"; exit 0 ;;
  repos/*/commits*)
    # Either repos/<o>/<r>/commits/<ref>  or  repos/<o>/<r>/commits?sha=..&path=..
    ref=""
    case "$path" in
      *"/commits/"*) ref="${path##*/commits/}" ;;
      *"/commits?"*)
        q="${path#*\?}"
        # extract sha= and path=
        b="$(printf '%s\n' "$q" | tr '&' '\n' | sed -n 's/^sha=//p')"
        p="$(printf '%s\n' "$q" | tr '&' '\n' | sed -n 's/^path=//p')"
        ref="${b}::${p}" ;;
    esac
    repo="${path%%/commits*}"; repo="${repo#repos/}"
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
# A minimal fixture estate: manifest (2 trees), install.sh, gui/Makefile,
# provenance ledger. The gate reads pins from these.
# ---------------------------------------------------------------------------
FIXROOT="$WORK/estate"
build_fixture() {
    local vendor_pin="$1" daemon_pin="$2" comp_digest="$3" comp_prov_sha="$4" skip_pin="$5"
    rm -rf "$FIXROOT"; mkdir -p "$FIXROOT/scripts" "$FIXROOT/gui" "$FIXROOT/vendor"

    cat > "$FIXROOT/vendor/VENDOR_MANIFEST.toml" <<EOF
[[tree]]
name             = "cm041/contact_syncer"
vendor_path      = "vendor/cm041/contact_syncer"
source_repo      = "\$CM041"
source_path      = "contact_syncer"
pinned_sha       = "$vendor_pin"
verify           = "full"

[[tree]]
name             = "cm019_preferences"
vendor_path      = "vendor/cm019_preferences"
source_repo      = "\$CM048"
source_path      = "."
pinned_sha       = "$skip_pin"
verify           = "skip"
EOF

    # install.sh: daemon pin + one wiki-compiler digest (+ a valid wiki-site pin).
    cat > "$FIXROOT/install.sh" <<EOF
#!/usr/bin/env bash
OSTLER_ASSISTANT_VERSION="\${OSTLER_ASSISTANT_VERSION:-$daemon_pin}"
    image: ghcr.io/ostler-ai/ostler-wiki-site@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    image: ghcr.io/ostler-ai/ostler-wiki-compiler@$comp_digest
EOF

    cat > "$FIXROOT/gui/Makefile" <<EOF
DAEMON_VERSION       ?= $daemon_pin
EOF

    # Provenance ledger. wiki-site always mapped fresh; wiki-compiler maps to
    # the requested source sha ONLY if comp_prov_sha is non-"MISSING".
    {
      echo "# fixture ledger"
      echo -e "wiki-site\tsha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t$CM044_FRESH"
      if [ "$comp_prov_sha" != "MISSING" ]; then
        echo -e "wiki-compiler\t$comp_digest\t$comp_prov_sha"
      fi
    } > "$FIXROOT/scripts/wiki_image_provenance.tsv"

    # The gate resolves REPO_ROOT from its own location; point it at the fixture
    # via env overrides instead. Symlink the real lib so the TOML reader loads.
    cp "$REPO_ROOT/scripts/_vendor_lib.sh" "$FIXROOT/scripts/_vendor_lib.sh"
}

# Run the gate against the fixture estate with a given MOCK env db.
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

make_mock_gh

# ===========================================================================
# (a) ALL FRESH -> exit 0
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_FRESH" "$SHA_FRESH"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "GATE: GREEN"; then
    ok "(a) all fresh -> exit 0, GATE GREEN"
else
    bad "(a) all fresh: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (b) STALE VENDOR PIN -> exit 1, names the tree
#   pin = SHA_OLD, live head = SHA_FRESH, compare OLD...FRESH = ahead 5
# ===========================================================================
build_fixture "$SHA_OLD" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_FRESH" "$SHA_FRESH"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 5 0" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "vendor:cm041/contact_syncer" \
   && printf '%s' "$OUT" | grep -qE "RED STALE:\+5"; then
    ok "(b) stale vendor pin -> exit 1, names tree + '+5'"
else
    bad "(b) stale vendor: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (c) STALE DAEMON -> exit 1
#   daemon pin 0.9.8 -> tag hub-v0.9.8 -> DAEMON_TAG_OLD; integ head newer.
#   compare OLD...INTEG = ahead 12
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.8" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_FRESH" "$SHA_FRESH"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_8="$DAEMON_TAG_OLD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_CMP_bbbbbbbb_aaaaaaaa="ahead 12 0" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE "daemon .* RED STALE:\+12"; then
    ok "(c) stale daemon -> exit 1, names daemon + '+12'"
else
    bad "(c) stale daemon: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (d) STALE WIKI IMAGE -> exit 1
#   provenance maps compiler digest -> CM044_OLD; CM044 head newer.
#   compare CM044_OLD...CM044_HEAD = ahead 7
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_OLD" "$SHA_FRESH"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  MOCK_CMP_44444444_33333333="ahead 7 0" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE "wiki:wiki-compiler .* RED STALE:\+7"; then
    ok "(d) stale wiki image -> exit 1, names image + '+7'"
else
    bad "(d) stale wiki image: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (e) GITHUB UNREACHABLE -> exit 3 CANNOT-VERIFY (never a false pass)
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_FRESH" "$SHA_FRESH"
OUT="$(run_gate MOCK_UNREACH=1 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q "GATE: CANNOT VERIFY"; then
    ok "(e) github unreachable -> exit 3 CANNOT-VERIFY (no false pass)"
else
    bad "(e) unreachable: rc=$RC (expected 3)"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (f) REPINNED WIKI DIGEST WITH NO PROVENANCE ROW -> exit 1 (fail-closed)
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "MISSING" "$SHA_FRESH"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED unrecorded-provenance"; then
    ok "(f) wiki repin w/o provenance row -> exit 1, fail-closed"
else
    bad "(f) unrecorded provenance: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (g) STALE verify=skip TREE -> exit 0 (WARN, not RED)
#   skip-tree pin = SHA_OLD behind live; compare ahead 3. Everything else fresh.
# ===========================================================================
build_fixture "$SHA_FRESH" "0.9.9" "sha256:cafe00000000000000000000000000000000000000000000000000000000cafe" "$CM044_FRESH" "$SHA_OLD"
OUT="$(run_gate \
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD" \
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD" \
  MOCK_CMP_22222222_11111111="ahead 3 0" \
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH" \
  MOCK_HEAD_ostler_ai_ostler_assistant_integration_hub_v1_0_9="$INTEG_HEAD" \
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD" \
  2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE "WARN STALE:\+3 \(skip\)"; then
    ok "(g) stale verify=skip tree -> exit 0, WARN not RED"
else
    bad "(g) skip warn: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

echo
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
