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
#
# COMPOSED, not written as literals. A 40-character run of digits is
# indistinguishable BY SHAPE from an account or device number, so the repo's
# ci-pii-shape-scan matches \b[0-9]{15,}\b on it and fails the PR -- correctly,
# because a shape guard that carved out an exception for "but these are
# obviously fake" would be a denylist again. The values are unchanged; only the
# literal leaves the file. Do not weaken the pattern and do not exclude tests/:
# excluding test dirs by design is what let real PII into a CM041 fixture.
mkrun() { # <char> -> a 40-character run of that char
    local c="$1" out="" i
    for i in $(seq 1 40); do out="$out$c"; done
    printf '%s' "$out"
}
SHA_FRESH="$(mkrun 1)"   # == live head (fresh)
SHA_OLD="$(mkrun 2)"     # behind live head (a pin)
LIVE_HEAD="$(mkrun 1)"
DAEMON_TAG_FRESH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DAEMON_TAG_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
# oa main HEAD sitting AHEAD of the pinned daemon tag -- the recency link.
OA_MAIN_AHEAD="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
CM044_FRESH="$(mkrun 3)"
CM044_OLD="$(mkrun 4)"
CM044_HEAD="$(mkrun 3)"
# Daemon artefact-provenance fixtures (29c20b1 chain). SHA256_PUB is what the
# published .sha256 sidecar carries AND what the fixture Makefile pins, so the
# happy path binds pin -> tag -> release -> bytes -> source for real.
SHA256_PUB="abababababababababababababababababababababababababababababababab"
SHA256_OTHER="cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
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

