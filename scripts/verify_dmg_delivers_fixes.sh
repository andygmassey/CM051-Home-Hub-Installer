#!/usr/bin/env bash
# verify_dmg_delivers_fixes.sh <dmg>
# ============================================================================
# #565 DELIVERY VERIFICATION -- READ THE ARTEFACT, NEVER main.
#
# A cut can merge every fix into main and still SHIP a DMG that carries none:
# the DMG is built from a pinned tree at cut time, and v1.0.50 (built 22:12,
# before #1247 merged at 02:38) is the proof -- it carries none of the three
# fixes that were already green on main. So the only honest question is "is the
# fix in the ARTEFACT", answered by mounting the DMG and reading its install.sh.
#
# WHAT THIS ASSERTS, AND HOW IT AVOIDS LYING:
#   - Mounts read-only at a mountpoint WE control. Never /Volumes/<Name>: a
#     stale image already there makes the new attach "<Name> 1" and you would
#     measure the OLD dmg. The hdiutil rc is READ, not swallowed.
#   - ENUMERATES every install.sh in the DMG and requires the fix in ALL of
#     them. An Ostler DMG carries two (outer installer + nested payload), both
#     run, and a `find | head -1` would sample one and miss a partial delivery.
#   - Greps a behaviour-tied INVARIANT per fix -- the string the fix introduced
#     into the code path -- never a comment, never a commit SHA. Each invariant
#     below was validated BOTH ways: absent in v1.0.50, present in origin/main
#     (@A2 2026-08-29). An absence check that is not paired with a
#     must-be-present control passes when the apparatus dies.
#   - Three outcomes: PASS (0), FAIL (1, a required fix is not delivered),
#     CANNOT-RUN (2, the mount failed or no install.sh was found -- nothing was
#     measured, which is not a pass).
#
# The next cut must carry these three; add a row when the required set changes.
# ============================================================================
set -uo pipefail

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
    echo "usage: $(basename "$0") <path-to-dmg>" >&2
    echo "  no default: a check that guesses the artefact measures the wrong one." >&2
    exit 2
fi

# (fix id, invariant). Behaviour-tied strings, validated absent-in-v1.0.50 /
# present-in-main. NOT a comment, NOT a SHA.
#
# 🔴 THE #2202 PAIR, ADDED 2026-09-19, AND IT IS A PAIR ON PURPOSE.
#
# Row 2202 measured the v1.0.100 artefact on the box: the ENTIRE merge-
# consistency repair and the orphan sweep are absent from what a customer
# installs. In the shipped payload install.sh, 35510 lines,
# repair_merge_consistency scored 0, against controls identity_resolver 24,
# batch_resolver 3 and imessage_fda 39, so the zero was a real absence and not
# a broken search. The module was not in the payload either.
#
# TWO ROWS, NOT ONE, AND NEITHER IS SUFFICIENT ALONE. The invocation lives in
# install.sh and the module it invokes lives in the vendored tree, so no single
# row here and no single capability_manifest entry can span both. Row 2202 said
# it in as many words: two separate patterns can BOTH be green while the feature
# is dead. In THIS file every row must pass for the gate to pass, so the pair is
# the conjunction that row asked for, enforced at cut time against the mounted
# DMG rather than against main.
#
# WHY IT COULD NOT HAVE BEEN ADDED BEFORE TODAY. Row 2202 names three gates.
# Gate 1 was CM041 #166, merged 2026-09-18. Gate 2 was the re-vendor, and it has
# landed: vendor/cm041/identity_resolver/repair_merge_consistency.py is present,
# with resolver.py in the same directory as the control proving the directory
# reads. Gate 3 is a BUILD, and these two rows are what make gate 3 checkable
# instead of asserted.
#
# INVARIANTS VALIDATED, both, with controls:
#   install.sh  "identity_resolver.repair_merge_consistency", 1 occurrence, at
#               :32480, and it is the invocation line itself rather than a
#               comment, which this file forbids keying on.
#   module      "_resurrectable_subjects", 3 in the module and 0 anywhere else
#               under vendor/, so the path suffix is not doing the work on its
#               own. CONTROL: "prefer_real_given_name" appears in 5 files, so
#               the search finds names where they exist and the 0 is real.
FIX_IDS=(  "#1247-sudo-gate-passwordless"                 "#1249-abort-speaks-on-terminal"   "#563-uninstall-count-nonfatal"
           "#2202-the-merge-consistency-repair-is-invoked" )
