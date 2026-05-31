# install.sh hand-off spec: spoken -> 4-artefact conversation feed

Builder-G, 2026-05-31. For TNM. Do NOT have Builder-G edit install.sh;
this is the spec TNM wires. Mirror the email-bundle wiring
(`email_source/INSTALL_HANDOFF_SPEC.md`) and the imessage-bundle
wiring; this feed is the third sibling in the same shape.

## What this feed is

The CONVERSATION-MEMORY leg for SPOKEN conversations: meetings, calls,
AND voice notes. It watches the Hub Mac's RemoteCapture (CM042)
transcript tree, normalises each finished recording session into a
cleaned speaker-labelled transcript plus CM048 metadata
(`channel="spoken"`), and invokes CM048's `pwg-convo process` so the
four artefacts land under
`~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/`.

It does NO capture / recording / transcription. CM042 (the
RemoteCapture macOS app) owns recording + Whisper transcription and
writes finished markdown transcripts under
`~/Documents/Ostler/Transcripts/YYYY/MM/`. This feed is read-only over
that tree. Meetings, calls, and voice notes all flow through this one
feed; a voice note is just a short single-speaker spoken capture and
needs no separate plumbing (single participant, no diarisation).

## Source layout (HR015)

```
spoken_source/
  __init__.py
  reader.py        # parses CM042 markdown transcripts (front matter + body)
  renderer.py      # cleaned transcript + CM048 metadata builder
  pipeline.py      # module entry: python -m spoken_source.pipeline
  bin/spoken-bundle-tick.sh
  launchd/com.creativemachines.ostler.spoken-bundle.plist
  tests/test_spoken_source.py
  INSTALL_HANDOFF_SPEC.md  (this file)
```

## 1. Stage the package + venv (mirror the email-source venv)

The wrapper runs `python -m spoken_source.pipeline`. Unlike the email
feed, the reader imports NO `ostler_fda` primitives (RemoteCapture
transcripts are plain markdown in the user-facing zone, no FDA needed).
So the venv is lighter:

- Create a venv at `${OSTLER_DIR}/services/spoken-source/.venv`.
- Copy the `spoken_source/` package into the SOURCE_DIR the wrapper
  `cd`s into. Recommended: stage it under
  `${OSTLER_DIR}/services/spoken-source/` so
  `OSTLER_SOURCE_DIR=${OSTLER_DIR}/services/spoken-source`.
- `pip install pyyaml` into the venv: the reader prefers PyYAML to
  parse the CM042 front matter and the privacy-map loader uses it.
  Both degrade gracefully without it (the reader has a built-in
  line-parser fallback for the exact CM042 shape; the privacy map is
  simply ignored), so PyYAML is recommended-not-required. Adding it
  matches the email-source venv and makes the per-source/per-context
  L3 map work.

The feed needs NO ostler_fda and NO ostler_security: the L3
short-circuit means an L3 capture never reaches the gist sink, and the
non-L3 sink path runs inside CM048's own venv (PWG_CONVO_CMD), which
already has ostler_security.

## 2. INSTALL_SNIPPET.sh

Add a `spoken-source/INSTALL_SNIPPET.sh` modelled byte-for-byte on
`email-source/INSTALL_SNIPPET.sh`. Differences:

- Wrapper: `bin/spoken-bundle-tick.sh` -> `$OSTLER_DIR/bin/`.
- Plist: `launchd/com.creativemachines.ostler.spoken-bundle.plist`.
- Label: `com.creativemachines.ostler.spoken-bundle`.
- Placeholders to sed-render in the plist:
  - `OSTLER_BIN`  -> `$OSTLER_DIR/bin`
  - `OSTLER_HOME` -> `$HOME`
  - `OSTLER_LOGS` -> `$LOGS_DIR`
  - `OSTLER_PYTHON_PATH` -> the spoken-source venv python3
  - `PWG_CONVO_CMD_VALUE` -> absolute CM048 pwg-convo invocation
    (the CM048 venv `python -m src.cli`, OR the installed
    `pwg-convo` console script). SAME value the email-bundle +
    imessage-bundle plists use.
- Placeholder to sed-render in the wrapper:
  - `OSTLER_SOURCE_DIR_PLACEHOLDER` -> `${OSTLER_DIR}/services/spoken-source`
- Make `$OSTLER_DIR/workspace` exist so the watermark
  (`spoken_source_state.json`) has somewhere to write. (Shared with
  the email-source workspace; same directory.)

## 3. Wrapper env the plist must set (already in the plist template)

