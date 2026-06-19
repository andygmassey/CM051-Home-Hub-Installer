"""Contact Syncer – reads contacts via CardDAV, classifies, and writes to Oxigraph + Qdrant."""
from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx

logger = logging.getLogger(__name__)

_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)

# Add parent directory so identity_resolver is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from contact_syncer.carddav import CardDAVClient
from contact_syncer.vcard_parser import parse_vcard
from contact_syncer.classifier import classify_contact
from contact_syncer.dedup import DedupDetector, print_report
from contact_syncer.photo_storage import remove_photo, write_photo

from identity_resolver.resolver import IdentityResolver  # type: ignore[import-untyped]
from identity_resolver.normalise import (  # type: ignore[import-untyped]
    clean_display_name,
    normalise_email,
    normalise_phone,
)

# Qdrant client
from qdrant_client import QdrantClient
from qdrant_client.models import PointStruct


class ContactSyncer:
    """Orchestrates the full contact sync pipeline."""

    def __init__(self, cfg: Any = None) -> None:
        self.cfg = cfg or config
        self.carddav = CardDAVClient(
            url=self.cfg.CARDDAV_URL,
            username=self.cfg.CARDDAV_USERNAME,
            password=self.cfg.CARDDAV_PASSWORD,
        )
        self.resolver = IdentityResolver(
            oxigraph_url=self.cfg.OXIGRAPH_URL,
            default_country_code=self.cfg.DEFAULT_COUNTRY_CODE,
        )
        self.qdrant = QdrantClient(url=self.cfg.QDRANT_URL)
        self.state_file = self.cfg.STATE_FILE
        # Set once we have confirmed/created the Qdrant collection in this
        # run, so the self-create probe costs one GET per sync, not one
        # per contact (#638).
        self._collection_ensured = False

    # -- state persistence ----------------------------------------------------

    def _load_state(self) -> Dict[str, Any]:
        if os.path.isfile(self.state_file):
            with open(self.state_file, "r", encoding="utf-8") as fh:
                return json.load(fh)
        return {}

    def _save_state(self, state: Dict[str, Any]) -> None:
        with open(self.state_file, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)

    # -- main sync ------------------------------------------------------------

    def sync(
        self,
        limit: Optional[int] = None,
        dry_run: bool = False,
    ) -> Dict[str, Any]:
        """Run the contact sync pipeline from CardDAV.

        1. Check CTag -- skip if unchanged.
        2. Get ETags, compare against state file.
        3. Fetch changed / new vCards.
        4. Parse -> classify -> resolve identity -> write Oxigraph -> queue Qdrant.
        5. Batch-embed person descriptions via Ollama.
        6. Upsert Qdrant points.
        7. Update state file.
        8. Log classification breakdown.

        Returns a result dict with shape::

            {
                "imported": int,        # person + business writes that succeeded
                "skipped": int,         # parse / write errors
                "errors": list[dict],   # detailed skip records
                "deleted": int,         # contacts removed because the CardDAV
                                        # collection no longer contains them
            }
        """
        state = self._load_state()
        old_ctag = state.get("collection_ctag", "")
        old_etags: Dict[str, str] = {
            k: v.get("etag", "") if isinstance(v, dict) else v
            for k, v in state.get("contacts", {}).items()
        }

        # Step 1: CTag check
        print("Checking collection CTag...")
        try:
            current_ctag = self.carddav.get_ctag()
        except Exception as exc:
            print(f"WARNING: CTag check failed ({exc}), proceeding with full ETag comparison.")
            current_ctag = ""

        if current_ctag and current_ctag == old_ctag and old_etags:
            print("CTag unchanged – no contacts modified since last sync. Skipping.")
            return {"imported": 0, "skipped": 0, "errors": [], "deleted": 0}

        # Step 2: Get ETags and determine changes
        print("Fetching ETags...")
        if old_etags:
            vcard_texts, deleted_hrefs = self.carddav.get_changed_vcards(old_etags)
            current_etags = self.carddav.get_etags()
            print(
                f"Found {len(vcard_texts)} changed/new contacts, "
                f"{len(deleted_hrefs)} deleted."
            )
        else:
            # Initial sync – fetch everything
            print("Initial sync – fetching all vCards...")
            vcard_texts = self.carddav.get_all_vcards()
            current_etags = self.carddav.get_etags()
            deleted_hrefs = []
            print(f"Fetched {len(vcard_texts)} vCards.")

        if limit is not None:
            vcard_texts = vcard_texts[:limit]
            print(f"Limited to {limit} contacts.")

        # Step 2b: Process deletions (before writes, so stale nodes are gone first)
        deleted_count = 0
        if deleted_hrefs and not dry_run:
            deleted_count = self._process_deletions(deleted_hrefs)
        elif deleted_hrefs and dry_run:
            print(f"[DRY RUN] Would process {len(deleted_hrefs)} deletion(s).")

        # Step 3-4: Parse, classify, resolve, write
        total = len(vcard_texts)
        counts = {"person": 0, "business": 0, "unclassified": 0, "errors": 0}
        skipped: List[Dict[str, Any]] = []  # {uid, fn, stage, error}
        qdrant_queue: List[Dict[str, Any]] = []  # {person_id, person_uri, parsed, description}

        for i, vcard_text in enumerate(vcard_texts, 1):
            # Progress every 100 contacts
            if i % 100 == 0 or i == total:
                pct = int(i / total * 100) if total else 0
                print(
                    f"Syncing contacts: {i}/{total} ({pct}%) – "
                    f"{counts['person']} people, {counts['business']} businesses, "
                    f"{counts['errors']} errors"
                )

            # Stage 1: parse
            try:
                parsed = parse_vcard(vcard_text)
            except Exception as exc:
                import traceback
                counts["errors"] += 1
                skipped.append({"uid": None, "fn": None, "stage": "parse", "error": str(exc)})
                print(f"  ERROR parsing vCard [{i}/{total}]: {exc}")
                print(f"    vCard preview: {vcard_text[:200]!r}")
                print(f"    {traceback.format_exc().splitlines()[-1]}")
                continue

            uid_for_log = parsed.get("uid")
            fn_for_log = parsed.get("fn")

            # Stage 2: classify / resolve / write – wrap entire body so one bad
            # contact cannot crash the whole sync.
            try:
                contact_type = classify_contact(parsed)
                counts[contact_type] = counts.get(contact_type, 0) + 1

                if dry_run:
                    print(f"  [DRY RUN] {fn_for_log} (uid={uid_for_log}) -> {contact_type}")
                    continue

                if contact_type == "business":
                    self._write_business_oxigraph(parsed)
                else:
                    # Person or unclassified -- clean the display name (strip
                    # leading/trailing emoji+symbol runs, collapse duplicate
                    # tokens like "AC AC") before it seeds the person node.
                    # Only touch person rows; business names keep their raw
                    # form. Empty result -> leave the original untouched so we
                    # never blank a name we couldn't clean.
                    _cleaned = clean_display_name(parsed.get("fn") or "")
                    if _cleaned:
                        parsed["fn"] = _cleaned
                    # Person or unclassified – create person node
                    person_id, person_uri = self._resolve_and_write_person(parsed, contact_type)
                    description = self._build_description(parsed)
                    qdrant_queue.append(
                        {
                            "person_id": person_id,
                            "person_uri": person_uri,
                            "parsed": parsed,
                            "description": description,
                        }
                    )
            except Exception as exc:
                import traceback
                counts["errors"] += 1
                skipped.append({
                    "uid": uid_for_log,
                    "fn": fn_for_log,
                    "stage": "write",
                    "error": f"{type(exc).__name__}: {exc}",
                })
                print(f"  ERROR writing contact [{i}/{total}] {fn_for_log!r} (uid={uid_for_log}): {exc}")
                print(f"    {traceback.format_exc().splitlines()[-1]}")
                continue

        # Step 5-6: Batch embed and upsert Qdrant (only for people)
        if qdrant_queue and not dry_run:
            print(f"\nEmbedding {len(qdrant_queue)} person descriptions...")
            descriptions = [item["description"] for item in qdrant_queue]
            batch_size = self.cfg.EMBED_BATCH_SIZE
            all_vectors: List[List[float]] = []

            for batch_start in range(0, len(descriptions), batch_size):
                batch = descriptions[batch_start : batch_start + batch_size]
                vectors = self._embed_batch(batch)
                all_vectors.extend(vectors)
                done = min(batch_start + batch_size, len(descriptions))
                print(f"  Embedding: {done}/{len(descriptions)} ({int(done / len(descriptions) * 100)}%)")

            for idx, item in enumerate(qdrant_queue):
                if idx < len(all_vectors):
                    self._upsert_qdrant(
                        person_id=item["person_id"],
                        person_uri=item["person_uri"],
                        parsed=item["parsed"],
                        vector=all_vectors[idx],
                    )

        # Step 7: Update state
        if not dry_run:
            new_contacts_state: Dict[str, Any] = {}
            for href, etag in current_etags.items():
                new_contacts_state[href] = {"etag": etag}
            state["collection_ctag"] = current_ctag
            state["contacts"] = new_contacts_state
            state["last_sync"] = datetime.now(timezone.utc).isoformat()
            self._save_state(state)

        # Step 8: Log summary
        print("\n" + "=" * 60)
        print("Sync complete:")
        print(f"  People:        {counts['person']}")
        print(f"  Businesses:    {counts['business']}")
        print(f"  Unclassified:  {counts['unclassified']}")
        print(f"  Errors:        {counts['errors']}")
        if deleted_hrefs:
            print(f"  Deleted:       {deleted_count}/{len(deleted_hrefs)}")
        print("=" * 60)

        if skipped:
            print(f"\nSkipped contacts ({len(skipped)}):")
            for item in skipped:
                print(f"  - [{item['stage']}] {item.get('fn')!r} uid={item.get('uid')}: {item.get('error')}")
            # Persist skip log for post-sync analysis
            try:
                skip_log = os.path.join(
                    os.path.dirname(os.path.abspath(self.state_file)),
                    "skipped_contacts.json",
                )
                with open(skip_log, "w", encoding="utf-8") as fh:
                    json.dump(
                        {
                            "timestamp": datetime.now(timezone.utc).isoformat(),
                            "skipped": skipped,
                        },
                        fh,
                        indent=2,
                    )
                print(f"  (written to {skip_log})")
            except Exception as exc:
                print(f"  (could not write skip log: {exc})")

        imported = counts["person"] + counts["business"] + counts["unclassified"]
        return {
            "imported": imported,
            "skipped": len(skipped),
            "errors": skipped,
            "deleted": deleted_count,
        }

    def sync_from_vcf(
        self,
        vcf_path: str,
        dry_run: bool = False,
    ) -> Dict[str, Any]:
        """Ingest contacts from a single vCard file (B1 install-time hydration).

        Used by the customer install path (CM051 install.sh hydrate_graph
        sub-phase). The file is the iCloud Contacts export written earlier
        in install.sh at ``${OSTLER_DIR}/imports/icloud-contacts.vcf``.

        Differs from :meth:`sync` in that:
          - input is a single concatenated multi-vCard file, not CardDAV
          - no CTag / ETag / state-file tracking (one-shot, idempotent
            on the graph-write side via identity resolution)
          - no deletion handling (the graph is being populated, not
            reconciled against a remote)
          - all progress lines go to stderr so stdout stays clean for the
            caller's JSON consumer

        Returns the same shape as :meth:`sync`::

            {"imported": N, "skipped": N, "errors": [...], "deleted": 0}
        """
        # Local helper -- keep prints off stdout so the caller can capture
        # a single-line JSON status from stdout.
        def _log(msg: str) -> None:
            print(msg, file=sys.stderr)

        text = ""
        if os.path.isfile(vcf_path):
            try:
                with open(vcf_path, "r", encoding="utf-8") as fh:
                    text = fh.read()
            except Exception as exc:
                _log(f"Could not read vCard file: {exc}")
                # Don't bail: still try the abcddb fallback below so a
                # broken vcf path doesn't strand the customer with zero
                # contacts when the on-disk AddressBook has thousands.
                text = ""
        else:
            _log(f"vCard file not found: {vcf_path}; will try AddressBook fallback.")

        # Split the concatenated multi-vCard file. iCloud's export glues
        # BEGIN:VCARD ... END:VCARD blocks together with no separator
        # other than the newline before the next BEGIN.
        vcard_pattern = re.compile(r"BEGIN:VCARD.*?END:VCARD", re.DOTALL)
        vcard_texts = vcard_pattern.findall(text) if text.strip() else []
        total = len(vcard_texts)
        if total > 0:
            _log(f"Found {total} vCards in {vcf_path}.")

        # Fallback: read directly from ~/Library/Application Support/
        # AddressBook/Sources/<UUID>/AddressBook-v22.abcddb. The osascript
        # vcf export the installer runs ahead of this step can produce
        # an empty file (no error code) when Contacts.app TCC hasn't
        # been granted to osascript even though Contacts data exists
        # locally. Reading the abcddb sqlite directly bypasses the
        # AppleEvent route and only needs Full Disk Access, which is
        # already required for the Mail / Calendar / iMessage paths.
        # macOS 15+ stores per-account contact stores under Sources/
        # (one UUID dir per account); the top-level AddressBook-v22.abcddb
        # only holds the local-only "On My Mac" address book and is
        # typically near-empty on iCloud-only customers.
        if total == 0:
            try:
                abcddb_vcards = self._read_abcddb_as_vcards()
            except Exception as exc:
                _log(f"AddressBook fallback failed: {exc}")
                abcddb_vcards = []
            if abcddb_vcards:
                vcard_texts = abcddb_vcards
                total = len(vcard_texts)
                _log(f"Found {total} contacts in AddressBook (fallback path).")

        if total == 0:
            _log("No vCards in file and AddressBook fallback returned 0.")
            return {"imported": 0, "skipped": 0, "errors": [], "deleted": 0}

        counts = {"person": 0, "business": 0, "unclassified": 0, "errors": 0}
        skipped: List[Dict[str, Any]] = []
        qdrant_queue: List[Dict[str, Any]] = []

        for i, vcard_text in enumerate(vcard_texts, 1):
            if i % 100 == 0 or i == total:
                _log(f"  Hydrating contacts: {i}/{total}")

            try:
                parsed = parse_vcard(vcard_text)
            except Exception as exc:
                counts["errors"] += 1
                skipped.append({"uid": None, "fn": None, "stage": "parse", "error": str(exc)})
                continue

            uid_for_log = parsed.get("uid")
            fn_for_log = parsed.get("fn")

            try:
                contact_type = classify_contact(parsed)
                counts[contact_type] = counts.get(contact_type, 0) + 1

                if dry_run:
                    continue

                if contact_type == "business":
                    self._write_business_oxigraph(parsed)
                else:
                    # Clean person display names (emoji/symbol edge-strip +
                    # duplicate-token collapse) before seeding the node.
                    _cleaned = clean_display_name(parsed.get("fn") or "")
                    if _cleaned:
                        parsed["fn"] = _cleaned
                    person_id, person_uri = self._resolve_and_write_person(parsed, contact_type)
                    description = self._build_description(parsed)
                    qdrant_queue.append(
                        {
                            "person_id": person_id,
                            "person_uri": person_uri,
                            "parsed": parsed,
                            "description": description,
                        }
                    )
            except Exception as exc:
                counts["errors"] += 1
                skipped.append({
                    "uid": uid_for_log,
                    "fn": fn_for_log,
                    "stage": "write",
                    "error": f"{type(exc).__name__}: {exc}",
                })
                continue

        # Batch-embed + upsert Qdrant for people (mirrors sync()).
        if qdrant_queue and not dry_run:
            _log(f"Embedding {len(qdrant_queue)} person descriptions...")
            descriptions = [item["description"] for item in qdrant_queue]
            batch_size = self.cfg.EMBED_BATCH_SIZE
            all_vectors: List[List[float]] = []

            for batch_start in range(0, len(descriptions), batch_size):
                batch = descriptions[batch_start : batch_start + batch_size]
                vectors = self._embed_batch(batch)
                all_vectors.extend(vectors)

            for idx, item in enumerate(qdrant_queue):
                if idx < len(all_vectors):
                    self._upsert_qdrant(
                        person_id=item["person_id"],
                        person_uri=item["person_uri"],
                        parsed=item["parsed"],
                        vector=all_vectors[idx],
                    )

        imported = counts["person"] + counts["business"] + counts["unclassified"]
        _log(
            f"Hydration complete: {imported} imported "
            f"({counts['person']} people, {counts['business']} businesses, "
            f"{counts['unclassified']} unclassified), {len(skipped)} skipped."
        )
        return {
            "imported": imported,
            "skipped": len(skipped),
            "errors": skipped,
            "deleted": 0,
        }

    # -- helpers --------------------------------------------------------------

    @staticmethod
    def _read_child_values(
        conn: Any,
        *,
        table: str,
        owner_candidates: Tuple[str, ...],
        value_candidates: Tuple[str, ...],
        label: str,
    ) -> Dict[int, List[str]]:
        """Read a ``{owner_pk: [value, ...]}`` map from an AddressBook child
        table (e.g. ZABCDEMAILADDRESS, ZABCDPHONENUMBER).

        AddressBook child-table column names drift across macOS versions, so
        we introspect the table with PRAGMA and pick the first owner / value
        column that actually exists rather than hard-coding a single shape.

        Unlike the previous bare ``except OperationalError: pass`` this logs
        loudly when the table is missing or no value column resolves, so a
        silent phone-only export (the email-drop bug) surfaces in the log
        instead of looking like "this person just had no email".
        """
        import sqlite3 as _sqlite3

        out: Dict[int, List[str]] = {}
        try:
            cols = {
                row["name"]
                for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
            }
        except _sqlite3.OperationalError as exc:
            logger.warning(
                "AddressBook %s table absent or unreadable (%s); "
                "%s addresses will not reach the graph from this store.",
                table,
                exc,
                label,
            )
            return out

        if not cols:
            logger.warning(
                "AddressBook %s table has no columns; no %s values extracted.",
                table,
                label,
            )
            return out

        owner_col = next((c for c in owner_candidates if c in cols), None)
        # Select EVERY candidate value column that exists, not just the first.
        # The drift case is a present-but-NULL primary (e.g. ZADDRESS empty,
        # the address living in ZADDRESSNORMALIZED): picking the first column
        # that merely EXISTS would read the NULL and silently drop the address.
        # Per row we take the first NON-NULL/non-empty value across them, in
        # candidate order.
        value_cols = [c for c in value_candidates if c in cols]
        if not owner_col or not value_cols:
            logger.warning(
                "AddressBook %s missing expected columns "
                "(owner one of %s -> %s; value one of %s -> %s; present=%s). "
                "No %s values extracted from this store.",
                table,
                owner_candidates,
                owner_col,
                value_candidates,
                value_cols,
                sorted(cols),
                label,
            )
            return out

        select_cols = ", ".join(f"{c} as v{i}" for i, c in enumerate(value_cols))
        try:
            for row in conn.execute(
                f"SELECT {owner_col} as pk, {select_cols} FROM {table}"
            ).fetchall():
                pk = row["pk"]
                if pk is None:
                    continue
                # First non-NULL / non-empty value across the candidate
                # columns, in candidate order (e.g. ZADDRESS, then fall back
                # to ZADDRESSNORMALIZED when ZADDRESS is present-but-NULL).
                clean = ""
                for i in range(len(value_cols)):
                    val = row[f"v{i}"]
                    if val is None:
                        continue
                    candidate = str(val).strip()
                    if candidate:
                        clean = candidate
                        break
                if not clean:
                    continue
                bucket = out.setdefault(pk, [])
                # Skip case-insensitive duplicates (a card can carry the same
                # address under several labels); keep first-seen casing.
                if not any(clean.lower() == seen.lower() for seen in bucket):
                    bucket.append(clean)
        except _sqlite3.OperationalError as exc:
            logger.warning(
                "AddressBook %s read failed (%s); no %s values extracted.",
                table,
                exc,
                label,
            )
        return out

    def _read_abcddb_as_vcards(self) -> List[str]:
        """Read every populated AddressBook-v22.abcddb under ~/Library
        and synthesise minimal vCard 3.0 text per record so the existing
        vcard_parser path can ingest them.

        On macOS 15+ the iCloud account writes its contacts under
        ~/Library/Application Support/AddressBook/Sources/<UUID>/
        AddressBook-v22.abcddb. The top-level AddressBook-v22.abcddb
        only holds the local-only "On My Mac" address book and is
        usually near-empty (e.g. 2 rows on a fresh iCloud customer
        whose 2400 contacts live entirely under Sources/).

        Each ZABCDRECORD row has first/middle/last name, organisation,
        title, email addresses, phone numbers, postal addresses, and a
        UID. We pull those into vCard form. Anything we can't read is
        skipped silently so one corrupt source doesn't strand the rest.
        """
        import glob
        import sqlite3 as _sqlite3
        from pathlib import Path

        ab_root = Path.home() / "Library" / "Application Support" / "AddressBook"
        if not ab_root.exists():
            return []

        # Collect every abcddb. Walk Sources/ subdirs in addition to
        # the top-level file so per-account stores are unioned.
        db_paths: List[Path] = []
        top = ab_root / "AddressBook-v22.abcddb"
        if top.is_file() and top.stat().st_size > 0:
            db_paths.append(top)
        sources = ab_root / "Sources"
        if sources.is_dir():
            for p in sorted(sources.glob("*/AddressBook-v22.abcddb")):
                if p.is_file() and p.stat().st_size > 0:
                    db_paths.append(p)

        if not db_paths:
            return []

        vcards: List[str] = []
        for db_path in db_paths:
            try:
                conn = _sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
                conn.row_factory = _sqlite3.Row
            except _sqlite3.OperationalError as exc:
                logger.warning("Cannot open %s: %s", db_path, exc)
                continue
            try:
                # ZABCDRECORD columns vary across macOS versions; some
                # builds split birthday into year/month/day, others
                # store a single ZBIRTHDAY date. Detect what is
                # actually present before building the query so we
                # never blow up the whole DB read for one missing col.
                avail = set()
                try:
                    info = conn.execute(
                        "PRAGMA table_info(ZABCDRECORD)"
                    ).fetchall()
                    avail = {row["name"] for row in info}
                except _sqlite3.OperationalError as exc:
                    logger.warning("PRAGMA failed on %s: %s", db_path, exc)
                    conn.close()
                    continue
                if "Z_PK" not in avail or "ZUNIQUEID" not in avail:
                    logger.warning("ZABCDRECORD missing core cols in %s", db_path)
                    conn.close()
                    continue

                def _col(name: str, alias: str) -> str:
                    return f"{name} as {alias}" if name in avail else f"NULL as {alias}"

                sel = ", ".join([
                    _col("ZUNIQUEID", "uid"),
                    _col("ZFIRSTNAME", "first"),
                    _col("ZMIDDLENAME", "middle"),
                    _col("ZLASTNAME", "last"),
                    _col("ZORGANIZATION", "org"),
                    _col("ZJOBTITLE", "title"),
                    _col("ZNOTE", "note"),
                    _col("ZBIRTHDAYYEAR", "birth_year"),
                    _col("ZBIRTHDAYMONTH", "birth_month"),
                    _col("ZBIRTHDAYDAY", "birth_day"),
                    _col("ZBIRTHDAY", "birth_day_only"),
                    _col("Z_PK", "pk"),
                ])
                try:
                    rows = conn.execute(
                        f"SELECT {sel} FROM ZABCDRECORD"
                    ).fetchall()
                except _sqlite3.OperationalError as exc:
                    logger.warning("ZABCDRECORD read failed in %s: %s", db_path, exc)
                    conn.close()
                    continue

                # Pre-fetch emails + phones for all rows in this DB, then
                # group by parent PK. One pass each rather than N queries.
                #
                # The child link-tables (ZABCDEMAILADDRESS / ZABCDPHONENUMBER)
                # vary in column naming across macOS versions exactly like
                # ZABCDRECORD does, so we introspect each table and pick the
                # owner + value columns that are actually present instead of
                # hard-coding one shape. Hard-coding ZADDRESS was a silent
                # email drop: when iCloud's Sequoia store carried the address
                # only in ZADDRESSNORMALIZED (ZADDRESS NULL/absent), the fixed
                # query returned no usable rows and -- because the failure was
                # swallowed with a bare ``pass`` -- every Contacts card reached
                # the graph phone-only with zero log line. Phones never hit
                # this because ZFULLNUMBER is stable across the same versions,
                # which is why card->phone coverage was 97% while card->email
                # was ~1%. We now (a) try the known value-column candidates in
                # order, (b) log loudly if none resolve, so a phone-only export
                # can never silently ship again.
                emails_by_pk = self._read_child_values(
                    conn,
                    table="ZABCDEMAILADDRESS",
                    owner_candidates=("ZOWNER",),
                    value_candidates=("ZADDRESS", "ZADDRESSNORMALIZED"),
                    label="email",
                )

                phones_by_pk = self._read_child_values(
                    conn,
                    table="ZABCDPHONENUMBER",
                    owner_candidates=("ZOWNER",),
                    value_candidates=("ZFULLNUMBER", "ZLASTFOURDIGITS"),
                    label="phone",
                )

                def _s(v) -> str:
                    if v is None:
                        return ""
                    try:
                        return str(v).strip()
                    except Exception:
                        return ""

                for r in rows:
                    pk = r["pk"]
                    first = _s(r["first"])
                    middle = _s(r["middle"])
                    last = _s(r["last"])
                    org = _s(r["org"])
                    title = _s(r["title"])
                    note = _s(r["note"])
                    uid = _s(r["uid"])

                    name_parts = [p for p in (first, middle, last) if p]
                    fn = " ".join(name_parts) or org
                    if not fn:
                        continue  # Skip rows with no displayable identity.

                    lines = ["BEGIN:VCARD", "VERSION:3.0"]
                    lines.append(f"FN:{fn}")
                    # N: Last;First;Middle;;
                    lines.append(f"N:{last};{first};{middle};;")
                    if org:
                        lines.append(f"ORG:{org}")
                    if title:
                        lines.append(f"TITLE:{title}")
                    for em in emails_by_pk.get(pk, []):
                        lines.append(f"EMAIL;TYPE=INTERNET:{em}")
                    for ph in phones_by_pk.get(pk, []):
                        lines.append(f"TEL:{ph}")
                    if note:
                        # vCard NOTE wants newlines escaped.
                        escaped = note.replace("\\", "\\\\").replace("\n", "\\n")
                        lines.append(f"NOTE:{escaped}")
                    try:
                        by = r["birth_year"]
                        bm = r["birth_month"]
                        bd = r["birth_day"]
                    except (KeyError, IndexError):
                        by = bm = bd = None
                    if by and bm and bd:
                        try:
                            lines.append(
                                f"BDAY:{int(by):04d}-{int(bm):02d}-{int(bd):02d}"
                            )
                        except (TypeError, ValueError):
                            pass
                    else:
                        # Alternative schema: ZBIRTHDAY single
                        # NSDate (Cocoa epoch 2001-01-01).
                        try:
                            raw = r["birth_day_only"]
                        except (KeyError, IndexError):
                            raw = None
                        if raw:
                            try:
                                from datetime import datetime as _dt, timedelta as _td
                                cocoa = _dt(2001, 1, 1) + _td(seconds=float(raw))
                                lines.append(
                                    f"BDAY:{cocoa.year:04d}-{cocoa.month:02d}-{cocoa.day:02d}"
                                )
                            except (TypeError, ValueError):
                                pass
                    if uid:
                        lines.append(f"UID:{uid}")
                    lines.append("END:VCARD")
                    vcards.append("\n".join(lines))
            except Exception as exc:
                logger.warning("Failed to read contacts from %s: %s", db_path, exc)
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

        # Dedup across source DBs by UID. Without this, contacts that
        # appear in both the local-only AddressBook and an iCloud Source
        # would import twice.
        seen_uids: set = set()
        deduped: List[str] = []
        for vc in vcards:
            m = re.search(r"^UID:(.+)$", vc, re.MULTILINE)
            key = (m.group(1).strip() if m else vc[:200])
            if key in seen_uids:
                continue
            seen_uids.add(key)
            deduped.append(vc)
        return deduped

    def _build_description(
        self, parsed: Dict[str, Any], facts: Optional[List[str]] = None
    ) -> str:
        """Generate embeddable text description from parsed contact data."""
        parts: List[str] = []

        fn = parsed.get("fn") or ""
        if fn:
            parts.append(fn + ".")

        title = parsed.get("title") or ""
        org = parsed.get("org") or ""
        if title and org:
            parts.append(f"{title} at {org}.")
        elif org:
            parts.append(f"Works at {org}.")
        elif title:
            parts.append(f"{title}.")

        notes = parsed.get("notes") or ""
        if notes:
            # Truncate very long notes for embedding
            if len(notes) > 500:
                notes = notes[:500] + "..."
            parts.append(notes)

        if facts:
            for fact in facts:
                parts.append(fact)

        return " ".join(parts)

    def _embed_batch(self, texts: List[str]) -> List[List[float]]:
        """Batch embed texts via Ollama ``/api/embed`` endpoint."""
        resp = httpx.post(
            f"{self.cfg.EMBED_OLLAMA_URL}/api/embed",
            json={"model": self.cfg.EMBED_MODEL, "input": texts},
            timeout=120.0,
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get("embeddings", [])

    def _ensure_qdrant_collection(self, vector_size: int) -> None:
        """Create the Qdrant collection if it does not already exist.

        On a fresh single-Mac install nothing pre-creates the `people`
        collection before this syncer runs: install.sh's graph_db_start
        brings Qdrant up empty, the contact hydrate (hydrate_graph) is the
        FIRST writer to `people`, and Qdrant does not auto-create a
        collection on upsert. Without this self-create the very first
        upsert 404s ("Collection 'people' doesn't exist"), the hydrate
        dies after reading every contact, and the People surfaces (iOS
        People tab, Hub People card, wiki People page, semantic search)
        stay blank. The sibling people-ingest writer already self-creates
        (HR015 ostler_fda.pwg_ingest._qdrant_ensure_collection); the
        contact syncer must do the same (#638).

        Idempotent: an existing collection short-circuits, so a re-run, or
        a box where the people-ingest step created it first, never
        clobbers data. The vector size comes from the real embedding (with
        the nomic-embed-text default as a fallback) and the distance
        matches the install.sh #606 pre-create and the people-ingest path:
        768-dim, Cosine, unnamed vectors.
        """
        collection = self.cfg.QDRANT_COLLECTION
        try:
            if self.qdrant.collection_exists(collection):
                return
        except Exception:
            # Probe failed (transient Qdrant hiccup): fall through and try
            # to create. A redundant create on an existing collection is
            # tolerated below, so this cannot make things worse.
            pass

        from qdrant_client.models import Distance, VectorParams

        size = vector_size if vector_size and vector_size > 0 else 768
        try:
            self.qdrant.create_collection(
                collection_name=collection,
                vectors_config=VectorParams(size=size, distance=Distance.COSINE),
            )
            logger.info(
                "Created Qdrant collection '%s' (size=%d, Cosine).",
                collection, size,
            )
        except Exception:
            # Lost a create race, or it already existed: tolerate only if
            # the collection is now present; otherwise re-raise so a
            # genuine Qdrant failure still surfaces to the caller.
            if self.qdrant.collection_exists(collection):
                return
            raise

    def _upsert_qdrant(
        self,
        person_id: str,
        person_uri: str,
        parsed: Dict[str, Any],
        vector: List[float],
    ) -> None:
        """Upsert a single person point into Qdrant."""
        # Fresh-install self-heal: make sure the collection exists before
        # the first upsert of the run, sized from this real embedding.
        # Once per syncer run via the _collection_ensured latch (#638).
        if not getattr(self, "_collection_ensured", False):
            self._ensure_qdrant_collection(len(vector))
            self._collection_ensured = True
        now_iso = datetime.now(timezone.utc).isoformat()
        # last_contact: prefer the EXISTING value in Qdrant, set by
        # meetings or future conversation pipelines. For a brand-new
        # contact with no prior signal, leave the fields at the
        # sentinel values ("" / 0) - we have no actual contact-event
        # evidence.
        #
        # Historical bug (Lester demo, 2026-04-27): this branch used
        # to fall back to the vCard REV (the card's modification
        # timestamp) when no prior signal existed. REV is not a
        # contact event - it's "when the contact card was last
        # edited" - and when that timestamp is years old (common for
        # imported / migrated cards), the wiki's decay heuristic
        # tripped its 3-year "Lost touch" threshold on contacts who
        # had actually never been signal-tracked at all. The fix is
        # to leave the field empty so downstream consumers can treat
        # absence as absence:
        #   - /api/v1/people/stale already filters `last_contact_ts > 0`,
        #     so 0-valued records are correctly excluded from the
        #     stale-contacts digest.
        #   - The wiki decay heuristic
        #     (compiler/pages/person_pages.py::_relationship_strength)
        #     treats empty `last_contact` as "no signal" and emits
        #     "New" or no badge, not "Lost touch".
        last_contact_ts: int = 0
        last_contact: str = ""
        point_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, person_uri))
        try:
            existing = self.qdrant.retrieve(
                collection_name=self.cfg.QDRANT_COLLECTION,
                ids=[point_uuid],
                with_payload=True,
            )
            if existing and existing[0].payload:
                existing_ts = existing[0].payload.get("last_contact_ts") or 0
                existing_lc = existing[0].payload.get("last_contact") or ""
                if existing_ts:
                    last_contact_ts = existing_ts
                    last_contact = existing_lc
        except Exception:
            pass  # point doesn't exist yet, fine

        payload = {
            "person_id": person_id,
            "person_uri": person_uri,
            "display_name": parsed.get("fn") or "",
            "given_name": parsed.get("given_name") or "",
            "family_name": parsed.get("family_name") or "",
            "organization": parsed.get("org") or "",
            "job_title": parsed.get("title") or "",
            "phones": [p["value"] for p in parsed.get("phones", [])],
            "emails": [e["value"] for e in parsed.get("emails", [])],
            "icloud_uid": parsed.get("uid") or "",
            "profile_photo_path": parsed.get("profile_photo_path") or "",
            "contact_type": "person",
            "privacy_level": self.cfg.DEFAULT_PRIVACY_LEVEL,
            "source": "icloud_contacts",
            "last_contact": last_contact,
            "last_contact_ts": last_contact_ts,
            "created_at": now_iso,
            "updated_at": now_iso,
        }

        # Qdrant requires a full UUID or unsigned int as point ID.
        # Derive a deterministic UUID from person_id for stable upserts.
        point = PointStruct(
            id=point_uuid,
            vector=vector,
            payload=payload,
        )
        self.qdrant.upsert(
            collection_name=self.cfg.QDRANT_COLLECTION,
            points=[point],
        )

    def _resolve_and_write_person(
        self, parsed: Dict[str, Any], contact_type: str
    ) -> Tuple[str, str]:
        """Resolve identity, write person node to Oxigraph. Returns (person_id, person_uri)."""
        from identity_resolver.models import PersonIdentity

        phones = [p["value"] for p in parsed.get("phones", []) if p.get("value")]
        emails = [e["value"] for e in parsed.get("emails", []) if e.get("value")]

        identity = PersonIdentity(
            display_name=parsed.get("fn") or "",
            given_name=parsed.get("given_name") or "",
            family_name=parsed.get("family_name") or "",
            organization=parsed.get("org") or "",
            icloud_uid=parsed.get("uid") or "",
            phones=phones,
            emails=emails,
        )

        # Try identity resolution – use_fuzzy=False because the CardDAV path
        # has a strong identifier (iCloud UID). Fuzzy name matching is disabled
        # here to prevent first-name collisions (e.g. "Sandra Andersson" being
        # incorrectly merged into "Sandra Stewart" via Jaro-Winkler prefix
        # bonus). Fuzzy matching is still available to other callers that
        # explicitly opt in (e.g. WhatsApp / email ingest).
        match = self.resolver.resolve(identity, use_fuzzy=False)

        if match and match.person_uri:
            person_uri = match.person_uri
            # Extract person_id from URI
            person_id = person_uri.split("person_")[-1] if "person_" in person_uri else str(uuid.uuid4())
            self._persist_photo(person_uri, parsed)
            self._update_person_oxigraph(person_uri, parsed, contact_type)
        else:
            person_id = str(uuid.uuid4()).replace("-", "")[:12]
            person_uri = f"https://pwg.dev/ontology#person_{person_id}"
            self._persist_photo(person_uri, parsed)
            self._create_person_oxigraph(person_uri, person_id, parsed, contact_type)
            # Register the new person in the resolver's in-memory fuzzy index so
            # LATER rows in this SAME run dedupe against it. The candidate
            # snapshot is loaded once and frozen; without this a one-shot bulk
            # import mints a fresh node for every repeat of a name -- the root
            # cause of one-shot-import duplicates on a fresh install, which the
            # incrementally synced graph never hit (each daily run re-snapshots).
            self.resolver.register_person(
                person_uri,
                identity.display_name,
                org=identity.organization,
                linkedin_url=getattr(identity, "linkedin_url", None),
            )

        return person_id, person_uri

    def _persist_photo(self, person_uri: str, parsed: Dict[str, Any]) -> None:
        """Write the PHOTO payload (if any) to disk and annotate *parsed*.

        Side-effect: mutates ``parsed["profile_photo_path"]`` to the final
        path, or leaves it absent if the card had no photo. Failures are
        swallowed and logged – a broken image must not stop the rest of the
        contact record from syncing.
        """
        photo = parsed.get("photo")
        if not photo:
            return
        try:
            path = write_photo(
                person_uri=person_uri,
                data=photo["data"],
                ext=photo["ext"],
                base_dir=self.cfg.PHOTO_DIR,
            )
            parsed["profile_photo_path"] = path
        except Exception as exc:
            print(f"    (photo write failed for {person_uri}: {exc})")

    def _create_person_oxigraph(
        self,
        person_uri: str,
        person_id: str,
        parsed: Dict[str, Any],
        contact_type: str,
    ) -> None:
        """Insert a new Person node into Oxigraph via SPARQL UPDATE."""
        now = datetime.now(timezone.utc).isoformat()
        fn = (parsed.get("fn") or "").replace('"', '\\"')
        given = (parsed.get("given_name") or "").replace('"', '\\"')
        family = (parsed.get("family_name") or "").replace('"', '\\"')
        org = (parsed.get("org") or "").replace('"', '\\"')
        title = (parsed.get("title") or "").replace('"', '\\"')
        notes = (parsed.get("notes") or "").replace('"', '\\"').replace("\n", "\\n")
        birthday = parsed.get("birthday") or ""

        triples = [
            f"<{person_uri}> a pwg:Person",
            f'<{person_uri}> pwg:displayName "{fn}"',
            f'<{person_uri}> pwg:contactType "{contact_type}"',
            f'<{person_uri}> pwg:privacyLevel "{self.cfg.DEFAULT_PRIVACY_LEVEL}"',
            f'<{person_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
        ]
        if given:
            triples.append(f'<{person_uri}> pwg:givenName "{given}"')
        if family:
            triples.append(f'<{person_uri}> pwg:familyName "{family}"')
        if org:
            triples.append(f'<{person_uri}> pwg:organization "{org}"')
        if title:
            triples.append(f'<{person_uri}> pwg:jobTitle "{title}"')
        if notes:
            triples.append(f'<{person_uri}> pwg:notes "{notes}"')
        if birthday:
            triples.append(f'<{person_uri}> pwg:birthday "{birthday}"^^xsd:date')
        # foaf:img – file:// URI pointing at the locally-stored portrait.
        # FOAF is the de-facto vocabulary for person-to-depicting-image; we
        # use foaf:img (the primary image) rather than foaf:depiction (any
        # image containing the person). The value is a file URI because the
        # image lives on the owner's disk, not at a public URL.
        photo_path = parsed.get("profile_photo_path")
        if photo_path:
            triples.append(f"<{person_uri}> foaf:img <file://{photo_path}>")
        if self.cfg.USER_ID:
            triples.append(
                f"<{person_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{self.cfg.USER_ID}>"
            )

        # Identifiers
        id_triples: List[str] = []
        if parsed.get("uid"):
            id_uri = f"https://pwg.dev/ontology#id_{person_id}_icloud"
            triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
            id_triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
            id_triples.append(f'<{id_uri}> pwg:identifierType "icloud_contact_uid"')
            id_triples.append(
                f'<{id_uri}> pwg:identifierValue "{parsed["uid"]}"'
            )

        for idx, phone in enumerate(parsed.get("phones", [])):
            id_uri = f"https://pwg.dev/ontology#id_{person_id}_phone{idx}"
            # Store the NORMALISED value so it matches what the resolver's
            # find_by_identifier queries for. Previously this wrote the raw
            # vCard value (e.g. "+852 9681 6605") while the resolver looked up
            # the E.164 form ("+85296816605"), so Tier-1 exact-identifier dedup
            # never fired and every repeat minted a duplicate (BW-1).
            phone_value = normalise_phone(
                phone["value"], self.resolver.default_country_code
            )
            triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
            id_triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
            id_triples.append(f'<{id_uri}> pwg:identifierType "phone"')
            id_triples.append(
                f'<{id_uri}> pwg:identifierValue "{phone_value}"'
            )
            if phone.get("label"):
                id_triples.append(
                    f'<{id_uri}> pwg:identifierLabel "{phone["label"]}"'
                )

        for idx, email in enumerate(parsed.get("emails", [])):
            id_uri = f"https://pwg.dev/ontology#id_{person_id}_email{idx}"
            # Normalise (lower-case) to match the resolver's lookup form (BW-1).
            email_value = normalise_email(email["value"])
            triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
            id_triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
            id_triples.append(f'<{id_uri}> pwg:identifierType "email"')
            id_triples.append(
                f'<{id_uri}> pwg:identifierValue "{_escape_sparql(email_value)}"'
            )
            if email.get("label"):
                id_triples.append(
                    f'<{id_uri}> pwg:identifierLabel "{email["label"]}"'
                )

        all_triples = triples + id_triples
        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            "INSERT DATA {\n  " + " .\n  ".join(all_triples) + " .\n}"
        )
        self._sparql_update(sparql)

    def _update_person_oxigraph(
        self, person_uri: str, parsed: Dict[str, Any], contact_type: str
    ) -> None:
        """Update an existing person node in Oxigraph with changed fields.

        Updates mutable scalar properties (displayName/org/jobTitle/contactType)
        AND merges any new identifiers (iCloud UID, phones, emails) from the
        incoming vCard onto the existing node. Idempotent – adding an
        identifier that already exists is a no-op.
        """
        fn = (parsed.get("fn") or "").replace('"', '\\"')
        org = (parsed.get("org") or "").replace('"', '\\"')
        title = (parsed.get("title") or "").replace('"', '\\"')

        # Part A: delete-then-reinsert mutable scalar properties
        delete_preds = [
            "pwg:displayName",
            "pwg:organization",
            "pwg:jobTitle",
            "pwg:contactType",
            "foaf:img",
        ]
        for pred in delete_preds:
            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
                f"DELETE WHERE {{ <{person_uri}> {pred} ?o . }}"
            )
            self._sparql_update(sparql)

        triples = [f'<{person_uri}> pwg:contactType "{contact_type}"']
        if fn:
            triples.append(f'<{person_uri}> pwg:displayName "{fn}"')
        if org:
            triples.append(f'<{person_uri}> pwg:organization "{org}"')
        if title:
            triples.append(f'<{person_uri}> pwg:jobTitle "{title}"')
        photo_path = parsed.get("profile_photo_path")
        if photo_path:
            triples.append(f"<{person_uri}> foaf:img <file://{photo_path}>")

        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
        )
        self._sparql_update(sparql)

        # Part B: merge identifiers. Add any iCloud UID / phone / email that
        # isn't already registered on this node. Previously this path silently
        # discarded secondary identifiers on merged contacts.
        person_id = self._extract_person_id(person_uri)

        new_ids: List[Tuple[str, str, Optional[str]]] = []
        uid = parsed.get("uid")
        if uid:
            new_ids.append(("icloud_contact_uid", uid, None))
        for phone in parsed.get("phones", []):
            v = phone.get("value") if isinstance(phone, dict) else None
            if v:
                # Normalise to the resolver's lookup form so dedup matches (BW-1).
                v = normalise_phone(v, self.resolver.default_country_code)
                new_ids.append(("phone", v, phone.get("label") if isinstance(phone, dict) else None))
        for email in parsed.get("emails", []):
            v = email.get("value") if isinstance(email, dict) else None
            if v:
                v = normalise_email(v)
                new_ids.append(("email", v, email.get("label") if isinstance(email, dict) else None))

        for idx, (id_type, id_value, label) in enumerate(new_ids):
            if self._identifier_exists(person_uri, id_type, id_value):
                continue
            # Stable id_uri derived from person_id + type + hash of value so
            # we don't collide with existing identifier URIs.
            value_hash = uuid.uuid5(uuid.NAMESPACE_URL, f"{id_type}:{id_value}").hex[:8]
            id_uri = f"https://pwg.dev/ontology#id_{person_id}_{id_type}_{value_hash}"
            safe_val = id_value.replace("\\", "\\\\").replace('"', '\\"')
            id_triples = [
                f"<{person_uri}> pwg:hasIdentifier <{id_uri}>",
                f"<{id_uri}> a pwg:PersonIdentifier",
                f'<{id_uri}> pwg:identifierType "{id_type}"',
                f'<{id_uri}> pwg:identifierValue "{safe_val}"',
            ]
            if label:
                safe_label = label.replace("\\", "\\\\").replace('"', '\\"')
                id_triples.append(f'<{id_uri}> pwg:identifierLabel "{safe_label}"')
            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(id_triples) + " .\n}"
            )
            self._sparql_update(sparql)

    @staticmethod
    def _extract_person_id(person_uri: str) -> str:
        """Extract the short person_id from a person URI."""
        if "person_" in person_uri:
            return person_uri.split("person_")[-1]
        return uuid.uuid4().hex[:12]

    def _identifier_exists(self, person_uri: str, id_type: str, id_value: str) -> bool:
        """Check whether an identifier of the given type/value is already on this node."""
        safe_val = id_value.replace("\\", "\\\\").replace('"', '\\"')
        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "ASK {\n"
            f"  <{person_uri}> pwg:hasIdentifier ?id .\n"
            f'  ?id pwg:identifierType "{id_type}" ;\n'
            f'      pwg:identifierValue "{safe_val}" .\n'
            "}"
        )
        try:
            resp = httpx.post(
                f"{self.cfg.OXIGRAPH_URL}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json",
                },
                timeout=30.0,
            )
            resp.raise_for_status()
            return bool(resp.json().get("boolean", False))
        except Exception:
            return False

    def _write_business_oxigraph(self, parsed: Dict[str, Any]) -> None:
        """Write a BusinessContact node to Oxigraph (no Qdrant point)."""
        biz_id = str(uuid.uuid4()).replace("-", "")[:12]
        biz_uri = f"https://pwg.dev/ontology#business_{biz_id}"
        fn = (parsed.get("fn") or "").replace('"', '\\"')
        now = datetime.now(timezone.utc).isoformat()

        triples = [
            f"<{biz_uri}> a pwg:BusinessContact",
            f'<{biz_uri}> pwg:businessName "{fn}"',
            f'<{biz_uri}> pwg:privacyLevel "{self.cfg.DEFAULT_PRIVACY_LEVEL}"',
            f'<{biz_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
        ]

        # Add identifiers
        for idx, phone in enumerate(parsed.get("phones", [])):
            id_uri = f"https://pwg.dev/ontology#id_{biz_id}_phone{idx}"
            triples.append(f"<{biz_uri}> pwg:hasIdentifier <{id_uri}>")
            triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
            triples.append(f'<{id_uri}> pwg:identifierType "phone"')
            triples.append(f'<{id_uri}> pwg:identifierValue "{phone["value"]}"')

        for idx, email in enumerate(parsed.get("emails", [])):
            id_uri = f"https://pwg.dev/ontology#id_{biz_id}_email{idx}"
            triples.append(f"<{biz_uri}> pwg:hasIdentifier <{id_uri}>")
            triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
            triples.append(f'<{id_uri}> pwg:identifierType "email"')
            triples.append(f'<{id_uri}> pwg:identifierValue "{email["value"]}"')

        if self.cfg.USER_ID:
            triples.append(
                f"<{biz_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{self.cfg.USER_ID}>"
            )

        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
        )
        self._sparql_update(sparql)

    # -- deletion -------------------------------------------------------------

    @staticmethod
    def _candidate_uids_from_href(href: str) -> List[str]:
        """Extract possible UIDs from a CardDAV href.

        iCloud CardDAV hrefs look like ``/.../card/<filename>.vcf``. The filename
        is a raw UUID for contacts added outside iCloud, but a base64-encoded
        UUID for iCloud-generated contacts. Return both so lookup covers both
        cases without us knowing which format the originally-imported UID used.
        """
        m = re.search(r"/card/([^/]+)\.vcf$", href)
        if not m:
            return []
        raw = m.group(1)
        candidates = {raw}
        # Try base64 decode
        try:
            # iCloud uses URL-safe-ish base64; standard decoder works for most
            padding = "=" * (-len(raw) % 4)
            decoded = base64.b64decode(raw + padding).decode("ascii", errors="ignore")
            if _UUID_RE.match(decoded):
                candidates.add(decoded)
        except Exception:
            pass
        return list(candidates)

    def _sparql_query(self, sparql: str) -> Dict[str, Any]:
        """Execute a SPARQL SELECT against Oxigraph."""
        resp = httpx.post(
            f"{self.cfg.OXIGRAPH_URL}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
            timeout=30.0,
        )
        resp.raise_for_status()
        return resp.json()

    def _find_nodes_by_icloud_uid(self, uids: List[str]) -> List[str]:
        """Return list of node URIs (Person or BusinessContact) matching any UID."""
        if not uids:
            return []
        values = " ".join(f'"{u}"' for u in uids)
        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "SELECT DISTINCT ?node WHERE {\n"
            "  ?node pwg:hasIdentifier ?id .\n"
            '  ?id pwg:identifierType "icloud_contact_uid" ;\n'
            "      pwg:identifierValue ?v .\n"
            f"  VALUES ?v {{ {values} }}\n"
            "}"
        )
        try:
            data = self._sparql_query(sparql)
            return [b["node"]["value"] for b in data.get("results", {}).get("bindings", [])]
        except Exception as exc:
            print(f"    (lookup failed: {exc})")
            return []

    def _delete_node_full(self, node_uri: str) -> None:
        """Delete a Person/BusinessContact and all its dependents.

        Removes: the node itself, its identifiers, its facts, meeting-attendee
        back-links, and the corresponding Qdrant point.
        """
        # Oxigraph: delete the node + everything it hasIdentifier/hasFact on,
        # plus anything referencing it as attendee.
        sparql = f"""
PREFIX pwg: <https://pwg.dev/ontology#>
DELETE {{
  <{node_uri}> ?p1 ?o1 .
  ?ident ?p2 ?o2 .
  ?fact  ?p3 ?o3 .
  ?meeting pwg:hasAttendee <{node_uri}> .
}}
WHERE {{
  {{ <{node_uri}> ?p1 ?o1 }}
  UNION
  {{ <{node_uri}> pwg:hasIdentifier ?ident . ?ident ?p2 ?o2 }}
  UNION
  {{ <{node_uri}> pwg:hasFact ?fact . ?fact ?p3 ?o3 }}
  UNION
  {{ ?meeting pwg:hasAttendee <{node_uri}> }}
}}
"""
        self._sparql_update(sparql)

        # Qdrant: delete by payload filter on person_uri
        try:
            from qdrant_client.models import Filter, FieldCondition, MatchValue, FilterSelector
            self.qdrant.delete(
                collection_name=self.cfg.QDRANT_COLLECTION,
                points_selector=FilterSelector(
                    filter=Filter(
                        must=[FieldCondition(key="person_uri", match=MatchValue(value=node_uri))]
                    )
                ),
            )
        except Exception as exc:
            # Not fatal – business contacts never had a Qdrant point
            print(f"    (Qdrant delete skipped for {node_uri}: {exc})")

        # Photo file: aligns with GDPR erasure – delete any portrait on disk
        try:
            remove_photo(node_uri, self.cfg.PHOTO_DIR)
        except Exception as exc:
            print(f"    (photo unlink skipped for {node_uri}: {exc})")

    def _process_deletions(self, deleted_hrefs: List[str]) -> int:
        """Delete contacts whose hrefs disappeared from CardDAV.

        Returns the number of Oxigraph nodes actually removed.
        """
        if not deleted_hrefs:
            return 0

        print(f"\nProcessing {len(deleted_hrefs)} deletion(s)...")
        removed = 0
        seen_nodes: Set[str] = set()

        for href in deleted_hrefs:
            uids = self._candidate_uids_from_href(href)
            if not uids:
                print(f"  SKIP: cannot extract UID from {href!r}")
                continue

            nodes = self._find_nodes_by_icloud_uid(uids)
            if not nodes:
                print(f"  SKIP: no Oxigraph node found for href {href} (uids={uids})")
                continue

            for node_uri in nodes:
                if node_uri in seen_nodes:
                    continue
                seen_nodes.add(node_uri)
                try:
                    self._delete_node_full(node_uri)
                    removed += 1
                    print(f"  DELETED {node_uri}")
                except Exception as exc:
                    print(f"  ERROR deleting {node_uri}: {exc}")

        print(f"Deletion summary: removed {removed} node(s) from {len(deleted_hrefs)} href(s).")
        return removed

    def _sparql_update(self, sparql: str) -> None:
        """Execute a SPARQL UPDATE against Oxigraph."""
        resp = httpx.post(
            f"{self.cfg.OXIGRAPH_URL}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
            timeout=30.0,
        )
        resp.raise_for_status()


