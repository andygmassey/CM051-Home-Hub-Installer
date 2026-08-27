#!/usr/bin/env bash
# test_orphan_gate_empty_pr_list_needs_a_control.sh
#
# `gh pr list --state open` exits 0 with `[]` both when a repo genuinely has no
# open PRs AND when the token resolves but cannot see pull requests. Some auth
# failures raise an error and are caught; this one does not. Zero-with-no-error
# is therefore the shape a silent auth regression wears, and it is the shape
# that reads as a clean pass. #1166.
#
# So an empty open list now triggers a POSITIVE CONTROL: ask for one PR in ANY
# state. Every repo in the sweep has had a pull request, so a control that finds
# none means the listing measured nothing, not zero.
#
# HOW THIS RUNS WITHOUT A NETWORK
# A stub `gh` is put first on PATH. It answers `pr list` from a fixture and
# `auth token` with nothing, so the gate's token resolution is exercised too.
# The stub is the only way to reach the empty-but-authenticated branch, which
# a real unreachable repo cannot produce -- that path errors instead.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_no_orphaned_fixes.sh"
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t emptypr)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

mkstub() {   # $1 = how the /pulls control should answer: ok|blind
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
# stub gh: the open listing is always an empty page; the CONTROL is the variable
if [ "\$1" = "auth" ]; then exit 1; fi
# The open listing is ALWAYS an empty page -- the ambiguous shape.
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then printf '%s' '[]'; exit 0; fi
# ONE api handler, dispatching on PATH, so each mode models a real token:
#   ok        may read /pulls            -> a real zero is accepted
#   blind     refused everywhere         -> CANNOT VERIFY
#   metaonly  Metadata yes, /pulls NO    -> the #522 shape. A fine-grained PAT
#             ALWAYS has Metadata, so a control probing repo metadata passes
#             while the subject listing is refused.
if [ "\$1" = "api" ]; then
    case "\$2" in
        */pulls*)
            case '$1' in
                ok) printf '%s' '[]'; exit 0 ;;
                *)  echo "HTTP 403: Resource not accessible by personal access token" >&2; exit 1 ;;
            esac ;;
        *)
            case '$1' in
                blind) echo "HTTP 403" >&2; exit 1 ;;
                *)     printf '%s' 'someowner/somerepo'; exit 0 ;;
            esac ;;
    esac
fi
exit 0
STUB
    chmod +x "$TMP/bin/gh"
}

make_repo() {
    local r="$TMP/repo"
    rm -rf "$r" "$r.origin"; mkdir -p "$r.origin" "$r"
    git init -q --bare "$r.origin"; git init -q "$r"
    git -C "$r" remote add origin "$r.origin"
    git -C "$r" config user.email a@example.com; git -C "$r" config user.name a
    echo seed > "$r/seed.txt"; git -C "$r" add -A; git -C "$r" commit -qm seed
    git -C "$r" branch -M main; git -C "$r" push -q -u origin main
    printf '%s' "$r"
}

run() {
    local bl="$TMP/baseline.$$.$RANDOM"; : > "$bl"
    PATH="$TMP/bin:$PATH" \
    OSTLER_ORPHAN_GATE_PR_CONTROL=1 \
    OSTLER_CUT_DEFERRALS=/nonexistent OSTLER_EXPIRED_BASELINE="$bl" \
    OSTLER_ORPHAN_GATE_REPOS="AAA|$1|origin/main|someowner/somerepo" \
        bash "$GATE" 2>&1
}
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }

printf '== test_orphan_gate_empty_pr_list_needs_a_control ==\n'
R="$(make_repo)"

# (1) CONTROL FINDS NOTHING -> the empty open list is not a measurement.
mkstub blind
out="$(run "$R")"
has "CANNOT VERIFY" "$out" \
    && ok "empty list + token refused on /pulls -> CANNOT VERIFY, not a pass" \
    || bad "an empty list with a blind control read as a PASS -- the false green this exists to stop"
has "cannot read pull requests on someowner/somerepo" "$out" \
    && ok "the message names WHY, not just that it failed" \
    || bad "CANNOT VERIFY did not name the control"

# (2) CONTROL FINDS A PR -> the zero is real and must NOT fail.
mkstub ok
out="$(run "$R")"
if has "CANNOT VERIFY" "$out"; then
    bad "a REAL zero was rejected -- the control is too strict and will block clean cuts"
else
    ok "empty list + /pulls answers 200 (even empty) -> accepted as a real zero"
fi
has "a real zero" "$out" \
    && ok "the accepted zero SAYS it was controlled" \
    || bad "the accepted zero is silent about its control"

# (3) The per-owner token variable is READ. `someowner` -> SOMEOWNER.
#     Proven by the CANNOT VERIFY message naming the variable to set.
mkstub blind
out="$(run "$R")"
has "OSTLER_ORPHAN_GATE_TOKEN_SOMEOWNER" "$out" \
    && ok "the remedy names the per-owner variable for THIS owner" \
    || bad "the remedy does not name the owner-specific variable"

# (4) OFF BY DEFAULT, and that must be VISIBLE rather than assumed. The gate's
#     own fixtures use repos no token can read, so an always-on control turns
#     eight GREEN arms red. The cut enables it; nothing else does. If this arm
#     ever fails, the default flipped and orphan_gate_selftest.sh is about to
#     go red for a reason nobody will connect to this file.
mkstub blind
bl="$TMP/baseline.default.$RANDOM"; : > "$bl"
out="$(PATH="$TMP/bin:$PATH" OSTLER_CUT_DEFERRALS=/nonexistent \
       OSTLER_EXPIRED_BASELINE="$bl" \
       OSTLER_ORPHAN_GATE_REPOS="AAA|$R|origin/main|someowner/somerepo" \
       bash "$GATE" 2>&1)"
if has "CANNOT VERIFY" "$out"; then
    bad "the control ran WITHOUT being enabled -- it is on by default and will red the gate's own fixtures"
else
    ok "off unless OSTLER_ORPHAN_GATE_PR_CONTROL is set (the cut sets it)"
fi

# (5) THE #522 SHAPE, and the arm that proves the fix rather than the feature.
#     A fine-grained PAT ALWAYS carries Metadata: read -- it is mandatory for
#     any repo access -- and may carry no Pull requests permission at all. The
#     old control read repos/{owner}/{repo}, which needs only Metadata, so such
#     a token PASSED it and returned an empty list: the exact false green the
#     control exists to stop. The control now asks /pulls, which needs the
#     SAME permission the subject needs.
#
#     This stub grants metadata and refuses /pulls. It MUST be caught.
mkstub metaonly
out="$(run "$R")"
if has "CANNOT VERIFY" "$out"; then
    ok "metadata-only token is CAUGHT (the old repo-metadata control passed it)"
else
    bad "a metadata-only token passed -- the control still tests the wrong permission (#522)"
fi
has "cannot read pull requests on" "$out" \
    && ok "the message names the PERMISSION, not just the repo" \
    || bad "the failure does not name which permission was missing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
