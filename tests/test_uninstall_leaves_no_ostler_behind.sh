#!/bin/bash
# ---------------------------------------------------------------------------
# test_uninstall_leaves_no_ostler_behind.sh
#
# CONSUMER-SIDE: after the shipped uninstaller runs, can a customer find any
# Ostler LaunchAgent, file, keychain item, app bundle, colima VM, store volume
# or listening port still on the Mac? And did it leave the customer's OWN
# things alone?
#
# Unlike the region tests beside it, this runs the WHOLE generated
# ~/.ostler/bin/ostler-uninstall body (the UNINSTALLEOF heredoc in install.sh)
# end to end, against a sandbox built from install.sh's own file layout:
#
#   * one plist in ~/Library/LaunchAgents for EVERY label install.sh (or a
#     vendored INSTALL_SNIPPET.sh it runs) can write, derived from the source,
#     not typed here; each one "loaded" in a stub launchd, and three of them
#     plus the Ostler.app bundle running a REAL TCP listener
#   * ~/.ostler (bin, services, data/knowledge-staging, power.conf, license/)
#   * ~/Documents/Ostler/Conversations (the customer's generated content)
#   * the "Ostler Recovery Key" keychain item (the only one install.sh adds)
#   * the colima `default` VM and its data disk, plus the five store volumes
#   * /Applications/Ostler.app and the /Applications/Ostler/ folder bundles
#   * /usr/local/bin/{pwg-convo,ostler-knowledge,gws}
#   * ~/.ollama/models (the uninstaller says it KEEPS these; asserted kept)
#   * customer sentinels: a non-Ostler LaunchAgent, a non-Ostler keychain
#     item, a file in ~/Documents, a sibling colima profile
#
# SANDBOXING: every absolute path the body touches (/Applications,
# /usr/local/bin, /opt/homebrew/bin, /etc) is rewritten into the sandbox, and
# the rewrite is VERIFIED complete before anything runs (CANNOT-RUN if not).
# launchctl, security, docker, colima, limactl, brew, pmset, sudo and
# osascript are stubs first on PATH. launchd itself is simulated: `bootout`
# of a label stops the process registered for it. Real launchd, the real
# login keychain and a real colima VM are NOT INSTRUMENTED here; that half is
# the thin walk's.
#
# CROSS-CHECK: every label derived from install.sh must also be NAMED in the
# uninstaller's OSTLER_LAUNCHAGENT_LABELS. The on-disk namespace scan would
# remove an unlisted plist, but only the list can boot out an agent whose
# plist is already gone, so an install.sh agent missing from the list FAILS.
#
# CONTROLS: the cross-check is re-run against an install.sh with one extra
# agent injected and must FAIL; then each of seven uninstaller steps is
# deleted in turn and the full-removal scenario must FAIL for each.
#
# EXIT  0 all held and every control went red   1 a property or control
#       failed   2 CANNOT-RUN (not a pass)
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${1:-${REPO_ROOT}/install.sh}"

