#!/usr/bin/env python3
"""
Pre-download Kokoro TTS models before first use.

This script downloads the Kokoro model (~1GB) and voice packs so that
the first audiobook conversion doesn't have a long wait.
"""

import sys
import os

# Add some color to output
class Colors:
    CYAN = '\033[0;36m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    DIM = '\033[2m'
    NC = '\033[0m'  # No Color
    BOLD = '\033[1m'


def print_step(msg):
    print(f"\n{Colors.CYAN}{Colors.BOLD}▶ {msg}{Colors.NC}")


def print_success(msg):
    print(f"  {Colors.GREEN}✔{Colors.NC} {msg}")


def print_info(msg):
    print(f"  {Colors.DIM}{msg}{Colors.NC}")


def print_error(msg):
    print(f"  {Colors.RED}✘{Colors.NC} {msg}")


def download_kokoro_model():
    """Download the Kokoro TTS model by importing the library."""
    print_step("Downloading Kokoro TTS model...")
    print_info("This will download ~1GB of model files.")
    print_info("Files are cached in ~/.cache/huggingface/")
    print()

    try:
        # Importing kokoro triggers the model download if not cached
        print_info("Loading Kokoro library...")
        from kokoro import KPipeline

        # Initialize the pipeline - this downloads the model if needed
        print_info("Initializing model (downloading if needed)...")
        pipeline = KPipeline(lang_code='a')

        print_success("Kokoro model is ready!")

        # Also download a voice to warm up the cache
        print_step("Testing voice synthesis...")
        print_info("Generating a short test audio...")

        # Generate a tiny sample to ensure voices work
        test_text = "Hello."
        generator = pipeline(test_text, voice='af_heart', speed=1.0)

        # Just get the first chunk to verify it works
        for _, _, _ in generator:
            break

        print_success("Voice synthesis is working!")

        return True

    except ImportError as e:
        print_error(f"Failed to import Kokoro: {e}")
        print_info("Make sure you're running this from the project's virtual environment:")
        print_info("  source .venv/bin/activate")
        print_info("  python scripts/download-models.py")
        return False

    except Exception as e:
        print_error(f"Failed to download model: {e}")
        print_info("Check your internet connection and try again.")
        return False


def check_model_cache():
    """Check if models are already cached."""
    cache_dir = os.path.expanduser("~/.cache/huggingface/hub")

    # Look for Kokoro model directories
    if os.path.exists(cache_dir):
        for item in os.listdir(cache_dir):
            if "kokoro" in item.lower():
                print_info(f"Found cached model: {item}")
                return True
    return False


def download_mlx_model():
    """Download the MLX Kokoro model if mlx-audio is installed."""
    print_step("Checking for MLX-Audio backend...")

    try:
        from mlx_audio.tts.models.kokoro import KokoroPipeline
        print_info("MLX-Audio is installed, downloading MLX model...")
    except ImportError:
        print_info("MLX-Audio not installed, skipping MLX model download.")
        print_info("Install with: pip install -r requirements-mlx.txt")
        return True  # Not an error, just optional

    try:
        print_info("Initializing MLX Kokoro pipeline (downloading model if needed)...")
        pipeline = KokoroPipeline(lang_code='a')

        # Generate a tiny sample to ensure it works
        print_info("Testing MLX voice synthesis...")
        test_text = "Hello."
        generator = pipeline(test_text, voice='af_heart', speed=1.0)

        # Just get the first chunk to verify it works
        for _, _, _ in generator:
            break

        print_success("MLX model is ready!")
        return True

    except Exception as e:
        print_error(f"Failed to download MLX model: {e}")
        print_info("MLX backend may not work correctly.")
        return False


def main():
    print(f"\n{Colors.BOLD}🎧 AI Audiobook Fast - Model Downloader{Colors.NC}\n")

    # Check if already cached
    if check_model_cache():
        print_info("Kokoro model appears to be cached already.")
        print_info("Running download anyway to ensure it's complete...\n")

    # Download/verify the PyTorch model
    success = download_kokoro_model()

    # Try to download MLX model (optional)
    mlx_success = download_mlx_model()

    if success:
        print(f"\n{Colors.GREEN}{Colors.BOLD}✨ All models are ready!{Colors.NC}")
        if not mlx_success:
            print(f"{Colors.DIM}Note: MLX model download was skipped or failed.{Colors.NC}")
        print(f"{Colors.DIM}You can now run: cd cli && npm run dev{Colors.NC}\n")
        return 0
    else:
        print(f"\n{Colors.RED}Model download failed.{Colors.NC}")
        print(f"{Colors.DIM}The model will download automatically on first use.{Colors.NC}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