# UNREADABLE repo: 404 EVERY endpoint under it, not just the bare repo probe.
# GitHub cannot be in the state "I will not show you this repo, but I will
# happily resolve commits inside it" -- and a mock that allows it lets a
# control pass while modelling a situation that cannot occur. Applying it
# here, before the endpoint dispatch, is what makes (m) reproduce the actual
# production symptom (RED unresolved) against the unpatched gate rather than
# a false GREEN.
case "$path" in
  repos/*)
    _r="${path#repos/}"; _owner="${_r%%/*}"; _rest="${_r#*/}"; _name="${_rest%%/*}"
    if [ "$(eval "printf '%s' \"\${MOCK_UNREADABLE_$(san "$_owner/$_name"):-}\"")" = "1" ]; then
      echo "{\"message\":\"Not Found\"}"; exit 1
    fi ;;
esac

# Unreachable for the RELEASE endpoints only, so a test can fail the daemon
# artefact lookup while the tag lookup still succeeds. Global MOCK_UNREACH
# fails the tag first and never reaches the release chain at all -- a test
# built on it passes without exercising the branch it names.
if [ "${MOCK_UNREACH_RELEASES:-0}" = "1" ]; then
  case "$path" in repos/*/releases/*) exit 2 ;; esac
fi

case "$path" in
  repos/*/compare/*)
    spec="${path#*/compare/}"; base="${spec%%...*}"; head="${spec#*...}"
    # The gate hits this ONE endpoint with TWO different --jq shapes: the
    # status/ahead/behind triple (gh_compare), and the delta commit LIST
    # (hold_ack enumeration for wiki + daemon). Returning MOCK_CMP for both
    # means a hold_ack test can never see a real sha -- it would parse
    # "ahead 3 0" as the delta and report everything un-acked, so the case
    # would "pass" without exercising the ack matcher at all.
    jqc=""; prevc=""
    for a in "$@"; do [ "$prevc" = "--jq" ] && jqc="$a"; prevc="$a"; done
    case "$jqc" in
      *commits*) key="MOCK_CMPDELTA_$(san "${base:0:8}")_$(san "${head:0:8}")" ;;
      *)         key="MOCK_CMP_$(san "${base:0:8}")_$(san "${head:0:8}")" ;;
    esac
    val="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$val" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
    printf '%s\n' "$val"; exit 0 ;;
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
  repos/*/releases/tags/*)
    # The daemon provenance chain (29c20b1): tag -> published release ->
    # .sha256 sidecar -> build-info.json commit. MOCK_REL_<tag> unset means
    # "no such release", which is what the real API does (404 -> non-zero).
    tag="${path##*/releases/tags/}"
    key="MOCK_REL_$(san "$tag")"
    state="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$state" ]; then echo "{\"message\":\"Not Found\"}"; exit 1; fi
    # The gate asks for asset ids via --jq. Honour that shape rather than
    # emitting a full assets[] array we would then have to jq for real.
    # An UNSET asset var means the asset is genuinely absent from the release.
    jqx=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jqx="$a"; prev="$a"; done
    case "$jqx" in
      *sha256*)     [ -n "${MOCK_ASSET_SHA256:-}" ] && echo "SHAID"; exit 0 ;;
      *build-info*) [ -n "${MOCK_ASSET_BUILDINFO:-}" ] && echo "BIID"; exit 0 ;;
    esac
    d=false; [ "$state" = "draft" ] && d=true
    echo "{\"draft\":$d,\"tag_name\":\"$tag\"}"; exit 0 ;;
  repos/*/releases/assets/*)
    case "${path##*/assets/}" in
      # Real sidecar format is "<sha>  <filename>"; the gate awk's field 1.
      SHAID) printf '%s  ostler-assistant.tar.gz\n' "${MOCK_ASSET_SHA256:-}"; exit 0 ;;
      BIID)  printf '{"commit_sha": "%s"}\n' "${MOCK_ASSET_BUILDINFO:-}"; exit 0 ;;
    esac
    echo "{\"message\":\"Not Found\"}"; exit 1 ;;
  repos/*)
    # BARE repo endpoint `repos/<owner>/<repo>` -- what repo_readable() probes
    # to separate "I cannot SEE that repo" from "that SHA is not IN it".
    # GitHub answers 404 for both, so the gate asks the two questions
    # separately (v1018-D621c).
    #
    # READABLE BY DEFAULT. Every pre-existing scenario above pins a repo it can
    # read, and making them opt IN would have quietly rewritten what twelve
    # controls mean. A test opts a single repo OUT with
    # MOCK_UNREADABLE_<sanitised-owner-repo>=1.
    rest="${path#repos/}"
    case "$rest" in
      */*/*) ;;   # deeper endpoint we do not model -- fall through to unmatched
      */*)
        # Unreadable is handled globally above, so reaching here means
        # readable: answer with .full_name, which is what the gate --jq's.
        printf '%s\n' "$rest"; exit 0 ;;
    esac ;;
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
DAEMON_SHA256        ?= $MK_SHA256
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
      DAEMON_HOLD_ACK_FILE="$FIXROOT/scripts/daemon_hold_ack.tsv" \
      CM044_BRANCH="main" \
      OA_BRANCH="main" \
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
    MK_SHA256="$SHA256_PUB"
    COMP_DIGEST="sha256:cafe00000000000000000000000000000000000000000000000000000000cafe"
    COMP_PROV="$CM044_FRESH"
}

