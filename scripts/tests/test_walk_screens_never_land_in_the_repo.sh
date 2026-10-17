#!/usr/bin/env bash
# scripts/tests/test_walk_screens_never_land_in_the_repo.sh
# DMG #23 privacy. The screens probes wrote screenshots and facts.json (which can
# carry REAL people's names) to $PWD/walk-screens/, inside the harness checkout of
# a PUBLIC repo, un-ignored: one `git add -A` would publish them. Now:
#  1. .gitignore covers walk-screens/ and walks/.record_walk.marker.*
#  2. the default dir is OUTSIDE the repo (walk store / evidence dir)
#  3. a real probe run writes NOTHING under the repo tree.
# EXIT 0 pass, 1 fail, 2 CANNOT-RUN. BASH 3.2.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SRC="${REPO}/scripts/box_walk_probes"
[ -f "${SRC}/lib/probe.sh" ] || { echo "CANNOT-RUN: no probe lib"; exit 2; }
WORK="$(mktemp -d)" || exit 78
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# 1. ignore rules (positive control: a tracked walk record must NOT be ignored)
cd "$REPO" || exit 78
git check-ignore -q walk-screens/x && ok "walk-screens/x is git-ignored" || bad "walk-screens/x is NOT ignored"
git check-ignore -q walk-screens/20260101T000000Z/customer-read/facts.json && ok "nested walk-screens file is ignored" || bad "nested walk-screens file NOT ignored"
git check-ignore -q walks/.record_walk.marker.12345 && ok "walks/.record_walk.marker.* is git-ignored" || bad "record_walk marker NOT ignored"
git check-ignore -q walks/v1.0.101.tsv && bad "CONTROL: a real walk record is wrongly ignored" || ok "control: walks/v1.0.101.tsv is not ignored"

# 2. default dir resolution
dir() { ( cd "$REPO" && env -i HOME="$WORK/hm" PATH="$PATH" "$@" bash -c '. scripts/box_walk_probes/lib/probe.sh; walk_screens_dir' ); }
inrepo() { case "$1" in "$REPO"/*) return 0;; *) return 1;; esac; }
d="$(dir)";                                  inrepo "$d" && bad "default dir is in the repo: $d" || ok "default dir is outside the repo (under HOME/.ostler/walks)"
case "$d" in "$WORK/hm/.ostler/walks/"*".evidence/screens") ok "default shape is <store>/<stamp>.evidence/screens";; *) bad "default shape wrong: $d";; esac
d="$(dir OSTLER_WALK_STORE="$WORK/store")";  case "$d" in "$WORK/store/"*) ok "OSTLER_WALK_STORE is honoured";; *) bad "store ignored: $d";; esac
d="$(dir OSTLER_BOX_WALK_EVIDENCE_DIR="$WORK/ev")"; [ "$d" = "$WORK/ev/screens" ] && ok "the run's evidence dir is honoured" || bad "evidence dir ignored: $d"
d="$(dir OSTLER_UNDER_TEST=1)";              case "$d" in "$WORK/hm/"*) bad "under test it fell to the real store: $d";; *) inrepo "$d" && bad "under test in repo" || ok "under test with no store: a temp dir, never the real store";; esac

# 3. a real probe run writes nothing under the repo tree
T="${WORK}/tree"; mkdir -p "$T"; cp -R "$SRC" "$T/box_walk_probes"
BIN="${WORK}/bin"; mkdir -p "$BIN"
cat > "$BIN/ssh" <<'EOS'
#!/bin/sh
case "$*" in *" -N "*|*"-N "*) sleep 20 ;; *zeroclaw_admin_token*) echo tok ;; *) echo no ;; esac
EOS
cat > "$BIN/py" <<'EOS'
#!/bin/sh
# stand-in for the Playwright driver: writes evidence into --out like the real one
while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
mkdir -p "$out"; echo '{}' > "$out/facts.json"; : > "$out/wiki.png"; exit 0
EOS
chmod +x "$BIN/ssh" "$BIN/py"
( cd "$T" && touch "$WORK/mark" && sleep 1 && PATH="$BIN:$PATH" HOME="$WORK/hm" OSTLER_BOX_HOST=fake.invalid \
    OSTLER_SCREENS_PYTHON="$BIN/py" perl -e 'alarm 90; exec @ARGV' bash box_walk_probes/probes/hub_screens_render_for_a_customer.sh ) > "$WORK/run.txt" 2>&1
found="$(find "$T" -newer "$WORK/mark" -type f 2>/dev/null | /usr/bin/grep -v '/__pycache__/' | wc -l | tr -d ' ')"
[ "$found" = "0" ] && ok "a real probe run wrote 0 files under the harness tree" || bad "probe run wrote $found file(s) under the tree"
w="$(find "$WORK/hm/.ostler/walks" -name facts.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$w" -ge 1 ] && ok "control: the run's evidence did land in the walk store ($w facts.json)" || bad "control: no evidence in the store (run output: $(tail -3 "$WORK/run.txt" | tr '\n' ' '))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
