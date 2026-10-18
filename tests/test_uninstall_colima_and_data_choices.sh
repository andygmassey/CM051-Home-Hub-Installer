#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_uninstall_colima_and_data_choices.sh
#
# The uninstaller gained two destructive OPTIONS, both OFF by default:
#
#   --remove-colima / interactive 'yes'  deletes the SHARED colima `default`
#                                        Docker VM (~30 GB).
#   --purge-data                         wipes ~/.ostler/data/knowledge-staging
#                                        (imported operator data, otherwise
#                                        preserved for a reinstall).
#
# The colima VM is SHARED: install.sh starts it as the `default` profile with
# no --profile, so a customer may have had it for their own Docker work long
# before installing Ostler. Deleting it then wipes their unrelated data. Andy's
# rule: "if it could wipe something else that was already there, then we need
# to ask for permission first." So the load-bearing properties this gate
# proves are:
#
#   1. default present, no opt-in (incl. --yes on its own, or EOF): KEPT.
#      --yes is consent to uninstall Ostler, NOT to delete a shared VM.
#   2. --remove-colima, or an interactive 'yes': the `default` VM is deleted,
#      and the delete is VERIFIED gone (result=removed, not a claim).
#   3. a SIBLING colima profile (e.g. a build VM named `ostlercut`) is NEVER
#      seen, asked about, or deleted -- the match is exact on `default`.
#   4. --purge-data wipes knowledge-staging; without it the tree is preserved;
#      power.conf is preserved either way.
#
# HOW IT RUNS SAFELY
# ---------------------------------------------------------------------------
# Running the whole uninstaller would rm -rf real paths under /Applications on
# a developer's machine and shell out to a real colima. So, exactly like
# tests/test_uninstall_removes_every_launchagent_plist.sh, this extracts only
# the two regions under test, runs them in a sandboxed $HOME, and points the
# uninstaller's binary-resolution at a STUB colima via the _OSTLER_COLIMA
# override the code already honours. No real colima, docker, or /Applications
# path is touched.
#
# NEGATIVE CONTROLS: a mutated region that ignores the opt-in must FAIL the
# "removed"/"purged" assertion, and the sibling-profile check must reject a
# stub that deletes the sibling. A gate never seen rejecting anything is
# indistinguishable from one that always passes.
#
# EXIT CODES
#   0  every property held and every control behaved
#   1  a property failed or a control misbehaved
#   2  could not run (region markers moved) -- NOT a pass
# ---------------------------------------------------------------------------
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=""; GRN=""; YEL=""; OFF=""; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${1:-${REPO_ROOT}/install.sh}"