```
OSTLER_PYTHON            spoken-source venv python3 (plist env)
PWG_CONVO_CMD            CM048 pwg-convo invocation (plist env)
```

And the wrapper reads these from the environment if the installer
exports / renders them (optional, all have safe defaults):

```
OSTLER_SOURCE_DIR        parent of spoken_source/ (render to
                         ${OSTLER_DIR}/services/spoken-source)
OSTLER_USER_DISPLAY_NAME -> install.sh $USER_NAME (so the operator's
                         own utterances render as "You")
OSTLER_CONTACTS          optional contacts.yaml (spoken: L3 map; see 5)
OSTLER_SPOKEN_SINCE_DAYS fresh-install clamp (default 30)
OSTLER_TRANSCRIPTS_DIR   RemoteCapture transcripts root override
                         (default ~/Documents/Ostler/Transcripts;
                         same chain CM042 AppConfiguration reads:
                         OSTLER_TRANSCRIPTS_DIR > CM042_TRANSCRIPT_DIR)
```

Recommend rendering `OSTLER_SOURCE_DIR` + `OSTLER_USER_DISPLAY_NAME`
into the wrapper at copy time (sed) OR adding them to the plist
`EnvironmentVariables`, matching whichever the email-bundle wiring
chose. `$USER_NAME` already exists in install.sh.

## 4. Transcripts-dir guard (never abort install)

- The wrapper exits 0 cleanly if `~/Documents/Ostler/Transcripts` does
  not exist (RemoteCapture never run / no recordings yet). RunAtLoad
  will not hard-fail the agent on a Mac that has never recorded.
- The reader also treats a missing transcripts directory as "no
  transcripts" internally (`read_transcripts` returns `[]`), so a
  race where the wrapper guard passes but the dir vanishes still exits
  0.
- Treat a non-zero bootstrap as a WARN, not a hard fail (mirror the
  email-bundle 3.14a `if ... else warn` wrapper). There is no FDA / no
  PermissionError path here: the transcripts live in the user-facing
  zone, so the only failure modes are "no transcripts" (exit 0) or a
  CM048 dispatch failure (logged, watermark untouched, retried next
  tick).
- Same bundle / clone / plaintext fallback chain as email-source for
  obtaining the vendor source on productised vs dev installs.

## 5. Fresh-install clamp + privacy map

- `--since-days` (default 30, override `OSTLER_SPOKEN_SINCE_DAYS`)
  bounds the first read window so a fresh install does not bundle
  every historic recording in one tick. The watermark
  (`~/.ostler/workspace/spoken_source_state.json`) then keeps
  subsequent ticks incremental: a session is only dispatched when its
  CM042 `call_id` has not been bundled before.
- Privacy: a session whose CM042 front matter marks it `L3` (the
  recorder's user-marked-private flag) rides through to
  `metadata['privacy_level']`, and CM048's writer short-circuits the
  gist arm (no Qdrant / Oxigraph). On top of that, an OPTIONAL operator
  map in the same `contacts.yaml` the email feed uses lets a capture
  surface or meeting type be pinned L3:
  ```
  spoken:
    sources:   { therapy_app: L3 }
    contexts:  { therapy: L3 }
  ```
  Only an explicit `L3` is honoured from the map (a benign L2 is left
  to CM048's classifier so a sensitive meeting can still escalate).
  Default is unset, leaving CM048's classifier inference (L2 baseline +
  sensitive escalation).

## 6. Uninstall

Add to the install.sh uninstall section (near the email-bundle bootout):

```
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.spoken-bundle" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.spoken-bundle.plist"
```

## 7. Doctor / progress copy

Add `spoken_bundle` to the LaunchAgent inventory line (alongside
"Doctor, export watcher, hub power, email-ingest, email-bundle,
imessage-bundle, wiki-recompile, ...") and a
`progress "Setting up spoken-bundle LaunchAgent ..."` step. No Rule 0.9
customer-string concerns beyond the progress label (English copy goes
through the same MSG_ catalogue path as the email-bundle strings).

## 8. Dependency ordering note

The spoken-bundle agent depends on CM042 (RemoteCapture) producing
transcripts and on CM048 (`pwg-convo`) being installed. CM048 is
already an install dependency of the email-bundle + imessage-bundle
agents, so PWG_CONVO_CMD is already resolved by the time this agent is
wired. CM042 is the RemoteCapture app the customer installs / launches
separately; the transcripts-dir guard (4) means the agent is harmless
and idempotent on a Mac where RemoteCapture has not yet produced any
transcript, so the agent can be bootstrapped at install time
regardless of CM042 state.
```
