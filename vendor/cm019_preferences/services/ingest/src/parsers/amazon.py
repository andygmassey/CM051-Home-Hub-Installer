"""Amazon data parser."""

import csv
import json
import logging
from collections import defaultdict
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any
from datetime import datetime
import aiofiles
import zipfile
import tempfile

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class AmazonParser(BaseParser):
    """
    Parser for Amazon data exports.

    Handles:
    - Order history (Retail.OrderHistory.*.csv)
    - Digital orders
    - Cart items
    - Product reviews (if available)
    - Search history
    """

    source_name = "amazon"

    SUPPORTED_PATTERNS = [
        "retail.orderhistory",
        "retail.cartitems",
        "digital-ordering",
        "digital items",
        "digital orders",
        "search history"
    ]

    # Prime Video patterns
    PRIME_VIDEO_PATTERNS = [
        "primevideo.viewcounts",
        "digitalvideo.search"
    ]

    # Kindle-specific patterns
    KINDLE_PATTERNS = [
        "digital.content.ownership",
        "kindle.devices.readingsession",
        "whispersync"
    ]

    # Origin types to include for Kindle ownership (exclude dictionaries and user guides)
    KINDLE_VALID_ORIGINS = ["Purchase", "PDocs", "Sample"]

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is an Amazon data export."""
        if file_path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any(
                        any(pattern in n for pattern in self.SUPPORTED_PATTERNS)
                        for n in names
                    )
            except Exception:
                return False

        name = file_path.name.lower()

        # Standard Amazon CSV files
        if file_path.suffix.lower() == ".csv":
            if any(pattern in name for pattern in self.SUPPORTED_PATTERNS):
                return True
            # Kindle CSV files
            if any(pattern in name for pattern in self.KINDLE_PATTERNS):
                return True
            # Prime Video CSV files
            if any(pattern in name for pattern in self.PRIME_VIDEO_PATTERNS):
                return True

        # Kindle ownership JSON files
        if file_path.suffix.lower() == ".json":
            if "digital.content.ownership" in name:
                return True

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Amazon data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == ".json":
            # Kindle ownership JSON files
            if "digital.content.ownership" in file_path.name.lower():
                async for pref in self._parse_kindle_ownership_json(file_path, default_compartment):
                    yield pref
        else:
            async for pref in self._parse_csv(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse an Amazon data export zip file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            # Find and process order history files
            tmpdir_path = Path(tmpdir)
            for pattern in self.SUPPORTED_PATTERNS:
                for file in tmpdir_path.rglob("*.csv"):
                    if any(p in file.name.lower() for p in self.SUPPORTED_PATTERNS):
                        async for pref in self._parse_csv(file, default_compartment):
                            yield pref

    async def _parse_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single Amazon CSV file."""
        file_name = file_path.name.lower()

        if "orderhistory" in file_name or "digital orders" in file_name:
            async for pref in self._parse_order_history(file_path, default_compartment):
                yield pref
        elif "cartitems" in file_name:
            async for pref in self._parse_cart_items(file_path, default_compartment):
                yield pref
        elif "search history" in file_name:
            async for pref in self._parse_search_history(file_path, default_compartment):
                yield pref
        elif "readingsession" in file_name:
            async for pref in self._parse_kindle_reading_sessions(file_path, default_compartment):
                yield pref
        elif "whispersync" in file_name:
            async for pref in self._parse_kindle_whispersync(file_path, default_compartment):
                yield pref
        # Prime Video files
        elif "primevideo.viewcounts" in file_name:
            async for pref in self._parse_prime_video_viewcounts(file_path, default_compartment):
                yield pref
        elif "digitalvideo.search" in file_name:
            async for pref in self._parse_prime_video_search(file_path, default_compartment):
                yield pref

    async def _parse_order_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Amazon order history CSV.

        Each completed order item represents a purchase preference.
        Cancelled orders are skipped.
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            # Parse CSV
            reader = csv.DictReader(content.splitlines())

            for row in reader:
                try:
                    order_status = row.get('Order Status', '').strip()

                    # Skip cancelled orders
                    if order_status.lower() == 'cancelled':
                        continue

                    # Skip if no product name
                    product_name = row.get('Product Name', '').strip()
                    if not product_name or product_name == 'Not Available':
                        continue

                    # Parse order date
                    order_date_str = row.get('Order Date', '')
                    observed_at = None
                    if order_date_str:
                        try:
                            observed_at = datetime.fromisoformat(order_date_str.replace('Z', '+00:00'))
                        except Exception:
                            pass

                    # Extract details
                    asin = row.get('ASIN', '').strip()
                    website = row.get('Website', 'Amazon.com').strip()
                    quantity = int(row.get('Quantity', '1') or 1)
                    condition = row.get('Product Condition', 'New').strip()

                    # Determine if it's a gift
                    gift_message = row.get('Gift Message', '')
                    gift_sender = row.get('Gift Sender Name', '')
                    is_gift = (gift_message and gift_message != 'Not Available') or \
                              (gift_sender and gift_sender != 'Not Available')

                    # V2: Calculate preference strength (bipolar scale)
                    # Base: 0.40 for completed purchases
                    # +0.05 if quantity > 1 (bought multiple)
                    # +0.05 if it's a gift (shows strong preference to give)
                    strength = 0.40
                    if quantity > 1:
                        strength += 0.05
                    if is_gift:
                        strength += 0.05
                    strength = min(strength, 0.55)  # V2: Cap purchases

                    # Determine category from product name (simple heuristic)
                    category = self._categorize_product(product_name)

                    # Create preference
                    pref = ParsedPreference(
                        subject=f"Purchased {product_name}" + (f" ({quantity}x)" if quantity > 1 else ""),
                        preference_type="Like",
                        strength=strength,
                        compartment_level=default_compartment,
                        source=self.source_name,
                        source_id=asin if asin else None,
                        category=category,
                        observed_at=observed_at,
                        size="Medium",
                        extra={
                            "website": website,
                            "asin": asin,
                            "quantity": quantity,
                            "condition": condition,
                            "is_gift": is_gift,
                            "order_status": order_status
                        }
                    )

                    yield pref

                except Exception as e:
                    logger.warning(f"Failed to parse order row: {e}")
                    continue

        except Exception as e:
            logger.error(f"Failed to parse order history file {file_path}: {e}")

    async def _parse_cart_items(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Amazon cart items CSV.

        Cart items represent purchase intent - products actively saved for later.
        Stronger signal than search, weaker than actual purchase.
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())

            for row in reader:
                try:
                    # Get product name
                    product_name = row.get('ProductName', '').strip()
                    if not product_name:
                        continue

                    # Clean product name (remove " [Product name associated with ASIN]" suffix)
                    if '[Product name associated with ASIN]' in product_name:
                        product_name = product_name.replace(' [Product name associated with ASIN]', '')

                    # Parse date added to cart
                    date_str = row.get('DateAddedToCart', '')
                    observed_at = None
                    if date_str:
                        try:
                            observed_at = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
                        except Exception:
                            pass

                    # Check cart list status (active vs saved)
                    cart_list = row.get('CartList', '').lower()
                    is_saved = cart_list == 'saved'

                    # V2: Cart items indicate intent
                    # Base: 0.15 for active cart, 0.18 for saved-for-later (more deliberate)
                    strength = 0.18 if is_saved else 0.15

                    # Extract other details
                    asin = row.get('ASIN', '').strip()
                    quantity = int(row.get('Quantity', '1') or 1)

                    if quantity > 1:
                        strength += 0.02  # Multiple quantity shows stronger intent

                    # Categorize product
                    category = self._categorize_product(product_name)

                    pref = ParsedPreference(
                        subject=product_name,
                        preference_type="Like",
                        strength=min(strength, 0.25),  # V2: Cap cart items
                        compartment_level=default_compartment,
                        source=self.source_name,
                        observed_at=observed_at,
                        category=category,
                        size="Small",
                        extra={
                            "asin": asin,
                            "quantity": quantity,
                            "cart_status": cart_list,
                            "intent": True
                        }
                    )

                    yield pref

                except Exception as e:
                    logger.warning(f"Failed to parse cart item row: {e}")
                    continue

        except Exception as e:
            logger.error(f"Failed to parse cart items file {file_path}: {e}")

    async def _parse_search_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Amazon search history CSV.

        Search queries indicate interest/intent, but weaker than purchases.
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())

            for row in reader:
                try:
                    search_query = row.get('Search Query', '').strip()
                    if not search_query:
                        continue

                    # Parse timestamp
                    timestamp_str = row.get('Time', '')
                    observed_at = None
                    if timestamp_str:
                        try:
                            observed_at = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
                        except Exception:
                            pass

                    # V2: Search queries are weak signals but still signals
                    strength = 0.08

                    # Categorize search query
                    category = self._categorize_product(search_query)

                    pref = ParsedPreference(
                        subject=f"Searched for: {search_query}",
                        preference_type="Like",  # V2: Weak positive
                        strength=strength,
                        compartment_level=default_compartment,
                        source=self.source_name,
                        category=category,
                        observed_at=observed_at,
                        size="Micro",
                        extra={
                            "query": search_query,
                            "type": "search"
                        }
                    )

                    yield pref

                except Exception as e:
                    logger.warning(f"Failed to parse search row: {e}")
                    continue

        except Exception as e:
            logger.error(f"Failed to parse search history file {file_path}: {e}")

    def _categorize_product(self, product_text: str) -> str:
        """
        Simple category detection based on keywords.

        This is a heuristic approach - could be enhanced with ML classification.
        """
        text_lower = product_text.lower()

        # Electronics & Tech
        if any(word in text_lower for word in ['raspberry pi', 'arduino', 'usb', 'cable', 'charger',
                                                 'laptop', 'computer', 'phone', 'tablet', 'camera',
                                                 'speaker', 'headphone', 'bluetooth', 'wifi', 'router',
                                                 'ssd', 'hard drive', 'memory', 'cpu', 'gpu']):
            return 'electronics'

        # Books & Reading
        if any(word in text_lower for word in ['book', 'kindle', 'paperback', 'hardcover', 'novel',
                                                 'biography', 'cookbook']):
            return 'books'

        # Home & Kitchen
        if any(word in text_lower for word in ['kitchen', 'cooking', 'pan', 'pot', 'knife', 'blender',
                                                 'furniture', 'lamp', 'bedding', 'towel', 'pillow',
                                                 'curtain', 'rug', 'shelf']):
            return 'home'

        # Health & Personal Care
        if any(word in text_lower for word in ['toothbrush', 'shampoo', 'soap', 'vitamin', 'supplement',
                                                 'fitness', 'yoga', 'exercise', 'health', 'medical']):
            return 'health'

        # Fashion & Clothing
        if any(word in text_lower for word in ['shirt', 'pants', 'dress', 'shoes', 'jacket', 'coat',
                                                 'hat', 'gloves', 'socks', 'clothing', 'fashion']):
            return 'fashion'

        # Sports & Outdoors
        if any(word in text_lower for word in ['sports', 'outdoor', 'camping', 'hiking', 'fishing',
                                                 'bike', 'bicycle', 'swimming', 'goggles', 'gym']):
            return 'sports'

        # Music & Instruments
        if any(word in text_lower for word in ['guitar', 'piano', 'drum', 'music', 'instrument',
                                                 'pick', 'string', 'amplifier', 'microphone']):
            return 'music'

        # Toys & Games
        if any(word in text_lower for word in ['toy', 'game', 'puzzle', 'lego', 'board game',
                                                 'playing cards', 'children']):
            return 'toys'

        # Default
        return 'shopping'

    # ==================== KINDLE PARSERS ====================

    async def _parse_kindle_ownership_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse a single Kindle Digital.Content.Ownership JSON file.

        Each JSON file contains one book's ownership information.
        Origin types:
        - Purchase: Bought books (strong signal)
        - PDocs: Personal documents sent to Kindle (medium signal)
        - Sample: Book samples (weak signal - indicates interest)
        - KindleDictionary, KindleUserGuide: Skip (not preference signals)
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
                content = await f.read()

            data = json.loads(content)

            # Extract resource info
            resource = data.get('resource', {})
            product_name = resource.get('productName', resource.get('Product Name', ''))
            asin = resource.get('asin', resource.get('ASIN', ''))

            # Skip if no product name or it's "Not Available"
            if not product_name or product_name == 'Not Available':
                return

            # Get rights info
            rights = data.get('rights', [])
            if not rights:
                return

            first_right = rights[0]
            origin = first_right.get('origin', {})
            origin_type = origin.get('originType', '')

            # Skip non-book content (dictionaries, user guides)
            if origin_type not in self.KINDLE_VALID_ORIGINS:
                return

            # Parse acquisition date
            acquired_date_str = first_right.get('acquiredDate', '')
            observed_at = None
            if acquired_date_str:
                try:
                    observed_at = datetime.fromisoformat(acquired_date_str.replace('Z', '+00:00'))
                except Exception:
                    pass

            # V2: Determine strength based on origin type
            if origin_type == 'Purchase':
                strength = 0.45  # V2: Paid for the book
                preference_type = "Like"
                data_type = "kindle_purchase"
            elif origin_type == 'PDocs':
                strength = 0.25  # V2: Sent personal document
                preference_type = "Like"
                data_type = "kindle_document"
            else:  # Sample
                strength = 0.15  # V2: Curious
                preference_type = "Like"
                data_type = "kindle_sample"

            # Clean up product name (remove series info in parentheses for cleaner subject)
            clean_name = product_name

            pref = ParsedPreference(
                subject=clean_name,
                preference_type=preference_type,
                strength=strength,
                compartment_level=default_compartment,
                source="kindle",
                source_id=asin,
                category="book",
                observed_at=observed_at,
                size="Medium",
                extra={
                    "data_type": data_type,
                    "origin_type": origin_type,
                    "asin": asin,
                    "resource_type": resource.get('resourceType', ''),
                    "right_status": first_right.get('rightStatus', '')
                }
            )

            yield pref

        except json.JSONDecodeError as e:
            logger.warning(f"Invalid JSON in Kindle ownership file {file_path}: {e}")
        except Exception as e:
            logger.error(f"Failed to parse Kindle ownership file {file_path}: {e}")

    async def _parse_kindle_reading_sessions(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Kindle reading session CSV.

        Contains reading time data per book. We aggregate by ASIN to get
        total reading time, which indicates engagement strength.
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())

            # Aggregate reading time by ASIN
            reading_stats: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
                'total_millis': 0,
                'session_count': 0,
                'page_flips': 0,
                'content_type': '',
                'first_session': None,
                'last_session': None
            })

            for row in reader:
                try:
                    asin = row.get('ASIN', '').strip()
                    content_type = row.get('content_type', '').strip()

                    # Skip rows without ASIN (personal documents, etc.)
                    if not asin:
                        continue

                    # Skip samples - we track those via ownership
                    if content_type == 'E-Book Sample':
                        continue

                    # Parse reading time
                    reading_millis = int(row.get('total_reading_millis', '0') or 0)
                    page_flips = int(row.get('number_of_page_flips', '0') or 0)

                    # Parse timestamps
                    start_str = row.get('start_timestamp', '')
                    if start_str and start_str != 'Not Available':
                        try:
                            start_time = datetime.fromisoformat(start_str.replace('Z', '+00:00'))
                            if reading_stats[asin]['first_session'] is None or \
                               start_time < reading_stats[asin]['first_session']:
                                reading_stats[asin]['first_session'] = start_time
                            if reading_stats[asin]['last_session'] is None or \
                               start_time > reading_stats[asin]['last_session']:
                                reading_stats[asin]['last_session'] = start_time
                        except Exception:
                            pass

                    # Accumulate stats
                    reading_stats[asin]['total_millis'] += reading_millis
                    reading_stats[asin]['session_count'] += 1
                    reading_stats[asin]['page_flips'] += page_flips
                    reading_stats[asin]['content_type'] = content_type

                except Exception as e:
                    logger.warning(f"Failed to parse reading session row: {e}")
                    continue

            # Yield aggregated reading activity per book
            for asin, stats in reading_stats.items():
                total_minutes = stats['total_millis'] / 60000

                # Only yield if meaningful reading time (> 1 minute)
                if total_minutes < 1:
                    continue

                # V2: Calculate strength based on reading time
                # 0-10 min: 0.15, 10-30 min: 0.25, 30-60 min: 0.35, 1-3 hr: 0.45, 3+ hr: 0.50
                if total_minutes < 10:
                    strength = 0.15
                elif total_minutes < 30:
                    strength = 0.25
                elif total_minutes < 60:
                    strength = 0.35
                elif total_minutes < 180:
                    strength = 0.45
                else:
                    strength = 0.50

                pref = ParsedPreference(
                    subject=f"Read Kindle book (ASIN: {asin})",
                    preference_type="Experience",
                    strength=strength,
                    compartment_level=default_compartment,
                    source="kindle",
                    source_id=asin,
                    category="book",
                    observed_at=stats['last_session'],
                    size="Medium",
                    extra={
                        "data_type": "kindle_reading_activity",
                        "asin": asin,
                        "total_reading_minutes": round(total_minutes, 1),
                        "session_count": stats['session_count'],
                        "page_flips": stats['page_flips'],
                        "first_session": stats['first_session'].isoformat() if stats['first_session'] else None,
                        "last_session": stats['last_session'].isoformat() if stats['last_session'] else None
                    }
                )

                yield pref

            logger.info(f"Parsed reading sessions for {len(reading_stats)} books from {file_path}")

        except Exception as e:
            logger.error(f"Failed to parse Kindle reading sessions file {file_path}: {e}")

    async def _parse_kindle_whispersync(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Kindle Whispersync CSV for annotations, highlights, and notes.

        This file contains:
        - kindle.highlight: Highlighted passages
        - kindle.note: User notes
        - kindle.continuous_read, kindle.most_recent_read, kindle.last_read: Reading progress

        Yields:
        1. Aggregated annotation preferences per book (strength based on annotation count)
        2. Individual note preferences (each note as a Micro insight)
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())

            # Aggregate annotations by ASIN
            book_annotations: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
                'product_name': '',
                'highlights': 0,
                'notes': [],
                'has_reading_progress': False,
                'last_modified': None
            })

            # Store individual notes with context for separate preferences
            individual_notes: list = []

            for row in reader:
                try:
                    asin = row.get('ASIN', '').strip()
                    if not asin:
                        continue

                    product_name = row.get('Product Name', '').strip()
                    annotation_type = row.get('Annotation Type', '').strip()
                    note_content = row.get('Note', '').strip()
                    is_deleted = row.get('Is Deleted', 'No').strip().lower() == 'yes'

                    # Skip deleted annotations
                    if is_deleted:
                        continue

                    # Store product name
                    if product_name and product_name != 'Not Available':
                        book_annotations[asin]['product_name'] = product_name

                    # Parse modification date
                    modified_str = row.get('Customer modified date on device', '')
                    modified = None
                    if modified_str and modified_str != 'Not Available':
                        try:
                            modified = datetime.fromisoformat(modified_str.replace('Z', '+00:00'))
                            if book_annotations[asin]['last_modified'] is None or \
                               modified > book_annotations[asin]['last_modified']:
                                book_annotations[asin]['last_modified'] = modified
                        except Exception:
                            pass

                    # Count annotation types
                    if annotation_type == 'kindle.highlight':
                        book_annotations[asin]['highlights'] += 1
                    elif annotation_type == 'kindle.note':
                        if note_content and note_content != 'Not Available':
                            book_annotations[asin]['notes'].append(note_content)
                            # Store individual note with context
                            individual_notes.append({
                                'note': note_content,
                                'asin': asin,
                                'product_name': product_name if product_name and product_name != 'Not Available' else None,
                                'observed_at': modified
                            })
                    elif annotation_type in ('kindle.continuous_read', 'kindle.most_recent_read', 'kindle.last_read'):
                        book_annotations[asin]['has_reading_progress'] = True

                except Exception as e:
                    logger.warning(f"Failed to parse whispersync row: {e}")
                    continue

            # Yield aggregated annotation preferences per book
            for asin, data in book_annotations.items():
                product_name = data['product_name']
                if not product_name:
                    product_name = f"Kindle book (ASIN: {asin})"

                highlights = data['highlights']
                notes = data['notes']
                total_annotations = highlights + len(notes)

                # Only yield if there are actual annotations (not just reading progress)
                if total_annotations == 0:
                    continue

                # V2: Calculate strength based on annotation count
                # 1-2 annotations: 0.35, 3-5: 0.42, 6-10: 0.48, 10+: 0.52
                if total_annotations <= 2:
                    strength = 0.35
                elif total_annotations <= 5:
                    strength = 0.42
                elif total_annotations <= 10:
                    strength = 0.48
                else:
                    strength = 0.52

                pref = ParsedPreference(
                    subject=f"Annotated: {product_name}",
                    preference_type="Like",
                    strength=strength,
                    compartment_level=default_compartment,
                    source="kindle",
                    source_id=asin,
                    category="book",
                    observed_at=data['last_modified'],
                    size="Medium",
                    extra={
                        "data_type": "kindle_annotation",
                        "asin": asin,
                        "highlight_count": highlights,
                        "note_count": len(notes),
                        "notes_preview": notes[:3] if notes else [],  # First 3 notes as preview
                        "has_reading_progress": data['has_reading_progress']
                    }
                )

                yield pref

            # Yield individual note preferences
            # Each note represents an insight/thought the user captured while reading
            for note_data in individual_notes:
                note_text = note_data['note']
                asin = note_data['asin']
                book_name = note_data['product_name'] or book_annotations[asin]['product_name'] or f"ASIN:{asin}"

                pref = ParsedPreference(
                    subject=note_text,
                    preference_type="Like",
                    strength=0.40,  # V2: User took time to write - meaningful
                    compartment_level=default_compartment,
                    source="kindle",
                    source_id=f"{asin}:note:{hash(note_text) % 100000}",
                    category="insight",
                    observed_at=note_data['observed_at'],
                    size="Micro",
                    extra={
                        "data_type": "kindle_note",
                        "asin": asin,
                        "book_title": book_name,
                        "note_text": note_text
                    }
                )

                yield pref

            annotated_books = len([a for a in book_annotations.values() if a['highlights'] + len(a['notes']) > 0])
            logger.info(f"Parsed {annotated_books} annotated books and {len(individual_notes)} individual notes from {file_path}")

        except Exception as e:
            logger.error(f"Failed to parse Kindle whispersync file {file_path}: {e}")

    # ==================== PRIME VIDEO PARSERS ====================

    async def _parse_prime_video_viewcounts(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Prime Video ViewCounts CSV for aggregate viewing statistics.

        Note: This file contains aggregate counts only, not individual titles.
        Useful for creating summary preferences about viewing habits.

        Columns include:
        - Number of TV shows watched
        - Number of movies watched
        - Number of kids titles watched
        - Number of prime titles watched
        - Number of rent/buy titles watched
        - Number of titles added to watchlist
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())

            for row in reader:
                try:
                    # Parse viewing counts
                    tv_shows = int(row.get('Number of TV shows watched', '0') or 0)
                    movies = int(row.get('Number of movies watched', '0') or 0)
                    kids_titles = int(row.get('Number of kids titles watched', '0') or 0)
                    prime_titles = int(row.get('Number of prime titles watched', '0') or 0)
                    rentbuy_titles = int(row.get('Number of rent/buy titles watched', '0') or 0)
                    watchlist_count = int(row.get('Number of titles added to watchlist', '0') or 0)
                    total_watched = int(row.get('Number of titles watched', '0') or 0)

                    # Skip rows with no viewing activity
                    if total_watched == 0 and watchlist_count == 0:
                        continue

                    # Get language preference
                    language = row.get('Language code', '').strip()

                    # Create viewing activity summary if there's any viewing
                    if total_watched > 0:
                        # V2: Calculate strength based on total viewing
                        # 1-5 titles: 0.12, 6-20: 0.20, 21-50: 0.30, 51-100: 0.38, 100+: 0.45
                        if total_watched <= 5:
                            strength = 0.12
                        elif total_watched <= 20:
                            strength = 0.20
                        elif total_watched <= 50:
                            strength = 0.30
                        elif total_watched <= 100:
                            strength = 0.38
                        else:
                            strength = 0.45

                        # Determine primary content type
                        if movies > tv_shows:
                            content_focus = "movies"
                        elif tv_shows > movies:
                            content_focus = "TV shows"
                        else:
                            content_focus = "movies and TV shows"

                        pref = ParsedPreference(
                            subject=f"Prime Video viewer: {total_watched} titles ({content_focus})",
                            preference_type="Summary",
                            strength=strength,
                            compartment_level=default_compartment,
                            source="prime_video",
                            category="movie_tv",
                            size="Large",
                            extra={
                                "data_type": "prime_video_activity",
                                "total_watched": total_watched,
                                "tv_shows_watched": tv_shows,
                                "movies_watched": movies,
                                "kids_titles_watched": kids_titles,
                                "prime_titles_watched": prime_titles,
                                "rentbuy_titles_watched": rentbuy_titles,
                                "watchlist_count": watchlist_count,
                                "language_preference": language
                            }
                        )
                        yield pref

                    # Create separate preference for kids content if significant
                    if kids_titles > 0 and kids_titles >= 3:
                        kids_strength = min(0.15 + (kids_titles * 0.01), 0.40)  # V2
                        pref = ParsedPreference(
                            subject=f"Prime Video kids content viewer: {kids_titles} titles",
                            preference_type="Pattern",
                            strength=kids_strength,
                            compartment_level=default_compartment,
                            source="prime_video",
                            category="movie_tv",
                            size="Medium",
                            extra={
                                "data_type": "prime_video_kids",
                                "kids_titles_watched": kids_titles,
                                "content_type": "kids"
                            }
                        )
                        yield pref

                    # Create preference for rent/buy behavior if present
                    if rentbuy_titles > 0:
                        rentbuy_strength = min(0.35 + (rentbuy_titles * 0.02), 0.50)  # V2
                        pref = ParsedPreference(
                            subject=f"Prime Video purchaser: {rentbuy_titles} titles rented/bought",
                            preference_type="Like",
                            strength=rentbuy_strength,
                            compartment_level=default_compartment,
                            source="prime_video",
                            category="movie_tv",
                            size="Medium",
                            extra={
                                "data_type": "prime_video_purchases",
                                "rentbuy_count": rentbuy_titles,
                                "indicates_willingness_to_pay": True
                            }
                        )
                        yield pref

                    # Create watchlist preference if significant
                    if watchlist_count >= 5:
                        watchlist_strength = min(0.15 + (watchlist_count * 0.005), 0.30)  # V2
                        pref = ParsedPreference(
                            subject=f"Prime Video watchlist: {watchlist_count} titles saved",
                            preference_type="Neutral",
                            strength=watchlist_strength,
                            compartment_level=default_compartment,
                            source="prime_video",
                            category="movie_tv",
                            size="Small",
                            extra={
                                "data_type": "prime_video_watchlist",
                                "watchlist_count": watchlist_count,
                                "indicates_intent": True
                            }
                        )
                        yield pref

                except Exception as e:
                    logger.warning(f"Failed to parse Prime Video viewcounts row: {e}")
                    continue

            logger.info(f"Parsed Prime Video viewcounts from {file_path}")

        except Exception as e:
            logger.error(f"Failed to parse Prime Video viewcounts file {file_path}: {e}")

    async def _parse_prime_video_search(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Prime Video search history CSV.

        Each search query indicates interest in finding specific content.
        Useful for understanding viewing intent and interests.

        Columns include:
        - Search Request Date
        - Search Query From Customer
        - Is Spell Corrected
        - Device Name
        - Country Code
        """
        try:
            async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig', errors='replace') as f:
                content = await f.read()

            reader = csv.DictReader(content.splitlines())
            search_count = 0

            for row in reader:
                try:
                    search_query = row.get('Search Query From Customer', '').strip()
                    if not search_query:
                        continue

                    # Parse timestamp
                    timestamp_str = row.get('Search Request Date', '')
                    observed_at = None
                    if timestamp_str:
                        try:
                            observed_at = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
                        except Exception:
                            pass

                    # Get device info
                    device = row.get('Device Name', '').strip()
                    profile_age = row.get('Customer Profile Age', '').strip()

                    # V2: Search queries indicate interest - weak signal
                    strength = 0.12

                    pref = ParsedPreference(
                        subject=f"Searched Prime Video: {search_query}",
                        preference_type="Like",  # V2: Weak positive
                        strength=strength,
                        compartment_level=default_compartment,
                        source="prime_video",
                        category="movie_tv",
                        observed_at=observed_at,
                        size="Small",
                        extra={
                            "data_type": "prime_video_search",
                            "query": search_query,
                            "device": device,
                            "profile_type": profile_age,
                            "is_spell_corrected": row.get('Is Spell Corrected', 'No') == 'Yes'
                        }
                    )

                    yield pref
                    search_count += 1

                except Exception as e:
                    logger.warning(f"Failed to parse Prime Video search row: {e}")
                    continue

            logger.info(f"Parsed {search_count} Prime Video searches from {file_path}")

        except Exception as e:
            logger.error(f"Failed to parse Prime Video search file {file_path}: {e}")
