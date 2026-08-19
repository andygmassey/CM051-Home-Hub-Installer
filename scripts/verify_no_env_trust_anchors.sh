#!/usr/bin/env bash
#
# verify_no_env_trust_anchors.sh -- no shipping file, in ANY language, may read
# a verification key out of the process environment.
#
# PROVED-RED-BY: scripts/tests/test_no_env_trust_anchors.sh
#
# ============================================================================
# WHY THIS EXISTS, AND IT IS NOT HYPOTHETICAL
# ============================================================================
#
# gui/OstlerInstaller/Auth/LicenseVerifier.swift once opened init?() with:
#
#     if let override = ProcessInfo.processInfo.environment[
#             "OSTLER_LICENSE_PUBKEY_OVERRIDE"], override.count == 64 {
#         hex = override
#     }
#
# in the shipping, notarised binary. Checked FIRST, REPLACING the production
# key. The paywall fell to: mint a keypair, self-sign a licence, launch the
# installer with that variable set. It was deleted on 2026-08-16 and locked in
# by a source-text guard in LicenseVerifierTests.swift, whose assertion message
# states the principle exactly:
#
#     "Whatever the variable is called, a trust anchor the launching process
#      can set is not a trust anchor."
#
# THAT GUARD SCANS ONE SWIFT FILE. On 2026-08-17 the same construct was found
# alive in install.sh:1081 -- same variable name, same 64-hex rule, feeding
# _lic_pubkey straight into the Ed25519 verifier. Not a regression of the Swift
# fix: a sibling implementation written to match the Swift behaviour, mirroring
# the version that had already been deleted as a defect. Its comment still
# asserts parity with a Swift branch that no longer exists.
#
# A single-file guard cannot see a sibling in another language. This one asks
# the question across the estate, so the next mirror fails loudly instead of
# being written in good faith against a stale comment.
#
# ============================================================================
# WHAT IT ASSERTS
# ============================================================================
#
# An ANCHOR-SHAPED environment variable (pubkey / public_key / verify_key /
# signing_key / trust_anchor, any case) must not be read by shipping code.
# Tests may: injecting a key is how you prove a verifier rejects a forgery.
#
# EXEMPTIONS ARE VISIBLE AND REASONED, never silent. Same contract as
# verify_cut_freshness.sh's `verify_exempt = true` + `exempt_reason`: an
# exemption is a ledger row a reader can audit, not an absence they must infer.
# Add one only with a reason, and expect to justify it.
#
# EXIT
#   0  no unexempted anchor-shaped environment read in shipping code
#   1  at least one found (or an exemption whose file no longer matches)
#   2  could not run. NOT a pass.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" 2>/dev/null || { echo "CANNOT-RUN: cannot enter '$REPO'" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "CANNOT-RUN: not a git repository: $REPO" >&2; exit 2; }

# Anchor-shaped names. Deliberately about the ROLE, not one variable: the Swift
# guard's whole point is that the name is not what makes it dangerous.
ANCHOR_RE='(PUBKEY|PUBLIC_KEY|VERIFY_KEY|VERIFICATION_KEY|SIGNING_KEY|TRUST_ANCHOR)'

# A READ of that name out of the environment. Shell ${VAR...} / $VAR, Swift
# ProcessInfo environment subscript, Python os.environ, Rust env::var.
READ_RE="(\\\$\\{?[A-Z_]*${ANCHOR_RE}[A-Z_]*|environment\\[\"[A-Za-z_]*${ANCHOR_RE}|environ(\\.get)?[\\(\\[][\"'][A-Za-z_]*${ANCHOR_RE}|env::var\\([\"'][A-Za-z_]*${ANCHOR_RE})"

# ---------------------------------------------------------------------------
# EXEMPTIONS. file<TAB>reason. Checked, not trusted: an exemption whose file no
# longer contains a match is itself a failure, so a stale row cannot quietly
# widen the allowlist after the code it excused has moved on.
# ---------------------------------------------------------------------------
EXEMPT_FILES=("install.sh")
EXEMPT_WHY=("OSTLER_LICENSE_PUBKEY_OVERRIDE at :1081 is the ONLY test seam the shell gate has -- OSTLER_LICENCE_PUBKEY at :986 is a baked assignment, not a \${VAR:-default}, so it cannot be injected. tests/test_licence_gate.sh:364 depends on the override. The Swift side removed its equivalent only because init(publicKey:) already existed as a compile-time seam; the shell has no such seam yet. HELD, NOT BLESSED: see #733. Whether this gate is load-bearing or advisory is Andy's call, and the exemption goes when the seam does.")

