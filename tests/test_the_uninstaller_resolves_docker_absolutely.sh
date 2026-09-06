#!/usr/bin/env bash
# The shipped uninstaller must not call a bare `docker`.
#
# MEASURED 2026-09-07 on the walk box, and it cost a customer's stores:
#
#     Uninstall FAILED ... line 273: docker: command not found
#     WARNING: YOUR DATA STORES WERE NOT REMOVED.
#
# Six containers stayed up and five named volumes -- the people graph, the
# vectors, the compiled wiki -- stayed on disk. The uninstaller reported that
# honestly, which is good design and is NOT the defect. The defect is that
# `docker compose down -v` could not run at all.
#
# THE CAUSE IS PATH, NOT DOCKER. Homebrew installs docker to /opt/homebrew/bin
# on Apple silicon or /usr/local/bin on Intel, and NEITHER is on the default
# PATH of a non-login shell -- which is what an ssh command, a launchd job, or
# a script piped to bash receives. Docker was installed and working the whole
# time; the uninstaller simply could not find it. scripts/ttywalk.sh already
# carries this exact workaround, in a comment that says why. The uninstaller
# never got it.
#
# WHY THIS TEST READS THE GENERATED FILE AND NOT install.sh. The uninstaller is
# written by a QUOTED heredoc (<<'UNINSTALLEOF'), so what install.sh contains
# and what the customer runs are the same bytes -- but only if you extract the
# heredoc. Grepping install.sh as a whole would also read the installer's OWN
# docker calls, which are a different subject with a different PATH situation,
# and it would pass or fail for reasons that have nothing to do with the
# uninstaller. Two subjects, one file.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

echo "== the shipped uninstaller resolves docker absolutely =="

[ -r "$INSTALL" ] || { cant "install.sh unreadable"; echo; exit 2; }

# ANCHOR ON THE TERMINATOR, NOT ON A LOOSE "cat > ... uninstall" MATCH. The
# first version of this gate matched an EARLIER heredoc and extracted 9,743
# lines instead of 637, which swept in the installer's own docker calls and a
# comment quoting the historical bug. Find the UNINSTALLEOF terminator, then
# walk back to the line that opens it.
END="$(awk '/^UNINSTALLEOF$/ {print NR; exit}' "$INSTALL")"
START="$(awk -v e="${END:-0}" 'NR<e && /<<.UNINSTALLEOF./ {n=NR} END {print n}' "$INSTALL")"
if [ -z "$START" ]; then
    cant "could not find the heredoc that writes ostler-uninstall. The generator moved; this gate is measuring nothing."
    printf '\n== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2
fi
if [ -z "$END" ] || [ "${START:-0}" -eq 0 ]; then
    cant "could not bracket the uninstaller heredoc (start='${START:-}' end='${END:-}')."
    printf '\n== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2
fi

UNIN="$(mktemp)"; trap 'rm -f "$UNIN"' EXIT
awk -v s="$((START+1))" -v e="$END" 'NR>=s && NR<e' "$INSTALL" > "$UNIN"
lines="$(wc -l < "$UNIN" | tr -d ' ')"
if [ "$lines" -lt 100 ]; then
    cant "extracted only ${lines} line(s) of uninstaller -- too small to be the real thing"
    printf '\n== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2
fi
ok "extracted the generated uninstaller: ${lines} lines (heredoc ${START}..${END})"

# A BARE docker invocation: `docker` at a command position, i.e. at the start of
# a line or after a common separator, and NOT preceded by / or " (an absolute
# path or a quoted variable expansion).
bare_docker() {
    # Exclude COMMENTS and ECHOED INSTRUCTIONS. Both mention `docker ...` as
    # prose -- one quotes the historical bug, the other tells the customer what
    # to run by hand -- and neither is an invocation. Flagging them would train
    # a reader to ignore this gate.
    /usr/bin/grep -nE '(^|[;&|(]|[[:space:]]&&[[:space:]]|\$\()[[:space:]]*docker[[:space:]]+(compose|volume|ps|rm|stop)' "$1" \
        | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#' \
        | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*(echo|printf)[[:space:]]' \
        | /usr/bin/grep -vE '[/"]docker' || true
}

hits="$(bare_docker "$UNIN")"
if [ -n "$hits" ]; then
    bad "the generated uninstaller calls a BARE docker; on a non-login shell this is 'command not found' and the customer's stores survive:"
    printf '         %s\n' "$hits"
else
    ok "no bare docker invocation in the generated uninstaller"
fi

# It must also actually try the two Homebrew locations rather than only PATH.
for loc in '/opt/homebrew/bin/docker' '/usr/local/bin/docker'; do
    if /usr/bin/grep -qF "$loc" "$UNIN"; then
        ok "it looks for docker at ${loc}"
    else
        bad "it never looks at ${loc}, so it still depends on PATH on that architecture"
    fi
done

# ── CONTROL THAT MUST FIRE ────────────────────────────────────────────────
CTRL="$(mktemp)"; trap 'rm -f "$UNIN" "$CTRL"' EXIT
printf 'cd ~/.ostler\nif _out="$(docker compose down -v 2>&1)"; then\n  :\nfi\n' > "$CTRL"
if [ -n "$(bare_docker "$CTRL")" ]; then
    ok "CONTROL: the detector DOES flag a bare 'docker compose down -v'"
else
    bad "CONTROL FAILED: the detector cannot see a bare docker call, so every PASS above is meaningless"
fi

# ── CONTROL THAT MUST NOT FIRE ────────────────────────────────────────────
printf 'D=/opt/homebrew/bin/docker\nif _out="$("$D" compose down -v 2>&1)"; then\n  :\nfi\n' > "$CTRL"
if [ -z "$(bare_docker "$CTRL")" ]; then
    ok "CONTROL: a quoted absolute-path invocation reads clean, so this gate does not reject its own fix"
else
    bad "CONTROL FAILED: the fixed form is still flagged; this gate would reject the correct code"
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$CANT" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