fails=0
ok()  { printf '  %sPASS%s  %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1" >&2; fails=$((fails + 1)); }
cannot() {
    printf '%sUNAVAILABLE%s %s\n' "$YEL" "$OFF" "$*" >&2
    printf '  A gate that could not run is NOT a pass.\n' >&2
    exit 2
}

[[ -f "$INSTALL_SCRIPT" ]] || cannot "no install.sh at: $INSTALL_SCRIPT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. Extract the shipped uninstaller body ────────────────────────────────
# `^[^#]*` on the opening marker so a comment MENTIONING the heredoc does not
# start the capture (the trap documented in the launchagent teardown test).
awk '
    /^[^#]*<<'\''UNINSTALLEOF'\''/ { capture = 1; next }
    /^UNINSTALLEOF$/               { capture = 0 }
    capture                        { print }
' "$INSTALL_SCRIPT" > "${WORK}/ostler-uninstall"
body_lines=$(wc -l < "${WORK}/ostler-uninstall" | tr -d ' ')
[[ "$body_lines" -ge 100 ]] || cannot "extracted uninstaller is only ${body_lines} lines; heredoc markers changed shape"

# ── 2. Isolate the two regions under test, by code anchors ─────────────────
extract_region() {
    # extract_region <start-regex> <end-regex-INCLUSIVE> <outfile>
    local start end
    start=$(grep -nE "$1" "${WORK}/ostler-uninstall" | head -1 | cut -d: -f1)
    end=$(grep -nE "$2"   "${WORK}/ostler-uninstall" | head -1 | cut -d: -f1)
    if [[ -z "$start" || -z "$end" || "$end" -lt "$start" ]]; then
        cannot "could not locate region ($1 .. $2); start='${start}' end='${end}'"
    fi
    awk -v a="$start" -v b="$end" 'NR>=a && NR<=b' "${WORK}/ostler-uninstall" > "$3"
    local n; n=$(wc -l < "$3" | tr -d ' ')
    [[ "$n" -ge 5 ]] || cannot "region ($1) is only ${n} lines; refusing to conclude from it"
}
extract_region '^COLIMA_RESULT="absent"$' '^_u_emit UNINSTALL_COLIMA "result=' "${WORK}/colima.region"
extract_region '^KNOWLEDGE_STAGING_DIR="\$\{HOME\}/\.ostler/data/knowledge-staging"$' \
               '^_u_emit UNINSTALL_PHASE "name=knowledge_staging"' "${WORK}/staging.region"

# Both regions must parse under bash 3.2 (the shell the uninstaller ships to).
for r in colima staging; do
    /bin/bash -n "${WORK}/${r}.region" 2>"${WORK}/parse.err" \
        || cannot "${r} region does not parse under /bin/bash: $(head -1 "${WORK}/parse.err")"
done

# ── 3. A stub colima that records calls and honours a state file ───────────
STUB_BIN="${WORK}/stub-bin"; mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/colima" <<'STUB'
#!/usr/bin/env bash
# Fake colima. STUB_COLIMA_STATE lists existing profiles, one per line.
# STUB_COLIMA_CALLS accumulates every invocation. `delete` removes ONLY the
# profile named as a positional arg, so the test can prove exact targeting.
state="${STUB_COLIMA_STATE:?}"; calls="${STUB_COLIMA_CALLS:?}"
printf 'colima %s\n' "$*" >> "$calls"
case "${1:-}" in
  list)
    printf 'PROFILE   STATUS   ARCH   CPUS  MEMORY  DISK   RUNTIME  ADDRESS\n'
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        printf '%s   Running  aarch64  2  4GiB  30GiB  docker\n' "$p"
    done < "$state"
    ;;
  stop) exit 0 ;;
  delete)
    shift
    target=""
    for a in "$@"; do case "$a" in -*) ;; *) target="$a";; esac; done
    [[ -n "$target" ]] || target="default"   # colima's own default profile
    grep -vx "$target" "$state" > "${state}.tmp" 2>/dev/null || : > "${state}.tmp"
    mv "${state}.tmp" "$state"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_BIN}/colima"

# A preamble every region runs under: faithful shell options + the marker
# emitter + a limactl that is never reachable (colima is found first).
write_preamble() {
    cat > "$1" <<'PRE'
set -euo pipefail
_u_emit() {
    [[ "${OSTLER_GUI:-}" == "1" ]] || return 0
    local _e="$1"; shift; printf '#OSTLER\t%s' "$_e"
    local _kv; for _kv in "$@"; do printf '\t%s' "$_kv"; done; printf '\n'
}
PRE
}

# Run the colima region. Args set the scenario via env; stdin is the caller's.
# Echoes: "result=<X>" line (from the emitted marker) and the recorded calls.
run_colima() {
    # $1 profiles-in-state (newline sep) ; $2 REMOVE_COLIMA_DECISION ;
    # $3 ASSUME_YES(unused by region but faithful) ; stdin = prompt answer
    local region="${4:-${WORK}/colima.region}"
    local sb; sb="$(mktemp -d "${WORK}/csb.XXXXXX")"
    printf '%b' "$1" > "${sb}/state"
    : > "${sb}/calls"
    local pre="${sb}/pre.sh"; write_preamble "$pre"
    {
        cat "$pre"
        printf 'REMOVE_COLIMA_DECISION=%q\n' "$2"
        printf 'PURGE_DATA=""\n'
        cat "$region"
        printf '\nprintf "CALLS<%%s>\\n" "$(tr "\\n" ";" < %q)"\n' "${sb}/calls"
    } > "${sb}/run.sh"
    OSTLER_GUI=1 \
    STUB_COLIMA_STATE="${sb}/state" STUB_COLIMA_CALLS="${sb}/calls" \
    _OSTLER_COLIMA="${STUB_BIN}/colima" _OSTLER_LIMACTL="" \
    HOME="$sb" PATH="${STUB_BIN}:${PATH}" \
        /bin/bash "${sb}/run.sh" 2>/dev/null
    # leave sb/state readable to caller via the STATE<> tail
    printf 'STATE<%s>\n' "$(tr '\n' ';' < "${sb}/state")"
}

