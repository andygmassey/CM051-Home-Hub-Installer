#!/usr/bin/env bash
# Stage the cut's DMG into dist/ and verify its seal -- without ever reporting a
# failure it did not measure.
#
# ============================================================================
# WHY THIS IS A SCRIPT AND NOT SIX LINES OF YAML
# ============================================================================
#
# #828 made the staging step `if: always()` so a late red can no longer discard
# a notarised DMG. That was right and it shipped. But `always()` changed WHEN
# this predicate runs: it now runs on every failed cut too, including the ones
# where `make ship` died long before a DMG existed. As written inline it said:
#
#     [ -f "$DMG" ] || { echo "::error::no DMG produced at $DMG" >&2; exit 1; }
#
# so a cut that failed at, say, notarisation now goes red TWICE: once for the
# real cause, and once here, with an annotation naming a CONSEQUENCE. On the
# night v1.0.34 burned, "no DMG produced" was the sentence that meant a version
# had been spent. Printing it on every unrelated failure spends its meaning.
#
# THE DISTINCTION IS NOT "IS THERE A DMG". It is "was there SUPPOSED to be
# one". Those are different questions and only the second is this step's:
#
#   job already red  + no DMG  ->  CANNOT RUN. Nothing was measured. Say so
#                                  quietly and exit 0. The job is already red
#                                  from the real cause and a second, louder
#                                  error buries it.
#   every prior step green + no DMG  ->  FAIL. A green build that produced no
#                                  DMG is a genuine, serious defect and until
#                                  now nothing named it.
#   DMG present (either way)  ->  VERIFY IT PROPERLY. Capture is unconditional;
#                                  blessing is strict. A failed cut that still
#                                  produced a DMG gets the same seal checks as
#                                  a green one, because the artefact is going
#                                  to be uploaded either way and an uploaded
#                                  DMG nobody checked is worse than none.
#
# This is the three-state discipline this estate already settled on elsewhere:
# CM044's operator-pii-scan refused to be either red or green when it could not
# look, and took CANNOT-RUN instead, because "a check that is red on every PR
# gets ignored within a week" and "a scan that could not run has measured
# nothing". Same argument, same shape, different gate.
#
# IT IS A SCRIPT BECAUSE INLINE YAML CANNOT BE PROVED RED. The decision above
# has four outcomes and the whole point of the change is which one fires when.
# A predicate that only anybody has ever watched pass is not known to be able
# to fail. --self-test drives every branch, including the two that must NOT
# fail, with the external tools stubbed on PATH so the real code path runs.
#
# Exit 0  the DMG was staged and verified, OR there was honestly nothing to do.
# Exit 1  something was measured and it was wrong.
# Exit 2  bad usage.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

# The DECLARED number of self-test controls. Moved by hand when a control is
# added or removed. Without a floor, a self-test that runs NOTHING reports a
# pass: no failures out of nothing is still no failures.
EXPECTED_CONTROLS=8

# ---------------------------------------------------------------- predicate --

# Ask make where the DMG is. NEVER restate the path here: v1.0.26 died because
# a step ran `find dist -name '*.dmg'` while DIST_DIR defaults to
# /tmp/ostler-installer-dist-$USER, so on the first cut where notarise, staple
# and create-dmg ALL succeeded, the step that was meant to collect the artefact
# could not find it and the upload was skipped. One definition of the path,
# owned by the thing that writes it.
dmg_path_from_make() {
    make -C "${GUI_DIR}" --no-print-directory print-dmg-path 2>/dev/null || true
}

