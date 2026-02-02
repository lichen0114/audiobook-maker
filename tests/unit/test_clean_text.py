"""Tests for the _clean_text function."""

import pytest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from app import _clean_text


@pytest.mark.unit
class TestCleanText:
    """Test cases for _clean_text function."""

    def test_multiple_spaces(self):
        """Multiple spaces should be collapsed to single space."""
        assert _clean_text("hello    world") == "hello world"
        assert _clean_text("a   b   c") == "a b c"

    def test_newlines(self):
        """Newlines should be converted to spaces."""
        assert _clean_text("hello\nworld") == "hello world"
        assert _clean_text("line1\n\n\nline2") == "line1 line2"

    def test_tabs(self):
        """Tabs should be converted to spaces."""
        assert _clean_text("hello\tworld") == "hello world"
        assert _clean_text("a\t\t\tb") == "a b"

    def test_mixed_whitespace(self):
        """Mixed whitespace should be normalized."""
        assert _clean_text("hello\n\t  world") == "hello world"
        assert _clean_text(" \n\t multiple \t\n spaces \n ") == "multiple spaces"

    def test_empty_string(self):
        """Empty string should return empty string."""
        assert _clean_text("") == ""

    def test_whitespace_only(self):
        """Whitespace-only string should return empty string."""
        assert _clean_text("   ") == ""
        assert _clean_text("\n\n\n") == ""
        assert _clean_text("\t\t\t") == ""
        assert _clean_text("  \n  \t  ") == ""

    def test_strip_leading_trailing(self):
        """Leading and trailing whitespace should be stripped."""
        assert _clean_text("  hello  ") == "hello"
        assert _clean_text("\nhello\n") == "hello"
        assert _clean_text("  hello world  ") == "hello world"

    def test_normal_text(self):
        """Normal text without extra whitespace should be unchanged."""
        assert _clean_text("hello world") == "hello world"
        assert _clean_text("The quick brown fox") == "The quick brown fox"

    def test_unicode_text(self):
        """Unicode text should be preserved."""
        assert _clean_text("Hello  world") == "Hello world"
        assert _clean_text("Cafe\n\nau lait") == "Cafe au lait"

    def test_punctuation_preserved(self):
        """Punctuation should be preserved."""
        assert _clean_text("Hello,   world!") == "Hello, world!"
        assert _clean_text("End.\n\nStart.") == "End. Start."
