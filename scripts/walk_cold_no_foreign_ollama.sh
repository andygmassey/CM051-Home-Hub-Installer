#!/bin/bash
# walk_cold_no_foreign_ollama.sh -- NEW-119. A cold box has NO ollama that the
# installer did not put there. Runs ON THE WALK BOX, fed over ssh by
# scripts/ttywalk.sh --reset (bash -s < this file), BEFORE anything is staged.
# Must run under /bin/bash 3.2.
#
# WHY (2026-10-29). A diagnostic install on a clean macOS 27.2 Mac failed
# because install.sh called a bare `ollama`. Every earlier walk had passed only
# because a leftover system ollama (and ~/.ollama/models) survived the "cold"
# reset: the cold box was never cold, so the walk could not see the defect.
#
# WHAT IT DOES, for EVERY login account on the box (dscl, UniqueID >= 501),
# not only the account the walk ssh-es in as:
#   - the account's LOGIN shell: PATH and `command -v ollama`; every ollama on
#     that PATH outside <home>/.ostler is FOREIGN;
#   - <home>/.ollama (the model store a previous ollama left behind);
#   - <home>/Applications/Ollama.app;
#   - the Homebrew service: LaunchAgents/homebrew.mxcl.ollama.plist and
#     `launchctl print gui/<uid>/homebrew.mxcl.ollama`;
# and once per box: the Homebrew ollama formula and cask (each brew prefix,
# run as the prefix owner), /Applications/Ollama.app, and any running ollama
# process outside a .ostler directory.
#
# Each item found is printed with its size (du -sk) and a sha256 (of the file
# for a binary; of a manifest of every file's relative path and size for a
# directory, so a multi-GB model store is not read end to end).
#
# WHAT IS REMOVED, AND WHAT IS ONLY LISTED (Archie, #3205 review). Removal is
# allowed ONLY in the WALKING account's home and in SYSTEM locations (the
# Homebrew formula, cask and service, /usr/local/bin and other paths outside
# /Users, /Applications/Ollama.app, running processes). Anything inside ANOTHER
# account's home -- its ~/.ollama, ~/Applications/Ollama.app, its LaunchAgent,
# its loaded agent, a binary on its PATH under its home -- is DETECTED ONLY:
# printed, never deleted, and the run ends CANNOT-RUN with the list. A script
# never deletes inside another person's home folder; a human or ORM clears it
# deliberately after reading the list. Then the whole examination runs AGAIN.
#
# VERDICTS (the trichotomy):
#   exit 0  PASS. Nothing foreign, or everything foreign removed and the second
#           look found nothing. The "examined:" lines are printed either way,
#           so a zero is visibly a real look and not an empty one.
#   exit 2  CANNOT-RUN. Something foreign survived removal, OR an account could
#           not be examined (no passwordless sudo to run as it, the login shell
#           did not answer, dscl listed nothing or did not list the walk user).
#           Never PASS: an account nobody looked at is not a clean account.
#
# ALSO: NO OSTLER LAUNCHD JOB (Archie, #3205; found by ORM). --reset with no
# uninstaller on the box left com.ostler.* LaunchAgent plists behind, which is
# not cold either. So the same pass asserts NO com.ostler.* plist in any
# account's ~/Library/LaunchAgents, /Library/LaunchAgents or
# /Library/LaunchDaemons, and NO loaded com.ostler.* label in any account's
# gui/<uid> domain or in the system domain. Same rules: the walking account's
# and the system ones are booted out, then deleted, then looked for again;
# another account's are listed only, and the run ends CANNOT-RUN.
#
# "com.ostler.*" ABOVE MEANS EVERY PREFIX IN OSTLER_LABEL_PREFIXES BELOW, which
# is exactly the set of launchd Label prefixes install.sh writes, derived from
# it (every <key>Label</key> string, resolved through its variable, and every
# literal assigned to a *label* variable). tests/test_ttywalk_reset_cold_no_
# foreign_ollama.sh re-derives that set from install.sh on every run and FAILS
# when install.sh writes a label no prefix here covers. ai.ostler.assistant is
# NOT in it: in install.sh it is only the daemon bundle CFBundleIdentifier
# (its TCC identity), never a launchd Label.
#
# TEST SEAMS (fakes only; tests/test_ttywalk_reset_cold_no_foreign_ollama.sh).
# Unset on a real walk.
#   COLD_ACCOUNTS          lines "name uid home shell" instead of dscl
#   COLD_SELF              the walk account instead of `id -un`
#   COLD_SUDO              sudo binary
#   COLD_BREW_CANDIDATES   space-separated brew paths
#   COLD_APPLICATIONS_DIR  instead of /Applications
#   COLD_PS_CMD            instead of `ps -axo pid=,command=`
#   COLD_LIBRARY_DIR       instead of /Library