fails=0
ok()     { printf '  PASS  %s\n' "$1"; }
bad()    { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
cannot() { printf 'CANNOT-RUN: %s\n  A check that could not run has not passed.\n' "$*" >&2; exit 2; }

[[ -f "$INSTALL_SCRIPT" ]] || cannot "no install.sh at ${INSTALL_SCRIPT}"
command -v python3 >/dev/null 2>&1 || cannot "python3 is needed for the TCP listeners"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-uninst-e2e.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
    # Kill only the listeners THIS test started, by recorded PID.
    if [[ -f "${WORK}/all_pids" ]]; then
        while read -r p; do kill -KILL "$p" 2>/dev/null || true; done < "${WORK}/all_pids"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. Labels install.sh can write, derived from the source ────────────────
derive_labels() {
    # derive_labels <install.sh> -> sorted unique labels on stdout
    local src="$1" repo; repo="$(cd "$(dirname "$src")" && pwd)"
    {
        # (a) literal plist paths
        grep -oE 'LaunchAgents/com\.[a-z0-9][a-z0-9.-]*[a-z0-9]\.plist' "$src" \
            | sed -E 's#^LaunchAgents/##; s#\.plist$##'
        # (b) <key>Label</key><string>literal</string> in plist heredocs
        grep -A1 '<key>Label</key>' "$src" \
            | grep -oE '<string>com\.[a-z0-9][a-z0-9.-]*[a-z0-9]</string>' \
            | sed -E 's#</?string>##g'
        # (c) label variables assigned a literal (covers ${VAR}.plist writers)
        grep -oE '[A-Za-z_]*[Ll][Aa][Bb][Ee][Ll][A-Za-z_]*="com\.[a-z0-9][a-z0-9.-]*[a-z0-9]"' "$src" \
            | sed -E 's#^[^=]*="##; s#"$##'
        # (d) the conversation-feed template, expanded per caller
        if grep -q 'local label="com.creativemachines.ostler.${feed_key}-bundle"' "$src"; then
            grep -oE '^[[:space:]]*_install_conversation_feed [a-z]+' "$src" \
                | awk '{print "com.creativemachines.ostler." $2 "-bundle"}'
        fi
        # (e) agents written by VENDORED snippets install.sh runs
        find "$repo" -name INSTALL_SNIPPET.sh -not -path '*/.git/*' 2>/dev/null \
            | while read -r snip; do
                grep -rhoE 'com\.(ostler|creativemachines\.ostler)[a-z0-9.-]*[a-z0-9]\.plist' "$(dirname "$snip")" \
                    | sed -E 's#\.plist$##'
            done
    } | grep -E '^com\.(ostler\.|creativemachines\.ostler)' | sort -u
}
derive_labels "$INSTALL_SCRIPT" > "${WORK}/labels.txt"
n_labels=$(grep -c . "${WORK}/labels.txt" || true)
[[ "$n_labels" -ge 25 ]] || cannot "derived only ${n_labels} labels from install.sh; the extraction is broken, not the product"
grep -q '^com.creativemachines.ostler.context-refresh$' "${WORK}/labels.txt" \
    || cannot "vendored-snippet derivation did not find context-refresh; arm (e) is blind"
grep -q '^com.creativemachines.ostler.spoken-bundle$' "${WORK}/labels.txt" \
    || cannot "feed-template derivation did not find spoken-bundle; arm (d) is blind"

# ── 2. Extract the generated uninstaller body ──────────────────────────────
extract_body() {
    awk '
        /^[^#]*<<'\''UNINSTALLEOF'\''/ { c = 1; next }
        /^UNINSTALLEOF$/               { c = 0 }
        c                              { print }
    ' "$1"
}
extract_body "$INSTALL_SCRIPT" > "${WORK}/body.sh"
[[ "$(wc -l < "${WORK}/body.sh" | tr -d ' ')" -ge 500 ]] || cannot "uninstaller heredoc markers moved"
/bin/bash -n "${WORK}/body.sh" || cannot "generated uninstaller does not parse under /bin/bash"

listed_labels() {
    awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/{c=1;next} c&&/^\)/{c=0} c' "$1" \
        | sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -E '^com\.' | sort -u
}

cross_check() {
    # cross_check <labels-file> <body> -> prints missing labels; rc 1 if any
    listed_labels "$2" > "${WORK}/listed.tmp"
    comm -23 "$1" "${WORK}/listed.tmp" > "${WORK}/missing.tmp"
    [[ ! -s "${WORK}/missing.tmp" ]]
}
n_listed=$(listed_labels "${WORK}/body.sh" | grep -c . || true)
[[ "$n_listed" -ge 20 ]] || cannot "OSTLER_LAUNCHAGENT_LABELS parsed to ${n_listed} labels"
echo "Cross-check: ${n_labels} labels install.sh can write, ${n_listed} named by the uninstaller"
if cross_check "${WORK}/labels.txt" "${WORK}/body.sh"; then
    ok "every one of ${n_labels} install.sh labels is named in OSTLER_LAUNCHAGENT_LABELS"
else
    bad "install.sh writes labels the uninstaller does not name: $(tr '\n' ' ' < "${WORK}/missing.tmp")"
fi
# Control: inject one new agent into a COPY of install.sh. Must go red.
cp "$INSTALL_SCRIPT" "${WORK}/install.injected.sh"
printf '\ncat > "${HOME}/Library/LaunchAgents/com.ostler.zz-injected-agent.plist" <<EOF\nEOF\n' >> "${WORK}/install.injected.sh"
derive_labels "${WORK}/install.injected.sh" > "${WORK}/labels.injected.txt"
if cross_check "${WORK}/labels.injected.txt" "${WORK}/body.sh"; then
    bad "CONTROL: an injected install.sh agent was NOT reported missing; the cross-check is blind"
else
    ok "CONTROL: an injected install.sh agent is reported missing ($(tr '\n' ' ' < "${WORK}/missing.tmp"))"
fi

# ── 3. Sandbox + stubs ─────────────────────────────────────────────────────
make_stubs() {
    local sb="$1" s="${1}/stubs"
    mkdir -p "$s"
    cat > "${s}/launchctl" <<'EOF'
#!/bin/bash
# Stub launchd. $SB/state/loaded: "label pid" (pid may be "-").
L="${SB}/state/loaded"; echo "launchctl $*" >> "${SB}/state/calls"
stop_label() {
    local lab="$1" line pid
    line="$(grep -E "^${lab//./\\.} " "$L" 2>/dev/null | head -1)"
    [[ -n "$line" ]] || return 113
    pid="${line#* }"; [[ "$pid" != "-" ]] && kill -TERM "$pid" 2>/dev/null
    grep -vE "^${lab//./\\.} " "$L" > "${L}.t"; mv "${L}.t" "$L"; return 0
}
case "${1:-}" in
  bootout) t="${2:-}"; stop_label "${t##*/}"; exit $? ;;
  unload)  f="${@: -1}"; b="$(basename "$f" .plist)"; stop_label "$b"; exit $? ;;
  list)    awk '{print $2 "\t0\t" $1}' "$L"; exit 0 ;;
  print)   t="${2:-}"; grep -qE "^${t##*/} " "$L"; exit $? ;;
  *) exit 0 ;;
