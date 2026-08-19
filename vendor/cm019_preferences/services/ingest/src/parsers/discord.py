"""Discord data parser."""

import json
import csv
import io
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, List
from collections import Counter
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class DiscordParser(BaseParser):
    """
    Parser for Discord data package exports.

    Handles the official Discord data package which includes:
    - messages/ folder with channel-specific message history
    - servers/ folder with server membership info
    - activity/ folder with activity data
    - account/ folder with account settings

    Reference: https://support.discord.com/hc/en-us/articles/360004957991
    """

    source_name = "discord"

    # The four directories that sit side by side at the root of a real Discord
    # data package. Compared as whole path SEGMENTS, never as substrings.
    DISCORD_PACKAGE_DIRS = frozenset({"messages", "servers", "activity", "account"})

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Discord data package."""
        name = file_path.name.lower()
        suffix = file_path.suffix.lower()

        # Check for Discord package ZIP
        if suffix == '.zip':
            if 'discord' in name:
                return True
            # Check ZIP contents for Discord structure
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    return self._has_discord_package_layout(zf.namelist())
            except Exception:
                return False

        # Check for individual message files
        if suffix == '.json' and 'discord' in name:
            return True

        # An EXTRACTED Discord package. MEASURED on a real 2026 export: the
        # archive on disk is package.zip PLUS an extracted/ tree of 74 .json,
        # and NOT ONE of the 74 was claimable, because the test above requires
        # the literal string "discord" in the FILENAME. A real package names
        # its members messages.json, servers/index.json and so on. So the same
        # bytes were claimed correctly inside the zip and became invisible the
        # moment the customer unzipped them, which is what a customer does.
        #
        # Reuses the SAME two-of-four sibling rule as the zip path rather than
        # inventing a second predicate, so the Facebook/Instagram exclusion it
        # was hardened for holds identically here: their activity trees carry
        # a "messages" directory but only that ONE of the four names, so they
        # still score 1 and are still declined.
        if suffix in ('.json', '.csv') and self._has_discord_dir_layout(file_path):
            return True

        # Check for CSV message format (older exports)
        if suffix == '.csv' and 'messages' in name and 'discord' in name:
            return True

        return False

    @classmethod
    def _has_discord_dir_layout(cls, file_path: Path) -> bool:
        """Is this file inside an EXTRACTED Discord package on disk?

        The zip branch answers this from a namelist. Once the customer unzips,
        there is no namelist, and the filename test above fails because a real
        package names its members messages.json / servers/index.json, never
        anything containing the literal string "discord".

        Deliberately the SAME rule as _has_discord_package_layout: at least TWO
        of the four package directories present as SIBLINGS of each other. One
        alone is not enough, and that is what keeps Facebook and Instagram out:
        their activity trees carry a "messages" directory and none of the other
        three, so they score 1 and are declined here exactly as they are in the
        zip path.

        Walks the ancestors rather than assuming a fixed depth, because
        Discord ships packages both flat and wrapped in a single top folder,
        and the customer may unzip either into a directory of their choosing.
        """
        seen_ancestor_dirs = 0
        for ancestor in file_path.parents:
            try:
                children = {c.name.lower() for c in ancestor.iterdir() if c.is_dir()}
            except (OSError, PermissionError):
                continue
            if len(cls.DISCORD_PACKAGE_DIRS & children) >= 2:
                return True
            seen_ancestor_dirs += 1
            # Bounded: a Discord package root is never more than a handful of
            # levels above one of its own files. Walking to / would make every
            # unrelated file pay for a full upward scan.
            if seen_ancestor_dirs >= 6:
                break
        return False

    @classmethod
    def _has_discord_package_layout(cls, member_names) -> bool:
        """Return True if the archive is laid out like a Discord data package.

        Two separate things were wrong with the test this replaces, which asked
        whether any member name CONTAINED any one of "messages/", "servers/",
        "activity/" or "account/":

        1. Containment, not path-segment equality. "activity/" is a substring
           of "your_facebook_activity/" and of "your_instagram_activity/", so
           every Facebook and Instagram export handed to the product was
           claimed here. ``IngestPipeline._get_parser`` takes the FIRST parser
           that claims a file and this parser is registered ahead of
           MetaParser, so Meta was never asked. Measured on real export
           archives: 0 preferences out of a Facebook export, against 4 from
           the Meta parser that should have had it.

        2. Any ONE of the four folders was enough. Facebook and Instagram both
           ship a "messages" directory inside their activity tree, so segment
           equality ALONE would still have handed them over.

        So: compare whole path SEGMENTS, and require at least TWO of the four
        to be siblings of each other. A real Discord package has all four. An
        unrelated export that happens to contain one "messages" folder has one.

        Discord also ships packages wrapped in a single top folder, so the
        siblings are counted at the archive root and one level below it.
        """
        siblings: Dict[str, set] = {}
        for raw in member_names:
            parts = [p for p in raw.replace("\\", "/").split("/") if p]
            # A directory is only evidenced by something living underneath it.
            if len(parts) >= 2:
                siblings.setdefault("", set()).add(parts[0].lower())
            if len(parts) >= 3:
                siblings.setdefault(parts[0].lower(), set()).add(parts[1].lower())
        return any(
            len(cls.DISCORD_PACKAGE_DIRS & found) >= 2
            for found in siblings.values()
        )

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Discord data package."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info(f"Parsing Discord data from {file_path}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.json':
            async for pref in self._parse_json_file(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            async for pref in self._parse_csv_file(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Discord data package ZIP."""
        servers_joined = []
        channel_activity = Counter()
        message_count = 0
        activity_games = Counter()
        channel_names: Dict[str, str] = {}  # Map channel ID to descriptive name
        server_names: Dict[str, str] = {}   # Map server ID to name

        with zipfile.ZipFile(file_path, 'r') as zf:
            file_list = zf.namelist()

            # First, load index files for better naming
            # Servers/index.json: {"server_id": "Server Name", ...}
            for name in file_list:
                if name.lower() == 'servers/index.json':
                    try:
                        content = zf.read(name).decode('utf-8')
                        # Server names dict available for server ID -> name mapping
                        _ = json.loads(content)
                    except Exception:
                        pass
                    break

            # Messages/index.json: {"channel_id": "channel_name in Server Name", ...}
            for name in file_list:
                if name.lower() == 'messages/index.json':
                    try:
                        content = zf.read(name).decode('utf-8')
                        channel_names = json.loads(content)
                    except Exception:
                        pass
                    break

            # Parse servers (only guild.json files contain server membership info)
            # Discord exports have paths like "Servers/123/guild.json" (no leading slash)
            # Other files like channels.json, audit-log.json, etc. should be skipped
            for name in file_list:
                if 'servers/' in name.lower() and name.endswith('guild.json'):
                    try:
                        content = zf.read(name).decode('utf-8')
                        data = json.loads(content)
                        if isinstance(data, dict) and 'name' in data:
                            servers_joined.append(data)
                    except Exception:
                        pass

            # Parse messages
            for name in file_list:
                name_lower = name.lower()

                # Messages folder structure: Messages/c{channel_id}/messages.json
                if 'messages/' in name_lower and name.endswith('.json') and 'index.json' not in name_lower:
                    try:
                        content = zf.read(name).decode('utf-8')
                        data = json.loads(content)

                        # Handle both array of messages and object with messages array
                        messages = data if isinstance(data, list) else data.get('messages', [])

                        if messages:
                            channel_id = self._extract_channel_id(name)
                            channel_activity[channel_id] += len(messages)
                            message_count += len(messages)
                    except Exception:
                        pass

                # CSV messages (older format)
                elif 'messages/' in name_lower and name.endswith('.csv'):
                    try:
                        content = zf.read(name).decode('utf-8')
                        reader = csv.DictReader(io.StringIO(content))
                        for row in reader:
                            message_count += 1
                            channel_id = row.get('channel_id', 'unknown')
                            channel_activity[channel_id] += 1
                    except Exception:
                        pass

            # Parse activity (games played, etc.)
            for name in file_list:
                if 'activity/' in name.lower() and name.endswith('.json'):
                    try:
                        content = zf.read(name).decode('utf-8')
                        data = json.loads(content)

                        # Activity data may contain games played
                        if isinstance(data, list):
                            for activity in data:
                                if isinstance(activity, dict):
                                    game_name = activity.get('application_name', activity.get('name', ''))
                                    if game_name:
                                        activity_games[game_name] += 1
                    except Exception:
                        pass

        # Store channel_names for use in yielding preferences
        self._channel_names = channel_names

        logger.info(f"Processed Discord data: {len(servers_joined)} servers, {message_count} messages, {len(activity_games)} games")

        # Yield server membership preferences
        for server in servers_joined:
            server_name = server.get('name', '')
            if not server_name:
                continue

            yield ParsedPreference(
                subject=f"Discord server: {server_name}",
                preference_type="Like",
                category="community",
                strength=0.25,  # V2: Server membership/message
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "server_membership",
                    "server_name": server_name,
                    "server_id": server.get('id', '')
                }
            )

        # Yield activity preferences for active channels
        total_messages = sum(channel_activity.values())
        for channel_id, count in channel_activity.most_common(20):
            if count < 10:  # Minimum activity threshold
                continue

            # Calculate relative activity
            activity_ratio = count / total_messages if total_messages > 0 else 0
            strength = min(0.5 + (activity_ratio * 2) + (count * 0.001), 0.9)

            # Use channel name from index if available
            channel_name = channel_names.get(channel_id, f"channel {channel_id}")

            yield ParsedPreference(
                subject=f"active in Discord: {channel_name}",
                preference_type="Like",
                category="social",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "channel_activity",
                    "channel_id": channel_id,
                    "channel_name": channel_name,
                    "message_count": count
                }
            )

        # Yield gaming preferences
        for game, count in activity_games.most_common(15):
            if count < 2:  # Minimum threshold
                continue

            strength = min(0.5 + (count * 0.05), 0.9)
            yield ParsedPreference(
                subject=game,
                preference_type="Like",
                category="gaming",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "game_activity",
                    "play_count": count
                }
            )

        # NOTE: We skip yielding a generic "using Discord" preference.
        # Everyone who uses Discord would get the same subject - not useful.
        # The specific servers, channels, and games are the meaningful signals.
        if message_count > 100:
            logger.info(f"Discord activity: {message_count} messages across {len(servers_joined)} servers")

    async def _parse_json_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse individual Discord JSON file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse Discord JSON: {e}")
            return

        # Handle different file types based on content
        if isinstance(data, list):
            # Could be messages or servers list
            if data and isinstance(data[0], dict):
                if 'content' in data[0] or 'timestamp' in data[0]:
                    # Messages
                    async for pref in self._parse_messages(data, default_compartment):
                        yield pref
                elif 'name' in data[0]:
                    # Servers
                    for server in data:
                        if server.get('name'):
                            yield ParsedPreference(
                                subject=f"Discord server: {server['name']}",
                                preference_type="Like",
                                category="community",
                                strength=0.25,  # V2: Server membership/message
                                source=self.source_name,
                                compartment_level=default_compartment,
                                size="Small",
                                extra={"type": "server_membership"}
                            )
        elif isinstance(data, dict):
            if 'messages' in data:
                async for pref in self._parse_messages(data['messages'], default_compartment):
                    yield pref

    async def _parse_csv_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Discord CSV message export."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        reader = csv.DictReader(io.StringIO(content))
        message_count = 0
        channels = Counter()

        for row in reader:
            message_count += 1
            channel = row.get('channel_id', row.get('ChannelID', 'unknown'))
            channels[channel] += 1

        # NOTE: Skip generic "messaging activity" preference - not meaningful.
        # The ZIP file parser extracts specific servers and games which ARE useful.
        if message_count > 50:
            logger.info(f"Discord CSV: {message_count} messages across {len(channels)} channels")

    async def _parse_messages(
        self,
        messages: List[Dict],
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse list of Discord messages."""
        if not messages:
            return

        # Analyze message patterns
        topic_mentions = Counter()
        emoji_usage = Counter()
        link_domains = Counter()

        for msg in messages:
            content = msg.get('content', '')

            # Extract mentioned topics (simple keyword extraction)
            words = content.lower().split()
            for word in words:
                if len(word) > 4 and word.isalpha():
                    topic_mentions[word] += 1

            # Track emoji usage
            import re
            emojis = re.findall(r'<:\w+:\d+>|[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF]', content)
            for emoji in emojis:
                emoji_usage[emoji] += 1

            # Track link sharing
            urls = re.findall(r'https?://([^/\s]+)', content)
            for domain in urls:
                link_domains[domain] += 1

        # Yield preferences for frequently shared domains
        for domain, count in link_domains.most_common(10):
            if count < 3:
                continue

            yield ParsedPreference(
                subject=f"sharing content from {domain}",
                preference_type="Like",
                category="content",
                strength=min(0.5 + (count * 0.05), 0.8),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "link_sharing",
                    "domain": domain,
                    "share_count": count
                }
            )

    def _extract_channel_id(self, path: str) -> str:
        """Extract channel ID from message file path."""
        import re
        # Pattern: messages/c{channel_id}/messages.json
        match = re.search(r'/c(\d+)/', path)
        if match:
            return match.group(1)

        # Alternative: messages/{channel_id}/
        match = re.search(r'/messages/(\d+)/', path)
        if match:
            return match.group(1)

        return 'unknown'