set -u

SELF="${COLD_SELF:-$(id -un)}"
SUDO="${COLD_SUDO:-sudo}"
APPS="${COLD_APPLICATIONS_DIR:-/Applications}"
BREWS="${COLD_BREW_CANDIDATES:-/opt/homebrew/bin/brew /usr/local/bin/brew}"
PS_CMD="${COLD_PS_CMD:-ps -axo pid=,command=}"
LIB="${COLD_LIBRARY_DIR:-/Library}"
OSTLER_LABEL_PREFIXES="com.ostler. com.creativemachines.ostler. com.creativemachines.ostler-"
OSTLER_RE="($(printf '%s\n' $OSTLER_LABEL_PREFIXES | sed 's/[.]/[.]/g' | paste -sd'|' -))[A-Za-z0-9._-]+"
LABEL="homebrew.mxcl.ollama"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/walk-cold-ollama.XXXXXX")" || { echo "CANNOT-RUN: no scratch dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── accounts ────────────────────────────────────────────────────────────
list_accounts() {
    if [[ -n "${COLD_ACCOUNTS:-}" ]]; then
        printf '%s\n' "$COLD_ACCOUNTS" | awk 'NF>=4'
        return 0
    fi
    local n uid home shell
    dscl . -list /Users UniqueID 2>"$WORK/dscl.err" | awk '$2>=501 && $1 !~ /^_/' | while read -r n uid; do
        home="$(dscl . -read "/Users/$n" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
        shell="$(dscl . -read "/Users/$n" UserShell 2>/dev/null | awk '{print $2}')"
        printf '%s %s %s %s\n' "$n" "$uid" "${home:--}" "${shell:--}"
    done
}

# Run as an account: directly for the walk user, sudo -n for any other.
as_acct() {
    local a="$1"; shift
    if [[ "$a" == "$SELF" ]]; then "$@"; else "$SUDO" -n -H -u "$a" "$@"; fi
}

# LOADED MEANS THE services BLOCK, NOTHING ELSE (v1.0.120 walk, 2026-10-30).
# `launchctl print gui/<uid>` (and `print system`) also carries a
# "disabled services" block: launchd's persistent enable/disable OVERRIDES,
# which name labels that are not loaded and may not even exist. Grepping the
# whole print read an "enabled" override as a loaded label; bootout cannot
# remove an override, so the walk box refused as not cold forever (measured on
# Mini16: gui/501/com.ostler.fda-rerun "Could not find service", yet listed).
#
# AN ACCOUNT WITH NO LOGIN SESSION HAS NO gui/<uid> DOMAIN. `launchctl print
# gui/502` answers "125: Domain does not support specified action" for an
# account nobody is logged in as, so a second account on the walk box made the
# precondition NOT EXAMINED, CANNOT-RUN, on every walk. No session means no gui
# agent is loaded; the account's user/<uid> domain (which does exist) is read
# instead, its services block only, and the examined list says so. Neither
# domain answering is still NOT EXAMINED.
services_block() { awk '/^\tservices = [{]/{f=1;next} f&&/^\t[}]/{f=0} f'; }

kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# Per-account file checks, run AS the account (another account's home is not
# readable to the walk user). Prints KIND|path records.
ACCT_PROBE='
home="$1"; label="$2"; pathlist="$3"
uid="$(id -u)"
IFS=:
for d in $pathlist; do
    [ -n "$d" ] || continue
    if [ -x "$d/ollama" ] && [ ! -d "$d/ollama" ]; then
        case "$d/" in "$home/.ostler/"*) echo "OURS|$d/ollama" ;; *) echo "BIN|$d/ollama" ;; esac
    fi