esac
EOF
    cat > "${s}/security" <<'EOF'
#!/bin/bash
# Stub keychain: $SB/state/keychain lines "service<TAB>account".
K="${SB}/state/keychain"; echo "security $*" >> "${SB}/state/calls"
cmd="${1:-}"; shift; svc=""
while [[ $# -gt 0 ]]; do case "$1" in -s) svc="$2"; shift 2;; *) shift;; esac; done
case "$cmd" in
  delete-generic-password)
    grep -q "^${svc}	" "$K" || exit 44
    grep -v "^${svc}	" "$K" > "${K}.t"; mv "${K}.t" "$K" ;;
  find-generic-password) grep -q "^${svc}	" "$K" || exit 44 ;;
esac
exit 0
EOF
    cat > "${s}/docker" <<'EOF'
#!/bin/bash
V="${SB}/state/volumes"; echo "docker $*" >> "${SB}/state/calls"
case "${1:-} ${2:-}" in
  "compose down") [[ " $* " == *" -v "* ]] && : > "$V"; exit 0 ;;
  "volume ls") cat "$V"; exit 0 ;;
  "info "*|"info") exit 0 ;;
esac
exit 0
EOF
    cat > "${s}/colima" <<'EOF'
#!/bin/bash
S="${SB}/state/colima"; echo "colima $*" >> "${SB}/state/calls"
case "${1:-}" in
  list) echo "PROFILE STATUS ARCH CPUS MEMORY DISK RUNTIME ADDRESS"
        while read -r p; do [[ -n "$p" ]] && echo "$p Running aarch64 2 4GiB 30GiB docker"; done < "$S" ;;
  delete) shift; t="default"; for a in "$@"; do case "$a" in -*) ;; *) t="$a";; esac; done
          grep -vx "$t" "$S" > "${S}.t"; mv "${S}.t" "$S" ;;
esac
exit 0
EOF
    cat > "${s}/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "${SB}/state/calls"
