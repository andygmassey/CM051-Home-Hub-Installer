"""Receipts and expenses (Bursar): the core data and judgement layer.

Local only. Reads the drop folder, iOS uploads (via the CLI) and email-intelligence
rows; writes a SQLite store and filed copies of the owner's originals. Never
re-encodes or deletes an original. Spec: ~/walkdriver/RECEIPTS_SPEC_2026-11-15.md.
Contract: ~/walkdriver/RECEIPTS_API_CONTRACT.md.
"""
