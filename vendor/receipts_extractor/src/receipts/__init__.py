"""Local receipt and order-confirmation extractor.

Reads mail that is already on the device, classifies receipts, extracts
structured rows and normalises them into the row shapes the Personal World
Graph (PWG) importers emit. No network access: nothing here fetches remote
images, follows links or calls a hosted service.
"""

from .extractor import ReceiptExtractor, ReceiptStore
from .models import CATEGORIES, Receipt

__all__ = ["ReceiptExtractor", "ReceiptStore", "Receipt", "CATEGORIES"]
