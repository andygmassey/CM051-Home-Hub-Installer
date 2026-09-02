#!/usr/bin/env bash
# probes/assistant_prompt_names_every_pwg_tool.sh
# ============================================================================
# QUESTION: does the SHIPPED daemon's system prompt actually NAME every
# personal-graph tool it registers -- in the branch a customer receives?
#
# WHY IT MATTERS (#854). A tool the model is never told about cannot be chosen.
# It is registered, it is protected from prompt slimming, it answers correctly
# when called, and it is unreachable. Measured on the pin c6fc48c0:
#
#     REGISTERED   pwg_people pwg_preferences pwg_knowledge_search
#                  pwg_overview pwg_person_timeline pwg_decisions
#                  pwg_topics pwg_commitments                        = 8
#     NAMED IN THE PROMPT                                            = 3
#
# The five unnamed ones included `pwg_overview`, which exists for exactly one
# purpose: to catch a broad opening question. With nothing pointing at it, a
# broad question had nothing to bind to and was coerced into a person lookup.
# One such coercion resolved "summarise my recent meetings" to a component
# supplier -- a customer-visible wrong answer produced by a correct tool.
#
# 🔴 THE THING THAT MAKES THIS PROBE HARD, AND THE REASON IT IS WRITTEN THIS WAY
#
# The obvious predicate -- "is the string pwg_overview in the daemon binary?"
# -- CANNOT FAIL. Every tool name is compiled in by the tool's own `fn name()`,
# so all eight are present in the binary whether or not the prompt mentions a
# single one. That predicate would have returned green on the exact build that
# shipped the defect. It measures the tool registry and reports it as prompt
# coverage.
#
# So this probe does not look for tool NAMES in the binary. It extracts the
# GUIDANCE PARAGRAPH by an anchor phrase that appears nowhere except the prompt,
# and then requires all eight names to appear INSIDE that paragraph. A name can
# only satisfy it by being in the guidance the model is handed.
#
# 🔴 AND IT READS THE COMPACT BRANCH, WHICH IS THE ONE THAT SHIPS
#
# `compact_context` defaults to TRUE. The verbose sections are behind
# `if !compact_context` and a customer does not receive them. A fix applied to
# the verbose branch alone is correct in the file and absent on the box, and it
# would test green against any reader that did not know which branch runs. The
# anchor below is deliberately a COMPACT-branch phrase.
#
# CANNOT-RUN is not FAIL here. If the binary is absent, unreadable, or carries
# no recognisable prompt, this probe says so and refuses to report a verdict.
# "I could not look" and "I looked and it was fine" must not print the same.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/probe.sh"

PROBE_NAME="assistant_prompt_names_every_pwg_tool"
PROBE_QUESTION="does the shipped system prompt name every registered pwg_* tool, in the branch a customer actually receives?"

DAEMON_BIN="${OSTLER_DAEMON_BIN:-\$HOME/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant}"

# Every pwg_* tool the runtime registers. These are registered together behind
# a single `pwg_people.enabled` gate, so the set moves as one. If a ninth is
# added and not added here, the floor assertion below is what catches it.
REQUIRED_TOOLS="pwg_overview pwg_people pwg_person_timeline pwg_preferences pwg_knowledge_search pwg_decisions pwg_topics pwg_commitments"
DECLARED_TOOL_COUNT=8

# The anchor. A phrase that exists ONLY in the compact-branch guidance
# paragraph -- not in any tool description, not in the registry, not in a
# comment that reaches the binary. Chosen by reading the shipped prompt text,
# not by recall.
COMPACT_ANCHOR='For a BROAD opener about the user'

