#!/usr/bin/env bash
# Every module the installer runs must exist in the copy it installs.
#
# WHY THIS EXISTS. MEASURED on the walk box, 2026-09-04, walks 11 and 12, from
# the installer's own diagnostic logs:
#
#   hydrate-contacts.log
#     File ".../import-pipeline/contact_syncer/syncer.py", line 35
#       from contact_syncer.photo_storage import remove_photo, write_photo
#     ModuleNotFoundError: No module named 'contact_syncer.photo_storage'
#
#   places-ingest.log
#     .../import-pipeline/.venv/bin/python: No module named
#       contact_syncer.places_ingest
#
# CONSEQUENCE, and it is customer-visible: hydrate_graph dies at elapsed_s=0
# and the customer is told "Your contacts are on this Mac but Ostler imported
# 0 of them". The Places build fails the same way. The install still reaches
# its end and reports DONE status=ok, so it looks finished.
#
# THE CAUSE IS TWO COPIES OF ONE PACKAGE. install.sh:17729 copies the ROOT
# `contact_syncer/` into ~/.ostler/import-pipeline. A second, COMPLETE copy
# lives at vendor/cm041/contact_syncer/. The root copy had 19 modules, the
# vendored one 24, and the five it lacked included the two above. The two
# syncer.py files are not identical either (65,023 vs 64,362 bytes), so the
# root copy is a diverged partial, not a stale mirror.
#
# HOW LONG: present in v1.0.60 through v1.0.65 inclusive, every tag checked.
# Not a recent regression. Earlier walks never reached step 32.
#
# THE INSTRUMENT IS find_spec, WHICH IS THE MECHANISM ModuleNotFoundError
# ITSELF REPORTS ON. It resolves a module without executing it, so a missing
# THIRD-PARTY dependency (httpx, qdrant_client) cannot be mistaken for a
# missing FIRST-PARTY module. Those are different findings with different
# fixes, and an import-and-catch test would merge them.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Resolve every module a package needs, against a given tree.
# Args: <tree root> <package>
# Prints "OK" or "MISSING: a b c", or "NOPKG".
_resolve() {
    python3 - "$1" "$2" "$SUBJECT" <<'PY'
import os, re, sys
root, pkg, installsh = sys.argv[1], sys.argv[2], sys.argv[3]
pkgdir = os.path.join(root, pkg)
if not os.path.isdir(pkgdir):
    print("NOPKG"); raise SystemExit(0)

# THE CONSUMER NAMES THE ENTRY POINTS. Reading them out of install.sh rather
# than hardcoding a list means a newly invoked module is covered the day it is
# invoked, not the day someone remembers to update this test.
src = open(installsh, encoding="utf-8", errors="replace").read()
want = set(re.findall(r'-m\s+' + re.escape(pkg) + r'\.([A-Za-z_]\w*)', src))

# ...plus every intra-package import inside the package itself, which is how
# the measured failure actually presented: syncer.py was invoked fine and died
# importing a sibling.
imp = re.compile(
    r'^\s*(?:from\s+' + re.escape(pkg) + r'\.([A-Za-z_]\w*)'
    r'|from\s+\.([A-Za-z_]\w*)\s+import'
    r'|import\s+' + re.escape(pkg) + r'\.([A-Za-z_]\w*))', re.M)
for f in sorted(os.listdir(pkgdir)):
    if not f.endswith(".py"):
        continue
    s = open(os.path.join(pkgdir, f), encoding="utf-8", errors="replace").read()
    for m in imp.finditer(s):
        want.add(m.group(1) or m.group(2) or m.group(3))
want.discard(None)
if not want:
    # A zero denominator must not read as success.
    print("NOPKG"); raise SystemExit(0)

# RESOLVE BY PATH, NOT BY find_spec. find_spec("pkg.mod") IMPORTS pkg first,
# so a package whose __init__ pulls a third-party dependency raises
# ModuleNotFoundError for THAT dependency and the submodule question is never
# answered. MEASURED on the walk box: probing ostler_security died on
# `No module named cryptography`, which says nothing about whether the
# first-party submodule exists. Reporting that as a missing module would be a
# false positive of exactly the kind this test exists to prevent.
#
# What the import system looks for when resolving `pkg.mod` inside a package
# directory is `<pkgdir>/mod.py` or `<pkgdir>/mod/__init__.py`. Checking that
# directly needs no execution and cannot be defeated by a heavy __init__.
missing = []
for m in sorted(want):
    if not (os.path.isfile(os.path.join(pkgdir, m + ".py"))
            or os.path.isfile(os.path.join(pkgdir, m, "__init__.py"))):
        missing.append(m)
print("MISSING: " + " ".join(missing) if missing else "OK")
PY
}

echo "── subject: the tree that gets copied into ~/.ostler/import-pipeline ──"

# install.sh copies exactly these three. Read from the script so the list
# cannot drift away from what actually ships.
PKGS="$(/usr/bin/grep -oE 'cp -R "\$\{SCRIPT_DIR\}/[a-z_]+"' "$SUBJECT" \
        | sed -E 's|.*/([a-z_]+)"|\1|' | sort -u)"
if [ -z "$PKGS" ]; then
    echo "CANNOT-RUN: could not read the copied package list out of install.sh." >&2
    echo "  Without it this test would silently check nothing." >&2
    exit 2
