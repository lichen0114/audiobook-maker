"""PyTorch-based Kokoro TTS backend."""

from typing import Generator
import numpy as np

from .base import TTSBackend
from .model_preparation import (
    emit_model_progress, prepare_model_files, preload_local_voices, voice_filenames,
)


class KokoroPyTorchBackend(TTSBackend):
    """TTS backend using the Kokoro library with PyTorch.

    This is the default backend that uses PyTorch for inference.
    On Apple Silicon Macs, it can use MPS (Metal Performance Shaders)
    for GPU acceleration.
    """

    def __init__(self):
        self._pipeline = None
        self._model = None
        self._sample_rate = 24000
        self.model_progress_callback = None
        self.requested_voice = 'af_heart'

    @property
    def name(self) -> str:
        return "pytorch"

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    def initialize(self, lang_code: str = "a", device: str = "auto") -> None:
        """Initialize the Kokoro PyTorch pipeline.

        Args:
            lang_code: Language code ('a' for American English, 'b' for British English)
            device: Requested torch device ('auto', 'cpu', or 'mps')
        """
        from kokoro import KModel, KPipeline
        import torch

        resolved_device = device
        if resolved_device == "auto":
            if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                resolved_device = "mps"
            else:
                resolved_device = 'cuda' if torch.cuda.is_available() else 'cpu'

        if resolved_device == "mps":
            if not hasattr(torch.backends, "mps") or not torch.backends.mps.is_available():
                raise RuntimeError("MPS requested but not available")
        paths = prepare_model_files(
            'hexgrad/Kokoro-82M',
            ['config.json', 'kokoro-v1_0.pth', *voice_filenames(self.requested_voice, '.pt')],
            self.model_progress_callback,
        )
        emit_model_progress(self.model_progress_callback, 'loading', message='Loading the local voice model…')
        self._model = KModel(config=paths['config.json'], model=paths['kokoro-v1_0.pth']).to(resolved_device).eval()
        self._pipeline = KPipeline(lang_code=lang_code, model=self._model)
        preload_local_voices(self._pipeline, self.requested_voice, paths, '.pt')
        emit_model_progress(self.model_progress_callback, 'ready', message='Voice model ready.')

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
        self._model = None
        # Optionally clear CUDA/MPS cache
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
                    torch.mps.empty_cache()
        except ImportError:
            pass