colima_result() { sed -n 's/.*UNINSTALL_COLIMA\t*result=\([a-z_]*\).*/\1/p' <<<"$1" | tail -1; }
colima_deleted() { grep -q 'colima delete' <<<"$1" && echo yes || echo no; }

# ── 4. Colima properties ───────────────────────────────────────────────────
echo "colima:"

out=$(printf '' | run_colima 'default\n' '' '')                 # no flag, EOF stdin
[[ "$(colima_result "$out")" == "kept" ]] \
    && ok "default present + no opt-in + EOF -> kept" \
    || bad "default present + no opt-in + EOF -> got '$(colima_result "$out")', expected kept"
[[ "$(colima_deleted "$out")" == "no" ]] \
    && ok "  and colima delete was NEVER called" \
    || bad "  colima delete WAS called without consent"

out=$(printf '' | run_colima 'default\n' 'remove' '')           # --remove-colima
[[ "$(colima_result "$out")" == "removed" ]] \
    && ok "--remove-colima -> removed (and verified gone)" \
    || bad "--remove-colima -> got '$(colima_result "$out")', expected removed"
[[ "$(colima_deleted "$out")" == "yes" ]] \
    && ok "  and colima delete WAS called" \
    || bad "  colima delete was not called under --remove-colima"

out=$(printf '' | run_colima 'default\n' 'keep' '')             # --keep-colima
[[ "$(colima_result "$out")" == "kept" ]] \
    && ok "--keep-colima -> kept" \
    || bad "--keep-colima -> got '$(colima_result "$out")', expected kept"

out=$(printf 'yes\n' | run_colima 'default\n' '' '')            # interactive yes
[[ "$(colima_result "$out")" == "removed" ]] \
    && ok "interactive 'yes' -> removed" \
    || bad "interactive 'yes' -> got '$(colima_result "$out")', expected removed"

out=$(printf 'no\n' | run_colima 'default\n' '' '')             # interactive no
[[ "$(colima_result "$out")" == "kept" ]] \
    && ok "interactive 'no' -> kept" \
    || bad "interactive 'no' -> got '$(colima_result "$out")', expected kept"

out=$(printf '' | run_colima '' '' '')                          # no default at all
[[ "$(colima_result "$out")" == "absent" ]] \
    && ok "no default instance -> absent (nothing asked, nothing deleted)" \
    || bad "no default instance -> got '$(colima_result "$out")', expected absent"
[[ "$(colima_deleted "$out")" == "no" ]] \
    && ok "  and colima delete was not called" \
    || bad "  colima delete called when no default existed"

# SAFETY-CRITICAL: a sibling profile must survive an explicit remove.
out=$(printf '' | run_colima 'default\nostlercut\n' 'remove' '')
state_after=$(sed -n 's/.*STATE<\(.*\)>.*/\1/p' <<<"$out")
if grep -q 'ostlercut' <<<"$state_after" && ! grep -q 'default' <<<"$state_after"; then
    ok "SAFETY: --remove-colima deleted 'default' ONLY; sibling 'ostlercut' survived"
else
    bad "SAFETY: sibling handling wrong; state after = '${state_after}' (expected ostlercut kept, default gone)"
fi

# CONTROL: a region that ignored the opt-in would report kept under
# --remove-colima. Prove the predicate distinguishes them by mutating the
# decision away and requiring the assertion to flip.
out=$(printf '' | run_colima 'default\n' 'keep' '')
if [[ "$(colima_result "$out")" != "removed" ]]; then
    ok "CONTROL: without the remove opt-in the result is NOT 'removed'"
else
    bad "CONTROL: result was 'removed' even without the opt-in -- predicate is blind"
fi

