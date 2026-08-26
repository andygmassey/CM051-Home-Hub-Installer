#!/bin/bash
# walk_dmg.sh <path-to.dmg>  -- the eight arms, arm 8 FIRST because it has veto.
#
# WHERE THIS SITS. scripts/box_walk_probes/README.md opens with "AFTER A DMG
# WALK, RUN THIS ONE COMMAND" and points at post_walk_qa.sh. That is the
# POST-INSTALL half and it needs a box that has already been installed onto.
# The DMG walk it refers to was the manual step nothing automated. This is that
# step. The two are complementary and neither replaces the other:
#
#   scripts/walk_dmg.sh              the ARTEFACT, before anyone installs it
#   scripts/post_walk_qa.sh <host>   the BOX, after they have
#
#
# WHY ARM 8 IS FIRST AND ALONE HAS A VETO. Seven arms said GO on v1.0.45.
# v1.0.45 BRICKS. Every one of the seven inspects the artefact AS SHIPPED, and
# the defect only appears once the thing has been RUN. A signature that verifies
# at rest tells you nothing about a bundle that writes into itself on first use.
#
# WHAT ARM 8 USED TO GET WRONG. It counted `codesign ... | grep -c '^file added:'`
# and returned 0 while 69 .pyc sat inside the bundle, so an arm 8 trusting it
# would have called a bricked artefact GREEN.
#
# I FIRST WROTE THAT codesign "prints no such line". THAT IS FALSE, and measured:
#
#   codesign --verify --deep --strict              grep 'file added:'  ->     0
#   codesign --verify --deep --strict --verbose=4  grep 'file added:'  ->  1448
#
# The lines exist. They are SUPPRESSED AT DEFAULT VERBOSITY, which is what the
# old arm used. The conclusion was right and the reason was wrong, which is worse
# than a wrong conclusion because it teaches the next reader a mechanism that
# does not exist.
#
# So: count .pyc and read the EXIT CODE. Not because the message is absent, but
# because whether a message appears at all depends on a verbosity flag, and a
# check should not rest on one.
set -Eeuo pipefail
#
# WHAT THIS SUITE HAS AND HAS NOT BEEN SEEN TO DO, 2026-08-26:
#
#   SEEN RED   on v1.0.45, the artefact that actually bricked a Mac. Arm 8
#              vetoes (192 .pyc written on first use, codesign rc=1) and arm 6
#              fails, while arms 1,2,3,4,7 ALL PASS. Five green arms on a
#              bricking DMG is the entire reason arm 8 exists.
#
#   NOT SEEN   green end to end. No artefact yet exists in which the bundled
#   GREEN      interpreter is not an import root, so arm 8 cannot pass on
#              anything currently cuttable. Its PASS branch HAS been exercised
#              separately -- same commands, guard set, 0 .pyc and codesign
#              rc=0 -- but not through this script.
#
#              A gate never seen green can be stuck red, so treat the first
#              green run (the first DMG cut from CM051 #1055) as itself
#              needing a second look.

