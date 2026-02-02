"""Tests for the generate_audio_segments function."""

import pytest
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from app import generate_audio_segments


@pytest.mark.unit
class TestGenerateAudioSegments:
    """Test cases for generate_audio_segments function."""

    def test_yields_audio_arrays(self):
        """Should yield audio arrays from pipeline."""
        mock_pipeline = MagicMock()

        # Create mock audio output
        mock_audio = np.random.randn(24000).astype(np.float32)
        mock_pipeline.return_value = [
            ("graphemes1", "phonemes1", mock_audio),
            ("graphemes2", "phonemes2", mock_audio),
        ]

        results = list(generate_audio_segments(
            pipeline=mock_pipeline,
            text="Hello world",
            voice="af_heart",
            speed=1.0,
            split_pattern=r"\n+",
        ))

        assert len(results) == 2
        for result in results:
            assert isinstance(result, np.ndarray)

    def test_passes_params_to_pipeline(self):
        """Should pass correct parameters to pipeline."""
        mock_pipeline = MagicMock()
        mock_pipeline.return_value = []

        list(generate_audio_segments(
            pipeline=mock_pipeline,
            text="Test text",
            voice="af_bella",
            speed=1.5,
            split_pattern=r"\n+",
        ))

        mock_pipeline.assert_called_once_with(
            "Test text",
            voice="af_bella",
            speed=1.5,
            split_pattern=r"\n+",
        )

    def test_empty_text(self):
        """Empty text should yield nothing."""
        mock_pipeline = MagicMock()
        mock_pipeline.return_value = []

        results = list(generate_audio_segments(
            pipeline=mock_pipeline,
            text="",
            voice="af_heart",
            speed=1.0,
            split_pattern=r"\n+",
        ))

        assert results == []

    def test_generator_behavior(self):
        """Should be a generator, not eagerly evaluated."""
        mock_pipeline = MagicMock()
        mock_audio = np.random.randn(24000).astype(np.float32)

        # Use a list with side effects to track iteration
        call_count = [0]

        def mock_generator(*args, **kwargs):
            for i in range(3):
                call_count[0] += 1
                yield (f"g{i}", f"p{i}", mock_audio)

        mock_pipeline.side_effect = mock_generator

        gen = generate_audio_segments(
            pipeline=mock_pipeline,
            text="Test",
            voice="af_heart",
            speed=1.0,
            split_pattern=r"\n+",
        )

        # Generator created but not iterated
        assert call_count[0] == 0

        # Iterate one item
        next(gen)
        assert call_count[0] == 1

    def test_different_voices(self):
        """Should handle different voice parameters."""
        mock_pipeline = MagicMock()
        mock_pipeline.return_value = []

        voices = ["af_heart", "af_bella", "am_adam", "bf_emma", "bm_george"]

        for voice in voices:
            list(generate_audio_segments(
                pipeline=mock_pipeline,
                text="Test",
                voice=voice,
                speed=1.0,
                split_pattern=r"\n+",
            ))

            # Verify voice was passed correctly
            last_call = mock_pipeline.call_args
            assert last_call.kwargs["voice"] == voice

    def test_different_speeds(self):
        """Should handle different speed parameters."""
        mock_pipeline = MagicMock()
        mock_pipeline.return_value = []

        speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

        for speed in speeds:
            list(generate_audio_segments(
                pipeline=mock_pipeline,
                text="Test",
                voice="af_heart",
                speed=speed,
                split_pattern=r"\n+",
            ))

            last_call = mock_pipeline.call_args
            assert last_call.kwargs["speed"] == speed
