"""Checkpoint management for resumable audiobook generation."""

import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Any, Tuple

import numpy as np


@dataclass
class CheckpointState:
    """State saved in a checkpoint for resumable processing."""
    epub_hash: str
    config: Dict[str, Any]
    total_chunks: int
    completed_chunks: List[int]
    chapter_start_indices: List[Tuple[int, str]]

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'CheckpointState':
        return cls(
            epub_hash=data['epub_hash'],
            config=data['config'],
            total_chunks=data['total_chunks'],
            completed_chunks=data['completed_chunks'],
            chapter_start_indices=[tuple(x) for x in data['chapter_start_indices']],
        )


@dataclass
class CheckpointInspection:
    """Detailed checkpoint compatibility result for planning and resume UX."""

    exists: bool
    resume_compatible: bool
    total_chunks: Optional[int] = None
    completed_chunks: int = 0
    reason: Optional[str] = None
    missing_audio_chunks: Optional[List[int]] = None


def compute_epub_hash(epub_path: str) -> str:
    """Compute SHA-256 hash of EPUB file for verification."""
    hasher = hashlib.sha256()
    with open(epub_path, 'rb') as f:
        # Read in chunks to handle large files
        while chunk := f.read(8192):
            hasher.update(chunk)
    return hasher.hexdigest()


def get_checkpoint_dir(output_path: str) -> str:
    """Get the checkpoint directory path for a given output file."""
    return f"{output_path}.checkpoint"


def save_checkpoint(checkpoint_dir: str, state: CheckpointState) -> None:
    """Publish a complete manifest without truncating the last good checkpoint."""
    os.makedirs(checkpoint_dir, exist_ok=True)
    state_path = os.path.join(checkpoint_dir, 'state.json')
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode='w', encoding='utf-8', dir=checkpoint_dir,
            prefix='.state-', suffix='.tmp', delete=False,
        ) as f:
            temp_path = f.name
            json.dump(state.to_dict(), f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, state_path)
        _sync_directory(checkpoint_dir)
    finally:
        if temp_path is not None:
            _remove_if_present(temp_path)


def _remove_if_present(path: str) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _sync_directory(path: str) -> None:
    """Persist a rename when directory fsync is supported by the filesystem."""
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        # Some filesystems do not support syncing directories. The file itself
        # is already synced and the rename is still atomic.
        pass


def load_checkpoint(checkpoint_dir: str) -> Optional[CheckpointState]:
    """Load checkpoint state from disk."""
    state_path = os.path.join(checkpoint_dir, 'state.json')
    if not os.path.exists(state_path):
        return None
    try:
        with open(state_path, 'r') as f:
            data = json.load(f)
        return CheckpointState.from_dict(data)
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


def save_chunk_audio(checkpoint_dir: str, chunk_idx: int, audio: np.ndarray) -> None:
    """Publish chunk audio before the manifest may reference it."""
    os.makedirs(checkpoint_dir, exist_ok=True)
    chunk_path = os.path.join(checkpoint_dir, f'chunk_{chunk_idx:06d}.npy')
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=checkpoint_dir, prefix=f'.chunk-{chunk_idx:06d}-',
            suffix='.tmp', delete=False,
        ) as f:
            temp_path = f.name
            np.save(f, audio, allow_pickle=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, chunk_path)
        _sync_directory(checkpoint_dir)
    finally:
        if temp_path is not None:
            _remove_if_present(temp_path)


def load_chunk_audio(checkpoint_dir: str, chunk_idx: int) -> Optional[np.ndarray]:
    """Load a single chunk's audio data from the checkpoint directory."""
    chunk_path = os.path.join(checkpoint_dir, f'chunk_{chunk_idx:06d}.npy')
    if not os.path.exists(chunk_path):
        return None
    try:
        return np.load(chunk_path, allow_pickle=False)
    except (IOError, ValueError, EOFError):
        return None


def load_all_chunk_audio(checkpoint_dir: str, total_chunks: int) -> Dict[int, np.ndarray]:
    """Load all available chunk audio from checkpoint directory."""
    results: Dict[int, np.ndarray] = {}
    for chunk_idx in range(total_chunks):
        audio = load_chunk_audio(checkpoint_dir, chunk_idx)
        if audio is not None:
            results[chunk_idx] = audio
    return results


def cleanup_checkpoint(checkpoint_dir: str) -> None:
    """Remove checkpoint directory and all its contents."""
    if os.path.exists(checkpoint_dir):
        shutil.rmtree(checkpoint_dir)


def inspect_checkpoint(
    checkpoint_dir: str,
    epub_path: str,
    config: Dict[str, Any],
    expected_total_chunks: Optional[int] = None,
) -> CheckpointInspection:
    """Inspect a checkpoint using the same compatibility rules as resume mode."""
    state = load_checkpoint(checkpoint_dir)
    if state is None:
        return CheckpointInspection(exists=False, resume_compatible=False, reason="missing")

    # Verify EPUB hash
    current_hash = compute_epub_hash(epub_path)
    if state.epub_hash != current_hash:
        return CheckpointInspection(
            exists=True,
            resume_compatible=False,
            total_chunks=state.total_chunks,
            completed_chunks=len(state.completed_chunks),
            reason="hash_mismatch",
        )

    # Verify key config options match.
    # Include text splitting and export options to avoid resuming incompatible jobs.
    key_options = [
        'voice',
        'speed',
        'lang_code',
        'backend',
        'device',
        'chunk_chars',
        'split_pattern',
        'parser_version',
        'selected_section_ids',
        'model_identity',
        'format',
        'bitrate',
        'normalize',
    ]
    for key in key_options:
        if state.config.get(key) != config.get(key):
            return CheckpointInspection(
                exists=True,
                resume_compatible=False,
                total_chunks=state.total_chunks,
                completed_chunks=len(state.completed_chunks),
                reason="config_mismatch",
            )

    if expected_total_chunks is not None and state.total_chunks != expected_total_chunks:
        return CheckpointInspection(
            exists=True,
            resume_compatible=False,
            total_chunks=state.total_chunks,
            completed_chunks=len(state.completed_chunks),
            reason="chunk_mismatch",
        )

    missing_audio_chunks = [
        chunk_idx
        for chunk_idx in state.completed_chunks
        if load_chunk_audio(checkpoint_dir, chunk_idx) is None
    ]
    usable_completed = len(state.completed_chunks) - len(missing_audio_chunks)

    return CheckpointInspection(
        exists=True,
        resume_compatible=True,
        total_chunks=state.total_chunks,
        completed_chunks=max(usable_completed, 0),
        missing_audio_chunks=missing_audio_chunks,
    )


def verify_checkpoint(checkpoint_dir: str, epub_path: str, config: Dict[str, Any]) -> bool:
    """Verify that a checkpoint is valid for the current job."""
    return inspect_checkpoint(
        checkpoint_dir,
        epub_path,
        config,
    ).resume_compatible