DMG="${1:?usage: walk_dmg.sh <path-to.dmg>}"
[ -f "$DMG" ] || { echo "CANNOT-RUN: no such file: $DMG"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/walk.XXXXXX")"
MP="$WORK/mnt"
mkdir -p "$MP"
cleanup() { /sbin/umount "$MP" 2>/dev/null || /usr/bin/hdiutil detach "$MP" -quiet 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pass=0; fail=0; cannot=0
say() { printf '%-6s %s\n' "$1" "$2"; case "$1" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) cannot=$((cannot+1));; esac; }

echo "=============================================================="
echo " DMG      $DMG"
echo " sha256   $(/usr/bin/shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo " bytes    $(/usr/bin/stat -f %z "$DMG")"
echo "=============================================================="

# ALWAYS an explicit -mountpoint. A stale image already at /Volumes/<Name>
# makes the new attach land at "<Name> 1", and measuring the OLD one raised a
# false cut-blocker once already.
# "Resource busy" here means THIS IMAGE IS ALREADY ATTACHED somewhere else,
# not that the DMG is bad. Say so, because a bare hdiutil error at the top of a
# walk reads as a corrupt artefact and has sent people looking for the wrong
# problem.
if ! /usr/bin/hdiutil attach "$DMG" -mountpoint "$MP" -nobrowse -readonly >/dev/null 2>"$WORK/attach.err"; then
  echo "CANNOT-RUN: could not attach the image."
  /usr/bin/sed 's/^/  /' "$WORK/attach.err"
  if /usr/bin/grep -q 'Resource busy' "$WORK/attach.err"; then
    echo "  This image is ALREADY ATTACHED. Detach it first:"
    /usr/bin/hdiutil info | /usr/bin/grep -B1 "$(basename "$DMG")" | /usr/bin/sed 's/^/    /' || true
    echo "  Nothing was measured. That is not a pass."
  fi
  exit 2
fi

# ENUMERATE, never head -1. An Ostler DMG holds TWO install.sh.
APPS=$(find "$MP" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')
if [ "$APPS" = "0" ]; then
  echo "CANNOT-RUN: no .app at the top level of the image. Nothing was measured."
  exit 2
fi
APP=$(find "$MP" -maxdepth 1 -name '*.app' | head -1)
echo " apps on the image: $APPS"
[ "$APPS" = "1" ] || say "CHECK" "more than one .app on the image; walking $(basename "$APP")"

# IDENTITY BEFORE ANY VERDICT. A mounted volume whose identity you never
# established can carry any version at all.
SHORT=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo " identity: $(basename "$APP")  $SHORT ($BUILD)"
echo

# ---- ARM 8. FIRST. VETO. ------------------------------------------------
echo "ARM 8  first run must not break the signature"
W8="$WORK/a8"; mkdir -p "$W8/home"
/usr/bin/ditto "$APP" "$W8/app"
PY="$W8/app/Contents/Resources/python/bin/python3.11"
if [ ! -x "$PY" ]; then
  say "CANNOT" "  no bundled interpreter at Contents/Resources/python/bin/python3.11"
else
  BEFORE=$(find "$W8/app" -name '*.pyc' | wc -l | tr -d ' ')
  /usr/bin/codesign --verify --deep --strict "$W8/app" >/dev/null 2>&1 && RC0=0 || RC0=1
  echo "  baseline: pyc=$BEFORE codesign rc=$RC0"
  if [ "$RC0" != "0" ]; then
    say "CANNOT" "  the ditto copy does not verify BEFORE we touch it; nothing below would mean anything"
  else
    # The customer's real shape: a venv built from the bundled interpreter,
    # then a LATER unguarded run under launchd's empty environment.
    env -u PYTHONPYCACHEPREFIX -u PYTHONDONTWRITEBYTECODE HOME="$W8/home" \
        "$PY" -m venv "$W8/home/.venv" >/dev/null 2>&1 || true
    env -i HOME="$W8/home" PATH=/usr/bin:/bin \
        "$W8/home/.venv/bin/python3" -c 'import json, ssl, sqlite3, urllib.request, email.parser' >/dev/null 2>&1 || true
    AFTER=$(find "$W8/app" -name '*.pyc' | wc -l | tr -d ' ')
    /usr/bin/codesign --verify --deep --strict "$W8/app" >/dev/null 2>&1 && RC1=0 || RC1=1
    echo "  after an unguarded first use: pyc=$AFTER codesign rc=$RC1"
    # THE PREDICATE IS "NO NEW WRITES", NOT "NO .pyc AT ALL".
    #
    # AFTER = 0 was correct while the bundle shipped with zero .pyc and any .pyc
    # at all was proof of a write. From v1.0.46 the bundle SEEDS its stdlib --
    # 1448 .pyc, deliberately, inside the seal (#1052, and #1085 which made all
    # 1448 unchecked-hash) -- because a pre-seeded unchecked-hash .pyc is one
    # the interpreter can never be provoked into rewriting.
    #
    # Against that artefact AFTER = 0 is false BY CONSTRUCTION. Measured on the
    # shipped v1.0.46 app: 1448 .pyc at rest, before anything runs. So this arm
    # would have returned 🔴 VETO on the artefact FOR CARRYING THE FIX, and
    # ARM 8 is the veto arm -- it runs FIRST and it is the one that decides.
    #
    # AFTER = BEFORE is the invariant that actually says "first use wrote
    # nothing into the bundle", and it holds in both worlds: 0 = 0 for an
    # unseeded bundle, 1448 = 1448 for a seeded one.
    #
    # codesign stays an INDEPENDENT arm rather than being folded into the
    # count, because the two failures are different shapes. A rewrite-in-place
    # changes no count at all: on the shipped v1.0.46, one bare-env import
    # rewrote 45 timestamp-mode .pyc with the count sitting at 1448 -> 1448 and
    # __pycache__ dirs at 134 -> 134, while codesign went 0 -> 1. Either signal
    # alone is a veto.
    if [ "$AFTER" = "$BEFORE" ] && [ "$RC1" = "0" ]; then
      say "PASS" "  the bundle survives its own first use (pyc $BEFORE -> $AFTER, unchanged)"
    else
      say "FAIL" "  🔴 VETO. first use changed the bundle: pyc $BEFORE -> $AFTER, codesign rc=$RC1"
    fi

    # ---- 8b. THE IMPORT ABOVE ONLY TOUCHES MODULES THAT ARE SEEDED ------
    #
    # Everything imported above -- json, ssl, sqlite3, urllib.request,
    # email.parser -- is stdlib, and from #1052 the stdlib is seeded. A seeded
    # unchecked-hash .pyc cannot be rewritten, so that import can no longer
    # provoke a write and arm 8 passes.
    #
    # THE PRODUCT'S OWN PYTHON IS NOT SEEDED. Measured on the shipped v1.0.47:
    # 1888 .py in the bundle, 1448 seeded, 440 with NO .pyc -- Ostler.app 86,
    # cm019_preferences 78, cm048_pipeline 32, ostler_fda 30, doctor 30,
    # ostler_security 29. Importing one of those under an empty environment
    # CREATES a .pyc inside the seal:
    #
    #   .pyc 1448 -> 1449   codesign rc=1   file added: 1
    #
    # So the two versions fail on OPPOSITE counters -- v1.0.46 rewrote 20 in
    # place with the count unchanged, v1.0.47 adds one with nothing rewritten --
    # and an arm that only ever imports seeded modules sees neither the second
    # shape nor the day someone adds an unseeded entry point.
    #
    # The count+rc predicate above is right and unchanged. What was missing is
    # that nothing ever EXERCISED the uncovered half.
    UNSEEDED=$(/usr/bin/python3 - "$W8/app" <<'PROBE'
import sys, os
app = sys.argv[1]
best = None
for root, dirs, files in os.walk(app):
    if "__pycache__" in root:
        continue
    if "__init__.py" not in files:
        continue
    src = os.path.join(root, "__init__.py")
    if os.path.exists(os.path.join(root, "__pycache__", "__init__.cpython-311.pyc")):
        continue
    sz = os.path.getsize(src)
    # smallest wins: a 0-byte __init__ imports with no side effects at all
    if best is None or sz < best[0]:
        best = (sz, root)
print(best[1] if best else "")
PROBE
)
    # 🔴 THE HAZARD IS "UNCOVERED **AND IMPORTABLE**", NOT "UNCOVERED".
    #
    # A .pyc is only ever written for a module that is IMPORTED. CPython never
    # caches bytecode for the script it runs as __main__. Measured on the
    # pinned interpreter that actually ships (3.11.15, cache_tag cpython-311),
    # with the control firing in the same run:
    #
    #     a module that is IMPORTED    -> __pycache__/x.cpython-311.pyc appears
    #     a script run as __main__     -> nothing is written, ever
    #
    # So counting every uncovered .py over-approximates the hazard, and this is
    # a VETO arm: over-approximating here BLOCKS A GOOD CUT.
    #
    # It already would have. On v1.0.47 with the #1095 and #1096 seeds applied,
    # the single remaining uncovered file is
    #   .../assistant-agent/OstlerAssistant.app/.../ingest/email-ingest/mark_first_ingest.py
    # which release/ingest-ticks/email-ingest/tick.sh:185 invokes BY PATH
    #   "$OSTLER_PYTHON" "$MARK_FIRST_INGEST" --sidecar "$SIDECAR"
    # as __main__, and which nothing in the daemon imports. It cannot write a
    # .pyc, so it cannot break the seal.
    #
    # And it is not ours to seed either: gui/Makefile:1230 ditto's that bundle
    # in already signed, and gui/Makefile:1253 VERIFIES its Developer ID against
    # the Team pin. Writing a .pyc into it would break the seal that check reads.
    # The outer sign is deliberately NO --deep (v1.0.16) for the same reason.
    #
    # A file is forgiven ONLY when all three hold, and the reason is printed:
    #   - it is not a package __init__.py (those are always imported)
    #   - it carries an `if __name__ == "__main__":` guard
    #   - no OTHER .py in the bundle mentions its module name, and no .sh in the
    #     bundle contains an import-shaped reference to it
    # Anything else counts as a hazard. Doubt vetoes.
    COVER_OUT=$(/usr/bin/python3 - "$W8/app" <<'COVER'
import sys, os, re
app = sys.argv[1]

pys, shs = [], []
for root, dirs, files in os.walk(app):
    if "__pycache__" in root:
        continue
    for f in files:
        if f.endswith(".py"):
            pys.append(os.path.join(root, f))
        elif f.endswith(".sh"):
            shs.append(os.path.join(root, f))

def read(q):
    try:
        return open(q, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        return ""

ptext = {q: read(q) for q in pys}
shtext = "\n".join(read(q) for q in shs)

uncovered = exempt = hazard = 0
for q in pys:
    d, f = os.path.dirname(q), os.path.basename(q)
    if os.path.exists(os.path.join(d, "__pycache__", f[:-3] + ".cpython-311.pyc")):
        continue
    uncovered += 1
    rel, stem = os.path.relpath(q, app), f[:-3]
    word = r"\b" + re.escape(stem) + r"\b"
    named_by_py = any(re.search(word, t) for o, t in ptext.items() if o != q)
    named_by_sh = re.search(r"import(?:_module)?\s*\(?\s*['\"]?" + re.escape(stem) + r"\b", shtext)
    is_main = re.search(r"^if\s+__name__\s*==\s*['\"]__main__['\"]", ptext[q], re.M)
    if f != "__init__.py" and is_main and not named_by_py and not named_by_sh:
        exempt += 1
        if exempt <= 8:
            sys.stderr.write("    exempt, cannot write a .pyc (runs as __main__, imported by nothing): %s\n" % rel)
    else:
        hazard += 1
        if hazard <= 8:
            sys.stderr.write("    HAZARD, uncovered and importable: %s\n" % rel)

print("%d %d %d %d" % (len(pys), uncovered, exempt, hazard))
COVER
) || COVER_OUT=""
    if [ -z "$COVER_OUT" ]; then
      say "CANNOT" "  could not count .pyc coverage; an unmeasured seal is not a verified one"
      HAZARD_N=""
    else
      PY_TOTAL=$(printf '%s' "$COVER_OUT" | /usr/bin/awk '{print $1}')
      UNCOVERED_N=$(printf '%s' "$COVER_OUT" | /usr/bin/awk '{print $2}')
      EXEMPT_N=$(printf '%s' "$COVER_OUT" | /usr/bin/awk '{print $3}')
      HAZARD_N=$(printf '%s' "$COVER_OUT" | /usr/bin/awk '{print $4}')
      echo "  .py examined $PY_TOTAL | uncovered $UNCOVERED_N | exempt $EXEMPT_N | hazard $HAZARD_N"
      if [ "$HAZARD_N" != "0" ]; then
        say "FAIL" "  🔴 VETO. $HAZARD_N .py in the bundle are uncovered AND importable; the first import of any one writes into the seal"
      fi
    fi

    if [ -z "$UNSEEDED" ]; then
      if [ "${HAZARD_N:-1}" = "0" ]; then
        say "PASS" "  every importable .py in the bundle is seeded; nothing can be created"
      else
        echo "  (no inert package-init left to probe, but the count above already vetoed)"
      fi
    else
      B2=$(find "$W8/app" -name '*.pyc' | wc -l | tr -d ' ')
      PKG=$(basename "$UNSEEDED"); PARENT=$(dirname "$UNSEEDED")
      echo "  probing an UNSEEDED module: ${UNSEEDED#"$W8/app/"}"
      env -i HOME="$W8/home" PATH=/usr/bin:/bin \
          "$PY" -c "import sys; sys.path.insert(0, '$PARENT'); import $PKG" >/dev/null 2>&1 || true
      A2=$(find "$W8/app" -name '*.pyc' | wc -l | tr -d ' ')
      /usr/bin/codesign --verify --deep --strict "$W8/app" >/dev/null 2>&1 && RC2=0 || RC2=1
      echo "  after importing it: pyc=$A2 codesign rc=$RC2"
      if [ "$A2" = "$B2" ] && [ "$RC2" = "0" ]; then
        say "PASS" "  an unseeded module can be imported without writing into the seal"
      else
        say "FAIL" "  🔴 VETO. importing an unseeded module wrote into the bundle: pyc $B2 -> $A2, codesign rc=$RC2"
      fi
    fi
  fi
fi
echo

# ---- ARMS 1-7 -----------------------------------------------------------
#
# BROKEN AND UNMEASURABLE ARE DIFFERENT VERDICTS, and these four arms used to
# collapse them. Each ran its tool with output sent to /dev/null and branched on
# nothing but the exit code, so ANY reason for a non-zero rc printed as a
# specific, confident, wrong claim about the artefact.
#
# Demonstrated on a walk whose attach failed, so $APP was never there:
#
#     FAIL     rc=1
#     FAIL     not stapled
#     FAIL     none found
#
# That reads as an unsigned, unnotarised DMG with no installer in it, a
# catastrophic cut-blocker, when in truth NOTHING WAS MEASURED. All three arms
# discarded the one line that said so: "No such file or directory".
#
# This estate's expensive failure is the FALSE cut-blocker, and arm 7 below
# already had the answer: separate the unreadable from the bad, and print the
# denominator. These four now do the same. A missing target or a missing tool is
# CANNOT-RUN. Only a tool that ran and disagreed is a FAIL, and it prints what
# it disagreed with.
#
# The tools name the artefact before they name the problem, and the artefact
# path is long. Truncating raw keeps the half the reader already knows and
# throws away the half they need, so collapse the path to <app> first.
why() { tr '\n' ' ' | sed "s|$APP|<app>|g" | tr -s ' ' | cut -c1-160; }

ARMS_TARGET_OK=1
if [ ! -d "$APP" ]; then
  ARMS_TARGET_OK=0
fi

echo "ARM 1  codesign at rest"
if [ "$ARMS_TARGET_OK" = "0" ]; then
  say "CANNOT" "  $APP is not there -- nothing was verified, and that is not a signing failure"
elif /usr/bin/codesign --verify --deep --strict "$APP" >"$WORK/cs.err" 2>&1; then
  say "PASS" "  rc=0"
else
  CS_RC=$?
  # codesign prints the path on line 1 and the REASON on line 2, so head -1
  # would print the least useful half.
  say "FAIL" "  rc=$CS_RC: $(why < "$WORK/cs.err")"
fi

echo "ARM 2  notarisation stapled"
if [ "$ARMS_TARGET_OK" = "0" ]; then
  say "CANNOT" "  $APP is not there -- staple state unknown, which is not 'not stapled'"
elif ! /usr/bin/xcrun --find stapler >/dev/null 2>&1; then
  say "CANNOT" "  xcrun cannot find stapler on this host -- staple state unknown"
elif /usr/bin/xcrun stapler validate "$APP" >"$WORK/st.err" 2>&1; then
  say "PASS" "  stapled"
else
  # stapler reports on STDOUT, so capturing only stderr left the FAIL with a
  # bare rc and no cause. Measured: a non-stapled bundle gives rc=66 and prints
  # nothing but "Processing: <path>", so on this arm the RC is the information.
  ST_RC=$?
  say "FAIL" "  rc=$ST_RC: $(why < "$WORK/st.err")"
fi

echo "ARM 3  Gatekeeper accepts it as a notarised installer"
if [ "$ARMS_TARGET_OK" = "0" ]; then
  say "CANNOT" "  $APP is not there -- Gatekeeper was never asked"
else
  SPCTL=$(/usr/sbin/spctl -a -vvv -t install "$APP" 2>&1 || true)
  case "$SPCTL" in
    *"source=Notarized Developer ID"*) say "PASS" "  source=Notarized Developer ID" ;;
    "") say "CANNOT" "  spctl printed nothing at all -- no verdict was returned" ;;
    *) say "FAIL" "  $(printf '%s' "$SPCTL" | why)" ;;
  esac