while [[ "${1:-}" == -* ]]; do shift; done
exec "$@"
EOF
    for c in limactl brew pmset osascript defaults killall open tailscale ollama; do
        printf '#!/bin/bash\necho "%s $*" >> "${SB}/state/calls"\nexit 0\n' "$c" > "${s}/${c}"
    done
    chmod +x "${s}"/*
    # The body probes Homebrew paths absolutely; those are rewritten into
    # the sandbox, so the same stubs must answer there.
    mkdir -p "${sb}/fs/opt/homebrew/bin"
    for c in docker colima limactl; do ln -s "${s}/${c}" "${sb}/fs/opt/homebrew/bin/${c}"; done
}

start_listener() {
    # start_listener <sb> <exe-path> -> echoes "pid port"
    # The listener is a REAL executable written AT <exe-path>, so the path is
    # in its command line exactly as a bundle binary's is. (`exec -a` does
    # not work: the python3 shim re-execs and drops argv0, measured, and
    # pgrep -f then cannot see it.)
    local sb="$1" exe="$2" pf
    pf="$(mktemp "${sb}/state/port.XXXXXX")"
    mkdir -p "$(dirname "$exe")"
    cat > "$exe" <<'PY'
#!/usr/bin/env python3
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",0)); s.listen(5)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
while True: time.sleep(1)
PY
    chmod +x "$exe"
    "$exe" "$pf" >/dev/null 2>&1 &
    local pid=$! i=0
    echo "$pid" >> "${WORK}/all_pids"
    while [[ ! -s "$pf" && $i -lt 50 ]]; do sleep 0.1; i=$((i + 1)); done
    [[ -s "$pf" ]] || cannot "listener ${exe} did not bind"
    echo "$pid $(cat "$pf")"
}

port_open() { python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1"; }

build_fixture() {
    local sb="$1" H="${1}/home" F="${1}/fs"
    mkdir -p "${H}/Library/LaunchAgents" "${sb}/state" "${F}/Applications/Ostler" \
             "${F}/usr/local/bin" "${F}/etc"
    : > "${sb}/state/loaded"; : > "${sb}/state/calls"
    while read -r lab; do
        printf '<plist><dict><key>Label</key><string>%s</string></dict></plist>\n' "$lab" \
            > "${H}/Library/LaunchAgents/${lab}.plist"
        echo "$lab -" >> "${sb}/state/loaded"
    done < "${WORK}/labels.txt"
    # Customer's own agent: must survive.
    echo '<plist/>' > "${H}/Library/LaunchAgents/com.example.customer-backup.plist"
    echo "com.example.customer-backup -" >> "${sb}/state/loaded"
    # Three services with REAL listeners, registered to their labels.
    : > "${sb}/state/ports"
    for lab in com.ostler.doctor com.ostler.ical-server com.creativemachines.ostler.assistant; do
        set -- $(start_listener "$sb" "${H}/.ostler/services/${lab}/run")
        grep -vE "^${lab//./\\.} " "${sb}/state/loaded" > "${sb}/state/l.t"; mv "${sb}/state/l.t" "${sb}/state/loaded"
        echo "$lab $1" >> "${sb}/state/loaded"
        echo "$lab $2" >> "${sb}/state/ports"
    done
    # ~/.ostler as install.sh lays it out.
    mkdir -p "${H}/.ostler/bin" "${H}/.ostler/services/cm048/.venv/bin" \
             "${H}/.ostler/data/knowledge-staging/notes" "${H}/.ostler/license" \
             "${H}/.ostler/logs" "${H}/.ostler/doctor"
    echo x > "${H}/.ostler/bin/ostler-uninstall"; echo x > "${H}/.ostler/docker-compose.yml"
    echo x > "${H}/.ostler/services/cm048/.venv/bin/pwg-convo"
    echo x > "${H}/.ostler/data/knowledge-staging/notes/n.md"
    echo policy > "${H}/.ostler/power.conf"; echo lic > "${H}/.ostler/license/ostler-licence.json"
    # Customer-facing content.
    mkdir -p "${H}/Documents/Ostler/Conversations/2026-10-01/chat-abc" "${H}/Documents/Ostler/Wiki"
    echo s > "${H}/Documents/Ostler/Conversations/2026-10-01/chat-abc/summary.md"
    echo "mine" > "${H}/Documents/customer-notes.txt"
    # Ollama models: the uninstaller says it does NOT remove these.
    mkdir -p "${H}/.ollama/models/blobs"; echo m > "${H}/.ollama/models/blobs/sha256-x"
    # Keychain.
    printf 'Ostler Recovery Key\tu1\ncom.example.customer-vpn\tme\n' > "${sb}/state/keychain"
    # colima default + a sibling profile + the data disk colima delete leaves.
    printf 'default\nostlercut\n' > "${sb}/state/colima"
    mkdir -p "${H}/.colima/_lima/_disks/colima"; echo d > "${H}/.colima/_lima/_disks/colima/datadisk"
    printf 'qdrant_data\noxigraph_data\nredis_data\nwiki-docs\nvane_data\n' > "${sb}/state/volumes"
    # Apps.
    for app in "Ostler.app" "Ostler/Recover Ostler.app" "Ostler/Ostler RemoteCapture.app" \
               "Ostler/Ostler Safari Extension.app" "Ostler/Ostler Uninstaller.app"; do
        mkdir -p "${F}/Applications/${app}/Contents/MacOS"
    done
    set -- $(start_listener "$sb" "${F}/Applications/Ostler.app/Contents/MacOS/Ostler")
    echo "app $1" >> "${sb}/state/apppid"; echo "Ostler.app $2" >> "${sb}/state/ports"
    ln -s "${H}/.ostler/services/cm048/.venv/bin/pwg-convo" "${F}/usr/local/bin/pwg-convo"
    ln -s "${H}/.ostler/bin/ostler-uninstall" "${F}/usr/local/bin/ostler-knowledge"
    echo gws > "${F}/usr/local/bin/gws"
}

sandbox_body() {
    # sandbox_body <body-in> <sb> <body-out>: rewrite absolute paths, then
    # PROVE no unsandboxed absolute path is left for the body to touch.
    local F="${2}/fs"
    sed -e "s#/Applications#${F}/Applications#g" \
        -e "s#/usr/local/bin#${F}/usr/local/bin#g" \
        -e "s#/opt/homebrew/bin#${F}/opt/homebrew/bin#g" \
        -e "s#/etc/kcpassword#${F}/etc/kcpassword#g" "$1" > "$3"
    local left
    left="$(grep -v '^[[:space:]]*#' "$3" | sed "s#${F}/[^ \"]*##g" \
            | grep -oE '(^|[ "=(:])/(Applications|usr/local|opt/homebrew|etc|Library|System|private|var|Users)[^ "]*' | head -3)"
    [[ -z "$left" ]] || cannot "sandbox rewrite left absolute paths the body could touch: ${left}"
}

run_uninstall() {
    # run_uninstall <body> <sb> <flags...> -> output in $sb/out, rc in $sb/rc
    local body="$1" sb="$2"; shift 2
    local rbody="${sb}/body.sandboxed.sh"
    sandbox_body "$body" "$sb" "$rbody"
    ( cd "${sb}/home" && env -i HOME="${sb}/home" USER=tester SB="$sb" TERM=dumb NO_COLOR=1 \
        PATH="${sb}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash "$rbody" "$@" < /dev/null > "${sb}/out" 2>&1 ); echo $? > "${sb}/rc"
}

# assert_full_removal <sb> -> prints FAIL lines for every surviving thing; rc 1 if any
assert_full_removal() {
    local sb="$1" H="${1}/home" F="${1}/fs" n=0 left
    left="$(ls "${H}/Library/LaunchAgents" | grep -E '^com\.(ostler\.|creativemachines\.ostler)' || true)"
    [[ -z "$left" ]] || { echo "    survived plist: $(echo $left)"; n=$((n+1)); }
    left="$(grep -E '^com\.(ostler\.|creativemachines\.ostler)' "${sb}/state/loaded" || true)"
    [[ -z "$left" ]] || { echo "    still loaded: $(echo $left | cut -c1-200)"; n=$((n+1)); }
    while read -r what port; do
        port_open "$port" && { echo "    port still listening: ${what} :${port}"; n=$((n+1)); }
    done < "${sb}/state/ports"
    left="$( cd "${H}/.ostler" 2>/dev/null && ls -A | sort | tr '\n' ' ' )"
    [[ "$left" == "license power.conf " ]] || { echo "    ~/.ostler holds more than license + power.conf: '${left}'"; n=$((n+1)); }
    [[ ! -e "${H}/Documents/Ostler" ]] || { echo "    ~/Documents/Ostler survived --remove-content"; n=$((n+1)); }
    grep -q '^Ostler Recovery Key	' "${sb}/state/keychain" && { echo "    keychain item survived"; n=$((n+1)); }
    grep -qx default "${sb}/state/colima" && { echo "    colima default VM survived --remove-colima"; n=$((n+1)); }
    [[ ! -e "${H}/.colima/_lima/_disks/colima/datadisk" ]] || { echo "    colima data disk survived"; n=$((n+1)); }
    [[ ! -s "${sb}/state/volumes" ]] || { echo "    store volumes survived: $(tr '\n' ' ' < "${sb}/state/volumes")"; n=$((n+1)); }
    [[ ! -e "${F}/Applications/Ostler.app" ]] || { echo "    /Applications/Ostler.app survived"; n=$((n+1)); }
    [[ ! -e "${F}/Applications/Ostler" ]] || { echo "    /Applications/Ostler survived: $(ls "${F}/Applications/Ostler" | tr '\n' ' ')"; n=$((n+1)); }
    for l in pwg-convo ostler-knowledge; do
        [[ ! -e "${F}/usr/local/bin/${l}" && ! -L "${F}/usr/local/bin/${l}" ]] || { echo "    /usr/local/bin/${l} survived"; n=$((n+1)); }
    done
    [[ "$n" -eq 0 ]]
}

# assert_customer_kept <sb>: the customer's own things are untouched
assert_customer_kept() {
    local sb="$1" H="${1}/home" F="${1}/fs" n=0
    [[ -f "${H}/Library/LaunchAgents/com.example.customer-backup.plist" ]] || { echo "    customer LaunchAgent deleted"; n=$((n+1)); }
    grep -q '^com.example.customer-backup ' "${sb}/state/loaded" || { echo "    customer LaunchAgent booted out"; n=$((n+1)); }
    grep -q '^com.example.customer-vpn	' "${sb}/state/keychain" || { echo "    customer keychain item deleted"; n=$((n+1)); }
    [[ -f "${H}/Documents/customer-notes.txt" ]] || { echo "    ~/Documents/customer-notes.txt deleted"; n=$((n+1)); }
    grep -qx ostlercut "${sb}/state/colima" || { echo "    sibling colima profile deleted"; n=$((n+1)); }
    [[ -f "${H}/.ollama/models/blobs/sha256-x" ]] || { echo "    Ollama models deleted (uninstaller says it keeps them)"; n=$((n+1)); }
    [[ -f "${F}/usr/local/bin/gws" ]] || { echo "    /usr/local/bin/gws deleted (uninstaller says it keeps it)"; n=$((n+1)); }
    [[ "$n" -eq 0 ]]
}

new_sandbox() { local sb; sb="$(mktemp -d "${WORK}/sb.XXXXXX")"; make_stubs "$sb"; build_fixture "$sb"; echo "$sb"; }

# ── 4. Scenario A: full removal ────────────────────────────────────────────
echo "Scenario A: --yes --remove-colima --purge-data --remove-content"
SB_A="$(new_sandbox)"
n_ports=$(grep -c . "${SB_A}/state/ports")
while read -r what port; do port_open "$port" || cannot "fixture listener ${what} :${port} is not listening before the run"; done < "${SB_A}/state/ports"
echo "  fixture: ${n_labels} Ostler plists loaded, ${n_ports} live TCP listeners, keychain 2 items, colima 2 profiles, 5 volumes"
run_uninstall "${WORK}/body.sh" "$SB_A" --yes --remove-colima --purge-data --remove-content
rc_a=$(cat "${SB_A}/rc")
[[ "$rc_a" -eq 0 ]] && ok "uninstaller exited 0" || { bad "uninstaller exited ${rc_a}"; tail -15 "${SB_A}/out"; }
if out="$(assert_full_removal "$SB_A")"; then
    ok "nothing of Ostler remains: 0 of ${n_labels} plists, 0 loaded, 0 of ${n_ports} ports, keychain item, colima VM + disk, 5 volumes, apps, symlinks"
else bad "Ostler left behind:"; echo "$out"; fi
if out="$(assert_customer_kept "$SB_A")"; then
    ok "customer's own LaunchAgent, keychain item, ~/Documents file, sibling colima, Ollama models, gws: all kept"
else bad "customer data touched:"; echo "$out"; fi
grep -q 'Done. Ostler has been removed.' "${SB_A}/out" && ok "customer is told: Done. Ostler has been removed." \
    || bad "the closing line is missing from the uninstaller output"

# ── 5. Scenario B: --yes only: content, VM and staging KEPT ────────────────
echo "Scenario B: --yes only (the defaults a customer gets without opting in)"
SB_B="$(new_sandbox)"
run_uninstall "${WORK}/body.sh" "$SB_B" --yes
H="${SB_B}/home"
[[ -f "${H}/Documents/Ostler/Conversations/2026-10-01/chat-abc/summary.md" ]] \
    && ok "~/Documents/Ostler/Conversations KEPT without --remove-content" \
    || bad "~/Documents/Ostler/Conversations deleted without an explicit --remove-content"
grep -qx default "${SB_B}/state/colima" && ok "colima default VM KEPT without --remove-colima" \
    || bad "colima default VM deleted without consent"
[[ -f "${H}/.ostler/data/knowledge-staging/notes/n.md" ]] && ok "knowledge staging KEPT without --purge-data" \
    || bad "knowledge staging deleted without --purge-data"
left="$(ls "${H}/Library/LaunchAgents" | grep -cE '^com\.(ostler\.|creativemachines\.ostler)' || true)"
[[ "$left" -eq 0 ]] && ok "all ${n_labels} Ostler LaunchAgents still removed on the default path" \
    || bad "${left} Ostler LaunchAgents survived the default path"

# ── 6. Mutation controls: delete one step, scenario A must go red ──────────
mutate() {
    # mutate <name> <mode> <arg>
    #   mode del:  delete every line holding the fixed string <arg>
    #              (several fragments joined by a literal '||' are all deleted)
    #   mode sub:  <arg> is "from=>to", a fixed-string replacement
    local name="$1" mode="$2" arg="$3" m="${WORK}/body.${1}.sh"
    MODE="$mode" ARG="$arg" python3 - "${WORK}/body.sh" "$m" <<'PY'
import os,sys
src=open(sys.argv[1]).read(); mode=os.environ["MODE"]; arg=os.environ["ARG"]
if mode=="del":
    frags=arg.split("||")
    out="".join(l for l in src.splitlines(True) if not any(f in l for f in frags))
else:
    a,b=arg.split("=>",1); out=src.replace(a,b)
open(sys.argv[2],"w").write(out)
PY
    if cmp -s "${WORK}/body.sh" "$m"; then bad "CONTROL ${name}: mutant did not apply"; return; fi
    local removed; removed="$(diff "${WORK}/body.sh" "$m" | grep -c '^<' || true)"
    if ! /bin/bash -n "$m" 2>/dev/null; then bad "CONTROL ${name}: mutant does not parse"; return; fi
    local sb; sb="$(new_sandbox)"
    run_uninstall "$m" "$sb" --yes --remove-colima --purge-data --remove-content
    if out="$(assert_full_removal "$sb")"; then
        bad "CONTROL ${name}: step removed (${removed} line(s)) and the test still passed"
    else
        ok "CONTROL ${name}: step removed, test went red ($(echo "$out" | head -1 | sed 's/^ *//'))"
    fi
}
echo "Controls: each uninstaller step removed in turn"
mutate plist-rm      del 'rm -f "${HOME}/Library/LaunchAgents/${_label}.plist"'
mutate bootout       del 'launchctl bootout "gui/$(id -u)/${_label}"||launchctl unload "${HOME}/Library/LaunchAgents/${_label}.plist"'
mutate keychain      del 'security delete-generic-password -s "Ostler Recovery Key"'
mutate colima-delete del '"$_OSTLER_COLIMA" delete --force default'
mutate hub-app       del 'rm -rf "/Applications/Ostler.app" 2>/dev/null'
mutate stores        sub '"$_OSTLER_DOCKER" compose down -v 2>&1=>"$_OSTLER_DOCKER" compose down 2>&1'
mutate ostler-dir    del 'find "${HOME}/.ostler" -mindepth 1 -maxdepth 1'

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "PASS: the uninstaller leaves no Ostler behind, keeps the customer's own data, and every control went red"
    exit 0
fi
echo "FAIL: ${fails} check(s) failed"
exit 1
