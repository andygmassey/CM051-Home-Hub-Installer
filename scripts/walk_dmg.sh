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
    # This arm used to require AFTER = 0. That was correct when the bundle
    # shipped with zero .pyc and any .pyc was proof of a write. From v1.0.46 the
    # bundle SEEDS its stdlib -- 1448 .pyc, deliberately, inside the seal --
    # because a pre-seeded unchecked-hash .pyc is one the interpreter can never
    # be provoked into rewriting. Against that artefact AFTER = 0 is false by
    # construction, so the old predicate would have VETOED v1.0.46 for carrying
    # the very fix the veto exists to demand.
    #
    # AFTER = BEFORE is the invariant that actually means "first use wrote
    # nothing into the bundle", and it holds in both worlds: 0 = 0 for an
    # unseeded bundle, 1448 = 1448 for a seeded one.
    #
    # codesign is kept as an INDEPENDENT arm and not folded into the count,
    # because the two failures are different: a rewrite-in-place changes no
    # count at all (v1046-D001, 45 timestamp .pyc rewritten, count 1448 ->
    # 1448, codesign rc 0 -> 1). Either signal alone is a veto.
    if [ "$AFTER" = "$BEFORE" ] && [ "$RC1" = "0" ]; then
      say "PASS" "  the bundle survives its own first use (pyc $BEFORE -> $AFTER, unchanged)"
    else
      DELTA=$((AFTER - BEFORE))
      say "FAIL" "  🔴 VETO. first use changed the bundle: pyc $BEFORE -> $AFTER (delta $DELTA), codesign rc=$RC1"
    fi
  fi
fi
echo

# ---- ARMS 1-7 -----------------------------------------------------------
echo "ARM 1  codesign at rest"
/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null && say "PASS" "  rc=0" || say "FAIL" "  rc=1"

echo "ARM 2  notarisation stapled"
/usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1 && say "PASS" "  stapled" || say "FAIL" "  not stapled"

echo "ARM 3  Gatekeeper accepts it as a notarised installer"
SPCTL=$(/usr/sbin/spctl -a -vvv -t install "$APP" 2>&1 || true)
case "$SPCTL" in
  *"source=Notarized Developer ID"*) say "PASS" "  source=Notarized Developer ID" ;;
  *) say "FAIL" "  $(printf '%s' "$SPCTL" | tr '\n' ' ' | cut -c1-120)" ;;
esac

echo "ARM 4  every install.sh on the image (enumerated, never head -1)"
find "$MP" -name install.sh -type f > "$WORK/ish"
N=$(wc -l < "$WORK/ish" | tr -d ' ')
echo "  count: $N"
[ "$N" -ge 1 ] && say "PASS" "  $N present" || say "FAIL" "  none found"

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

echo "ARM 7  no .pyc shipped inside the image"
SHIPPED=$(find "$MP" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')
[ "$SHIPPED" = "0" ] && say "PASS" "  0" || say "FAIL" "  $SHIPPED already in the artefact"

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