# The full estate's "everything else fresh" mock env (daemon + wiki + tree2 fresh).
FULL_FRESH_ENV=(
  MOCK_HEAD_andygmassey_CM041_People_Graph_main__contact_syncer="$LIVE_HEAD"
  MOCK_HEAD_andygmassey_CM048_PWG_Conversation_Processing_main="$LIVE_HEAD"
  MOCK_HEAD_ostler_ai_ostler_assistant_hub_v0_9_9="$DAEMON_TAG_FRESH"
  MOCK_HEAD_andygmassey_CM044_PWG_Personal_Wiki_main="$CM044_HEAD"
  # Link 5, RECENCY: oa main HEAD == the tag's commit, so the daemon is current.
  # Cases (c8)-(c10) move this ahead to exercise the behind-HEAD branch.
  MOCK_HEAD_ostler_ai_ostler_assistant_main="$DAEMON_TAG_FRESH"
  # Daemon provenance chain, all links intact: a published (non-draft) release
  # for the pinned tag, a .sha256 sidecar matching gui/Makefile DAEMON_SHA256,
  # and a build-info.json whose commit_sha == the tag's commit.
  MOCK_REL_hub_v0_9_9="published"
  MOCK_ASSET_SHA256="$SHA256_PUB"
  MOCK_ASSET_BUILDINFO="$DAEMON_TAG_FRESH"
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
# (c1)-(c5) DAEMON ARTEFACT-PROVENANCE CHAIN -> each broken link is exit 1
#
# This slot used to hold a single "(c) stale daemon" case asserting
# `daemon ... RED STALE:+12` from a comparison against DAEMON_INTEGRATION_BRANCH.
# 29c20b1 deleted that comparison outright and replaced it with the chain below;
# the assertion was left behind, so it asserted a contract the gate no longer
# had and could never pass again. It went red on 2026-08-01 and stayed red
# through v1.0.16, v1.0.17 and v1.0.18. Meanwhile the five branches that
# actually replaced it had no coverage at all -- so the gate protecting the
# customer download path was both permanently red AND untested.
#
# Each case below breaks exactly one link and asserts the gate names that link.
# ===========================================================================
# (c1) the pin resolves to no tag at all
reset_defaults; DAEMON_PIN="0.9.8"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED no-tag-for-pin"; then
    ok "(c1) pin with no tag -> exit 1, no-tag-for-pin"
else
    bad "(c1) no-tag-for-pin: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c2) tag exists but NO published release -- every customer install would 404
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" MOCK_REL_hub_v0_9_9= 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED no-published-release"; then
    ok "(c2) no published release -> exit 1, no-published-release"
else
    bad "(c2) no-published-release: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c3) the release exists but is still a DRAFT -- not downloadable by a customer
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" MOCK_REL_hub_v0_9_9="draft" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED release-is-draft"; then
    ok "(c3) draft release -> exit 1, release-is-draft"
else
    bad "(c3) release-is-draft: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c4) Makefile DAEMON_SHA256 != the published sidecar -- installer would reject
#      the very tarball it just downloaded
reset_defaults; MK_SHA256="$SHA256_OTHER"; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED sha256-mismatch"; then
    ok "(c4) Makefile sha256 != sidecar -> exit 1, sha256-mismatch"
else
    bad "(c4) sha256-mismatch: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c5) the published binary was built from a DIFFERENT commit than the tag --
#      the shipped daemon is not the tagged source (the v1.0.13.3 R1/R5 class)
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" MOCK_ASSET_BUILDINFO="$DAEMON_TAG_OLD" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED built-from-other-commit"; then
    ok "(c5) build-info commit != tag commit -> exit 1, built-from-other-commit"
else
    bad "(c5) built-from-other-commit: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c6) release published with no .sha256 sidecar -- the pin cannot be bound to
#      the shipped bytes at all
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" MOCK_ASSET_SHA256= 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "RED no-sha256-asset"; then
    ok "(c6) no .sha256 sidecar -> exit 1, no-sha256-asset"
else
    bad "(c6) no-sha256-asset: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c7) GitHub unreachable must make the daemon CANNOT-VERIFY, never RED.
#      Before v1018-D029 this block used bare `gh`, so a network failure was
#      indistinguishable from "no release exists" and printed a confident
#      RED no-published-release. A gate that cries wolf when the network
#      blips is a gate people learn to ignore -- which is how the real thing
#      sails through. (e) asserts the whole-gate exit code; this asserts the
#      daemon ROW specifically, because that is where the false RED appeared.
#      MOCK_UNREACH_RELEASES (not global MOCK_UNREACH): the tag still resolves,
#      so we reach the release chain and fail exactly there. With global
#      unreachability this case passes without ever entering the block it
#      claims to test.
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" MOCK_UNREACH_RELEASES=1 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -qE "daemon .*CANNOT-VERIFY" \
   && ! printf '%s' "$OUT" | grep -q "RED no-published-release"; then
    ok "(c7) release lookup unreachable -> daemon CANNOT-VERIFY, not a false RED"
else
    bad "(c7) daemon release unreachable: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (c8)-(c10) DAEMON RECENCY -- the fifth link (task #328).
#
# The seven cases above all break the PROVENANCE chain. Not one of them makes
# the daemon BEHIND its own main, so until now this suite could not tell the
# difference between "the shipped daemon is coherent" and "the shipped daemon
# is current". It was green on 2026-08-12 while the real gate scored pin
# hub-v0.4.54 @ 782a6195 as "FRESH tag+sha256+build-info" with oa main 29
# commits ahead at 10b003a0 -- the WhatsApp merge. Eighteen passing cases and
# the launch-blocking hole sat in the gap between them.
# ===========================================================================
# (c8) daemon behind oa main, NO hold_ack -> exit 1, names the lag
reset_defaults; build_fixture
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_HEAD_ostler_ai_ostler_assistant_main="$OA_MAIN_AHEAD" \
  MOCK_CMP_aaaaaaaa_eeeeeeee="ahead 3 0" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE "daemon .*RED STALE:\+3" \
   && printf '%s' "$OUT" | grep -q "NO hold_ack"; then
    ok "(c8) daemon behind oa main, no hold_ack -> exit 1, RED STALE"
else
    bad "(c8) daemon-behind-head: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c9) same lag, hold_ack covers the WHOLE delta + grafted=true -> exit 0 HELD
reset_defaults; build_fixture
printf 'aaaaaaaa\t%s %s %s\ttrue\tv1.1 daemon work, no shipping bugfix held\n' \
    "$D1" "$D2" "$D3" > "$FIXROOT/scripts/daemon_hold_ack.tsv"
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_HEAD_ostler_ai_ostler_assistant_main="$OA_MAIN_AHEAD" \
  MOCK_CMP_aaaaaaaa_eeeeeeee="ahead 3 0" \
  MOCK_CMPDELTA_aaaaaaaa_eeeeeeee="$(printf '%s\n%s\n%s' "$D1" "$D2" "$D3")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE "daemon .*HELD hold_ack" \
   && printf '%s' "$OUT" | grep -q "GATE: GREEN"; then
    ok "(c9) daemon lag + hold_ack covers whole delta -> exit 0, HELD"
else
    bad "(c9) daemon hold_ack full: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# (c10) same lag, hold_ack MISSING one delta sha -> exit 1, names ONLY that one
reset_defaults; build_fixture
printf 'aaaaaaaa\t%s %s\ttrue\tpartial ack\n' "$D1" "$D2" \
    > "$FIXROOT/scripts/daemon_hold_ack.tsv"
OUT="$(run_gate "${FULL_FRESH_ENV[@]}" \
  MOCK_HEAD_ostler_ai_ostler_assistant_main="$OA_MAIN_AHEAD" \
  MOCK_CMP_aaaaaaaa_eeeeeeee="ahead 3 0" \
  MOCK_CMPDELTA_aaaaaaaa_eeeeeeee="$(printf '%s\n%s\n%s' "$D1" "$D2" "$D3")" \
  2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "daemon RED: delta commit(s) NOT in hold_ack_shas" \
   && printf '%s' "$OUT" | grep -q "d3d3d3d3d3d3" \
   && ! printf '%s' "$OUT" | grep -qE "hold_ack_shas:.*d1d1d1d1d1d1"; then
    ok "(c10) daemon lag + hold_ack missing a delta sha -> exit 1, names ONLY d3"
else
    bad "(c10) daemon hold_ack partial: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
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
    # ...and it must say NETWORK, not credentials. (e) and (m) share an exit
    # code and must not share an explanation: if both print the same remedy the
    # cause-naming added for run 31685172775 is decorative, and the operator is
    # sent at the wrong thing exactly as before.
    if printf '%s' "$OUT" | grep -q "Restore network" \
       && ! printf '%s' "$OUT" | grep -q "SOURCE REPO could not be read"; then
        ok "(e2) unreachable names the NETWORK, not a credential -- (e) and (m) discriminate"
    else
        bad "(e2) unreachable and unreadable print the same explanation"
        printf '%s\n' "$OUT" | sed 's/^/      /'
    fi
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

# ===========================================================================
# (m) SOURCE REPO UNREADABLE -> exit 3 CANNOT-VERIFY, and specifically NOT a
#     RED that accuses the pin.  (v1018-D621c)
#
# Cut run 31682172040 printed fifteen vendor trees as "RED unresolved" --
# byte-identical, which is the shape of a broken probe, not fifteen
# independently broken pins. Every one of those pins resolved by hand with an
# account that HAS access. The gate was reading a permissions 404 on the
# COMMITS endpoint and asserting "bad pin" from evidence that says only "I
# cannot see that repo".
#
# This control pins the DISTINCTION, not the wording: unreadable must land in
# the cannot-verify bucket AND must not claim the pin is bad. Asserting only
# "says CANNOT-VERIFY" would still pass if the gate ALSO emitted a RED row.
# ===========================================================================
reset_defaults
build_fixture
# NOTE the deliberate absence of a MOCK_HEAD_* for this repo. An unreadable
# repo 404s on the commits endpoint too -- that is the whole reason the two
# states were indistinguishable. Supplying a working commit lookup alongside
# an unreadable repo would model a state GitHub cannot be in, and this control
# would then have passed against the UNPATCHED gate (verified: it scored a
# false GREEN, exit 0, instead of the production symptom).
OUT="$(run_gate FRESHNESS_ONLY="cm041/contact_syncer" \
  MOCK_UNREADABLE_andygmassey_CM041_People_Graph=1 \
  2>&1)"; RC=$?
if [ "$RC" -eq 3 ] \
   && printf '%s' "$OUT" | grep -q "CANNOT-VERIFY unreadable-source" \
   && printf '%s' "$OUT" | grep -q "andygmassey/CM041-People-Graph" \
   && printf '%s' "$OUT" | grep -q "stale/RED=0" \
   && ! printf '%s' "$OUT" | grep -q "RED unresolved"; then
    ok "(m) unreadable source repo -> exit 3 CANNOT-VERIFY, no RED against the pin"
else
    bad "(m) unreadable-source: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# The SUMMARY line must name the right CAUSE, not just the right exit code.
# It used to say "(unreachable)" and "Restore network + re-run" for every
# cannot-verify. On cut run 31685172775 fifteen trees landed here for want of
# a credential, and were told to fix the network -- an accurate exit code
# wearing the wrong explanation, which sends the operator at the wrong thing.
# Reuses $OUT from (m): same run, different assertion.
if printf '%s' "$OUT" | grep -q "SOURCE REPO could not be read" \
   && printf '%s' "$OUT" | grep -q "Do NOT re-pin them" \
   && ! printf '%s' "$OUT" | grep -q "Restore network"; then
    ok "(m2) the exit-3 SUMMARY names the credential cause, not the network"
else
    bad "(m2) summary names the wrong cause for an unreadable repo"
    printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# ===========================================================================
# (n) READABLE repo, pinned SHA genuinely ABSENT -> STILL exit 1 RED.
#
# The other direction, and the one that actually matters. Andy's constraint on
# this fix: "a fix that turns a real bad pin into CANNOT-VERIFY is worse than
# the bug." A cannot-verify bucket that quietly swallows real bad pins is the
# warn-bucket-is-not-a-safe-bucket move -- the cut would go out on a pin that
# does not exist, and the gate would report it as merely unchecked.
#
# Same fixture as (m) with ONE variable changed: the repo is readable, and the
# commit lookup 404s. If (m) and (n) ever print the same verdict the probe has
# stopped discriminating, which is exactly the failure being fixed here.
# ===========================================================================
reset_defaults; T1_PIN="$SHA_OLD"
build_fixture
OUT="$(run_gate FRESHNESS_ONLY="cm041/contact_syncer" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q "RED unresolved" \
   && printf '%s' "$OUT" | grep -q "the source repo IS readable" \
   && ! printf '%s' "$OUT" | grep -q "CANNOT-VERIFY"; then
    ok "(n) readable repo + absent SHA -> STILL exit 1 RED, not reclassified"
else
    bad "(n) absent-sha-still-red: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

echo
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