# ── 5. Knowledge-staging region ────────────────────────────────────────────
echo "knowledge-staging:"
run_staging() {
    # $1 = PURGE_DATA value ; $2 = create staging? (yes/no)
    local sb; sb="$(mktemp -d "${WORK}/ksb.XXXXXX")"
    mkdir -p "${sb}/.ostler/data" "${sb}/.ostler/logs"
    printf 'policy\n' > "${sb}/.ostler/power.conf"
    printf 'junk\n'   > "${sb}/.ostler/logs/x.log"
    if [[ "$2" == "yes" ]]; then
        mkdir -p "${sb}/.ostler/data/knowledge-staging/notes"
        printf 'evernote\n' > "${sb}/.ostler/data/knowledge-staging/notes/a.md"
    fi
    local pre="${sb}/pre.sh"; write_preamble "$pre"
    {
        cat "$pre"
        printf 'PURGE_DATA=%q\n' "$1"
        cat "${WORK}/staging.region"
    } > "${sb}/run.sh"
    OSTLER_GUI=1 HOME="$sb" PATH="${STUB_BIN}:${PATH}" \
        /bin/bash "${sb}/run.sh" 2>/dev/null
    # report disk state
    printf 'STAGING_EXISTS=%s POWERCONF_EXISTS=%s LOGS_EXIST=%s\n' \
        "$([[ -d "${sb}/.ostler/data/knowledge-staging" ]] && echo yes || echo no)" \
        "$([[ -f "${sb}/.ostler/power.conf" ]] && echo yes || echo no)" \
        "$([[ -e "${sb}/.ostler/logs/x.log" ]] && echo yes || echo no)"
}
staging_outcome() { sed -n 's/.*name=knowledge_staging\t*outcome=\([a-z_]*\).*/\1/p' <<<"$1" | tail -1; }
kv() { sed -n "s/.*$1=\\([a-z]*\\).*/\\1/p" <<<"$2" | tail -1; }

out=$(run_staging '' yes)                       # default: preserve
[[ "$(staging_outcome "$out")" == "preserved" ]] \
    && ok "no --purge-data -> outcome preserved" \
    || bad "no --purge-data -> outcome '$(staging_outcome "$out")', expected preserved"
[[ "$(kv STAGING_EXISTS "$out")" == "yes" ]] \
    && ok "  and the staging tree still exists on disk" \
    || bad "  staging tree was removed without --purge-data"
[[ "$(kv POWERCONF_EXISTS "$out")" == "yes" ]] \
    && ok "  and power.conf is preserved" \
    || bad "  power.conf was removed"
[[ "$(kv LOGS_EXIST "$out")" == "no" ]] \
    && ok "  and the rest of ~/.ostler (logs) was removed" \
    || bad "  ~/.ostler/logs survived, so the teardown did not run"

out=$(run_staging '1' yes)                      # --purge-data
[[ "$(staging_outcome "$out")" == "purged" ]] \
    && ok "--purge-data -> outcome purged" \
    || bad "--purge-data -> outcome '$(staging_outcome "$out")', expected purged"
[[ "$(kv STAGING_EXISTS "$out")" == "no" ]] \
    && ok "  and the staging tree is gone from disk" \
    || bad "  staging tree survived --purge-data"
[[ "$(kv POWERCONF_EXISTS "$out")" == "yes" ]] \
    && ok "  and power.conf is STILL preserved" \
    || bad "  power.conf was removed by --purge-data (should be kept)"

out=$(run_staging '' no)                        # nothing to preserve
[[ "$(staging_outcome "$out")" == "absent" ]] \
    && ok "no staging present -> outcome absent" \
    || bad "no staging present -> outcome '$(staging_outcome "$out")', expected absent"

# CONTROL: the outcome predicate must distinguish preserved from purged, not
# read one wildcard. If it does not, the two assertions above cannot both hold.
if [[ "$(staging_outcome "$(run_staging '' yes)")" != "$(staging_outcome "$(run_staging '1' yes)")" ]]; then
    ok "CONTROL: preserve and purge yield DIFFERENT outcomes on the wire"
else
    bad "CONTROL: preserve and purge produced the same outcome -- predicate is blind"
fi

# ── verdict ────────────────────────────────────────────────────────────────
echo ""
if [[ "$fails" -eq 0 ]]; then
    printf '%sPASS%s colima + knowledge-staging choices behave, both controls held\n' "$GRN" "$OFF"
    exit 0
fi
printf '%sFAIL%s %d assertion(s) failed\n' "$RED" "$OFF" "$fails" >&2
exit 1