is_exempt() { # is_exempt <path> -> 0 if listed
    local p="$1" i
    for i in "${!EXEMPT_FILES[@]}"; do
        [ "$p" = "${EXEMPT_FILES[$i]}" ] && return 0
    done
    return 1
}

# Shipping files only. Tests are excluded BY PATH and that is the one thing a
# reader should check hardest: widening this filter is how the gate goes blind.
mapfile -t FILES < <(git ls-files \
    | grep -E '\.(sh|swift|py|rs)$' \
    | grep -vE '(^|/)tests?/' \
    | grep -vE 'Tests?\.swift$' \
    | grep -vE '_test\.(py|rs|sh)$' \
    | sort)

[ "${#FILES[@]}" -gt 0 ] || { echo "CANNOT-RUN: enumerated zero shipping files -- the filter is wrong, not the tree" >&2; exit 2; }

VIOLATIONS=0
HELD=0
declare -a HIT_FILES=()

for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    n="$(grep -cE "$READ_RE" "$f" 2>/dev/null || true)"
    [ "${n:-0}" -gt 0 ] || continue
    HIT_FILES+=("$f")
    if is_exempt "$f"; then
        HELD=$((HELD+1))
        printf '  HELD       %-46s %s match(es)\n' "$f" "$n"
    else
        VIOLATIONS=$((VIOLATIONS+1))
        printf '  VIOLATION  %-46s %s match(es)\n' "$f" "$n"
        grep -nE "$READ_RE" "$f" | sed 's/^/               /' >&2
    fi
done

echo
echo "scanned ${#FILES[@]} shipping files (.sh .swift .py .rs, tests excluded by path)"
echo "anchor-shaped environment reads: held=${HELD}  violations=${VIOLATIONS}"

# Every exemption must still MATCH something. A row excusing a file that no
# longer has the construct is a widened allowlist nobody voted for -- the
# stale-guard shape this estate keeps finding.
#
# ONLY WHEN SCANNING THIS REPO. The exemption list names paths in THIS tree, so
# against any other tree every row is "stale" by construction. The first version
# of this block did not scope it, and the self-test caught it immediately: three
# controls that should have been GREEN went red on fixtures that simply are not
# this repository. A gate usable on exactly one directory cannot be driven by a
# fixture, and a gate that cannot be driven by a fixture cannot be proved to say
# no -- which is the whole reason this file has a PROVED-RED-BY header.
STALE=0
SELF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(cd "$REPO" && pwd)" = "$SELF_REPO" ]; then
    for i in "${!EXEMPT_FILES[@]}"; do
        e="${EXEMPT_FILES[$i]}"
        found=0
        for h in "${HIT_FILES[@]:-}"; do [ "$h" = "$e" ] && found=1; done
        if [ "$found" -eq 0 ]; then
            echo "  STALE EXEMPTION: $e no longer contains an anchor-shaped read -- delete the row" >&2
            STALE=$((STALE+1))
        fi
    done
fi

if [ "$HELD" -gt 0 ]; then
    echo
    echo "HELD, with reasons:"
    for i in "${!EXEMPT_FILES[@]}"; do
        printf '  %s\n' "${EXEMPT_FILES[$i]}"
        printf '%s\n' "${EXEMPT_WHY[$i]}" | fold -s -w 72 | sed 's/^/      /'
    done
fi

if [ "$VIOLATIONS" -gt 0 ] || [ "$STALE" -gt 0 ]; then
    echo
    echo "GATE: RED -- a trust anchor the launching process can set is not a trust anchor." >&2
    echo "  Inject through a compile-time or call-time seam instead. If the construct is" >&2
    echo "  genuinely required, add it to EXEMPT_FILES with a reason that will survive" >&2
    echo "  being read back in six months." >&2
    exit 1
fi

echo "GATE: GREEN -- no unexempted anchor-shaped environment read in shipping code."
exit 0
