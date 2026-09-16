#!/usr/bin/env python3
"""A record with a privacy level and no compartment level cannot be found.

THE DEFECT THIS EXISTS FOR. Ostler carries TWO privacy scales that run in
opposite directions (see docs/PRIVACY_LEVELS.md):

    privacy_level      L0..L3, a STRING, HIGHER is more private, L3 hidden
    compartment_level  0..6,   an INT,   LOWER  is more private, 0 Personal

The compartment search filter has two arms, one numeric and one string. A
payload carrying NO compartment_level matches NEITHER, so the record sits on
the customer's disk and never appears in a result. Measured on a real box
before this guard existed: 934 of 9,948 points had the field absent, and five
of the six FDA writers stamped a privacy level and no compartment level at all.

Nothing reported it. A search returning less and a search working correctly
print the same thing.

WHY IT PARSES RATHER THAN GREPS. Counting occurrences of a string cannot tell
a dict key from a comment mentioning one, and this file is full of comments
mentioning both. The check walks dict literals and asks whether the keys are
present together.
"""
import ast
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
FDA = REPO / "vendor" / "ostler_fda"
PRIVACY = "privacy_level"
COMPARTMENT = "compartment_level"

fails = []


def dict_keys(node):
    out = set()
    for k in node.keys:
        if isinstance(k, ast.Constant) and isinstance(k.value, str):
            out.add(k.value)
    return out


def subscript_writes(tree):
    """`d["privacy_level"] = x` assignments, which are payload writes too."""
    hits = {PRIVACY: [], COMPARTMENT: []}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for t in node.targets:
            if (isinstance(t, ast.Subscript) and isinstance(t.slice, ast.Constant)
                    and t.slice.value in hits):
                hits[t.slice.value].append(node.lineno)
    return hits


def main():
    if not FDA.is_dir():
        print("CANNOT-RUN: vendor/ostler_fda is not present. That is NOT a pass:")
        print("            this guard measured nothing.")
        return 2

    files = sorted(FDA.glob("*.py"))
    if len(files) < 5:
        print(f"CANNOT-RUN: only {len(files)} python file(s) under vendor/ostler_fda.")
        print("            The tree has more than that, so this is a broken read")
        print("            rather than a small tree.")
        return 2

    examined = 0
    offenders = []
    for f in files:
        try:
            tree = ast.parse(f.read_text(encoding="utf-8"))
        except SyntaxError as e:
            fails.append(f"{f.name} does not parse: {e}")
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Dict):
                continue
            keys = dict_keys(node)
            if PRIVACY not in keys:
                continue
            examined += 1
            if COMPARTMENT not in keys:
                offenders.append(f"{f.name}:{node.lineno}")
        sw = subscript_writes(tree)
        if sw[PRIVACY] and not sw[COMPARTMENT]:
            offenders.append(f"{f.name}:{sw[PRIVACY][0]} (subscript write)")
        examined += len(sw[PRIVACY])

    # ── A ZERO DENOMINATOR IS NOT A PASS ──────────────────────────────────
    # If the walk finds no payloads at all, the writers were renamed, moved,
    # or the parse silently produced nothing. "No offenders" would then be
    # true and meaningless.
    if examined == 0:
        print("CANNOT-RUN: found ZERO payloads carrying a privacy_level across")
        print(f"            {len(files)} file(s). The writers cannot all have stopped")
        print("            stamping it, so this is a broken predicate.")
        return 2

    print(f"examined {examined} payload site(s) carrying `{PRIVACY}` "
          f"across {len(files)} file(s).")

    if offenders:
        print()
        print(f"  FAIL  {len(offenders)} payload(s) stamp a privacy level and NO "
              f"compartment level:")
        for o in offenders:
            print(f"        {o}")
        print()
        print("        A record with no compartment_level matches neither arm of the")
        print("        compartment filter, so the customer can never find it. Stamp it")
        print("        from the file's own DEFAULT_COMPARTMENT, and do NOT derive it")
        print("        from the privacy level: the two scales run opposite ways.")
        fails.append("unstamped payloads")
    else:
        print(f"  PASS  every one of the {examined} payload site(s) carrying a privacy "
              f"level also carries a compartment level")

    # ── THE OTHER HALF: the compartment level must be an INT, not "L2" ─────
    # It is declared int and indexed as integer. The string form matched no
    # range query at all, which is how 4,804 points became unsearchable.
    stringy = []
    for f in files:
        try:
            tree = ast.parse(f.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Dict):
                continue
            for k, v in zip(node.keys, node.values):
                if (isinstance(k, ast.Constant) and k.value == COMPARTMENT
                        and isinstance(v, ast.Constant) and isinstance(v.value, str)):
                    stringy.append(f"{f.name}:{node.lineno} = {v.value!r}")
    if stringy:
        print(f"  FAIL  {len(stringy)} site(s) write compartment_level as a STRING:")
        for s in stringy:
            print(f"        {s}")
        print("        It is declared int and indexed as integer; a string matches no")
        print("        range query, which is how 4,804 points became unsearchable.")
        fails.append("string compartment level")
    else:
        print("  PASS  no site writes compartment_level as a string literal")

    print(f"\n{2 - len(fails)} passed, {len(fails)} failed, denominator 2")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
