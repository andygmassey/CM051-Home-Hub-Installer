#!/usr/bin/env bash
# Tests for scripts/verify_ab_results.py (the hub re-pin A/B chat-regression gate).
# Builds a throwaway git repo per case; each case is a PR shape with a verdict.
# AB_GATE=<path> runs the same cases against another copy of the script.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="${AB_GATE:-$here/scripts/verify_ab_results.py}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
OLD=$(printf 'a%.0s' $(seq 64)); NEW=$(printf 'b%.0s' $(seq 64)); HUB=$(printf 'c%.0s' $(seq 64))
T=$'\t'
P=$'run_stamp=20261011T010203Z\nrun_host=lab-mini-1'
H="question_id${T}old_pass${T}new_pass${T}n${T}old_tools_none${T}new_tools_none${T}old_p50_ms${T}new_p50_ms"

pins() { printf 'DAEMON_SHA256        ?= %s\nHUB_APP_SHA256       ?= %s\n' "$1" "$HUB" > gui/Makefile; }
mk() {
  r="$work/$1"; mkdir -p "$r/gui" "$r/ab-results"; cd "$r" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  pins "$OLD"; echo base > .keep; git add -A && git commit -qm base
}
# row <id> <old_pass> <new_pass> <n> <old_tools_none> <new_tools_none>
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t900\t800\n' "$@"; }
# put <sha> <drops> <rows...> : write ab-results/<sha>.tsv
put() { s="$1"; d="$2"; shift 2; { printf '%s\n%s\n' "$P" "$H"; printf '%s\n' "$@"; printf 'drops=%s\n' "$d"; } > "ab-results/$s.tsv"; }
run() { # run <name> <want-rc> [commit-message]
  cd "$work/$1" || exit 1; git add -A && git commit -qm "${3:-pr}"
  out="$(python3 "$gate" --base HEAD~1 --head HEAD 2>&1)"; rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1 rc=$rc :: $(echo "$out" | tail -1 | cut -c1-150)"
  else echo "NOT OK $1 rc=$rc want=$2"; echo "$out"; fail=1; fi
}
G="$(row q1 3 3 10 1 1)"

mk nofile;    pins "$NEW"; run nofile 1
mk good;      pins "$NEW"; put "$NEW" 0 "$(row q1 9 10 10 2 0)" "$(row q2 10 10 10 0 0)"; run good 0
mk noise;     pins "$NEW"; put "$NEW" 0 "$(row q1 10 9 10 0 0)" "$(row q2 9 8 10 0 0)" "$(row q3 10 10 10 0 2)"; run noise 0
mk lowfloor_unchanged; pins "$NEW"; put "$NEW" 0 "$(row q1 2 2 10 0 0)"; run lowfloor_unchanged 1
mk bigdrop;   pins "$NEW"; put "$NEW" 1 "$(row q1 10 7 10 0 0)"; run bigdrop 1
mk below8;    pins "$NEW"; put "$NEW" 1 "$(row q1 8 7 10 0 0)"; run below8 1
mk tools3;    pins "$NEW"; put "$NEW" 1 "$(row q1 10 10 10 0 3)"; run tools3 1
mk n5;        pins "$NEW"; put "$NEW" 0 "$(row q1 5 5 5 0 0)"; run n5 1
mk liar;      pins "$NEW"; put "$NEW" 0 "$(row q1 10 7 10 0 0)"; run liar 1
mk dropsnz;   pins "$NEW"; put "$NEW" 1 "$(row q1 10 10 10 0 0)"; run dropsnz 1
mk extracol;  pins "$NEW"; { printf '%s\n%s\ttext\n' "$P" "$H"; printf '%s\tsecret words\n' "$(row q1 10 10 10 0 0)"; echo drops=0; } > "ab-results/$NEW.tsv"; run extracol 1
mk textcell;  pins "$NEW"; put "$NEW" 0 "$(row 'What is Bob phone' 10 10 10 0 0)"; run textcell 1
mk wrongsha;  pins "$NEW"; put "$OLD" 0 "$G"; run wrongsha 1
mk hubonly;   printf 'DAEMON_SHA256        ?= %s\nHUB_APP_SHA256       ?= %s\n' "$OLD" "$NEW" > gui/Makefile; run hubonly 1
mk nostamp;   pins "$NEW"; { printf '%s\n%s\n%s\ndrops=0\n' 'run_host=lab-mini-1' "$H" "$(row q1 10 10 10 0 0)"; } > "ab-results/$NEW.tsv"; run nostamp 1
mk nohost;    pins "$NEW"; { printf '%s\n%s\n%s\ndrops=0\n' 'run_stamp=20261011T010203Z' "$H" "$(row q1 10 10 10 0 0)"; } > "ab-results/$NEW.tsv"; run nohost 1
mk hostspace; pins "$NEW"; P=$'run_stamp=20261011T010203Z\nrun_host=lab mini'; put "$NEW" 0 "$(row q1 10 10 10 0 0)"; run hostspace 1
mk hostpunct; pins "$NEW"; P=$'run_stamp=20261011T010203Z\nrun_host=lab_mini.1'; put "$NEW" 0 "$(row q1 10 10 10 0 0)"; run hostpunct 1
mk badstamp;  pins "$NEW"; P=$'run_stamp=2026-10-11\nrun_host=lab-mini-1'; put "$NEW" 0 "$(row q1 10 10 10 0 0)"; run badstamp 1
P=$'run_stamp=20261011T010203Z\nrun_host=lab-mini-1'
mk skip;      echo "# comment" >> gui/Makefile; run skip 0
# one file per sha: modify an existing results file
mk rerun_no;  put "$NEW" 0 "$(row q1 10 10 10 0 0)"; pins "$NEW"; git add -A; git commit -qm "repin"; put "$NEW" 0 "$(row q1 10 9 10 0 0)"; run rerun_no 1
mk rerun_yes; put "$NEW" 0 "$(row q1 10 10 10 0 0)"; pins "$NEW"; git add -A; git commit -qm "repin"; put "$NEW" 0 "$(row q1 10 9 10 0 0)"; run rerun_yes 0 $'pr\n\nab-rerun: first run hit a cold model'
mk add_only;  put "$NEW" 0 "$(row q1 10 10 10 0 0)"; pins "$NEW"; run add_only 0
if [ "$fail" = 0 ]; then echo "ALL OK"; else echo "FAILED"; fi
exit "$fail"
