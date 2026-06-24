#!/usr/bin/env python3
"""Extract every protocol-event handler from the Swift GUI.

The Swift consumer side of the install.sh -> GUI contract lives in
two files:

  gui/OstlerInstaller/ProgressProtocol.swift
      Canonical event-kind dispatch (the `switch event { ... }`
      inside ProgressDecoder.decode).  Every case arm here is a
      registered handler for a top-level event kind.

  gui/OstlerInstaller/Steps/StepCatalog.swift
      The canonicalOrder array of stable STEP_BEGIN / PHASE ids the
      sidebar pre-renders before the first marker arrives.  Out-of-band
      ids appear dynamically, so the array is an authoritative dead-
      handler list for ticked sidebar entries -- if an id is here but
      install.sh never emits it, the sidebar tick is unreachable.

Architectural note (surfaced during scoping):
  The brief assumed the GUI had per-prompt-id handlers (e.g.
  `renderPU8Allowlist`).  It does not.  InstallerCoordinator's
  `.prompt` case arm is generic -- the sheet renderer consumes the
  PendingPrompt struct uniformly regardless of id.  Therefore the
  PROMPT handler is recorded once with `id_or_name: "*"` (wildcard) and
  the per-id contract for prompts is enforced separately via the
  PromptKind enum (text/secret/yesno/choice) which IS a concrete
  Swift-side constraint.

Skips:
  Swift `//` line comments and /* ... */ block comments so a
  documented-but-commented-out case arm is not counted.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Events the brief flags as "soft" -- emission with no GUI case arm is
# acceptable (logged as a NOTE, not a fail).  Documented in the
# progress_emitter.sh header block.
# - MAIL_ACCOUNTS_FOUND: CX-81 B2 marker, install.sh telemetry only.
# - STEP: CX-81 B8 permissions-briefing marker; install.sh emits one
#   STEP event before the customer-facing TCC briefing block (NOT a
#   STEP_BEGIN sidebar advance). GUI falls through to .unknown; the
#   briefing text surfaces via subsequent echo lines on the log pane.
# - CX106_QDRANT_BEFORE / CX106_QDRANT_AFTER: CX-106 initial-hydration
#   diagnostic count markers ("count=N" of Qdrant collections before/after
#   the synchronous hydrate). Log-pane telemetry only, not a sidebar row;
#   the GUI intentionally falls through to .unknown.
# - IMESSAGE_TCC_DENIED: CX-278 iMessage-TCC posture marker
#   ("status=denied" + remediation hint). install.sh already opens the
#   Privacy pane and surfaces a customer-facing info() line on the log
#   pane; the emit is telemetry, not a sidebar row, so the GUI falls
#   through to .unknown. (Surfaced once CX106_QDRANT was resolved -- it
#   was masked behind that failure on origin/main.)
# - AI_CONV_DRAIN: BUG-025 AI-conversations producer-drain diagnostic
#   marker ("discovered=N written=M" counts of episodic artefacts). Same
#   posture as the CX106_QDRANT markers -- log-pane telemetry only, no
#   conversation content crosses the boundary, the GUI falls through to
#   .unknown. The customer-facing sidebar row is the ai_conversations_drain
#   STEP_BEGIN, not this emit.
SOFT_UNKNOWN_OK: set[str] = {
    "MAIL_ACCOUNTS_FOUND",
    "STEP",
    "CX106_QDRANT_BEFORE",
    "CX106_QDRANT_AFTER",
    "IMESSAGE_TCC_DENIED",
    "AI_CONV_DRAIN",
}


def _strip_swift_comments(source: str) -> str:
    """Remove // line comments and /* ... */ block comments.

    Naive (does not respect strings) but adequate for the two files we
    parse -- neither contains a `//` or `/*` inside a string literal
    that would confuse this stripper.
    """
    # Block comments first so /* // */ stays correct.
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    # Line comments: from `//` to end of line, but only when not inside
    # a string.  The protocol files do not have `//` inside strings, so
    # a naive strip is fine here.
    source = re.sub(r"//[^\n]*", "", source)
    return source


def _extract_decoder_cases(src: str, rel: str) -> list[dict]:
    """Pull `case "EVENT":` arms out of ProgressDecoder.decode.

    Returns one handler entry per arm.  We anchor on the leading
    `switch event {` to avoid matching `case` in any other switch in
    the file.
    """
    # Anchor on the leading `switch event {`, then capture the body by
    # balancing braces from the opening `{` to its matching close. A naive
    # `(.*?)^\s*\}\s*$` regex stops at the FIRST standalone `}` line, which
    # is the nested `}` closing the `if ... {` block inside the DONE arm --
    # so it silently dropped RECOVERY_KEY and every other case after DONE.
    # Brace-balancing (skipping `}` inside string literals) captures the
    # whole switch regardless of nested blocks.
    open_pat = re.compile(r"switch\s+event\s*\{")
    om = open_pat.search(src)
    if not om:
        return []
    case_offset = om.end()  # index just past the opening brace
    depth = 1
    i = case_offset
    in_str = False
    while i < len(src) and depth > 0:
        ch = src[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = src[case_offset:i]
    case_pat = re.compile(r'case\s+"([A-Z][A-Z0-9_]+)"\s*:')
    handlers: list[dict] = []
    # Compute line numbers by counting newlines up to the match start.
    for case_m in case_pat.finditer(body):
        event_kind = case_m.group(1)
        abs_offset = case_offset + case_m.start()
        line_no = src.count("\n", 0, abs_offset) + 1
        handlers.append({
            "kind": event_kind,
            "id_or_name": None,
            "file": rel,
            "line": line_no,
            "handler_symbol": f"ProgressDecoder.decode/case \"{event_kind}\"",
        })
    return handlers


def _extract_prompt_kinds(src: str, rel: str) -> list[str]:
    """Pull the protocol-wire values of PromptKind from its enum
    declaration.

    The Swift declaration carries two forms:
        enum PromptKind: String, Equatable {
            case text, secret, yesno, choice
            case acknowledge
            case folder
            case textWithCancel = "text_with_cancel"
        }

    For a case with an explicit raw value (`= "snake_case"`), the
    raw value IS the wire value -- install.sh emits the snake_case
    form across the FIFO, and the Swift `PromptKind(rawValue:)`
    initialiser deserialises it back. The contract test's job is
    to confirm install.sh's `kind=` arg can deserialise; that
    means the wire value, not the Swift case name.

    For a case WITHOUT a raw value, Swift's default raw value is
    the case name itself, so the wire value equals the case name.

    The pre-2026-05-22 extractor scraped only case names, which
    blew up the contract test the first time someone introduced
    a snake_case raw value (`textWithCancel = "text_with_cancel"`
    for the Q15 typed-INSTALL legal gate).
    """
    enum_pat = re.compile(
        r"enum\s+PromptKind\b[^{]*\{(.*?)\}",
        re.DOTALL,
    )
    m = enum_pat.search(src)
    if not m:
        return []
    body = m.group(1)
    kinds: list[str] = []
    # Each `case` line is either:
    #   case foo                       (default raw value = "foo")
    #   case foo, bar, baz             (multi-case, default raw values)
    #   case foo = "snake_case"        (explicit raw value)
    # Multi-case lines never carry explicit raw values in Swift, so
    # the two shapes are mutually exclusive per line.
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped.startswith("case"):
            continue
        # Drop trailing `//` comments before splitting.
        comment_idx = stripped.find("//")
        if comment_idx >= 0:
            stripped = stripped[:comment_idx].rstrip()
        # Strip the leading `case` keyword.
        rest = stripped[len("case"):].strip()
        if not rest:
            continue
        # Explicit raw value form: `name = "wire_value"`.
        eq_match = re.match(r"([A-Za-z0-9_]+)\s*=\s*\"([^\"]+)\"", rest)
        if eq_match:
            kinds.append(eq_match.group(2))
            continue
        # Default raw value form: comma-separated case names.
        for name in rest.split(","):
            name = name.strip()
            if name:
                kinds.append(name)
    return kinds


def _extract_canonical_order(src: str, rel: str) -> list[dict]:
    """Pull the StepCatalog.canonicalOrder string array.

    Returns one handler entry per id, marked as a STEP_BEGIN handler
    (the sidebar consumes both STEP_BEGIN and PHASE markers against
    this same list -- see InstallerCoordinator.swift:371,381).
    """
    pat = re.compile(
        r"static\s+let\s+canonicalOrder\s*:\s*\[String\]\s*=\s*\[(.*?)\]",
        re.DOTALL,
    )
    m = pat.search(src)
    if not m:
        return []
    body = m.group(1)
    line_base = src.count("\n", 0, m.start(1)) + 1
    handlers: list[dict] = []
    for str_m in re.finditer(r'"([^"]+)"', body):
        idx = str_m.start()
        line_no = line_base + body.count("\n", 0, idx)
        handlers.append({
            "kind": "STEP_BEGIN",
            "id_or_name": str_m.group(1),
            "file": rel,
            "line": line_no,
            "handler_symbol": "StepCatalog.canonicalOrder",
        })
        # Same id is also a registered PHASE handler -- the sidebar
        # advance logic (advanceSidebarFromPhase) gates on the same
        # array.  Two entries keeps the diff symmetric.
        handlers.append({
            "kind": "PHASE",
            "id_or_name": str_m.group(1),
            "file": rel,
            "line": line_no,
            "handler_symbol": "StepCatalog.canonicalOrder",
        })
    return handlers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent.parent,
        help="Repo root (defaults to two levels above gui/scripts/).",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write manifest JSON to this path (defaults to stdout).",
    )
    args = parser.parse_args()

    repo_root: Path = args.repo_root.resolve()
    protocol_path = repo_root / "gui" / "OstlerInstaller" / "ProgressProtocol.swift"
    catalog_path = repo_root / "gui" / "OstlerInstaller" / "Steps" / "StepCatalog.swift"
    for src_path in (protocol_path, catalog_path):
        if not src_path.exists():
            print(f"ERROR: missing {src_path}", file=sys.stderr)
            return 2

    proto_rel = str(protocol_path.relative_to(repo_root))
    catalog_rel = str(catalog_path.relative_to(repo_root))

    proto_src = _strip_swift_comments(protocol_path.read_text(encoding="utf-8"))
    catalog_src = _strip_swift_comments(catalog_path.read_text(encoding="utf-8"))

    handlers = _extract_decoder_cases(proto_src, proto_rel)
    prompt_kinds = _extract_prompt_kinds(proto_src, proto_rel)

    # PROMPT dispatch is generic in the Swift coordinator (one case arm
    # ingests every prompt regardless of id).  Re-tag the PROMPT entry
    # so the diff understands it is a wildcard handler.
    for h in handlers:
        if h["kind"] == "PROMPT":
            h["id_or_name"] = "*"

    handlers.extend(_extract_canonical_order(catalog_src, catalog_rel))

    manifest = {
        "handlers": handlers,
        "prompt_kinds": prompt_kinds,
        "soft_unknown_ok": sorted(SOFT_UNKNOWN_OK),
    }
    payload = json.dumps(manifest, indent=2, sort_keys=False)
    if args.out:
        args.out.write_text(payload + "\n")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
