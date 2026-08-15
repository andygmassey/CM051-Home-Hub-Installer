#!/bin/bash
# ==========================================================================
# test_memory_embeddings_wired.sh
#
# THE ASSISTANT'S MEMORY IS TWO HALVES AND ONLY ONE OF THEM IS LOUD.
#
# Phase 3 installs nomic-embed-text and a healthcheck POSTs to /api/embed and
# HARD-FAILS the install unless real vectors come back. That half is noisy and
# cannot regress unnoticed.
#
# The other half is four echo lines that write a [memory] section into
# config.toml. Delete them and NOTHING fails. The daemon falls back to its
# schema default embedding_provider "none", through create_embedding_provider's
# fallback arm to NoopEmbedding, whose dimensions() is 0, which makes
# get_or_compute_embedding return Ok(None), which makes store() write a NULL
# embedding and REPORT SUCCESS. On a real box: memories populated, FTS
# populated, every embedding column NULL, embedding_cache at 0 rows. A fact
# stated at 21:08 could not be retrieved at 21:13 on the same channel, and
# every layer returned success.
#
# WHY THIS FILE EXISTS. On 2026-08-15 a PR whose subject was a consent label
# arrived at +21/-65 on install.sh. The 64 unmentioned deletions were this
# block and the parity check below it. Thirteen checks passed. Nothing in
# tests/, .github/workflows/ or scripts/ mentioned embedding_provider at all,
# so the deletion was invisible to the whole board. The fix shipped without a
# regression test, which is the only reason removing it could read green.
#
# The instrument and the defect share a surface deliberately: this reads
# install.sh, the artefact that ships and writes the config, not a doc about
# it.
#
# Usage:
#   test_memory_embeddings_wired.sh [path-to-install.sh]
#   test_memory_embeddings_wired.sh --selftest
#
# --selftest mutates COPIES in a temp dir and asserts the predicate goes red on
# each known-bad shape, plus stays green on the real tree. A gate with only a
# positive control cannot be told apart from one that is broken shut, and a
# gate with only negative controls cannot be told apart from one that is broken
# open. Both directions are exercised.
#
# Exit codes:
#   0  every assertion passed
#   1  an assertion failed (the defect is present)
#   2  CANNOT RUN (target missing or unreadable) -- never reported as a pass,
#      because 0 failures over 0 assertions looks identical to clean
# ==========================================================================

set -uo pipefail

# HERE derives from THIS FILE's own path, so running a copy from /tmp resolves
# every target outside the repo and produces a clean-looking result off an
# artefact that is not the one under test. Run it in place.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SELFTEST_TMP=""

# The dimensions nomic-embed-text actually emits. Written into config.toml AND
# asserted by the install-time parity check, so the two literals must agree.
EXPECTED_DIMS=768

