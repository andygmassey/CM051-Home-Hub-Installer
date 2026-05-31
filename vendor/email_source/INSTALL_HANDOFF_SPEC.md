# install.sh hand-off spec: email -> 4-artefact conversation feed

Builder-D, 2026-05-31. For TNM. Do NOT have Builder-D edit install.sh;
this is the spec TNM wires.

## What this feed is

The CONVERSATION-MEMORY leg for email. It reads the Hub Mac's Apple
Mail store, threads messages into conversation threads, renders a
cleaned transcript plus CM048 metadata, and invokes CM048's
`pwg-convo process` so the four artefacts land under
`~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/`.

It is SEPARATE from the existing `email-ingest/` LaunchAgent
(`com.creativemachines.ostler.email-ingest`), which drains Apple Mail
into an mbox and pushes email FACTS into the graph via
`pwg-email-ingest`. The two feeds read the same Apple Mail store but
write different products. They do not collide: different LaunchAgent
label, different wrapper, different state file, different output.

## Source layout (HR015)

```
email_source/
  __init__.py
  reader.py        # Apple Mail .emlx reader (reuses ostler_fda primitives)
  threader.py      # reference-graph + subject-fallback threading
  pipeline.py      # module entry: python -m email_source.pipeline
  bin/email-bundle-tick.sh
  launchd/com.creativemachines.ostler.email-bundle.plist
  tests/test_email_source.py
```

Mirror the iMessage feed (`services/imessage_source/`) and the
existing `email-ingest/` for the install wiring conventions.

## 1. Stage the package + venv (mirror 3.14b-pre-venv email-ingest)

The wrapper runs `python -m email_source.pipeline`, and the reader
imports `ostler_fda.apple_mail_mbox`. So the venv interpreter must
have BOTH on its import path:

- Install `ostler_fda` into a dedicated venv at
  `${OSTLER_DIR}/services/email-source/.venv` (same as the
  email-ingest venv pattern: `pip install "$OSTLER_FDA_SRC"`).
- Copy the `email_source/` package into the SOURCE_DIR that the
  wrapper `cd`s into. SOURCE_DIR must be the parent of BOTH the
  `email_source/` package AND the `ostler_fda/` package the reader
  imports. Recommended: stage both under
  `${OSTLER_DIR}/services/email-source/` so
  `OSTLER_SOURCE_DIR=${OSTLER_DIR}/services/email-source`.
  (The venv site-packages already has ostler_fda from the pip
  install, so SOURCE_DIR only strictly needs the `email_source/`
  package; keeping ostler_fda alongside is belt-and-braces.)
- PyYAML: the contacts/privacy map loader imports `yaml` lazily and
  degrades to "no names, no L3 overrides" if absent. Add `pyyaml` to
  the venv pip install so the per-contact L3 map works.

The feed needs NO ostler_security: the L3 short-circuit means an L3
thread never reaches the gist sink. The L2 sink path runs inside
CM048's own venv (PWG_CONVO_CMD), which already has ostler_security.

## 2. INSTALL_SNIPPET.sh

Add an `email-source/INSTALL_SNIPPET.sh` modelled byte-for-byte on
`email-ingest/INSTALL_SNIPPET.sh`. Differences:

- Wrapper: `bin/email-bundle-tick.sh` -> `$OSTLER_DIR/bin/`.
- Plist: `launchd/com.creativemachines.ostler.email-bundle.plist`.
- Label: `com.creativemachines.ostler.email-bundle`.
- Placeholders to sed-render in the plist:
  - `OSTLER_BIN`  -> `$OSTLER_DIR/bin`
  - `OSTLER_HOME` -> `$HOME`
  - `OSTLER_LOGS` -> `$LOGS_DIR`
  - `OSTLER_PYTHON_PATH` -> the email-source venv python3
  - `PWG_CONVO_CMD_VALUE` -> absolute CM048 pwg-convo invocation
    (the CM048 venv `python -m src.cli`, OR the installed
    `pwg-convo` console script). SAME value the imessage-bundle
    plist uses.
- Make `$OSTLER_DIR/workspace` exist so the watermark
  (`email_source_state.json`) has somewhere to write. (email-ingest
  makes `imports/email` + `state`; this feed needs `workspace`.)

## 3. Wrapper env the plist must set (already in the plist template)

```
OSTLER_PYTHON            email-source venv python3 (plist env)
PWG_CONVO_CMD            CM048 pwg-convo invocation (plist env)
```

And the wrapper reads these from the environment if the installer
exports them when bootstrapping (optional, all have safe defaults):

```
OSTLER_SOURCE_DIR        parent of email_source/ (default placeholder;
                         render to ${OSTLER_DIR}/services/email-source)
OSTLER_USER_DISPLAY_NAME -> install.sh $USER_NAME
OSTLER_USER_EMAIL        -> install.sh $USER_EMAIL (so the operator's
                         own outgoing mail renders as "You")
OSTLER_CONTACTS          optional contacts.yaml (addr -> name, L3)
OSTLER_EMAIL_SINCE_DAYS  fresh-install clamp (default 30)
```

Recommend rendering `OSTLER_SOURCE_DIR`, `OSTLER_USER_DISPLAY_NAME`,
and `OSTLER_USER_EMAIL` into the wrapper at copy time (sed) OR adding
them to the plist `EnvironmentVariables` dict, matching whichever the
imessage-bundle wiring chose. `$USER_NAME` and `$USER_EMAIL` already
exist in install.sh (lines ~1405 / ~1441).

## 4. FDA / account guards (never abort install)

- The wrapper exits 0 cleanly if `~/Library/Mail` does not exist
  (Mail never opened). RunAtLoad will not hard-fail the agent.
- The reader raises `PermissionError` with an FDA-grant message if
  the Mail tree exists but FDA is denied; the pipeline `run()`
  returns exit code 2. launchd records it in `email-bundle.err`;
  the install step must treat a non-zero bootstrap as a WARN, not a
  hard fail (mirror the email-ingest `warn ... | exit "$rc"` shape
  and the install-side `if ... else warn` wrapper at 3.14a).
- Same bundle/clone/plaintext fallback chain as email-ingest 3.14a
  for obtaining the vendor source on productised vs dev installs.

## 5. Fresh-install clamp

`--since-days` (default 30, override `OSTLER_EMAIL_SINCE_DAYS`)
bounds the first read window so a fresh install does not bundle the
entire mailbox in one tick. The watermark
(`~/.ostler/workspace/email_source_state.json`) then keeps subsequent
ticks incremental: a thread is only re-dispatched when it carries a
message-id not previously bundled (a new reply re-bundles the whole
thread so the four-artefact output stays complete).

If TNM wants a progressive backfill like email-ingest's two-checkpoint
model, that is a later enhancement; v1.0 ships the simple 30-day
forward clamp, which is enough to seed recent conversation memory
without a multi-thousand-message first tick.

## 6. Uninstall

Add to the install.sh uninstall section (near the existing
email-ingest bootout at ~line 6536):

```
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.email-bundle" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.email-bundle.plist"
```

## 7. Doctor / progress copy

Add `email_bundle` to the LaunchAgent inventory line (~line 6439:
"Doctor, export watcher, hub power, email-ingest, wiki-recompile,
...") and a `progress "Setting up email-bundle LaunchAgent ..."`
step. No Rule 0.9 customer-string concerns beyond the progress label
(English copy goes through the same MSG_ catalogue path as the
email-ingest strings).
```
