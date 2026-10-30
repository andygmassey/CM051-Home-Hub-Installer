#!/usr/bin/env bash
# Runs the REAL scripts/ttywalk.sh --from-dmg against a fake ssh (identity only)
# and a fake hdiutil, with a private TMPDIR, and asserts:
#  (2) a failed attach prints hdiutil's own stderr ("Resource busy");
#  (3) the ostler-dmg.* temp dir count is the same before and after, for a
#      failed attach AND for an attach that succeeds and the run then dies.
# Control: TTYWALK_SUBJECT pointed at a copy with the EXIT trap removed MUST
# leak (count 1), so a count of 0 means something.
# Exit: 0 holds | 1 broken | 2 CANNOT RUN
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJ="${TTYWALK_SUBJECT:-$HERE/../scripts/ttywalk.sh}"
[ -f "$SUBJ" ] || { echo "CANNOT RUN: no subject" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/tmp"; : > "$W/x.dmg"
printf '#!/bin/bash\nprintf "Foo\\nMac14,3\\nwalker\\n"\n' > "$W/bin/ssh"
cat > "$W/bin/hdiutil" <<'F'
#!/bin/bash
case "$1" in
  attach) if [ "$FAKE_ATTACH" = fail ]; then echo "hdiutil: attach failed - Resource busy" >&2; exit 16; fi; exit 0 ;;
  *) exit 0 ;;
esac
F
chmod +x "$W/bin/ssh" "$W/bin/hdiutil"
count() { find "$W/tmp" -maxdepth 1 -name 'ostler-dmg.*' | wc -l | tr -d ' '; }
run() { # $1 subject, $2 attach mode
  FAKE_ATTACH="$2" TMPDIR="$W/tmp" PATH="$W/bin:$PATH" bash "$1" --host walker@box --expect-name Foo --from-dmg "$W/x.dmg" 2>&1
}
fail=0
b=$(count); out="$(run "$SUBJ" fail)"; a=$(count)
if grep -q 'Resource busy' <<< "$out"; then echo "  ok    failed attach prints hdiutil's stderr (Resource busy)"; else echo "  FAIL  hdiutil stderr not printed: $(tail -c 200 <<< "$out")"; fail=1; fi
if [ "$b" = "$a" ]; then echo "  ok    failed attach: ostler-dmg.* count $b -> $a"; else echo "  FAIL  failed attach leaked: $b -> $a"; fail=1; fi
b=$(count); run "$SUBJ" ok >/dev/null; a=$(count)
if [ "$b" = "$a" ]; then echo "  ok    attach ok then die: ostler-dmg.* count $b -> $a"; else echo "  FAIL  attach-then-die leaked: $b -> $a"; fail=1; fi
# control: no EXIT trap must leak
sed 's/^trap _ttywalk_on_exit EXIT$/:/' "$SUBJ" > "$W/nocleanup.sh"
cp -R "$(dirname "$SUBJ")"/lib_*.sh "$W/" 2>/dev/null
b=$(count); run "$W/nocleanup.sh" fail >/dev/null 2>&1; a=$(count)
if [ "$a" -gt "$b" ]; then echo "  ok    control: with the EXIT trap removed the dir leaks ($b -> $a), so the count can fail"; else echo "  FAIL  control did not leak ($b -> $a): the count proves nothing"; fail=1; fi
exit "$fail"
