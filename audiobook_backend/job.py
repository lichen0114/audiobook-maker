import argparse
import importlib.metadata
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from checkpoint import CheckpointInspection, get_checkpoint_dir, inspect_checkpoint

from .chunking import split_text_to_chunks
from .epub_parser import PARSER_VERSION, parse_epub
from .metadata import apply_metadata_overrides
from .models import BookMetadata, ParsedEpub
from .runtime import (
    default_chunk_chars_for_backend,
    is_low_memory_apple_host,
    resolve_backend,
    resolve_device_for_args,
    resolve_pipeline_mode_for_args,
)


@dataclass
class PreparedJob:
    input_path: str
    output_path: str
    checkpoint_dir: str
    use_checkpoint: bool
    resolved_backend: str
    resolved_device: str
    chunk_chars: int
    pipeline_mode: str
    parsed_epub: ParsedEpub
    chapters: list[Any]
    chunks: list[Any]
    chapter_start_indices: list[tuple[int, str]]
    total_chars: int
    book_metadata: BookMetadata
    checkpoint_status: Optional[CheckpointInspection]
    warnings: list[str]


@dataclass
class JobPreparationDeps:
    resolve_backend: Callable[[str], str] = resolve_backend
    resolve_device_for_args: Callable[..., tuple[str, list[str]]] = resolve_device_for_args
    default_chunk_chars_for_backend: Callable[[str], int] = default_chunk_chars_for_backend
    resolve_pipeline_mode_for_args: Callable[..., tuple[str, list[str]]] = (
        resolve_pipeline_mode_for_args
    )
    is_low_memory_apple_host: Callable[[], bool] = is_low_memory_apple_host
    parse_epub: Callable[..., ParsedEpub] = parse_epub
    split_text_to_chunks: Callable[..., tuple[list[Any], list[tuple[int, str]]]] = (
        split_text_to_chunks
    )
    apply_metadata_overrides: Callable[[BookMetadata, argparse.Namespace], BookMetadata] = (
        apply_metadata_overrides
    )
    inspect_checkpoint: Callable[..., CheckpointInspection] = inspect_checkpoint
    get_checkpoint_dir: Callable[[str], str] = get_checkpoint_dir


DEFAULT_PREPARATION_DEPS = JobPreparationDeps()


def _cached_model_revision(repo_id: str) -> str:
    """Read Hugging Face's cached snapshot identity without making a request."""
    try:
        from huggingface_hub import try_to_load_from_cache

        cached = try_to_load_from_cache(repo_id, "config.json")
        if isinstance(cached, str):
            parts = Path(cached).parts
            if "snapshots" in parts:
                index = parts.index("snapshots")
                if index + 1 < len(parts):
                    return parts[index + 1]
    except (ImportError, OSError, ValueError):
        pass
    return "unknown"


def build_checkpoint_config(
    args: argparse.Namespace,
    resolved_backend: str,
    chunk_chars: int,
    resolved_device: str,
    selected_section_ids: Optional[list[str]] = None,
) -> dict[str, Any]:
    model_repo, distribution = {
        "mlx": ("prince-canuma/Kokoro-82M", "mlx-audio"),
        "pytorch": ("hexgrad/Kokoro-82M", "kokoro"),
        "mock": ("mock:v1", None),
    }.get(resolved_backend, (resolved_backend, None))
    try:
        model_runtime = importlib.metadata.version(distribution) if distribution else "builtin"
    except importlib.metadata.PackageNotFoundError:
        model_runtime = "unavailable"
    model_identity = f"{resolved_backend}:{model_repo}:{model_runtime}"
    if distribution:
        model_identity += ":" + _cached_model_revision(model_repo)
    return {
        "voice": args.voice,
        "speed": args.speed,
        "lang_code": args.lang_code,
        "backend": resolved_backend,
        "device": resolved_device if resolved_backend == "pytorch" else "auto",
        "chunk_chars": chunk_chars,
        "split_pattern": args.split_pattern,
        "format": args.format,
        "bitrate": args.bitrate,
        "normalize": args.normalize,
        "parser_version": PARSER_VERSION,
        "selected_section_ids": selected_section_ids,
        "model_identity": model_identity,
    }


