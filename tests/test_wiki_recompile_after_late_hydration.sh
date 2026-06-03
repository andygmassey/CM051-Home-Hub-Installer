#!/usr/bin/env bash
#
# test_wiki_recompile_after_late_hydration.sh
#
# Regression test for task #598: on a fresh Mac, iCloud Contacts (and
# other sources) finish syncing AFTER the install-time wiki compile, so
# the install compiles a partial graph and the wiki looks empty. Two
# triggers self-heal it:
#
#   (a) the ostler-contact-resync success branch kicks the existing
#       wiki-recompile tick the moment late contacts land; and
#   (b) a bounded, self-removing first-day catch-up LaunchAgent reuses
#       the same tick to cover ANY late source for the first few hours,
#       then unloads itself, leaving the daily agent as steady state.
#
# This test byte-walks install.sh (no install run) and refuses any
# regression of either trigger. It must NEVER let the daily agent's
# interval be turned into a forever-every-30-min agent, and it must
# refuse any duplication of compile logic (both triggers must reuse
# wiki-recompile-tick.sh, never re-implement docker compose run).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS_SH="$REPO_ROOT/install.sh.strings.en-GB.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_wiki_recompile_after_late_hydration: FAILED" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Carve (a): the ostler-contact-resync wrapper heredoc.
# ---------------------------------------------------------------------------
RESYNC_BLOCK="$(awk '/bin\/ostler-contact-resync" <</{p=1} p; /^CRSEOF$/{if(p){print; exit}}' "$INSTALL_SH")"

if [[ -z "$RESYNC_BLOCK" ]]; then
    failure "could not carve the ostler-contact-resync wrapper heredoc"
fi

# (a1) The success branch (count > 0) must invoke the existing tick.
if ! grep -q 'wiki-recompile-tick.sh' <<<"$RESYNC_BLOCK"; then
    failure "(a) contact-resync wrapper never invokes wiki-recompile-tick.sh -- late contacts would not rebuild the wiki until the daily agent"
fi

# (a2) The trigger must be guarded on the tick being executable so an
# older layout degrades quietly.
if ! grep -q '\[\[ -x "${OSTLER_DIR}/bin/wiki-recompile-tick.sh" \]\]' <<<"$RESYNC_BLOCK"; then
    failure "(a) tick invocation is not guarded on the tick being executable"
fi

# (a3) The trigger must be backgrounded + non-fatal (nohup ... &) so a
# recompile failure can never break the re-sync or hold the agent open.
if ! grep -Eq 'nohup "?\$\{OSTLER_DIR\}/bin/wiki-recompile-tick.sh"?[^&]*&' <<<"$RESYNC_BLOCK"; then
    failure "(a) tick is not launched backgrounded/non-fatally (nohup ... &)"
fi

# (a4) It must fire BEFORE remove_self -- the agent must still self-remove.
# The success branch is the LAST remove_self call in the wrapper (the
# bounded-give-up branch calls remove_self earlier); compare the tick
# kick against that final call.
_trigger_line="$(grep -n 'nohup .*wiki-recompile-tick.sh' <<<"$RESYNC_BLOCK" | tail -1 | cut -d: -f1)"
_remove_line="$(grep -n '^    remove_self$' <<<"$RESYNC_BLOCK" | tail -1 | cut -d: -f1)"
if [[ -z "$_trigger_line" || -z "$_remove_line" ]] || [[ "$_trigger_line" -ge "$_remove_line" ]]; then
    failure "(a) tick must be kicked BEFORE remove_self in the success branch"
fi

# ---------------------------------------------------------------------------
# Carve (b): the first-day catch-up wrapper heredoc.
# ---------------------------------------------------------------------------
CATCHUP_BLOCK="$(awk '/bin\/ostler-wiki-recompile-catchup" <</{p=1} p; /^WCUEOF$/{if(p){print; exit}}' "$INSTALL_SH")"

