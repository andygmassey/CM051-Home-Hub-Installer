# Apple Music scheduled refresh: how the TCC grant is attributed

CM051 v1.0.108. Every claim is labelled MEASURED (with the command or
record) or INFERRED (reasoned, not observed). The one claim the design
depends on is INFERRED, and has a console-walk probe that settles it.

## The problem

"Media & Apple Music" (`kTCCServiceMediaLibrary`) is granted per client, and
the client is the *responsible process*, not the process that calls the
framework. Apple Music was read at install only, because the recurring FDA
re-run is a launchd job and cannot hold that grant.

## What was MEASURED

1. Over ssh, with no grant, the helper prints `status unavailable`,
   `NSCocoaErrorDomain 4097`, exit 0, and tccd logs `Policy disallows prompt`
   for the **sshd-keygen-wrapper** responsible process. MEASURED on Mini16,
   macOS 26.5.2 (recorded in `console_only_probes.tsv` and
   `tests/test_apple_music_library_reader.py`, `DENIED_PAYLOAD`).
   What this shows: the client tccd charged was the session's ancestor, not
   the helper binary that made the call. Attribution follows the responsible
   process chain.
2. Opening `ITLibrary(apiVersion:)` is itself the permission request: tccd logs
   `TCCAccessRequest ... service=kTCCServiceMediaLibrary, preflight=no`.
   MEASURED on Mini16 (`PermissionsPrewarmer.swift`, `requestMusicLibraryAccess`).
3. The helper embeds its own bundle identifier,
   `ai.ostler.installer.musiclibrary` (`gui/ostler-music-library/Info.plist`),
   which differs from the app's `ai.ostler.installer`
   (`gui/project.yml`). MEASURED by reading both files.
4. The new Swift mode, driven against a fake helper (swiftc, this Mac, no
   Music library touched): not armed exits 0 without running the helper;
   armed runs it and writes `helper_out.json` mode 0600 atomically; a missing
   helper exits 0 with `could not look`. MEASURED, 2026-10-15.

## What is INFERRED (and not yet observed anywhere)

A. **A bare helper run directly by launchd would hold no grant.** The customer
   clicked Allow for the installer app (the prewarm runs inside the app). A
   launchd job's responsible process is its own program, so a job whose
   program is `ostler-music-library` is its own TCC client
   (`ai.ostler.installer.musiclibrary` or its path), which has no record.
   This is why the first obvious design (agent runs the helper) was rejected.

B. **A launchd job whose program is the installer app, running the helper as
   its child, is attributed to the installer app.** It is the same process
   ancestry as `install.sh` running the helper under the app, and the app's
   own identity (`ai.ostler.installer`) is the one the customer granted. The
   app is the launchd job's own program, so it is the responsible process;
   the helper is a child that does not disclaim responsibility.
   *Unverified assumptions inside B:* (i) launching the app's
   `Contents/MacOS/OstlerInstaller` directly (not through LaunchServices) is
   attributed to its bundle identity rather than its path; (ii) the install-time
   helper read is itself attributed to the app. (ii) is what the shipped
   install already relies on; neither has been observed with the grant present.

C. **Background-safe.** macOS has no public status call for this service, so
   "never prompt" is enforced by design rather than by asking: the install
   writes `state/music_refresh/armed` only after its own native read
   returned tracks (which can only happen if the customer clicked Allow), and
   the app does nothing unless `armed` exists. Three refusals in a row
   disarm it. INFERRED residue: if a customer later resets the grant with
   `tccutil`, the next scheduled run could raise the dialog once, in their
   own GUI session. It cannot raise one before the first grant.

## How it is designed to be right even if B is wrong

If B fails, the failure is visible and harmless: the app's read is refused,
`apply` logs `could not look (unavailable NSCocoaErrorDomain:4097)`, the
snapshot is untouched, and after three refusals the refresh disarms. Nothing
is written to the Hub, nothing aborts, no dialog is shown (the refusal is
the no-grant answer, not a prompt, in an armed state). The probe below turns
that into a named FAIL instead of a silent stale library.

## The check that settles it (console walk, not ssh)

`scripts/box_walk_probes/probes/apple_music_refresh_runs_under_the_grant.sh`,
registered in `console_only_probes.tsv` (surface `tcc`). On a box where the
customer clicked Allow at install, RunAtLoad makes the agent read once at
bootstrap, so `~/.ostler/state/music_refresh/state.json` must show
`last_status "ok"` within minutes. To read the attribution directly while the
console is attended:

    log show --last 10m --predicate 'subsystem == "com.apple.TCC"' | grep MediaLibrary

and confirm the `responsible` client is `ai.ostler.installer`, not
`ai.ostler.installer.musiclibrary`. Until that is run, status is **INFERRED**.
