#!/bin/bash
# NEW-119: ttywalk.sh --reset must refuse a box that is not cold because a
# foreign ollama survived the reset, on ANY account.
#
# THE DEFECT (2026-10-29). A diagnostic install on a clean macOS 27.2 Mac failed
# because install.sh called a bare `ollama`. Every earlier walk had passed only
# because a leftover system ollama (and ~/.ollama/models) survived the "cold"
# reset, so the walk could never see it.
#
# WHAT THIS DOES. Runs the real scripts/walk_cold_no_foreign_ollama.sh against
# FAKES ONLY: two fake accounts (alice = the walk user, bob = another account)
# with fake homes and fake login shells that set their own PATH, a fake sudo
# (can be told to refuse an account), a fake launchctl, a fake brew prefix, a
# fake /Applications and a fake process list. Nothing reads dscl, the real
# launchd, the real Homebrew or this machine's own ollama. HOME is a mktemp dir.
#
# SCENARIOS
#   CLEAN       nothing foreign. PASS, with the examined list naming BOTH accounts.
#   DIRTY       foreign ollama on alice's login PATH, bob's ~/.ollama, bob's
#               brew service plist (loaded), a brew formula, /Applications/
#               Ollama.app and a running ollama process; plus an installer-owned
#               ollama under alice's ~/.ostler. All foreign items printed with
#               size and sha, removed; PASS; the .ostler one untouched.
#   STUCK       the brew uninstall fails. CANNOT-RUN (rc 2), never PASS.
#   NO-EXAMINE  sudo refuses bob. CANNOT-RUN (rc 2), bob named as not examined.
#   MUTANT      the script with its account loop cut to the first account. The
#               bob-only dirty box then reads PASS with bob's ~/.ollama still
#               there; the assertions below must catch it.
#   WIRING      ttywalk.sh runs the script under --reset, before staging, and dies
#               on a non-zero.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${COLD_OLLAMA_SH:-$REPO/scripts/walk_cold_no_foreign_ollama.sh}"
TTYWALK="$REPO/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ "$(uname -s)" = Darwin ] || { echo "CANNOT-RUN: needs macOS (stat -f, shasum), as the walk box does" >&2; exit 2; }
[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no subject at $SUBJECT" >&2; exit 2; }
[ -f "$TTYWALK" ] || { echo "CANNOT-RUN: no ttywalk.sh" >&2; exit 2; }
/bin/bash -n "$SUBJECT" || { echo "CANNOT-RUN: subject does not parse" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'kill $(cat "$ROOT"/pids 2>/dev/null) 2>/dev/null; chmod -R u+w "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"; mkdir -p "$HOME"

# ── one fake box per scenario ──────────────────────────────────────────────
mkbox() {
    W="$ROOT/$1"; mkdir -p "$W/fakebin" "$W/Users/alice/.ostler/bin" "$W/Users/bob" "$W/alicebin" "$W/bobbin" \
        "$W/brew/bin" "$W/Applications" "$W/loaded" "$W/shells"
    : > "$W/ps.txt"
    for a in alice bob; do
        cat > "$W/shells/$a" <<EOF
#!/bin/bash
# fake login shell: -l -c CMD, with this account's login PATH
while [ \$# -gt 0 ]; do case "\$1" in -c) shift; break ;; *) shift ;; esac; done
PATH="$W/Users/$a/.ostler/bin:$W/${a}bin:$W/fakebin:/usr/bin:/bin" exec /bin/bash -c "\$1"
EOF
        chmod +x "$W/shells/$a"
    done
    cat > "$W/fakebin/sudo" <<EOF
#!/bin/bash
u=""
while [ \$# -gt 0 ]; do case "\$1" in -n|-H) shift ;; -u) u="\$2"; shift 2 ;; *) break ;; esac; done
if [ -z "\$u" ]; then [ -e "$W/sudo_root_refuse" ] && { echo "sudo: a password is required" >&2; exit 1; }; exec "\$@"; fi
grep -qx "\$u" "$W/sudo_refuse" 2>/dev/null && { echo "sudo: a password is required" >&2; exit 1; }
[ -d "$W/Users/\$u" ] && export HOME="$W/Users/\$u"
FAKE_ACCT="\$u" exec "\$@"
EOF
    cat > "$W/fakebin/launchctl" <<EOF
#!/bin/bash
case "\$1" in
  print)   [ -e "$W/loaded/\${FAKE_ACCT:-none}" ] ;;
  bootout) rm -f "$W/loaded/\${FAKE_ACCT:-none}" ;;
  *) exit 64 ;;
esac
EOF
    cat > "$W/brew/bin/brew" <<EOF
#!/bin/bash
case "\$*" in
  --version) echo "Homebrew 9.9.9-fake" ;;
  "list --formula ollama") [ -e "$W/brew/formula" ] ;;
  "list --cask ollama")    [ -e "$W/brew/cask" ] ;;
  "services list")         echo "Name Status User File"; [ -e "$W/brew/svc" ] && echo "ollama started x y" ; true ;;
  "services stop ollama")  rm -f "$W/brew/svc" ;;
  "uninstall --force --formula ollama") [ -e "$W/brew_stuck" ] && exit 1; rm -rf "$W/brew/formula" "$W/brew/opt" "$W/brew/Cellar" ;;
  "uninstall --force --cask ollama")    [ -e "$W/brew_stuck" ] && exit 1; rm -f "$W/brew/cask" ;;
  *) exit 1 ;;
