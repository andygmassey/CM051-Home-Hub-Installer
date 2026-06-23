#!/usr/bin/env python3
"""Tests for AmazonParser extracted-directory support.

Verifies that can_parse() and parse() handle a directory path (the real
Amazon data-export structure has no root zip -- the operator unpacks it and
points the ingest CLI at the top-level folder).

All fixtures are SYNTHETIC -- no real personal data is used anywhere here.
See PRODUCTISATION_CHECKLIST.md Rule 0.
"""

import asyncio
import csv
import sys
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

# Make the vendor tree importable without an installed package.
REPO = Path(__file__).resolve().parent.parent
INGEST_SRC_PARENT = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
sys.path.insert(0, str(INGEST_SRC_PARENT))

# Pre-import the amazon module so patch() can resolve the target string
# "src.parsers.amazon.settings" before tests run. The import is safe here
# because it only registers the module; no network connections are made
# until parse() is called.
import src.parsers.amazon as _amazon_module  # noqa: E402  (after sys.path tweak)
from src.parsers.amazon import AmazonParser  # noqa: E402


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_mock_settings() -> MagicMock:
    s = MagicMock()
    s.default_compartment = 2
    s.is_date_excluded.return_value = False
    return s


def _write_order_csv(path: Path, rows: int = 3) -> None:
    """Write a synthetic Retail.OrderHistory CSV with *rows* fake orders."""
    fieldnames = [
        "Order Date",
        "Order ID",
        "Order Status",
        "Shipping Date",
        "Store Name",
        "Product Name",
        "ASIN",
        "Website",
        "Quantity",
        "Product Condition",
        "Subtotal",
        "Shipping Charge",
        "Tax Before Promotions",
        "Tax Charged",
        "Promotion Applied",
        "Total Charged",
        "Tracking Number",
        "Shipment Date",
        "Delivery Date",
        "Gift Message",
        "Gift Sender Name",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        products = [
            "Synthetic Widget A",
            "Synthetic Gadget B",
            "Synthetic Gizmo C",
        ]
        for i in range(rows):
            writer.writerow({
                "Order Date": "2025-01-01",
                "Order ID": f"999-FAKE-{i:04d}",
                "Order Status": "Shipped",
                "Shipping Date": "2025-01-02",
                "Store Name": "Amazon.co.uk",
                "Product Name": products[i % len(products)],
                "ASIN": f"B0FAKE{i:04d}",
                "Website": "Amazon.co.uk",
                "Quantity": "1",
                "Product Condition": "New",
                "Subtotal": "9.99",
                "Shipping Charge": "0.00",
                "Tax Before Promotions": "2.00",
                "Tax Charged": "2.00",
                "Promotion Applied": "",
                "Total Charged": "11.99",
                "Tracking Number": "",
                "Shipment Date": "",
                "Delivery Date": "",
                "Gift Message": "",
                "Gift Sender Name": "",
            })


def _make_amazon_dir(root: Path) -> Path:
    """Build a minimal but structurally correct synthetic Amazon export tree."""
    orders = root / "Orders" / "Retail.OrderHistory.1"
    orders.mkdir(parents=True)
    _write_order_csv(orders / "Retail.OrderHistory.1.csv")

    # Also add a cart-items file for coverage.
    cart = root / "Orders" / "Retail.CartItems.1"
    cart.mkdir(parents=True)
    cart_csv = cart / "Retail.CartItems.1.csv"
    cart_csv.write_text(
        "ASIN,ProductName,DateAddedToCart,Quantity,CartList\n"
        "B0FAKE0001,Synthetic Cart Item,2025-03-01T10:00:00Z,1,Active\n",
        encoding="utf-8",
    )

    return root


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_can_parse_zip_still_works() -> None:
    """A .zip file containing Retail.OrderHistory.csv still returns True."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "amazon_export.zip"
            with zipfile.ZipFile(zip_path, "w") as zf:
                content = (
                    "Order Date,Order Status,Product Name,ASIN\n"
                    "2025-01-01,Shipped,Synthetic Item,B0FAKE0001\n"
                )
                zf.writestr(
                    "Orders/Retail.OrderHistory.1/Retail.OrderHistory.1.csv",
                    content,
                )
            result = parser.can_parse(zip_path)
            if not result:
                fail("can_parse returned False for a zip containing Retail.OrderHistory.csv")
    print("PASS: can_parse(.zip with Retail.OrderHistory.csv) == True")


def test_can_parse_csv_still_works() -> None:
    """Individual Retail.OrderHistory.1.csv file still returns True."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()
        with tempfile.TemporaryDirectory() as tmp:
            csv_path = Path(tmp) / "Retail.OrderHistory.1.csv"
            _write_order_csv(csv_path)
            result = parser.can_parse(csv_path)
            if not result:
                fail("can_parse returned False for individual Retail.OrderHistory.csv")
    print("PASS: can_parse(Retail.OrderHistory.1.csv) == True")


def test_can_parse_extracted_dir_with_orders_subdir() -> None:
    """A directory containing Orders/Retail.OrderHistory.1/ returns True."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "03 - Amazon"
            _make_amazon_dir(root)
            result = parser.can_parse(root)
            if not result:
                fail(
                    "can_parse returned False for extracted dir with Orders/ subdir"
                )
    print("PASS: can_parse(extracted dir with Orders/) == True")


def test_can_parse_extracted_dir_with_kindle_subdir() -> None:
    """A directory with only a Kindle/ subdir (no Orders/) still returns True."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "03 - Amazon"
            kindle = root / "Kindle" / "extracted"
            kindle.mkdir(parents=True)
            (kindle / "placeholder.txt").write_text("synthetic", encoding="utf-8")
            result = parser.can_parse(root)
            if not result:
                fail(
                    "can_parse returned False for extracted dir with only Kindle/ subdir"
                )
    print("PASS: can_parse(extracted dir with Kindle/) == True")


def test_can_parse_non_amazon_dir_returns_false() -> None:
    """A directory containing only Spotify files does NOT return True."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Spotify Export"
            root.mkdir()
            (root / "StreamingHistory0.json").write_text(
                '[{"ts": "2025-01-01", "trackName": "Synthetic Song"}]',
                encoding="utf-8",
            )
            (root / "Follow.json").write_text("{}", encoding="utf-8")
            result = parser.can_parse(root)
            if result:
                fail(
                    "can_parse wrongly returned True for a Spotify export directory"
                )
    print("PASS: can_parse(Spotify export dir) == False")


def test_parse_dir_yields_order_records() -> None:
    """parse() on an extracted dir yields >= 1 record (count only)."""
    with patch("src.parsers.amazon.settings", _make_mock_settings()):
        parser = AmazonParser()

        async def _run(dir_path: Path) -> int:
            count = 0
            async for _pref in parser.parse(dir_path, default_compartment=2):
                count += 1
            return count

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "03 - Amazon"
            _make_amazon_dir(root)
            record_count = asyncio.run(_run(root))
            if record_count < 1:
                fail(
                    f"parse(extracted dir) yielded {record_count} records; expected >= 1"
                )
    print(
        f"PASS: parse(extracted dir) yielded {record_count} records (>= 1 expected)"
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    test_can_parse_zip_still_works()
    test_can_parse_csv_still_works()
    test_can_parse_extracted_dir_with_orders_subdir()
    test_can_parse_extracted_dir_with_kindle_subdir()
    test_can_parse_non_amazon_dir_returns_false()
    test_parse_dir_yields_order_records()
    print("\nALL AMAZON EXTRACTED-DIR TESTS PASSED")


if __name__ == "__main__":
    main()