stage_and_verify() {
    local job_status="$1" dmg

    dmg="$(dmg_path_from_make | head -1)"

    if [ -z "$dmg" ] || [ ! -f "$dmg" ]; then
        local what="no DMG at '${dmg}'"
        [ -z "$dmg" ] && what="make could not name the DMG path"

        if [ "$job_status" != "success" ]; then
            # NOT an error annotation, and NOT a non-zero exit. Both would put
            # this step's name at the top of a run that failed somewhere else.
            echo "::notice title=Nothing to capture (this is not the failure)::CANNOT VERIFY: ${what}. The job was ALREADY red before this step ran, so the build never got far enough to produce one. See the FIRST failing step for the real cause. Nothing was measured here and this is not an additional failure."
            echo "CANNOT RUN: ${what}, and the job was already red. Measured nothing."
            return 0
        fi

        # The other half, and it is new. Before this split, a green build that
        # silently produced no DMG was caught here only incidentally.
        echo "::error title=Green build produced no DMG::${what}, and yet EVERY prior step succeeded. The build reported success without producing an artefact." >&2
        echo "FAIL: ${what} although every prior step succeeded." >&2
        return 1
    fi

    echo "dmg: ${dmg}"

    # notarytool exits 0 on `Invalid`, so the status is parsed rather than
    # inferred from $?. Same reasoning applies here: check the words.
    if ! xcrun stapler validate "$dmg"; then
        echo "::error title=DMG is not stapled::stapler validate failed for ${dmg}" >&2
        return 1
    fi

    local spctl_out
    spctl_out="$(spctl -a -vvv -t install "$dmg" 2>&1)"
    printf '%s\n' "$spctl_out"
    # `printf | grep -q` under pipefail: grep exits 0 on the first match and
    # closes the pipe, and printf can take SIGPIPE. Test the captured string.
    case "$spctl_out" in
        *"source=Notarized Developer ID"*) : ;;
        *)
            echo "::error title=DMG is not Notarized Developer ID::spctl did not report a Notarized Developer ID source for ${dmg}" >&2
            return 1
            ;;
    esac

    # Stage into dist/ so the upload globs have a stable, workspace-local home
    # regardless of where DIST_DIR points.
    mkdir -p dist
    cp "$dmg" dist/ || return 1
    ( cd dist && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS ) || return 1
    cat dist/SHA256SUMS
    ls -la dist/

    echo "EVIDENCE: staged $(basename "$dmg") into dist/ with SHA256SUMS, seal verified (job_status=${job_status})"
    return 0
}

# ---------------------------------------------------------------- self-test --
#
# The external tools are stubbed by PREPENDING a directory to PATH. The real
# predicate runs unmodified; only make, xcrun, spctl and shasum are replaced.
# That is the difference between testing this file and testing a copy of its
# logic, which would be the "duplicated predicate" failure: two spellings of
# one rule, and the test keeps passing after the shipped one drifts.

self_test() {
    local pass=0 fail=0
    TMPDIR_SELFTEST="$(mktemp -d)"
    # NOT `local`: the EXIT trap body is expanded when the trap FIRES, in the
    # global scope, where a function-local would be unset -- and under `set -u`
    # that aborts the cleanup it exists to guarantee.
    trap 'rm -rf "$TMPDIR_SELFTEST"' EXIT
    local root="$TMPDIR_SELFTEST"

    # build_stubs <dir> <dmg-path-to-report> <stapler-rc> <spctl-text>
    build_stubs() {
        local d="$1/bin" want="$2" staple_rc="$3" spctl_text="$4"
        mkdir -p "$d"
        cat > "$d/make" <<EOF
#!/usr/bin/env bash
# Only answers print-dmg-path; anything else is a test bug, loudly.
for a in "\$@"; do
  if [ "\$a" = "print-dmg-path" ]; then printf '%s\n' '${want}'; exit 0; fi
done
echo "STUB make called with unexpected args: \$*" >&2
exit 99
EOF
        cat > "$d/xcrun" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "stapler" ] || { echo "STUB xcrun: unexpected \$*" >&2; exit 99; }
echo "stub stapler validate"
exit ${staple_rc}
EOF
        cat > "$d/spctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${spctl_text}'
exit 0
EOF
        chmod +x "$d/make" "$d/xcrun" "$d/spctl"
        printf '%s' "$d"
    }

    # run_case <name> <want-rc> <dmg-exists yes|no> <job-status> <staple-rc> <spctl-text> [grep-for]
    run_case() {
        local desc="$1" want_rc="$2" exists="$3" js="$4" src="$5" stext="$6" needle="${7:-}"
        local case_dir; case_dir="$(mktemp -d "${root}/caseXXXXXX")"
        local dmg="${case_dir}/OstlerInstaller-9.9.9.dmg"
        [ "$exists" = "yes" ] && printf 'not a real dmg' > "$dmg"
        local bin; bin="$(build_stubs "$case_dir" "$dmg" "$src" "$stext")"

        local out rc=0
        out="$(cd "$case_dir" && PATH="${bin}:$PATH" GUI_DIR=gui \
                 bash "$SCRIPT_PATH" --job-status "$js" 2>&1)" || rc=$?

        local ok=1
        [ "$rc" -eq "$want_rc" ] || ok=0
        if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then ok=0; fi

        if [ "$ok" -eq 1 ]; then
            printf '  ok    %-62s (rc=%s)\n' "$desc" "$rc"; pass=$((pass + 1))
        else
            printf '  NOT OK %-61s want rc=%s got %s\n' "$desc" "$want_rc" "$rc"
            [ -n "$needle" ] && printf '        expected to find: %s\n' "$needle"
            printf '%s\n' "$out" | sed 's/^/        | /'
            fail=$((fail + 1))
        fi
    }

    local GOOD='the DMG is valid