fi

echo "ARM 4  every install.sh on the image (enumerated, never head -1)"
# A zero here has two shapes: an image with no install.sh, and a find that could
# not read the mountpoint. They print identically unless find's stderr is kept.
if [ ! -d "$MP" ]; then
  say "CANNOT" "  $MP is not a directory -- the image is not mounted, so 0 means 'could not look'"
else
  find "$MP" -name install.sh -type f > "$WORK/ish" 2>"$WORK/ish.err"
  N=$(wc -l < "$WORK/ish" | tr -d ' ')
  echo "  count: $N"
  if [ "$N" -ge 1 ]; then
    say "PASS" "  $N present"
  elif [ -s "$WORK/ish.err" ]; then
    say "CANNOT" "  find could not read the image: $(why < "$WORK/ish.err")"
  else
    say "FAIL" "  none found"
  fi
fi

# Arms 5 and 6 check EVERY install.sh, not the first.
#
# The earlier version `head -1`'d this list, in a script whose arm 4 header says
# "enumerated, never head -1". On v1.0.45 the two copies are byte-identical
# (same sha256, 1,287,082 bytes) so the answer was right BY LUCK. A cut that
# shipped a stale payload copy would have walked straight past it, and the
# payload copy is the one that ends up in /Applications.
each_install_sh() { # $1 pattern, $2 arm label, $3 verdict-when-missing
  local pattern="$1" label="$2" missing_verdict="$3"
  local n=0 hit=0 f
  while IFS= read -r f; do
    n=$((n+1))
    if /usr/bin/grep -q "$pattern" "$f" 2>/dev/null; then
      hit=$((hit+1))
    else
      echo "    absent in ${f#$MP/}"
    fi
  done < "$WORK/ish"
  echo "  $hit of $n copies carry it"
  if [ "$n" -eq 0 ]; then
    say "CANNOT" "  no install.sh to check"
  elif [ "$hit" -eq "$n" ]; then
    say "PASS" "  $label"
  elif [ "$hit" -eq 0 ]; then
    say "$missing_verdict" "  $label: absent from every copy"
  else
    say "FAIL" "  $label: THE COPIES DISAGREE ($hit of $n). One of them ships without it."
  fi
}

