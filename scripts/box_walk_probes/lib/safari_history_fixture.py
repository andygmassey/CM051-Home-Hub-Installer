#!/usr/bin/env python3
"""Write a SYNTHETIC Safari History.db for the walk seed (scripts/ttywalk.sh).

Usage: safari_history_fixture.py <out.db> [--now <unix-seconds>]

Schema mirrors Safari's own (history_items / history_visits, visit_time in Mac
absolute seconds since 2001-01-01). Every URL is on a reserved example domain
and every title is invented: no real browsing data, ever (PUBLIC repo).
A walk_synthetic_marker table (never present in a real History.db) lets the
seed recognise its own earlier fixture and replace it, while refusing to touch
any file without the marker. Visits sit inside the last 30 days so the extractor's default 365-day window
and the catch-up ladder both see them. Prints the visit and domain counts it
wrote, so the caller can record what was planted.
"""
import os
import sqlite3
import sys
import time

MAC_EPOCH_OFFSET = 978307200

SYNTHETIC_PAGES = [
    ("https://www.example.com/", "Walk fixture home page"),
    ("https://www.example.com/news/walk-fixture-1", "Walk fixture article one"),
    ("https://www.example.org/recipes/walk-fixture-soup", "Walk fixture soup recipe"),
    ("https://docs.example.net/guide/getting-started", "Walk fixture getting started"),
    ("https://shop.example.com/catalogue/walk-fixture-kettle", "Walk fixture kettle"),
    ("https://travel.example.org/guides/walk-fixture-lisbon", "Walk fixture city guide"),
]

SCHEMA = """
CREATE TABLE history_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL UNIQUE,
    domain_expansion TEXT,
    visit_count INTEGER NOT NULL,
    daily_visit_counts BLOB NOT NULL,
    weekly_visit_counts BLOB,
    autocomplete_triggers BLOB,
    should_recompute_derived_visit_counts INTEGER NOT NULL,
    visit_count_score INTEGER NOT NULL,
    status_code INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE walk_synthetic_marker (note TEXT);
INSERT INTO walk_synthetic_marker VALUES ('synthetic walk fixture, safe to replace');
CREATE TABLE history_visits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
    visit_time REAL NOT NULL,
    title TEXT,
    load_successful BOOLEAN NOT NULL DEFAULT 1,
    http_non_get BOOLEAN NOT NULL DEFAULT 0,
    synthesized BOOLEAN NOT NULL DEFAULT 0,
    redirect_source INTEGER,
    redirect_destination INTEGER,
    origin INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,
    attributes INTEGER NOT NULL DEFAULT 0,
    score INTEGER NOT NULL DEFAULT 0
);
"""


def build(path, now):
    if os.path.exists(path):
        os.unlink(path)
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    visits = 0
    for i, (url, title) in enumerate(SYNTHETIC_PAGES):
        n = 2 + (i % 3)
        con.execute(
            "INSERT INTO history_items (url, visit_count, daily_visit_counts, "
            "should_recompute_derived_visit_counts, visit_count_score) "
            "VALUES (?, ?, x'', 0, 0)", (url, n))
        item_id = con.execute("SELECT id FROM history_items WHERE url=?", (url,)).fetchone()[0]
        for k in range(n):
            t = now - (i * 3 + k + 1) * 86400 - 3600
            con.execute(
                "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?,?,?)",
                (item_id, t - MAC_EPOCH_OFFSET, title))
            visits += 1
    con.commit()
    con.close()
    domains = len({u.split("/")[2] for u, _ in SYNTHETIC_PAGES})
    return visits, domains


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    now = int(time.time())
    if "--now" in argv:
        now = int(argv[argv.index("--now") + 1])
    visits, domains = build(argv[1], now)
    print("visits=%d domains=%d" % (visits, domains))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
