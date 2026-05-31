"""WhatsApp data parser.

Handles two types of WhatsApp exports:
1. Chat exports (.txt, .json, .zip) - Message content analysis
2. Account Info exports (GDPR) - Group memberships and communities

Account Info Export Structure:
    extracted/
    ├── whatsapp_connections/
    │   ├── groups.json       # wa_groups array of group names (~1000+ groups)
    │   ├── communities.json  # wa_communities array with sub_groups
    │   └── contacts.json     # wa_contacts array (phone numbers only)
    └── ...

Group names reveal interests: "AI Tinkerers", "3D Printing gurus", "Bikers", etc.
"""

import json
import re
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, List, Any, Set, Tuple
from datetime import datetime
from collections import Counter, defaultdict
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


# Topic extraction patterns for WhatsApp group names
# Maps keywords/patterns to (topic, category) tuples
TOPIC_PATTERNS: Dict[str, Tuple[str, str]] = {
    # Technology
    r'\bAI\b': ('AI/Machine Learning', 'technology'),
    r'\bartificial intelligence\b': ('AI/Machine Learning', 'technology'),
    r'\bmachine learning\b': ('AI/Machine Learning', 'technology'),
    r'\bML\b': ('AI/Machine Learning', 'technology'),
    r'\bLLM\b': ('AI/Machine Learning', 'technology'),
    r'\bGPT\b': ('AI/Machine Learning', 'technology'),
    r'\bGenAI\b': ('AI/Machine Learning', 'technology'),
    r'\bblockchain\b': ('Blockchain/Web3', 'technology'),
    r'\bcrypto\b': ('Blockchain/Web3', 'technology'),
    r'\bweb3\b': ('Blockchain/Web3', 'technology'),
    r'\bDAO\b': ('Blockchain/Web3', 'technology'),
    r'\bNFT\b': ('Blockchain/Web3', 'technology'),
    r'\b3D\s*print': ('3D Printing', 'technology'),
    r'\bVR\b': ('Virtual Reality', 'technology'),
    r'\bAR\b': ('Augmented Reality', 'technology'),
    r'\bIoT\b': ('Internet of Things', 'technology'),
    r'\bAIoT\b': ('AI + IoT', 'technology'),
    r'\bRFID\b': ('RFID Technology', 'technology'),
    r'\btechno': ('Technology', 'technology'),
    r'\btech\b': ('Technology', 'technology'),
    r'\bsoftware\b': ('Software Development', 'technology'),
    r'\bdev\s*license\b': ('Software Development', 'technology'),
    r'\bdrone': ('Drones/FPV', 'technology'),
    r'\bFPV\b': ('Drones/FPV', 'technology'),
    r'\brobot': ('Robotics', 'technology'),
    r'\bcode\b': ('Programming', 'technology'),
    r'\bcoding\b': ('Programming', 'technology'),
    r'\bMinecraft\s*Cod': ('Programming', 'technology'),

    # Design & UX
    r'\bUX\b': ('UX Design', 'professional'),
    r'\bUI\b': ('UI Design', 'professional'),
    r'\bdesign\s*think': ('Design Thinking', 'professional'),
    r'\bgraphic\s*design': ('Graphic Design', 'professional'),
    r'\bmodelmaking\b': ('Modelmaking', 'hobby'),
    r'\bPCB\s*Art\b': ('PCB Art', 'hobby'),

    # Innovation & Business
    r'\binnov': ('Innovation', 'professional'),
    r'\bstartup': ('Startups', 'professional'),
    r'\bentrepreneur': ('Entrepreneurship', 'professional'),
    r'\bventure\b': ('Venture Capital', 'professional'),
    r'\bVC\b': ('Venture Capital', 'professional'),
    r'\bacceler': ('Startup Accelerators', 'professional'),
    r'\bincubat': ('Startup Incubators', 'professional'),

    # Hobbies & Interests
    r'\bbike': ('Cycling/Biking', 'hobby'),
    r'\bcycl': ('Cycling/Biking', 'hobby'),
    r'\brid[ei]': ('Cycling/Biking', 'hobby'),
    r'\bpinball\b': ('Pinball', 'hobby'),
    r'\barcade\b': ('Arcade Gaming', 'hobby'),
    r'\bphoto': ('Photography', 'hobby'),
    r'\bvideo\s*geek': ('Videography', 'hobby'),
    r'\bdj\b': ('DJing', 'hobby'),
    r'\bsurf': ('Surfing', 'hobby'),
    r'\bbeard': ('Grooming/Beards', 'hobby'),
    r'\bgadget': ('Gadgets', 'hobby'),
    r'\bhobby': ('Hobbies', 'hobby'),
    r'\bgin\b': ('Gin/Cocktails', 'food'),
    r'\bbeer': ('Beer', 'food'),
    r'\bwine\b': ('Wine', 'food'),
    r'\bcurry\b': ('Curry/Indian Food', 'food'),
    r'\bfood\b': ('Food', 'food'),
    r'\bcook': ('Cooking', 'food'),
    r'\bbbq\b': ('BBQ', 'food'),
    r'\bsushi\b': ('Japanese Food', 'food'),
    r'\brestaurant': ('Dining Out', 'food'),
    r'\bmotor': ('Motorcycles', 'hobby'),
    r'\bmoto': ('Motorcycles', 'hobby'),
    r'\bpetrol': ('Cars/Automotive', 'hobby'),
    r'\bcar\b': ('Cars/Automotive', 'hobby'),
    r'\baudi\b': ('Cars/Automotive', 'hobby'),
    r'\btravel': ('Travel', 'hobby'),
    r'\bhike': ('Hiking', 'hobby'),
    r'\bjunk\s*boat': ('Junk Boating', 'hobby'),
    r'\bjunk\s*trip': ('Junk Boating', 'hobby'),
    r'\bequest': ('Equestrian', 'hobby'),
    r'\bhorse': ('Equestrian', 'hobby'),
    r'\brugby\b': ('Rugby', 'sport'),
    r'\bsevens\b': ('Rugby Sevens', 'sport'),
    r'\bping\s*pong': ('Table Tennis', 'sport'),
    r'\bfitness\b': ('Fitness', 'sport'),
    r'\bgym\b': ('Fitness', 'sport'),
    r'\bworkout': ('Fitness', 'sport'),
    r'\byoga\b': ('Yoga', 'sport'),
    r'\brun\b': ('Running', 'sport'),
    r'\bquiz\b': ('Pub Quizzes', 'hobby'),

    # Entertainment
    r'\bstar\s*wars\b': ('Star Wars', 'entertainment'),
    r'\bavengers\b': ('Marvel', 'entertainment'),
    r'\bmarvel\b': ('Marvel', 'entertainment'),
    r'\bmovie': ('Movies', 'entertainment'),
    r'\bfilm\b': ('Movies', 'entertainment'),
    r'\bnetflix\b': ('Streaming', 'entertainment'),
    r'\bmusic\b': ('Music', 'entertainment'),
    r'\bconcert': ('Concerts', 'entertainment'),
    r'\bcoldplay\b': ('Concerts', 'entertainment'),
    r'\bstormtrooper': ('Star Wars Cosplay', 'entertainment'),

    # Professional/Companies (extract as professional interest)
    r'\bchanel\b': ('Fashion/Luxury', 'professional'),
    r'\bsamsung\b': ('Tech Industry', 'professional'),
    r'\blg\b': ('Tech Industry', 'professional'),
    r'\bdeloitte\b': ('Consulting', 'professional'),
    r'\bkpmg\b': ('Consulting', 'professional'),
    r'\bpwc\b': ('Consulting', 'professional'),
    r'\bey\b': ('Consulting', 'professional'),
    r'\baccenture\b': ('Consulting', 'professional'),
    r'\bgoldman\b': ('Finance', 'professional'),
    r'\bbanking\b': ('Finance', 'professional'),
    r'\binsurance\b': ('Insurance', 'professional'),
    r'\bretail\b': ('Retail', 'professional'),
    r'\bfashion\b': ('Fashion', 'professional'),
    r'\bluxury\b': ('Luxury', 'professional'),
    r'\bmktg\b': ('Marketing', 'professional'),
    r'\bmarketing\b': ('Marketing', 'professional'),
    r'\bhr\b': ('Human Resources', 'professional'),
    r'\bl&d\b': ('Learning & Development', 'professional'),
    r'\btraining\b': ('Training', 'professional'),
    r'\binfra\b': ('Infrastructure', 'professional'),
    r'\becomm': ('E-commerce', 'professional'),
    r'\bshopify\b': ('E-commerce', 'professional'),
    r'\bcrm\b': ('CRM', 'professional'),
    r'\bpos\b': ('Point of Sale', 'professional'),
    r'\bmpos\b': ('Mobile POS', 'professional'),
    r'\bpayment': ('Payments', 'professional'),
    r'\bapple\s*pay\b': ('Mobile Payments', 'professional'),

    # Communities & Networking
    r'\bmeetup\b': ('Meetups', 'networking'),
    r'\bnetwork': ('Networking', 'networking'),
    r'\bcommunit': ('Community', 'networking'),
    r'\bambassador': ('Brand Ambassadors', 'networking'),
    r'\bmentor': ('Mentorship', 'networking'),
    r'\bconnect': ('Networking', 'networking'),

    # Education
    r'\bedtech\b': ('EdTech', 'education'),
    r'\bcourse\b': ('Education', 'education'),
    r'\bschool\b': ('Education', 'education'),
    r'\buniversity\b': ('Education', 'education'),
    r'\bpoly\s*u\b': ('Education', 'education'),
    r'\blearning\b': ('Education', 'education'),

    # Location-based interests (reveal geographic connection)
    r'\bhong\s*kong\b': ('Hong Kong', 'location'),
    r'\bhk\b': ('Hong Kong', 'location'),
    r'\blantau\b': ('Lantau/Outdoors HK', 'location'),
    r'\bshenzhen\b': ('Shenzhen/China Tech', 'location'),
    r'\bshanghai\b': ('Shanghai', 'location'),
    r'\bsingapore\b': ('Singapore', 'location'),
    r'\bsg\b': ('Singapore', 'location'),
    r'\blondon\b': ('London', 'location'),
    r'\bbristol\b': ('Bristol UK', 'location'),
    r'\bedinburgh\b': ('Edinburgh', 'location'),
}