echo "ARM 5  the interpreter is NOT an import root inside the app"
each_install_sh '_ostler_relocate_bundled_python' 'install.sh relocates it out of the bundle' 'CHECK'

echo "ARM 6  install.sh sets the bytecode redirect itself"
each_install_sh 'PYTHONPYCACHEPREFIX' 'the guard is present' 'FAIL' 

# ARM 7 IS THE SIBLING OF ARM 8, AND IT WENT STALE THE SAME WAY.
#
# It used to be `SHIPPED = 0`: no .pyc anywhere on the image. That was right
# while the bundle shipped none and any .pyc was contraband. From v1.0.46 the
# bundle SEEDS its stdlib on purpose (#1052), so zero is now the FAILING state
# -- it would mean the seeding never ran -- and a non-zero count is the goal.
#
# Measured on the shipped v1.0.46 image: 1448 .pyc. Under the old predicate
# that read FAIL "1448 already in the artefact", which is the artefact being
# marked down for carrying its own fix. I corrected ARM 8 for exactly this and
# missed ARM 7 ninety lines below it; fixing the instance is not fixing the
# class.
#
# The question is no longer "are there .pyc" but "can any of them be REWRITTEN
# in place", because a rewrite inside a signed bundle breaks the seal without
# moving the count -- v1046-D001, 45 files, count 1448 -> 1448.
#
# PEP 552 flag word at offset 4:
#     0 timestamp       validated against .py mtime   -> REWRITABLE
#     1 unchecked-hash  never validated               -> SAFE
#     3 checked-hash    validated against .py hash    -> REWRITABLE
# Read with od so no interpreter is involved, and so an unreadable file is
# CANNOT-RUN rather than a silent pass.
echo "ARM 7  every shipped .pyc must be unrewritable (unchecked-hash)"
SHIPPED=$(find "$MP" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SHIPPED" = "0" ]; then
  say "FAIL" "  0 .pyc on the image -- the stdlib seeding did not run"
else
  BADMODE=0
  UNREAD=0
  while IFS= read -r -d '' f; do
    fl="$(od -An -tu4 -j4 -N4 "$f" 2>/dev/null | tr -d ' \n')"
    if [ -z "$fl" ]; then UNREAD=$((UNREAD + 1))
    elif [ "$fl" != "1" ]; then BADMODE=$((BADMODE + 1)); fi
  done < <(find "$MP" -name '*.pyc' -type f -print0 2>/dev/null)
  echo "  $SHIPPED seeded; $BADMODE not unchecked-hash; $UNREAD unreadable"
  if [ "$UNREAD" != "0" ]; then
    say "CANNOT" "  $UNREAD .pyc could not be read -- that is not a pass"
  elif [ "$BADMODE" = "0" ]; then
    say "PASS" "  all $SHIPPED are unchecked-hash and cannot be rewritten"
  else
    say "FAIL" "  🔴 $BADMODE of $SHIPPED are rewritable -- v1046-D001, the seal can break with the count unchanged"
  fi
fi

echo
echo "=============================================================="
printf " PASS %s   FAIL %s   CANNOT-RUN %s\n" "$pass" "$fail" "$cannot"
if [ "$fail" -gt 0 ]; then
  echo " VERDICT: NO-GO"; exit 1
elif [ "$cannot" -gt 0 ]; then
  echo " VERDICT: CANNOT-RUN. Not a pass. Nothing was proved."; exit 2
fi
echo " VERDICT: GO on the artefact. This says nothing about the INSTALL."
echo "=============================================================="
