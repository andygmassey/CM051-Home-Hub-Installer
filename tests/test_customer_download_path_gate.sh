#!/usr/bin/env bash
# ============================================================================
# CONTROLS FOR THE CUSTOMER-DOWNLOAD-PATH GATE. An unproven gate is not a gate.
#
# The gate this drives (scripts/verify_customer_download_path.sh) shipped
# WITHOUT controls, and Archie's review found exactly what that costs: its DMG
# shape-check read `head -c 512` for a `koly` marker that UDIF stores as a
# TRAILER, at the END of the file. The grep therefore matched nothing on any
# real DMG, the `!` was always true, and the condition silently collapsed to
# `size < 1000000`. Nobody saw it because nothing had ever watched it fire.
#
# Two failures fell out of that single wrong offset:
#
#   a >1MB HTML error page   PASSED the shape check  (the gate's whole purpose)
#   a genuine DMG under 1MB  FAILED as "not a DMG"   (cry wolf on a good tree)
#
# Writing these controls then found a THIRD, which no amount of reading had:
# `code="$(curl ... || echo 000)"` captured `000000`, because curl prints `000`
# on a connection failure AND exits non-zero, so the `||` fired too. The
# unreachable-network branch was therefore dead and an offline run reported the
# customer download path BROKEN. That is limb 7.
#
# Limb 1 is a PREMISE CONTROL: it builds a real UDZO image and measures where
# `koly` actually is. If UDIF ever changes, that limb goes red and NAMES the
# reason rather than the gate quietly going blind again.
#
# Exit: 0 all controls pass | 1 a control failed | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../scripts/verify_customer_download_path.sh"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$GATE" ] || cannot "gate not readable at $GATE"
command -v curl    >/dev/null 2>&1 || cannot "curl absent -- the gate itself needs it"
command -v python3 >/dev/null 2>&1 || cannot "python3 absent -- needed to serve fixtures"

