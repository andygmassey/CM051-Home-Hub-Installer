"""Owner-outbound rows in the Hub's SQLCipher DB. Key comes only from
ostler_security.resolve_db_key. Fails closed: no key means no file is created
and nothing is written."""
import re

_HEX = re.compile(r"^[0-9a-fA-F]{16,}$")
_DDL = """CREATE TABLE IF NOT EXISTS owner_outbound (
    person_uri TEXT NOT NULL,
    channel TEXT NOT NULL,
    last_owner_sent_at INTEGER,
    owner_sent_count INTEGER NOT NULL DEFAULT 0,
    group_sent_count INTEGER NOT NULL DEFAULT 0,
    source_id TEXT,
    updated_at INTEGER,
    PRIMARY KEY (person_uri, channel))"""


class KeyUnavailable(Exception):
    pass


class StoreUnavailable(Exception):
    """CANNOT-RUN: the sqlcipher3 binding is not importable here. Not a pass."""


class SqlCipherStore:
    def __init__(self, conn):
        self._conn = conn

    @classmethod
    def open(cls, path, key_resolver):
        key = key_resolver()
        if not key or not _HEX.match(key):
            raise KeyUnavailable("no usable DB key; refusing to create or write")
        try:
            import sqlcipher3
        except ImportError as e:
            raise StoreUnavailable("CANNOT-RUN: sqlcipher3 not importable") from e
        conn = sqlcipher3.connect(path)
        conn.execute(f"PRAGMA key = \"x'{key}'\"")
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()  # wrong key raises here
        conn.execute(_DDL)
        return cls(conn)

    def get_row(self, person_uri, channel):
        cur = self._conn.execute(
            "SELECT last_owner_sent_at, owner_sent_count, group_sent_count, source_id, updated_at "
            "FROM owner_outbound WHERE person_uri=? AND channel=?", (person_uri, channel))
        r = cur.fetchone()
        if not r:
            return None
        return {"last_owner_sent_at": r[0], "owner_sent_count": r[1],
                "group_sent_count": r[2], "source_id": r[3], "updated_at": r[4]}

    def upsert_row(self, person_uri, channel, row):
        self._conn.execute(
            "INSERT INTO owner_outbound (person_uri, channel, last_owner_sent_at, owner_sent_count, "
            "group_sent_count, source_id, updated_at) VALUES (?,?,?,?,?,?,?) "
            "ON CONFLICT(person_uri, channel) DO UPDATE SET "
            "last_owner_sent_at=excluded.last_owner_sent_at, owner_sent_count=excluded.owner_sent_count, "
            "group_sent_count=excluded.group_sent_count, source_id=excluded.source_id, "
            "updated_at=excluded.updated_at",
            (person_uri, channel, row.get("last_owner_sent_at"), row["owner_sent_count"],
             row["group_sent_count"], row.get("source_id"), row.get("updated_at")))

    def delete_rows_for(self, person_uri):
        cur = self._conn.execute("DELETE FROM owner_outbound WHERE person_uri=?", (person_uri,))
        return cur.rowcount

    def person_uris(self):
        return [r[0] for r in self._conn.execute(
            "SELECT DISTINCT person_uri FROM owner_outbound").fetchall()]

    def commit(self):
        self._conn.commit()

    def count_rows_for(self, person_uri):
        return self._conn.execute(
            "SELECT count(*) FROM owner_outbound WHERE person_uri=?", (person_uri,)).fetchone()[0]

    def close(self):
        self._conn.close()
