# install.sh hand-off spec: WhatsApp -> 4-artefact conversation feed

Builder-H, 2026-05-31. For TNM. Do NOT have Builder-H edit install.sh;
this is the spec TNM wires. Mirrors `email_source/INSTALL_HANDOFF_SPEC.md`
and the spoken-bundle wiring.

## What this feed is

The CONVERSATION-MEMORY leg for WhatsApp. It reads the Hub Mac's
WhatsApp Desktop store (`ChatStorage.sqlite`), pulls message BODIES for
the in-tier chats (T1 DM + T2 intimate/active group; T3 large-passive is
skipped), renders a cleaned transcript plus CM048 metadata, and invokes
CM048's `pwg-convo process` so the four artefacts land under
`~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/`.

It is SEPARATE from the existing `hydrate_whatsapp` install sub-phase
(install.sh:9144+), which runs `python -m ostler_fda.whatsapp_history`
to push people-graph FACTS (metadata only: Person + lastContactWhatsApp
+ tier). The two read the same `ChatStorage.sqlite` but write different
products. They do not collide: different LaunchAgent label, different
wrapper, different state file, different output. This feed reads bodies;
the hydrate sub-phase never does.

The read is local-file-only against WhatsApp Desktop's already-synced
store. It never contacts Meta, never relays anything, never uses the
WhatsApp API.

## Source layout (HR015)

```
whatsapp_source/
  __init__.py
  reader.py        # ZTEXT body extractor (reuses ostler_fda.whatsapp_history)
  renderer.py      # transcript + CM048 metadata
  pipeline.py      # module entry: python -m whatsapp_source.pipeline
  bin/whatsapp-bundle-tick.sh
  launchd/com.creativemachines.ostler.whatsapp-bundle.plist
  tests/test_whatsapp_source.py
```

