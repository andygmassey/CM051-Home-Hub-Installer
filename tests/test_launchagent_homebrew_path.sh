#!/usr/bin/env bash
#
# test_launchagent_homebrew_path.sh
#
# THE DEFECT, measured on the Mini 2026-08-20 after a real power cycle:
#
#     colima  FATA  exec "limactl": executable file not found in $PATH
#
# launchd hands its jobs a minimal PATH -- /usr/bin:/bin:/usr/sbin:/sbin --
# unless the plist sets EnvironmentVariables:PATH. Homebrew is not in it.
# The assistant daemon owns `colima start`; colima resolves limactl through
# PATH. So the VM never booted, and Qdrant, Oxigraph, Redis, Vane, wiki-site
# and store-proxy were all gone until someone started Colima by hand.
#
# Recovery proved the chain is exactly one link: with the Homebrew prefix on
# PATH, Colima came up in 75s and all six containers returned by themselves.
#
# WHY THIS IS A CLASS AND NOT A PLIST. Measured on the live box: 24 ostler
# LaunchAgents, 6 carrying a Homebrew-aware PATH, and BOTH agents that broke
# that day in the other 18. The technique was known, used, and omitted. There
# was no rule, so each agent was correct or broken by accident. This file is
# the rule.
#
# WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
#
# A DECLARED set: the writers we KNOW produce agents that shell out to
# Homebrew-installed tooling must emit a Homebrew-aware PATH. Each entry
# carries its reason, because a required-list with no justification rots into
# a list nobody dares change. It does NOT assert all 24 -- stay-awake runs
# caffeinate and is genuinely fine on /usr/bin. Failing 18 on day one produces
# a gate everyone routes around.
#
# THIS IS A SOURCE-SIDE TEST AND IT CANNOT SEE A BROKEN BOX. TNM made this
# point and it is correct: a gate over install.sh goes green while the machine
# in front of you has no Colima. The box-side half is a separate instrument,
# scripts/box_walk_probes/probes/launchagents_resolve_their_tools.sh, which
# reads the INSTALLED plists over ssh. Neither substitutes for the other:
# this one stops the fix being reverted, that one stops it being believed.
#
# Runnable standalone:  bash tests/test_launchagent_homebrew_path.sh
# Exits non-zero on ANY mismatch.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0
CHECKS=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "  ok   $*"; }
count()   { CHECKS=$((CHECKS + 1)); }

# The prefix that makes Homebrew tooling reachable on Apple silicon. A PATH
# that merely EXISTS is not the assertion -- reachability is.
BREW_MARK='/opt/homebrew/bin'

# ---------------------------------------------------------------------------
# THE PREDICATE, defined once so the controls below drive the SAME code.
#
#   template_has_brew_path <file>  -> echoes YES | NO-PATH | NO-HOMEBREW
#
# Deliberately not `grep -q PATH`: a plist can carry a PATH key that omits
# Homebrew entirely, which is the shape most likely to be got wrong by a
# later edit, and a presence check calls it correct.
# ---------------------------------------------------------------------------
template_has_brew_path() {
    local f="$1" line
    [[ -f "$f" ]] || { echo "MISSING"; return 0; }
    # The <string> immediately following <key>PATH</key>.
    line="$(grep -A1 '<key>PATH</key>' "$f" 2>/dev/null | grep '<string>' | head -1)"
    if [[ -z "$line" ]]; then echo "NO-PATH"; return 0; fi
    case "$line" in
        *"$BREW_MARK"*) echo "YES" ;;
        *)              echo "NO-HOMEBREW" ;;
    esac
}

echo "=== 1. DECLARED writers must emit a Homebrew-aware PATH ==="