done
unset IFS
[ -e "$home/.ollama" ] && echo "DIR|$home/.ollama"
[ -e "$home/Applications/Ollama.app" ] && echo "USERAPP|$home/Applications/Ollama.app"
[ -e "$home/Library/LaunchAgents/$label.plist" ] && echo "AGENT|$home/Library/LaunchAgents/$label.plist"
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then echo "LOADED|gui/$uid/$label"; fi
for pfx in $5; do for f in "$home"/Library/LaunchAgents/"$pfx"*.plist; do [ -e "$f" ] && echo "OSTPLIST|$f"; done; done
_dom="gui/$uid"
if _gui="$(launchctl print "gui/$uid" 2>/dev/null)"; then echo "__gui_ok"
elif _gui="$(launchctl print "user/$uid" 2>/dev/null)"; then echo "__gui_ok"; echo "__user_dom"; _dom="user/$uid"
fi
printf "%s\n" "$_gui" | awk "/^\tservices = [{]/{f=1;next} f&&/^\t[}]/{f=0} f" | grep -oE "$4" | sort -u | while read -r l; do echo "OSTLOADED|$_dom/$l"; done
echo "__probe_ok"
'

# examine OUTFILE EXAMINEDFILE -- writes KIND|acct|subject records.
examine() {
    local out="$1" ex="$2" n uid home shell login lpath cv rec acct_list="" nacct=0 b owner
    : > "$out"; : > "$ex"
    list_accounts > "$WORK/accounts" 2>>"$WORK/dscl.err"
    nacct="$(awk 'END{print NR}' "$WORK/accounts")"
    if [[ "$nacct" -eq 0 ]]; then
        echo "NOEXAMINE|-|no login account enumerated ($(tr '\n' ' ' < "$WORK/dscl.err"))" >> "$out"
        return
    fi
    if ! awk -v s="$SELF" '$1==s{f=1} END{exit !f}' "$WORK/accounts"; then
        echo "NOEXAMINE|-|the enumeration does not list the walk user ${SELF}; it is not a real look" >> "$out"
    fi
    while read -r n uid home shell; do
        acct_list="${acct_list}${acct_list:+,}${n}"
        if [[ "$home" == "-" || "$shell" == "-" ]]; then
            echo "NOEXAMINE|$n|no home or login shell recorded" >> "$out"; continue
        fi
        login="$(as_acct "$n" "$shell" -l -c 'printf "__login_ok\n%s\n" "$PATH"; command -v ollama 2>/dev/null; true' 2>/dev/null </dev/null)"
        if ! printf '%s\n' "$login" | grep -qx '__login_ok'; then
            echo "NOEXAMINE|$n|could not run its login shell ${shell} (sudo -n refused, or the shell did not answer)" >> "$out"; continue
        fi
        lpath="$(printf '%s\n' "$login" | awk 'p==1{print; exit} $0=="__login_ok"{p=1}')"
        cv="$(printf '%s\n' "$login" | awk 'p>=2{print} p==1{p=2} $0=="__login_ok"{p=1}' | head -1)"
        if [[ -n "$cv" ]]; then
            case "$cv" in
                "$home/.ostler/"*) echo "  ${n}: command -v ollama -> ${cv} (installer-owned, under .ostler)" >> "$ex" ;;
                /*) echo "BIN|$n|$cv" >> "$out" ;;
                *)  echo "NONPATH|$n|command -v ollama answered a non-path: ${cv}" >> "$out" ;;
            esac
        fi
        rec="$(as_acct "$n" /bin/bash -c "$ACCT_PROBE" _ "$home" "$LABEL" "$lpath" "$OSTLER_RE" "$OSTLER_LABEL_PREFIXES" 2>/dev/null </dev/null)"
        if ! printf '%s\n' "$rec" | grep -qx '__probe_ok'; then
            echo "NOEXAMINE|$n|could not run the file probe as ${n}" >> "$out"; continue
        fi
        if ! printf '%s\n' "$rec" | grep -qx '__gui_ok'; then
            echo "NOEXAMINE|$n|launchctl print gui/${uid} did not answer as ${n}; its loaded labels are unknown" >> "$out"
        fi
        if printf '%s\n' "$rec" | grep -qx '__user_dom'; then
            echo "  ${n}: no gui/${uid} domain (no login session, so no agent is loaded there); loaded labels read from user/${uid}" >> "$ex"
        fi
        printf '%s\n' "$rec" | grep -v -e '^__probe_ok$' -e '^__gui_ok$' -e '^__user_dom$' -e '^OURS|' | sed "s#|#|$n|#" >> "$out"
        echo "  ${n} (uid ${uid}, ${home}): login shell ${shell}, PATH dirs $(printf '%s' "$lpath" | awk -F: '{print NF}'), ~/.ollama, ~/Applications/Ollama.app, ${LABEL} plist + launchctl gui/${uid}, Ostler (${OSTLER_LABEL_PREFIXES}) plists + labels in gui/${uid}" >> "$ex"
    done < "$WORK/accounts"
    echo "  accounts (${nacct}): ${acct_list}" >> "$ex"

    for b in $BREWS; do
        if [[ ! -x "$b" ]]; then echo "  brew ${b}: absent" >> "$ex"; continue; fi
        owner="$(stat -f %Su "$b" 2>/dev/null)"
        if [[ -z "$owner" ]]; then echo "NOEXAMINE|-|cannot read the owner of ${b}" >> "$out"; continue; fi
        if ! as_acct "$owner" "$b" --version >/dev/null 2>&1 </dev/null; then
            echo "NOEXAMINE|$owner|cannot run ${b} as its owner ${owner}" >> "$out"; continue
        fi
        as_acct "$owner" "$b" list --formula ollama >/dev/null 2>&1 </dev/null && echo "BREWF|$owner|$b" >> "$out"
        as_acct "$owner" "$b" list --cask ollama >/dev/null 2>&1 </dev/null && echo "BREWC|$owner|$b" >> "$out"
        if as_acct "$owner" "$b" services list 2>/dev/null </dev/null | awk '$1=="ollama"{f=1} END{exit !f}'; then
            echo "BREWSVC|$owner|$b" >> "$out"
        fi
        echo "  brew ${b} (owner ${owner}): formula ollama, cask ollama, services list" >> "$ex"
    done
    [[ -e "$APPS/Ollama.app" ]] && echo "APP|-|$APPS/Ollama.app" >> "$out"
    for pfx in $OSTLER_LABEL_PREFIXES; do
        for f in "$LIB"/LaunchAgents/"$pfx"*.plist "$LIB"/LaunchDaemons/"$pfx"*.plist; do
            [[ -e "$f" ]] && echo "SYSPLIST|-|$f" >> "$out"
        done
    done
    echo "  ${LIB}/LaunchAgents and ${LIB}/LaunchDaemons: plists for ${OSTLER_LABEL_PREFIXES}" >> "$ex"
    if _sys="$(launchctl print system 2>/dev/null)"; then
        printf '%s\n' "$_sys" | services_block | grep -oE "$OSTLER_RE" | sort -u | while read -r l; do echo "SYSLOADED|-|system/$l"; done >> "$out"
        echo "  launchctl print system: labels for ${OSTLER_LABEL_PREFIXES}" >> "$ex"
    else
        echo "NOEXAMINE|-|launchctl print system did not answer; system labels are unknown" >> "$out"
    fi
    echo "  ${APPS}/Ollama.app" >> "$ex"
    $PS_CMD 2>/dev/null | awk '{pid=$1; c=$0; sub(/^ *[0-9]+ +/, "", c); split(c, a, " "); b=a[1]; sub(/.*\//, "", b);
        if ((b=="ollama" || c ~ /Ollama[.]app\//) && c !~ /\/[.]ostler\//) print "PROC|-|" pid " " c}' >> "$out"
    echo "  running processes named ollama or under Ollama.app (outside .ostler)" >> "$ex"
}

describe() {
    local kind="$1" a="$2" s="$3" kb sha bin
    case "$kind" in
        BIN)     printf 'FOREIGN binary [%s] %s  %s KB  sha256 %s\n' "$a" "$s" "$(as_acct "$a" du -skL "$s" 2>/dev/null | awk '{print $1}')" "$(as_acct "$a" shasum -a 256 "$s" 2>/dev/null | awk '{print $1}')" ;;
        DIR|USERAPP) printf 'FOREIGN %s [%s] %s  %s KB  sha256(manifest) %s\n' "$kind" "$a" "$s" \
                 "$(as_acct "$a" du -sk "$s" 2>/dev/null | awk '{print $1}')" \
                 "$(as_acct "$a" /bin/bash -c 'cd "$1" && find . -type f -exec stat -f "%N %z" {} + 2>/dev/null | LC_ALL=C sort | shasum -a 256' _ "$s" 2>/dev/null | awk '{print $1}')" ;;
        AGENT|LOADED) printf 'FOREIGN launchd [%s] %s\n' "$a" "$s" ;;
        OSTPLIST|SYSPLIST) bin="$a"; [[ "$bin" == "-" ]] && bin="$SELF"
                 printf 'LEFTOVER Ostler plist [%s] %s  %s bytes  sha256 %s\n' "$a" "$s" \
                 "$(as_acct "$bin" /bin/bash -c 'wc -c < "$1"' _ "$s" 2>/dev/null | tr -d ' ')" \
                 "$(as_acct "$bin" shasum -a 256 "$s" 2>/dev/null | awk '{print $1}')" ;;
        OSTLOADED|SYSLOADED) printf 'LEFTOVER Ostler label loaded [%s] %s\n' "$a" "$s" ;;
        BREWF|BREWC|BREWSVC)
            bin="$(dirname "$(dirname "$s")")/opt/ollama/bin/ollama"
            kb=""; sha=""
            [[ -e "$bin" ]] && { kb="$(kb_of "$(dirname "$(dirname "$s")")/Cellar/ollama")"; sha="$(sha_of "$bin")"; }
            printf 'FOREIGN homebrew %s [owner %s] via %s  %s KB  sha256 %s\n' "$kind" "$a" "$s" "${kb:-?}" "${sha:-?}" ;;
        APP)     bin="$s/Contents/Resources/ollama"
                 printf 'FOREIGN app %s  %s KB  sha256(Contents/Resources/ollama) %s\n' "$s" "$(kb_of "$s")" "$([[ -e "$bin" ]] && sha_of "$bin" || echo none)" ;;
        PROC)    printf 'FOREIGN process %s\n' "$s" ;;
        *)       printf '%s [%s] %s\n' "$kind" "$a" "$s" ;;
    esac
}

home_of() { awk -v n="$1" '$1==n{print $3}' "$WORK/accounts"; }
# protected KIND ACCOUNT SUBJECT -> 0 when the item is inside ANOTHER
# account's home (or is that account's launchd session), so it is listed only.
protected() {
    local kind="$1" a="$2" s="$3" h selfhome
    case "$kind" in PROC|BREWSVC|BREWF|BREWC|APP|SYSPLIST|SYSLOADED) return 1 ;; esac
    selfhome="$(home_of "$SELF")"
    if [[ "$a" != "$SELF" ]]; then
        case "$kind" in DIR|USERAPP|AGENT|LOADED|OSTPLIST|OSTLOADED) return 0 ;; esac
        h="$(home_of "$a")"
        case "$s" in "$h"/*) return 0 ;; esac
    fi
    # Any path under /Users that is not the walking account's own home is
    # someone else's, whichever account's PATH it was found on.
    [[ -n "$selfhome" ]] || return 0
    case "$s" in
        "$selfhome"/*) return 1 ;;
        /Users/*) return 0 ;;
    esac
    return 1
}

remove_item() {
    local kind="$1" a="$2" s="$3" uid
    case "$kind" in
        PROC)    kill "${s%% *}" 2>/dev/null || "$SUDO" -n kill "${s%% *}" 2>/dev/null; return 0 ;;
        LOADED|OSTLOADED) as_acct "$a" launchctl bootout "$s" >/dev/null 2>&1; return 0 ;;
        SYSLOADED) launchctl bootout "$s" >/dev/null 2>&1 || "$SUDO" -n launchctl bootout "$s" >/dev/null 2>&1; return 0 ;;
        OSTPLIST) uid="$(awk -v n="$a" '$1==n{print $2}' "$WORK/accounts")"
                 as_acct "$a" launchctl bootout "gui/${uid}/$(basename "$s" .plist)" >/dev/null 2>&1
                 as_acct "$a" rm -f "$s" ;;
        SYSPLIST) uid="$(awk -v n="$SELF" '$1==n{print $2}' "$WORK/accounts")"
                 case "$s" in */LaunchDaemons/*) d="system" ;; *) d="gui/${uid}" ;; esac
                 launchctl bootout "${d}/$(basename "$s" .plist)" >/dev/null 2>&1 \
                     || "$SUDO" -n launchctl bootout "${d}/$(basename "$s" .plist)" >/dev/null 2>&1
                 rm -f "$s" 2>/dev/null || "$SUDO" -n rm -f "$s" ;;
        AGENT)   uid="$(awk -v n="$a" '$1==n{print $2}' "$WORK/accounts")"
                 as_acct "$a" launchctl bootout "gui/${uid}/${LABEL}" >/dev/null 2>&1
                 as_acct "$a" rm -f "$s" ;;
        BREWSVC) as_acct "$a" "$s" services stop ollama >/dev/null 2>&1 </dev/null ;;
        BREWF)   as_acct "$a" "$s" uninstall --force --formula ollama >/dev/null 2>&1 </dev/null ;;
        BREWC)   as_acct "$a" "$s" uninstall --force --cask ollama >/dev/null 2>&1 </dev/null ;;
        APP)     rm -rf "$s" 2>/dev/null || "$SUDO" -n rm -rf "$s" ;;
        DIR|USERAPP) as_acct "$a" rm -rf "$s" ;;
        BIN)     as_acct "$a" rm -f "$s" 2>/dev/null || "$SUDO" -n rm -f "$s" ;;
        *)       return 1 ;;
    esac
}

# Order matters: stop what runs before deleting what it runs from.
PRIO='PROC LOADED OSTLOADED SYSLOADED AGENT OSTPLIST SYSPLIST BREWSVC BREWF BREWC APP USERAPP DIR BIN'

echo "NEW-119 cold precondition: no foreign ollama and no Ostler launchd job (${OSTLER_LABEL_PREFIXES}), on any account"
examine "$WORK/found1" "$WORK/examined1"
echo "examined:"; cat "$WORK/examined1"

if grep -q '^NOEXAMINE|' "$WORK/found1"; then
    grep '^NOEXAMINE|' "$WORK/found1" | sed 's/^NOEXAMINE|/  NOT EXAMINED [/; s/|/] /'
fi
nfound="$(grep -c -v -e '^NOEXAMINE|' -e '^$' "$WORK/found1")"
if [[ "$nfound" -gt 0 ]]; then
    echo "found ${nfound} foreign item(s):"
    while IFS='|' read -r k a s; do
        [[ "$k" == "NOEXAMINE" || -z "$k" ]] && continue
        echo "  $(describe "$k" "$a" "$s")"
    done < "$WORK/found1"
    for k in $PRIO; do
        while IFS='|' read -r kk a s; do
            [[ "$kk" == "$k" ]] || continue
            if protected "$kk" "$a" "$s"; then
                echo "  NOT REMOVED (inside another account's home; detect only) ${kk} [${a}] ${s}"
                continue
            fi
            if remove_item "$kk" "$a" "$s"; then echo "  removed ${kk} [${a}] ${s}"; else echo "  REMOVAL FAILED ${kk} [${a}] ${s}"; fi
        done < "$WORK/found1"
    done
    echo "re-checking after removal"
    examine "$WORK/found2" "$WORK/examined2"
else
    cp "$WORK/found1" "$WORK/found2"
fi

if grep -q . "$WORK/found2"; then
    echo "still present or not examined after removal:"
    while IFS='|' read -r k a s; do
        [[ -z "$k" ]] && continue
        if [[ "$k" == "NOEXAMINE" ]]; then echo "  NOT EXAMINED [${a}] ${s}"; else echo "  $(describe "$k" "$a" "$s")"; fi
    done < "$WORK/found2"
    if grep -v '^NOEXAMINE|' "$WORK/found2" | grep -q .; then
        echo "  Items inside another account's home are never deleted by this script."
        echo "  A human or ORM clears them deliberately after reading the list above."
    fi
    echo "NO-FOREIGN-OLLAMA: CANNOT-RUN (the box is not cold, or not every account could be examined; this is not a PASS)"
    exit 2
fi
if [[ "$nfound" -gt 0 ]]; then
    echo "NO-FOREIGN-OLLAMA: PASS (cleaned ${nfound} foreign item(s); second look found none)"
else
    echo "NO-FOREIGN-OLLAMA: PASS (nothing foreign on any examined account)"
fi
exit 0
