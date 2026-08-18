#!/usr/bin/env bash
# The enrichment opt-in QUESTION must exist in the cut after v1.0.36.
#
# WHY THIS EXISTS, and why it is a gate rather than a backlog row.
#
# Andy, 2026-08-18: "users must EXPLICITLY decide whether public-data
# enrichment runs. Not a default-on setting." Then, on being told the agent
# would be gated off for v1.0.36: "Make sure that this decision doesn't slip
# through the next install - I want it operational then."
#
# So there are two halves and only the first is done:
#
#   v1.0.36  the recurring enrichment agent is installed ONLY when
#            OSTLER_ENRICH_AGENT_ENABLED=1. Nothing sets it, so it is off.
#            That preserves the behaviour of every DMG shipped to date --
#            the agent has never run on any customer Mac, because the
#            function that installs it was defined below its own call site
#            and the install died there (#409).
#
#   NEXT     a customer-facing question that lets the person decide, and
#            SETS that variable from their answer.
#
# A deferral that lives only in a task list is a reminder, and reminders lose.
# This is the enforcer: the moment the installer version goes past 1.0.36, the
# cut cannot be green until the question exists. Nobody has to remember, and
# nobody can quietly ship the default through a second version.
#
# THE PREDICATE IS DELIBERATELY NOT "an assignment exists".
# `OSTLER_ENRICH_AGENT_ENABLED=1` hardcoded at the top of install.sh would
# satisfy that while giving the customer no choice at all -- it would turn the
# agent on by default and pass a gate named after consent. So the check also
# requires a QUESTION whose id names enrichment, because that is what a
# decision looks like in this installer.
#
# Exit: 0 pass, 1 fail, 2 cannot-run (never laundered into a pass).

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

DEFERRED_THROUGH="1.0.36"
PLIST="gui/OstlerInstaller/Info.plist"
TARGET="${TARGET_INSTALL_SH:-install.sh}"

for f in "$PLIST" "$TARGET"; do
    if [ ! -f "$f" ]; then
        echo "CANNOT-RUN: $f not found. This is not a pass."
        exit 2
    fi
done

# Version, read from the artefact the cut actually stamps. gui/Makefile:120
# reads this same key to name the DMG, so it is the version that ships rather
# than a number written down somewhere near it.
VERSION="${FORCE_INSTALLER_VERSION:-$(
    grep -A1 'CFBundleShortVersionString' "$PLIST" \
    | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1
)}"

if [ -z "$VERSION" ]; then
    echo "CANNOT-RUN: could not read CFBundleShortVersionString from $PLIST."
    echo "  A version this gate cannot read is a version it cannot judge."
    exit 2
fi

# Is the opt-in actually built? Two independent conditions, both required.
#
#   1. Something ASSIGNS the variable. The gate at the call site only ever
#      READS it as ${OSTLER_ENRICH_AGENT_ENABLED:-0}, so a read is not a wire.
#   2. A QUESTION exists whose id names enrichment. This is what stops a
#      hardcoded =1 from satisfying a consent gate.
# NOT ANCHORED TO LINE START, and TNM found out why the hard way.
#
# The first version of this used `^[[:space:]]*`, which only matches an
# assignment that begins its own line. But the natural way to write this opt-in
# is on the back of the condition that decides it:
#
#     [[ "$ans" == y ]] && OSTLER_ENRICH_AGENT_ENABLED=1
#
# That is midline, so the anchored predicate scored 0, and the gate stayed RED
# with the work genuinely finished. A gate that can only be satisfied by
# guessing the author's formatting is the "nobody can ever go green, so somebody
# deletes the gate" failure narrowed rather than removed -- and my own
# satisfiable control arm passed only because I happened to plant the assignment
# at column zero, so the control confirmed my formatting rather than the space of
# legitimate ones. There is now a fifth arm that plants it midline.
assign_hits="$(grep -cE '(^|[[:space:]&|;()])(export[[:space:]]+)?OSTLER_ENRICH_AGENT_ENABLED=' "$TARGET" || true)"
question_hits="$(grep -icE 'gui_read[^\n]*enrich|id=["'"'"']?[a-z_]*enrich[a-z_]*["'"'"']?' "$TARGET" || true)"

has_optin=0
[ "$assign_hits" -gt 0 ] && [ "$question_hits" -gt 0 ] && has_optin=1

newer_than_deferral="$(python3 - "$VERSION" "$DEFERRED_THROUGH" <<'PY'
import sys
def parts(v):
    out = []
    for chunk in v.strip().split("."):
        digits = "".join(c for c in chunk if c.isdigit())
        out.append(int(digits) if digits else 0)
    return out
a, b = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(a), len(b))
a += [0] * (n - len(a))
b += [0] * (n - len(b))
print("yes" if a > b else "no")
PY
)"

if [ "$newer_than_deferral" != "yes" ] && [ "$newer_than_deferral" != "no" ]; then
    echo "CANNOT-RUN: could not compare version '$VERSION' against '$DEFERRED_THROUGH'."
    exit 2
fi

echo "installer version ${VERSION}; deferral covers through ${DEFERRED_THROUGH}"
echo "opt-in wired: assignments=${assign_hits} enrichment-question=${question_hits}"

if [ "$has_optin" -eq 1 ]; then
    echo "PASS: the enrichment opt-in question exists and sets OSTLER_ENRICH_AGENT_ENABLED."
    exit 0
fi

if [ "$newer_than_deferral" = "yes" ]; then
    echo
    echo "FAIL: installer version ${VERSION} is past ${DEFERRED_THROUGH}, and the"
    echo "      enrichment opt-in question still does not exist."
    echo
    echo "  Andy ratified ONE cut of deferral, v1.0.36, on the explicit condition"
    echo "  that it be operational in the next install. This is that condition,"
    echo "  enforced rather than remembered."
    echo
    echo "  WHAT IS OWED: a customer-facing question that asks whether public-data"
    echo "  enrichment may run, and assigns OSTLER_ENRICH_AGENT_ENABLED from the"
    echo "  answer. Until then the recurring agent is installed on nobody's Mac,"
    echo "  which is safe but is not the product."
    echo
    echo "  Setting OSTLER_ENRICH_AGENT_ENABLED=1 without a question does NOT"
    echo "  satisfy this gate, and that is deliberate: it would switch the agent"
    echo "  on by default, which is the thing the directive forbids."
    exit 1
fi

echo "PASS (deferred): v${VERSION} is within the one ratified cut of deferral."
echo "  OWED IN THE NEXT CUT: the enrichment opt-in question. This gate turns"
echo "  RED automatically the moment CFBundleShortVersionString goes past"
echo "  ${DEFERRED_THROUGH}, so the deferral cannot silently become permanent."
exit 0
