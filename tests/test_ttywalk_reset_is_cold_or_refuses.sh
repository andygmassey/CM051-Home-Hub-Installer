#!/bin/bash
# ===========================================================================
# ttywalk.sh --reset must PROVE the box cold, or refuse to stage.
#
# THE DEFECT (v1.0.129 walk, 2026-11-12). The reset printed "NO SHIPPED
# UNINSTALLER FOUND. This reset did NOT uninstall." and the #1828 config-only
# teardown left ~/.ostler/state alone: 123,775 files under
# state/conversations_mirror predated the reset. Every conversation, people,
# dedupe and email count of that walk was measured on carried-over state.
#
# WHAT THIS RUNS. The real scripts/walk_cold_wipe_state.sh, and the real driver
# glue extracted from ttywalk.sh (the two `DO_RESET == 1` cold-proof blocks),
# against a TEMP HOME with a stub ssh that runs the remote command locally.
# Synthetic data only. Nothing touches the real home or a real box.
#
# ARMS
#   CLEAN      a populated fake box is wiped: PROVEN, both counts printed per
#              root, the licence kept (allowlist), state gone.
#   NEGATIVE   a planted file under ~/.ostler/state that cannot be removed (its
#              directory is read-only) makes the reset REFUSE (rc 2), names the
#              path, and the driver dies before staging.
#   CAP        25 survivors list at most 20 paths.
#   ALLOWLIST  a row with no reason, and a missing allowlist, are refused.
#   MUTANT     the script with its refusal neutered is run on the NEGATIVE box;
#              the assertion must catch it (the control for the control).
# Exit: 0 pass, 1 fail, 2 cannot-run.
# ===========================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${COLD_WIPE_SH:-$REPO/scripts/walk_cold_wipe_state.sh}"
ALLOW="$REPO/scripts/walk_cold_allowlist.tsv"
TTYWALK="$REPO/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
for f in "$SUBJECT" "$ALLOW" "$TTYWALK"; do [ -f "$f" ] || { echo "CANNOT-RUN: missing $f" >&2; exit 2; }; done
/bin/bash -n "$SUBJECT" || { echo "CANNOT-RUN: subject does not parse" >&2; exit 2; }
[ "$(id -u)" != 0 ] || { echo "CANNOT-RUN: root ignores a read-only directory, so the negative arm cannot plant a survivor" >&2; exit 2; }

WORK="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

AS="Library/Application Support"
mkbox() {  # mkbox <home>
    local h="$1"
    mkdir -p "$h/.ostler/state/conversations_mirror/2026-05-15" "$h/.ostler/license" "$h/.ostler/config" \
             "$h/Documents/Ostler/Conversations" "$h/$AS/Ostler-Synth" "$h/$AS/Other App"
    local i
    for i in 1 2 3 4 5 6 7 8; do printf 'synthetic %s\n' "$i" > "$h/.ostler/state/conversations_mirror/2026-05-15/m$i.md"; done
    printf '{}\n' > "$h/.ostler/license/license.json"
    printf 'K=v\n' > "$h/.ostler/config/.env"
    printf 'note\n' > "$h/Documents/Ostler/Conversations/c1.md"
    printf 'db\n' > "$h/$AS/Ostler-Synth/x.db"
    printf 'keep\n' > "$h/$AS/Other App/keep.db"
}
plant() {  # plant <home> <n> : n files that cannot be removed (read-only dir)
    local h="$1" n="$2" i
    mkdir -p "$h/.ostler/state/locked"
    for i in $(seq 1 "$n"); do printf 'planted\n' > "$h/.ostler/state/locked/p$i"; done
    chmod 555 "$h/.ostler/state/locked"
}
unplant() { chmod 755 "$1/.ostler/state/locked" 2>/dev/null; }
run_script() {  # run_script <script> <home> <mode>
    HOME="$2" COLD_MODE="$3" COLD_ALLOWLIST_FILE="${COLD_ALLOWLIST_FILE-$ALLOW}" /bin/bash "$1"
}

printf 'the reset proves the box cold or refuses\n'

