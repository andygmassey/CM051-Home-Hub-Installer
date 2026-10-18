#!/usr/bin/env bash
#
# test_email_checkpoint_lives_under_dot_ostler.sh
#
# The email-ingest tick used to hand ostler-fda OSTLER_HOME=$HOME. ostler-fda
# appends /state itself, so the Apple Mail checkpoint was written to
# ~/state/apple_mail_mbox_checkpoint.json, OUTSIDE ~/.ostler. The uninstaller
# never removed it, so a reinstall inherited "backfill complete" from the
# previous install and emitted zero messages every hour (measured on a walk
# box: 12 ticks, 20986 .emlx scanned per tick, 0 emitted).
#
# BEHAVIOURAL arm: runs the REAL tick against the REAL vendored emitter in a
# sandbox HOME and asserts where the checkpoint lands, and that a planted
# legacy checkpoint is removed. Wiring arms: the install-time hydrate, the
# generated uninstaller and box_pristine all name the same paths.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$REPO_ROOT/vendor/email_ingest/bin/email-ingest-tick.sh"
FAILED=0
failure() { echo "FAIL: $*" >&2; FAILED=1; }

SANDBOX="$(mktemp -d -t email-ckpt-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
H="$SANDBOX/home"
mkdir -p "$H/Library/Mail/V10" "$H/state"
# A legacy checkpoint shaped like the one found on the walk box.
cat > "$H/state/apple_mail_mbox_checkpoint.json" <<'JSON'
{"schema_version": 2, "backfill_complete": true, "newest_processed": "2026-09-23T04:31:53+00:00", "oldest_processed": "2026-06-16T04:24:17+00:00", "last_emit_count": 0}
JSON

set +e
env -i PATH="/usr/bin:/bin" HOME="$H" \
    PYTHONPATH="$REPO_ROOT/vendor" OSTLER_PYTHON="$(command -v python3)" \
    PWG_EMAIL_INGEST=/usr/bin/true \
    bash "$TICK" >"$SANDBOX/tick.out" 2>&1
rc=$?
set -e
echo "tick rc=$rc"

NEW="$H/.ostler/state/apple_mail_mbox_checkpoint.json"
if [[ ! -f "$NEW" ]]; then
    failure "checkpoint not written under ~/.ostler/state (tick rc=$rc); tail of tick output:"
    tail -n 15 "$SANDBOX/tick.out" >&2
fi
if [[ -f "$H/state/apple_mail_mbox_checkpoint.json" ]]; then
    failure "checkpoint still present at the legacy ~/state path (written or not removed)"
fi
if [[ -d "$H/state" ]]; then
    failure "empty legacy ~/state folder left behind"
fi

# Control: a non-empty ~/state that is not ours must survive.
mkdir -p "$H/state"; echo keep > "$H/state/someone-elses-file"
cp "$SANDBOX/tick.out" "$SANDBOX/tick1.out"
env -i PATH="/usr/bin:/bin" HOME="$H" PYTHONPATH="$REPO_ROOT/vendor" \
    OSTLER_PYTHON="$(command -v python3)" PWG_EMAIL_INGEST=/usr/bin/true \
    bash "$TICK" >"$SANDBOX/tick.out" 2>&1 || true
[[ -f "$H/state/someone-elses-file" ]] || failure "the tick deleted a file in ~/state it does not own"

# Wiring: install-time hydrate uses the same root as the tick.
if grep -n 'OSTLER_HOME="\$HOME"' "$REPO_ROOT/install.sh" >/dev/null; then
    failure "install.sh still runs ostler_fda.apple_mail_mbox with OSTLER_HOME=\$HOME"
fi
n=$(grep -c 'OSTLER_HOME="\$OSTLER_DIR" \$_HYDRATE_EMAIL_TIMEOUT_WRAP' "$REPO_ROOT/install.sh" || true)
[[ "$n" == "1" ]] || failure "install-time email hydrate does not pass OSTLER_HOME=\$OSTLER_DIR (count=$n)"

# Wiring: the generated uninstaller removes the legacy file.
body="$(awk '/<<.UNINSTALLEOF.$/{f=1;next} /^UNINSTALLEOF$/{f=0} f' "$REPO_ROOT/install.sh")"
n=$(grep -c 'rm -f "${HOME}/state/apple_mail_mbox_checkpoint.json"' <<<"$body" || true)
[[ "$n" == "1" ]] || failure "uninstaller body does not remove ~/state/apple_mail_mbox_checkpoint.json (count=$n)"

# Wiring: box_pristine removes and asserts it.
n=$(grep -c 'HOME}/state/apple_mail_mbox_checkpoint.json|' "$REPO_ROOT/scripts/box_pristine.sh" || true)
[[ "$n" == "1" ]] || failure "box_pristine.sh PATHS does not carry the legacy checkpoint (count=$n)"

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo "PASS: email checkpoint lives under ~/.ostler/state; legacy ~/state copy removed everywhere"
