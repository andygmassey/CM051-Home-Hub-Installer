#!/usr/bin/env bash
# Bundle-phase declaration completeness gate
# =============================================================
#
# THE INVARIANT
#
#     every file a bundling postBuildScript copies into the .app
#     appears in BOTH that phase's inputFiles AND its outputFiles
#
# WHY IT MATTERS. Xcode uses those two lists for incremental-build dependency
# tracking, and nothing else validates them:
#
#   * absent from inputFiles  -> editing the source file does not dirty the
#                                phase, so Xcode may skip it entirely and the
#                                bundle keeps the PREVIOUS copy
#   * absent from outputFiles -> Xcode has no record the phase produces it, so
#                                a deleted/dirty build product is not noticed
#
# Either way the build goes green and the .app ships a STALE file. The symptom
# is "I edited that and nothing changed", which reads as a logic bug in the
# thing you edited, not as a build-system fault -- so it is looked for in
# entirely the wrong place. Same shape as the wiki-image namespace drift: a
# correct-looking pipeline delivering an old artefact.
#
# WHAT HAPPENED (2026-08-07). lib/settling_progress.sh was added to the
# "Bundle install.sh + lib/..." phase's cp block, but not to either list. It
# went out correctly on clean builds and could go out stale on incremental
# ones. Every other file in that phase was in both lists; this one was missed
# by hand, which is precisely what a mechanical check is for.
#
# This gate is deliberately mechanical: it does not know which files matter,
# it just refuses to let cp and the declarations disagree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/gui/project.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

[[ -f "$PROJECT_YML" ]] || fail "gui/project.yml not found at $PROJECT_YML"

# The parse lives in Python: project.yml is YAML with shell heredocs inside it,
# and a line-oriented shell parse of that is how you get a gate that quietly
# stops matching.
python3 - "$PROJECT_YML" <<'PY'
import re
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()

# Split into postBuildScript entries. Each starts at a "      - name:" line at
# the phase indent level; take everything up to the next one.
entries = re.split(r"\n(?=      - name: )", body)

# Only phases that copy out of ${SRCROOT}/../ are in scope. Phases that
# generate content (compile a helper, download Python) legitimately have no
# source file to declare.
COPY_RE = re.compile(
    r'^\s*cp\s+(?:-[A-Za-z]+\s+)*"\$\{SRCROOT\}/\.\./([^"]+)"\s+"\$\{DEST\}/([^"]+)"',
    re.M,
)

problems = []
checked = 0

for entry in entries:
    name_match = re.search(r"- name: (.+)", entry)
    if not name_match:
        continue
    phase = name_match.group(1).strip()

    copies = COPY_RE.findall(entry)
    if not copies:
        continue

    # A phase with no declarations at all is opting out of incremental
    # tracking wholesale -- noisy to flag here, and visible in review.
    if "inputFiles:" not in entry and "outputFiles:" not in entry:
        continue

    checked += 1
    for src, dest in copies:
        # NOTE on scope: COPY_RE only matches unconditional copies whose
        # SOURCE is "${SRCROOT}/../...". The one conditional copy in this
        # project.yml (Ostler.app, guarded by OSTLER_APP_PATH) reads from a
        # shell variable, so it never matches and needs no special case. If a
        # guarded ${SRCROOT} copy is ever added, it will be flagged here and
        # should be moved out of the `if` or declared -- not silently skipped.
        want_in = f"$(SRCROOT)/../{src}"
        want_out = f"$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/{dest}"

        if want_in not in entry:
            problems.append((phase, src, "inputFiles", want_in))
        if want_out not in entry:
            problems.append((phase, src, "outputFiles", want_out))

if not checked:
    print(
        "FAIL: parsed no bundling phases with declarations -- the parser has "
        "stopped matching gui/project.yml and this gate is now blind.",
        file=sys.stderr,
    )
    sys.exit(1)

# SCOPE HONESTY. This gate understands exactly one shape: `cp` with a literal
# "${SRCROOT}/../..." source. Today that is every source-file copy in the file.
# If someone adds a phase that stages sources with rsync/ditto/install, or via
# a shell variable, this gate would go on passing while covering less -- the
# silent-narrowing failure. So refuse to pass on a verb we cannot read.
UNKNOWN_VERB_RE = re.compile(
    r'^\s*(rsync|ditto|install)\s+[^\n]*\$\{SRCROOT\}/\.\./', re.M
)
unknown = UNKNOWN_VERB_RE.findall(body)
if unknown:
    print(
        "FAIL: gui/project.yml stages sources with a copy verb this gate "
        "cannot read (" + ", ".join(sorted(set(unknown))) + ").\n"
        "      Those copies are NOT being checked for inputFiles/outputFiles\n"
        "      declarations. Extend COPY_RE rather than leaving them unchecked.",
        file=sys.stderr,
    )
    sys.exit(1)

if problems:
    print(
        "FAIL: a bundling phase copies a file it does not declare.\n"
        "      Xcode can skip the phase and ship a STALE copy.\n",
        file=sys.stderr,
    )
    for phase, src, which, needed in problems:
        print(f"  {src}", file=sys.stderr)
        print(f"    phase:   {phase}", file=sys.stderr)
        print(f"    missing: {which} entry", file=sys.stderr)
        print(f"    add:     - {needed}\n", file=sys.stderr)
    sys.exit(1)

total_copies = sum(len(COPY_RE.findall(e)) for e in entries)
print(
    f"ok: {checked} bundling phase(s), {total_copies} source copy(ies) -- "
    "all declared in both inputFiles and outputFiles"
)
PY

pass "gui/project.yml bundling declarations complete"

# ── Positive control ──────────────────────────────────────────────────────
# A gate that has stopped matching passes exactly like a clean tree. Prove it
# still bites by removing a known declaration from a COPY and re-running.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/gui" "$SCRATCH/tests"
grep -v '^          - \$(SRCROOT)/\.\./lib/progress_emitter\.sh$' "$PROJECT_YML" \
    > "$SCRATCH/gui/project.yml"
cp "${BASH_SOURCE[0]}" "$SCRATCH/tests/$(basename "${BASH_SOURCE[0]}")"

if (cd "$SCRATCH" && bash "tests/$(basename "${BASH_SOURCE[0]}")" >/dev/null 2>&1); then
    fail "POSITIVE CONTROL FAILED -- the gate passed a project.yml with a
      deliberately removed inputFiles entry. It is not actually checking
      anything; a real regression would slip through it unnoticed."
fi
pass "positive control: the gate rejects a removed declaration"

echo "PASS: bundle-phase declaration completeness"
