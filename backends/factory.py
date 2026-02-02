"""Factory function for creating TTS backends."""

from typing import List

from .base import TTSBackend


def create_backend(backend_type: str) -> TTSBackend:
    """Create a TTS backend instance.

    Args:
        backend_type: The type of backend to create ('pytorch' or 'mlx')

    Returns:
        An instance of TTSBackend

    Raises:
        ValueError: If the backend type is unknown
        ImportError: If the required dependencies are not installed
    """
    if backend_type == "pytorch":
        from .kokoro_pytorch import KokoroPyTorchBackend

        return KokoroPyTorchBackend()
    elif backend_type == "mlx":
        from .kokoro_mlx import KokoroMLXBackend

        return KokoroMLXBackend()
    else:
        raise ValueError(
            f"Unknown backend type: {backend_type}. "
            f"Available backends: {get_available_backends()}"
        )


def get_available_backends() -> List[str]:
    """Get a list of available backend types.

    Returns:
        List of backend type strings that can be used with create_backend()
    """
    backends = ["pytorch"]  # PyTorch is always available if kokoro is installed

    # Check if MLX is available
    try:
        from .kokoro_mlx import is_mlx_available

        if is_mlx_available():
            backends.append("mlx")
    except ImportError:
        pass

    return backends