# label | file | why it needs Homebrew on PATH
REQUIRED_TEMPLATES="
assistant|assistant-agent/launchd/com.creativemachines.ostler.assistant.plist|owns \`colima start\`; colima resolves limactl through PATH
"

while IFS='|' read -r label rel why; do
    [[ -n "$label" ]] || continue
    count
    verdict="$(template_has_brew_path "$REPO_ROOT/$rel")"
    if [[ "$verdict" == "YES" ]]; then
        pass "$label ($rel)"
    else
        failure "$label: $rel reads $verdict, expected a PATH containing $BREW_MARK. Reason it is required: $why. launchd gives /usr/bin:/bin:/usr/sbin:/sbin, so the tooling is unreachable."
    fi
done <<< "$REQUIRED_TEMPLATES"

# The fda-rerun plist is a heredoc inside install.sh, not a template file, so
# it is checked against the emitted body rather than a path. Its job runs the
# tick's python toolchain, which resolves through PATH.
count
FDA_BODY="$(sed -n '/^<?xml version="1.0" encoding="UTF-8"?>$/,/^FDARPEOF$/p' "$INSTALL_SH" 2>/dev/null | grep -B4 -A4 'com.ostler.fda-rerun')"
FDA_PATH_LINE="$(sed -n '/<string>com.ostler.fda-rerun<\/string>/,/^FDARPEOF$/p' "$INSTALL_SH" 2>/dev/null | grep -A1 '<key>PATH</key>' | grep '<string>' | head -1)"
if [[ -z "$FDA_BODY" ]]; then
    failure "could not locate the com.ostler.fda-rerun heredoc in install.sh. This test cannot assert what it cannot find, and a silent skip here would read as a pass."
elif [[ -z "$FDA_PATH_LINE" ]]; then
    failure "the com.ostler.fda-rerun heredoc in install.sh emits no EnvironmentVariables:PATH. That job runs the tick's python toolchain, which resolves through PATH, and launchd gives it /usr/bin:/bin:/usr/sbin:/sbin."
elif [[ "$FDA_PATH_LINE" != *"$BREW_MARK"* ]]; then
    failure "the com.ostler.fda-rerun heredoc emits a PATH that omits $BREW_MARK. Presence of the key is not the assertion; reachability of the tooling is."
else
    pass "fda-rerun heredoc (install.sh)"
fi

echo
echo "=== 2. POSITIVE CONTROL: the predicate must find a value it MUST find ==="
#
# Without this, a predicate that returns NO-PATH for everything would satisfy
# the negative control below AND fail section 1 loudly enough to be "fixed"
# by weakening section 1. context-refresh has carried this key since long
# before today's incident, so it is a value the predicate must find.
count
CTRL_POS="$REPO_ROOT/context-refresh/launchd/com.creativemachines.ostler.context-refresh.plist"
ctrl_verdict="$(template_has_brew_path "$CTRL_POS")"
if [[ "$ctrl_verdict" == "YES" ]]; then
    pass "predicate finds the pre-existing PATH in context-refresh"
else
    failure "POSITIVE CONTROL: context-refresh has carried a Homebrew PATH since before this incident and the predicate reads it as $ctrl_verdict. The predicate is broken, so every verdict it returns above is meaningless."
fi

echo
echo "=== 3. NEGATIVE CONTROL: the predicate must FAIL on a stripped copy ==="
#
# Both directions. A checker stuck on "missing" would satisfy a one-sided
# control while being useless, which is why section 2 exists above.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

count
# 3a. PATH removed entirely -- the shape of the assistant plist before today.
grep -v '/usr/local/bin:/opt/homebrew/bin' "$CTRL_POS" | grep -v '<key>PATH</key>' > "$TMPD/nopath.plist"
neg_a="$(template_has_brew_path "$TMPD/nopath.plist")"
if [[ "$neg_a" == "NO-PATH" ]]; then
    pass "stripped copy reads NO-PATH"
else
    failure "NEGATIVE CONTROL DID NOT FIRE: a plist with the PATH key removed read as $neg_a. This test cannot detect the defect it exists for."
fi

count
# 3b. PATH present but Homebrew absent -- the one most likely to be got wrong
#     by a later edit, and invisible to a presence check.
sed 's|/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin|/usr/bin:/bin:/usr/sbin:/sbin|' "$CTRL_POS" > "$TMPD/nobrew.plist"
neg_b="$(template_has_brew_path "$TMPD/nobrew.plist")"
if [[ "$neg_b" == "NO-HOMEBREW" ]]; then
    pass "Homebrew-less PATH reads NO-HOMEBREW"
else
    failure "NEGATIVE CONTROL DID NOT FIRE: a PATH that exists but omits $BREW_MARK read as $neg_b. Presence of the key is not the assertion."
fi

echo
echo "=== 4. THE UPGRADE LIMB, driven against the SHIPPED guard ==="
#
# A fix that only lands in the heredoc reaches fresh installs and leaves every
# existing box broken forever, because the file exists and the writer skips.
# That is the #768/#769 shape install.sh's own comment warns about one
# paragraph above the guard.
#
# So this extracts the guard TEXT from install.sh and evals it. A later edit
# to that guard is driven by this test, not paraphrased by it -- a re-typed
# copy here would pass while the shipped guard rotted.
GUARD="$(sed -n '/^    FDA_RERUN_NEEDS_WRITE=0$/,/^    fi$/p' "$INSTALL_SH")"
if [[ -z "$GUARD" ]]; then
    count
    failure "could not extract the FDA_RERUN_NEEDS_WRITE guard from install.sh. Nothing was driven, which is not the same as nothing being wrong."
else
    mk_plist() { # mk_plist <file> <extra-xml>
        {
            printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
            printf '  <key>Label</key><string>com.ostler.fda-rerun</string>\n'
            printf '%s\n' "$2"
            printf '</dict>\n</plist>\n'
        } > "$1"
    }

    BREW_XML='  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string></dict>
  <key>StartInterval</key><integer>3600</integer>'
    mk_plist "$TMPD/correct.plist" "$BREW_XML"
    mk_plist "$TMPD/pathless.plist" '  <key>StartInterval</key><integer>3600</integer>'
    mk_plist "$TMPD/legacy.plist"   '  <key>StartCalendarInterval</key><dict/>'

    drive_guard() { # drive_guard <plist-or-absent-path> -> "needs:legacy:pathless"
        FDA_RERUN_PLIST="$1"
        # Seed all three to a sentinel BEFORE the eval. Under `set -u` an
        # unassigned variable aborts the printf, and the arm then fails with
        # an empty verdict -- which reads as "the guard misbehaved" when the
        # true finding is "the guard has no such limb". The failure text has
        # to name what was measured, so a limb that was never written reports
        # as ABSENT, not as a wrong value.
        FDA_RERUN_NEEDS_WRITE=ABSENT
        FDA_RERUN_WAS_LEGACY=ABSENT
        FDA_RERUN_WAS_PATHLESS=ABSENT
        eval "$GUARD"
        printf '%s:%s:%s' "$FDA_RERUN_NEEDS_WRITE" "$FDA_RERUN_WAS_LEGACY" "$FDA_RERUN_WAS_PATHLESS"
    }

    # arm | plist | expected needs:legacy:pathless | why
    ARMS="
absent|$TMPD/does-not-exist.plist|1:0:0|a fresh install has nothing on disk and must write
legacy|$TMPD/legacy.plist|1:1:0|the pre-#769 StartCalendarInterval shape must still be rewritten
pathless|$TMPD/pathless.plist|1:0:1|an existing modern plist with no Homebrew PATH is the box we measured today
correct|$TMPD/correct.plist|0:0:0|a guard that always rewrites would satisfy all three arms above
"
    while IFS='|' read -r arm plist expected why; do
        [[ -n "$arm" ]] || continue
        count
        got="$(drive_guard "$plist")"
        if [[ "$got" == "$expected" ]]; then
            pass "guard arm $arm -> $got"
        elif [[ "$got" == *ABSENT* ]]; then
            failure "guard arm $arm: the shipped guard never assigns one of needs:legacy:pathless -- it returned $got. The limb does not exist in install.sh, so this is an absent mechanism, not a wrong value. $why"
        else
            failure "guard arm $arm: expected needs:legacy:pathless=$expected, got $got. $why"
        fi
    done <<< "$ARMS"
fi

echo
echo "=== 5. A REWRITE THAT IS NOT RELOADED IS NOT IN FORCE ==="
#
# launchctl bootstrap is a no-op against an already-loaded label. If the
# bootout is gated on the legacy limb alone, the PATH limb overwrites the file
# and the box keeps running the job we just replaced -- on disk and not in
# force, which reads as done on every surface that looks at the file.
count
BOOTOUT_COND="$(grep -n 'FDA_RERUN_WAS_LEGACY" == "1"' "$INSTALL_SH" | grep 'if \[\[' | head -1)"
if [[ -z "$BOOTOUT_COND" ]]; then
    failure "could not find the fda-rerun bootout condition in install.sh."
elif [[ "$BOOTOUT_COND" == *FDA_RERUN_WAS_PATHLESS* ]]; then
    pass "bootout covers the pathless limb as well as the legacy one"
else
    failure "the fda-rerun bootout fires only on the legacy limb: ${BOOTOUT_COND}. The pathless limb replaces a file that is equally already registered, so without a bootout the box keeps running the PATH-less job until next login."
fi

echo
echo "=== 6. EVERY shipped template must parse under a STRICT XML parser ==="
#
# Found by breaking it: the PATH comment added above originally used a double
# hyphen as punctuation. XML forbids that inside a comment body. `plutil -lint`
# accepted the file and printed OK; python's expat, which is what actually
# reads the RENDERED plist in tests/test_colima_autostart_mechanism.sh, did
# not. A lenient validator saying OK is not the same as the file being valid,
# and the two disagreed silently.
#
# Seven sibling templates carried the same latent fault (14 occurrences,
# several of them a genuine `since-days` CLI flag written literally). Nothing
# parsed them strictly, so nothing complained. This asserts over ALL of them,
# not the declared set, because the fault has nothing to do with which agent
# needs Homebrew and everything to do with how these files are written.
count
STRICT_OUT="$(cd "$REPO_ROOT" && python3 - <<'PYEOF' 2>&1
import plistlib, subprocess, sys
files = subprocess.run(['git', 'ls-files', '*/launchd/*.plist'],
                       capture_output=True, text=True).stdout.split()
if not files:
    print('EXAMINED 0 -- no launchd templates found; an empty set passes every assertion it does not make')
    sys.exit(2)
bad = []
for f in files:
    try:
        plistlib.load(open(f, 'rb'))
    except Exception as e:
        bad.append(f'{f}: {e}')
print(f'EXAMINED {len(files)}')
for b in bad:
    print(f'  {b}')
sys.exit(1 if bad else 0)
PYEOF
)"
STRICT_RC=$?
printf '%s\n' "$STRICT_OUT" | sed 's/^/  /'
if [[ "$STRICT_RC" == "0" ]]; then
    pass "all shipped launchd templates parse strictly"
elif [[ "$STRICT_RC" == "2" ]]; then
    failure "the strict-parse check examined ZERO templates. A zero denominator reads as success; it is not one."
else
    failure "at least one shipped launchd template is not well-formed XML (see above). plutil accepts a double hyphen inside a comment body; the strict parsers that read the rendered plist do not."
fi

echo
echo "------------------------------------------------------------"
echo "checks run: $CHECKS"
if [[ "$FAILED" != "0" ]]; then
    echo "test_launchagent_homebrew_path: FAILED" >&2
    exit 1
fi
echo "test_launchagent_homebrew_path: PASSED"
exit 0
