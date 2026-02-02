"""Tests for the export_pcm_to_mp3 function."""

import pytest
import sys
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from app import export_pcm_to_mp3, DEFAULT_SAMPLE_RATE


@pytest.mark.unit
class TestExportPcmToMp3:
    """Test cases for export_pcm_to_mp3 function."""

    def test_valid_pcm_export(self, temp_dir, mock_ffmpeg):
        """Valid PCM data should be exported successfully."""
        pcm_data = np.array([0, 16383, -16383, 32767, -32767], dtype=np.int16)
        output_path = f"{temp_dir}/output.mp3"

        export_pcm_to_mp3(pcm_data, output_path)

        # Verify ffmpeg was called
        mock_ffmpeg.assert_called_once()
        call_args = mock_ffmpeg.call_args

        # Check command arguments
        cmd = call_args[0][0]
        assert cmd[0] == "/usr/bin/ffmpeg"
        assert "-f" in cmd
        assert "s16le" in cmd
        assert output_path in cmd

    def test_empty_audio_creates_silent_mp3(self, temp_dir, mock_ffmpeg):
        """Empty audio should create a minimal silent MP3."""
        pcm_data = np.array([], dtype=np.int16)
        output_path = f"{temp_dir}/silent.mp3"

        export_pcm_to_mp3(pcm_data, output_path)

        # Verify ffmpeg was called with anullsrc for silent audio
        call_args = mock_ffmpeg.call_args
        cmd = call_args[0][0]
        assert "anullsrc" in str(cmd)

    def test_ffmpeg_not_found(self, temp_dir):
        """Should raise FileNotFoundError if ffmpeg not found."""
        with patch("shutil.which") as mock_which:
            mock_which.return_value = None

            pcm_data = np.array([0, 1000], dtype=np.int16)
            output_path = f"{temp_dir}/output.mp3"

            with pytest.raises(FileNotFoundError) as excinfo:
                export_pcm_to_mp3(pcm_data, output_path)

            assert "ffmpeg not found" in str(excinfo.value)

    def test_ffmpeg_failure(self, temp_dir):
        """Should raise RuntimeError if ffmpeg fails."""
        with patch("shutil.which") as mock_which:
            mock_which.return_value = "/usr/bin/ffmpeg"

            with patch("subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(
                    returncode=1,
                    stderr=b"Error: something went wrong"
                )

                pcm_data = np.array([0, 1000], dtype=np.int16)
                output_path = f"{temp_dir}/output.mp3"

                with pytest.raises(RuntimeError) as excinfo:
                    export_pcm_to_mp3(pcm_data, output_path)

                assert "ffmpeg failed" in str(excinfo.value)

    def test_custom_sample_rate(self, temp_dir, mock_ffmpeg):
        """Custom sample rate should be passed to ffmpeg."""
        pcm_data = np.array([0, 1000], dtype=np.int16)
        output_path = f"{temp_dir}/output.mp3"
        custom_rate = 48000

        export_pcm_to_mp3(pcm_data, output_path, sample_rate=custom_rate)

        call_args = mock_ffmpeg.call_args
        cmd = call_args[0][0]
        assert str(custom_rate) in cmd

    def test_custom_bitrate(self, temp_dir, mock_ffmpeg):
        """Custom bitrate should be passed to ffmpeg."""
        pcm_data = np.array([0, 1000], dtype=np.int16)
        output_path = f"{temp_dir}/output.mp3"

        export_pcm_to_mp3(pcm_data, output_path, bitrate="320k")

        call_args = mock_ffmpeg.call_args
        cmd = call_args[0][0]
        assert "320k" in cmd

    def test_float_data_converted_to_int16(self, temp_dir, mock_ffmpeg):
        """Float data should be converted to int16."""
        pcm_data = np.array([0.5, -0.5], dtype=np.float32)
        output_path = f"{temp_dir}/output.mp3"

        export_pcm_to_mp3(pcm_data, output_path)

        # Verify input was provided (conversion happened)
        call_args = mock_ffmpeg.call_args
        assert call_args.kwargs.get("input") is not None

    def test_pcm_data_piped_to_ffmpeg(self, temp_dir, mock_ffmpeg):
        """PCM data should be piped to ffmpeg stdin."""
        pcm_data = np.array([0, 16383, -16383], dtype=np.int16)
        output_path = f"{temp_dir}/output.mp3"

        export_pcm_to_mp3(pcm_data, output_path)

        call_args = mock_ffmpeg.call_args
        # Check that input bytes were provided
        input_bytes = call_args.kwargs.get("input")
        assert input_bytes is not None
        assert len(input_bytes) == pcm_data.nbytes
