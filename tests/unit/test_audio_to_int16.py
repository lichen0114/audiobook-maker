"""Tests for the audio_to_int16 function."""

import pytest
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from app import audio_to_int16


@pytest.mark.unit
class TestAudioToInt16:
    """Test cases for audio_to_int16 function."""

    def test_numpy_float_array(self):
        """Float numpy array should be converted to int16."""
        audio = np.array([0.0, 0.5, -0.5, 1.0, -1.0], dtype=np.float32)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert result[0] == 0  # 0.0 -> 0
        assert result[1] == 16383  # 0.5 -> 16383 (approx)
        assert result[2] == -16383  # -0.5 -> -16383 (approx)
        assert result[3] == 32767  # 1.0 -> 32767
        assert result[4] == -32767  # -1.0 -> -32767

    def test_clipping_above_one(self):
        """Values above 1.0 should be clipped."""
        audio = np.array([1.5, 2.0, 10.0], dtype=np.float32)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        # All values should be clipped to 32767
        assert all(r == 32767 for r in result)

    def test_clipping_below_minus_one(self):
        """Values below -1.0 should be clipped."""
        audio = np.array([-1.5, -2.0, -10.0], dtype=np.float32)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        # All values should be clipped to -32767
        assert all(r == -32767 for r in result)

    def test_int16_passthrough(self):
        """Int16 arrays should pass through unchanged."""
        audio = np.array([0, 16383, -16383, 32767, -32767], dtype=np.int16)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        np.testing.assert_array_equal(result, audio)

    def test_python_list(self):
        """Python list should be converted."""
        audio = [0.0, 0.5, -0.5]
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert len(result) == 3

    def test_empty_array(self):
        """Empty array should return empty int16 array."""
        audio = np.array([], dtype=np.float32)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert len(result) == 0

    def test_float64_array(self):
        """Float64 arrays should also work."""
        audio = np.array([0.5, -0.5], dtype=np.float64)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert result[0] == 16383
        assert result[1] == -16383


@pytest.mark.unit
class TestAudioToInt16WithTorch:
    """Test cases for audio_to_int16 with torch tensors."""

    @pytest.fixture
    def torch_available(self):
        """Check if torch is available."""
        try:
            import torch
            return True
        except ImportError:
            return False

    def test_torch_tensor_cpu(self, torch_available):
        """Torch CPU tensor should be converted."""
        if not torch_available:
            pytest.skip("torch not available")

        import torch
        audio = torch.tensor([0.5, -0.5, 1.0, -1.0], dtype=torch.float32)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert result[0] == 16383
        assert result[1] == -16383
        assert result[2] == 32767
        assert result[3] == -32767

    def test_torch_tensor_detached(self, torch_available):
        """Torch tensor with grad should be detached."""
        if not torch_available:
            pytest.skip("torch not available")

        import torch
        audio = torch.tensor([0.5, -0.5], dtype=torch.float32, requires_grad=True)
        result = audio_to_int16(audio)

        assert result.dtype == np.int16
        assert len(result) == 2