# Noise patterns to filter out (generic groups, events, etc.)
NOISE_PATTERNS: List[str] = [
    r'^dinner$',
    r'^tonight$',
    r'^tomorrow$',
    r'^sunday$',
    r'^saturday$',
    r'^weekend$',
    r'^this\s*evening$',
    r'^drinks$',
    r'^drinkies$',
    r'^drinkypoos$',
    r'^lunch$',
    r'^breakfast$',
    r'^coffee$',
    r'^catch\s*up$',
    r'^meet\s*up$',
    r'^get\s*together$',
    r'^gathering$',
    r'^party$',
    r'^celebration$',
    r'^birthday',
    r"'s\s*birthday",
    r'\d+(st|nd|rd|th)\s*birthday',
    r'^bday\b',
    r'\bbirthday\s*party',
    r'\bbday\s*party',
    r'^sleepover$',
    r'^playdate$',
    r'^intro$',
    r'^introductions$',
    r'^connection$',
    r'^connect$',
    r'^team$',
    r'^news$',
    r'^update$',
    r'^chat$',
    r'^group$',
    r'^family$',
    r'we\s*are\s*family',
    r'^hello$',
    r'^hi$',
    r'^hey$',
    r'^omg$',
    r'^wtf$',
    r'^ffs$',
    r'^conf$',
    r'^offsite$',
    r'^u\.?k\.?$',
    r'^sick\s*kids$',
    r'^\w+\s*x\s*\w+$',  # Simple "Person x Person" groups (too generic)
    r'^(\w+,?\s*)+&\s*\w+$',  # "Person, Person & Person" groups
    r'^(\w+),\s*(\w+)\s*(&|and)\s*(\w+)$',  # "A, B & C" pattern
    r'^\w+\s*&\s*\w+$',  # "Person & Person" groups
    r'^\w+\s*:\s*\w+$',  # "Person : Person" groups
    r"^the\s+\w+s$",  # "The Smiths" type family groups
    r"^the\s+\w+'s$",  # "The Smith's" type family groups
    r'neighbours?',  # Neighbour groups
    r'\bneighbou?rs?\b',
    r'^visitors$',
    r'^sammy$',
    r'^papers$',
    r'^shoulder$',
    r'^roach$',
    r'^duc$',
    r'^cake$',
    r'^elliot$',
    r'^nic$',
    r'^jd$',
    r'^\s*$',  # Empty
]

