# contact_cards_seed.sh -- sourced by run_box_walk.sh. Defines contact_cards_apply
# and contact_cards_forget.
#
# v1.0.115 walk34: no_person_holds_two_contact_cards (BLOCKING) was CANNOT-RUN,
# "ZERO icloud_contact_uid identifiers in the graph", because a cold walk account
# has no Contacts. This gives it cards THROUGH THE CODE THE INSTALLED HUB RUNS, so
# the resolver runs, the vectors exist, and the probe measures something:
#
#   1. contact_syncer.syncer --vcf <synthetic cards.vcf>   (install.sh hydrate_graph's line)
#   2. ostler_fda.pwg_ingest.ingest_imessage <synthetic conversation>
#   3. ostler_fda.dedupe_merge.run()                       (install.sh's order)
#   3b. pwg_ingest.ingest_people_to_qdrant()               (the shipped reconcile: the merge
#       survivor is sometimes the iMessage-minted node, whose URI has no vector until
#       this runs; measured, 2 of 6 local runs)
#   3c. identity_resolver.repair_merge_consistency --apply, AFTER the dedupe: this is the
#       shipped order since the "[116]" fix (install.sh's MERGE-CONSISTENCY REPAIR, SECOND
#       PASS, right after dedupe_merge). The seed runs its own dedupe after install, so it
#       must run the same repair after it, exactly as install.sh does; without it the
#       contact_syncer point on a merged-away card node stays (macOS CI runner: 9 vectors
#       for 8 people). Backups go to the walk-seed dir, never the pipeline tree.
#   4. read back: every cast Person has a vector, the nameless number has ONE
#      holder, the household landline has TWO (a real collision opportunity).
#
# Nothing here writes a triple or a vector by hand (#3072 r1 did, and graded a
# vacuous pass). The outcome is written to ~/.walk-contact-cards-seed-run so a
# CANNOT-RUN can be told from a seed that never applied. On "seeded" the BOX clock's
# epoch is also written to ~/.walk-contact-cards-seed-ts on the box: the duplicate-
# review probe waits for the Hub's cached /api/v1/contacts/diff report to be built
# after it (same clock as the report's as_of), else it is CANNOT-RUN (stale).

_ccs_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" "$OSTLER_BOX_HOST" "$1"
    else
        bash -c "$1"
    fi
}

# PYTHONPATH=$PIPE (v1.0.116 walk34, failed-guard): the fixture runs BY PATH from
# $D, so python puts $D on sys.path, not the cwd, and "from contact_syncer.syncer"
# raised ModuleNotFoundError (guard.err, shown in the forget step). Not TCC, not
# Contacts: the seed never touches the Contacts database, it feeds a synthetic vcf.
#
# Box-side prelude: paths, and the fixture staged from this repo. The pipeline
# venv (contact_syncer) and the email-ingest venv (ostler_fda) are the two the
# installer itself uses for these steps (install.sh _HYDRATE_PIPELINE_PY and
# _INITIAL_HYDRATE_PY); both carry the store-auth shim, so no credential is
# handled here.
_ccs_prelude() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "O=\$HOME/.ostler; D=\$O/walk-seed/contact-cards; PIPE=\$O/import-pipeline
PY=\$PIPE/.venv/bin/python; FDAPY=\$O/services/email-ingest/.venv/bin/python
OXI=\${OXIGRAPH_URL:-http://localhost:7878}
mkdir -p \$D && printf %s '$(base64 < "${here}/contact_cards_fixture.py" | tr -d '\n')' | base64 -d > \$D/contact_cards_fixture.py || { echo failed-stage; exit 0; }
[ -x \$PY ] || { echo failed-no-pipeline-venv; exit 0; }
export PYTHONPATH=\$PIPE\${PYTHONPATH:+:\$PYTHONPATH}"
}