fi
# NOT EVERY COPIED PACKAGE LIVES IN THIS REPO, AND A PACKAGE THIS TEST CANNOT
# SEE MUST NOT SCORE A PASS. `SCRIPT_DIR` at install time is the DMG's
# Contents/Resources, not the repo root; ostler_fda, ostler_security,
# ostler_hygiene, meeting_syncer and identity_resolver reach it from elsewhere
# in the cut pipeline. Counting those as passes would have made this suite
# report 9 green while examining exactly one package. Set OSTLER_ARTEFACT_ROOT
# to a mounted DMG's Contents/Resources to examine them for real.
ROOTS="${REPO}"
[ -n "${OSTLER_ARTEFACT_ROOT:-}" ] && ROOTS="${ROOTS} ${OSTLER_ARTEFACT_ROOT}"
_examined=0; _skipped=""
for pkg in $PKGS; do
    _found_in=""
    for root in $ROOTS; do
        [ -d "${root}/${pkg}" ] && { _found_in="$root"; break; }
    done
    if [ -z "$_found_in" ]; then
        _skipped="${_skipped} ${pkg}"
        continue
    fi
    _examined=$((_examined+1))
    r="$(_resolve "$_found_in" "$pkg")"
    case "$r" in
        OK)        ok "${pkg}: every module install.sh invokes, and every sibling they import, resolves" ;;
        NOPKG)     bad "${pkg}: the directory exists at ${_found_in} but the resolver found nothing to check. A zero denominator is not a pass." ;;
        MISSING:*) bad "${pkg}: ${r#MISSING: } cannot be imported from the copy that gets installed. This is the measured defect." ;;
        *)         bad "${pkg}: unexpected resolver output '${r}'" ;;
    esac
done

if [ -n "$_skipped" ]; then
    printf '  [NOT EXAMINED]%s\n' "$_skipped"
    printf '                 not in this tree. They reach the DMG from elsewhere in\n'
    printf '                 the cut pipeline. Pass OSTLER_ARTEFACT_ROOT=<mounted\n'
    printf '                 DMG>/Contents/Resources to cover them. NOT counted as passes.\n'
fi

# The one package this repo genuinely ships must have been examined, or the
# suite is reporting on nothing at all.
if [ "$_examined" -lt 1 ]; then
    echo "CANNOT-RUN: 0 packages examined. install.sh names $(printf '%s' "$PKGS" | wc -w | tr -d ' ') but none were found in any root given." >&2
    exit 2
fi
if [ ! -d "${REPO}/contact_syncer" ]; then
    echo "CANNOT-RUN: contact_syncer is absent from this repo, which is where it ships from." >&2
    exit 2
fi
printf '  denominator: %s of %s copied package(s) examined%s\n' \
    "$_examined" "$(printf '%s' "$PKGS" | wc -w | tr -d ' ')" \
    "$([ -n "${OSTLER_ARTEFACT_ROOT:-}" ] && echo " (artefact root supplied)" || echo " (repo only)")"

echo "── NEGATIVE CONTROL: v1.0.65, the cut whose walk measured the failure ──"

_CONTROL_TAG="v1.0.65"
_ctldir="${WORK}/ctl"
mkdir -p "$_ctldir"
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/${_CONTROL_TAG}" >/dev/null 2>&1; then
    echo "CANNOT-RUN: tag ${_CONTROL_TAG} is not in this checkout." >&2
    echo "  A shallow or tagless clone cannot see it, and checking nothing" >&2
    echo "  must not read as a passing control." >&2
    exit 2
fi
if ! git -C "$REPO" archive "${_CONTROL_TAG}" contact_syncer 2>/dev/null | tar -x -C "$_ctldir" 2>/dev/null; then
    echo "CANNOT-RUN: could not extract contact_syncer from ${_CONTROL_TAG}." >&2
    exit 2
fi
if [ ! -d "${_ctldir}/contact_syncer" ]; then
    echo "CANNOT-RUN: the extraction produced no contact_syncer directory." >&2
    exit 2
fi

_r="$(_resolve "$_ctldir" contact_syncer)"
case "$_r" in
    *photo_storage*) ok "control ${_CONTROL_TAG}: photo_storage is unresolvable there, reproducing the ModuleNotFoundError from the box" ;;
    OK)              bad "control ${_CONTROL_TAG}: everything resolves there too. That cut DID fail on a real box, so this harness is not measuring the defect." ;;
    NOPKG)           echo "CANNOT-RUN: the control tree yielded no package to examine." >&2; exit 2 ;;
    *)               bad "control ${_CONTROL_TAG}: unexpected output '${_r}'" ;;
esac

# CONTROL ON THE CONTROL. The resolver must be capable of finding a module
# that IS present in that same tree, or its MISSING verdict above could be an
# artefact of a broken sys.path rather than a real absence.
_present="$(python3 - "$_ctldir" <<'PY'
import importlib.util, sys, os
root = sys.argv[1]
sys.path.insert(0, root)
print("FOUND" if importlib.util.find_spec("contact_syncer.config") else "NOTFOUND")
PY
)"
case "$_present" in
    FOUND) ok "CONTROL ON THE CONTROL: a module that IS in that tree resolves, so the absence above is real and not a broken path" ;;
    *)     bad "the resolver cannot find contact_syncer.config in the control tree either (${_present}); its MISSING verdict proves nothing" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
