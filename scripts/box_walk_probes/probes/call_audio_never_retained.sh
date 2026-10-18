#!/usr/bin/env bash
# call_audio_never_retained -- after a real capture, is any call audio left on
# the box? (v1.0.109, RemoteCapture 0.1.7 = CM042 #32, Andy's core privacy rule:
# call audio is transcribed on this Mac and deleted straight away; it is never
# kept and never sent anywhere.)
#
# Counts audio files (.wav .m4a .caf .aif .aiff .mp3) in the three places
# RemoteCapture has ever written audio:
#   1. <DARWIN_USER_TEMP_DIR>RemoteCapture/<session>/  the live capture dir
#      (AudioSessionManager.swift: temporaryDirectory/RemoteCapture/<id>/
#      system_audio.wav + microphone.wav)
#   2. ~/Documents/Ostler/Transcripts/                 where builds <= 0.1.6
#      moved retained audio next to the transcript
#   3. ~/Documents/CM042-Transcripts/                  the legacy transcripts dir
# and, as the control that a capture actually happened, the transcripts
# RemoteCapture wrote (<dir>/YYYY/MM/*-call.md, TranscriptWriter.swift).
#
# Verdicts, decided by judge() and nothing else:
#   any audio file                     -> FAIL (audio was retained)
#   a root unreadable                  -> CANNOT-RUN (could not look; never "0")
#   0 transcripts                      -> CANNOT-RUN: no capture was made, so 0
#                                         audio proves nothing. A capture needs
#                                         the Screen Recording + Microphone TCC
#                                         grants, which only a human at the
#                                         console can give (console_only_probes.tsv).
#   >=1 transcript and 0 audio         -> PASS
#
# Only counts leave the box, never a file name (a transcript name carries the
# call source and time).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="call_audio_never_retained"
PROBE_QUESTION="after one real RemoteCapture capture, are there 0 audio files left in the capture temp dir and the transcripts dirs, with at least one transcript proving a capture happened?"

# The box-side reader. Prints key=value counts. RC_TMP_ROOT / RC_HOME override
# the roots so the self-test drives this exact text against synthetic trees.
read -r -d '' _GATHER <<'GATHER'
tmp="${RC_TMP_ROOT:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)RemoteCapture}"
home="${RC_HOME:-$HOME}"
audio=0; transcripts=0; unreadable=0; roots=0
for r in "$tmp" "$home/Documents/Ostler/Transcripts" "$home/Documents/CM042-Transcripts"; do
  roots=$((roots+1))
  [ -e "$r" ] || continue
  if ! ls "$r" >/dev/null 2>&1; then unreadable=$((unreadable+1)); continue; fi
  errf="$(mktemp)"
  n="$(find "$r" -type f \( -iname '*.wav' -o -iname '*.m4a' -o -iname '*.caf' -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.mp3' \) 2>"$errf" | wc -l | tr -d ' ')"
  [ -s "$errf" ] && unreadable=$((unreadable+1))
  audio=$((audio+n))
  if [ "$r" != "$tmp" ]; then
    m="$(find "$r" -type f -name '*-call.md' 2>>"$errf" | wc -l | tr -d ' ')"
    transcripts=$((transcripts+m))
  fi
  rm -f "$errf"
done
echo "roots=$roots audio=$audio transcripts=$transcripts unreadable=$unreadable"
GATHER

judge() {
    # judge "<gatherer output line>"
    local line="$1" roots audio transcripts unreadable
    case "${line}" in
        roots=*" audio="*" transcripts="*" unreadable="*) ;;
        *) probe_cannot_run "the box-side reader returned no counts (got: '${line}')" ;;
    esac
    roots="${line#roots=}"; roots="${roots%% *}"
    audio="${line#* audio=}"; audio="${audio%% *}"
    transcripts="${line#* transcripts=}"; transcripts="${transcripts%% *}"
    unreadable="${line#* unreadable=}"; unreadable="${unreadable%% *}"
    probe_examined "${roots}" "audio roots (capture temp dir, Ostler/Transcripts, CM042-Transcripts); ${audio} audio files, ${transcripts} transcripts"
    [ "${audio}" -eq 0 ] || probe_fail "${audio} call audio file(s) left on disk; audio must be deleted straight after transcription"
    [ "${unreadable}" -eq 0 ] || probe_cannot_run "${unreadable} root(s) could not be read, so 0 audio files is not a measurement"
    [ "${transcripts}" -ge 1 ] || probe_cannot_run "TCC: no RemoteCapture transcript on the box, so no capture was made and 0 audio proves nothing. A capture needs the Screen Recording and Microphone grants at the console: make one short capture, then re-run"
    probe_pass "0 audio files after ${transcripts} transcript(s)"
}

self_test() {
    # Drives _GATHER + judge() against synthetic trees. Each case runs in a
    # subshell because judge() exits. A case that does not land on its
    # expected verdict breaks the self-test.
    local t got bad=0
    t="$(mktemp -d)"
    _case() {  # _case <name> <expected VERDICT word>
        got="$(RC_TMP_ROOT="${t}/$1/tmp/RemoteCapture" RC_HOME="${t}/$1/home" /bin/bash -c "${_GATHER}")"
        got="$( (judge "${got}") | sed -n 's/^VERDICT: \([A-Z-]*\).*/\1/p')"
        [ "${got}" = "$2" ] || { echo "  self-test case $1: expected $2, got '${got}'"; bad=1; }
    }
    mkdir -p "${t}/live/tmp/RemoteCapture/S1" "${t}/live/home/Documents/Ostler/Transcripts/2026/10"
    : > "${t}/live/tmp/RemoteCapture/S1/system_audio.wav"
    : > "${t}/live/home/Documents/Ostler/Transcripts/2026/10/2026-10-19-1200-zoom-call.md"
    _case live FAIL
    mkdir -p "${t}/kept/home/Documents/Ostler/Transcripts/2026/10"
    : > "${t}/kept/home/Documents/Ostler/Transcripts/2026/10/2026-10-19-1200-mic.wav"
    : > "${t}/kept/home/Documents/Ostler/Transcripts/2026/10/2026-10-19-1200-zoom-call.md"
    _case kept FAIL
    mkdir -p "${t}/nocap/home/Documents/Ostler/Transcripts"
    _case nocap CANNOT-RUN
    mkdir -p "${t}/clean/tmp/RemoteCapture" "${t}/clean/home/Documents/Ostler/Transcripts/2026/10"
    : > "${t}/clean/home/Documents/Ostler/Transcripts/2026/10/2026-10-19-1200-zoom-call.md"
    _case clean PASS
    rm -rf "${t}"
    probe_examined 4 "synthetic trees (live temp audio, retained audio, no capture, clean)"
    [ "${bad}" -eq 0 ] && probe_fail "negative control behaved: temp audio and retained audio each FAIL, no capture is CANNOT-RUN, and only the clean tree passes"
    probe_pass "SELF-TEST BROKEN: the judge did not land every synthetic tree on its expected verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was counted"
    local out
    out="$(box_run "printf %s '$(printf %s "${_GATHER}" | base64 | tr -d '\n')' | base64 -d | /bin/bash" 2>/dev/null | tail -1)"
    judge "${out}"
}

probe_main "$@"
