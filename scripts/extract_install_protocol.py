#!/usr/bin/env python3
"""Extract every protocol-event emission from install.sh.

The cross-component contract between install.sh and the Swift GUI is the
#OSTLER<TAB>EVENT<TAB>k=v... wire format defined in lib/progress_emitter.sh.
This script walks install.sh and lib/progress_emitter.sh, finds every
emission callsite, and writes a JSON manifest of (kind, id_or_name,
args, file, line) tuples.

The manifest is consumed by tests/test_install_gui_contract.py, which
diffs it against the Swift handler manifest produced by
gui/scripts/extract_gui_renderers.py to surface protocol drift.

Discovered helpers (calls -- not the no-op stub definitions):
  gui_emit <EVENT> <k=v ...>      direct emission, EVENT is uppercase
  gui_step_begin <id> <title> ... wraps gui_emit STEP_BEGIN
  gui_step_end [status]           wraps gui_emit STEP_END
  gui_phase <id> <title>          wraps gui_emit PHASE
  gui_done [status]               wraps gui_emit DONE
  gui_needs_sudo [reason]         wraps gui_emit NEEDS_SUDO
  gui_needs_fda <probe> [reason]  wraps gui_emit NEEDS_FDA
  gui_read <title> [kind] [default] [help] [choices] [id]
                                  wraps gui_emit PROMPT (last positional
                                  is the prompt id; falls back to a
                                  slug of the title when omitted, but
                                  every callsite in the tree passes id)
  step "Title" [id]               wraps gui_phase (in install.sh)

The parser skips:
  - Comment-only lines and trailing comments
  - Heredoc bodies (<<EOF ... EOF and <<'EOF' ... EOF)
  - Function definitions (e.g. gui_emit() {...}, including the no-op
    stubs at lines ~236-245 and ~567-593 in install.sh)
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

# Wrapper function name -> emitted EVENT kind. step() wraps gui_phase
# which wraps gui_emit PHASE; progress() wraps gui_step_begin which
# wraps gui_emit STEP_BEGIN.  The parser treats them as a chain.
WRAPPERS: dict[str, str] = {
    "gui_step_begin": "STEP_BEGIN",
    "gui_step_end": "STEP_END",
    "gui_phase": "PHASE",
    "gui_done": "DONE",
    "gui_needs_sudo": "NEEDS_SUDO",
    "gui_needs_fda": "NEEDS_FDA",
    "gui_read": "PROMPT",
    "step": "PHASE",      # step() in install.sh -> gui_phase
    "progress": "STEP_BEGIN",  # progress() in install.sh -> gui_step_begin
}

# Lines that LOOK like calls but are definitions or stubs. Anything that
# matches one of these patterns is skipped.
_DEFN_RE = re.compile(
    r"""^\s*
        (?:function\s+)?
        (gui_emit|gui_step_begin|gui_step_end|gui_phase|gui_done|
         gui_needs_sudo|gui_needs_fda|gui_read|gui_log|gui_warn|
         gui_active|step|progress)
        \s*\(\s*\)
    """,
    re.VERBOSE,
)

_COMMENT_RE = re.compile(r"^\s*#")
_HEREDOC_OPEN_RE = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def _inside_quotes(line: str, idx: int) -> bool:
    """True when position `idx` of `line` is inside a single- or
    double-quoted span at bash's parsing level.

    Tracks `$(` ... `)` command substitutions because bash suspends the
    surrounding double-quote scope inside them -- so `"$(gui_read ...)"`
    does NOT count as wrapper-inside-quotes for our purposes.  The
    stack tracks substitution depth and saves/restores the quote
    flags at each substitution boundary.

    Used to suppress false-positive wrapper matches inside quoted
    string arguments to `warn "step 3.14 may pause"`, `info "..."`,
    etc.
    """
    in_single = False
    in_double = False
    # Stack of (in_single, in_double) snapshots for each `$(` we enter.
    subst_stack: list[tuple[bool, bool]] = []
    i = 0
    while i < idx and i < len(line):
        ch = line[i]
        if ch == "\\" and i + 1 < len(line):
            i += 2
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif (
            ch == "$"
            and i + 1 < len(line)
            and line[i + 1] == "("
            and not in_single
        ):
            # Enter a command substitution: save the outer quote scope
            # and reset to "unquoted" for the substitution body.
            subst_stack.append((in_single, in_double))
            in_single = False
            in_double = False
            i += 2
            continue
        elif ch == ")" and subst_stack:
            in_single, in_double = subst_stack.pop()
        i += 1
    return in_single or in_double


def _strip_inline_comment(line: str) -> str:
    """Drop a trailing '# comment' from a bash line.

    Conservative: only strips when the '#' is preceded by whitespace and
    is outside any single- or double-quoted span.  Avoids false-positive
    truncation of `gui_emit STEP_BEGIN "id=foo" "title=#1"`.
    """
    in_single = False
    in_double = False
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            if i == 0 or line[i - 1].isspace():
                return line[:i]
        i += 1
    return line


def _split_call_args(rest: str) -> list[str]:
    """Best-effort positional-arg split for a bash call.

    Uses shlex so quoted strings stay grouped.  Walks character-by-
    character to find the matching close paren / quote so the arg list
    does not pick up the trailing `)"` from an enclosing `$(...)"`
    command substitution.
    """
    cleaned = rest.strip()

    # Walk forward tracking quote and paren state so we can clip at the
    # end of the call's own arg list.  This is the correct way to bound
    # `gui_read "..." text "" "" "" "id"` when it is inside
    # `VAR="$(gui_read ... )"` -- shlex alone cannot tell where the
    # outer `$()` closes.
    in_single = False
    in_double = False
    paren_depth = 0  # tracks `$(...)` and `(...)` AFTER the call name
    end_idx = len(cleaned)
    i = 0
    n = len(cleaned)
    while i < n:
        ch = cleaned[i]
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif not in_single and not in_double:
            if ch == "(":
                paren_depth += 1
            elif ch == ")":
                # Close of an enclosing $(...) -- stop here.  At
                # paren_depth 0 the `)` belongs to the wrapping
                # substitution, not the call.
                if paren_depth == 0:
                    end_idx = i
                    break
                paren_depth -= 1
            elif ch == ";":
                # End of statement on the same line.
                end_idx = i
                break
        i += 1
    cleaned = cleaned[:end_idx].strip()
    # Drop a trailing line-continuation that survived the stitching.
    cleaned = cleaned.rstrip("\\").strip()
    try:
        tokens = shlex.split(cleaned, comments=False, posix=True)
    except ValueError:
        # Unbalanced quotes after our trimming would be a real parse
        # error; fall back to whitespace split so we still record an
        # entry (the test harness flags malformed callsites separately).
        tokens = cleaned.split()
    return tokens


def _slugify_title(title: str) -> str:
    """Mirror gui_read / step's title->id slug derivation."""
    lowered = title.lower()
    out_chars = []
    for ch in lowered:
        if ch.isalnum() or ch == "_":
            out_chars.append(ch)
        elif ch == " ":
            out_chars.append("_")
    slug = "".join(out_chars)
    return slug or "prompt"


