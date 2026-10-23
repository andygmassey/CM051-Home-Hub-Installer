#!/usr/bin/env bash
# ttywalk.sh --reset must run the shipped uninstaller, boot out EVERY Ostler
# launchd job, and refuse to continue while a store port is still held.
#
# THE DEFECT (v1.0.117 thin walk, W4). --reset booted out only
# com.ostler.engine-supervisor. com.creativemachines.ostler.assistant is
# KeepAlive; it restarted colima 22s after the VM delete and held all six
# store ports, so walk attempt 1 was CANNOT-RUN. install.sh writes
# ~/.ostler/bin/ostler-uninstall and the reset never looked for it. The port
# survey then printed HELD and carried on.
#
# WHAT THIS DOES. Extracts the real `if [[ "$DO_RESET" -eq 1 ]]` block from
# ttywalk.sh and runs it with a FAKE ssh that executes the remote body in the
# remote login shell (zsh on the walk box, bash too), against a fake HOME and
# stub launchctl / lsof / nc / colima / sleep that model the box:
#
#   - launchctl keeps a loaded-jobs file; `list` prints it, `bootout` removes
#     the label (and records the call). Nothing touches the real launchd.
#   - colima keeps a running flag; `stop` clears it.
#   - lsof / nc report the six store ports held while colima is running OR
#     the KeepAlive assistant is still loaded (it would restart colima), or
#     while a STUCK listener file says so.
#
# SCENARIOS
#   WALK:    the v1.0.117 box. Uninstaller present, assistant + supervisor +
#            another Ostler job loaded, colima up. Must: run the uninstaller,
#            leave no Ostler job loaded, find the ports free, continue (rc 0).
#   STUCK:   a listener that survives everything. Must exit non-zero via die,
#            loudly, before staging.
#   LEAKY DELETE: colima leaves ~/.colima/_lima/_disks/colima behind (what a
#            plain `colima delete -f` does on 0.10.3). Must refuse.
#   REFUSALS: a job that will not unload, a leftover Ostler process,
#            /Applications/Ostler.app or /Applications/Ostler still there, and
#            a non-zero uninstaller rc each end the walk CANNOT-RUN, with no
#            provenance written.
#   OTHER ACCOUNT: the same, but lsof cannot see it (permission-scoped);
#            only a TCP connect can. Must still refuse.
#   CONTROL: nothing installed, nothing loaded, ports free. Must continue
#            (rc 0) and say it did not uninstall.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${TTYWALK_SH:-$REPO/scripts/ttywalk.sh}"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at $SUBJECT" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── the real reset block ──────────────────────────────────────────────────
awk '/^if \[\[ "\$DO_RESET" -eq 1 \]\]; then$/{f=1} f{print} f && /^fi$/{exit}' "$SUBJECT" > "$WORK/reset_block.sh"
n="$(wc -l < "$WORK/reset_block.sh" | tr -d ' ')"
if [ "$n" -lt 50 ] || ! grep -q 'rule "RESET' "$WORK/reset_block.sh"; then
    echo "CANNOT-RUN: could not extract the reset block ($n lines)" >&2; exit 2
fi
bash -n "$WORK/reset_block.sh" || { echo "CANNOT-RUN: extracted reset block does not parse" >&2; exit 2; }

# THE BLOCK RESOLVES colima BY ABSOLUTE PATH (on purpose: the walk box login
# PATH has no Homebrew). On a dev Mac with Homebrew colima that would run the
# REAL `colima stop`. Re-point those paths at a placeholder the test fills per
# box, and refuse to run at all if any Homebrew path survives the rewrite.
# THE SAME FOR /Applications: the block checks /Applications/Ostler.app, and a
# dev Mac may have one. Only absolute /Applications paths are re-pointed (the
# ~/Applications ones already live under the fake HOME).
sed -e 's#/opt/homebrew/bin/colima#__STUB_COLIMA__#g' -e 's#/usr/local/bin/colima#__STUB_COLIMA__#g' \
    -e 's#\([[:space:]]\)/Applications/#\1__SANDBOX__/Applications/#g' \
    "$WORK/reset_block.sh" > "$WORK/reset_block.tmpl"
