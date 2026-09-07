#!/usr/bin/env bash
# What actually reaches the customer between two commits?
#
# WHY THIS EXISTS. On 2026-09-07 the payload delta for v1.0.74 was reasoned out
# as "which commits touch install.sh", plus "gui/Makefile builds the DMG and is
# not in it". Both steps are true. Neither can see the other NINE payload
# inputs. Measured on that range: TWO payload inputs had changed, and the second
# was `vendor/VENDOR_MANIFEST.toml`, which is copied into the DMG and written
# onto the customer's machine by install.sh:1034.
#
# It happened not to matter -- it is copied, not branched on -- so the
# conclusion survived. The METHOD would have waved through a launchd plist, a
# services/doctor bump or a stale cut-bom.tsv just as readily, and all three
# reach the customer without touching install.sh.
#
# 🗿 THE PAYLOAD LIST IS PARSED FROM gui/Makefile, NEVER HARDCODED HERE. A
# hardcoded copy is a second source of truth that rots exactly like the
# reasoning it replaces: the day someone adds an input to the payload, a
# hardcoded list keeps reporting a confident, wrong answer.
#
# USAGE
#   scripts/payload_delta.sh <from-ref> [<to-ref>]   default to-ref: HEAD
#   scripts/payload_delta.sh --self-test
#
# Exit 0 when the delta was computed, 2 when the payload list could not be
# parsed -- CANNOT-RUN, because "no payload input changed" and "I could not
# find the payload inputs" print identically and only one is safe.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${PAYLOAD_DELTA_REPO:-$(cd "${HERE}/.." && pwd)}"
MAKEFILE="${REPO}/gui/Makefile"

# A parse that finds implausibly few inputs is a broken parse, not a small
# payload. The floor is deliberately below today's count so a legitimate
# removal does not trip it, and far above zero so a silent parse failure does.
MIN_INPUTS="${PAYLOAD_DELTA_MIN_INPUTS:-4}"

die() { printf '%s\n' "$*" >&2; exit 2; }

# Pull the payload sources out of the assembly recipe. They appear as shell
# assignments of the form NAME="$SRC_ROOT/<path>" inside the stage-payload
# block, so the repo-relative path is what follows SRC_ROOT/.
payload_sources() {
    [ -f "${MAKEFILE}" ] || return 1
    # shellcheck disable=SC2016  # the single quotes are the point: $$SRC_ROOT
    # is LITERAL text in the Makefile (make's escape for a shell $), so
    # expanding it here would search for whatever SRC_ROOT happens to be in
    # this shell, which is nothing.
    grep -oE '\$\$SRC_ROOT/[A-Za-z0-9_./$()-]+' "${MAKEFILE}" \
        | sed 's|^\$\$SRC_ROOT/||' \
        | grep -vE '^\$' \
        | sort -u
}

report() {
    local from="$1" to="${2:-HEAD}"

    git -C "${REPO}" rev-parse --verify --quiet "${from}^{commit}" >/dev/null \
        || die "CANNOT-RUN: '${from}' is not a commit in ${REPO}"
    git -C "${REPO}" rev-parse --verify --quiet "${to}^{commit}" >/dev/null \
        || die "CANNOT-RUN: '${to}' is not a commit in ${REPO}"

    local -a sources=()
    while IFS= read -r p; do [ -n "${p}" ] && sources+=("${p}"); done < <(payload_sources)

    if [ "${#sources[@]}" -lt "${MIN_INPUTS}" ]; then
        die "CANNOT-RUN: parsed only ${#sources[@]} payload input(s) from ${MAKEFILE} (floor ${MIN_INPUTS}). A broken parse reports a clean delta and looks identical to a real one."
    fi

    local total
    total="$(git -C "${REPO}" rev-list --count "${from}..${to}" 2>/dev/null || echo 0)"

    printf '== payload delta  %s..%s ==\n' "${from}" "${to}"
    printf '   %s commit(s) in range; %s payload input(s) parsed from gui/Makefile\n\n' \
           "${total}" "${#sources[@]}"

    local changed=0 p n
    for p in "${sources[@]}"; do
        # A path carrying an unexpanded Makefile variable cannot be resolved
        # here, and it is NOT absent. cuts/v$(VERSION)/MUST_CONTAIN.tsv is the
        # cut BOM: a real payload input whose path depends on the version being
        # built. Printing it as ABSENT would be a false finding on a file that
        # certainly ships, so it is named as version-dependent and handed back
        # to the caller to check per cut.
        # shellcheck disable=SC2016  # matching the literal characters of an
        # unexpanded make variable, not expanding one.
        case "${p}" in
            *'$('*|*'${'*)
                printf '  PER-CUT      %-38s version-dependent path; check it for the cut you are building\n' "${p}"
                continue ;;
        esac

        # A path that does not exist in the tree is reported, not skipped: an
        # input named by the Makefile and absent from the repo is a finding.
        if ! git -C "${REPO}" cat-file -e "${to}:${p}" 2>/dev/null \
           && [ ! -e "${REPO}/${p}" ]; then
            printf '  ABSENT       %-38s named by the Makefile, not in the tree at %s\n' "${p}" "${to}"
            continue
        fi
        n="$(git -C "${REPO}" diff --name-only "${from}..${to}" -- "${p}" 2>/dev/null | grep -c . || true)"
        if [ "${n}" -gt 0 ]; then
            changed=$((changed + 1))
            printf '  CHANGED      %-38s %s file(s)\n' "${p}" "${n}"
            git -C "${REPO}" log --oneline "${from}..${to}" -- "${p}" 2>/dev/null | sed 's/^/                 /'
        else
            printf '  unchanged    %s\n' "${p}"
        fi
    done

    printf '\n  %d of %d payload input(s) changed.\n' "${changed}" "${#sources[@]}"
    if [ "${changed}" -eq 0 ]; then
        printf '  Nothing that ships changed in this range.\n'
    else
        printf '  Every line above marked CHANGED reaches the customer. Reasoning from\n'
        printf '  install.sh alone would have named %d of them.\n' \
               "$(printf '%s\n' "${sources[@]}" | grep -cx 'install.sh' || true)"
    fi
    return 0
}

