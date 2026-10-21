# contact_cards_seed.sh -- sourced by run_box_walk.sh. Defines contact_cards_apply
# and contact_cards_forget.
#
# v1.0.115 walk34: no_person_holds_two_contact_cards (BLOCKING) was CANNOT-RUN,
# "ZERO icloud_contact_uid identifiers in the graph", because a cold walk account
# has no Contacts. This seeds six synthetic cards (lib/contact_cards_fixture.py)
# before the probes read the box, only when the graph holds none. The outcome is
# written to ~/.walk-contact-cards-seed-run so a CANNOT-RUN can be told from a
# seed that never applied.

_ccs_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" "$OSTLER_BOX_HOST" "$1"
    else
        bash -c "$1"
    fi
}

_ccs_stage_and_run() {
    local here dir
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dir='$HOME/.ostler/walk-contact-cards'
    _ccs_box "mkdir -p ${dir} && printf %s '$(base64 < "${here}/contact_cards_fixture.py" | tr -d '\n')' | base64 -d > ${dir}/contact_cards_fixture.py && cd ${dir} && python3 contact_cards_fixture.py $1" 2>/dev/null | tail -1
}

contact_cards_apply() {
    local state
    printf 'Contact cards seed (v1.0.115: no_person_holds_two_contact_cards was CANNOT-RUN on an empty graph)\n'
    state="$(_ccs_stage_and_run seed)"
    state="${state:-failed-no-answer}"
    printf '  %s\n\n' "$state"
    printf '%s\n' "$state" > "${HOME}/.walk-contact-cards-seed-run" 2>/dev/null || true
    case "$state" in seeded|skipped-real-contacts) return 0 ;; *) return 1 ;; esac
}

contact_cards_forget() {
    local out
    printf -- '--- CONTACT CARDS SEED: removing the synthetic cards ---\n'
    out="$(_ccs_stage_and_run forget)"
    printf '    %s\n\n' "${out:-failed-no-answer}"
}