if [ "$(grep -v '^[[:space:]]*#' "$WORK/reset_block.tmpl" | grep -c -E '(^|[[:space:]"])/Applications/')" -gt 0 ]; then
    echo "CANNOT-RUN: the reset block names a /Applications path this test does not sandbox" >&2; exit 2
fi
if [ "$(grep -v '^[[:space:]]*#' "$WORK/reset_block.tmpl" | grep -c -e '/opt/homebrew' -e '/usr/local/bin')" -gt 0 ]; then
    echo "CANNOT-RUN: the reset block names a Homebrew path this test does not sandbox" >&2; exit 2
fi
grep -q '__STUB_COLIMA__' "$WORK/reset_block.tmpl" || { echo "CANNOT-RUN: no colima path found to sandbox" >&2; exit 2; }
printf '  extracted reset block: %s lines\n' "$n"

SHELLS=()
[ -x /bin/zsh ] && SHELLS+=(/bin/zsh)
SHELLS+=(/bin/bash)

# ── stubs ─────────────────────────────────────────────────────────────────
mkstubs() {  # $1 = box dir
    local b="$1"; mkdir -p "$b/stub"
    cat > "$b/stub/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$b/launchctl.calls"
case "\$1" in
  list) printf 'PID\tStatus\tLabel\n'; while read -r l; do [ -n "\$l" ] && printf -- '-\t0\t%s\n' "\$l"; done < "$b/loaded"; exit 0 ;;
  bootout) l="\${2##*/}"; grep -qx "\$l" "$b/loaded" || exit 3
           [ -e "$b/sticky" ] && grep -qx "\$l" "$b/sticky" && exit 5
           grep -vx "\$l" "$b/loaded" > "$b/loaded.tmp"; mv "$b/loaded.tmp" "$b/loaded"; exit 0 ;;
esac
exit 0
EOF
    # colima 0.10.3 semantics: delete removes the VM; ONLY --data removes the
    # data disk. A box with "$b/leaky_colima" models a delete that leaves the
    # disk whatever it is asked (the refusal path).
    cat > "$b/stub/colima" <<EOF
#!/bin/bash
echo "colima \$*" >> "$b/colima.calls"
case "\$1" in
  stop) rm -f "$b/colima_running"; echo "msg=done" ;;
  delete) rm -f "$b/colima_running"; rm -rf "$b/fakehome/.colima/_lima/colima"
          case " \$* " in *" --data "*) [ -e "$b/leaky_colima" ] || { rm -rf "$b/fakehome/.colima/_lima/_disks/colima"; echo 31000000 > "$b/df_avail"; } ;; esac
          echo "msg=deleted" ;;
esac
exit 0
EOF
    cat > "$b/stub/held" <<EOF
#!/bin/bash
# held iff a stuck listener, or colima up, or the KeepAlive assistant loaded
[ -e "$b/stuck" ] && exit 0
[ -e "$b/colima_running" ] && exit 0
grep -qx com.creativemachines.ostler.assistant "$b/loaded" && exit 0
exit 1
EOF
    printf '#!/bin/bash\nexec "%s/stub/held"\n' "$b" > "$b/stub/lsof"
    printf '#!/bin/bash\nexec "%s/stub/held"\n' "$b" > "$b/stub/nc"
    printf '#!/bin/bash\nexit 0\n' > "$b/stub/sleep"
    printf '#!/bin/bash\nexit 1\n' > "$b/stub/pgrep"
    # ps: "-o command= -p PID" -> the self line; "-axo pid=,command=" -> procs file
    cat > "$b/stub/ps" <<EOF
#!/bin/bash
case " \$* " in
  *" -axo "*) cat "$b/procs" 2>/dev/null ;;
  *) echo "SELF-SHELL" ;;
esac
exit 0
EOF
    cat > "$b/stub/df" <<EOF
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity\n/dev/disk3 100 50 %s 50%%\n' "\$(cat "$b/df_avail" 2>/dev/null || echo 1000)"
EOF
    mkdir -p "$b/root/Applications"
    chmod +x "$b/stub/"*
    # fake ssh: run the LAST argument (the remote body) in the remote shell,
    # with HOME and PATH pointing at the fake box.
    cat > "$b/stub/ssh" <<EOF