# -- CLI ----------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Sync contacts from CardDAV into the PWG People Graph."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Limit the number of contacts to process.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse and classify contacts without writing to storage.",
    )
    parser.add_argument(
        "--dedup",
        action="store_true",
        help="Run duplicate detection report after sync.",
    )
    parser.add_argument(
        "--vcf",
        type=str,
        default=None,
        help=(
            "Path to a vCard file (multi-vCard concatenation, e.g. an iCloud "
            "Contacts export). When given, the CardDAV path is skipped and "
            "contacts are read from this file. Used by CM051 install.sh's "
            "hydrate_graph sub-phase (CX-81 B1)."
        ),
    )
    parser.add_argument(
        "--graph-endpoint",
        type=str,
        default=None,
        help=(
            "Override the Oxigraph URL the syncer writes to. Equivalent to "
            "setting the OXIGRAPH_URL environment variable but explicit on "
            "the command line. Other backends (Qdrant, embed model) still "
            "come from env vars / config.py."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help=(
            "Emit a single-line JSON status dict on stdout when the run "
            "completes ({\"imported\": N, \"skipped\": N, \"errors\": [...]}). "
            "Implied when --vcf is given so install-time callers can pipe "
            "the count into a customer-facing message. Progress lines for "
            "the vcf path are routed to stderr."
        ),
    )
    args = parser.parse_args()

    # Apply --graph-endpoint by mutating the config module so any code that
    # reads config.OXIGRAPH_URL after this point picks up the override.
    # ContactSyncer reads it inside __init__, so this must happen first.
    if args.graph_endpoint:
        config.OXIGRAPH_URL = args.graph_endpoint

    syncer = ContactSyncer()
    if args.vcf:
        result = syncer.sync_from_vcf(vcf_path=args.vcf, dry_run=args.dry_run)
    else:
        result = syncer.sync(limit=args.limit, dry_run=args.dry_run)

    if args.dedup and not args.dry_run and not args.vcf:
        print("\nRunning duplicate detection...")
        detector = DedupDetector(config.OXIGRAPH_URL)
        report = detector.detect()
        print_report(report)

    # Single-line JSON status on stdout when requested or when reading from
    # a vCard file. install.sh's hydrate_graph step parses this with `jq`.
    if args.json or args.vcf:
        print(json.dumps(result or {"imported": 0, "skipped": 0, "errors": []}))


if __name__ == "__main__":
    main()
