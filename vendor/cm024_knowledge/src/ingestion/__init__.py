# Ingestion pipeline components
from .enex_parser import ENEXParser

# Lazy imports for components not yet implemented
__all__ = [
    "ENEXParser",
]

def __getattr__(name):
    """Lazy import for components not yet implemented."""
    if name == "MarkdownWriter":
        from .markdown_writer import MarkdownWriter
        return MarkdownWriter
    elif name == "PrivacyClassifier":
        from .classifier import PrivacyClassifier
        return PrivacyClassifier
    elif name == "ImportanceScorer":
        from .importance_scorer import ImportanceScorer
        return ImportanceScorer
    elif name == "SemanticChunker":
        from .chunker import SemanticChunker
        return SemanticChunker
    elif name == "Embedder":
        from .embedder import Embedder
        return Embedder
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