# Company/work group patterns that reveal professional network but not interest
WORK_GROUP_PATTERNS: List[str] = [
    r'invoices?',
    r'delivery',
    r'pick\s*up',
    r'shipping',
    r'customs',
    r'dhl',
    r'payment',
    r'closing',
    r'feedback',
    r'test',
    r'testing',
    r'trial',
    r'demo',
    r'rollout',
    r'transition',
    r'closing',
]


class WhatsAppParser(BaseParser):
    """
    Parser for WhatsApp data exports.

    Handles:
    - JSON exports from WhatsApp Chat Exporter tools
    - Native WhatsApp text export format (.txt)
    - ZIP archives containing chat exports
    - Account Info exports (GDPR) with groups.json, communities.json

    Extracts preferences based on:
    - Frequent contacts (communication preferences)
    - Common topics/keywords in messages
    - Shared media types
    - Group participation
    - Group name topic extraction (Account Info)
    - Community memberships (Account Info)
    """

    source_name = "whatsapp"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a WhatsApp data export."""
        name = file_path.name.lower()
        suffix = file_path.suffix.lower()

        # Check for Account Info export directory structure
        if file_path.is_dir():
            # Check for whatsapp_connections subdirectory with groups.json
            connections_dir = file_path / 'whatsapp_connections'
            if connections_dir.exists():
                return (connections_dir / 'groups.json').exists()
            # Also check if this IS the whatsapp_connections directory
            if file_path.name == 'whatsapp_connections':
                return (file_path / 'groups.json').exists()
            return False

        # Check for WhatsApp Account Info JSON files
        if suffix == '.json':
            # Check if parent directory is whatsapp_connections
            if file_path.parent.name == 'whatsapp_connections':
                return name in ('groups.json', 'communities.json')
            # Check for wa_groups or wa_communities keys
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        if any(k in data for k in ['wa_groups', 'wa_communities']):
                            return True
                        return any(k in data for k in ['chats', 'messages', 'participants'])
                    if isinstance(data, list) and len(data) > 0:
                        return any(k in data[0] for k in ['sender', 'message', 'date'])
            except:
                pass

        # Check for WhatsApp naming patterns
        if 'whatsapp' in name:
            return suffix in ('.json', '.txt', '.zip')

        # Check for chat export pattern
        if suffix == '.txt':
            # WhatsApp exports often have "WhatsApp Chat" in the name
            return 'chat' in name and ('whatsapp' in name or 'wa' in name)

        if suffix == '.zip':
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any('whatsapp' in n or '_chat.txt' in n for n in names)
            except:
                return False

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp data export."""
        if default_compartment is None:
            default_compartment = 1  # L1 Family - chats are personal

        logger.info(f"Parsing WhatsApp data from {file_path}")

        # Handle directory (Account Info export)
        if file_path.is_dir():
            async for pref in self._parse_account_info_dir(file_path, default_compartment):
                yield pref
            return

        suffix = file_path.suffix.lower()
        name = file_path.name.lower()

        # Check for Account Info JSON files
        if suffix == '.json':
            # Check if this is groups.json or communities.json from Account Info
            if file_path.parent.name == 'whatsapp_connections':
                if name == 'groups.json':
                    async for pref in self._parse_groups_json(file_path, default_compartment):
                        yield pref
                    return
                elif name == 'communities.json':
                    async for pref in self._parse_communities_json(file_path, default_compartment):
                        yield pref
                    return

            # Check content for wa_groups/wa_communities
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        if 'wa_groups' in data:
                            async for pref in self._parse_groups_json(file_path, default_compartment):
                                yield pref
                            return
                        elif 'wa_communities' in data:
                            async for pref in self._parse_communities_json(file_path, default_compartment):
                                yield pref
                            return
            except:
                pass

        if suffix == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif suffix == '.json':
            async for pref in self._parse_json(file_path, default_compartment):
                yield pref
        elif suffix == '.txt':
            async for pref in self._parse_txt(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                if name_lower.endswith('.json'):
                    content = zf.read(name).decode('utf-8')
                    try:
                        data = json.loads(content)
                        async for pref in self._parse_json_content(data, default_compartment):
                            yield pref
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse JSON: {name}")

                elif name_lower.endswith('.txt') and 'chat' in name_lower:
                    content = zf.read(name).decode('utf-8')
                    async for pref in self._parse_txt_content(content, name, default_compartment):
                        yield pref

    async def _parse_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp JSON export."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
            async for pref in self._parse_json_content(data, default_compartment):
                yield pref
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")

    async def _parse_txt(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp text export."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        async for pref in self._parse_txt_content(content, file_path.name, default_compartment):
            yield pref

    async def _parse_json_content(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse JSON content from WhatsApp export."""

        messages = []
        participants = []

        # Handle different JSON structures
        if isinstance(data, dict):
            messages = data.get('chats', data.get('messages', []))
            participants = data.get('participants', [])
        elif isinstance(data, list):
            messages = data

        if not messages:
            return

        # Analyze messages
        contact_counts = Counter()
        topic_keywords = Counter()
        attachment_types = Counter()

        for msg in messages:
            if not isinstance(msg, dict):
                continue

            sender = msg.get('sender', msg.get('from', ''))
            message_text = msg.get('message', msg.get('text', msg.get('body', '')))
            msg_type = msg.get('type', 'conversation')

            if sender:
                contact_counts[sender] += 1

            # Track attachments
            if msg_type == 'attachment' or 'attachment' in msg:
                att = msg.get('attachment', {})
                ext = att.get('extention', att.get('extension', att.get('type', 'file')))
                attachment_types[ext] += 1

            # Extract keywords from messages
            if message_text and msg_type in ('conversation', 'text'):
                keywords = self._extract_keywords(message_text)
                for kw in keywords:
                    topic_keywords[kw] += 1

        logger.info(f"Analyzed {len(messages)} WhatsApp messages")

        # Yield contact preferences (frequent contacts)
        for contact, count in contact_counts.most_common(20):
            if count < 5:  # Minimum message threshold
                continue

            strength = min(0.5 + (count * 0.005), 0.9)
            yield ParsedPreference(
                subject=f"communicating with {contact}",
                preference_type="Like",
                category="social",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "frequent_contact",
                    "contact": contact,
                    "message_count": count
                }
            )

        # Yield topic preferences from keywords
        for keyword, count in topic_keywords.most_common(15):
            if count < 10:  # Minimum occurrence threshold
                continue

            strength = min(0.4 + (count * 0.01), 0.75)
            category = self._categorize_keyword(keyword)

            yield ParsedPreference(
                subject=keyword,
                preference_type="Like",
                category=category,
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "topic_interest",
                    "mention_count": count
                }
            )

        # Yield media sharing preferences
        for media_type, count in attachment_types.items():
            if count < 3:
                continue

            media_name = self._media_type_name(media_type)
            yield ParsedPreference(
                subject=f"sharing {media_name}",
                preference_type="Like",
                category="communication",
                strength=min(0.5 + (count * 0.02), 0.8),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "media_sharing",
                    "media_type": media_type,
                    "share_count": count
                }
            )

    async def _parse_txt_content(
        self,
        content: str,
        filename: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp text export format."""
        # WhatsApp text format: "DD/MM/YYYY, HH:MM - Sender: Message"
        # or: "[DD/MM/YYYY, HH:MM:SS] Sender: Message"

        patterns = [
            r'(\d{1,2}/\d{1,2}/\d{2,4}),?\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*[-–]\s*([^:]+):\s*(.+)',
            r'\[(\d{1,2}/\d{1,2}/\d{2,4}),?\s*(\d{1,2}:\d{2}(?::\d{2})?)\]\s*([^:]+):\s*(.+)',
        ]

        contact_counts = Counter()
        topic_keywords = Counter()
        message_count = 0

        for line in content.split('\n'):
            line = line.strip()
            if not line:
                continue

            for pattern in patterns:
                match = re.match(pattern, line)
                if match:
                    sender = match.group(3).strip()
                    message = match.group(4).strip()
                    message_count += 1

                    # Skip system messages
                    if sender.lower() in ['system', 'whatsapp']:
                        continue

                    contact_counts[sender] += 1

                    # Skip media placeholders
                    if '<Media omitted>' not in message and '<attached:' not in message.lower():
                        keywords = self._extract_keywords(message)
                        for kw in keywords:
                            topic_keywords[kw] += 1
                    break

        # Extract chat name from filename
        chat_name = filename.replace('.txt', '').replace('WhatsApp Chat with ', '')
        chat_name = re.sub(r'[_-]', ' ', chat_name).strip()

        logger.info(f"Parsed {message_count} messages from WhatsApp chat: {chat_name}")

        if message_count > 10:
            # This is an active chat - yield as a preference
            yield ParsedPreference(
                subject=f"chatting in {chat_name}",
                preference_type="Like",
                category="social",
                strength=min(0.5 + (message_count * 0.001), 0.85),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "active_chat",
                    "chat_name": chat_name,
                    "message_count": message_count
                }
            )

        # Yield contact preferences
        for contact, count in contact_counts.most_common(10):
            if count < 5:
                continue

            yield ParsedPreference(
                subject=f"communicating with {contact}",
                preference_type="Like",
                category="social",
                strength=min(0.5 + (count * 0.005), 0.85),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "frequent_contact",
                    "contact": contact,
                    "message_count": count
                }
            )

    def _extract_keywords(self, text: str) -> List[str]:
        """Extract meaningful keywords from message text."""
        # Skip very short messages
        if len(text) < 10:
            return []

        # Normalize text
        text = text.lower()

        # Remove URLs
        text = re.sub(r'https?://\S+', '', text)

        # Remove common words and extract potential topics
        stop_words = {
            'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
            'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
            'should', 'may', 'might', 'must', 'shall', 'can', 'need', 'dare',
            'ought', 'used', 'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by',
            'from', 'up', 'about', 'into', 'through', 'during', 'before', 'after',
            'above', 'below', 'between', 'under', 'again', 'further', 'then',
            'once', 'here', 'there', 'when', 'where', 'why', 'how', 'all', 'each',
            'few', 'more', 'most', 'other', 'some', 'such', 'no', 'nor', 'not',
            'only', 'own', 'same', 'so', 'than', 'too', 'very', 'just', 'and',
            'but', 'if', 'or', 'because', 'as', 'until', 'while', 'of', 'this',
            'that', 'these', 'those', 'am', 'it', 'its', 'i', 'me', 'my', 'we',
            'our', 'you', 'your', 'he', 'him', 'his', 'she', 'her', 'they', 'them',
            'what', 'which', 'who', 'whom', 'ok', 'okay', 'yes', 'no', 'yeah',
            'lol', 'haha', 'hehe', 'omg', 'btw', 'idk', 'imo', 'tbh', 'gonna',
            'wanna', 'gotta', 'dont', 'didnt', 'cant', 'wont', 'im', 'ive',
            'ill', 'youre', 'youve', 'youll', 'hes', 'shes', 'its', 'were',
            'theyre', 'theyve', 'theyll', 'lets', 'thats', 'whats', 'hows',
            'get', 'got', 'getting', 'go', 'going', 'gone', 'come', 'coming',
            'know', 'think', 'want', 'like', 'see', 'look', 'make', 'take',
            'good', 'great', 'nice', 'cool', 'thanks', 'thank', 'please', 'sorry'
        }

        # Extract words
        words = re.findall(r'\b[a-z]{4,}\b', text)
        keywords = [w for w in words if w not in stop_words]

        return keywords[:5]  # Return top 5 keywords per message

    def _categorize_keyword(self, keyword: str) -> str:
        """Categorize a keyword into a preference category."""
        categories = {
            'food': ['food', 'eat', 'dinner', 'lunch', 'breakfast', 'restaurant', 'cook', 'recipe'],
            'travel': ['travel', 'trip', 'vacation', 'flight', 'hotel', 'visit', 'beach', 'mountain'],
            'entertainment': ['movie', 'film', 'show', 'series', 'watch', 'netflix', 'music', 'song'],
            'fitness': ['gym', 'workout', 'exercise', 'run', 'running', 'yoga', 'sport'],
            'technology': ['phone', 'app', 'computer', 'laptop', 'software', 'tech', 'code'],
            'work': ['work', 'job', 'meeting', 'project', 'deadline', 'office', 'boss'],
            'family': ['family', 'kids', 'children', 'parents', 'mom', 'dad', 'brother', 'sister'],
        }

        for category, keywords in categories.items():
            if keyword in keywords:
                return category

        return 'general'

    def _media_type_name(self, ext: str) -> str:
        """Convert file extension to human-readable media type."""
        media_names = {
            'jpg': 'photos', 'jpeg': 'photos', 'png': 'photos', 'gif': 'GIFs',
            'mp4': 'videos', 'mov': 'videos', 'avi': 'videos',
            'mp3': 'audio messages', 'ogg': 'voice notes', 'opus': 'voice notes',
            'pdf': 'documents', 'doc': 'documents', 'docx': 'documents',
            'vcf': 'contacts', 'webp': 'stickers'
        }
        return media_names.get(ext.lower(), f'{ext} files')

    # =========================================================================
    # Account Info Export Parsing (GDPR exports with groups.json, communities.json)
    # =========================================================================

    async def _parse_account_info_dir(
        self,
        dir_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse WhatsApp Account Info export directory."""
        # Find the whatsapp_connections directory
        connections_dir = dir_path / 'whatsapp_connections'
        if not connections_dir.exists():
            # Maybe we're already in the connections dir or parent
            if dir_path.name == 'whatsapp_connections':
                connections_dir = dir_path
            elif (dir_path / 'extracted' / 'whatsapp_connections').exists():
                connections_dir = dir_path / 'extracted' / 'whatsapp_connections'
            else:
                logger.warning(f"Could not find whatsapp_connections in {dir_path}")
                return

        # Parse groups.json
        groups_file = connections_dir / 'groups.json'
        if groups_file.exists():
            async for pref in self._parse_groups_json(groups_file, default_compartment):
                yield pref

        # Parse communities.json
        communities_file = connections_dir / 'communities.json'
        if communities_file.exists():
            async for pref in self._parse_communities_json(communities_file, default_compartment):
                yield pref

    async def _parse_groups_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse groups.json from WhatsApp Account Info export.

        Extracts interests/topics from group names using pattern matching.
        Group names like "AI Tinkerers", "3D Printing gurus", "Bikers" reveal interests.
        """
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse groups.json: {e}")
            return

        groups = data.get('wa_groups', [])
        if not groups:
            logger.warning(f"No wa_groups found in {file_path}")
            return

        # Filter out empty groups
        groups = [g for g in groups if g and g.strip()]
        total_groups = len(groups)

        logger.info(f"Processing {total_groups} WhatsApp groups from {file_path}")

        # Track topics extracted and their source groups
        topic_groups: Dict[str, List[str]] = defaultdict(list)  # topic -> [group_names]
        meaningful_groups: List[str] = []
        filtered_noise: int = 0
        filtered_work: int = 0

        for group_name in groups:
            group_name = group_name.strip()
            if not group_name:
                continue

            # Check if this is noise (generic group names)
            if self._is_noise_group(group_name):
                filtered_noise += 1
                continue

            # Check if this is work-operational (not interest-revealing)
            if self._is_work_operational_group(group_name):
                filtered_work += 1
                continue

            # Extract topics from this group name
            topics = self._extract_topics_from_group(group_name)

            if topics:
                meaningful_groups.append(group_name)
                for topic, category in topics:
                    topic_groups[topic].append(group_name)

        logger.info(
            f"WhatsApp groups analysis: {total_groups} total, "
            f"{len(meaningful_groups)} meaningful, "
            f"{filtered_noise} noise filtered, "
            f"{filtered_work} work-operational filtered, "
            f"{len(topic_groups)} unique topics extracted"
        )

        # Yield group membership count as a social signal
        yield ParsedPreference(
            subject=f"WhatsApp group memberships ({total_groups} groups)",
            preference_type="Pattern",
            category="social",
            strength=min(0.5 + (total_groups * 0.0003), 0.85),
            source=self.source_name,
            compartment_level=default_compartment,
            size="Large",
            extra={
                "type": "social_network_size",
                "total_groups": total_groups,
                "meaningful_groups": len(meaningful_groups),
                "filtered_noise": filtered_noise,
                "filtered_work": filtered_work,
                "unique_topics": len(topic_groups)
            }
        )

        # Yield preferences for each topic, with strength based on group count
        for topic, source_groups in topic_groups.items():
            group_count = len(source_groups)

            # Strength based on number of groups with this topic
            # 1 group = 0.55, 2 = 0.60, 3 = 0.65, etc.
            strength = min(0.5 + (group_count * 0.05), 0.90)

            # Determine category from the topic (stored during extraction)
            category = self._get_topic_category(topic)

            yield ParsedPreference(
                subject=f"interested in: {topic}",
                preference_type="Like",
                category=category,
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "group_topic_interest",
                    "topic": topic,
                    "group_count": group_count,
                    "source_groups": source_groups[:10],  # Limit to 10 examples
                    "extraction_method": "group_name_pattern"
                }
            )

    async def _parse_communities_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse communities.json from WhatsApp Account Info export.

        Communities are organized groups with sub-groups, often representing
        larger interest communities (e.g., "AI Tinkerers Hong Kong", "Posit Network").
        """
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse communities.json: {e}")
            return

        communities = data.get('wa_communities', [])
        if not communities:
            logger.warning(f"No wa_communities found in {file_path}")
            return

        logger.info(f"Processing {len(communities)} WhatsApp communities from {file_path}")

        for community in communities:
            if not isinstance(community, dict):
                continue

            subject = community.get('subject', '').strip()
            description = community.get('description', '').strip()
            sub_groups = community.get('sub_groups', [])
            creation_ts = community.get('creation')

            if not subject:
                continue

            # Skip noise communities
            if self._is_noise_group(subject):
                continue

            # Extract topics from community name and description
            topics_from_name = self._extract_topics_from_group(subject)
            topics_from_desc = self._extract_topics_from_group(description) if description else []

            all_topics = list(set(topics_from_name + topics_from_desc))

            # Parse creation timestamp
            observed_at = None
            if creation_ts:
                try:
                    observed_at = datetime.fromtimestamp(creation_ts)
                except (ValueError, OSError):
                    pass

            # Sub-groups count indicates community size/engagement
            sub_group_count = len(sub_groups) if sub_groups else 0
            sub_group_names = [sg.get('subject', '') for sg in sub_groups if isinstance(sg, dict)]

            # Yield community membership preference
            strength = min(0.6 + (sub_group_count * 0.02), 0.85)

            yield ParsedPreference(
                subject=f"member of community: {subject}",
                preference_type="Like",
                category="networking",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                observed_at=observed_at,
                extra={
                    "type": "community_membership",
                    "community_name": subject,
                    "description": description[:200] if description else None,
                    "sub_group_count": sub_group_count,
                    "sub_group_names": sub_group_names[:5],  # First 5
                    "topics_extracted": [t[0] for t in all_topics]
                }
            )

            # Yield topic preferences from community
            for topic, category in all_topics:
                yield ParsedPreference(
                    subject=f"interested in: {topic}",
                    preference_type="Like",
                    category=category,
                    strength=0.25,  # V2: Community membership
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    observed_at=observed_at,
                    extra={
                        "type": "community_topic_interest",
                        "topic": topic,
                        "source_community": subject,
                        "extraction_method": "community_name_pattern"
                    }
                )

    def _is_noise_group(self, group_name: str) -> bool:
        """Check if a group name is noise (generic, event-based, etc.)."""
        name_lower = group_name.lower().strip()

        # Check against noise patterns
        for pattern in NOISE_PATTERNS:
            if re.search(pattern, name_lower, re.IGNORECASE):
                return True

        # Too short to be meaningful
        if len(name_lower) < 3:
            return True

        return False

    def _is_work_operational_group(self, group_name: str) -> bool:
        """Check if a group is work-operational (not interest-revealing)."""
        name_lower = group_name.lower()

        for pattern in WORK_GROUP_PATTERNS:
            if re.search(pattern, name_lower, re.IGNORECASE):
                return True

        return False

    def _extract_topics_from_group(self, group_name: str) -> List[Tuple[str, str]]:
        """
        Extract topics from a group name using pattern matching.

        Returns list of (topic, category) tuples.
        """
        if not group_name:
            return []

        topics: List[Tuple[str, str]] = []
        name_lower = group_name.lower()

        # Try each topic pattern
        for pattern, (topic, category) in TOPIC_PATTERNS.items():
            if re.search(pattern, group_name, re.IGNORECASE):
                topics.append((topic, category))

        return topics

    def _get_topic_category(self, topic: str) -> str:
        """Get the category for a topic (reverse lookup from TOPIC_PATTERNS)."""
        for pattern, (t, category) in TOPIC_PATTERNS.items():
            if t == topic:
                return category
        return "interest"  # Default category
