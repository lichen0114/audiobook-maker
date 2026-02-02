"""PyTorch-based Kokoro TTS backend."""

from typing import Generator
import numpy as np

from .base import TTSBackend


class KokoroPyTorchBackend(TTSBackend):
    """TTS backend using the Kokoro library with PyTorch.

    This is the default backend that uses PyTorch for inference.
    On Apple Silicon Macs, it can use MPS (Metal Performance Shaders)
    for GPU acceleration.
    """

    def __init__(self):
        self._pipeline = None
        self._sample_rate = 24000

    @property
    def name(self) -> str:
        return "pytorch"

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    def initialize(self, lang_code: str = "a") -> None:
        """Initialize the Kokoro PyTorch pipeline.

        Args:
            lang_code: Language code ('a' for American English, 'b' for British English)
        """
        from kokoro import KPipeline

        self._pipeline = KPipeline(lang_code=lang_code)

    def generate(
        self,
        text: str,
        voice: str,
        speed: float,
        split_pattern: str = r"\n+",
    ) -> Generator[np.ndarray, None, None]:
        """Generate audio using Kokoro PyTorch.

        Args:
            text: Text to synthesize
            voice: Voice identifier
            speed: Speech speed multiplier
            split_pattern: Regex for internal text splitting

        Yields:
            Audio arrays (torch tensors that will be converted to numpy)
        """
        if self._pipeline is None:
            raise RuntimeError("Backend not initialized. Call initialize() first.")

        generator = self._pipeline(
            text, voice=voice, speed=speed, split_pattern=split_pattern
        )
        for _, _, audio in generator:
            yield audio

    def cleanup(self) -> None:
        """Release PyTorch resources."""
        self._pipeline = None
        # Optionally clear CUDA/MPS cache
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                # MPS doesn't have explicit cache clearing, but we can hint at it
                pass
        except ImportError:
            pass
