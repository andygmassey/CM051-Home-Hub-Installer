"""Tests for Safari bookmarks extractor."""
from __future__ import annotations

import plistlib
import tempfile
from pathlib import Path

import pytest

from ostler_fda.safari_bookmarks import (
    Bookmark,
    _walk_bookmarks,
    extract_bookmarks,
    reading_list,
    top_bookmark_domains,
)


def _create_bookmarks_plist(path: Path, bookmarks: list[dict]) -> None:
    """Create a Safari Bookmarks.plist with test data."""
    plist = {
        "WebBookmarkType": "WebBookmarkTypeList",
        "Title": "Root",
        "Children": bookmarks,
    }
    with open(path, "wb") as f:
        plistlib.dump(plist, f)


def _make_bookmark(url: str, title: str) -> dict:
    return {
        "WebBookmarkType": "WebBookmarkTypeLeaf",
        "URLString": url,
        "URIDictionary": {"title": title},
    }


def _make_folder(name: str, children: list[dict]) -> dict:
    return {
        "WebBookmarkType": "WebBookmarkTypeList",
        "Title": name,
        "Children": children,
    }


class TestExtractBookmarks:
    """Test bookmark extraction from plist."""

    def test_basic_extraction(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [
            _make_bookmark("https://example.com/", "Example"),
            _make_bookmark("https://github.com/", "GitHub"),
        ])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert len(bookmarks) == 2
        assert bookmarks[0].url == "https://example.com/"
        assert bookmarks[0].title == "Example"
        assert bookmarks[0].domain == "example.com"

    def test_nested_folders(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [
            _make_folder("AI Research", [
                _make_bookmark("https://arxiv.org/", "arXiv"),
                _make_bookmark("https://huggingface.co/", "HuggingFace"),
            ]),
            _make_folder("News", [
                _make_bookmark("https://bbc.co.uk/", "BBC"),
            ]),
        ])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert len(bookmarks) == 3
        assert bookmarks[0].folder == "AI Research"
        assert bookmarks[2].folder == "News"

    def test_reading_list_folder_renamed(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [
            _make_folder("com.apple.ReadingList", [
                _make_bookmark("https://longread.com/article", "Long Article"),
            ]),
        ])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert len(bookmarks) == 1
        assert bookmarks[0].folder == "Reading List"

    def test_favourites_folder_renamed(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [
            _make_folder("BookmarksBar", [
                _make_bookmark("https://fav.com/", "Favourite"),
            ]),
        ])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert bookmarks[0].folder == "Favourites"

    def test_skips_non_http(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [
            _make_bookmark("javascript:void(0)", "Bookmarklet"),
            _make_bookmark("https://valid.com/", "Valid"),
        ])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert len(bookmarks) == 1
        assert bookmarks[0].domain == "valid.com"

    def test_empty_plist(self, tmp_path):
        plist = tmp_path / "Bookmarks.plist"
        _create_bookmarks_plist(plist, [])
        bookmarks = extract_bookmarks(plist_path=plist)
        assert bookmarks == []

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_bookmarks(plist_path=tmp_path / "nonexistent.plist")


class TestReadingList:
    """Test reading list filter."""

    def test_filters_to_reading_list(self):
        bookmarks = [
            Bookmark("A", "https://a.com/", "a.com", "Reading List"),
            Bookmark("B", "https://b.com/", "b.com", "Favourites"),
            Bookmark("C", "https://c.com/", "c.com", "Reading List"),
        ]
        rl = reading_list(bookmarks)
        assert len(rl) == 2
        assert all(b.folder == "Reading List" for b in rl)


class TestTopBookmarkDomains:
    """Test domain ranking."""

    def test_counts_and_sorts(self):
        bookmarks = [
            Bookmark("A1", "https://a.com/1", "a.com", "Root"),
            Bookmark("A2", "https://a.com/2", "a.com", "Root"),
            Bookmark("B1", "https://b.com/1", "b.com", "Root"),
        ]
        result = top_bookmark_domains(bookmarks)
        assert result[0] == ("a.com", 2)
        assert result[1] == ("b.com", 1)

    def test_limit(self):
        bookmarks = [
            Bookmark(f"D{i}", f"https://d{i}.com/", f"d{i}.com", "Root")
            for i in range(10)
        ]
        result = top_bookmark_domains(bookmarks, limit=3)
        assert len(result) == 3
