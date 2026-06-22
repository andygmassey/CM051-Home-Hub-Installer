"""Source adapters.

Each adapter exposes a ``read(...) -> Iterable[Conversation]``
function. The unifier registers adapters and merges their outputs.

Launch adapters (v0.1):
- ``zeroclaw_sessions``: ZeroClaw gateway sessions DB
- ``channel_jsonl``: per-channel JSONLs (iMessage / WhatsApp / ...)

Post-launch stubs (v0.2):
- ``claude_code_watcher``
- ``chatgpt_export``
- ``claude_desktop_leveldb``

The post-launch files exist at v0.1 to lock the plug-in contract.
Calling them raises ``NotImplementedError``.
"""
