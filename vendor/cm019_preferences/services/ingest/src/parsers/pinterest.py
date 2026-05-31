"""Pinterest data parser - comprehensive extraction."""

import logging
import re
from pathlib import Path
from typing import AsyncIterator, Optional, List, Dict
from datetime import datetime
from bs4 import BeautifulSoup, NavigableString
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class PinterestParser(BaseParser):
    """
    Comprehensive parser for Pinterest data exports.

    Handles pinterest.html Subject Access Request data:
    - Boards (collections the user created)
    - Pins (individual saved items with titles and board associations)
    - Search history (what the user searched for)
    - Inferred interests (Pinterest's analysis of user preferences)
    - Followees (accounts the user follows)
    """

    source_name = "pinterest"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Pinterest data export."""
        if file_path.suffix.lower() != '.html':
            return False
        name = file_path.name.lower()
        return 'pinterest' in name

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest data export comprehensively."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info(f"Parsing Pinterest data from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        soup = BeautifulSoup(content, 'html.parser')

        # Parse all sections
        async for pref in self._parse_boards(soup, default_compartment):
            yield pref

        async for pref in self._parse_pins(soup, default_compartment):
            yield pref

        async for pref in self._parse_search_history(soup, default_compartment):
            yield pref

        async for pref in self._parse_interests(soup, default_compartment):
            yield pref

        async for pref in self._parse_followees(soup, default_compartment):
            yield pref

    async def _parse_boards(
        self,
        soup: BeautifulSoup,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest boards."""
        # Find the Boards section header
        boards_header = soup.find('h1', id='cq8g8')
        if not boards_header:
            boards_header = soup.find('h1', string=re.compile(r'^Boards$', re.I))

        if not boards_header:
            logger.debug("No boards section found")
            return

        # Find the next h1 to know where to stop
        next_section = boards_header.find_next('h1')

        # Find all links between boards header and next section
        boards = []
        for link in boards_header.find_all_next('a'):
            # Stop if we've passed the next section
            if next_section and link.find_previous('h1') != boards_header:
                # Check if this link comes after the next section header
                if next_section in link.find_all_previous('h1'):
                    break

            href = link.get('href', '')
            if 'pinterest.com' in href and '/pin/' not in href:
                # This is a board link
                board_name = link.get_text(strip=True)
                if board_name and board_name != 'No data':
                    # Extract category from following text if available
                    category = None
                    next_elem = link.next_sibling
                    while next_elem:
                        if isinstance(next_elem, NavigableString):
                            text = str(next_elem)
                            if 'Category:' in text:
                                cat_match = re.search(r'Category:\s*(\w+)', text)
                                if cat_match and cat_match.group(1) != 'None':
                                    category = cat_match.group(1)
                            break
                        next_elem = next_elem.next_sibling

                    boards.append({
                        'name': board_name,
                        'url': href,
                        'category': category
                    })

                    # Stop after we hit the Pins section
                    if next_section and link.find_next('h1') == next_section:
                        break

        logger.info(f"Parsed {len(boards)} Pinterest boards")

        for board in boards:
            yield ParsedPreference(
                subject=f"Pinterest board: {board['name']}",
                preference_type="Like",
                category=self._map_category(board['category']) if board['category'] else "lifestyle",
                strength=0.35,  # V2: Curated board
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "board",
                    "board_name": board['name'],
                    "url": board['url'],
                    "pinterest_category": board['category']
                }
            )

    async def _parse_pins(
        self,
        soup: BeautifulSoup,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest pins."""
        # Find the Pins section
        pins_header = soup.find('h1', id='0o3mz')
        if not pins_header:
            pins_header = soup.find('h1', string=re.compile(r'^Pins$', re.I))

        if not pins_header:
            logger.debug("No pins section found")
            return

        # Get the raw HTML content after the pins header
        pins_html = str(pins_header.find_next_sibling())

        # Find all pin entries by looking for the pattern
        # Each pin starts with a pinterest.com/pin/ link
        pins = []
        current_element = pins_header.find_next()

        while current_element:
            # Stop at next h1 section
            if current_element.name == 'h1':
                break

            # Look for pin links
            if current_element.name == 'a':
                href = current_element.get('href', '')
                if '/pin/' in href:
                    # Found a pin, now extract its details
                    pin_data = {'url': href, 'title': None, 'board_name': None, 'created_at': None}

                    # Look for Title and Board Name in following text
                    sibling = current_element.next_sibling
                    while sibling and not (hasattr(sibling, 'name') and sibling.name == 'a'):
                        if isinstance(sibling, NavigableString):
                            text = str(sibling)

                            # Extract Title
                            title_match = re.search(r'Title:\s*([^,<]+)', text)
                            if title_match:
                                title = title_match.group(1).strip()
                                if title and title != 'No data':
                                    pin_data['title'] = title

                            # Extract Board Name
                            board_match = re.search(r'Board Name:\s*([^,<]+)', text)
                            if board_match:
                                board = board_match.group(1).strip()
                                if board and board != 'No data':
                                    pin_data['board_name'] = board

                            # Extract Created at
                            created_match = re.search(r'Created at:\s*(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})', text)
                            if created_match:
                                try:
                                    pin_data['created_at'] = datetime.strptime(
                                        created_match.group(1), "%Y/%m/%d %H:%M:%S"
                                    )
                                except:
                                    pass

                        sibling = sibling.next_sibling
                        if sibling and hasattr(sibling, 'name') and sibling.name in ('h1', 'h2'):
                            break

                    if pin_data['title']:
                        pins.append(pin_data)

            current_element = current_element.find_next()

        logger.info(f"Parsed {len(pins)} Pinterest pins")

        # Yield individual pins
        for pin in pins:
            category = self._infer_category(pin['title'])

            yield ParsedPreference(
                subject=pin['title'],  # Use full title (already validated as meaningful)
                preference_type="Like",
                category=category,
                strength=0.28,  # V2: Pin save
                observed_at=pin['created_at'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "pin",
                    "url": pin['url'],
                    "board_name": pin['board_name'],
                }
            )

        # Also aggregate by board to show board interests
        board_counts: Dict[str, int] = {}
        for pin in pins:
            if pin['board_name']:
                board_counts[pin['board_name']] = board_counts.get(pin['board_name'], 0) + 1

        for board_name, count in board_counts.items():
            if count >= 3:  # Only boards with 3+ pins
                yield ParsedPreference(
                    subject=f"Interest in {board_name} (via {count} pins)",
                    preference_type="Like",
                    category=self._infer_category(board_name),
                    strength=min(0.6 + (count * 0.02), 0.9),
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "type": "board_interest",
                        "board_name": board_name,
                        "pin_count": count,
                    }
                )

    async def _parse_search_history(
        self,
        soup: BeautifulSoup,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest search history."""
        # Find search history section
        search_header = soup.find('h1', id='hmz0r')
        if not search_header:
            search_header = soup.find('h1', string=re.compile(r'Search history', re.I))

        if not search_header:
            logger.debug("No search history section found")
            return

        # Get all text after the search header until next h1
        searches = []
        current = search_header.next_sibling

        while current:
            if hasattr(current, 'name') and current.name == 'h1':
                break

            if isinstance(current, NavigableString):
                text = str(current)

                # Extract Query from pattern: Query: search term
                query_match = re.search(r'Query:\s*([^\n<]+)', text)
                if query_match:
                    query = query_match.group(1).strip()
                    if query and query != 'No data' and len(query) > 1:
                        # Skip email-like queries
                        if '@' not in query:
                            # Extract timestamp if available
                            time_match = re.search(r'Time\(s\) of search:\s*(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})', text)
                            timestamp = None
                            if time_match:
                                try:
                                    timestamp = datetime.strptime(time_match.group(1), "%Y/%m/%d %H:%M:%S")
                                except:
                                    pass

                            searches.append({'query': query, 'timestamp': timestamp})

            current = current.next_sibling

        logger.info(f"Parsed {len(searches)} Pinterest searches")

        for search in searches:
            category = self._infer_category(search['query'])

            yield ParsedPreference(
                subject=f"Searched: {search['query']}",
                preference_type="Like",
                category=category,
                strength=0.20,  # V2: Follow
                observed_at=search['timestamp'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Micro",
                extra={
                    "type": "search",
                    "query": search['query'],
                }
            )

    async def _parse_interests(
        self,
        soup: BeautifulSoup,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest inferred interests."""
        # Find interests section - it's an h2 not h1
        interests_header = soup.find('h2', id='kp0yp')
        if not interests_header:
            interests_header = soup.find('h2', string=re.compile(r'Inferences.*interests', re.I))

        if not interests_header:
            logger.debug("No interests section found")
            return

        # Get the text content after the header until next h1 or h2
        interests = []
        current = interests_header.next_sibling

        while current:
            if hasattr(current, 'name') and current.name in ('h1', 'h2'):
                break

            if isinstance(current, NavigableString):
                text = str(current).strip()
                # Interests are separated by <br> tags, so we get them as separate strings
                if text and text != 'No data' and len(text) > 1:
                    # Skip HTML artifacts
                    if not text.startswith('<') and not text.startswith('='):
                        interests.append(text)

            current = current.next_sibling

        # Also try parsing from get_text with br separator
        if not interests:
            # Alternative: get all text content
            next_section = interests_header.find_next(['h1', 'h2'])
            if next_section:
                # Get text between headers
                text_content = ""
                for elem in interests_header.next_siblings:
                    if elem == next_section:
                        break
                    if isinstance(elem, NavigableString):
                        text_content += str(elem)

                # Split by common separators
                for interest in re.split(r'<br>|<br/>|\n', text_content):
                    interest = interest.strip()
                    if interest and interest != 'No data' and len(interest) > 1:
                        if not interest.startswith('<'):
                            interests.append(interest)

        logger.info(f"Parsed {len(interests)} Pinterest inferred interests")

        for interest in interests:
            category = self._infer_category(interest)

            yield ParsedPreference(
                subject=interest,
                preference_type="Like",
                category=category,
                strength=0.05,  # V2: ML inference - very weak signal
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "inferred_interest",
                }
            )

    async def _parse_followees(
        self,
        soup: BeautifulSoup,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Pinterest accounts the user follows."""
        # Find followees section
        followees_header = soup.find('h1', id='fmv4l')
        if not followees_header:
            followees_header = soup.find('h1', string=re.compile(r'^Followees$', re.I))

        if not followees_header:
            logger.debug("No followees section found")
            return

        # Find the next section to know where to stop
        next_section = followees_header.find_next('h1')

        followees = []
        for link in followees_header.find_all_next('a'):
            if next_section and next_section in link.find_all_previous('h1'):
                break

            href = link.get('href', '')
            if 'pinterest.com' in href and '/pin/' not in href:
                username = link.get_text(strip=True)
                if username and username != 'No data':
                    followees.append({'username': username, 'url': href})

        logger.info(f"Parsed {len(followees)} Pinterest followees")

        # Only create preferences for followees (showing who the user is interested in)
        for followee in followees[:50]:  # Limit to avoid too many
            yield ParsedPreference(
                subject=f"Follows Pinterest user: {followee['username']}",
                preference_type="Like",
                category="social",
                strength=0.12,  # V2: Search intent
                source=self.source_name,
                compartment_level=default_compartment,
                size="Micro",
                extra={
                    "type": "followee",
                    "username": followee['username'],
                    "url": followee['url'],
                }
            )

    def _map_category(self, pinterest_category: str) -> str:
        """Map Pinterest categories to our categories."""
        if not pinterest_category:
            return "lifestyle"

        category_map = {
            "products": "shopping",
            "film_music_books": "entertainment",
            "home_decor": "home",
            "design": "art",
            "food_drink": "food",
            "travel": "travel",
            "fashion": "fashion",
            "art": "art",
            "photography": "photography",
            "diy_crafts": "crafts",
            "technology": "technology",
            "sports": "sports",
            "outdoors": "outdoors",
            "vehicles": "automotive",
            "architecture": "architecture",
        }

        return category_map.get(pinterest_category.lower(), "lifestyle")

    def _infer_category(self, text: str) -> str:
        """Infer category from text content."""
        if not text:
            return "lifestyle"

        text_lower = text.lower()

        category_keywords = {
            "food": ["recipe", "food", "cook", "bake", "meal", "dinner", "lunch",
                     "breakfast", "dessert", "cake", "kitchen", "chef"],
            "fashion": ["fashion", "outfit", "style", "clothing", "dress", "shoes",
                        "jewelry", "accessories", "jacket", "coat", "wear"],
            "home": ["home", "decor", "interior", "furniture", "room", "kitchen",
                     "bathroom", "bedroom", "garden", "house", "apartment", "flooring", "wall"],
            "travel": ["travel", "vacation", "trip", "destination", "beach",
                       "mountain", "city", "hotel", "adventure"],
            "art": ["art", "painting", "drawing", "illustration", "design",
                    "creative", "craft", "diy", "graphic"],
            "fitness": ["fitness", "workout", "exercise", "yoga", "gym",
                        "health", "wellness", "sport"],
            "beauty": ["beauty", "makeup", "skincare", "hair", "nail", "cosmetic"],
            "technology": ["tech", "gadget", "app", "software", "computer",
                           "phone", "digital", "apple", "gaming"],
            "photography": ["photo", "photography", "camera", "portrait", "landscape"],
            "automotive": ["car", "motorcycle", "bike", "vehicle", "motor", "racing",
                           "porsche", "ducati", "bmw", "mercedes", "lamborghini",
                           "vintage car", "classic car", "scooter", "bicycle", "cycling"],
        }

        for category, keywords in category_keywords.items():
            if any(kw in text_lower for kw in keywords):
                return category

        return "lifestyle"