def _parse_kv_args(args: list[str]) -> tuple[str | None, list[str]]:
    """Extract id=<x> from a gui_emit args list and return (id, args).

    Args that are already `id=<...>` count.  Others are echoed back
    verbatim (the manifest preserves the raw shape).
    """
    id_value: str | None = None
    for arg in args:
        if arg.startswith("id="):
            id_value = arg[3:]
            break
    return id_value, args


def _parse_line_call(
    line: str,
    fname: str,
    lineno: int,
) -> list[dict] | None:
    """Match one bash line against a known emitter callsite.

    Returns a list of emission dicts (one per call -- a line typically
    has just one), or None if no emitter call is present.
    """
    if _COMMENT_RE.match(line):
        return None
    if _DEFN_RE.match(line):
        return None

    stripped = _strip_inline_comment(line).strip()
    if not stripped:
        return None

    # Calls inside $() share a leading whitespace pattern with bare
    # statements once the surrounding `$(` is gone.  We accept both.
    # Identify the leading callable token.  We allow an arbitrary
    # leading prefix (e.g. assignment, `if`, `then`) provided the token
    # we recognise sits at a word boundary.
    emissions: list[dict] = []

    # gui_emit <EVENT> <k=v ...>
    m = re.search(
        r"\bgui_emit\s+([A-Z][A-Z0-9_]+)\b(.*)$",
        stripped,
    )
    if m:
        event = m.group(1)
        rest = m.group(2)
        args = _split_call_args(rest)
        id_value, args_clean = _parse_kv_args(args)
        emissions.append({
            "kind": event,
            "id_or_name": id_value,
            "args": args_clean,
            "file": fname,
            "line": lineno,
            "via": "gui_emit",
        })

    # Wrapper helpers.  Order matters: longer names first so `gui_step_`
    # is not shadowed by `gui_`.
    for wrapper in sorted(WRAPPERS, key=len, reverse=True):
        # `\b` does not match between `_` chars in Python regex, but we
        # bracket on shell-word-boundary chars to keep matches anchored.
        # `(` is included so calls inside command substitution (`$(...)`)
        # are caught -- every `gui_read` callsite in install.sh is of the
        # form `VAR="$(gui_read ...)"`, which would otherwise be missed.
        pat = re.compile(rf"(?:^|[\s;&|(]){re.escape(wrapper)}(\s|$)")
        for m in pat.finditer(stripped):
            # Skip when the wrapper token sits inside a quoted span --
            # e.g. `warn "step 3.14 may pause"` would otherwise match
            # `step` as a real callsite.
            if _inside_quotes(stripped, m.start()):
                continue
            # Skip if this is the same span we already matched as
            # gui_emit (gui_emit's name does not collide with the
            # wrapper list, so this is just defence in depth).
            call_start = m.end() - len(m.group(1))
            rest = stripped[call_start:].lstrip()
            args = _split_call_args(rest)
            kind = WRAPPERS[wrapper]
            id_value: str | None = None
            if wrapper == "gui_step_begin":
                # gui_step_begin <id> <title> [phase] [idx] [total]
                id_value = args[0] if args else None
            elif wrapper == "gui_step_end":
                # gui_step_end [status]  -- id is the implicit
                # __OSTLER_STEP_ID, surfaced as None in the manifest.
                id_value = None
            elif wrapper == "gui_phase":
                # gui_phase <id> <title>
                id_value = args[0] if args else None
            elif wrapper == "gui_done":
                # gui_done [status]
                id_value = None
            elif wrapper == "gui_needs_sudo":
                id_value = None
            elif wrapper == "gui_needs_fda":
                # gui_needs_fda <probe> [reason] -- probe IS the id key
                id_value = args[0] if args else None
            elif wrapper == "gui_read":
                # gui_read <title> [kind] [default] [help] [choices] [id]
                # Prefer the explicit id (arg 5).  Fall back to the slug
                # of the title so the contract test still has a stable
                # id for callsites that omit the 6th arg.
                if len(args) >= 6 and args[5]:
                    id_value = args[5]
                elif args:
                    id_value = _slugify_title(args[0])
            elif wrapper == "step":
                # step "Title" [id]
                if len(args) >= 2 and args[1]:
                    id_value = args[1]
                elif args:
                    id_value = _slugify_title(args[0])
            elif wrapper == "progress":
                # progress "Title" [id]   (install.sh in-line wrapper
                # around gui_step_begin -- same shape as step())
                if len(args) >= 2 and args[1]:
                    id_value = args[1]
                elif args:
                    id_value = _slugify_title(args[0])

            emissions.append({
                "kind": kind,
                "id_or_name": id_value,
                "args": args,
                "file": fname,
                "line": lineno,
                "via": wrapper,
            })
            break  # one wrapper match per line is plenty

    return emissions or None