echo "== #886 controls: the customer download path gate =="

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() {
    if [ -n "$SRV_PID" ]; then
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

DOCROOT="${WORK}/docroot"; mkdir -p "$DOCROOT"

# ── 1. PREMISE CONTROL: where does `koly` actually live? ──────────
# Build a REAL UDZO image rather than reasoning about the format.
DMG_VERSION="9.9.9"
have_dmg=0
if command -v hdiutil >/dev/null 2>&1; then
    STAGE="${WORK}/stage/Ostler.app/Contents"; mkdir -p "$STAGE"
    cat > "${STAGE}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>${DMG_VERSION}</string>
</dict></plist>
PLIST
    if hdiutil create -quiet -srcfolder "${WORK}/stage" -format UDZO \
         -volname OstlerTest "${DOCROOT}/good.dmg" >/dev/null 2>&1; then
        have_dmg=1
    fi
fi

if [ "$have_dmg" -eq 1 ]; then
    # grep -c, never grep -q, in a pipe under pipefail: a short-circuiting
    # consumer reports a successful match as a failure (#895). -c must read all
    # of its input to count, so it cannot short-circuit.
    head_hits="$(head -c 512 "${DOCROOT}/good.dmg" | LC_ALL=C grep -ca 'koly' || true)"
    tail_hits="$(tail -c 512 "${DOCROOT}/good.dmg" | LC_ALL=C grep -ca 'koly' || true)"
    dmg_size="$(wc -c < "${DOCROOT}/good.dmg" | tr -d ' ')"

    if [ "${head_hits:-0}" -eq 0 ]; then
        ok "PREMISE: 'koly' is NOT in the first 512 bytes -- the original head -c 512 check could never match"
    else
        bad "PREMISE BROKEN: 'koly' WAS found in the first 512 bytes. UDIF layout has changed, or this is not a UDZO image. Every conclusion below about the offset is void -- investigate before trusting this file."
    fi

    if [ "${tail_hits:-0}" -ge 1 ]; then
        ok "PREMISE: 'koly' IS in the last 512 bytes -- it is a TRAILER, which is why the gate now reads tail"
    else
        bad "PREMISE BROKEN: no 'koly' trailer in a freshly built UDZO image. The gate's new predicate would fail every real DMG."
    fi

    if [ "$dmg_size" -lt 1000000 ]; then
        ok "a real DMG here is ${dmg_size} bytes, UNDER 1MB -- the exact tree the old predicate would have failed as 'not a DMG'"
    else
        printf '        note: fixture DMG is %s bytes, over 1MB, so the cry-wolf half is not exercised by size here\n' "$dmg_size"
    fi
else
    printf '        SKIPPED limb 1 and the DMG-serving limbs: hdiutil unavailable or the image build failed.\n'
    printf '        Those limbs are macOS-only. The HTTP limbs below still run on Linux CI.\n'
fi

# ── 2. fixtures for the non-DMG cases ─────────────────────────────
printf '<html><body>Not Found</body></html>\n' > "${DOCROOT}/error.html"
# >1MB, because THAT is the payload the old predicate waved through.
python3 -c "
import sys
open(sys.argv[1],'w').write('<html><body>' + ('padding ' * 200000) + '</body></html>')
" "${DOCROOT}/big.html"
big_size="$(wc -c < "${DOCROOT}/big.html" | tr -d ' ')"

# ── 3. serve them, so the gate does real HTTP ─────────────────────
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DOCROOT" >/dev/null 2>&1 &
SRV_PID=$!

# Wait for readiness rather than sleeping a guessed interval.
up=0
for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://127.0.0.1:${PORT}/error.html" 2>/dev/null; then up=1; break; fi
    sleep 0.1
done
[ "$up" -eq 1 ] || cannot "local fixture server never came up on 127.0.0.1:${PORT}"

run_gate() {   # url, want-version -> prints rc
    local url="$1" want="$2" rc
    OSTLER_DOWNLOAD_URL="$url" OSTLER_DOWNLOAD_POSTURE=public \
        /bin/bash "$GATE" "$want" >/dev/null 2>&1
    rc=$?
    printf '%s' "$rc"
}

# ── 4. a 200 serving an error page must FAIL, not pass ────────────
rc="$(run_gate "http://127.0.0.1:${PORT}/error.html" 1.0.37)"
if [ "$rc" = "1" ]; then
    ok "small HTML error page served with 200 -> FAIL (rc=1)"
else
    bad "small HTML error page served with 200 -> rc=${rc}, expected 1. A 200 serving an error page reads as success."
fi

# ── 5. THE REGRESSION CASE: >1MB error page ───────────────────────
# Under the old `head -c 512` predicate this PASSED outright, because the size
# conjunct was the only live half of the condition.
rc="$(run_gate "http://127.0.0.1:${PORT}/big.html" 1.0.37)"
if [ "$rc" = "1" ]; then
    ok "REGRESSION: ${big_size}-byte HTML error page -> FAIL (rc=1); the old predicate waved this through"
else
    bad "REGRESSION: ${big_size}-byte HTML error page -> rc=${rc}, expected 1. This is the precise defect Archie found; the shape check is blind again."
fi

# ── 6. a real DMG: right version passes, wrong version fails ──────
if [ "$have_dmg" -eq 1 ]; then
    rc="$(run_gate "http://127.0.0.1:${PORT}/good.dmg" "1.0.37")"
    if [ "$rc" = "1" ]; then
        ok "real DMG at ${DMG_VERSION} asked for 1.0.37 -> FAIL (rc=1), the wrong-build case"
    else
        bad "real DMG at ${DMG_VERSION} asked for 1.0.37 -> rc=${rc}, expected 1. The gate cannot tell builds apart."
    fi

    rc="$(run_gate "http://127.0.0.1:${PORT}/good.dmg" "${DMG_VERSION}")"
    if [ "$rc" = "0" ]; then
        ok "real DMG at ${DMG_VERSION} asked for ${DMG_VERSION} -> OK (rc=0)"
    elif [ "$rc" = "2" ]; then
        bad "real DMG at the right version -> rc=2 CANNOT. The gate could not mount it or could not read the version, so it has no opinion where it should have one."
    else
        bad "real DMG at the right version -> rc=${rc}, expected 0. This is the cry-wolf direction: a correct tree reported as broken."
    fi
fi

# ── 7. unreachable network is CANNOT, never a verdict ─────────────
# This limb is why the controls were worth writing. `|| echo 000` doubled the
# captured value to `000000`, so the CANNOT branch was unreachable and an
# offline run declared the customer download path BROKEN.
DEAD="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)')"
rc="$(run_gate "http://127.0.0.1:${DEAD}/install.dmg" 1.0.37)"
if [ "$rc" = "2" ]; then
    ok "unreachable host -> CANNOT (rc=2), not a verdict on the URL"
else
    bad "unreachable host -> rc=${rc}, expected 2. A gate that cannot reach the network must not get to have an opinion about it. Check for '|| echo 000' having come back."
fi

# ── 8. the trap fix: no temp file survives the run ────────────────
# `trap ... EXIT` REPLACES rather than appends, so the gate's original two traps
# leaked the first temp file on every run. Assert BEHAVIOUR, not the source text.
#
# 🔴 THE OBVIOUS WAY TO WRITE THIS LIMB IS VACUOUS. The first version set
# TMPDIR to a private directory and counted what was left in it. Measured:
#
#     TMPDIR=/private/dir mktemp   ->  /var/folders/.../tmp.QoIRnq0GZZ
#
# BSD mktemp does not honour TMPDIR, so that limb watched an empty directory
# nothing ever wrote to and passed on the FIXED and the BROKEN gate alike. It
# was a control pointed at the wrong object.
#
# So intercept `mktemp` itself on PATH. Now every temp path the gate takes is
# one we chose, and what is left afterwards is exactly what leaked.
STUB="${WORK}/bin"; mkdir -p "$STUB"
TMPROOT="${WORK}/tmproot"; mkdir -p "$TMPROOT"
cat > "${STUB}/mktemp" <<'STUBEOF'
#!/bin/bash
root="${OSTLER_TEST_TMPROOT:?stub mktemp needs OSTLER_TEST_TMPROOT}"
n="$$.${RANDOM}"
case "${1:-}" in
    -d) d="${root}/d.${n}"; mkdir -p "$d"; printf '%s\n' "$d" ;;
    -u) printf '%s\n' "${root}/u.${n}" ;;
    *)  f="${root}/f.${n}"; : > "$f"; printf '%s\n' "$f" ;;