# ---- CLEAN ----
H1="$WORK/h1"; mkbox "$H1"
out_b="$(run_script "$SUBJECT" "$H1" before 2>&1)"; rc_b=$?
out_w="$(run_script "$SUBJECT" "$H1" wipe 2>&1)"; rc_w=$?
[ "$rc_b" = 0 ] && [ "$rc_w" = 0 ] && ok "CLEAN: before and wipe both rc 0" || bad "CLEAN: rc before=$rc_b wipe=$rc_w"
grep -q 'BEFORE teardown: 9 files under .*\.ostler$' <<< "$out_b" && ok "CLEAN: before count for ~/.ostler is 9 (8 state files + config; licence is allowlisted, not counted)" || bad "CLEAN: before count wrong: $out_b"
grep -q 'before=9 after=0' <<< "$out_w" && ok "CLEAN: wipe prints before=9 after=0 for ~/.ostler" || bad "CLEAN: wipe line missing: $out_w"
grep -q 'Ostler: before=1 after=0' <<< "$out_w" && ok "CLEAN: ~/Documents/Ostler counted before=1 after=0" || bad "CLEAN: Documents/Ostler line missing"
grep -q 'Ostler-Synth: before=1 after=0' <<< "$out_w" && ok "CLEAN: the Library glob root counted" || bad "CLEAN: the Library glob root missing"
[ -f "$H1/.ostler/license/license.json" ] && ok "CLEAN: the licence (allowlisted) survived" || bad "CLEAN: the licence was deleted"
[ ! -e "$H1/.ostler/state/conversations_mirror" ] && [ ! -e "$H1/.ostler/config/.env" ] && ok "CLEAN: state and config are gone" || bad "CLEAN: state or config survived"
[ -f "$H1/$AS/Other App/keep.db" ] && ok "CLEAN: a non-Ostler app dir is untouched" || bad "CLEAN: a non-Ostler app dir was deleted"
grep -q '^PROVEN(' "$H1/.walk-cold-run" && ok "CLEAN: ~/.walk-cold-run reads PROVEN(...)" || bad "CLEAN: run file: $(cat "$H1/.walk-cold-run" 2>&1)"

# ---- NEGATIVE ----
H2="$WORK/h2"; mkbox "$H2"; plant "$H2" 1
run_script "$SUBJECT" "$H2" before >/dev/null 2>&1
out2="$(run_script "$SUBJECT" "$H2" wipe 2>&1)"; rc2=$?
[ "$rc2" = 2 ] && ok "NEGATIVE: a planted file under ~/.ostler/state makes the reset refuse (rc 2)" || bad "NEGATIVE: rc=$rc2, expected 2: $out2"
grep -q 'NOT COLD' <<< "$out2" && grep -q 'state/locked/p1' <<< "$out2" && ok "NEGATIVE: it says NOT COLD and names the offending path" || bad "NEGATIVE: no NOT COLD / path in: $out2"
grep -q '^NOT_COLD(' "$H2/.walk-cold-run" && ok "NEGATIVE: ~/.walk-cold-run reads NOT_COLD(...)" || bad "NEGATIVE: run file: $(cat "$H2/.walk-cold-run" 2>&1)"

# ---- CAP ----
H3="$WORK/h3"; mkbox "$H3"; plant "$H3" 25
run_script "$SUBJECT" "$H3" before >/dev/null 2>&1
out3="$(run_script "$SUBJECT" "$H3" wipe 2>&1)"
n="$(grep -c '^  .*state/locked/p' <<< "$out3")"
[ "$n" = 20 ] && ok "CAP: 25 survivors list exactly 20 paths" || bad "CAP: listed $n paths, expected 20"

# ---- ALLOWLIST ----
printf '.ostler/license/\n' > "$WORK/noreason.tsv"
H4="$WORK/h4"; mkbox "$H4"
COLD_ALLOWLIST_FILE="$WORK/noreason.tsv" run_script "$SUBJECT" "$H4" wipe >/dev/null 2>&1; rc4=$?
[ "$rc4" = 2 ] && [ -f "$H4/.ostler/state/conversations_mirror/2026-05-15/m1.md" ] && ok "ALLOWLIST: a row with no reason is refused (rc 2) and nothing is deleted" || bad "ALLOWLIST: no-reason row rc=$rc4"
COLD_ALLOWLIST_FILE="" COLD_ALLOWLIST_B64="" run_script "$SUBJECT" "$H4" wipe >/dev/null 2>&1; rc5=$?
[ "$rc5" = 2 ] && [ -f "$H4/.ostler/state/conversations_mirror/2026-05-15/m1.md" ] && ok "ALLOWLIST: no allowlist at all is refused (rc 2) and nothing is deleted" || bad "ALLOWLIST: missing allowlist rc=$rc5"
b64="$(base64 < "$ALLOW" | tr -d '\n')"
COLD_ALLOWLIST_FILE="" COLD_ALLOWLIST_B64="$b64" run_script "$SUBJECT" "$H4" wipe >/dev/null 2>&1; rc6=$?
[ "$rc6" = 0 ] && ok "ALLOWLIST: the base64 form the driver sends decodes and wipes (rc 0)" || bad "ALLOWLIST: b64 rc=$rc6"