`reader.py` imports `ostler_fda.whatsapp_history` (the read-only open +
the three-tier classifier + Mac-epoch conversion). This module is ALSO
the one the hydrate sub-phase already vendors (CM051 #180). So the venv
that runs this feed must have `ostler_fda` importable, exactly as the
hydrate sub-phase needs it.

## 1. Stage the package + venv (mirror the email-source / spoken-source venv)

The wrapper runs `python -m whatsapp_source.pipeline`, and the reader
imports `ostler_fda.whatsapp_history`. So the venv interpreter must have
BOTH on its import path:

- Install `ostler_fda` into a dedicated venv at
  `${OSTLER_DIR}/services/whatsapp-source/.venv`
  (`pip install "$OSTLER_FDA_SRC"`, same pattern the hydrate sub-phase
  and the email-source venv use).
- Copy the `whatsapp_source/` package into the SOURCE_DIR the wrapper
  `cd`s into. SOURCE_DIR must be the parent of BOTH the
  `whatsapp_source/` package AND the `ostler_fda/` package the reader
  imports. Recommended: stage both under
  `${OSTLER_DIR}/services/whatsapp-source/` so
  `OSTLER_SOURCE_DIR=${OSTLER_DIR}/services/whatsapp-source`.
  (The venv site-packages already has `ostler_fda` from the pip install,
  so SOURCE_DIR only strictly needs the `whatsapp_source/` package;
  keeping `ostler_fda` alongside is belt-and-braces, matching email.)
- PyYAML: the contacts / privacy / label map loader imports `yaml`
  lazily and degrades to "no names, no labels, no L3 overrides" if
  absent. Add `pyyaml` to the venv pip install so the per-contact L3 +
  family/partner label map works.

The feed needs NO `ostler_security`: an L3 thread never reaches the gist
sink. The L2 sink path runs inside CM048's own venv (PWG_CONVO_CMD),
which already has `ostler_security`.

## 2. INSTALL_SNIPPET.sh

Add a `whatsapp-source/INSTALL_SNIPPET.sh` modelled byte-for-byte on the
email-source / spoken-source snippet. Differences:

- Wrapper: `bin/whatsapp-bundle-tick.sh` -> `$OSTLER_DIR/bin/`.
- Plist: `launchd/com.creativemachines.ostler.whatsapp-bundle.plist`.
- Label: `com.creativemachines.ostler.whatsapp-bundle`.
- Placeholders to sed-render in the plist:
  - `OSTLER_BIN`  -> `$OSTLER_DIR/bin`
  - `OSTLER_HOME` -> `$HOME`
  - `OSTLER_LOGS` -> `$LOGS_DIR`
  - `OSTLER_PYTHON_PATH` -> the whatsapp-source venv python3
  - `PWG_CONVO_CMD_VALUE` -> absolute CM048 pwg-convo invocation (the
    CM048 venv `python -m src.cli`, OR the installed `pwg-convo` console
    script). SAME value the email-bundle + spoken-bundle plists use.
- Make `$OSTLER_DIR/workspace` exist so the watermark
  (`whatsapp_source_state.json`) has somewhere to write.

## 3. Gate behind the WhatsApp-channel-enabled condition

This feed must only be wired when the customer enabled the WhatsApp
channel AND accepted the unofficial-read consent (the existing
`CHANNEL_WHATSAPP_ENABLED == true` + `CHANNEL_WHATSAPP_CONSENT_ACCEPTED`
gate that already guards the hydrate sub-phase at install.sh ~1766).
Reading message bodies is strictly more sensitive than the metadata the
hydrate sub-phase reads, so it rides the SAME consent gate, never a
weaker one. If the customer declined WhatsApp, do not install this
LaunchAgent at all.

## 4. Wrapper env the plist must set (already in the plist template)

```
OSTLER_PYTHON            whatsapp-source venv python3 (plist env)
PWG_CONVO_CMD            CM048 pwg-convo invocation (plist env)
```

And the wrapper reads these from the environment if the installer
exports them at copy time (all have safe defaults):

```
OSTLER_SOURCE_DIR         parent of whatsapp_source/ (default placeholder;
                          render to ${OSTLER_DIR}/services/whatsapp-source)
OSTLER_USER_DISPLAY_NAME  -> install.sh $USER_NAME (so the operator's own
                          messages render as "You")
OSTLER_CONTACTS           optional contacts.yaml (whatsapp: JID -> name +
                          contact_label/group_label + privacy_level)
OSTLER_WHATSAPP_SINCE_DAYS fresh-install + ongoing clamp (default 365)
OSTLER_WHATSAPP_DB        optional ChatStorage.sqlite override (tests /
                          non-standard installs; default is the standard
                          container path)
```

Recommend rendering `OSTLER_SOURCE_DIR` + `OSTLER_USER_DISPLAY_NAME`
into the wrapper at copy time (sed) OR into the plist
`EnvironmentVariables`, matching whatever the email-bundle /
spoken-bundle wiring chose. `$USER_NAME` already exists in install.sh.

## 5. FDA / app guards (never abort install)

- The wrapper exits 0 cleanly if `ChatStorage.sqlite` does not exist
  (WhatsApp Desktop never run). RunAtLoad will not hard-fail the agent.
- If the store exists but FDA is denied, the reader raises
  `PermissionError` with an FDA-grant message; the pipeline `run()`
  returns exit code 2. launchd records it in `whatsapp-bundle.err`; the
  install step must treat a non-zero bootstrap as a WARN, not a hard
  fail (mirror the email-bundle / hydrate_whatsapp warn-not-abort shape).
- An encrypted / mid-migration database surfaces as a `sqlite3` error;
  the reader's open will raise and the pipeline returns non-zero. Same
  WARN-not-abort treatment.
- Same bundle / clone / plaintext fallback chain as the hydrate sub-phase
  for obtaining the vendor source on productised vs dev installs.

## 6. Fresh-install + ongoing clamp ("your last year of WhatsApp")

`--since-days` (default 365, override `OSTLER_WHATSAPP_SINCE_DAYS`)
bounds the read window to the last year. This is the honest, code-true
promise: the store is windowed + T3-filtered by design, so the customer
copy must say **"your last year of WhatsApp conversations"**, NEVER
"full history" (see the older-messages recon note below for WHY the Mac
store does not even contain years of history).

The window bounds BOTH the session last-message filter AND the
per-message body pull, and a `--max-messages-per-chat` cap (default
2000, newest kept) prevents one runaway chat from blowing up a tick. The
watermark (`~/.ostler/workspace/whatsapp_source_state.json`) records the
last-bundled message timestamp PER chat, so subsequent ticks are
incremental: a chat is only re-dispatched when it carries a message
newer than the last one bundled (a fresh reply re-bundles the whole chat
so the four-artefact output stays complete).

## 7. Uninstall

Add to the install.sh uninstall section (near the existing email-bundle
bootout):

```
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.whatsapp-bundle" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.whatsapp-bundle.plist"
```

## 8. Doctor / progress copy

Add `whatsapp_bundle` to the LaunchAgent inventory line (alongside
"email-ingest, email-bundle, spoken-bundle, ...") and a
`progress "Setting up whatsapp-bundle LaunchAgent ..."` step. English
copy goes through the same MSG_ catalogue path as the other bundle
strings (Rule 0.9).

## 9. CONSENT-COPY UPDATE (first-class deliverable, ships in the SAME PR)

The consent + privacy copy must NEVER be ahead of the code. Until this
feed ships, the WhatsApp consent describes a metadata-only read. Once
this feed lands (bodies), update the copy in the SAME PR to honestly say
Ostler reads recent WhatsApp message **contents**, about the last year,
from the local store.

Direction for install.sh:1785 and the surrounding WhatsApp consent block
(install.sh ~1766-1810), plus `legal/consent_strings.py`
(`WHATSAPP_UNOFFICIAL_RISK_CONSENT`), the privacy policy, and docs:

- KEEP the hidden-folder / local-read framing verbatim ("reading the
  data WhatsApp Web has already saved into a hidden folder on your Mac",
  "We never contact Meta", "We just read the file they wrote locally").
- KEEP the full ToS / ban-risk disclosure block unchanged (it is already
  honest about the unofficial-read posture).
- UPDATE the "what we read" sentence so it is explicit that this now
  includes message CONTENTS, bounded to about the last year. Suggested
  edit to the line at install.sh ~1771 ("Ostler can read your WhatsApp
  messages locally on this Mac so you can search and reference them..."):
  make it say it reads the **content** of your recent WhatsApp messages
  (about the last year) from the local store, not just who you messaged
  and when.
- Do NOT promise "full history" or "all your WhatsApp". The honest
  promise everywhere is "your last year of WhatsApp conversations",
  because (a) the feed is windowed to 365 days and T3-filtered, and (b)
  the Mac Desktop store only holds a recent synced window in the first
  place (see recon note below).

This pairs with the narrow v1.0.0 #591 metadata-only edit ("reads who
you've messaged and when") -> now superseded by the contents wording, in
the SAME PR as the body extraction, never before.

## Recon note for the consent author (older-messages reality)

The macOS WhatsApp Desktop `ChatStorage.sqlite` is a COMPANION-device
store populated by the multi-device HistorySync push from the phone. It
holds only a recent synced window (commonly 1-3 months, sometimes up to
6-12 months depending on account age / volume / server-side config), NOT
years of history. The "full history / every message ever" claim in
`WHATSAPP_HISTORY_EXTRACTION.md` is about the iPhone LOCAL BACKUP
extraction path (a different file), not the Desktop store this feed
reads. So a customer wanting messages OLDER than what the feed surfaces
is bounded by what their PHONE has pushed to the Mac, not by our
`--since-days` filter. Widening `--since-days` past the synced window
returns nothing extra. Do not imply the year window is the limiting
factor when the store itself is the limit.
```
