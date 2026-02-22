# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) and other coding agents working in this repository.

## Project Overview

AI Audiobook Fast converts EPUB files into MP3 or M4B audiobooks using Kokoro TTS.

Runtime architecture:
- `cli/`: interactive terminal UI (TypeScript + Ink + React)
- `app.py`: Python backend for EPUB parsing, TTS generation, checkpointing, and export
- `backends/`: pluggable TTS backends (`pytorch`, `mlx`, `mock`)
- `checkpoint.py`: resumable processing state and chunk persistence

The CLI launches the Python backend as a subprocess and parses its event stream (JSON in normal CLI operation; legacy text parsers remain for some helper flows).

## Documentation Map

Use these docs together when changing behavior:
- `README.md`: end-user setup and usage
- `ARCHITECTURE.md`: runtime design, pipeline modes, IPC
- `CHECKPOINTS.md`: checkpoint/resume details
- `FORMATS_AND_METADATA.md`: MP3/M4B and metadata behavior

## Common Commands

### Setup

```bash
./setup.sh

# Manual setup
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Optional test tooling
pip install -r requirements-dev.txt

# Optional MLX backend (Apple Silicon)
pip install -r requirements-mlx.txt

# CLI deps
npm install --prefix cli
```

### Development (interactive CLI)

```bash
npm run dev --prefix cli
npm run dev:mps --prefix cli
npm run build --prefix cli
npm start --prefix cli
```

### Testing

```bash
# Python fast tests + coverage gate used in CI workflow
.venv/bin/python -m pytest -m "not slow" --cov=app --cov-fail-under=75

# Python subprocess e2e tests
.venv/bin/python -m pytest tests/e2e

# Slow format/ffmpeg validation tests
.venv/bin/python -m pytest -m slow

# CLI tests
npm test --prefix cli
npm run test:coverage --prefix cli
```

### Direct Backend Usage (Examples)

```bash
# Basic MP3
.venv/bin/python app.py --input book.epub --output book.mp3

# Explicit backend
.venv/bin/python app.py --backend mlx --input book.epub --output book.mp3

# M4B with metadata overrides
.venv/bin/python app.py --format m4b --title "Title" --author "Author" \
  --cover ./cover.jpg --input book.epub --output book.m4b

# Checkpoint create/resume
.venv/bin/python app.py --checkpoint --input book.epub --output book.mp3
.venv/bin/python app.py --resume --input book.epub --output book.mp3

# Integration mode (JSON events)
.venv/bin/python app.py --event_format json --log_file ./run.log \
  --input book.epub --output book.mp3
```

## Current Architecture Highlights

### CLI flow (`cli/src/App.tsx`)

Current screen/state sequence:
- `checking`
- `setup-required` or `welcome`
- `files`
- `config`
- `metadata` (M4B only)
- `resume` (when checkpoint exists and is valid)
- `processing`
- `done`

Important implementation details:
- M4B runs call `extractMetadata()` before processing and allow title/author/cover overrides.
- Checkpoint pre-check uses `checkCheckpoint()` and shows a resume dialog before starting.
- Choosing “start fresh” deletes `<output>.checkpoint/` for the checked file.

### Backend (`app.py`)

Key runtime responsibilities:
- parse flags and validate inputs
- resolve TTS backend (`auto`, `pytorch`, `mlx`, `mock`)
- choose pipeline mode (`sequential` or `overlap3`)
- parse EPUB and chunk text
- emit progress events
- manage checkpoints and resume logic
- export MP3/M4B through `ffmpeg`

### Pipeline modes

- `sequential`: default for most paths, required for checkpointed runs and M4B
- `overlap3`: optimized MP3 path (no checkpoints) using threaded inference/conversion queues

`app.py` will warn and fall back to sequential if `--pipeline_mode overlap3` is requested for unsupported combinations.

### Export paths

Runtime export is `ffmpeg`-based (direct subprocess invocation):
- MP3 can stream PCM directly to an `ffmpeg` subprocess when checkpoints are off
- MP3 and M4B can also use a temporary PCM spool file path
- M4B export writes chapter metadata and optional cover art via ffmetadata + `ffmpeg`

Do not document runtime export as `pydub`-driven.

## Backend Flags Worth Knowing

Frequently changed / easy to drift:
- `--backend`, `--format`, `--bitrate`, `--normalize`
- `--checkpoint`, `--resume`, `--check_checkpoint`
- `--pipeline_mode`, `--prefetch_chunks`, `--pcm_queue_size`
- `--event_format`, `--log_file`
- `--title`, `--author`, `--cover`
- `--extract_metadata`

Notes:
- `--workers` is currently a compatibility flag; inference remains sequential.
- `--no_checkpoint` is deprecated and currently a no-op (checkpointing is opt-in).

## IPC Protocol (CLI <-> Python)

Backend event categories include:
- `phase`, `metadata`, `timing`, `heartbeat`, `worker`, `progress`, `checkpoint`, `error`, `done`
- `log` (JSON mode only; emitted by backend `info()` / `warn()` helpers)

The CLI runner (`cli/src/utils/tts-runner.ts`):
- always passes `--event_format json`
- writes backend logs to a timestamped file (`~/.audiobook-maker/logs` or repo `.logs` fallback)
- parses JSON first, then legacy text lines as fallback

Legacy text parsing is still used directly by helper utilities like:
- `cli/src/utils/metadata.ts`
- `cli/src/utils/checkpoint.ts`

## Environment Variables (CLI Runner / Local Dev)

Recognized or relevant variables:
- `AUDIOBOOK_PYTHON`: preferred Python executable for CLI subprocesses
- `PYTHON`: secondary Python override candidate
- `AUDIOBOOK_VERBOSE=1`: echo parsed backend output lines to CLI stderr
- `AUDIOBOOK_OMP_THREADS`: override derived `OMP_NUM_THREADS`
- `AUDIOBOOK_OPENBLAS_THREADS`: override derived `OPENBLAS_NUM_THREADS`

When using PyTorch + MPS path, the CLI runner may set:
- `PYTORCH_ENABLE_MPS_FALLBACK=1`
- `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0`
- `OMP_NUM_THREADS=<derived>`
- `OPENBLAS_NUM_THREADS=<derived>`

## Contributor Checklist For Behavior Changes

If you change any of the following, update docs in the same PR:
- backend flags or defaults
- checkpoint validation rules or event codes
- output format behavior (MP3/M4B, metadata, cover handling)
- CLI workflow screens or config wizard steps
- IPC event payloads or parsing semantics

Minimum docs to review per change:
- `README.md`
- `ARCHITECTURE.md`
- `CHECKPOINTS.md` and/or `FORMATS_AND_METADATA.md`