# ---------------------------------------------------------------------------
# adjudicate_prompt_blob <blob>
#
# A named function over TEXT, so the self-test drives this exact logic without
# needing a box or a binary. Echoes one of:
#   NO_ANCHOR                 -- no guidance paragraph found (CANNOT-RUN)
#   MISSING:<t1,t2,...>       -- paragraph found, these tools are not named
#   ALL_NAMED                 -- paragraph found and every tool is named in it
# ---------------------------------------------------------------------------
adjudicate_prompt_blob() {
    _blob="$1"

    # Extract the single line carrying the anchor. Rust stores the paragraph as
    # one contiguous literal, so the guidance arrives as one `strings` run.
    _para="$(printf '%s\n' "$_blob" | grep -F "$COMPACT_ANCHOR" | head -1)"
    if [ -z "$_para" ]; then
        echo "NO_ANCHOR"
        return
    fi

    _missing=""
    for _t in $REQUIRED_TOOLS; do
        case "$_para" in
            *"$_t"*) : ;;
            *) _missing="${_missing}${_missing:+,}${_t}" ;;
        esac
    done

    if [ -n "$_missing" ]; then
        echo "MISSING:${_missing}"
    else
        echo "ALL_NAMED"
    fi
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the shipped prompt was never read"

    # Anti-vacuity on the tool list itself. An empty or shrunken REQUIRED_TOOLS
    # would make every assertion below trivially satisfiable.
    _n=0
    for _t in $REQUIRED_TOOLS; do _n=$(( _n + 1 )); done
    if [ "$_n" -ne "$DECLARED_TOOL_COUNT" ]; then
        probe_cannot_run "the probe's own tool list holds ${_n} entries but declares ${DECLARED_TOOL_COUNT}; refusing to grade the prompt against a list that has drifted"
    fi

    box_run "test -f \"${DAEMON_BIN}\"" >/dev/null 2>&1 \
        || probe_cannot_run "no daemon binary at ${DAEMON_BIN}; the shipped prompt cannot be read (coverage lost, NOT a pass)"

    # `strings` over the shipped Mach-O. Read the ARTEFACT, never the source
    # tree -- the tree is not what the customer runs.
    _blob="$(box_run "strings -a \"${DAEMON_BIN}\" 2>/dev/null | grep -F '${COMPACT_ANCHOR}' | head -1")"

    if [ -z "$_blob" ]; then
        # MUST-HIT CONTROL. Prove the binary is readable AND carries prompt text
        # at all, so a missing anchor is attributable rather than ambiguous.
        _sanity="$(box_run "strings -a \"${DAEMON_BIN}\" 2>/dev/null | grep -c -F '## Personal Data'")"
        _sanity="$(printf '%s' "${_sanity:-0}" | tr -cd '0-9')"
        probe_examined 0 "guidance paragraphs found in the shipped binary"
        if [ "${_sanity:-0}" -eq 0 ]; then
            probe_cannot_run "could not read any prompt text out of ${DAEMON_BIN} (the '## Personal Data' control also scored 0), so this is an unreadable artefact, not a measured absence"
        fi
        probe_fail "the shipped binary carries prompt text ('## Personal Data' found) but NOT the compact-branch guidance anchor. Either the compact branch no longer names the personal-graph tools, or the guidance moved and this probe's anchor is stale -- both need a human, and neither is a pass (#854)"
    fi

    _verdict="$(adjudicate_prompt_blob "$_blob")"
    probe_examined "$DECLARED_TOOL_COUNT" "registered pwg_* tools checked against the SHIPPED compact-branch prompt"

    case "$_verdict" in
        NO_ANCHOR)
            probe_cannot_run "the guidance paragraph could not be isolated from the binary; nothing was graded"
            ;;
        MISSING:*)
            probe_fail "the shipped compact prompt does not name: ${_verdict#MISSING:} -- compact_context defaults to true, so this IS the branch customers receive and those tools are unreachable however well they work when called (#854)"
            ;;
        ALL_NAMED)
            probe_note "anchor: ${COMPACT_ANCHOR}"
            probe_pass "all ${DECLARED_TOOL_COUNT} registered pwg_* tools are named inside the shipped compact-branch guidance paragraph"
            ;;
        *)
            probe_fail "adjudicator returned an unrecognised verdict '${_verdict}'"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# SELF-TEST -- INVERTED BY CONVENTION.
