# Formats and Metadata

This guide explains output format behavior (MP3 vs M4B) and how metadata is extracted/overridden.

## Overview

The backend supports two output formats:
- `mp3` (default)
- `m4b` (audiobook container with chapters and embedded metadata)

Both are exported through direct `ffmpeg` subprocess calls in `app.py`.

## MP3 vs M4B at a Glance

| Topic | MP3 | M4B |
| --- | --- | --- |
| Default format | Yes | No |
| Container/codec | MP3 | `.m4b` with AAC audio |
| Chapter markers | No | Yes |
| Embedded title/author | Typically not written by this pipeline | Yes (via ffmetadata) |
| Cover art embedding | No | Yes (optional) |
| Optimized streaming export path | Yes (when checkpointing is off) | No |
| Checkpoint support | Yes | Yes |

## MP3 Export Behavior

### Runtime export path

MP3 export uses `ffmpeg` directly.

Current runtime has two MP3 paths:
1. **Streaming path** (fast path)
   - Used when format is `mp3` and checkpointing is off
   - PCM is streamed directly into an `ffmpeg` subprocess
2. **Spool-file path**
   - Used when checkpointing is on (or when not using the streaming path)
   - Backend writes PCM to a temporary file, then runs `ffmpeg`

### MP3 options

- `--bitrate {128k,192k,320k}`
- `--normalize` (adds `loudnorm` audio filter)

Example:

```bash
.venv/bin/python app.py \
  --input book.epub \
  --output book.mp3 \
  --bitrate 320k \
  --normalize
```

## M4B Export Behavior

M4B export always uses a spool-file based path in the current implementation.

### What gets embedded

- title (from EPUB metadata or `--title` override)
- author (from EPUB metadata or `--author` override)
- chapter markers (derived from EPUB chapter boundaries and final sample offsets)
- optional cover image (`--cover` override or EPUB cover if present)

### M4B options

- `--format m4b`
- `--bitrate {128k,192k,320k}` (AAC bitrate)
- `--normalize`
- `--title`, `--author`, `--cover`

Example:

```bash
.venv/bin/python app.py \
  --format m4b \
  --title "My Book" \
  --author "Someone" \
  --cover ./cover.png \
  --input book.epub \
  --output book.m4b
```

## Metadata Sources and Overrides

### EPUB metadata extraction

The backend can extract EPUB metadata with:

```bash
.venv/bin/python app.py --extract_metadata --input book.epub --output /dev/null
```

The backend emits metadata events including:
- `title`
- `author`
- `has_cover`

The interactive CLI uses a helper (`cli/src/utils/metadata.ts`) that calls this mode before M4B processing.

### Override precedence for M4B

When `--format m4b` is used:
1. backend extracts metadata from the EPUB
2. optional CLI/user overrides are applied (`--title`, `--author`, `--cover`)
3. final metadata is exported through ffmetadata + `ffmpeg`

### Cover image overrides

`--cover <path>` replaces the EPUB cover (if any).

Supported extension handling in current backend code:
- `.jpg`, `.jpeg` -> `image/jpeg`
- `.png` -> `image/png`
- `.gif` -> `image/gif`
- unknown extension -> defaults to `image/jpeg`

If the file does not exist, the backend raises `FileNotFoundError`.

## Chapter Markers (M4B)

Chapter markers are generated from EPUB chapter boundaries after chunking and audio generation.

At a high level:
1. EPUB text is split into chunks while preserving chapter-start references
2. backend tracks sample offsets for each chunk during processing
3. chapter start/end samples are converted into ffmetadata chapter entries
4. `ffmpeg` writes the final M4B with embedded chapters

If a chapter title is missing, the backend falls back to `Chapter <n>`.

## Interactive CLI Metadata Flow (M4B)

Current CLI behavior (`cli/src/App.tsx` + `MetadataEditor.tsx`):
- choosing `M4B` in the config wizard triggers metadata extraction for the first selected file
- a metadata review screen lets the user:
  - keep extracted metadata
  - edit title
  - edit author
  - set a custom cover image path
- the selected values are passed to the backend as `--title`, `--author`, `--cover`

## Format-Specific Operational Notes

### Checkpointing and format choice

- Checkpointing works with both MP3 and M4B.
- Checkpointing changes MP3 export behavior (disables the streaming fast path).
- `overlap3` pipeline mode is currently restricted to MP3 without checkpointing.

### Bitrate and normalization

- `--bitrate` affects both MP3 and M4B outputs.
- `--normalize` adds an `ffmpeg` loudness filter to both formats.
- Normalization can increase processing time slightly.

## Troubleshooting

### M4B produced without expected metadata

Check:
- you used `--format m4b`
- override flags were passed correctly
- cover file path exists and is readable

### Cover override failed

Common causes:
- wrong path
- path contains shell characters without quoting
- unsupported/mislabeled file extension (backend may default MIME to JPEG)

### I expected chapter markers in MP3

Chapter markers are implemented for M4B output. Use `--format m4b`.

## Related Docs

- `README.md`
- `ARCHITECTURE.md`
- `CHECKPOINTS.md`
