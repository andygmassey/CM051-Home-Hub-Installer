#!/usr/bin/env bash
# tests/test_no_shipped_writer_under_documents_or_desktop.sh
# ==========================================================
# Privacy contract: with iCloud "Desktop & Documents" on, anything written
# under ~/Documents or ~/Desktop is uploaded off the Mac. No shipped writer
# may point there.
#
# Measured 2026-11-17: RemoteCapture 0.1.11 defaulted its call transcripts to
# a Transcripts folder under ~/Documents, and install.sh set no override, so call
# transcripts went to iCloud and never reached the pipeline (which reads
# ~/Ostler/Transcripts). CM042 now defaults to ~/Ostler/Transcripts; this
# installer ALSO pins it, so an older RemoteCapture is covered.
#
# Two claims:
#   1. PIN: the RemoteCapture LaunchAgent plist install.sh writes, rendered
#      under a TEMP HOME, is valid and sets
#      EnvironmentVariables.OSTLER_TRANSCRIPTS_DIR = $HOME/Ostler/Transcripts.
#   2. SCAN: no plist <string>, no *_DIR / *_ROOT / *_PATH assignment and no
#      compose bind-mount source in install.sh or any tracked .plist or
#      docker-compose file names a path under ~/Documents or ~/Desktop
#      (${HOME}, $HOME or ~ spellings, any case).
#      Exemption: LEGACY_* names (migration sources, read and removed).
#      Controls: the scanner is run on synthetic files that carry each shape
#      (must fire, once per shape) and on a clean synthetic file (must not).
#
# KNOWN, NOT COVERED (read paths and one in-place writer that this scan's
# shapes do not describe): the export auto-unzip at install.sh (loop over
# ~/Downloads ~/Desktop ~/Documents) extracts the owner's own export zip
# beside the zip. Tracked separately; it is not a *_DIR, plist or mount.
#
# Never touches the real HOME. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
set -u
GREP=/usr/bin/grep
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"
fail=0
ok()     { echo "ok: $*"; }
bad()    { echo "FAIL: $*" >&2; fail=1; }
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
[ -f "$INSTALL" ] || cannot "install.sh missing"
command -v plutil >/dev/null 2>&1 || cannot "plutil not on PATH (macOS only)"

W="$(mktemp -d)" || cannot "mktemp"
trap 'rm -rf "$W"' EXIT

# ---- 1. PIN -----------------------------------------------------------------
root_line="$($GREP -m1 -E '^USER_FACING_ROOT=' "$INSTALL")" || cannot "no USER_FACING_ROOT= in install.sh"
body="$(awk '/cat > "\$REMOTECAPTURE_PLIST_TARGET" <<RCAPEOF/{p=1; next} p&&/^RCAPEOF$/{exit} p{print}' "$INSTALL")"
[ -n "$body" ] || cannot "RemoteCapture plist heredoc (RCAPEOF) not found in install.sh"
H="$W/home"; mkdir -p "$H"
HOME="$H" ROOT_LINE="$root_line" BODY="$body" bash -c '
    set -u
    eval "$ROOT_LINE"
    REMOTECAPTURE_LAUNCHAGENT_LABEL=com.example.rc
    REMOTECAPTURE_BINARY_INSIDE_APP=/Applications/Ostler/RC.app/Contents/MacOS/RC
    LOGS_DIR="$HOME/.ostler/logs"
    eval "cat <<RCAPEOF
$BODY
RCAPEOF"' > "$W/rc.plist" || cannot "could not render the RemoteCapture plist"
if plutil -lint "$W/rc.plist" >/dev/null 2>"$W/lint.err"; then
    ok "rendered RemoteCapture plist is valid"
else
    bad "rendered RemoteCapture plist does not lint: $(cat "$W/lint.err")"