#!/bin/bash
body="\${@: -1}"
HOME="$b/fakehome" PATH="$b/stub:/usr/bin:/bin" exec "\$REMOTE_SHELL" -c "\$body"
EOF
    chmod +x "$b/stub/ssh"
    mkdir -p "$b/fakehome"
}

run_reset() {  # $1 box, $2 shell -> prints output, returns rc
    local b="$1"
    sed -e "s#__STUB_COLIMA__#$b/stub/colima#g" -e "s#__SANDBOX__#$b/root#g" "$WORK/reset_block.tmpl" > "$b/reset_block.sh"
    cat > "$b/driver.sh" <<EOF
set -uo pipefail
say() { printf '%s\n' "\$*"; }
rule() { printf -- '---- %s ----\n' "\$*"; }
die() { printf 'CANNOT-RUN: %s\n' "\$*" >&2; exit 2; }
DO_RESET=1
SSH=("$b/stub/ssh" -o BatchMode=yes "fake@walkbox.invalid")
. "$b/reset_block.sh"
echo "CONTINUED-TO-STAGE"
EOF
    REMOTE_SHELL="$2" /bin/bash "$b/driver.sh" > "$b/out" 2>&1
    echo $?
}

box_walk() {  # the v1.0.117 box
    local b="$1"; mkstubs "$b"
    mkdir -p "$b/fakehome/.ostler/bin"
    # ostler-remotecapture: a dash after ostler, which the old prefix regex missed.
    printf 'com.ostler.engine-supervisor\ncom.creativemachines.ostler.assistant\ncom.creativemachines.ostler.wiki-recompile-catchup\ncom.creativemachines.ostler-remotecapture\n' > "$b/loaded"
    : > "$b/colima_running"
    # A VM and its 30 GB data disk from the previous walk.
    mkdir -p "$b/fakehome/.colima/_lima/colima" "$b/fakehome/.colima/_lima/_disks/colima"
    : > "$b/fakehome/.colima/_lima/_disks/colima/datadisk"
    # A fake uninstaller that, like the real one, unloads only what it knows.
    # It deliberately MISSES the assistant, so the bootout backstop is tested
    # too, not only the uninstaller.
    cat > "$b/fakehome/.ostler/bin/ostler-uninstall" <<EOF
#!/bin/bash
echo "FAKE_UNINSTALLER_RAN assume_yes=\${OSTLER_UNINSTALL_ASSUME_YES:-}"
launchctl bootout "gui/\$(id -u)/com.creativemachines.ostler.wiki-recompile-catchup" || true
exit \$(cat "$b/uninstall_rc" 2>/dev/null || echo 0)
EOF
    chmod +x "$b/fakehome/.ostler/bin/ostler-uninstall"
}

