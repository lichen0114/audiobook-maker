"""Tests for the extract_epub_text function."""

import pytest
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from app import extract_epub_text


@pytest.mark.unit
class TestExtractEpubText:
    """Test cases for extract_epub_text function."""

    def test_valid_epub(self, mock_epub):
        """Valid EPUB should return list of (title, text) tuples."""
        result = extract_epub_text("test.epub")

        assert isinstance(result, list)
        assert len(result) == 2

        # Check first chapter
        title1, text1 = result[0]
        assert title1 == "Chapter 1"
        assert "first paragraph" in text1
        assert "second paragraph" in text1

        # Check second chapter
        title2, text2 = result[1]
        assert title2 == "Chapter 2"
        assert "Chapter two" in text2

    def test_text_cleaning(self, mock_epub):
        """Extracted text should be cleaned."""
        result = extract_epub_text("test.epub")

        # Text should not have excessive whitespace
        for _, text in result:
            assert "  " not in text  # No double spaces
            assert "\n" not in text  # No newlines (cleaned)

    def test_empty_epub_raises_error(self):
        """EPUB with no readable content should raise ValueError."""
        with patch("app.epub") as mock_epub:
            mock_book = MagicMock()
            # Return no items
            mock_book.get_items_of_type.return_value = []
            mock_epub.read_epub.return_value = mock_book

            with pytest.raises(ValueError) as excinfo:
                extract_epub_text("empty.epub")

            assert "No readable text" in str(excinfo.value)

    def test_chapter_without_title(self):
        """Chapter without title tag should have empty title."""
        with patch("app.epub") as mock_epub:
            mock_book = MagicMock()
            mock_item = MagicMock()
            # HTML without title tag
            mock_item.get_content.return_value = b"""
            <html>
                <body><p>Content without title.</p></body>
            </html>
            """
            mock_book.get_items_of_type.return_value = [mock_item]
            mock_epub.read_epub.return_value = mock_book

            result = extract_epub_text("notitle.epub")

            assert len(result) == 1
            title, text = result[0]
            assert title == ""
            assert "Content without title" in text

    def test_chapter_with_only_whitespace_skipped(self):
        """Chapters with only whitespace should be skipped."""
        with patch("app.epub") as mock_epub:
            mock_book = MagicMock()

            mock_item1 = MagicMock()
            mock_item1.get_content.return_value = b"""
            <html>
                <body>   </body>
            </html>
            """

            mock_item2 = MagicMock()
            mock_item2.get_content.return_value = b"""
            <html>
                <body><p>Real content here.</p></body>
            </html>
            """

            mock_book.get_items_of_type.return_value = [mock_item1, mock_item2]
            mock_epub.read_epub.return_value = mock_book

            result = extract_epub_text("mixed.epub")

            # Only item with content should be returned
            assert len(result) == 1
            _, text = result[0]
            assert "Real content" in text

    def test_html_tags_stripped(self):
        """HTML tags should be stripped from content."""
        with patch("app.epub") as mock_epub:
            mock_book = MagicMock()
            mock_item = MagicMock()
            mock_item.get_content.return_value = b"""
            <html>
                <head><title>Test</title></head>
                <body>
                    <h1>Heading</h1>
                    <p>Paragraph with <b>bold</b> and <i>italic</i> text.</p>
                </body>
            </html>
            """
            mock_book.get_items_of_type.return_value = [mock_item]
            mock_epub.read_epub.return_value = mock_book

            result = extract_epub_text("tagged.epub")

            _, text = result[0]
            assert "<h1>" not in text
            assert "<b>" not in text
            assert "<i>" not in text
            assert "Heading" in text
            assert "bold" in text
            assert "italic" in text


@pytest.mark.integration
class TestExtractEpubTextRealFile:
    """Integration tests with real EPUB file."""

    def test_sample_epub(self, sample_epub_path):
        """Test with actual sample EPUB file."""
        result = extract_epub_text(sample_epub_path)

        assert isinstance(result, list)
        assert len(result) >= 1

        # Verify content was extracted
        all_text = " ".join(text for _, text in result)
        assert len(all_text) > 50  # Has substantial content