FIX_INV=(  "sudo already available without a password"    "Install aborted at line"          "COUNTS_INCOMPLETE"
           "identity_resolver.repair_merge_consistency" )

# 🔴 THIS CHECK ONLY EVER READ install.sh, AND ITS NAME DOES NOT SAY SO.
#
# One `find`, `-name 'install.sh'`. Every fix that lives anywhere else in the
# payload -- the vendored Python packages, the .app binary, lib/ -- was outside
# what this could see, while the script is the thing an operator runs to answer
# "does the DMG deliver the fixes".
#
# The case that forced this: #1543, the RULE 2 dedupe guard, is a launch blocker
# and it lives in contact_syncer/syncer.py. Running this check against the DMG
# that ships it would have printed PASS while measuring nothing about it.
#
# PAYLOAD_PATH is a path SUFFIX, not a basename, so `syncer.py` cannot be
# satisfied by meeting_syncer's copy. A payload entry whose file is not in the
# DMG at all is CANNOT-RUN, never a pass: an absent file and a present-but-stale
# one must not report the same.
#
# THE TWO KINSHIP ROWS, ADDED 2026-09-06. Both fixes were MERGED UPSTREAM the
# same morning and neither reached the artefact, which is CM051 #1656. A fix on
# a repo's main is not a fix on a customer's Mac, and until these rows existed
# nothing in the cut could tell the two apart for anything but install.sh.
#
# WHICH COPY SHIPS, measured rather than assumed, because #1656 named the wrong
# one: gui/project.yml copies the CONTENTS of vendor/cm041/ to the Resources
# root (`cp -R "${VENDOR_ROOT}/contact_syncer" "${DEST}/contact_syncer"`), and
# on a customer box SCRIPT_DIR IS that Resources root. So install.sh:18411
# stages the VENDORED tree, not the repo-root twin. This gate reads the DMG, so
# it is indifferent to that argument -- which is the point of reading the DMG.
# 🔴 THE #145 ROWS, ADDED 2026-09-06, AND WHY THEY POINT AT THE CALL SITES.
#
# The #142 row above asserts `is_kinship_given_name` in canonical_name.py. That
# row was GREEN while CM041 #145 sat unvendored for the whole of the afternoon,
# because #145 adds DIFFERENT functions and the row names only #142's. A gate
# keyed to a name proves the fix it names and is blind to the next one.
#
# Measured before these rows existed: driving the shipped vendored blob and
# CM041 main with the same input, the artefact returned "Smith" where upstream
# returned "Jane Smith" -- a real given name, present on the node, discarded.
# 3 of 5 cases differed and the delivery gate was green over all three.
#
# THE INVARIANT IS THE CALL SITE, NOT THE DEFINITION. Re-vendoring
# canonical_name.py alone would have added `prefer_real_given_name` as a
# function nobody calls: resolver.py and batch_resolver.py are DIVERGENT TWINS
# and keep their own `given = next(...)` line. A row asserting the definition
# would have gone green on a fix that could never fire, which is the same shape
# of blindness one layer down. So each row names the file that must CALL it.
# 🔴 THE TWO DEDUPE-MERGE ROWS, ADDED 2026-09-07, AND WHY THEY EXIST AT ALL.
#
# ostler_fda/dedupe_merge.py is the RULE 1 exact-key sweep the install runs at
# initial_hydrate. Its RULE 2 veto (bae15730, #1573) and its mergedInto
# tombstone (the fix behind residual B on people_stores_reconcile) are BOTH
# grafts on the VENDORED copy only. Measured 2026-09-07 by grep on five
# surfaces: HR015 source ostler_fda/dedupe_merge.py at the pin f5875d40: veto 0,
# tombstone 0; at HEAD a0ea428f: 0, 0; vendor/divergences/ostler_fda.patch:
# 0, 0; vendor/ostler_fda/dedupe_merge.py on main before this change: veto 1,
# tombstone 0; with this change: 1, 1. So the
# next re-sync from source overwrites both unless they reach the source
# first, and NOTHING in the cut could tell the artefact with them from the
# artefact without them. That is this project's signature failure -- a fix on
# a repo's main that never reaches the customer's Mac -- and these rows are
# what make it visible on the mounted DMG. The invariants are the strings
# each fix introduced into the CODE PATH: the stats key the veto returns, and
# the f-string of the tombstone update. Not comments, not SHAs.
# 🔴 THE SECOND #755 ROW, ADDED 2026-09-16 (CM051 #1619), AND WHY A SECOND ROW.
# The row above names the FUNCTION. A function name is not a behaviour: a
# refactor that keeps `_source_is_the_users_own` and drops the bundle test
# leaves that row green while the artefact ingests another device's address
# book again, which is #1619 exactly. The DISCRIMINATOR is the owning-bundle
# string, so this row names that instead. Measured on the vendored tree
# 2026-09-16: `com.apple.AddressBookSourceSync` 5, `_source_is_the_users_own`
# 2, control `_read_abcddb_as_vcards` 2 in the same file, so all three are real
# readings. Same lesson as the two #145 rows one file along: a gate keyed to a
# name proves the name and is blind to the behaviour behind it.
PAYLOAD_IDS=(  "#1543-rule-2-on-the-write"
               "#755-only-the-users-own-address-book"
               "#1619-the-discriminator-is-the-owning-bundle"
               "#142-a-kinship-word-is-never-welded"
               "#145-the-resolver-elects-the-real-given-name"
               "#145-the-batch-path-elects-it-too"
               "#1573-dedupe-merge-vetoes-two-cards"
               "#1573-dedupe-merge-leaves-a-tombstone"
               "#2202-the-repair-module-is-in-the-payload" )