source=Notarized Developer ID
origin=Developer ID Application: Test'
    local BAD='the DMG is valid
source=Unnotarized Developer ID'

    # 1. THE POSITIVE ARM. Without it, a predicate that rejects everything
    #    passes every negative control and looks rigorous.
    run_case "green job, DMG present and sealed -> staged" \
             0 yes success 0 "$GOOD" "EVIDENCE: staged"

    # 2. THE ONE #828 EXISTS FOR. A red job that DID produce a DMG must still
    #    capture and verify it. If this ever returns non-zero the artefact
    #    stops being staged on exactly the runs where it is most needed.
    run_case "RED job, DMG present and sealed -> still staged" \
             0 yes failure 0 "$GOOD" "EVIDENCE: staged"

    # 3. THE FIX. Red job, no DMG: CANNOT RUN, exit 0, notice not error.
    run_case "RED job, no DMG -> CANNOT RUN, quiet, exit 0" \
             0 no failure 0 "$GOOD" "CANNOT RUN"

    # 4. and it must NOT emit an error annotation, because that annotation is
    #    what buries the real cause. Asserted separately from the exit code:
    #    a step can exit 0 and still shout.
    run_case "RED job, no DMG -> emits ::notice, not ::error" \
             0 no failure 0 "$GOOD" "::notice title=Nothing to capture"

    # 5. THE OTHER HALF, AND IT IS NEW COVERAGE. Green job, no DMG is a real
    #    defect and must be named. If this arm is ever softened to match 3,
    #    a build that silently stops producing artefacts goes green for ever.
    run_case "GREEN job, no DMG -> FAIL naming the contradiction" \
             1 no success 0 "$GOOD" "although every prior step succeeded"

    # 6. Blessing stays strict: an unstapled DMG fails even though it exists.
    run_case "DMG present but stapler fails -> FAIL" \
             1 yes success 1 "$GOOD" "not stapled"

    # 7. And an unnotarised one. This arm had no test at all before.
    run_case "DMG present but spctl not Notarized -> FAIL" \
             1 yes success 0 "$BAD" "not Notarized Developer ID"

    # 8. A RED job with a BROKEN DMG must still fail. This is the control that
    #    stops case 3 from being over-applied into "if the job is red, shut
    #    up about everything", which would let an unnotarised artefact upload
    #    unchallenged.
    run_case "RED job, DMG present but unnotarised -> still FAIL" \
             1 yes failure 0 "$BAD" "not Notarized Developer ID"

    local ran=$((pass + fail))
    echo
    echo "self-test: ${ran} of ${EXPECTED_CONTROLS} controls ran, ${pass} passed, ${fail} failed"
    echo "EVIDENCE: stage-and-verify self-test ran ${ran}/${EXPECTED_CONTROLS} controls, ${pass} passed, ${fail} failed"

    if [ "$ran" -ne "$EXPECTED_CONTROLS" ]; then
        echo "FAIL: ${EXPECTED_CONTROLS} controls declared, ${ran} actually ran." >&2
        echo "      A self-test that measured nothing is not a passing gate." >&2
        return 1
    fi
    [ "$fail" -eq 0 ]
}

# ------------------------------------------------------------------- main ----

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
GUI_DIR="${GUI_DIR:-gui}"

main() {
    # Default to "success" so that a caller which forgets to pass the job
    # status gets the STRICT branch, not the quiet one. An omission must never
    # buy silence.
    local job_status="success"

    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test)  shift; self_test; return $? ;;
            --job-status) job_status="${2:-success}"; shift 2 ;;
            -h|--help)
                echo "usage: $0 [--job-status <success|failure|cancelled>]"
                echo "       $0 --self-test"
                return 0 ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done

    stage_and_verify "$job_status"
}

main "$@"
