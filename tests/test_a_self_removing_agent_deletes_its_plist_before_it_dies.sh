#!/usr/bin/env bash
# A self-removing LaunchAgent must delete its files BEFORE it boots itself out.
#
# WHY THIS EXISTS. MEASURED on the v1.0.66 artefact, archie@192.168.1.240,
# 2026-09-05. The dedupe catch-up agent had done its job -- the converge was
# marked complete at 06:07:28 -- and it had called remove_self(). The label was
# gone from the launchd domain. Both the plist AND the tries file were still on
# disk:
#
#     ~/Library/LaunchAgents/com.creativemachines.ostler.dedupe-catchup.plist
#     ~/.ostler/state/dedupe-catchup.tries
#
# THE MECHANISM, PROVED BY EXECUTION, NOT BY READING. remove_self() ran
# `launchctl bootout` on its OWN label and then `rm -f`. A 10-iteration probe
# on that Mac: the line BEFORE the bootout was reached 10/10, the line AFTER it
# 0/10. launchd tears the job down before control returns, so the rm was
# unreachable dead code. install.sh :1457 already notes that bootout returns as
# soon as launchd ACCEPTS the request, which is what makes this look survivable
# on a reading and not be.
#
# WHY IT MATTERS TO A CUSTOMER. ~/Library/LaunchAgents is read again at every
# login. A plist left behind is re-loaded, so a "self-removing" agent came back
# on every reboot, for the life of the machine, and the surviving tries file
# carried its old count back with it. Three agents shipped this shape.
#
# THE INVARIANT IS ORDER, NOT PRESENCE. Both statements exist in the broken
# form and in the fixed one. Only their order differs, so a test that greps for
# either line alone passes on both trees and proves nothing.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

# Emit one line per remove_self body: "<startline> <rm_offset> <bootout_offset>".
# Offsets are line numbers within the body; 0 means the statement is absent.
_bodies() {
    awk '
        /^[[:space:]]*remove_self\(\)[[:space:]]*\{/ { inb=1; n=0; s=NR; rm=0; bo=0; next }
        inb {
            n++
            # A COMMENT IS NOT CODE. The fixed bodies carry a comment block that
            # names both statements, and grading the prose put "bootout" before
            # the real rm and mis-flagged a correct tree. Neither hand-built
            # control caught it, because neither carries comments.
            if ($0 ~ /^[[:space:]]*#/) {
                if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) { print s, rm, bo; inb=0 }
                next
            }
            if (rm == 0 && $0 ~ /rm -f[[:space:]]+"\$PLIST"/)            rm = n
            if (bo == 0 && $0 ~ /launchctl[[:space:]]+bootout/)          bo = n
            if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) { print s, rm, bo; inb=0 }
        }
    ' "$1"
}

_grade() {   # _grade <file> <label>; echoes "<total> <good> <bad> <missing>"
    local tot=0 good=0 wrong=0 miss=0 s rm bo
    while read -r s rm bo; do
        tot=$((tot+1))
        if [ "$rm" -eq 0 ] || [ "$bo" -eq 0 ]; then miss=$((miss+1))
        elif [ "$rm" -lt "$bo" ]; then good=$((good+1))
        else wrong=$((wrong+1)); fi
    done < <(_bodies "$1")
    printf '%s %s %s %s' "$tot" "$good" "$wrong" "$miss"
}

echo "── subject: this tree ──"
read -r TOT GOOD WRONG MISS <<<"$(_grade "$SUBJECT")"
echo "    remove_self bodies found: ${TOT}  (rm-first ${GOOD} / bootout-first ${WRONG} / incomplete ${MISS})"

if [ "$TOT" -eq 0 ]; then
    echo "CANNOT-RUN: no remove_self() body was found in install.sh. The extractor" >&2
    echo "  matches nothing, so a green result here would mean 'could not look'," >&2
    echo "  not 'all correct'." >&2
    exit 2
fi

[ "$TOT" -ge 3 ] \
    && ok "all ${TOT} self-removing agents are visible to the extractor" \
    || bad "only ${TOT} remove_self bodies found; three shipped in v1.0.66, so the extractor has gone blind to at least one"

