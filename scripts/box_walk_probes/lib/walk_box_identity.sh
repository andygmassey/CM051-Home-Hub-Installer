#!/usr/bin/env bash
# walk_box_declare_synthetic USER
#
# Declares a box synthetic (~/.ostler/state/synthetic-box) ONLY when the account
# running the walk is a walk account: `ostlerwalk` (the dedicated walk Mac) or
# walkN (the throwaway accounts). Any other account, including the owner's, is
# never declared, so the CONTEXT.md swap in owner_knowledge_score keeps refusing
# on a real owner's box. Walk 132 refused on the walk box because nothing ever
# declared it; Mini16 must stay undeclared (it holds real personal data).
#
# Prints DECLARED, ALREADY, or NOT_A_WALK_ACCOUNT. Writes only under $HOME/.ostler/state.
walk_box_declare_synthetic() {
    case "$1" in
        ostlerwalk|walk[0-9]*)
            if [ -f "$HOME/.ostler/state/synthetic-box" ]; then echo ALREADY; return 0; fi
            mkdir -p "$HOME/.ostler/state" && : > "$HOME/.ostler/state/synthetic-box" && echo DECLARED ;;
        *) echo NOT_A_WALK_ACCOUNT ;;
    esac
}