self_test() {
    local pass=0 fail=0 out rc
    echo "self-test: the parser must find the payload, and must refuse when it cannot"

    local -a s=()
    while IFS= read -r p; do [ -n "${p}" ] && s+=("${p}"); done < <(payload_sources)
    if [ "${#s[@]}" -ge "${MIN_INPUTS}" ]; then
        printf '  [PASS] parsed %d payload input(s) from gui/Makefile (floor %d)\n' "${#s[@]}" "${MIN_INPUTS}"
        pass=$((pass+1))
    else
        printf '  [FAIL] parsed only %d input(s); the report would be uninterpretable\n' "${#s[@]}"
        fail=$((fail+1))
    fi

    # install.sh must be among them, or the parser is finding the wrong thing.
    if printf '%s\n' "${s[@]}" | grep -qx 'install.sh'; then
        printf '  [PASS] install.sh is among the parsed inputs, so the parse is on target\n'; pass=$((pass+1))
    else
        printf '  [FAIL] install.sh is NOT among the parsed inputs; the parse found something else\n'; fail=$((fail+1))
    fi

    # CONTROL THAT MUST REFUSE: an empty Makefile must be CANNOT-RUN, never a
    # clean delta. Without this the floor is untested and a parse failure would
    # print "0 of 0 changed" and read as good news.
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/paydelta.XXXXXX")" || { echo "  [CANNOT-RUN] no temp dir"; return 1; }
    mkdir -p "${tmp}/gui" "${tmp}/scripts"
    : > "${tmp}/gui/Makefile"
    cp "${BASH_SOURCE[0]}" "${tmp}/scripts/"
    ( cd "${REPO}" && git rev-parse HEAD >/dev/null 2>&1 )
    out="$(PAYLOAD_DELTA_REPO="${tmp}" bash "${tmp}/scripts/$(basename "${BASH_SOURCE[0]}")" HEAD HEAD 2>&1)"; rc=$?
    if [ "${rc}" -eq 2 ] && grep -q 'CANNOT-RUN' <<< "${out}"; then
        printf '  [PASS] CONTROL: an unparseable Makefile is CANNOT-RUN (rc=2), not a clean delta\n'; pass=$((pass+1))
    else
        printf '  [FAIL] CONTROL: an empty Makefile gave rc=%s, so a parse failure can read as good news\n' "${rc}"
        printf '%s\n' "${out}" | sed 's/^/         /'
        fail=$((fail+1))
    fi
    rm -rf -- "${tmp}"

    printf '\n  PASS: %d  FAIL: %d\n' "${pass}" "${fail}"
    [ "${fail}" -eq 0 ] || return 1
    return 0
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    "")          die "usage: $0 <from-ref> [<to-ref>] | --self-test" ;;
    *)           report "$1" "${2:-HEAD}"; exit $? ;;
esac