PAYLOAD_PATH=( "contact_syncer/syncer.py"
               "contact_syncer/syncer.py"
               "contact_syncer/syncer.py"
               "identity_resolver/canonical_name.py"
               "identity_resolver/resolver.py"
               "identity_resolver/batch_resolver.py"
               "ostler_fda/dedupe_merge.py"
               "ostler_fda/dedupe_merge.py"
               "identity_resolver/repair_merge_consistency.py" )
PAYLOAD_INV=(  "_node_holds_a_different_canonical_key"
               "_source_is_the_users_own"
               "com.apple.AddressBookSourceSync"
               "is_kinship_given_name"
               "prefer_real_given_name"
               "prefer_real_given_name"
               "refused_rule2"
               "mergedInto> <{canonical}>"
               "_resurrectable_subjects" )

# ── COMMENT STRIPPING, AND WHY THIS GATE WAS BLIND WITHOUT IT ────────────────
#
# The header above says this file "greps a behaviour-tied INVARIANT per fix --
# the string the fix introduced into the code path -- never a comment". That
# was the INTENT and it was never enforced. `grep -cF` counts a line whether it
# is executed or commented out, so the claim was decoration.
#
# MEASURED 2026-09-23 against a built DMG carrying this repo's install.sh. The
# only live occurrence of the #2202 invariant is the invocation at install.sh
#     .venv/bin/python3 -m identity_resolver.repair_merge_consistency \
# Prefixing that one line with "# was: " in BOTH install.sh copies kills the
# merge-consistency repair on every customer Mac, and this gate printed
#     PRESENT   #2202-the-merge-consistency-repair-is-invoked (in all 2)
#     PASS: every required fix invariant is present
# rc=0. That is the gate that answers "does the DMG contain the fixes" saying
# yes about a feature it had just watched die.
#
# THE RULE: match only against text that survives comment stripping. Shell and
# Python both comment with '#', which is every file this gate reads.
#
# CONSERVATIVE BY CONSTRUCTION, because a false FAIL here blocks a cut:
#   - a line whose first non-blank character is '#' contributes nothing;
#   - on any other line the first '#' that is NOT inside a single- or
#     double-quoted span AND is preceded by whitespace ends the line;
#   - anything else is left exactly as it was. A '#' inside "http://x#y" or
#     mid-token (a Python f-string, a shell ${x#y} expansion) is untouched.
#
# VALIDATED BOTH WAYS on the real artefact: all 13 invariants below still read
# PRESENT on an unmutated DMG after stripping, and the mutation above now reads
# ABSENT. Neither direction alone would have been worth anything.
strip_comments() {
    awk '
        {
            line = $0
            probe = line
            sub(/^[[:space:]]+/, "", probe)
            if (substr(probe, 1, 1) == "#") next
            n = length(line); sq = 0; dq = 0; out = line
            for (k = 1; k <= n; k++) {
                ch = substr(line, k, 1)
                if (ch == "\\" && sq == 0) { k++; continue }
                if (ch == "\047" && dq == 0) { sq = 1 - sq; continue }
                if (ch == "\"" && sq == 0) { dq = 1 - dq; continue }
                if (ch == "#" && sq == 0 && dq == 0) {
                    prev = (k == 1) ? " " : substr(line, k - 1, 1)
                    if (prev == " " || prev == "\t") { out = substr(line, 1, k - 1); break }
                }
            }
            print out
        }
    ' "$1"
}

