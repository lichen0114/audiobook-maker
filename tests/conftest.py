"""Shared pytest fixtures for all tests."""

import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import numpy as np

# Add the project root to the path
sys.path.insert(0, str(Path(__file__).parent.parent))


@pytest.fixture
def temp_dir():
    """Create a temporary directory for test files."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield tmpdir


@pytest.fixture
def sample_epub_path():
    """Path to the sample EPUB fixture."""
    return str(Path(__file__).parent / "fixtures" / "sample.epub")


@pytest.fixture
def mock_kpipeline():
    """Mock KPipeline for testing without loading the model."""
    with patch("app.KPipeline") as mock:
        # Create a mock pipeline that yields audio segments
        mock_instance = MagicMock()

        def mock_call(text, voice, speed, split_pattern):
            # Yield mock audio segments based on text length
            segment_count = max(1, len(text) // 200)
            for i in range(segment_count):
                # Create mock audio: (graphemes, phonemes, audio_array)
                mock_audio = np.random.randn(24000).astype(np.float32)  # 1 second of audio
                yield (f"segment_{i}", f"phonemes_{i}", mock_audio)

        mock_instance.side_effect = mock_call
        mock_instance.return_value = mock_call
        mock.return_value = mock_instance
        yield mock


@pytest.fixture
def mock_epub():
    """Create a mock EPUB book object."""
    with patch("app.epub") as mock_epub_module:
        # Create mock book
        mock_book = MagicMock()

        # Create mock document items
        mock_item1 = MagicMock()
        mock_item1.get_content.return_value = b"""
        <html>
            <head><title>Chapter 1</title></head>
            <body>
                <p>This is the first paragraph of chapter one.</p>
                <p>This is the second paragraph with more content.</p>
            </body>
        </html>
        """

        mock_item2 = MagicMock()
        mock_item2.get_content.return_value = b"""
        <html>
            <head><title>Chapter 2</title></head>
            <body>
                <p>Chapter two begins here with some text.</p>
                <p>The story continues with more paragraphs.</p>
            </body>
        </html>
        """

        mock_book.get_items_of_type.return_value = [mock_item1, mock_item2]
        mock_epub_module.read_epub.return_value = mock_book

        yield mock_epub_module


@pytest.fixture
def sample_chapters():
    """Sample chapter data for testing text processing."""
    return [
        ("Chapter 1", "This is the first paragraph. This is the second paragraph with more content."),
        ("Chapter 2", "Chapter two begins here. The story continues with more text."),
    ]


@pytest.fixture
def sample_audio_float():
    """Sample float32 audio array."""
    return np.array([0.5, -0.5, 1.0, -1.0, 0.0, 0.3, -0.8], dtype=np.float32)


@pytest.fixture
def sample_audio_int16():
    """Sample int16 audio array."""
    return np.array([16383, -16383, 32767, -32767, 0, 9830, -26214], dtype=np.int16)


@pytest.fixture
def mock_ffmpeg(temp_dir):
    """Mock ffmpeg subprocess for testing export."""
    with patch("shutil.which") as mock_which:
        mock_which.return_value = "/usr/bin/ffmpeg"

        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stderr=b"")
            yield mock_run


@pytest.fixture
def capture_stdout(capsys):
    """Capture stdout for testing IPC messages."""
    return capsys