check_file() {
    local f="$1"
    local failures=0
    local examined=0

    if [[ ! -f "$f" ]]; then
        echo "CANNOT RUN: no such file: $f" >&2
        return 2
    fi
    if [[ ! -s "$f" ]]; then
        echo "CANNOT RUN: file is empty: $f" >&2
        return 2
    fi

    # ---- 1. the section header is written at all -------------------------
    examined=$((examined + 1))
    local section_count
    section_count=$(grep -c 'echo "\[memory\]"' "$f")
    if [[ "$section_count" -lt 1 ]]; then
        echo "FAIL [memory-section]: install.sh never writes a [memory] section."
        echo "   Without it the daemon uses embedding_provider \"none\", stores NULL"
        echo "   embeddings, reports success, and the assistant cannot recall anything."
        failures=$((failures + 1))
    elif [[ "$section_count" -gt 1 ]]; then
        echo "FAIL [memory-section]: [memory] is written $section_count times."
        echo "   A second section silently overrides the first in TOML order."
        failures=$((failures + 1))
    else
        echo "PASS [memory-section]: config.toml gets exactly one [memory] section"
    fi

    # ---- 2. the provider is a real one, not the schema default -----------
    #
    # Asserting "the line exists" is not enough: embedding_provider = "none" is
    # a line that exists and is exactly the defect. Read the VALUE.
    examined=$((examined + 1))
    local provider_line
    provider_line=$(grep 'echo "embedding_provider' "$f" | head -1)
    if [[ -z "$provider_line" ]]; then
        echo "FAIL [provider]: no embedding_provider is written."
        failures=$((failures + 1))
    elif printf '%s' "$provider_line" | grep -qE 'embedding_provider *= *\\?"none\\?"'; then
        echo "FAIL [provider]: embedding_provider is written as \"none\"."
        echo "   That is the daemon's own schema default and routes to NoopEmbedding."
        failures=$((failures + 1))
    elif ! printf '%s' "$provider_line" | grep -q 'custom:'; then
        echo "FAIL [provider]: embedding_provider does not name a custom: endpoint."
        echo "   line: $provider_line"
        failures=$((failures + 1))
    else
        echo "PASS [provider]: embedding_provider points at a real custom: endpoint"
    fi

    # ---- 3. a model is named ---------------------------------------------
    examined=$((examined + 1))
    if grep -q 'echo "embedding_model' "$f"; then
        echo "PASS [model]: embedding_model is written"
    else
        echo "FAIL [model]: no embedding_model is written."
        failures=$((failures + 1))
    fi

    # ---- 4. dimensions are written, and are a positive integer -----------
    examined=$((examined + 1))
    local dims_written
    dims_written=$(grep 'echo "embedding_dimensions' "$f" | head -1 | grep -oE '[0-9]+' | tail -1)
    if [[ -z "$dims_written" ]]; then
        echo "FAIL [dimensions]: no embedding_dimensions is written."
        echo "   The schema default is 1536 (text-embedding-3-small), which mis-sizes"
        echo "   every vector nomic-embed-text produces."
        failures=$((failures + 1))
    elif [[ "$dims_written" -le 0 ]]; then
        echo "FAIL [dimensions]: embedding_dimensions is not a positive integer: $dims_written"
        failures=$((failures + 1))
    else
        echo "PASS [dimensions]: embedding_dimensions = $dims_written"
    fi

    # ---- 5. the install-time parity check still exists -------------------
    #
    # The written width is an ASSUMPTION until something measures it. The
    # install already has a real vector in hand from the healthcheck, so it
    # counts that vector rather than trusting the constant. Deleting this
    # check is silent by construction: a wrong width degrades recall without
    # ever erroring.
    examined=$((examined + 1))
    if grep -q 'EMBED_DIMS_ACTUAL' "$f"; then
        echo "PASS [parity-check]: the install measures the real vector width"
    else
        echo "FAIL [parity-check]: the embedding dimension parity check is gone."
        echo "   Nothing verifies that the model emits the width we configured,"
        echo "   and a mismatch degrades recall without producing an error."
        failures=$((failures + 1))
    fi

    # ---- 6. the two literals agree ---------------------------------------
    #
    # config.toml gets one hardcoded width and the parity check compares
    # against another. Change the model and edit only one, and the install
    # passes its own check while writing the wrong number.
    examined=$((examined + 1))
    local dims_asserted
    dims_asserted=$(grep -A2 'if \[\[ -z "\$EMBED_DIMS_ACTUAL" \]\]' "$f" | grep -oE 'EMBED_DIMS_ACTUAL" != "[0-9]+"' | grep -oE '[0-9]+' | head -1)
    if [[ -z "$dims_asserted" ]]; then
        dims_asserted=$(grep -oE 'EMBED_DIMS_ACTUAL" != "[0-9]+"' "$f" | grep -oE '[0-9]+' | head -1)
    fi
    if [[ -z "$dims_asserted" ]]; then
        echo "FAIL [literals-agree]: could not find the width the parity check asserts."
        failures=$((failures + 1))
    elif [[ -z "$dims_written" ]]; then
        echo "FAIL [literals-agree]: no written width to compare against."
        failures=$((failures + 1))
    elif [[ "$dims_written" != "$dims_asserted" ]]; then
        echo "FAIL [literals-agree]: config writes $dims_written, parity check asserts $dims_asserted."
        echo "   The install would pass its own check while configuring the wrong width."
        failures=$((failures + 1))
    elif [[ "$dims_written" != "$EXPECTED_DIMS" ]]; then
        echo "FAIL [literals-agree]: both say $dims_written, but this gate expects $EXPECTED_DIMS."
        echo "   If the embedding model changed, update EXPECTED_DIMS here in the same"
        echo "   commit, so the change is deliberate rather than drift."
        failures=$((failures + 1))
    else
        echo "PASS [literals-agree]: config and parity check both say $dims_written"
    fi

    # ---- verdict, with the denominator stated ----------------------------
    echo
    echo "examined $examined assertions against $f"
    if [[ "$examined" -eq 0 ]]; then
        echo "REFUSING: nothing was examined, which is not the same as clean." >&2
        return 2
    fi
    if [[ "$failures" -gt 0 ]]; then
        echo "$failures of $examined FAILED"
        return 1
    fi
    echo "all $examined passed"
    return 0
}