[ "$WRONG" -eq 0 ] \
    && ok "no body boots itself out before deleting its files" \
    || bad "${WRONG}/${TOT} bodies call bootout BEFORE rm -- everything after the bootout is unreachable, and the plist survives to be re-loaded at next login"

[ "$MISS" -eq 0 ] \
    && ok "every body has BOTH statements, so none silently stopped removing its files" \
    || bad "${MISS}/${TOT} bodies are missing the rm or the bootout entirely"

# The plist must not be addressed by PATH after it has been deleted: `launchctl
# unload "$PLIST"` needs the file, so it cannot be a fallback once rm has run.
# bootout addresses the job by LABEL and does not.
if _bodies "$SUBJECT" >/dev/null && awk '
        /^[[:space:]]*remove_self\(\)[[:space:]]*\{/ { inb=1; next }
        inb {
            if ($0 ~ /^[[:space:]]*#/) { next }
            if ($0 ~ /launchctl[[:space:]]+unload/) { found=1 }
            if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) { inb=0 }
        }
        END { exit (found ? 1 : 0) }
    ' "$SUBJECT"; then
    ok "no body still falls back to 'launchctl unload \$PLIST', which cannot work once the plist is gone"
else
    bad "a remove_self body still calls 'launchctl unload \$PLIST' after deleting that same plist"
fi

# ── MUST-MISS CONTROL ────────────────────────────────────────────────────
# A hand-built body in the CORRECT order must grade clean. Without this, a
# predicate that flagged everything unconditionally would pass every limb above.
_TMP="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$_TMP"' EXIT
cat > "${_TMP}/good.sh" <<'GOOD'
remove_self() {
    rm -f "$PLIST" "$TRIES_FILE"
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
}
GOOD
read -r T2 G2 W2 M2 <<<"$(_grade "${_TMP}/good.sh")"
[ "$T2" -eq 1 ] && [ "$W2" -eq 0 ] && [ "$M2" -eq 0 ] \
    && ok "MUST-MISS CONTROL: a correctly ordered body grades clean (${G2}/1 rm-first)" \
    || bad "MUST-MISS CONTROL: a correctly ordered body was graded ${W2} wrong / ${M2} incomplete. The predicate flags regardless of order and proves nothing."

# ── MUST-FLAG CONTROL ────────────────────────────────────────────────────
cat > "${_TMP}/bad.sh" <<'BAD'
remove_self() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TRIES_FILE"
}
BAD
read -r T3 G3 W3 M3 <<<"$(_grade "${_TMP}/bad.sh")"
[ "$T3" -eq 1 ] && [ "$W3" -eq 1 ] \
    && ok "MUST-FLAG CONTROL: the shipped v1.0.66 ordering is detected as bootout-first" \
    || bad "MUST-FLAG CONTROL: the known-broken body graded ${W3} wrong out of ${T3}. The predicate cannot see the defect it exists for."

# ── NEGATIVE CONTROL, pinned to the tree that SHIPPED the defect ─────────
# c5bfd5f8 is origin/main immediately before this fix, and is the tree whose
# built artefact left the dedupe plist on disk at .240. Pinned to a fixed sha,
# never a branch: a control that reads origin/main inverts the moment this
# merges.
_CONTROL_SHA="c5bfd5f8"
echo "── negative control: ${_CONTROL_SHA} (the tree whose agent left its plist behind) ──"
_CTL="${_TMP}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_CTL" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and grading nothing must not read as" >&2
    echo "  a passing control." >&2
    exit 2
fi
read -r T4 G4 W4 M4 <<<"$(_grade "$_CTL")"
if [ "$T4" -eq 0 ]; then
    echo "CANNOT-RUN: no remove_self body found in the control blob either." >&2
    exit 2
fi
[ "$W4" -ge 3 ] \
    && ok "control ${_CONTROL_SHA}: ${W4}/${T4} bodies boot out first, reproducing the defect measured on the box" \
    || bad "control ${_CONTROL_SHA}: only ${W4}/${T4} bodies grade as bootout-first. That tree DID leave a plist on a real Mac, so this harness is not measuring the defect."

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
