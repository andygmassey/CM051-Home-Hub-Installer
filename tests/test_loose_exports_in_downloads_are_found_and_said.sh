#!/usr/bin/env bash
# A LOOSE EXPORT IN DOWNLOADS IS FOUND, IMPORTED ONCE, AND EVERY RUN SAYS SO.
#
# MEASURED on a synthetic walk box (studio29, v1.0.107 candidate, #30): a
# loose calendar.ics, emails.mbox and contacts.vcf in ~/Downloads. The
# Downloads watcher (com.ostler.export-scan -> tick.sh -> ostler-scan-exports)
# recognised none of them and returned 0 at its `FOUND -eq 0` guard BEFORE it
# wrote anything: exit 0, 0-byte logs, no notification. The install-time scan
# had listed two of the same files as "Found 2 GDPR export(s)" from find arms
# of its own, so the two detectors disagreed about the same folder. And the
# installer's closing text sent the customer to Terminal to run a command
# against a folder that does not exist, with a literal escape code in it.
#
# This drives the SHIPPED text: the scanner and the install-time scan block
# are both extracted from install.sh, the detector is the shipped lib, and the
# importer and osascript are stubs that record their calls. Fake HOME,
# synthetic fixtures only. Nothing real is read or imported.
#
# THREE STATES. 0 pass, 1 fail, 2 CANNOT-RUN (which is not a pass).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
LIB="${REPO}/lib/ostler-detect-exports.sh"
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }
[ -f "$LIB" ] || { echo "CANNOT-RUN: no lib/ostler-detect-exports.sh" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/loose-exports.XXXXXX")" || { echo "CANNOT-RUN: no scratch dir" >&2; exit 2; }
trap 'rm -rf "$SB"' EXIT

# ── the shipped scanner ─────────────────────────────────────────────────────
SCAN="$SB/ostler-scan-exports"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-scan-exports" <<'"'"'SCANEOF'"'"'$/{f=1;next} /^SCANEOF$/{f=0} f' \
    "$INSTALL" > "$SCAN"
[ -s "$SCAN" ] || { echo "CANNOT-RUN: could not extract ostler-scan-exports from install.sh" >&2; exit 2; }
/bin/bash -n "$SCAN" || { echo "CANNOT-RUN: the extracted scanner does not parse" >&2; exit 2; }

mkdir -p "$SB/shim"
cat > "$SB/shim/osascript" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\${NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$SB/shim/osascript"

# A box: fake HOME with the shipped lib, a recording importer whose exit code
# is read from a file (so a test can make it fail), and an empty Downloads.
_box() {
    local h="$SB/$1"
    mkdir -p "$h/.ostler/lib" "$h/.ostler/bin" "$h/Downloads"
    cp "$LIB" "$h/.ostler/lib/ostler-detect-exports.sh"
    cat > "$h/.ostler/bin/ostler-import" <<EOF
#!/bin/bash
# records one line per call: the dir it was given, then what was in it
{ printf 'CALL %s\n' "\$1"; ls "\$1" 2>/dev/null | sed 's/^/  HAS /'; } >> "$h/importer.calls"
exit "\$(cat "$h/importer.rc" 2>/dev/null || echo 0)"
EOF
    chmod +x "$h/.ostler/bin/ostler-import"
    printf '%s\n' "$h"
}
_scan() {  # $1 = home
    HOME="$1" NOTIFY_LOG="$1/notify.log" PATH="$SB/shim:$PATH" \
        OSTLER_CATCHUP_BUDGET_SECONDS="${OSTLER_CATCHUP_BUDGET_SECONDS:-600}" \
        /bin/bash "$SCAN" >/dev/null 2>"$1/scan.err"
}
_calls() { grep -c '^CALL ' "$1/importer.calls" 2>/dev/null || true; }
_lastlog() { tail -n 1 "$1/.ostler/logs/export-scan.log" 2>/dev/null; }
_act() { sed -n "s/^$2=//p" "$1/.ostler/state/source_activity/downloads_exports.tsv" 2>/dev/null; }

# Synthetic fixtures. example.com and invented names only.
_mbox() { printf 'From pat@example.com Thu Jan  1 00:00:00 2026\nFrom: Pat Example <pat@example.com>\nSubject: synthetic\n\nhello\n' > "$1"; }
_ics() {
    { printf 'BEGIN:VCALENDAR\nVERSION:2.0\n'
      i=0; while [ "$i" -lt 40 ]; do
          printf 'BEGIN:VEVENT\nSUMMARY:synthetic fixture event %s\nEND:VEVENT\n' "$i"; i=$((i+1)); done
      printf 'END:VCALENDAR\n'; } > "$1"
}
_vcf() { printf 'BEGIN:VCARD\nVERSION:3.0\nFN:Pat Example\nEMAIL:pat@example.com\nEND:VCARD\n' > "$1"; }
_settle() { touch -t 202601010000 "$1"/* 2>/dev/null; }   # older than the growing-file check cares about

echo "=== A LOOSE EXPORT IN DOWNLOADS IS FOUND, IMPORTED ONCE, AND SAID ==="

# ── 1. loose .mbox, .ics and .vcf are RECOGNISED ────────────────────────────
echo "-- 1. a loose .mbox, .ics and .vcf are recognised by the watcher --"
H="$(_box one)"
_mbox "$H/Downloads/emails.mbox"; _ics "$H/Downloads/calendar.ics"; _vcf "$H/Downloads/contacts.vcf"
_settle "$H/Downloads"
_scan "$H"; rc=$?
[ "$rc" -eq 0 ] && ok "the watcher exits 0" || bad "the watcher exited ${rc}: $(tail -3 "$H/scan.err")"
L="$(_lastlog "$H")"
case "$L" in
    *"3 recognised"*) ok "all three loose files are recognised: ${L%% \{*}" ;;
    *) bad "the watcher did not recognise the three loose files. Last log line: ${L:-<none: nothing was logged>}" ;;
esac
if grep -q '  HAS emails.mbox' "$H/importer.calls" 2>/dev/null && grep -q '  HAS calendar.ics' "$H/importer.calls" 2>/dev/null; then
    ok "the importer was handed the mailbox and the calendar"
else
    bad "the importer never saw the mailbox and the calendar (calls: $(_calls "$H"))"
fi
if grep -q 'HAS contacts.vcf' "$H/importer.calls" 2>/dev/null; then
    bad "the .vcf was handed to an importer that has no vCard arm, so it would be reported imported and not be"
else
    ok "the .vcf, which no importer leg reads, was NOT handed over as if it would import"
fi

# ── 2. found-but-not-imported writes the REASON ─────────────────────────────
echo "-- 2. a recognised file that is not imported carries its reason --"
case "$L" in
    *"skipped 1 Contacts file because "*) ok "the log line names the skip and its reason" ;;
    *) bad "no skip reason in the log line: ${L:-<none>}" ;;
esac
H2="$(_box vcf_only)"
_vcf "$H2/Downloads/contacts.vcf"; _settle "$H2/Downloads"
_scan "$H2"
st="$(_act "$H2" last_status)"; dt="$(_act "$H2" last_detail)"
if [ "$st" = "not_imported" ] && printf '%s' "$dt" | grep -q 'found 1 export(s) in Downloads, imported 0' \
   && printf '%s' "$dt" | grep -qi 'contact card'; then
    ok "Doctor-facing record: status=${st}, detail says found 1, imported 0, and why"
else
    bad "found-but-not-imported is not recorded with its reason: status=${st:-<absent>} detail=${dt:-<absent>}"
fi
H3="$(_box importer_fails)"
_mbox "$H3/Downloads/emails.mbox"; _settle "$H3/Downloads"; echo 1 > "$H3/importer.rc"
_scan "$H3"
st="$(_act "$H3" last_status)"; dt="$(_act "$H3" last_detail)"
if [ "$st" = "error" ] && printf '%s' "$dt" | grep -q 'imported 0' \
   && grep -q 'exit code 1' "$H3/.ostler/state/export-scan/last_scan.tsv" 2>/dev/null; then
    ok "a failed import is recorded as error, imported 0, with the importer's exit code"
else
    bad "a failed import is not recorded honestly: status=${st:-<absent>} detail=${dt:-<absent>}"
fi
if grep -qi 'could not finish' "$H3/notify.log" 2>/dev/null && ! grep -qi 'now part of your world' "$H3/notify.log" 2>/dev/null; then
    ok "and the customer is told it could not finish, not that it worked"
else
    bad "failure notification wrong: $(cat "$H3/notify.log" 2>/dev/null)"
fi

# ── 3. a re-run does NOT re-import ──────────────────────────────────────────
echo "-- 3. a re-run does not re-import, and says already imported --"
before="$(_calls "$H")"
_scan "$H"
after="$(_calls "$H")"
L2="$(_lastlog "$H")"
if [ "${before:-0}" -ge 2 ] && [ "$after" = "$before" ]; then
    ok "second run made no new importer call (${before} -> ${after})"
else
    bad "second run re-imported: importer calls ${before} -> ${after}"
fi
case "$L2" in
    *"2 already imported"*) ok "the log says so: 2 already imported" ;;
    *) bad "the re-run log does not say already imported: ${L2:-<none>}" ;;
esac
# CONTROL: the ledger keys on size and mtime, so it is not "skip everything".
_ics "$H/Downloads/calendar.ics"; printf 'BEGIN:VEVENT\nSUMMARY:one more\nEND:VEVENT\n' >> "$H/Downloads/calendar.ics"
touch -t 202602010000 "$H/Downloads/calendar.ics"
_scan "$H"
[ "$(_calls "$H")" = "$((after + 1))" ] && ok "CONTROL: a CHANGED calendar is imported again (one new call)" \
    || bad "CONTROL: a changed file was not re-imported (calls ${after} -> $(_calls "$H"))"
# CONTROL: a failed import is retried, never written to the ledger.
rm -f "$H3/importer.rc"
_scan "$H3"
grep -q 'emails.mbox' "$H3/.ostler/state/export-scan/imported.tsv" 2>/dev/null \
    && ok "CONTROL: the failed mailbox is retried on the next run and then recorded" \
    || bad "CONTROL: a failed import was not retried"

# ── 4. an empty Downloads logs a line, not silence ──────────────────────────
echo "-- 4. an empty Downloads logs a line, and catch-up still runs first --"
H4="$(_box empty)"
mkdir -p "$H4/.ostler/bin/catchup.d"; : > "$H4/.ostler/lib/ostler_catchup.py"
cat > "$H4/.ostler/bin/catchup.d/10-probe.sh" <<EOF
#!/bin/bash
echo "ran budget=\$1" >> "$H4/catchup.ran"
EOF
chmod +x "$H4/.ostler/bin/catchup.d/10-probe.sh"
_scan "$H4"
L4="$(_lastlog "$H4")"
case "$L4" in
    *"0 candidate file(s), 0 recognised"*"status=no_data"*) ok "empty Downloads: ${L4%% \{*}" ;;
    *) bad "an empty Downloads wrote no summary line: ${L4:-<nothing logged>}" ;;
esac
[ "$(_act "$H4" last_status)" = "no_data" ] && ok "and the activity record says no_data" \
    || bad "no activity record for an empty run"
[ -s "$H4/catchup.ran" ] && ok "no exports present, catch-up STILL ran (the new early exit is after it)" \
    || bad "catch-up did not run with an empty Downloads"
# and with Downloads missing entirely
rm -rf "$H4/Downloads" "$H4/catchup.ran"
_scan "$H4"
case "$(_lastlog "$H4")" in
    *"no Downloads folder"*) ok "no Downloads folder at all is SAID, not silent" ;;
    *) bad "a missing Downloads folder was not said: $(_lastlog "$H4")" ;;
esac
[ -s "$H4/catchup.ran" ] && ok "and catch-up still ran" || bad "catch-up did not run when Downloads is missing"

# ── 5. the two detectors AGREE on every fixture ─────────────────────────────
echo "-- 5. the install-time scan and the watcher agree, file by file --"
BLOCK="$SB/install_scan_block.sh"
awk '/# >>> loose-export-scan/{f=1;next} /# <<< loose-export-scan/{f=0} f' "$INSTALL" > "$BLOCK"
if [ ! -s "$BLOCK" ]; then
    bad "the install-time scan has no shared-table block: it still detects loose files with its own find arms, so it can disagree with the watcher"
else
    H5="$(_box agree)"
    D="$H5/Downloads"
    _mbox "$D/emails.mbox"; _ics "$D/calendar.ics"; _vcf "$D/contacts.vcf"
    mkdir -p "$D/takeout-x/Takeout/Calendar" "$D/notes" "$D/Some App.app/Contents"
    _ics "$D/takeout-x/Takeout/Calendar/Work.ics"
    printf 'BEGIN:VCALENDAR\nEND:VCALENDAR\n' > "$D/tiny.ics"
    : > "$D/empty.mbox"
    printf '<?xml version="1.0"?><en-export><note><title>synthetic</title></note></en-export>\n' > "$D/notes/export.enex"
    printf '[01/01/2026, 09:00:00] Pat Example: hello\n' > "$D/WhatsApp Chat with Pat Example.txt"
    _ics "$D/Some App.app/Contents/bundled.ics"
    printf 'not an export\n' > "$D/readme.txt"
    _settle "$D"
    _scan "$H5"
    # watcher view: label, path, verdict
    awk -F'\t' 'NR > 1 { v = ($2 == "skipped") ? "skip" : "import"; print $1 "\t" $4 "\t" v }' \
        "$H5/.ostler/state/export-scan/last_scan.tsv" 2>/dev/null | sort > "$SB/watcher.view"
    # install-time view: run the shipped block with the shipped lib
    (
        set -u
        OSTLER_DIR="$H5/.ostler"; search_dir="$D"
        DETECTED_EXPORTS=(); DETECTED_EXPORT_ROOTS=(); LOOSE_EXPORTS_SKIPPED=()
        EXPORTS_DIR=""; TAKEOUT_MBOX_PATH=""
        # shellcheck source=/dev/null
        . "$BLOCK"
        for e in ${DETECTED_EXPORTS[@]+"${DETECTED_EXPORTS[@]}"}; do
            printf '%s\t%s\timport\n' "${e%%: *}" "${e#*: }"
        done
        for e in ${LOOSE_EXPORTS_SKIPPED[@]+"${LOOSE_EXPORTS_SKIPPED[@]}"}; do
            p="${e#*: }"; p="${p% (*}"
            printf '%s\t%s\tskip\n' "${e%%: *}" "$p"
        done
    ) 2>"$SB/install_block.err" | sort > "$SB/install.view"
    n="$(wc -l < "$SB/install.view" | tr -d ' ')"
    if [ "${n:-0}" -lt 7 ]; then
        bad "the install-time block saw only ${n} item(s); the harness or the block is broken: $(head -3 "$SB/install_block.err")"
    elif diff "$SB/install.view" "$SB/watcher.view" > "$SB/agree.diff"; then
        ok "both detectors return the same ${n} items with the same verdicts"
    else
        bad "the detectors DISAGREE: $(sed 's|'"$D"'/||g' "$SB/agree.diff" | tr '\n' ' ')"
    fi
    grep -q 'bundled.ics' "$SB/install.view" "$SB/watcher.view" \
        && bad "a file inside an .app bundle was reported as the customer's" \
        || ok "a file inside an .app bundle is pruned by both"
    grep -q 'readme.txt' "$SB/watcher.view" \
        && bad "a plain text file was reported as an export" \
        || ok "MUST-MISS: a plain readme.txt is not an export"
fi

# ── 6. the closing text: no Terminal command, no raw escape codes ───────────
echo "-- 6. the closing text tells the customer plainly, with no raw codes --"
NS="$SB/next_steps.sh"
awk '/^echo -e "  \$\{BOLD\}Next steps:\$\{NC\}"$/{f=1} f{print} f&&/Connect your accounts/{exit}' "$INSTALL" > "$NS"
if ! grep -q 'Connect your accounts' "$NS"; then
    echo "CANNOT-RUN: could not extract the Next steps block from install.sh" >&2; exit 2
fi
printf 'fi\n' >> "$NS"
OUT="$( BOLD='\033[1m'; NC='\033[0m'; USER_NAME="Pat Example"; EXPORTS_DIR=""
        # shellcheck source=/dev/null
        . "$NS" 2>&1 )"
if printf '%s' "$OUT" | grep -qF '\033'; then
    bad "the closing text prints a literal \\033 escape code"
else
    ok "no literal \\033 in the closing text"
fi
if printf '%s' "$OUT" | grep -q 'gdpr-exports'; then
    bad "the closing text still names the nonexistent gdpr-exports folder"
else
    ok "no gdpr-exports folder in the closing text"
fi
if printf '%s' "$OUT" | grep -q 'ostler-import'; then
    bad "the closing text still gives the customer a Terminal command"
else
    ok "no Terminal command in the closing text"
fi
printf '%s' "$OUT" | grep -q 'Downloads' && ok "it tells them to use their Downloads folder" \
    || bad "the closing text does not mention Downloads"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\342\200\224')" && bad "the closing text has an em dash" \
    || ok "no em dash"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