# ==========================================================================
# selftest: prove the predicate discriminates, in BOTH directions
# ==========================================================================
selftest() {
    local real="$HERE/install.sh"
    if [[ ! -f "$real" ]]; then
        echo "CANNOT RUN SELFTEST: $real is missing" >&2
        return 2
    fi

    # NOT `local`. The EXIT trap fires after this function has returned, so a
    # local would be out of scope by then: under `set -u` that is an unbound
    # variable error at exit and the temp dir survives. Global, cleaned by a
    # trap that can still see it.
    SELFTEST_TMP="$(mktemp -d)"
    trap 'rm -rf "${SELFTEST_TMP:-}"' EXIT
    local tmp="$SELFTEST_TMP"

    local controls=0
    local bad=0

    # -- positive control: the real tree must PASS -------------------------
    # Without this, a gate that fails everything would score full marks on the
    # negative controls alone.
    controls=$((controls + 1))
    if check_file "$real" >/dev/null 2>&1; then
        echo "PASS [control-positive]: the real install.sh passes"
    else
        echo "FAIL [control-positive]: the real install.sh does NOT pass."
        echo "   Either the tree is broken or this gate is broken shut. Run it"
        echo "   directly to see which:  bash tests/test_memory_embeddings_wired.sh"
        bad=$((bad + 1))
    fi

    # -- negative control 1: the whole section deleted ---------------------
    # This is the exact shape of the 2026-08-15 near-miss.
    controls=$((controls + 1))
    grep -v 'echo "\[memory\]"' "$real" > "$tmp/no_section.sh"
    if check_file "$tmp/no_section.sh" >/dev/null 2>&1; then
        echo "FAIL [control-no-section]: deleting the [memory] section still PASSES."
        bad=$((bad + 1))
    else
        echo "PASS [control-no-section]: deleting the [memory] section is caught"
    fi

    # -- negative control 2: provider downgraded to the schema default -----
    # The line still exists. Only the value is wrong, which is the version of
    # this defect a line-presence check cannot see.
    controls=$((controls + 1))
    sed 's|echo "embedding_provider = .*|echo "embedding_provider = \\"none\\""|' "$real" > "$tmp/provider_none.sh"
    if check_file "$tmp/provider_none.sh" >/dev/null 2>&1; then
        echo "FAIL [control-provider-none]: embedding_provider=\"none\" still PASSES."
        bad=$((bad + 1))
    else
        echo "PASS [control-provider-none]: provider \"none\" is caught"
    fi

    # -- negative control 3: parity check removed --------------------------
    controls=$((controls + 1))
    grep -v 'EMBED_DIMS_ACTUAL' "$real" > "$tmp/no_parity.sh"
    if check_file "$tmp/no_parity.sh" >/dev/null 2>&1; then
        echo "FAIL [control-no-parity]: removing the parity check still PASSES."
        bad=$((bad + 1))
    else
        echo "PASS [control-no-parity]: removing the parity check is caught"
    fi

    # -- negative control 4: the two literals disagree ---------------------
    controls=$((controls + 1))
    sed 's|echo "embedding_dimensions = 768"|echo "embedding_dimensions = 1536"|' "$real" > "$tmp/dims_drift.sh"
    if check_file "$tmp/dims_drift.sh" >/dev/null 2>&1; then
        echo "FAIL [control-dims-drift]: config 1536 vs parity 768 still PASSES."
        bad=$((bad + 1))
    else
        echo "PASS [control-dims-drift]: a width disagreement is caught"
    fi

    # -- negative control 5: missing target must REFUSE, not pass ----------
    controls=$((controls + 1))
    check_file "$tmp/does_not_exist.sh" >/dev/null 2>&1
    if [[ "$?" -eq 2 ]]; then
        echo "PASS [control-absent-target]: a missing target exits 2, not 0"
    else
        echo "FAIL [control-absent-target]: a missing target did not exit 2."
        echo "   An unreadable artefact reported as clean is the false green this"
        echo "   whole file exists to prevent."
        bad=$((bad + 1))
    fi

    echo
    echo "examined $controls controls"
    if [[ "$bad" -gt 0 ]]; then
        echo "$bad of $controls FAILED"
        return 1
    fi
    echo "all $controls passed"
    return 0
}

case "${1:-}" in
    --selftest)
        selftest
        exit $?
        ;;
    "")
        check_file "$HERE/install.sh"
        exit $?
        ;;
    *)
        check_file "$1"
        exit $?
        ;;
esac