def prepare_job(
    args: argparse.Namespace,
    *,
    inspect_checkpoint_state: bool,
    progress_callback: Optional[Callable[[int, int, int], None]] = None,
    deps: Optional[JobPreparationDeps] = None,
) -> PreparedJob:
    deps = deps or DEFAULT_PREPARATION_DEPS
    checkpoint_dir = deps.get_checkpoint_dir(args.output)
    use_checkpoint = args.checkpoint or args.resume
    resolved_backend = deps.resolve_backend(args.backend)
    resolved_device, device_warnings = deps.resolve_device_for_args(args, resolved_backend)
    chunk_chars = (
        args.chunk_chars
        if args.chunk_chars is not None
        else deps.default_chunk_chars_for_backend(resolved_backend)
    )
    pipeline_mode, pipeline_warnings = deps.resolve_pipeline_mode_for_args(
        args, use_checkpoint
    )
    warnings = [*device_warnings, *pipeline_warnings]

    if deps.is_low_memory_apple_host() and args.backend == "auto" and args.device == "auto":
        warnings.append(
            "Low-memory Apple profile detected: auto mode will use PyTorch on CPU "
            f"with {chunk_chars}-character chunks for stability."
        )
    if deps.is_low_memory_apple_host() and resolved_backend == "mlx":
        warnings.append(
            "MLX can be unstable on 8 GB Apple Silicon when processing multiple books."
        )

    parsed_epub = deps.parse_epub(args.input, progress_callback=progress_callback)
    warnings.extend(getattr(parsed_epub, "warnings", []))
    chapters = parsed_epub.chapters
    sections_file = getattr(args, "sections_file", None)
    if sections_file:
        with open(sections_file, encoding="utf-8") as selected_file:
            selected_ids = json.load(selected_file)
        if (
            not isinstance(selected_ids, list)
            or not selected_ids
            or any(not isinstance(section_id, str) for section_id in selected_ids)
            or len(set(selected_ids)) != len(selected_ids)
        ):
            raise ValueError("Section selection must be a non-empty JSON list of unique section IDs.")
        available_ids = {section.section_id for section in parsed_epub.sections}
        if set(selected_ids) - available_ids:
            raise ValueError("Section selection contains unknown IDs; inspect this EPUB again.")
        selected_set = set(selected_ids)
        for section in parsed_epub.sections:
            section.included = section.section_id in selected_set
        chapters = [section for section in parsed_epub.sections if section.included]
    selected_section_ids = [
        getattr(chapter, "section_id", "") for chapter in chapters
    ]
    chunks, chapter_start_indices = deps.split_text_to_chunks(chapters, chunk_chars)
    total_chars = sum(len(chunk.text) for chunk in chunks)

    if not chunks and not getattr(args, "inspect_job", False):
        raise ValueError("No text chunks produced from EPUB.")

    book_metadata = parsed_epub.metadata
    if args.format == "m4b":
        book_metadata = deps.apply_metadata_overrides(parsed_epub.metadata, args)

    checkpoint_status = None
    if inspect_checkpoint_state:
        checkpoint_status = deps.inspect_checkpoint(
            checkpoint_dir,
            args.input,
            build_checkpoint_config(
                args, resolved_backend, chunk_chars, resolved_device, selected_section_ids
            ),
            expected_total_chunks=len(chunks),
        )
        if checkpoint_status.missing_audio_chunks:
            warnings.append(
                f"Checkpoint is missing {len(checkpoint_status.missing_audio_chunks)} saved chunk audio file(s); "
                "those chunks will be regenerated."
            )

    return PreparedJob(
        input_path=args.input,
        output_path=args.output,
        checkpoint_dir=checkpoint_dir,
        use_checkpoint=use_checkpoint,
        resolved_backend=resolved_backend,
        resolved_device=resolved_device,
        chunk_chars=chunk_chars,
        pipeline_mode=pipeline_mode,
        parsed_epub=parsed_epub,
        chapters=chapters,
        chunks=chunks,
        chapter_start_indices=chapter_start_indices,
        total_chars=total_chars,
        book_metadata=book_metadata,
        checkpoint_status=checkpoint_status,
        warnings=warnings,
    )

