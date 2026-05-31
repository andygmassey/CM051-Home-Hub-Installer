"""Allow running the enrichment CLI as a module.

Usage:
    python -m src.cli enrich --category book --limit 100
    python -m src.cli stats
"""

from .cli import main

if __name__ == "__main__":
    main()