def _scan_file(path: Path, repo_root: Path) -> list[dict]:
    """Walk a bash script and emit one entry per recognised callsite.

    Skips:
      - heredoc bodies (the marker shape would otherwise be misread)
      - lines inside a function definition body, ONLY for
        lib/progress_emitter.sh -- the library file declares the
        wrappers, so its internal `gui_emit ...` calls would create
        phantom emissions.  install.sh is scanned in full, including
        the in-line `step()` definition (its `gui_phase` line is a
        wrapper signature, not a real emission, so the test will
        filter that one entry by line number later if it sneaks in --
        but the function-body filter below also catches it).

    Stitches lines ending in `\\` so multi-line callsites
    (e.g. install.sh:1441's wrapped gui_read) parse as one logical
    line and keep the start line number.
    """
    rel = str(path.relative_to(repo_root))
    is_progress_emitter = path.name == "progress_emitter.sh"
    is_install = path.name == "install.sh"
    emissions: list[dict] = []
    heredoc_terminator: str | None = None
    func_depth = 0  # `{` depth INSIDE a top-level function definition
    in_function = False

    # Read all lines so we can stitch continuations.
    raw_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    i = 0
    while i < len(raw_lines):
        start_lineno = i + 1
        line = raw_lines[i]

        if heredoc_terminator is not None:
            if line.strip() == heredoc_terminator:
                heredoc_terminator = None
            i += 1
            continue

        m_here = _HEREDOC_OPEN_RE.search(line)
        if m_here:
            heredoc_terminator = m_here.group(1)
            # The opener line itself can still carry a call before `<<`,
            # so we fall through.

        # Stitch line continuations.
        logical = line
        while logical.rstrip().endswith("\\") and i + 1 < len(raw_lines):
            logical = logical.rstrip()[:-1] + " " + raw_lines[i + 1]
            i += 1

        # Function-body tracking.  We only suppress emissions inside
        # function bodies for the library file; install.sh's `step()`
        # and `progress()` wrappers are intentionally counted (their
        # bodies contain the gui_phase / gui_step_begin calls that
        # are the real callsites -- and the wrappers are themselves
        # only invoked from install.sh, which IS scanned).
        if is_progress_emitter:
            # Detect function-definition opener on this line.
            if _DEFN_RE.match(line):
                in_function = True
                func_depth = line.count("{") - line.count("}")
            elif in_function:
                func_depth += line.count("{") - line.count("}")
                if func_depth <= 0:
                    in_function = False
                    func_depth = 0
                    i += 1
                    continue
            if in_function:
                i += 1
                continue

        found = _parse_line_call(logical, rel, start_lineno)
        if found:
            # The line inside `step()`'s own definition (install.sh
            # ~270, `gui_phase "$id" "$title"`) is a wrapper-internal
            # call -- the real PHASE emissions are the `step` callsites
            # we already record.  Drop it by file+line if present.
            if is_install:
                found = [e for e in found if not (
                    e["file"].endswith("install.sh")
                    and e["via"] == "gui_phase"
                    and e["id_or_name"] == "$id"
                )]
            emissions.extend(found)

        i += 1

    return emissions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repo root (defaults to one level above scripts/).",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write manifest JSON to this path (defaults to stdout).",
    )
    args = parser.parse_args()

    repo_root: Path = args.repo_root.resolve()
    sources = [
        repo_root / "install.sh",
        repo_root / "lib" / "progress_emitter.sh",
    ]
    for src in sources:
        if not src.exists():
            print(f"ERROR: missing {src}", file=sys.stderr)
            return 2

    emissions: list[dict] = []
    for src in sources:
        emissions.extend(_scan_file(src, repo_root))

    manifest = {"emissions": emissions}
    payload = json.dumps(manifest, indent=2, sort_keys=False)
    if args.out:
        args.out.write_text(payload + "\n")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
