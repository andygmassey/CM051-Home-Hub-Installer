#!/usr/bin/env bash
# A walk installs the operator's owner identity ONLY on a target declared as
# the owner's own, and refuses when that cannot be decided.
#
# WHY THIS EXISTS. Walk #31, 2026-10-18: ttywalk.sh staged the operator-local
# owner file onto every walked account whenever the file existed on the
# driver, and walk_drive.py answered install.sh's "Full name:" prompt from it.
# A disposable test account was installed with the operator's real identity.
#
# END TO END THROUGH THE REAL CODE. The owner block is cut out of the real
# scripts/ttywalk.sh and run with `ssh`, `ioreg` and `id` stubbed so the
# "remote" is a scratch HOME; the real scripts/walk_drive.py is then asked
# what it answers to "Full name". Every value below is synthetic (approved
# cast, example.com, Ofcom drama range); no real owner file is read.
#
# Plus the record scan in scripts/lib_walk_owner.sh: a record carrying an
# owner value is counted without printing it, a clean one is not, and the
# positive control holds. THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
T="$(mktemp -d)" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

OWNER_UUID="0A1B2C3D-0000-4000-8000-00000000A0A0"
OTHER_UUID="0A1B2C3D-0000-4000-8000-00000000B0B0"
STANDIN_NAME="Jane Doe"           # synthetic stand-in for the real owner
mkdir -p "$T/driver" "$T/bin"
printf 'OWNER_NAME="%s"\nOWNER_EMAIL=jane.doe@example.com\nOWNER_PHONE=+447700900123\n' "$STANDIN_NAME" > "$T/driver/owner_identity.env"
printf '# synthetic\n%s ownerac\n' "$OWNER_UUID" > "$T/driver/owner_targets.conf"

# ── cut the real owner block out of ttywalk.sh ──────────────────────────
start="$(/usr/bin/grep -n "^# THE WALK'S OWNER\." "$SUBJECT" | head -1 | cut -d: -f1)"
end="$(/usr/bin/grep -n '^if \[\[ "\$STAGE_ONLY" -eq 1 \]\]; then' "$SUBJECT" | head -1 | cut -d: -f1)"
if [ -z "$start" ] || [ -z "$end" ] || [ "$end" -le "$start" ]; then
    echo "CANNOT-RUN: could not locate the owner block in ttywalk.sh (start=${start:-?} end=${end:-?})" >&2; exit 2
fi
sed -n "${start},$((end - 1))p" "$SUBJECT" > "$T/block.sh"

# Stubs: `ssh` runs the command in the fake remote HOME; ioreg/id answer the
# UUID and account each case declares.
cat > "$T/bin/fakessh" <<'SH'
#!/bin/bash
shift $(( $# - 1 ))
HOME="$FAKE_REMOTE" exec /bin/bash -c "$1"
SH
cat > "$T/bin/ioreg" <<'SH'
#!/bin/bash
[ -n "${FAKE_UUID:-}" ] && printf '  "IOPlatformUUID" = "%s"\n' "$FAKE_UUID"
exit 0
SH
cat > "$T/bin/id" <<'SH'
#!/bin/bash
printf '%s\n' "$FAKE_ACCT"
SH
chmod +x "$T/bin/"*

# run_case NAME UUID ACCT [TARGETS_FILE] -> sets RC, OUT, ANSWER
run_case() {
    local name="$1"; local targets="${4:-$T/driver/owner_targets.conf}"
    local remote="$T/remote_$name"; mkdir -p "$remote"
    # A STALE owner file from an earlier walk: a non-owner walk must clear it.
    cp "$T/driver/owner_identity.env" "$remote/.walk-owner.env"
    cat > "$T/run_$name.sh" <<SH
set -uo pipefail
PASS=0; FAIL=1; CANNOT_RUN=2
die() { printf 'CANNOT-RUN: %s\n' "\$*" >&2; exit 2; }
say() { printf '%s\n' "\$*"; }
SSH=("$T/bin/fakessh" -o BatchMode=yes fakehost)
BASH_SOURCE_DIR="$REPO/scripts"
SH
    # ttywalk sources its lib relative to BASH_SOURCE; point that at the repo.
    sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#${REPO}/scripts#g" "$T/block.sh" >> "$T/run_$name.sh"
    OUT="$(PATH="$T/bin:$PATH" FAKE_REMOTE="$remote" FAKE_UUID="$2" FAKE_ACCT="$3" \
        OSTLER_WALK_OWNER_FILE="$T/driver/owner_identity.env" OSTLER_WALK_OWNER_TARGETS="$targets" \
        /bin/bash "$T/run_$name.sh" 2>&1)"; RC=$?
    ANSWER="$(HOME="$remote" python3 - "$REPO/scripts" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wd", sys.argv[1] + "/walk_drive.py")
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
print(wd.resolve(dict(wd.build_table())["Full name"]))
PY
)"
}

leaks() { case "$OUT" in *"$STANDIN_NAME"*|*jane.doe@example.com*|*900123*) return 0;; esac; return 1; }

# 1. NON-OWNER target, owner file present on the driver -> synthetic.
run_case nonowner "$OTHER_UUID" walk31
if [ "$RC" -eq 0 ] && [ "$ANSWER" = "Sam Doe" ]; then
    ok "non-owner target with an owner file present: installs the synthetic cast owner"