if [[ -z "$CATCHUP_BLOCK" ]]; then
    failure "could not carve the ostler-wiki-recompile-catchup wrapper heredoc"
fi

# (b1) The catch-up wrapper must reuse the tick, NOT re-implement compile.
if ! grep -q 'wiki-recompile-tick.sh' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up wrapper does not reuse wiki-recompile-tick.sh"
fi
if grep -q 'docker compose' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up wrapper duplicates compile logic (docker compose) instead of reusing the tick"
fi

# (b2) The catch-up must be bounded: a MAX_TRIES-style cap.
if ! grep -q 'WIKI_CATCHUP_MAX_TRIES' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up wrapper has no MAX_TRIES cap -- could run forever"
fi
if ! grep -Eq 'tries.*-gt.*WIKI_CATCHUP_MAX_TRIES' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up wrapper does not compare its run counter against the cap"
fi

# (b3) The catch-up must self-remove once the cap is reached.
if ! grep -q 'remove_self' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up wrapper never self-removes its agent"
fi
if ! grep -q 'launchctl bootout' <<<"$CATCHUP_BLOCK"; then
    failure "(b) catch-up self-removal does not boot out its own LaunchAgent"
fi

# (b4) The catch-up LaunchAgent must be installed with its own label and a
# short StartInterval (and must be a distinct label from the daily agent).
if ! grep -q 'com.creativemachines.ostler.wiki-recompile-catchup' "$INSTALL_SH"; then
    failure "(b) catch-up LaunchAgent label is never installed"
fi
if ! grep -q 'WIKI_CATCHUP_INTERVAL_S' "$INSTALL_SH"; then
    failure "(b) catch-up plist has no StartInterval variable"
fi

# (b5) The DAILY agent's interval must stay daily. The bundled daily plist
# template must still be StartInterval 86400 -- the catch-up must NOT have
# rewritten it to a 30-min forever schedule.
DAILY_PLIST="$REPO_ROOT/wiki-recompile/launchd/com.creativemachines.ostler.wiki-recompile.plist"
if [[ -f "$DAILY_PLIST" ]]; then
    if ! grep -A1 '<key>StartInterval</key>' "$DAILY_PLIST" | grep -q '<integer>86400</integer>'; then
        failure "(b) the DAILY wiki-recompile plist interval is no longer 86400 -- the catch-up must not change the steady-state agent"
    fi
else
    failure "daily wiki-recompile plist template missing at $DAILY_PLIST"
fi

# (b6) The uninstaller must boot out AND remove the catch-up agent plist.
if ! grep -q 'bootout "gui/\$(id -u)/com.creativemachines.ostler.wiki-recompile-catchup"' "$INSTALL_SH"; then
    failure "uninstaller does not boot out the wiki-recompile-catchup agent"
fi
if ! grep -q 'rm -f "\${HOME}/Library/LaunchAgents/com.creativemachines.ostler.wiki-recompile-catchup.plist"' "$INSTALL_SH"; then
    failure "uninstaller does not remove the wiki-recompile-catchup plist"
fi

# ---------------------------------------------------------------------------
# Strings: the new user-facing MSG_* keys must exist.
# ---------------------------------------------------------------------------
if [[ -f "$STRINGS_SH" ]]; then
    for key in \
        MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI \
        MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED \
        MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED \
        MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK ; do
        if ! grep -q "${key}=" "$STRINGS_SH"; then
            failure "string ${key} is missing from the en-GB catalogue"
        fi
    done
else
    failure "install.sh.strings.en-GB.sh missing"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_wiki_recompile_after_late_hydration: FAILED" >&2
    exit 1
fi
echo "test_wiki_recompile_after_late_hydration: late-hydration wiki recompile wired (a: contact-resync kicks tick before remove_self, guarded + backgrounded; b: bounded self-removing catch-up agent reusing tick; daily interval unchanged; uninstaller + strings)"