# live_count <file> <invariant> -> occurrences that survive comment stripping.
# `grep -c`, never `grep -q`: this file sets pipefail and a short-circuiting
# consumer SIGPIPEs the producer and inverts the verdict. grep -c reads to EOF.
live_count() {
    grep -cF -- "$2" < "$1"
}

# ── THE SENSITIVITY ARM. IT RUNS EVERY TIME, ON THE REAL ARTEFACT ────────────
#
# A fix you cannot make fail is the same defect wearing a new pattern. So for
# every invariant, this gate builds a copy of the file it is about to measure
# with EVERY occurrence of that invariant commented out, and requires its own
# matcher to report ABSENT. If the matcher still finds it, the gate is blind
# and says so instead of printing a verdict.
#
# This is the positive/negative control pair in one: the measurement itself is
# the must-be-PRESENT arm, and this is the must-be-ABSENT arm, both taken on
# the same bytes in the same run.
prove_sensitive() {   # $1 = source file, $2 = invariant
    _ps_mut="${WORK}/sens.mutant"
    awk -v inv="$2" '{ if (index($0, inv)) print "# was: " $0; else print }' "$1" > "$_ps_mut"
    strip_comments "$_ps_mut" > "${WORK}/sens.stripped"
    _ps_n="$(live_count "${WORK}/sens.stripped" "$2")"
    rm -f "$_ps_mut" "${WORK}/sens.stripped"
    [ "$_ps_n" -eq 0 ]
}