fi
got="$(plutil -extract EnvironmentVariables.OSTLER_TRANSCRIPTS_DIR raw -o - "$W/rc.plist" 2>"$W/ex.err")"
if [ "$got" = "$H/Ostler/Transcripts" ]; then
    ok "RemoteCapture plist pins OSTLER_TRANSCRIPTS_DIR to \$HOME/Ostler/Transcripts"
else
    bad "OSTLER_TRANSCRIPTS_DIR is '$got' (want '$H/Ostler/Transcripts'); plutil said: $(cat "$W/ex.err")"
fi

# ---- 2. SCAN ----------------------------------------------------------------
# One ERE per shape. HOMEISH matches ${HOME}, $HOME, ~ ; DD is the folder.
HOMEISH='(\$\{HOME\}|\$HOME|~)'
DD='([Dd][Oo][Cc][Uu][Mm][Ee][Nn][Tt][Ss]|[Dd][Ee][Ss][Kk][Tt][Oo][Pp])'
SHAPES=(
    "<string>${HOMEISH}/${DD}(/|<)"
    "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_]*(_DIR|_ROOT|_PATH)=[\"']?${HOMEISH}/${DD}(/|\"|'|\$)"
    "^[[:space:]]*-[[:space:]]*[\"']?${HOMEISH}/${DD}[^:]*:"
)
# LEGACY_* names are migration SOURCES (the uninstaller's old-root check),
# read and removed, never written: they are the one exemption, by NAME.
scan() {   # $1 file ; prints file:line for each hit (comments skipped)
    local s
    for s in "${SHAPES[@]}"; do
        $GREP -n -E -- "$s" "$1" | $GREP -v -E '^[0-9]+:[[:space:]]*#' \
          | $GREP -v -E '^[0-9]+:[[:space:]]*(export[[:space:]]+)?LEGACY_[A-Za-z_]*=' | sed "s|^|$1:|"
    done
}

# Controls first: a scanner that cannot fire proves nothing.
printf '%s\n' '    <string>${HOME}/Documents/Example/Transcripts</string>' > "$W/pos1"
printf '%s\n' 'export OSTLER_EXAMPLE_DIR="$HOME/Desktop/out"' > "$W/pos2"
printf '%s\n' '      - "~/documents/Example:/data"' > "$W/pos3"
printf '%s\n' '    <string>${HOME}/Ostler/Transcripts</string>' 'OSTLER_EXAMPLE_DIR="$HOME/Ostler"' \
    '# OLD_DIR="$HOME/Documents/x" (a comment)' 'LEGACY_ROOT="${HOME}/Documents/Example"' 'for d in "${HOME}/Desktop" "${HOME}/Documents"; do' > "$W/neg"
for c in pos1 pos2 pos3; do
    n="$(scan "$W/$c" | wc -l | tr -d ' ')"
    [ "$n" = 1 ] && ok "control $c: scanner fires once" || bad "control $c: scanner fired $n times, want 1"
done
n="$(scan "$W/neg" | wc -l | tr -d ' ')"
[ "$n" = 0 ] && ok "clean control: scanner silent" || bad "clean control: scanner fired $n times: $(scan "$W/neg")"

# The subject.
files=("$INSTALL")
while IFS= read -r f; do files+=("$REPO/$f"); done < <(
    git -C "$REPO" ls-files -- '*.plist' '*docker-compose*.yml' '*docker-compose*.yaml' 2>/dev/null \
      | $GREP -v -E '^(tests|\.github)/' )
[ "${#files[@]}" -ge 1 ] || cannot "nothing to scan"
hits=""
for f in "${files[@]}"; do hits+="$(scan "$f")"; done
if [ -z "$hits" ]; then
    ok "scanned ${#files[@]} file(s): 0 shipped writer paths under ~/Documents or ~/Desktop"
else
    bad "shipped writer path(s) under ~/Documents or ~/Desktop: $hits"
fi

[ "$fail" = 0 ] && echo "PASS: test_no_shipped_writer_under_documents_or_desktop" || echo "FAIL: test_no_shipped_writer_under_documents_or_desktop" >&2
exit "$fail"
