# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Audiobook Fast converts EPUB files into MP3 audiobooks using the Kokoro TTS engine. It has a two-tier architecture:
- **Frontend CLI** (`cli/`): Node.js/TypeScript/React terminal UI using Ink
- **Backend** (`app.py`): Python script handling EPUB parsing and TTS generation

The CLI spawns the Python process and communicates via stdout (IPC protocol with structured messages).

## Common Commands

### Setup (Recommended: One-Command)
```bash
./setup.sh  # Installs everything automatically (Homebrew, FFmpeg, Python, Node.js, deps)
```

### Setup (Manual)
```bash
# Python environment
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# CLI dependencies
cd cli && npm install
```

### Development
```bash
cd cli
npm run dev              # Start interactive CLI
npm run dev:mps          # With Apple Silicon GPU acceleration
npm run build            # Compile TypeScript to dist/
npm start                # Run compiled version
```

### Testing
```bash
# Python tests (from repo root)
pytest                         # Run all tests with coverage
pytest tests/unit              # Unit tests only
pytest tests/integration       # Integration tests only
pytest -k test_clean_text      # Run single test by name
pytest -m slow                 # Run tests marked as slow

# CLI tests (from cli/)
cd cli
npm test                       # Run all tests
npm run test:watch             # Watch mode
npm run test:coverage          # With coverage report
```

### Direct Python Usage
```bash
python app.py --input book.epub --output book.mp3 --voice af_heart --speed 1.0
```

## Architecture

### Frontend (cli/src/)
- `index.tsx` - Entry point
- `App.tsx` - Main component with state machine: `checking` → `setup-required`|`welcome` → `files` → `config` → `processing` → `done`
- `components/` - UI components (Header, FileSelector, ConfigPanel, BatchProgress, GpuMonitor, KeyboardHint, SetupRequired)
- `utils/tts-runner.ts` - Spawns Python process, sets MPS env vars, parses stdout progress
- `utils/preflight.ts` - Checks for FFmpeg, Python venv, and Kokoro installation before starting

### Setup Scripts (scripts/)
- `setup-macos.sh` - Main setup logic for macOS (Homebrew, FFmpeg, Python, Node.js, venv, deps)
- `check-python.sh` - Finds compatible Python (3.10-3.12) from Homebrew, pyenv, or system
- `download-models.py` - Pre-downloads Kokoro TTS model (~1GB) before first use

### Backend (app.py)
Uses sequential GPU inference + background encoding (optimized for Apple Silicon MPS):
1. Main thread extracts EPUB text, splits into ~1200-char chunks
2. Main thread runs Kokoro inference sequentially (GPU), queues audio for encoding
3. Background thread converts audio tensors to int16 numpy arrays
4. Results stored as numpy arrays, concatenated with `np.concatenate()` (O(n) vs O(n²))
5. Raw PCM piped directly to ffmpeg for MP3 export (bypasses WAV 4GB limit)

**Why not multi-threaded GPU?** MPS serializes GPU operations, so multiple workers queue up waiting. Testing showed 0.88x slower with threading.

**Why direct ffmpeg instead of pydub?** pydub's `export()` creates an intermediate WAV file, which has a 4GB limit (~24.9 hours at 24kHz 16-bit mono). Long audiobooks exceed this. The `export_pcm_to_mp3()` function pipes raw PCM via stdin to ffmpeg, avoiding this limitation.

Key Python args: `--input`, `--output`, `--voice`, `--speed`, `--chunk_chars`

### IPC Protocol
Python outputs to stdout, parsed by `tts-runner.ts`:
```
PHASE:PARSING              # Before text extraction
PHASE:INFERENCE            # Before inference loop
PHASE:CONCATENATING        # Before np.concatenate()
PHASE:EXPORTING            # Before MP3 export
METADATA:total_chars:N     # After text extraction (character count)
WORKER:0:INFER:Chunk X/Y   # Per-chunk inference status
TIMING:chunk_idx:ms        # Per-chunk timing in milliseconds
HEARTBEAT:timestamp        # Every 5 seconds during inference
PROGRESS:N/M chunks        # Overall progress
```

### MPS Environment Variables
When MPS is enabled, `tts-runner.ts` sets:
- `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0` - Aggressive memory cleanup
- `OMP_NUM_THREADS=4` / `OPENBLAS_NUM_THREADS=2` - Reduce GIL contention

## Key Dependencies

- **Python**: kokoro (TTS), ebooklib (EPUB), torch, numpy
- **Node.js**: react, ink (terminal UI), commander (CLI args), glob (file patterns)
- **System**: FFmpeg (required for MP3 export), Python 3.10-3.12 (Kokoro requirement)

## Voice Options

American: `af_heart` (default), `af_bella`, `af_nicole`, `af_sarah`, `af_sky`, `am_adam`, `am_michael`
British: `bf_emma`, `bf_isabella`, `bm_george`, `bm_lewis`