esac
STUBEOF
chmod +x "${STUB}/mktemp"

# Prove the stub is the one being used before trusting anything it reports.
stub_check="$(PATH="${STUB}:${PATH}" OSTLER_TEST_TMPROOT="$TMPROOT" mktemp)"
case "$stub_check" in
    "${TMPROOT}"/*) ok "PREMISE: the mktemp stub is on PATH and the gate's temp files are observable" ;;
    *) bad "PREMISE FAILED: mktemp resolved to ${stub_check}, outside the observed root. Limb 8 below would be vacuous -- it would watch a directory nothing writes to." ;;
esac
rm -f "$stub_check"

PATH="${STUB}:${PATH}" OSTLER_TEST_TMPROOT="$TMPROOT" \
    OSTLER_DOWNLOAD_URL="http://127.0.0.1:${PORT}/error.html" \
    OSTLER_DOWNLOAD_POSTURE=public /bin/bash "$GATE" 1.0.37 >/dev/null 2>&1
left="$(find "$TMPROOT" -type f | wc -l | tr -d ' ')"
if [ "$left" -eq 0 ]; then
    ok "no temp file survives the run -- the single EXIT trap cleans up every one"
else
    bad "${left} temp file(s) leaked. A second 'trap ... EXIT' REPLACES the first rather than adding to it, so only the last one registered gets cleaned:"
    find "$TMPROOT" -type f | sed 's/^/          /'
fi

finish
