#!/usr/bin/env bash
# scripts/box_walk_probes/lib/assistant_asked.sh
# ============================================================================
# THE OPPORTUNITY SIGNAL FOR oa_daemon_chat (#1634).
#
# ONE FUNCTION, TWO CALLERS, SO THE CONTRACT CANNOT DRIFT IN SILENCE:
#
#   run_box_walk.sh                        reads the real probe's real output
#   tests/test_usage_journal_producer_gate.sh
#                                          drives it over synthesised lines,
#                                          including ones it MUST refuse
#
# WHY IT EXISTS
# -------------
# usage_journal_producers matches oa_daemon_chat on `purpose=answering`, which
# the daemon writes when somebody sends it a message. A box that has ingested
# and compiled but that NOBODY HAS TALKED TO produces exactly the reading a
# broken daemon produces: zero records. The gate used to report the second with
# no way to see the first.
#
# The signal that tells them apart already runs in the same walk and is
# registered in the same manifest: assistant_answers_grounded asks the daemon
# real questions over /ws/chat and counts them. So nothing new is measured
# here; this reads what that probe already printed and hands it to the gate as
# `--no-opportunity oa_daemon_chat`.
#
# THE CONTRACT, AND WHY IT FAILS SAFE
# -----------------------------------
# lib/probe.sh's probe_examined() prints `EXAMINED: <n> <text>`, and
# probes/assistant_answers_grounded.sh calls it with the text
# "questions asked over /ws/chat (...)". That phrase is the interface.
#
# Reword it and this function returns NOTHING, which the probe treats as
# UNKNOWN -- and unknown excuses nothing, so the producer keeps its FAIL. The
# safe direction is the loud one: a broken signal can never turn a red off,
# only leave it on. tests/test_usage_journal_producer_gate.sh arm 16 asserts
# the phrase is still in the grounded probe, so a reword is caught in the PR
# that does it rather than by a walk that quietly stops narrowing.
#
# macOS bash 3.2.57 + BSD sed. No GNU-only constructs.
# ============================================================================

# assistant_asked_from_output <probe output on stdin>
#
# Prints the number of questions assistant_answers_grounded asked, or nothing
# at all when the output does not carry that denominator. Never prints a
# fabricated 0: "it asked none" and "I could not tell" must not print the same,
# because the first excuses the producer and the second must not.
#
# THE FIRST MATCH WINS (`head -1`), stated here rather than buried: probe
# output carries exactly one EXAMINED line per verdict by construction
# (lib/probe.sh sets PROBE_EXAMINED_SET), and taking the first of a
# single-element set is a guard against a future second line rather than a
# narrowing of a real one.
assistant_asked_from_output() {
    sed -n 's|^EXAMINED: \([0-9][0-9]*\) questions asked over /ws/chat.*|\1|p' \
        | head -1
}
