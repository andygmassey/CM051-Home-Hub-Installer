#!/bin/bash
# ---------------------------------------------------------------------------
# test_uninstall_stops_orphaned_ticks.sh
#
# THE DEFECT (measured on a v1.0.121 trial box). After the shipped uninstaller
# and its launchctl bootouts, an orphaned wiki-recompile-tick.sh (PPID 1) kept
# running and blocked the next install's reset. install.sh starts that tick
# with `nohup ... &`, not through launchd, so no bootout reaches it.
#
# THE CONTRACT, run through the WHOLE generated ~/.ostler/bin/ostler-uninstall
# (the UNINSTALLEOF heredoc in install.sh) in a sandbox HOME, with real
# processes:
#   1. every tick script the installer lays down, ENUMERATED FROM THE SOURCE
#      (install.sh, every INSTALL_SNIPPET.sh, the conversation-feed template
#      and the sealed run-source ticks), placed at its installed path under
#      ~/.ostler and RUNNING at PPID 1 with a child, is gone after
#      `ostler-uninstall --yes`, child included (RED on main);
#   2. NEGATIVE CONTROLS, never touched: a same-named wiki-recompile-tick.sh
#      outside ~/.ostler, and a process whose argument merely STARTS WITH an
#      Ostler tick path (exact whole-argument match, not a substring);
#   3. the uid half of the match is load-bearing: presented with a different
#      uid, the same ticks are left alone;
#   4. a tick that cannot be stopped (both kills refused, simulated by
#      substituting them in a sandbox copy) is REPORTED by pid, and the closing
#      line does not claim "Ostler has been removed";
#   5. MUTATION: with the call removed, case 1 goes RED.
#
# launchctl, security, docker, colima, sudo and friends are stubs first on
# PATH; real launchd is NOT INSTRUMENTED here (the thin walk's half). Every
# process this test starts is killed by PID at exit, never by pattern.
#
# Exit 0 pass / 1 fail / 2 could not run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${UNINSTALL_TICK_TEST_INSTALL_SH:-${REPO}/install.sh}"
WORK="$(mktemp -d)"
: > "${WORK}/all_pids"
cleanup() {
    local p
    while read -r p; do [[ -n "$p" ]] && kill -KILL "$p" 2>/dev/null; done < "${WORK}/all_pids"
    rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
ok()     { printf '  ok    %s\n' "$*"; }
bad()    { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }

[[ -f "$INSTALL_SH" ]] || cannot "no install.sh at ${INSTALL_SH}"

# ── 1. The tick scripts the installer lays down, from the source ───────────
# Prints "<relative path under ~/.ostler>" per tick.
derive_ticks() {
    local names n key sub
    names="$(/usr/bin/grep -ohE '[A-Za-z0-9_-]+-tick\.sh' "${REPO}/install.sh" \
                "${REPO}"/*/INSTALL_SNIPPET.sh "${REPO}"/vendor/*/INSTALL_SNIPPET.sh 2>/dev/null \
             | /usr/bin/grep -v '^-' | sort -u)"
    for n in $names; do echo "bin/${n}"; done
    # The conversation-feed template: ${feed_key}-bundle-tick.sh, staged under
    # services/<key>-source/<stage_subpath>/bin by _install_conversation_feed,
    # and sealed as Resources/ingest/<key>-bundle/tick.sh in the daemon app.
    while read -r key sub; do
        echo "services/${key}-source/${sub}/bin/${key}-bundle-tick.sh"
        echo "OstlerAssistant.app/Contents/Resources/ingest/${key}-bundle/tick.sh"
    done < <(/usr/bin/grep -E '^[[:space:]]*_install_conversation_feed [a-z]+ ' "${REPO}/install.sh" \
             | awk '{print $2, $3}')
    echo "OstlerAssistant.app/Contents/Resources/ingest/email-ingest/tick.sh"
}
derive_ticks | sort -u > "${WORK}/ticks.txt"
n_ticks="$(/usr/bin/grep -c . "${WORK}/ticks.txt" || true)"
[[ "$n_ticks" -ge 10 ]] || cannot "derived only ${n_ticks} tick paths from the source; the derivation is broken"
for must in bin/wiki-recompile-tick.sh bin/editor-frontpage-tick.sh bin/email-ingest-tick.sh \
            bin/context-refresh-tick.sh services/whatsapp-source/whatsapp_source/bin/whatsapp-bundle-tick.sh; do
    /usr/bin/grep -qxF "$must" "${WORK}/ticks.txt" || cannot "derivation missed ${must}; it is blind"
done
echo "Derived ${n_ticks} tick scripts from the source:"
sed 's/^/    ~\/.ostler\//' "${WORK}/ticks.txt"

# ── 2. The generated uninstaller body ──────────────────────────────────────
extract_body() {
    awk '
        /^[^#]*<<'\''UNINSTALLEOF'\''/ { c = 1; next }
        /^UNINSTALLEOF$/               { c = 0 }
        c                              { print }
    ' "$1"
}
extract_body "$INSTALL_SH" > "${WORK}/body.sh"
[[ "$(wc -l < "${WORK}/body.sh" | tr -d ' ')" -ge 500 ]] || cannot "uninstaller heredoc markers moved"
/bin/bash -n "${WORK}/body.sh" || cannot "generated uninstaller does not parse under /bin/bash"

# ── 3. Sandbox ─────────────────────────────────────────────────────────────
make_sandbox() {
    local sb; sb="$(mktemp -d "${WORK}/sb.XXXXXX")"
    local s="${sb}/stubs" H="${sb}/home" F="${sb}/fs"
    mkdir -p "$s" "${H}/Library/LaunchAgents" "${H}/.ostler/bin" "${F}/Applications" \
             "${F}/usr/local/bin" "${F}/etc" "${F}/opt/homebrew/bin" "${sb}/state"
    : > "${sb}/state/calls"
    for c in launchctl security docker colima limactl brew pmset osascript defaults killall open tailscale ollama; do
        printf '#!/bin/bash\necho "%s $*" >> "${SB}/state/calls"\nexit 0\n' "$c" > "${s}/${c}"
    done
    printf '#!/bin/bash\necho "sudo $*" >> "${SB}/state/calls"\nwhile [[ "${1:-}" == -* ]]; do shift; done\nexec "$@"\n' > "${s}/sudo"
    chmod +x "${s}"/*
    for c in docker colima limactl; do ln -s "${s}/${c}" "${F}/opt/homebrew/bin/${c}"; done
    echo "$sb"
}

sandbox_body() {   # <body-in> <sb> <body-out>
    local F="${2}/fs"
    sed -e "s#/Applications#${F}/Applications#g" \
        -e "s#/usr/local/bin#${F}/usr/local/bin#g" \
        -e "s#/opt/homebrew/bin#${F}/opt/homebrew/bin#g" \
        -e "s#/etc/kcpassword#${F}/etc/kcpassword#g" "$1" > "$3"
}

# start_detached <script-path> <pidfile-prefix>: run at PPID 1 with a child.
start_detached() {
    local p="$1" pf="$2" i=0
    mkdir -p "$(dirname "$p")"
    cat > "$p" <<EOF
#!/bin/bash
echo \$\$ > "${pf}.pid"
/bin/sleep 300 &
echo \$! > "${pf}.child"
wait
EOF
    chmod +x "$p"
    ( nohup "$p" >/dev/null 2>&1 & )
    while [[ ( ! -s "${pf}.pid" || ! -s "${pf}.child" ) && $i -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done
    [[ -s "${pf}.pid" && -s "${pf}.child" ]] || cannot "stub tick ${p} did not start"
    cat "${pf}.pid" "${pf}.child" >> "${WORK}/all_pids"
}

alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }

# populate <sb>: every derived tick running at PPID 1, plus the two controls.
populate() {
    local sb="$1" H="${1}/home" rel i=0 ppid
    while read -r rel; do
        i=$((i + 1))
        start_detached "${H}/.ostler/${rel}" "${sb}/state/tick${i}"
        echo "${sb}/state/tick${i} ${rel}" >> "${sb}/state/ticks"
    done < "${WORK}/ticks.txt"
    ppid="$(ps -o ppid= -p "$(cat "${sb}/state/tick1.pid")" | tr -d ' ')"
    [[ "$ppid" == 1 ]] || cannot "stub tick is not orphaned (PPID ${ppid}, wanted 1); the fixture does not model the defect"
    # Control A: same name, NOT under ~/.ostler.
    start_detached "${H}/not-ostler/bin/wiki-recompile-tick.sh" "${sb}/state/ctlA"
    # Control B: an argument that merely starts with an Ostler tick path.
    ( nohup /usr/bin/python3 -c 'import os,sys,time
open(sys.argv[2],"w").write(str(os.getpid())); time.sleep(300)' \
        "${H}/.ostler/bin/wiki-recompile-tick.sh.orig" "${sb}/state/ctlB.pid" >/dev/null 2>&1 & )
    i=0; while [[ ! -s "${sb}/state/ctlB.pid" && $i -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done
    [[ -s "${sb}/state/ctlB.pid" ]] || cannot "control B did not start"
    cat "${sb}/state/ctlB.pid" >> "${WORK}/all_pids"; echo >> "${WORK}/all_pids"
}

run_uninstall() {   # <body> <sb> [extra PATH dir]
    local body="$1" sb="$2" pre="${3:-}"
    sandbox_body "$body" "$sb" "${sb}/body.sandboxed.sh"
    ( cd "${sb}/home" && env -i HOME="${sb}/home" USER=tester SB="$sb" TERM=dumb NO_COLOR=1 \
        PATH="${pre:+${pre}:}${sb}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash "${sb}/body.sandboxed.sh" --yes < /dev/null > "${sb}/out" 2>&1 ); echo $? > "${sb}/rc"
}

# count_left <sb> -> echoes "<ticks alive> <children alive>"
count_left() {
    local sb="$1" pf rel t=0 c=0
    while read -r pf rel; do
        alive "$(cat "${pf}.pid")" && t=$((t + 1))
        alive "$(cat "${pf}.child")" && c=$((c + 1))
    done < "${sb}/state/ticks"
    echo "$t $c"
}

controls_alive() {
    local sb="$1"
    alive "$(cat "${sb}/state/ctlA.pid")" && alive "$(cat "${sb}/state/ctlA.child")" \
        && alive "$(cat "${sb}/state/ctlB.pid")"
}

# ── Case 1: every tick stopped, controls untouched ─────────────────────────
echo "Case 1: ostler-uninstall --yes with ${n_ticks} orphaned ticks running"
SB="$(make_sandbox)"; populate "$SB"
read -r t0 c0 <<< "$(count_left "$SB")"
[[ "$t0" == "$n_ticks" && "$c0" == "$n_ticks" ]] || cannot "only ${t0}/${n_ticks} ticks and ${c0} children running before the run"
run_uninstall "${WORK}/body.sh" "$SB"
read -r t1 c1 <<< "$(count_left "$SB")"
if [[ "$t1" == 0 && "$c1" == 0 ]]; then
    ok "1 all ${n_ticks} ticks and their ${n_ticks} children stopped (before: ${t0}+${c0}, after: 0+0); rc=$(cat "${SB}/rc")"
else
    bad "1 ${t1} of ${n_ticks} ticks and ${c1} children still running after the uninstall (rc=$(cat "${SB}/rc"))"
    /usr/bin/grep -iE 'background task|Done\.' "${SB}/out" | sed 's/^/        | /'
fi
/usr/bin/grep -q 'Stopping .* Ostler background task' "${SB}/out" \
    && ok "1 the uninstaller says it stopped them: $(/usr/bin/grep -o 'Stopping [0-9]* Ostler background task(s)' "${SB}/out")" \
    || bad "1 no 'Stopping ... background task' line in the output"
/usr/bin/grep -qx '  Done. Ostler has been removed.' "${SB}/out" \
    && ok "1 clean run still closes with 'Done. Ostler has been removed.'" \
    || bad "1 the clean closing line is missing"
if controls_alive "$SB"; then
    ok "2 controls untouched: same-named tick outside ~/.ostler (and its child), and a '...tick.sh.orig' argument"
else
    bad "2 a non-Ostler control process was killed"
fi
RED_ON_MAIN_T1="$t1"

# ── Case 3: a different uid is not ours ────────────────────────────────────
echo "Case 3: the same ticks, presented as another user's"
SB3="$(make_sandbox)"; populate "$SB3"
mkdir -p "${SB3}/idstub"
printf '#!/bin/bash\nif [[ "${1:-}" == "-u" ]]; then echo 4242; else exec /usr/bin/id "$@"; fi\n' > "${SB3}/idstub/id"
chmod +x "${SB3}/idstub/id"
run_uninstall "${WORK}/body.sh" "$SB3" "${SB3}/idstub"
read -r t3 c3 <<< "$(count_left "$SB3")"
if [[ "$t3" == "$n_ticks" ]] && ! /usr/bin/grep -q 'Stopping .* Ostler background task' "${SB3}/out"; then
    ok "3 with a foreign uid, 0 of ${n_ticks} ticks touched (the uid half of the match is load-bearing)"
else
    bad "3 ticks killed although their uid was not ours (${t3}/${n_ticks} left)"
fi

# ── Case 4: an unkillable tick is reported, not claimed clean ──────────────
echo "Case 4: both kills refused"
if /usr/bin/grep -q 'kill -TERM \$_tick_pids' "${WORK}/body.sh"; then
    sed -e 's/kill -TERM \$_tick_pids 2>\/dev\/null || true/true/' \
        -e 's/kill -KILL \$_alive 2>\/dev\/null || true/true/' "${WORK}/body.sh" > "${WORK}/body.nokill.sh"
    n_sub="$(diff "${WORK}/body.sh" "${WORK}/body.nokill.sh" | /usr/bin/grep -c '^<' || true)"
    [[ "$n_sub" == 2 ]] || cannot "the no-kill substitution changed ${n_sub} lines, wanted 2"
    SB4="$(make_sandbox)"; populate "$SB4"
    run_uninstall "${WORK}/body.nokill.sh" "$SB4"
    first_pid="$(cat "${SB4}/state/tick1.pid")"
    if /usr/bin/grep -q 'could not be stopped' "${SB4}/out" && /usr/bin/grep -q "pid ${first_pid}:" "${SB4}/out" \
       && ! /usr/bin/grep -qx '  Done. Ostler has been removed.' "${SB4}/out" \
       && /usr/bin/grep -q 'APART FROM the running tasks' "${SB4}/out"; then
        ok "4 survivors reported by pid ($(/usr/bin/grep -c '^      pid ' "${SB4}/out") lines), and the closing line says 'APART FROM the running tasks'"
    else
        bad "4 an unstoppable tick was not reported, or the closing line still claimed a clean removal"
        tail -20 "${SB4}/out" | sed 's/^/        | /'
    fi
else
    bad "4 the uninstaller has no tick kill to refuse (no 'kill -TERM \$_tick_pids'); it does not stop ticks at all"
fi

# ── Case 5: mutation, the call removed ─────────────────────────────────────
echo "Case 5: mutation"
if /usr/bin/grep -qx '_u_stop_ostler_ticks' "${WORK}/body.sh"; then
    /usr/bin/grep -vx '_u_stop_ostler_ticks' "${WORK}/body.sh" > "${WORK}/body.mut.sh"
    SB5="$(make_sandbox)"; populate "$SB5"
    run_uninstall "${WORK}/body.mut.sh" "$SB5"
    read -r t5 c5 <<< "$(count_left "$SB5")"
    if [[ "$t5" -gt 0 ]]; then
        ok "5 mutant (call removed) goes RED: ${t5} of ${n_ticks} ticks survive"
    else
        bad "5 mutant with the call removed still stopped every tick; case 1 proves nothing"
    fi
else
    bad "5 no top-level '_u_stop_ostler_ticks' call in the uninstaller"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
    echo "PASS: the uninstaller stops every Ostler tick by exact path + uid, leaves look-alikes alone, and reports survivors"
    exit 0
fi
echo "FAIL: ${fails} check(s) failed"
exit 1
