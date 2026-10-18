#!/usr/bin/env python3
"""A conversation must produce all four artefacts, or the customer loses one.

THE LOCKED RULE (CLAUDE.md, 2026-05-09): every human conversation produces
summary.md, todos.md, transcript.md and frontmatter metadata, together under
~/Documents/Ostler/Conversations/<date>/<slug>-<id>/. "Transcript without
summary or summary without todos is a fail."

WHAT WAS MEASURED, 2026-09-16, and why this file exists.
conversation_writer.py writes all four unconditionally. NOTHING CHECKED THAT.
`todos.md` appeared in 0 files across tests/, scripts/ and .github/, against a
control of 1 for `summary.md` on the identical search, and 0 of the box-walk
probes read conversations at all. So a pipeline could drop three of the four
and every gate we own would stay green.

That is the week's defect class pointed at a locked directive: the rule was
written down, the writer obeys it today, and nothing makes tomorrow's writer
obey it. A rule with no enforcer is a preference.

WHAT THIS ASSERTS. The real writer is called with a real bundle and the four
files are required on disk WITH CONTENT, because an empty todos.md satisfies a
file-exists check while giving the customer nothing. The subject is the
customer's folder, not the function's return value: the return value can claim
a path the writer never wrote.
"""
import pathlib, sys, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Imported AS ITS PACKAGE, the way the shipped callers do it
# (processor.py: `from . import conversation_writer`). Importing the file
# directly raises ImportError on its relative imports, and a test that
# reached for a path the product never uses would be measuring a different
# module from the one that runs.
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
from src import conversation_writer as cw  # noqa: E402

REQUIRED = ("summary.md", "transcript.md", "todos.md")


def _bundle(**over):
    topic = cw.Topic(name="Roof", points=("Quote due Friday", "Two trades"))
    summary = cw.ConversationSummary(overall="Roof quote agreed", topics=(topic,))
    todo = cw.Todo(
        id=cw.make_todo_id("synthetic-fourartefact-0001", "other", "Send the quote"),
        text="Send the quote", owner="other", deadline="2026-09-20")
    kw = dict(
        conversation_id="synthetic-fourartefact-0001",
        source_kind="channel", source_subtype="imessage",
        source_session_id="synthetic-session-0001", channel="im",
        participants=("owner", "counterparty"),
        started_at="2026-09-16T09:00:00Z", ended_at="2026-09-16T09:12:00Z",
        summary=summary, transcript="owner: hello\ncounterparty: hi\n",
        todos=(todo,), privacy_level="L2")
    kw.update(over)
    return cw.ConversationBundle(**kw)


class FourArtefacts(unittest.TestCase):
    def _write(self, **over):
        d = pathlib.Path(tempfile.mkdtemp())
        out = cw.write_conversation(_bundle(**over), root=d, user_id="user")
        folders = [p for p in d.rglob("*") if p.is_dir() and (p / "summary.md").exists()]
        self.assertTrue(folders, f"the writer produced no conversation folder under {d}")
        return folders[0], out

    def test_all_four_land_with_content(self):
        folder, _ = self._write()
        missing = [n for n in REQUIRED if not (folder / n).exists()]
        self.assertFalse(missing, f"artefacts missing from the customer's folder: {missing}")
        empty = [n for n in REQUIRED if (folder / n).stat().st_size == 0]
        self.assertFalse(empty, f"artefacts present but EMPTY, which a file-exists check would pass: {empty}")
        print(f"\n  all {len(REQUIRED)} artefacts present with content in {folder.name}")

    def test_every_artefact_carries_frontmatter_metadata(self):
        """The fourth artefact is metadata, and it lives in the frontmatter."""
        folder, _ = self._write()
        for n in REQUIRED:
            head = (folder / n).read_text().splitlines()[:1]
            self.assertEqual(head, ["---"],
                             f"{n} does not open with YAML frontmatter, so the metadata artefact is absent from it")
        body = (folder / "summary.md").read_text()
        for key in ("conversation_id", "privacy_level"):
            self.assertIn(key, body, f"frontmatter does not carry {key}")
        print("  every artefact opens with frontmatter carrying conversation_id and privacy_level")

    def test_todos_body_actually_carries_the_todo(self):
        """CONTROL AGAINST A VACUOUS PASS.

        todos.md could contain only frontmatter and satisfy every check above
        while the customer's commitment is lost. Require the text through.
        """
        folder, _ = self._write()
        self.assertIn("Send the quote", (folder / "todos.md").read_text(),
                      "todos.md exists and does not contain the todo, so the artefact is a shell")
        print("  todos.md carries the commitment text, not just frontmatter")

    def test_the_predicate_can_fail(self):
        """POSITIVE CONTROL. A folder with a file removed must be detected.

        Without this, a bug that made REQUIRED empty would turn every test
        above into a pass that measures nothing.
        """
        folder, _ = self._write()
        (folder / "todos.md").unlink()
        missing = [n for n in REQUIRED if not (folder / n).exists()]
        self.assertEqual(missing, ["todos.md"],
                         "removing an artefact was not detected, so the checks above prove nothing")
        print("  control: removing todos.md is detected")


if __name__ == "__main__":
    unittest.main(verbosity=2)
