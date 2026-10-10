#!/usr/bin/env bash
# The v1.0.107 #17 scale gate, everything that can be proven without a box:
#   1. the scale fixture is deterministic (same seed -> byte-identical files),
#      carries 4,000+ unique synthetic people across the three export shapes,
#      and every person, email and phone is synthetic (cast tokens,
#      @example.com, Ofcom drama range)
#   2. qdrant_has_fd_headroom_and_writes_land: the judge rejects the #16
#      shapes (nofile 1024; fds at the limit; Places 0 of 979 written with
#      status=ok; chunks with no vectors) and the probe's --self-test is FAIL
#   3. assistant_self_description_is_clean and chat_latency_baseline: canned
#      replies (leaky -> red; clean and "I'm <Name>" -> green) and --self-test
#   4. the walk runner calls scale_fixture_apply (flush left, as the seeds)
# The Qdrant RED/GREEN against the pinned image needs docker and ~20 minutes
# per arm: scripts/qdrant_fd_scale_proof.sh, run by hand, not in CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fails=0; total=0
ok() { total=$((total + 1)); echo "  ok    $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "  FAIL  $1"; }
GEN=scripts/box_walk_probes/lib/scale_fixture.py
t1="$(mktemp -d)"; t2="$(mktemp -d)"
python3 "$GEN" generate --out "$t1/f" --reminders 200 --notes 50 >/dev/null \
    && python3 "$GEN" generate --out "$t2/f" --reminders 200 --notes 50 >/dev/null \
    || { echo "CANNOT-RUN: the generator did not run"; exit 2; }
diff -r "$t1/f" "$t2/f" >/dev/null && ok "the scale fixture is deterministic for a seed" || bad "two runs with the same seed differ"
python3 "$GEN" generate --out "$t2/g" --seed 109 --reminders 200 --notes 50 >/dev/null
diff -q "$t1/f/contacts/contacts.vcf" "$t2/g/contacts/contacts.vcf" >/dev/null \
    && bad "a different seed wrote the same contacts (the seed is not used)" || ok "control: a different seed writes different people"
python3 - "$t1/f" <<'PY' && ok "4,000+ unique people, three export shapes, all synthetic" || bad "people volume or synthetic-only check"
import csv, json, re, sys, io
d = sys.argv[1]
m = json.load(open(d + "/manifest.json"))
assert m["people_unique"] >= 4000, m
vcf = open(d + "/contacts/contacts.vcf").read()
li = open(d + "/linkedin/Connections.csv").read()
fb = json.load(open(d + "/facebook/your_friends.json"))["friends_v2"]
names = set(re.findall(r"^FN:(.+)\r?$", vcf, re.M))
rows = list(csv.DictReader(io.StringIO(li[li.index("First Name"):])))
names |= {"%s %s" % (r["First Name"], r["Last Name"]) for r in rows}
names |= {f["name"] for f in fb}
assert len(rows) == m["linkedin"] and len(fb) == m["facebook"]
emails = re.findall(r"[\w.+-]+@[\w.-]+", vcf + li)
assert emails and all(e.endswith("@example.com") for e in emails), "a non-example.com address"
phones = re.findall(r"^TEL;[^:]*:(.+)\r?$", vcf, re.M)
assert phones and all(p.startswith("+44 7700 900") for p in phones), "a phone outside the Ofcom drama range"
cast = set(open(".pii-name-registry.tsv").read().lower().split())
for n in names:
    for w in re.findall(r"[A-Za-z]{2,}", n):
        assert w.lower() in cast, "not a cast token: %r" % w
PY
python3 scripts/box_walk_probes/lib/qdrant_fd_headroom.py --self-test >/dev/null 2>&1 \
    && ok "qdrant_fd_headroom judge: the #16 shapes all go red, the good capture passes" || bad "qdrant_fd_headroom self-test"
python3 scripts/box_walk_probes/lib/assistant_chat.py --self-test >/dev/null 2>&1 \
    && ok "assistant_chat judges: leaky and vocative replies red, clean and self-naming replies green" || bad "assistant_chat self-test"
for p in qdrant_has_fd_headroom_and_writes_land assistant_self_description_is_clean chat_latency_baseline; do
    bash "scripts/box_walk_probes/probes/$p.sh" --self-test >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] && ok "$p --self-test returns FAIL (1)" || bad "$p --self-test returned $rc"
done
grep -q '^scale_fixture_apply' scripts/box_walk_probes/run_box_walk.sh \
    && ok "run_box_walk.sh calls scale_fixture_apply" || bad "run_box_walk.sh never calls scale_fixture_apply"
for p in qdrant_has_fd_headroom_and_writes_land assistant_self_description_is_clean; do
    grep -q "^${p}	blocking	" scripts/walk_promote_scope.tsv \
        && ok "$p is BLOCKING in walk_promote_scope.tsv" || bad "$p is not declared blocking"
done
grep -q "^chat_latency_baseline	advisory	" scripts/walk_promote_scope.tsv \
    && ok "chat_latency_baseline is ADVISORY" || bad "chat_latency_baseline is not declared advisory"
echo "== $((total - fails)) pass / $fails fail / $total total =="
[ "$fails" -eq 0 ]