#   exit 1 (probe_fail)  = every control fired => the probe is HEALTHY
#   exit 0 (probe_pass)  = a control did NOT fire => the probe is BROKEN
# ---------------------------------------------------------------------------
self_test() {
    probe_examined 6 "crafted prompt fixtures driven through adjudicate_prompt_blob"

    _sf() { probe_pass "SELF-TEST CONTROL FAILED -- $1"; }

    _all="Some unrelated string
For a BROAD opener about the user, call \`pwg_overview\` FIRST. For a person call \`pwg_people\`; history \`pwg_person_timeline\`. Tastes \`pwg_preferences\`. Notes \`pwg_knowledge_search\`. Decisions \`pwg_decisions\`; topics \`pwg_topics\`; owed \`pwg_commitments\`.
Trailing noise"

    # 1. The healthy shape passes.
    _r="$(adjudicate_prompt_blob "$_all")"
    [ "$_r" = "ALL_NAMED" ] || _sf "a fully-named guidance paragraph adjudicated as '${_r}', expected ALL_NAMED. A correct build would be reported as defective."

    # 2. THE DEFECT THIS PROBE EXISTS FOR: the five tools unnamed, exactly as
    #    shipped before #854. Must be caught and must NAME them.
    _pre854="For a BROAD opener about the user, ignore that. For a person call \`pwg_people\`. Tastes \`pwg_preferences\`. Notes \`pwg_knowledge_search\`."
    _r="$(adjudicate_prompt_blob "$_pre854")"
    case "$_r" in
        MISSING:*) : ;;
        *) _sf "the pre-#854 prompt (3 of 8 named) adjudicated as '${_r}', expected MISSING. This probe would have passed the build that shipped the defect." ;;
    esac
    for _t in pwg_overview pwg_person_timeline pwg_decisions pwg_topics pwg_commitments; do
        case "$_r" in
            *"$_t"*) : ;;
            *) _sf "the pre-#854 verdict '${_r}' does not name the absent tool ${_t}; an operator could not act on it." ;;
        esac
    done

    # 3. 🔴 THE DISCRIMINATION THAT MATTERS. A binary whose tool NAMES are all
    #    present (they always are -- `fn name()` compiles them in) but whose
    #    GUIDANCE names none of them must FAIL. If this collapses, the probe is
    #    measuring the tool registry and reporting it as prompt coverage, and
    #    it would be green on the defective build.
    _registry_only="pwg_overview
pwg_people
pwg_person_timeline
pwg_preferences
pwg_knowledge_search
pwg_decisions
pwg_topics
pwg_commitments
For a BROAD opener about the user, do something unrelated."
    _r="$(adjudicate_prompt_blob "$_registry_only")"
    case "$_r" in
        MISSING:*) : ;;
        *) _sf "a binary carrying every tool NAME but naming none of them in the guidance adjudicated as '${_r}', expected MISSING. The probe is reading the tool registry, not the prompt -- it would pass the exact build that shipped #854." ;;
    esac

    # 4. VERBOSE-ONLY MUST NOT SATISFY IT. A fix applied to the branch that does
    #    not ship must not read as covered.
    _verbose_only="## What You Know About The User
For BROAD opening questions call the \`pwg_overview\` tool FIRST. Also \`pwg_people\` \`pwg_person_timeline\` \`pwg_preferences\` \`pwg_knowledge_search\` \`pwg_decisions\` \`pwg_topics\` \`pwg_commitments\`."
    _r="$(adjudicate_prompt_blob "$_verbose_only")"
    [ "$_r" = "NO_ANCHOR" ] || _sf "a VERBOSE-only prompt adjudicated as '${_r}', expected NO_ANCHOR. Naming the tools only in the branch that does not ship would read as covered."

    # 5. SILENCE IS NOT SUCCESS. Empty input is the shape a dropped ssh makes.
    _r="$(adjudicate_prompt_blob "")"
    [ "$_r" = "NO_ANCHOR" ] || _sf "empty input adjudicated as '${_r}', expected NO_ANCHOR. Silence would have read as a measurement."

    # 6. ONE MISSING TOOL IS STILL A FAILURE. A near-miss must not round to pass.
    _one_short="${_all//pwg_commitments/pwg_somethingelse}"
    _r="$(adjudicate_prompt_blob "$_one_short")"
    [ "$_r" = "MISSING:pwg_commitments" ] || _sf "a paragraph missing exactly one tool adjudicated as '${_r}', expected MISSING:pwg_commitments. A single dropped tool would be rounded away."

    probe_fail "controls fired on all 6 fixtures: healthy passes, the pre-#854 3-of-8 shape is caught AND names all five absent tools, a tool-registry-only binary does NOT satisfy the prompt predicate, verbose-only does not count as covered, silence is not read as a measurement, and a single missing tool is not rounded to pass"
}

probe_main "$@"