esac
EOF
    cat > "$W/fakebin/fakeps" <<EOF
#!/bin/bash
while read -r pid rest; do [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null && echo "\$pid \$rest"; done < "$W/ps.txt"
EOF
    chmod +x "$W/fakebin/"* "$W/brew/bin/brew"
}

runbox() {   # runbox SUBJECT -> sets RC, OUT
    OUT="$(cd "$W" && PATH="$W/fakebin:/usr/bin:/bin" FAKE_ACCT=alice \
        COLD_ACCOUNTS="alice 501 $W/Users/alice $W/shells/alice
bob 502 $W/Users/bob $W/shells/bob" \
        COLD_SELF=alice COLD_SUDO="$W/fakebin/sudo" COLD_BREW_CANDIDATES="$W/brew/bin/brew" \
        COLD_APPLICATIONS_DIR="$W/Applications" COLD_PS_CMD="$W/fakebin/fakeps" \
        /bin/bash "$1" 2>&1)"; RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

dirty() {   # all foreign items, installer-owned one too
    printf 'fake-ollama-binary %s\n' "$1" > "$W/alicebin/ollama"; chmod +x "$W/alicebin/ollama"
    printf 'ours\n' > "$W/Users/alice/.ostler/bin/ollama"; chmod +x "$W/Users/alice/.ostler/bin/ollama"
    mkdir -p "$W/Users/bob/.ollama/models"; head -c 8192 /dev/zero > "$W/Users/bob/.ollama/models/blob"
    mkdir -p "$W/Users/bob/Library/LaunchAgents"; : > "$W/Users/bob/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
    : > "$W/loaded/bob"; : > "$W/brew/svc"; : > "$W/brew/formula"
    mkdir -p "$W/brew/opt/ollama/bin" "$W/brew/Cellar/ollama"; printf 'brewbin\n' > "$W/brew/opt/ollama/bin/ollama"
    mkdir -p "$W/Applications/Ollama.app/Contents/Resources"; printf 'appbin\n' > "$W/Applications/Ollama.app/Contents/Resources/ollama"
    mkdir -p "$W/procbin"; printf "#!/bin/bash\nexec sleep 300\n" > "$W/procbin/ollama"; chmod +x "$W/procbin/ollama"; "$W/procbin/ollama" </dev/null >/dev/null 2>&1 & echo $! >> "$ROOT/pids"; disown $! 2>/dev/null
    echo "$! $W/procbin/ollama serve" > "$W/ps.txt"
}

echo "== CLEAN"
mkbox clean; runbox "$SUBJECT"
[ "$RC" -eq 0 ] && has "NO-FOREIGN-OLLAMA: PASS (nothing foreign" && ok "clean box: PASS" || bad "clean box: rc=$RC"
has "examined:" && has "accounts (2): alice,bob" && has "  bob (uid 502" && has "  alice (uid 501" \
    && ok "clean box: examined list names both accounts" || bad "clean box: examined list incomplete"
has "Ollama.app" && has "brew $W/brew/bin/brew" && ok "clean box: examined list names brew and the app" || bad "clean box: examined list missing brew/app"

echo "== DIRTY (removable)"
mkbox dirty; dirty dirty; want_sha="$(shasum -a 256 "$W/alicebin/ollama" | awk '{print $1}')"
kill -0 "$(tail -1 "$ROOT/pids")" 2>/dev/null && ok "control: the fake foreign ollama process is alive before the run" || bad "control: fake process already dead, the kill limb would be vacuous"
runbox "$SUBJECT"
[ "$RC" -eq 0 ] && has "NO-FOREIGN-OLLAMA: PASS (cleaned" && ok "dirty box: cleaned, PASS" || { bad "dirty box: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
has "FOREIGN binary [alice] $W/alicebin/ollama" && has "sha256 $want_sha" && ok "binary printed with sha256" || bad "binary not printed with its sha256"
has "FOREIGN DIR [bob] $W/Users/bob/.ollama" && has "KB" && ok "bob ~/.ollama printed with size" || bad "bob ~/.ollama not printed with size"
for p in "$W/alicebin/ollama" "$W/Users/bob/.ollama" "$W/Users/bob/Library/LaunchAgents/homebrew.mxcl.ollama.plist" \
         "$W/loaded/bob" "$W/brew/formula" "$W/brew/svc" "$W/Applications/Ollama.app"; do
    [ ! -e "$p" ] && ok "removed ${p#$W/}" || bad "still present ${p#$W/}"
done
kill -0 "$(tail -1 "$ROOT/pids")" 2>/dev/null && bad "foreign ollama process still running" || ok "foreign ollama process killed"
[ -e "$W/Users/alice/.ostler/bin/ollama" ] && ok "installer-owned ~/.ostler ollama untouched" || bad "removed the installer-owned ~/.ostler ollama"
has "re-checking after removal" && ok "second look ran" || bad "no second look"

echo "== STUCK (removal fails)"
mkbox stuck; dirty stuck; : > "$W/brew_stuck"; runbox "$SUBJECT"
[ "$RC" -eq 2 ] && has "NO-FOREIGN-OLLAMA: CANNOT-RUN" && ok "unremovable item: CANNOT-RUN rc 2" || bad "unremovable item: rc=$RC"
has "NO-FOREIGN-OLLAMA: PASS" && bad "unremovable item printed PASS" || ok "unremovable item never prints PASS"
has "still present or not examined after removal" && has "FOREIGN homebrew BREWF" && ok "survivor named" || bad "survivor not named"

echo "== NO-EXAMINE (sudo refuses bob)"
mkbox noexam; echo bob > "$W/sudo_refuse"; runbox "$SUBJECT"
[ "$RC" -eq 2 ] && has "NOT EXAMINED [bob]" && ok "unexaminable account: CANNOT-RUN, bob named" || bad "unexaminable account: rc=$RC"

echo "== MUTANT (account loop skips the second account)"
MUT="$ROOT/mutant.sh"
sed 's#done < "\$WORK/accounts"#done < <(head -1 "$WORK/accounts")#' "$SUBJECT" > "$MUT"
if cmp -s "$SUBJECT" "$MUT"; then
    bad "mutant did not apply (subject unchanged), so it proves nothing"
else
    mkbox mutant; mkdir -p "$W/Users/bob/.ollama/models"; : > "$W/Users/bob/.ollama/models/blob"
    runbox "$MUT"; caught=0
    [ -e "$W/Users/bob/.ollama" ] && caught=$((caught+1))
    has "accounts (2): alice,bob" || caught=$((caught+1))
    [ "$caught" -gt 0 ] && ok "mutant caught ($caught assertion(s) red: bob's ~/.ollama survives / examined list lacks bob)" \
        || bad "mutant NOT caught"
    # and the real subject on the same bob-only box is green
    mkbox mutctl; mkdir -p "$W/Users/bob/.ollama/models"; : > "$W/Users/bob/.ollama/models/blob"
    runbox "$SUBJECT"
    [ "$RC" -eq 0 ] && [ ! -e "$W/Users/bob/.ollama" ] && has "accounts (2): alice,bob" \
        && ok "control: real subject cleans the bob-only box" || bad "control: real subject did not clean the bob-only box (rc=$RC)"
fi

echo "== WIRING (ttywalk.sh)"
blk="$(awk '/^# ── NEW-119/{f=1} f{print} f && /^fi$/{exit}' "$TTYWALK")"
printf '%s\n' "$blk" | grep -q 'if \[\[ "\$DO_RESET" -eq 1 \]\]' && ok "ttywalk: precondition sits under --reset" || bad "ttywalk: precondition not under --reset"
printf '%s\n' "$blk" | grep -q "walk_cold_no_foreign_ollama.sh" && printf '%s\n' "$blk" | grep -q "/bin/bash -s' < \"\$_cold_ollama_script\"" \
    && ok "ttywalk: ships the script to the box over ssh" || bad "ttywalk: does not ship the script"
printf '%s\n' "$blk" | grep -q '^        die "NEW-119' && ok "ttywalk: a non-zero dies (CANNOT-RUN)" || bad "ttywalk: a non-zero does not die"
l_new="$(grep -n '^# ── NEW-119' "$TTYWALK" | head -1 | cut -d: -f1)"
l_stage="$(grep -n '^# ── Stage:' "$TTYWALK" | head -1 | cut -d: -f1)"
[ -n "$l_new" ] && [ -n "$l_stage" ] && [ "$l_new" -lt "$l_stage" ] && ok "ttywalk: precondition runs before staging (line $l_new < $l_stage)" || bad "ttywalk: precondition not before staging"
/bin/bash -n "$TTYWALK" && ok "ttywalk.sh parses" || bad "ttywalk.sh does not parse"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -ge 20 ] || { echo "CANNOT-RUN: only $PASS assertions ran" >&2; exit 2; }
exit 0