# ---- UNREADABLE: a find that errors must never read as cold (Archie, #3459) ----
# The first version piped find into wc -l, so the exit status was wc's: a
# permission error left after=0 and the box read cold PROVEN without looking.
H8="$WORK/h8"; mkbox "$H8"; mkdir -p "$H8/Documents/Ostler/sealed"; printf 'x\n' > "$H8/Documents/Ostler/sealed/f"; chmod 000 "$H8/Documents/Ostler/sealed"
run_script "$SUBJECT" "$H8" before >/dev/null 2>&1
out8="$(run_script "$SUBJECT" "$H8" wipe 2>&1)"; rc8=$?
chmod 755 "$H8/Documents/Ostler/sealed"
[ "$rc8" = 2 ] && ok "UNREADABLE: a chmod 000 subdir under a root makes the wipe rc 2, not cold" || bad "UNREADABLE: rc=$rc8: $out8"
grep -q 'PROVEN' "$H8/.walk-cold-run" && bad "UNREADABLE: the run file says PROVEN" || ok "UNREADABLE: the run file does not say PROVEN ($(cut -c1-40 "$H8/.walk-cold-run"))"
grep -q 'Documents/Ostler' <<< "$out8" && grep -qi 'permission denied\|WIPE ERROR\|CANNOT LOOK' <<< "$out8" && ok "UNREADABLE: the root and find's own error line are printed" || bad "UNREADABLE: no root/error line: $out8"
H9="$WORK/h9"; mkbox "$H9"; mkdir -p "$H9/.ostler/state/sealed"; chmod 000 "$H9/.ostler/state/sealed"
run_script "$SUBJECT" "$H9" before >/dev/null 2>&1; rcb9=$?
chmod 755 "$H9/.ostler/state/sealed"
[ "$rcb9" = 2 ] && ok "UNREADABLE: the BEFORE count also refuses (rc 2) on an unreadable subdir" || bad "UNREADABLE: before rc=$rcb9"
# A root whose parent cannot be listed is not "absent".
H10="$WORK/h10"; mkbox "$H10"; rm -rf "$H10/Documents/Ostler"; chmod 000 "$H10/Documents"
run_script "$SUBJECT" "$H10" before >/dev/null 2>&1; rc10=$?
chmod 755 "$H10/Documents"
[ "$rc10" = 2 ] && ok "ABSENT: a root under an unreadable parent is CANNOT-LOOK (rc 2), not absent-so-0" || bad "ABSENT: rc=$rc10"
H11="$WORK/h11"; mkbox "$H11"; rm -rf "$H11/Documents/Ostler"
run_script "$SUBJECT" "$H11" before 2>&1 | grep -q 'BEFORE teardown: 0 files under .*Documents/Ostler' && ok "ABSENT: a genuinely absent root under a readable parent counts 0" || bad "ABSENT: control failed"
# Positive control: a find that sees nothing at all must be caught.
mkdir -p "$WORK/blindbin"; printf '#!/bin/sh\nexit 0\n' > "$WORK/blindbin/find"; chmod +x "$WORK/blindbin/find"
H12="$WORK/h12"; mkbox "$H12"
PATH="$WORK/blindbin:$PATH" run_script "$SUBJECT" "$H12" before >/dev/null 2>&1; rc12=$?
[ "$rc12" = 2 ] && ok "CONTROL: a find that returns nothing fails the planted-file positive control (rc 2)" || bad "CONTROL: blind find was believed (rc=$rc12)"

