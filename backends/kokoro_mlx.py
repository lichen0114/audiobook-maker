"""MLX-based Kokoro TTS backend for Apple Silicon."""

import importlib.util
from typing import Generator
import numpy as np

from .base import TTSBackend
from .model_preparation import (
    emit_model_progress, prepare_model_files, preload_local_voices, voice_filenames,
)


class KokoroMLXBackend(TTSBackend):
    """TTS backend using MLX for Apple Silicon optimization.

    This backend uses mlx-audio which provides significantly faster
    inference on Apple Silicon Macs (M1/M2/M3/M4) compared to PyTorch.
    Typical performance is >20x real-time.
    """

    def __init__(self):
        self._pipeline = None
        self._sample_rate = 24000
        self.model_progress_callback = None
        self.requested_voice = 'af_heart'

    @property
    def name(self) -> str:
        return "mlx"

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    def initialize(self, lang_code: str = "a", device: str = "auto") -> None:
        """Initialize the Kokoro MLX pipeline.

        Args:
            lang_code: Language code ('a' for American English, 'b' for British English)
            device: Ignored for MLX; present for interface compatibility
        """
        try:
            from mlx_audio.tts.models.kokoro import KokoroPipeline
            import mlx_audio.tts as tts
        except ImportError as e:
            raise ImportError(
                "MLX backend requires mlx-audio. Install with: pip install mlx-audio"
            ) from e

        # Load the model first, then create the pipeline
        repo_id = "prince-canuma/Kokoro-82M"
        paths = prepare_model_files(
            repo_id,
            ['config.json', 'kokoro-v1_0.safetensors',
             *voice_filenames(self.requested_voice, '.safetensors')],
            self.model_progress_callback,
        )
        emit_model_progress(self.model_progress_callback, 'loading', message='Loading the local voice model…')
        from pathlib import Path
        model = tts.load(Path(paths['config.json']).parent, model_type='kokoro')
        self._pipeline = KokoroPipeline(lang_code=lang_code, model=model, repo_id=repo_id)
        preload_local_voices(self._pipeline, self.requested_voice, paths, '.safetensors')
        emit_model_progress(self.model_progress_callback, 'ready', message='Voice model ready.')

    def generate(
        self,
        text: str,
        voice: str,
        speed: float,
        split_pattern: str = r"\n+",
    ) -> Generator[np.ndarray, None, None]:
        """Generate audio using Kokoro MLX.

        Args:
            text: Text to synthesize
            voice: Voice identifier
            speed: Speech speed multiplier
            split_pattern: Regex for internal text splitting (may not be used by MLX)

        Yields:
            Audio arrays (1D numpy arrays, float32)
        """
        if self._pipeline is None:
            raise RuntimeError("Backend not initialized. Call initialize() first.")

        import mlx.core as mx

        # mlx-audio's KokoroPipeline returns Result objects with .audio attribute
        generator = self._pipeline(
            text, voice=voice, speed=speed, split_pattern=split_pattern
        )
        for result in generator:
            # Result object has .audio attribute containing the MLX array
            audio = result.audio
            # Convert MLX array to numpy
            if isinstance(audio, mx.array):
                audio = np.array(audio)
            # MLX returns (1, samples) shape, flatten to 1D for consistency with PyTorch backend
            if audio.ndim == 2:
                audio = audio.squeeze(0)
            yield audio

    def cleanup(self) -> None:
        """Release MLX resources."""
        self._pipeline = None
        # MLX manages memory automatically, but we can clear the cache
        try:
            import mlx.core as mx

            mx.clear_cache()
        except (ImportError, AttributeError):
            pass


def is_mlx_available() -> bool:
    """Check if MLX backend is available (mlx-audio installed)."""
    return importlib.util.find_spec("mlx_audio") is not None
