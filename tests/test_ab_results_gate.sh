#!/usr/bin/env bash
# Tests for scripts/verify_ab_results.py (the hub re-pin A/B chat-regression gate).
# Builds a throwaway git repo per case; each case is a PR shape with a verdict.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/scripts/verify_ab_results.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
OLD=$(printf 'a%.0s' $(seq 64)); NEW=$(printf 'b%.0s' $(seq 64)); HUB=$(printf 'c%.0s' $(seq 64))
H="question_id	old_pass	new_pass	n	old_tools_none	new_tools_none	old_p50_ms	new_p50_ms"

mk() {
  r="$work/$1"; mkdir -p "$r/gui" "$r/ab-results"; cd "$r" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  printf 'DAEMON_SHA256        ?= %s\nHUB_APP_SHA256       ?= %s\n' "$OLD" "$HUB" > gui/Makefile
  git add -A && git commit -qm base
}
repin() { printf 'DAEMON_SHA256        ?= %s\nHUB_APP_SHA256       ?= %s\n' "$NEW" "$HUB" > gui/Makefile; }
run() {
  cd "$work/$1" || exit 1; git add -A && git commit -qm pr
  out="$(python3 "$gate" --base HEAD~1 --head HEAD 2>&1)"; rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1 rc=$rc :: $(echo "$out" | tail -1)"
  else echo "NOT OK $1 rc=$rc want=$2"; echo "$out"; fail=1; fi
}

mk nofile;    repin;                                                                                         run nofile 1
mk good;      repin; printf '%s\nq1\t3\t3\t5\t1\t1\t900\t800\nq2\t2\t4\t5\t2\t0\t900\t800\ndrops=0\n' "$H" > "ab-results/$NEW.tsv"; run good 0
mk liar;      repin; printf '%s\nq1\t3\t2\t5\t1\t1\t900\t800\ndrops=0\n' "$H" > "ab-results/$NEW.tsv";        run liar 1
mk toolsrise; repin; printf '%s\nq1\t3\t3\t5\t1\t2\t900\t800\ndrops=0\n' "$H" > "ab-results/$NEW.tsv";        run toolsrise 1
mk extracol;  repin; printf '%s\ttext\nq1\t3\t3\t5\t1\t1\t900\t800\tsecret words\ndrops=0\n' "$H" > "ab-results/$NEW.tsv"; run extracol 1
mk textcell;  repin; printf '%s\nWhat is Bob phone\t3\t3\t5\t1\t1\t900\t800\ndrops=0\n' "$H" > "ab-results/$NEW.tsv"; run textcell 1
mk dropsnz;   repin; printf '%s\nq1\t3\t2\t5\t1\t1\t900\t800\ndrops=1\n' "$H" > "ab-results/$NEW.tsv";        run dropsnz 1
mk wrongsha;  repin; printf '%s\nq1\t3\t3\t5\t1\t1\t900\t800\ndrops=0\n' "$H" > "ab-results/$OLD.tsv";        run wrongsha 1
mk hubonly;   printf 'DAEMON_SHA256        ?= %s\nHUB_APP_SHA256       ?= %s\n' "$OLD" "$NEW" > gui/Makefile;   run hubonly 1
mk skip;      echo "# comment" >> gui/Makefile;                                                               run skip 0
if [ "$fail" = 0 ]; then echo "ALL OK"; else echo "FAILED"; fi
exit "$fail"