# ---- MUTANT: refusal neutered ----
sed -e 's/\[ "\$after" -ne 0 \] && bad=1/:/' -e 's/^bad="\$wipe_err"$/bad=0/' "$SUBJECT" > "$WORK/mutant.sh"
cmp -s "$SUBJECT" "$WORK/mutant.sh" && { echo "CANNOT-RUN: the mutation did not apply"; exit 2; }
H5="$WORK/h5"; mkbox "$H5"; plant "$H5" 1
run_script "$WORK/mutant.sh" "$H5" before >/dev/null 2>&1
run_script "$WORK/mutant.sh" "$H5" wipe >/dev/null 2>&1; rcm=$?
[ "$rcm" = 0 ] && ok "MUTANT: with the refusal removed the negative box reads rc 0, so arm NEGATIVE does discriminate" || bad "MUTANT: not caught (rc=$rcm)"
unplant "$H2"; unplant "$H3"; unplant "$H5"

# ---- DRIVER GLUE through a stub ssh ----
cat > "$WORK/ssh_stub" <<'STUB'
#!/bin/bash
exec env HOME="$FAKE_HOME" /bin/bash -c "$1"
STUB
chmod +x "$WORK/ssh_stub"
cp "$SUBJECT" "$WORK/walk_cold_wipe_state.sh"; cp "$ALLOW" "$WORK/walk_cold_allowlist.tsv"
{
  printf 'die() { echo "DIE: $*"; exit 9; }\nrule() { :; }\nDO_RESET=1\nSSH=("%s/ssh_stub")\n' "$WORK"
  awk '/^if \(\( DO_RESET == 1 \)\); then$/{f=1} f{print} f && /^fi$/{f=0}' "$TTYWALK"
} > "$WORK/glue.sh"
nb="$(grep -c 'COLD_MODE=' "$WORK/glue.sh")"
[ "$nb" = 2 ] && ok "GLUE: both cold-proof blocks extracted from ttywalk.sh" || { echo "CANNOT-RUN: extracted $nb COLD_MODE lines, expected 2"; exit 2; }
bash -n "$WORK/glue.sh" || { echo "CANNOT-RUN: glue does not parse"; exit 2; }
H6="$WORK/h6"; mkbox "$H6"
outg="$(FAKE_HOME="$H6" bash "$WORK/glue.sh" 2>&1)"; rcg=$?
[ "$rcg" = 0 ] && grep -q 'before=9 after=0' <<< "$outg" && grep -q 'BEFORE teardown: 9 files' <<< "$outg" && ok "GLUE: clean box passes through the real driver blocks, both counts printed" || bad "GLUE: clean rc=$rcg: $outg"
H7="$WORK/h7"; mkbox "$H7"; plant "$H7" 1
outn="$(FAKE_HOME="$H7" bash "$WORK/glue.sh" 2>&1)"; rcn=$?
unplant "$H7"
[ "$rcn" = 9 ] && grep -q 'DIE: cold proof: NOT COLD' <<< "$outn" && ok "GLUE: a planted survivor makes the driver die before staging" || bad "GLUE: planted rc=$rcn: $outn"

# ---- WIRING ----
l1="$(grep -n 'COLD_MODE=before' "$TTYWALK" | head -1 | cut -d: -f1)"
l2="$(grep -n 'DO_RESET" -eq 1 \]\]; then' "$TTYWALK" | head -1 | cut -d: -f1)"
l3="$(grep -n 'COLD_MODE=wipe' "$TTYWALK" | head -1 | cut -d: -f1)"
l4="$(grep -n '^# ── Stage: the REPO by default' "$TTYWALK" | head -1 | cut -d: -f1)"
[ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ -n "$l4" ] && [ "$l1" -lt "$l2" ] && [ "$l3" -lt "$l4" ] && ok "WIRING: count runs before the reset block (line $l1 < $l2), wipe before staging (line $l3 < $l4)" || bad "WIRING: order wrong ($l1 $l2 $l3 $l4)"
grep -q 'walk-cold-run' "$TTYWALK" && grep -q "walk-cold" "$REPO/scripts/post_walk_qa.sh" && ok "WIRING: ttywalk consumes the run file and post_walk_qa reads it" || bad "WIRING: marker not consumed"
/bin/bash -n "$TTYWALK" && ok "ttywalk.sh parses" || bad "ttywalk.sh does not parse"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