WORK="$(mktemp -d)"
MP="$(mktemp -d)"
DEV=""
ATTACHED=0
cleanup() {
    # A DETACH WHOSE FAILURE IS INVISIBLE IS NOT A DETACH.
    #
    # THIS LEAKED THE IMAGE AND COST THE v1.0.51 CUT TWO GATES. The old body was
    #     [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1 || true
    # which discards stdout, stderr AND the return code. If the detach fails --
    # a busy volume moments after traversing it with find is the ordinary case
    # on a CI runner -- the script still exits 0 with the image ATTACHED, and
    # says nothing. The next consumer of the same DMG then dies with
    # "hdiutil: attach failed - Resource busy / This image is ALREADY ATTACHED".
    #
    # THE EVIDENCE IS ORDERING, and it is decisive (@TNM, run 33268357529):
    #     18:37:46.166  this script prints "install.sh copies in the DMG: 2"
    #                   <- which REQUIRES a successful mount, so the image was FREE
    #     18:37:46.239  this script exits 0
    #     18:37:46.587  the next step attaches -> Resource busy
    # The image was free when we took it and busy 0.35s later. The only mount
    # alive in that window was ours, and the only thing that ran in between was
    # this trap.
    #
    # ⚠️ A LOCAL RUN CANNOT EXCLUDE THIS. Running the pre-fix script on a Mac
    # gives rc=0, attached=no -- I did exactly that and wrongly read it as
    # exclusion. It proves the happy path. The failure path was unobservable by
    # construction, because the rc was thrown away. A control that cannot fail
    # for the reason the subject fails is not a control.
    #
    # So: detach by the MOUNTPOINT we created (never a parsed device node, which
    # is a second thing that can silently be empty), READ the return code, and
    # if the image is still attached SAY SO with the consequence named.
    if [ "$ATTACHED" -eq 1 ]; then
        if ! hdiutil detach "$MP" -quiet 2>/dev/null; then
            [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
        fi
        # `grep -c`, NOT `grep -q`. This file sets `set -uo pipefail`, and
        # `producer | grep -q` exits on first match, SIGPIPEs the producer and
        # inverts the verdict. tests/test_pipefail_shortcircuit_inversion.sh
        # caught this exact line as the 67th instance against a baseline of 66
        # -- my own new defect, of the class I was fixing. grep -c must read to
        # EOF, so it cannot short-circuit, and it is POSIX rather than a bashism.
        if [ "$(hdiutil info 2>/dev/null | grep -cF -- "$DMG")" -gt 0 ]; then
            echo "WARNING: ${DMG} is STILL ATTACHED after cleanup." >&2
            echo "         The next step that mounts it will fail with 'Resource busy'." >&2
        fi
    fi
    [ -d "$MP" ] && rmdir "$MP" 2>/dev/null || true
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

attach_out="$(hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$DMG" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    echo "CANNOT-RUN: hdiutil attach failed (rc=${rc}). Nothing measured." >&2
    printf '%s\n' "$attach_out" >&2
    exit 2
fi
ATTACHED=1   # set the INSTANT the attach succeeds. NOT after the parse below:
             # a cleanup gated on a parse does not run when the parse is what broke.
DEV="$(printf '%s\n' "$attach_out" | awk '/GUID_partition_scheme|Apple_HFS|Apple_APFS/{print $1; exit}')"

# Enumerate, bash 3.2-safe (no mapfile on a stock Mac shell).
INSTALLS=()
while IFS= read -r _f; do
    [ -n "$_f" ] && INSTALLS+=("$_f")
done < <(find "$MP" -name 'install.sh' -type f 2>/dev/null)
n_installs="${#INSTALLS[@]}"
echo "install.sh copies in the DMG: ${n_installs}"
if [ "$n_installs" -eq 0 ]; then
    echo "CANNOT-RUN: no install.sh found in the mounted DMG -- wrong artefact or a changed layout." >&2
    exit 2
fi

# Strip once per file, not once per (file, invariant): install.sh is ~1.9 MB.
# A stripped copy that came out EMPTY means the stripper broke, and an empty
# haystack reports every invariant ABSENT -- a whole-cut FAIL from a tool
# fault. Refuse instead: "could not look" must never print as "not there".
STRIPPED=()
si=0
while [ "$si" -lt "$n_installs" ]; do
    _sf="${WORK}/install.${si}.stripped"
    strip_comments "${INSTALLS[$si]}" > "$_sf"
    if [ ! -s "$_sf" ]; then
        echo "CANNOT-RUN: comment stripping emptied ${INSTALLS[$si]} -- the stripper is broken." >&2
        exit 2
    fi
    STRIPPED+=("$_sf")
    si=$((si + 1))
done

fail=0
i=0
while [ "$i" -lt "${#FIX_IDS[@]}" ]; do
    id="${FIX_IDS[$i]}"; inv="${FIX_INV[$i]}"
    # THE MUST-BE-ABSENT ARM, taken BEFORE the measurement it guards.
    if ! prove_sensitive "${INSTALLS[0]}" "$inv"; then
        echo "CANNOT-RUN: the matcher still finds '${inv}' after every occurrence" >&2
        echo "            in ${INSTALLS[0]} was commented out. This gate is BLIND to" >&2
        echo "            that invariant, so its verdict on ${id} means nothing." >&2
        exit 2
    fi
    present_in=0
    for f in "${STRIPPED[@]}"; do
        if [ "$(live_count "$f" "$inv")" -gt 0 ]; then
            present_in=$((present_in + 1))
        fi
    done
    if [ "$present_in" -eq "$n_installs" ]; then
        printf '  PRESENT   %-32s (in all %d install.sh)\n' "$id" "$n_installs"
    else
        printf '  ABSENT    %-32s (in %d of %d) -- NOT DELIVERED\n' "$id" "$present_in" "$n_installs"
        fail=1
    fi
    i=$((i + 1))
done

# ── PAYLOAD FIXES: everything that is NOT install.sh ─────────────────────────
cannot_payload=0
j=0
while [ "$j" -lt "${#PAYLOAD_IDS[@]}" ]; do
    pid="${PAYLOAD_IDS[$j]}"; ppath="${PAYLOAD_PATH[$j]}"; pinv="${PAYLOAD_INV[$j]}"
    PFILES=()
    while IFS= read -r _pf; do
        [ -n "$_pf" ] && PFILES+=("$_pf")
    done < <(find "$MP" -type f -path "*/${ppath}" 2>/dev/null)
    n_p="${#PFILES[@]}"
    if [ "$n_p" -eq 0 ]; then
        printf '  NOT MEASURED  %-30s no %s in the DMG -- CANNOT-RUN, not a pass\n' "$pid" "$ppath" >&2
        cannot_payload=1
        j=$((j + 1))
        continue
    fi
    if ! prove_sensitive "${PFILES[0]}" "$pinv"; then
        echo "CANNOT-RUN: the matcher still finds '${pinv}' after every occurrence" >&2
        echo "            in ${PFILES[0]} was commented out -- BLIND to ${pid}." >&2
        exit 2
    fi
    p_present=0
    for f in "${PFILES[@]}"; do
        _pstrip="${WORK}/payload.stripped"
        strip_comments "$f" > "$_pstrip"
        if [ ! -s "$_pstrip" ]; then
            echo "CANNOT-RUN: comment stripping emptied ${f} -- the stripper is broken." >&2
            exit 2
        fi
        if [ "$(live_count "$_pstrip" "$pinv")" -gt 0 ]; then
            p_present=$((p_present + 1))
        fi
    done
    if [ "$p_present" -eq "$n_p" ]; then
        printf '  PRESENT   %-32s (in all %d %s)\n' "$pid" "$n_p" "$ppath"
    else
        printf '  ABSENT    %-32s (in %d of %d %s) -- NOT DELIVERED\n' "$pid" "$p_present" "$n_p" "$ppath"
        fail=1
    fi
    j=$((j + 1))
done

# PRECEDENCE, STATED. A measured absence outranks an unmeasurable entry: a DMG
# that provably lacks a fix is a FAIL even if another entry could not be looked
# for. Only when nothing failed does an unmeasured entry decide the verdict, and
# then it is CANNOT-RUN rather than a pass.
if [ "$fail" -ne 0 ]; then
    echo "FAIL: the DMG does not deliver every required fix (see ABSENT above)." >&2
    exit 1
fi
if [ "$cannot_payload" -ne 0 ]; then
    echo "CANNOT-RUN: a payload fix could not be looked for (see NOT MEASURED above)." >&2
    echo "            Every install.sh invariant passed. That is not the same as delivery." >&2
    exit 2
fi
echo "PASS: every required fix invariant is present as LIVE code (comments stripped)"
echo "      -- ${#FIX_IDS[@]} in every install.sh, ${#PAYLOAD_IDS[@]} in the payload; each one proven ABSENT first on a commented-out copy."
exit 0