else
    bad "non-owner target answered a non-synthetic Full name (rc=$RC; stand-in leaked=$([ "$ANSWER" = "$STANDIN_NAME" ] && echo yes || echo no))"
fi
[ ! -e "$T/remote_nonowner/.walk-owner.env" ] && ok "non-owner target: a stale ~/.walk-owner.env is removed" || bad "non-owner target still holds ~/.walk-owner.env"

# 1b. Owner's UUID but a DIFFERENT account on it -> synthetic (pair, not host).
run_case otheracct "$OWNER_UUID" marta80q
[ "$RC" -eq 0 ] && [ "$ANSWER" = "Sam Doe" ] && ok "owner's host, other account: synthetic" || bad "owner's host, other account answered a non-synthetic name (rc=$RC)"

# 1c. No allowlist at all -> synthetic (nothing declared is never 'owner').
run_case nolist "$OWNER_UUID" ownerac "$T/driver/absent.conf"
[ "$RC" -eq 0 ] && [ "$ANSWER" = "Sam Doe" ] && ok "no owner-targets allowlist: synthetic even on the owner's pair" || bad "no allowlist answered a non-synthetic name (rc=$RC)"

# 2. OWNER target -> the owner file, staged 0600.
run_case owner "$OWNER_UUID" ownerac
if [ "$RC" -eq 0 ] && [ "$ANSWER" = "$STANDIN_NAME" ]; then
    ok "declared owner target: installs the owner file's identity"
else
    bad "declared owner target did not get the owner identity (rc=$RC)"
fi
perm="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$T/remote_owner/.walk-owner.env" 2>&1)"
[ "$perm" = 600 ] && ok "owner target: the staged file is 0600" || bad "owner target: staged file mode '${perm:-absent}'"

# 3. UNEVALUABLE predicate -> refuse, nothing staged.
run_case nouuid "" walk31
[ "$RC" -eq 2 ] && case "$OUT" in *REFUSING*) true;; *) false;; esac && ok "empty target UUID: the walk REFUSES (exit 2)" || bad "empty target UUID did not refuse (rc=$RC)"
printf 'not a pair at all\n' > "$T/driver/bad.conf"
run_case badlist "$OTHER_UUID" walk31 "$T/driver/bad.conf"
[ "$RC" -eq 2 ] && ok "malformed owner-targets allowlist: the walk REFUSES (exit 2)" || bad "malformed allowlist did not refuse (rc=$RC)"

# Never print a value.
any=0
run_case owner "$OWNER_UUID" ownerac; leaks && any=1
run_case nonowner "$OTHER_UUID" walk31; leaks && any=1
[ "$any" -eq 0 ] && ok "the harness output carries no owner value" || bad "an owner value appeared in harness output"

# ── the record scan, with its positive control ──────────────────────────
if [ -f "$REPO/scripts/lib_walk_owner.sh" ]; then
    # shellcheck source=scripts/lib_walk_owner.sh
    source "$REPO/scripts/lib_walk_owner.sh"
    printf 'version\tv0.0.0\nverdict\tCLEAN\n' > "$T/clean.tsv"
    printf 'version\tv0.0.0\nnote\tasked %s about it\nphone\t07700 900123 x\n' "jane DOE" > "$T/dirty.tsv"
    printf 'note\tcall 447700900123\n' > "$T/digits.tsv"
    S="$(walk_owner_scan_record "$T/clean.tsv" "$T/driver/owner_identity.env")"; r=$?
    [ "$r" -eq 0 ] && case "$S" in *"control 1/1; matching lines 0"*) true;; *) false;; esac && ok "record scan: a clean record is 0 matches, control 1/1" || bad "record scan on a clean record: rc=$r"
    S="$(walk_owner_scan_record "$T/dirty.tsv" "$T/driver/owner_identity.env")"; r=$?
    [ "$r" -eq 1 ] && case "$S" in *"matching lines 1"*) true;; *) false;; esac && ok "record scan: a record carrying the owner's name (any case) is counted" || bad "record scan missed the owner name: rc=$r"
    S="$(walk_owner_scan_record "$T/digits.tsv" "$T/driver/owner_identity.env")"; r=$?
    [ "$r" -eq 1 ] && ok "record scan: a digits-only owner phone is counted" || bad "record scan missed the digits-only phone: rc=$r"
    case "$S" in *"$STANDIN_NAME"*|*jane.doe*|*900123*) bad "record scan printed an owner value";; *) ok "record scan prints counts only";; esac
    : > "$T/empty_owner.env"; printf 'X=1\n' > "$T/empty_owner.env"
    walk_owner_scan_record "$T/clean.tsv" "$T/empty_owner.env" >/dev/null; r=$?
    [ "$r" -eq 2 ] && ok "record scan: an owner file yielding no values is CANNOT-RUN, not clean" || bad "record scan on a valueless owner file: rc=$r"
    # post_walk_qa.sh must call it on the record it writes.
    /usr/bin/grep -q 'walk_owner_scan_record "\$RECORD"' "$REPO/scripts/post_walk_qa.sh" \
        && ok "post_walk_qa.sh scans the record it writes" || bad "post_walk_qa.sh does not scan its record"
else
    bad "scripts/lib_walk_owner.sh is absent: no owner predicate and no record scan"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "PASS: owner identity only on a declared owner target; record scanned"; exit 0; }
echo FAIL; exit 1
