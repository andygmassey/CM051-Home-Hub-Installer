"""Otter.ai owner export: TXT, SRT, DOCX from the conversation's Export menu.

Export path CONFIRMED in Otter's help centre (three-dot menu > Export; TXT,
DOCX, PDF, SRT). PDF is not parsed. The TXT layout below ("Name  0:12" on
one line, text on the next) is ASSUMED from the export options (speaker
names, timestamps) and must be checked against a real file. Otter's
summary/action items are a separate export (not parsed here: TODO).
"""
from __future__ import annotations

from pathlib import Path

from ..model import Meeting, Utterance
from . import transcript_files as tf


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext != ".txt":
        return tf.parse(path, source="otter", label="Otter")
    paras = [l.strip() for l in path.read_text(encoding="utf-8", errors="replace").splitlines()]
    paras = [p for p in paras if p]
    title = tf.title_from(path)
    if paras and not tf._HDR.match(paras[0]) and not tf._LABEL.match(paras[0]):
        title, paras = paras[0], paras[1:]  # a leading title line
    utts = tf.parse_paragraphs(paras)
    if not utts:
        return []
    return [Meeting(source="otter", source_label="Otter", title=title,
                    started_at=tf.date_from(path), utterances=tuple(utts),
                    source_file=path.name)]
