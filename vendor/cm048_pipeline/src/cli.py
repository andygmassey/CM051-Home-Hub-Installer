"""pwg-convo CLI — entry point for CM048.

Commands:
  process TRANSCRIPT_FILE METADATA_FILE [--dry-run] [--priority P]
  status [CONVERSATION_ID]
  retry CONVERSATION_ID
  reprocess CONVERSATION_ID [--from-step STEP]
  list

Install via `python -m cm048.cli ...` from the CM048 root, or symlink
the installed package's entry point.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .processor import process
from .schemas import PIPELINE_STEP_ORDER, PipelineState, read_json
from .settings import ensure_directories, load_settings, settings_from_env_override


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pwg-convo")
    parser.add_argument("--settings", type=Path, default=None)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--json-logs", action="store_true",
                        help="Emit structured JSON log lines to stderr")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_process = sub.add_parser("process", help="Process a transcript through the pipeline")
    p_process.add_argument("transcript", type=Path)
    p_process.add_argument("metadata", type=Path)
    p_process.add_argument("--dry-run", action="store_true")
    p_process.add_argument("--priority", default="medium", choices=["high", "medium", "low", "deferred"])
    p_process.add_argument("--no-sinks", action="store_true")

    p_status = sub.add_parser("status", help="Show status of one or all conversations")
    p_status.add_argument("conversation_id", nargs="?")

    p_retry = sub.add_parser("retry", help="Retry a failed pipeline from last failed step")
    p_retry.add_argument("conversation_id")

    p_reproc = sub.add_parser("reprocess", help="Re-run from a specific step onward")
    p_reproc.add_argument("conversation_id")
    p_reproc.add_argument("--from-step", required=True)

    p_list = sub.add_parser("list", help="List all conversations in state dir")

    p_batch = sub.add_parser("batch", help="Process all fixtures in a directory")
    p_batch.add_argument("directory", type=Path)
    p_batch.add_argument("--dry-run", action="store_true")
    p_batch.add_argument("--no-sinks", action="store_true")
    p_batch.add_argument("--stop-on-error", action="store_true",
                         help="Stop the batch if any conversation fails")

    p_retry_all = sub.add_parser("retry-all", help="Retry all failed conversations")

    p_summary = sub.add_parser("summary", help="Overview of PWG conversation processing state")

    p_clear = sub.add_parser("clear-step",
                             help="Clear a step's output from all conversations (for re-processing)")
    p_clear.add_argument("step", help="Step prefix to clear (e.g. '05' clears 05_facts.json etc.)")
    p_clear.add_argument("--dry-run", action="store_true",
                         help="Show what would be cleared without deleting")

    p_cand = sub.add_parser(
        "candidates",
        help="Manage Foundry candidate facts (list, promote, unpromote)",
    )
    p_cand_sub = p_cand.add_subparsers(dest="cand_cmd", required=True)

    p_cand_list = p_cand_sub.add_parser(
        "list", help="List current candidate facts in Oxigraph",
    )
    p_cand_list.add_argument(
        "--conversation", help="Filter to one conversation_id",
    )
    p_cand_list.add_argument("--limit", type=int, default=20)

    p_cand_promote = p_cand_sub.add_parser(
        "promote",
        help="Manually promote ALL candidates in one conversation",
    )
    p_cand_promote.add_argument("conversation_id")

    p_cand_unpromote = p_cand_sub.add_parser(
        "unpromote",
        help="Revert a manual promotion (flip back to candidate)",
    )
    p_cand_unpromote.add_argument("conversation_id")

    args = parser.parse_args(argv)

    settings = settings_from_env_override(load_settings(args.settings))

    from .log import configure_logging
    configure_logging(
        verbose=args.verbose,
        user_id=settings.user_id,
        json_mode=args.json_logs,
    )
    ensure_directories(settings)

    if args.cmd == "process":
        return cmd_process(args, settings)
    if args.cmd == "status":
        return cmd_status(args, settings)
    if args.cmd == "retry":
        return cmd_retry(args, settings)
    if args.cmd == "reprocess":
        return cmd_reprocess(args, settings)
    if args.cmd == "list":
        return cmd_list(args, settings)
    if args.cmd == "batch":
        return cmd_batch(args, settings)
    if args.cmd == "retry-all":
        return cmd_retry_all(args, settings)
    if args.cmd == "summary":
        return cmd_summary(args, settings)
    if args.cmd == "clear-step":
        return cmd_clear_step(args, settings)
    if args.cmd == "candidates":
        return cmd_candidates(args, settings)
    return 1


def cmd_process(args, settings) -> int:
    transcript = args.transcript.read_text()
    metadata = json.loads(args.metadata.read_text())
    conv_id = metadata.get("conversation_id")
    if not conv_id:
        print("metadata.json must include a conversation_id", file=sys.stderr)
        return 2

    state = process(
        conv_id,
        transcript,
        metadata,
        settings,
        dry_run=args.dry_run,
        ingest_sinks=not args.no_sinks,
    )
    print(json.dumps(state.to_dict(), indent=2))
    return 0 if state.failed_step is None else 1


def cmd_status(args, settings) -> int:
    if args.conversation_id:
        path = settings.processing_state_dir / args.conversation_id / "state.json"
        if not path.exists():
            print(f"No state for {args.conversation_id}")
            return 1
        print(json.dumps(read_json(path), indent=2))
        return 0
    # All
    for sub in sorted(settings.processing_state_dir.glob("*/state.json")):
        data = read_json(sub)
        print(
            f"{data['conversation_id']:50s} step={data['current_step']:25s} "
            f"failed={data.get('failed_step') or '-'}"
        )
    return 0


def cmd_retry(args, settings) -> int:
    path = settings.processing_state_dir / args.conversation_id / "state.json"
    if not path.exists():
        print(f"No state for {args.conversation_id}", file=sys.stderr)
        return 2
    state_dict = read_json(path)
    failed = state_dict.get("failed_step")
    if not failed:
        print(f"{args.conversation_id} is not in a failed state; nothing to retry.")
        return 0

    transcript_path = settings.processing_state_dir / args.conversation_id / "00_raw_transcript.md"
    metadata_path = settings.processing_state_dir / args.conversation_id / "00_metadata.json"
    transcript = transcript_path.read_text()
    metadata = json.loads(metadata_path.read_text())

    state = process(
        args.conversation_id,
        transcript,
        metadata,
        settings,
        resume_from_step=failed,
    )
    print(json.dumps(state.to_dict(), indent=2))
    return 0 if state.failed_step is None else 1


def cmd_reprocess(args, settings) -> int:
    # Archive existing outputs from --from-step onward, then run
    state_dir = settings.processing_state_dir / args.conversation_id
    if not state_dir.exists():
        print(f"No state dir for {args.conversation_id}", file=sys.stderr)
        return 2

    if args.from_step not in PIPELINE_STEP_ORDER:
        print(f"Unknown step: {args.from_step}", file=sys.stderr)
        return 2
    from_idx = PIPELINE_STEP_ORDER.index(args.from_step)
    downstream_steps = set(PIPELINE_STEP_ORDER[from_idx:])
    downstream_prefixes = tuple(s.split("_", 1)[0] for s in downstream_steps)

    # Archive outputs for the from-step and every downstream step —
    # otherwise stale files linger and sinks re-ingest old data.
    from datetime import datetime
    stamp = datetime.utcnow().strftime("%Y%m%dT%H%M%S")
    for f in state_dir.iterdir():
        if ".archive" in f.name:
            continue
        if not f.name.startswith(downstream_prefixes):
            continue
        if f.is_dir():
            f.rename(state_dir / (f.name + f".{stamp}.archive"))
        else:
            f.rename(f.with_suffix(f.suffix + f".{stamp}.archive"))

    # Clear downstream steps from state.json so _should_run lets them re-run.
    state_path = state_dir / "state.json"
    if state_path.exists():
        state_data = json.loads(state_path.read_text())
        state_data["completed_steps"] = [
            s for s in state_data.get("completed_steps", [])
            if s not in downstream_steps
        ]
        if (state_data.get("failed_step") or "") in downstream_steps:
            state_data["failed_step"] = None
            state_data["failure_reason"] = None
        state_path.write_text(json.dumps(state_data, indent=2))

    transcript_path = state_dir / "00_raw_transcript.md"
    metadata_path = state_dir / "00_metadata.json"
    transcript = transcript_path.read_text()
    metadata = json.loads(metadata_path.read_text())

    state = process(
        args.conversation_id,
        transcript,
        metadata,
        settings,
        resume_from_step=args.from_step,
    )
    print(json.dumps(state.to_dict(), indent=2))

    if state.failed_step is not None:
        return 1
    # Guard against silent-success: if `from_step` didn't end up in
    # completed_steps, the archive/state-clear block above failed to unblock
    # the processor and nothing actually ran.
    if args.from_step not in state.completed_steps:
        print(
            f"reprocess: {args.from_step} did not run — "
            f"completed_steps={state.completed_steps}",
            file=sys.stderr,
        )
        return 1
    return 0


def cmd_list(args, settings) -> int:
    for sub in sorted(settings.processing_state_dir.iterdir()):
        if sub.is_dir() and (sub / "state.json").exists():
            data = read_json(sub / "state.json")
            failed = data.get("failed_step") or "-"
            steps = len(data.get("completed_steps", []))
            print(
                f"{sub.name:50s} step={data['current_step']:20s} "
                f"completed={steps} failed={failed}"
            )
    return 0


def cmd_batch(args, settings) -> int:
    """Process all .md + .metadata.json pairs in a directory."""
    directory = args.directory
    if not directory.is_dir():
        print(f"Not a directory: {directory}", file=sys.stderr)
        return 2

    # Find all fixture pairs: *.md with matching *.metadata.json
    pairs = []
    for md_file in sorted(directory.glob("*.md")):
        meta_file = md_file.with_suffix("").with_suffix(".metadata.json")
        if meta_file.exists():
            pairs.append((md_file, meta_file))

    if not pairs:
        print(f"No fixture pairs found in {directory}")
        return 0

    print(f"Found {len(pairs)} conversations to process")
    succeeded = 0
    failed = 0

    for i, (md_file, meta_file) in enumerate(pairs, 1):
        metadata = json.loads(meta_file.read_text())
        conv_id = metadata.get("conversation_id", md_file.stem)
        print(f"\n[{i}/{len(pairs)}] {conv_id}")

        try:
            transcript = md_file.read_text()
            state = process(
                conv_id,
                transcript,
                metadata,
                settings,
                dry_run=args.dry_run,
                ingest_sinks=not args.no_sinks,
            )
            if state.failed_step:
                print(f"  FAILED at {state.failed_step}")
                failed += 1
                if args.stop_on_error:
                    print("Stopping batch (--stop-on-error)")
                    break
            else:
                steps = len(state.completed_steps)
                print(f"  OK ({steps} steps)")
                succeeded += 1
        except Exception as exc:
            print(f"  ERROR: {exc}")
            failed += 1
            if args.stop_on_error:
                print("Stopping batch (--stop-on-error)")
                break

    print(f"\nBatch complete: {succeeded} succeeded, {failed} failed, {len(pairs)} total")
    return 0 if failed == 0 else 1


def cmd_retry_all(args, settings) -> int:
    """Retry all conversations in a failed state."""
    retried = 0
    still_failed = 0

    if not settings.processing_state_dir.exists():
        print("No processing state directory found.")
        return 0

    for sub in sorted(settings.processing_state_dir.iterdir()):
        if not sub.is_dir():
            continue
        state_path = sub / "state.json"
        if not state_path.exists():
            continue
        state_dict = read_json(state_path)
        failed_step = state_dict.get("failed_step")
        if not failed_step:
            continue

        conv_id = state_dict["conversation_id"]
        print(f"Retrying {conv_id} from {failed_step}...")

        transcript_path = sub / "00_raw_transcript.md"
        metadata_path = sub / "00_metadata.json"
        if not transcript_path.exists() or not metadata_path.exists():
            print(f"  SKIP — missing raw transcript or metadata")
            continue

        transcript = transcript_path.read_text()
        metadata = json.loads(metadata_path.read_text())

        try:
            state = process(
                conv_id,
                transcript,
                metadata,
                settings,
                resume_from_step=failed_step,
            )
            if state.failed_step:
                print(f"  STILL FAILED at {state.failed_step}")
                still_failed += 1
            else:
                print(f"  OK")
                retried += 1
        except Exception as exc:
            print(f"  ERROR: {exc}")
            still_failed += 1

    print(f"\nRetry-all complete: {retried} recovered, {still_failed} still failed")
    return 0 if still_failed == 0 else 1


def cmd_summary(args, settings) -> int:
    """Print a high-level overview of the PWG conversation processing state."""
    import sqlite3

    total = 0
    complete = 0
    failed = 0
    total_facts = 0
    total_signals = 0
    total_linked = 0
    classifications = {}

    if settings.processing_state_dir.exists():
        for sub in sorted(settings.processing_state_dir.iterdir()):
            if not sub.is_dir():
                continue
            state_path = sub / "state.json"
            if not state_path.exists():
                continue
            total += 1
            data = read_json(state_path)
            if data.get("failed_step"):
                failed += 1
            elif "07_sinks_written" in data.get("completed_steps", []):
                complete += 1

            # Count classifications
            class_path = sub / "01_classification.json"
            if class_path.exists():
                c = read_json(class_path)
                slug = c.get("suggested_type_slug", "unknown")
                classifications[slug] = classifications.get(slug, 0) + 1

            # Count facts
            facts_path = sub / "05_facts.json"
            if facts_path.exists():
                try:
                    facts = read_json(facts_path)
                    if isinstance(facts, list):
                        total_facts += len(facts)
                except Exception:
                    pass

            # Count relationship signals
            sig_dir = sub / "03_relationship_signals"
            if sig_dir.exists():
                total_signals += len(list(sig_dir.glob("*.json")))

            # Count linked conversations
            links_path = sub / "08_links.json"
            if links_path.exists():
                try:
                    links = read_json(links_path)
                    if links.get("related_ids"):
                        total_linked += 1
                except Exception:
                    pass

    # Conversation MD files
    md_count = 0
    if settings.output_conversations_dir.exists():
        md_count = len(list(settings.output_conversations_dir.glob("*.md")))

    # Coach observations
    coach_count = 0
    if settings.coach_db_path.exists():
        try:
            conn = sqlite3.connect(str(settings.coach_db_path))
            coach_count = conn.execute(
                "SELECT count(*) FROM observations"
            ).fetchone()[0]
            conn.close()
        except Exception:
            pass

    print("=== PWG Conversation Processing Summary ===")
    print()
    print(f"Conversations processed:  {total}")
    print(f"  Complete (sinks written): {complete}")
    print(f"  Failed:                   {failed}")
    print(f"  In progress:              {total - complete - failed}")
    print()
    print(f"Conversation MD files:    {md_count}")
    print(f"Facts extracted:          {total_facts}" +
          (f"  ({total_facts/complete:.1f}/conv)" if complete else ""))
    print(f"Relationship signals:     {total_signals}" +
          (f"  ({total_signals/complete:.1f}/conv)" if complete else ""))
    print(f"Coach observations:       {coach_count}")
    print(f"Cross-linked:             {total_linked}")
    print()
    if classifications:
        print("Classification breakdown:")
        for slug, count in sorted(classifications.items()):
            print(f"  {slug}: {count}")
    print()
    print(f"State dir:   {settings.processing_state_dir}")
    print(f"Output dir:  {settings.output_conversations_dir}")
    print(f"Coach DB:    {settings.coach_db_path}")
    return 0


def cmd_clear_step(args, settings) -> int:
    """Clear a specific step's output files from all conversations.

    This enables targeted re-processing: clear step 05 (facts), then
    run batch again — only the cleared step will re-run since the
    processor checks for existing output files.

    Also removes the step from state.json's completed_steps so the
    processor knows to re-run it.
    """
    from datetime import datetime

    step_prefix = args.step
    stamp = datetime.utcnow().strftime("%Y%m%dT%H%M%S")
    cleared = 0
    conversations = 0

    if not settings.processing_state_dir.exists():
        print("No processing state directory found.")
        return 0

    for sub in sorted(settings.processing_state_dir.iterdir()):
        if not sub.is_dir():
            continue
        state_path = sub / "state.json"
        if not state_path.exists():
            continue

        # Find files matching the step prefix
        matching = []
        for f in sub.iterdir():
            if f.name.startswith(step_prefix) and ".archive" not in f.name:
                matching.append(f)
        # Also check for directory-style outputs (e.g. 03_relationship_signals/)
        for d in sub.iterdir():
            if d.is_dir() and d.name.startswith(step_prefix):
                matching.append(d)

        if not matching:
            continue

        conversations += 1
        for f in matching:
            if args.dry_run:
                print(f"  would archive: {f.name}")
            else:
                if f.is_dir():
                    archive_name = f.name + f".{stamp}.archive"
                    f.rename(sub / archive_name)
                else:
                    f.rename(f.with_suffix(f.suffix + f".{stamp}.archive"))
            cleared += 1

        # Update state.json: remove matching steps from completed_steps
        if not args.dry_run:
            state_data = read_json(state_path)
            orig_steps = state_data.get("completed_steps", [])
            state_data["completed_steps"] = [
                s for s in orig_steps
                if not s.startswith(step_prefix)
            ]
            # Also remove downstream steps (sinks + linking depend on earlier steps)
            try:
                cleared_idx = next(
                    i for i, s in enumerate(PIPELINE_STEP_ORDER)
                    if s.startswith(step_prefix)
                )
                # Remove all steps at or after the cleared step
                downstream = set(PIPELINE_STEP_ORDER[cleared_idx:])
                state_data["completed_steps"] = [
                    s for s in state_data["completed_steps"]
                    if s not in downstream
                ]
            except StopIteration:
                pass

            # Clear failed_step if it matches
            if (state_data.get("failed_step") or "").startswith(step_prefix):
                state_data["failed_step"] = None
                state_data["failed_reason"] = None

            json.dump(state_data, open(state_path, "w"), indent=2)

        print(f"  {sub.name}: {len(matching)} files")

    action = "Would clear" if args.dry_run else "Cleared"
    print(f"\n{action} {cleared} files across {conversations} conversations")
    return 0


def cmd_candidates(args, settings) -> int:
    """Dispatcher for `pwg-convo candidates <list|promote|unpromote>`.

    The auto-promotion path runs inside the pipeline (step 08_linked).
    This CLI is for operator override: listing what's currently in
    candidate state, manually promoting a known-good conversation's
    facts, or reverting a wrong promotion.
    """
    from .candidates import list_candidates, promote_conversation, set_candidate

    if args.cand_cmd == "list":
        rows = list_candidates(
            settings,
            conversation_id=args.conversation,
            limit=args.limit,
        )
        if not rows:
            print("(no candidate facts)")
            return 0
        print(f"{len(rows)} candidate fact(s):")
        for r in rows:
            subj = r["subject"].rsplit("/", 1)[-1] or r["subject"]
            print(f"  [{r['conversation_id']}] {subj}: {r['text']}")
        return 0

    if args.cand_cmd == "promote":
        count = promote_conversation(args.conversation_id, settings)
        print(f"Promoted {count} candidate(s) in {args.conversation_id}")
        return 0

    if args.cand_cmd == "unpromote":
        # Unpromote lists the conversation's facts regardless of current
        # state, then flips them back to candidate=true. Intended as
        # "oops, that promote was wrong" rather than a routine operation.
        from .candidates import _sparql_select
        graph_uri = f"urn:pwg:user/{settings.user_id}"  # noqa: F841
        sparql = f"""
PREFIX pwg: <urn:pwg:>
SELECT ?fact WHERE {{
  ?fact a <urn:pwg:Fact> ;
        <urn:pwg:fromConversation> <urn:pwg:conversation/{args.conversation_id}> .
}}
"""
        rows = _sparql_select(sparql, settings)
        for r in rows:
            set_candidate(r.get("fact", ""), True, settings)
        print(f"Unpromoted {len(rows)} fact(s) in {args.conversation_id}")
        return 0

    print(f"Unknown candidates subcommand: {args.cand_cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