for sh in "${SHELLS[@]}"; do
    tag="$(basename "$sh")"

    # ── WALK ──────────────────────────────────────────────────────────────
    b="$WORK/walk.$tag"; box_walk "$b"
    rc="$(run_reset "$b" "$sh")"
    grep -q 'FAKE_UNINSTALLER_RAN assume_yes=1' "$b/out" \
        && ok "[$tag] WALK: the shipped ~/.ostler/bin/ostler-uninstall ran, with consent set" \
        || bad "[$tag] WALK: the shipped uninstaller did not run"
    if [ ! -s "$b/loaded" ]; then
        ok "[$tag] WALK: no Ostler launchd job is left loaded"
    else
        bad "[$tag] WALK: still loaded after reset: $(tr '\n' ' ' < "$b/loaded")"
    fi
    grep -q 'bootout gui/[0-9]*/com.creativemachines.ostler.assistant' "$b/launchctl.calls" \
        && ok "[$tag] WALK: the KeepAlive assistant was booted out" \
        || bad "[$tag] WALK: the KeepAlive assistant was never booted out"
    if [ "$rc" -eq 0 ] && grep -q 'all six ports free' "$b/out" && grep -q CONTINUED-TO-STAGE "$b/out"; then
        ok "[$tag] WALK: ports verified free and the walk continues"
    else
        bad "[$tag] WALK: rc=$rc; $(grep -E 'HELD|FAILED|free|CANNOT' "$b/out" | head -3 | tr '\n' ' ')"
    fi

    if grep -q 'colima delete --data -f' "$b/colima.calls" 2>/dev/null && [ ! -e "$b/fakehome/.colima/_lima/_disks/colima" ]; then
        ok "[$tag] WALK: colima delete --data -f ran and the data disk is gone"
    else
        bad "[$tag] WALK: data disk survived or delete --data never ran: $(tr '\n' ';' < "$b/colima.calls" 2>/dev/null)"
    fi

    if grep -q '^wiped-by-shipped-uninstaller(' "$b/fakehome/.walk-stores-provenance-run" 2>/dev/null; then
        ok "[$tag] WALK: provenance says wiped-by-shipped-uninstaller"
    else
        bad "[$tag] WALK: provenance is '$(cat "$b/fakehome/.walk-stores-provenance-run" 2>/dev/null)'"
    fi
    if grep -q 'free space before the reset: 1000 KB' "$b/out" && grep -q 'free space after the reset: 31000000 KB' "$b/out"; then
        ok "[$tag] WALK: free space recorded before (1000 KB) and after (31000000 KB)"
    else
        bad "[$tag] WALK: df before/after not recorded: $(grep -i 'free space' "$b/out" | tr '\n' ' ')"
    fi
    grep -q 'bootout gui/[0-9]*/com.creativemachines.ostler-remotecapture' "$b/launchctl.calls" \
        && ok "[$tag] WALK: com.creativemachines.ostler-remotecapture (dash, not dot) is booted out" \
        || bad "[$tag] WALK: ostler-remotecapture was never booted out"

    # ── LEAKY DELETE: the data disk survives the delete ───────────────────
    b="$WORK/leaky.$tag"; box_walk "$b"; : > "$b/leaky_colima"
    rc="$(run_reset "$b" "$sh")"
    if [ "$rc" -ne 0 ] && ! grep -q CONTINUED-TO-STAGE "$b/out" && grep -q 'colima data disk is still present' "$b/out"; then
        ok "[$tag] LEAKY DELETE: a surviving data disk stops the walk (rc=$rc), so a warm box is never walked as cold"
    else
        bad "[$tag] LEAKY DELETE: rc=$rc, continued=$(grep -c CONTINUED-TO-STAGE "$b/out"); the leftover disk was not refused"
    fi

    # ── REFUSALS that used to only print (Archie review item 2) ───────────
    refused() {  # $1 box, $2 label, $3 expected reason token
        local b="$1" rc
        rc="$(run_reset "$b" "$sh")"
        if [ "$rc" -ne 0 ] && ! grep -q CONTINUED-TO-STAGE "$b/out" && grep -q "RESET FAILED:.*$3" "$b/out" \
           && [ ! -e "$b/fakehome/.walk-stores-provenance-run" ]; then
            ok "[$tag] $2: the walk is refused (rc=$rc, reason $3) and no provenance is written"
        else
            bad "[$tag] $2: rc=$rc continued=$(grep -c CONTINUED-TO-STAGE "$b/out") provenance=$(cat "$b/fakehome/.walk-stores-provenance-run" 2>/dev/null); $(grep 'RESET FAILED' "$b/out" | tail -1)"
        fi
    }
    b="$WORK/sticky.$tag"; box_walk "$b"; echo com.creativemachines.ostler.wiki-recompile > "$b/sticky"; echo com.creativemachines.ostler.wiki-recompile >> "$b/loaded"
    refused "$b" "JOB STILL LOADED" "job-still-loaded"
    b="$WORK/procs.$tag"; box_walk "$b"; echo "4242 $b/fakehome/.ostler/bin/ostler-catchup-runner --tick" > "$b/procs"
    refused "$b" "LEFTOVER PROCESS" "leftover-processes"
    b="$WORK/app.$tag"; box_walk "$b"; mkdir -p "$b/root/Applications/Ostler.app"
    refused "$b" "OSTLER.APP STILL PRESENT" "app-present"
    b="$WORK/appdir.$tag"; box_walk "$b"; mkdir -p "$b/root/Applications/Ostler"
    refused "$b" "/APPLICATIONS/OSTLER STILL PRESENT" "app-present"
    b="$WORK/urc.$tag"; box_walk "$b"; echo 1 > "$b/uninstall_rc"
    refused "$b" "UNINSTALLER RC 1" "uninstaller-rc-1"

    # ── STUCK ─────────────────────────────────────────────────────────────
    b="$WORK/stuck.$tag"; box_walk "$b"; : > "$b/stuck"
    rc="$(run_reset "$b" "$sh")"
    if [ "$rc" -ne 0 ] && ! grep -q CONTINUED-TO-STAGE "$b/out" && grep -q 'RESET FAILED' "$b/out" && grep -q 'CANNOT-RUN' "$b/out"; then
        ok "[$tag] STUCK: a port that stays held stops the walk loudly (rc=$rc) before staging"
    else
        bad "[$tag] STUCK: rc=$rc, continued=$(grep -c CONTINUED-TO-STAGE "$b/out"), the walk was not refused"
    fi

    # ── OTHER ACCOUNT: lsof is permission-scoped and sees nothing ─────────
    b="$WORK/other.$tag"; box_walk "$b"; : > "$b/stuck"
    printf '#!/bin/bash\nexit 1\n' > "$b/stub/lsof"
    rc="$(run_reset "$b" "$sh")"
    if [ "$rc" -ne 0 ] && ! grep -q CONTINUED-TO-STAGE "$b/out" && grep -q 'RESET FAILED' "$b/out"; then
        ok "[$tag] OTHER ACCOUNT: a listener lsof cannot see is still caught by a connect, and refused"
    else
        bad "[$tag] OTHER ACCOUNT: rc=$rc; a listener invisible to lsof was read as a free port"
    fi

    # ── STALE JOBS, NO UNINSTALLER (the v1.0.116 wiki-recompile evidence) ──
    # The 117 walk box logged "wiki-recompile-tick.sh: No such file or
    # directory" from ~/.ostler/logs/wiki-recompile.err: the previous build's
    # wiki-recompile job was still loaded and fired after its script was gone.
    # With no uninstaller to unload it, the bootout sweep must.
    b="$WORK/stale.$tag"; mkstubs "$b"
    printf 'com.creativemachines.ostler.wiki-recompile\ncom.ostler.fda-rerun\n' > "$b/loaded"
    mkdir -p "$b/fakehome/.colima/_lima/_disks/colima" "$b/fakehome/.ostler/license"
    echo '{"licence":"synthetic"}' > "$b/fakehome/.ostler/license/license.json"
    rc="$(run_reset "$b" "$sh")"
    if [ "$rc" -eq 0 ] && [ ! -s "$b/loaded" ] && grep -q CONTINUED-TO-STAGE "$b/out"; then
        ok "[$tag] STALE JOBS: with no uninstaller, the leftover wiki-recompile and fda-rerun jobs are booted out"
    else
        bad "[$tag] STALE JOBS: rc=$rc, still loaded: $(tr '\n' ' ' < "$b/loaded")"
    fi
    # Archie review blocker 1: with NO uninstaller, delete --data still destroys
    # the stores, so the record must say wiped, never carried-over.
    prov="$(cat "$b/fakehome/.walk-stores-provenance-run" 2>/dev/null)"
    if [ ! -e "$b/fakehome/.colima/_lima/_disks/colima" ] && [ "${prov#wiped-by-explicit-store-wipe(}" != "$prov" ]; then
        ok "[$tag] NO UNINSTALLER: the data disk is deleted and provenance says wiped (${prov%%(*}), not carried-over"
    else
        bad "[$tag] NO UNINSTALLER: disk_present=$([ -e "$b/fakehome/.colima/_lima/_disks/colima" ] && echo yes || echo no) provenance='$prov'"
    fi
    [ -s "$b/fakehome/.ostler/license/license.json" ] \
        && ok "[$tag] NO UNINSTALLER: the licence survives the reset" \
        || bad "[$tag] NO UNINSTALLER: the reset destroyed the licence"

    # ── CONTROL ───────────────────────────────────────────────────────────
    b="$WORK/clean.$tag"; mkstubs "$b"; : > "$b/loaded"
    rc="$(run_reset "$b" "$sh")"
    if [ "$rc" -eq 0 ] && grep -q CONTINUED-TO-STAGE "$b/out" && grep -q 'did NOT uninstall' "$b/out"; then
        ok "[$tag] CONTROL: a clean box continues, and says no uninstaller ran"
    else
        bad "[$tag] CONTROL: rc=$rc; a clean box was refused or went silent: $(tail -3 "$b/out" | tr '\n' ' ')"
    fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