_ccs_apply_script() {
    printf '%s\n' "$(_ccs_prelude)
rm -f \$HOME/.walk-contact-cards-seed-ts
cd \$PIPE || { echo failed-no-pipeline-dir; exit 0; }
real=\$(\$PY \$D/contact_cards_fixture.py guard 2>\$D/guard.err | tail -n 1)
case \"\$real\" in ''|*[!0-9]*) cat \$D/guard.err >&2; echo failed-guard; exit 0 ;; 0) : ;; *) echo skipped-real-contacts; exit 0 ;; esac
\$PY \$D/contact_cards_fixture.py stage \$D >/dev/null || { echo failed-stage-cards; exit 0; }
j=\$(\$PY -m contact_syncer.syncer --vcf \$D/cards.vcf --graph-endpoint \"\$OXI\" 2>\$D/syncer.log | tail -n 1)
n=\$(printf %s \"\$j\" | /usr/bin/python3 -c 'import json,sys; print(int(json.loads(sys.stdin.read()).get(\"imported\", -1)))')
case \"\$n\" in ''|*[!0-9]*|0) echo failed-syncer-imported-\${n:-nothing}; exit 0 ;; esac
[ -x \$FDAPY ] || { echo failed-no-ingest-venv; exit 0; }
\$FDAPY -c 'import json,sys; from pathlib import Path
from ostler_fda import pwg_ingest, dedupe_merge
r = pwg_ingest.ingest_imessage(Path(sys.argv[1])); m = dedupe_merge.run()
q = pwg_ingest.ingest_people_to_qdrant()
print(json.dumps({\"ingest\": r.get(\"status\"), \"merge\": m, \"vectors\": q.get(\"status\")}))' \$D >\$D/ingest.log 2>&1 || { echo failed-ingest-or-merge; exit 0; }
cd \$PIPE && \$PY -m identity_resolver.repair_merge_consistency --oxigraph-url \"\$OXI\" --qdrant-url \"\${QDRANT_URL:-http://localhost:6333}\" --backup-dir \$D/backups --apply >\$D/repair.log 2>&1 || { cat \$D/repair.log >&2; echo failed-merge-consistency-repair; exit 0; }
v=\$(\$PY \$D/contact_cards_fixture.py verify 2>\$D/verify.err | tail -n 1)
case \"\$v\" in seeded) date +%s > \$HOME/.walk-contact-cards-seed-ts ;; esac
echo \"\$v\""
}

_ccs_stage_and_run() {
    _ccs_box "$(_ccs_apply_script)" | tail -1
}

contact_cards_apply() {
    local state
    printf 'Contact cards seed (v1.0.115: no_person_holds_two_contact_cards was CANNOT-RUN on an empty graph)\n'
    state="$(_ccs_stage_and_run)"
    state="${state:-failed-no-answer}"
    printf '  %s\n\n' "$state"
    printf '%s\n' "$state" > "${HOME}/.walk-contact-cards-seed-run" 2>/dev/null || true
    case "$state" in seeded|skipped-real-contacts) return 0 ;; *) return 1 ;; esac
}

# Forget: delete the cast, surface forget's stderr, then remove the whole staged
# walk-seed/contact-cards dir (fixture, cards.vcf, logs, backups) so nothing is left behind.
_ccs_forget_script() {
    printf '%s\n' "$(_ccs_prelude)
cd \$PIPE || { echo failed-no-pipeline-dir; exit 0; }
out=\$(\$PY \$D/contact_cards_fixture.py forget 2>\$D/forget.err | tail -n 1)
cat \$D/forget.err >&2
rm -rf \"\$D\"; rmdir \"\$O/walk-seed\" 2>/dev/null
echo \"\$out\""
}

contact_cards_forget() {
    local out
    printf -- '--- CONTACT CARDS SEED: removing the synthetic cards ---\n'
    out="$(_ccs_box "$(_ccs_forget_script)" | tail -1)"
    printf '    %s\n\n' "${out:-failed-no-answer}"
}
