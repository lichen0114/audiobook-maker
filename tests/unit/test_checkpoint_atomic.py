"""Recovery must preserve the previous complete manifest and chunk on failure."""

from dataclasses import replace

import numpy as np
import pytest

import checkpoint


def state(**changes):
    return replace(checkpoint.CheckpointState(
        epub_hash='hash', config={}, total_chunks=2,
        completed_chunks=[0], chapter_start_indices=[(0, 'Chapter')],
    ), **changes)


def test_failed_manifest_serialization_preserves_previous_checkpoint(tmp_path):
    checkpoint.save_checkpoint(str(tmp_path), state())
    with pytest.raises(TypeError):
        checkpoint.save_checkpoint(str(tmp_path), state(config={'unserializable': object()}))
    assert checkpoint.load_checkpoint(str(tmp_path)).completed_chunks == [0]
    assert [p.name for p in tmp_path.iterdir()] == ['state.json']


def test_failed_manifest_replace_preserves_previous_checkpoint(tmp_path, monkeypatch):
    checkpoint.save_checkpoint(str(tmp_path), state())

    def fail(*args):
        raise OSError('disk full')

    monkeypatch.setattr(checkpoint.os, 'replace', fail)
    with pytest.raises(OSError, match='disk full'):
        checkpoint.save_checkpoint(str(tmp_path), state(completed_chunks=[0, 1]))
    assert checkpoint.load_checkpoint(str(tmp_path)).completed_chunks == [0]
    assert [p.name for p in tmp_path.iterdir()] == ['state.json']


def test_failed_chunk_write_preserves_previous_audio(tmp_path, monkeypatch):
    original = np.array([1, 2, 3], dtype=np.int16)
    checkpoint.save_chunk_audio(str(tmp_path), 0, original)

    def fail(file, audio, **kwargs):
        file.write(b'partial write')
        raise OSError('disk full')

    monkeypatch.setattr(checkpoint.np, 'save', fail)
    with pytest.raises(OSError, match='disk full'):
        checkpoint.save_chunk_audio(str(tmp_path), 0, np.zeros(5, dtype=np.int16))
    np.testing.assert_array_equal(checkpoint.load_chunk_audio(str(tmp_path), 0), original)
    assert [p.name for p in tmp_path.iterdir()] == ['chunk_000000.npy']


def test_truncated_legacy_chunk_is_regenerated(tmp_path):
    (tmp_path / 'chunk_000000.npy').write_bytes(b'')
    assert checkpoint.load_chunk_audio(str(tmp_path), 0) is None


@pytest.mark.parametrize('key', ['parser_version', 'selected_section_ids', 'model_identity'])
def test_new_synthesis_identity_cannot_resume_legacy_checkpoint(tmp_path, key):
    epub = tmp_path / 'book.epub'
    epub.write_bytes(b'book')
    saved = state(epub_hash=checkpoint.compute_epub_hash(str(epub)))
    checkpoint.save_checkpoint(str(tmp_path), saved)
    inspection = checkpoint.inspect_checkpoint(str(tmp_path), str(epub), {key: 'new'})
    assert not inspection.resume_compatible
    assert inspection.reason == 'config_mismatch'
