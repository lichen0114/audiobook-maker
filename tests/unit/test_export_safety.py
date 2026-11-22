"""Failure boundaries for publishing audio and streaming encoder diagnostics."""

import os
import errno
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from audiobook_backend import export
from audiobook_backend.cleanup import cleanup_ffmpeg_process
from audiobook_backend.models import BookMetadata


@pytest.fixture
def successful_encoder(monkeypatch):
    calls = []

    def encode(cmd, **kwargs):
        calls.append((cmd, kwargs))
        Path(cmd[-1]).write_bytes(b'encoded audio')
        return SimpleNamespace(returncode=0, stderr=b'')

    monkeypatch.setattr(export.shutil, 'which', lambda name: '/usr/bin/ffmpeg')
    monkeypatch.setattr(export.subprocess, 'run', encode)
    return calls


@pytest.mark.parametrize('format,file_input', [('mp3', False), ('m4b', False), ('mp3', True), ('m4b', True)])
def test_every_exporter_keeps_existing_output(tmp_path, successful_encoder, format, file_input):
    output = tmp_path / f'book.{format}'
    output.write_bytes(b'original audiobook')
    data = np.array([0, 1000, -1000], dtype=np.int16)
    if file_input:
        source = tmp_path / 'input.pcm'
        source.write_bytes(data.tobytes())
        fn = getattr(export, f'export_pcm_file_to_{format}')
        source = str(source)
    else:
        fn = getattr(export, f'export_pcm_to_{format}')
        source = data
    extra = {'metadata': BookMetadata('Title', 'Author'), 'chapters': []} if format == 'm4b' else {}
    published = fn(source, str(output), **extra)
    assert output.read_bytes() == b'original audiobook'
    assert Path(published) == tmp_path / f'book (2).{format}'
    assert Path(published).read_bytes() == b'encoded audio'
    cmd = successful_encoder[0][0]
    assert cmd[-1] != str(output)
    assert Path(cmd[-1]).parent == tmp_path
    assert '-nostats' in cmd
    assert not list(tmp_path.glob('.*.partial*'))


def test_publication_handles_a_file_created_after_planning(tmp_path, monkeypatch):
    output = tmp_path / 'book.mp3'
    (tmp_path / 'book (2).mp3').write_bytes(b'another audiobook')

    def encode(cmd, **kwargs):
        Path(cmd[-1]).write_bytes(b'new audio')
        output.write_bytes(b'created while encoding')
        return SimpleNamespace(returncode=0, stderr=b'')

    monkeypatch.setattr(export.shutil, 'which', lambda _: '/usr/bin/ffmpeg')
    monkeypatch.setattr(export.subprocess, 'run', encode)
    published = export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output))
    assert Path(published).name == 'book (3).mp3'
    assert output.read_bytes() == b'created while encoding'


@pytest.mark.skipif(sys.platform != 'darwin', reason='renamex_np is a macOS API')
@pytest.mark.parametrize('failure', sorted({errno.EOPNOTSUPP, errno.ENOTSUP, errno.EPERM}))
def test_macos_exclusive_rename_fallback_preserves_existing_files(
        tmp_path, monkeypatch, successful_encoder, failure):
    output = tmp_path / 'book.mp3'
    second = tmp_path / 'book (2).mp3'
    output.write_bytes(b'original')
    second.write_bytes(b'another original')

    def unsupported_link(source, destination):
        raise OSError(failure, 'hard links not supported')

    monkeypatch.setattr(export.os, 'link', unsupported_link)
    published = export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output))
    assert Path(published) == tmp_path / 'book (3).mp3'
    assert Path(published).read_bytes() == b'encoded audio'
    assert output.read_bytes() == b'original'
    assert second.read_bytes() == b'another original'
    assert not list(tmp_path.glob('.*.partial*'))


def test_disk_errors_do_not_trigger_rename_fallback(tmp_path, monkeypatch, successful_encoder):
    output = tmp_path / 'book.mp3'
    output.write_bytes(b'original')

    def disk_full(source, destination):
        raise OSError(errno.ENOSPC, 'disk full')

    def unexpected_fallback(*args):
        pytest.fail('disk errors must not attempt another publication mechanism')

    monkeypatch.setattr(export.os, 'link', disk_full)
    monkeypatch.setattr(export, '_rename_exclusive_macos', unexpected_fallback)
    with pytest.raises(OSError, match='disk full'):
        export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output))
    assert output.read_bytes() == b'original'
    assert list(tmp_path.iterdir()) == [output]


def test_explicit_replace_preserves_original_until_encoding_succeeds(tmp_path, monkeypatch):
    output = tmp_path / 'book.mp3'
    output.write_bytes(b'original')

    def encode(cmd, **kwargs):
        assert output.read_bytes() == b'original'
        Path(cmd[-1]).write_bytes(b'replacement')
        return SimpleNamespace(returncode=0, stderr=b'')

    monkeypatch.setattr(export.shutil, 'which', lambda _: '/usr/bin/ffmpeg')
    monkeypatch.setattr(export.subprocess, 'run', encode)
    published = export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output), overwrite=True)
    assert published == str(output)
    assert output.read_bytes() == b'replacement'


def test_temporary_unlink_failure_does_not_report_successful_publication_as_failure(
        tmp_path, monkeypatch, successful_encoder, caplog):
    output = tmp_path / 'book.mp3'
    original_unlink = os.unlink

    def failed_unlink(path, *args, **kwargs):
        if '.partial.mp3' in os.fspath(path):
            raise PermissionError('temporary cleanup blocked')
        return original_unlink(path, *args, **kwargs)

    monkeypatch.setattr(export.os, 'unlink', failed_unlink)
    published = export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output))
    assert published == str(output)
    assert output.read_bytes() == b'encoded audio'
    assert 'Audiobook saved' in caplog.text
    assert caplog.text.count('temporary cleanup blocked') == 1


@pytest.mark.parametrize('returncode', [0, 1])
def test_failed_or_empty_export_never_publishes(tmp_path, monkeypatch, returncode):
    output = tmp_path / 'book.mp3'
    output.write_bytes(b'original')

    def encode(cmd, **kwargs):
        if returncode:
            Path(cmd[-1]).write_bytes(b'incomplete')
        return SimpleNamespace(returncode=returncode, stderr=b'encoder failed')

    monkeypatch.setattr(export.shutil, 'which', lambda _: '/usr/bin/ffmpeg')
    monkeypatch.setattr(export.subprocess, 'run', encode)
    with pytest.raises(RuntimeError):
        export.export_pcm_to_mp3(np.zeros(10, dtype=np.int16), str(output), overwrite=True)
    assert output.read_bytes() == b'original'
    assert list(tmp_path.iterdir()) == [output]


def test_stream_drains_large_stderr_before_consuming_input(tmp_path, monkeypatch):
    output = tmp_path / 'book.mp3'
    # A watchdog makes a pipe regression fail rather than hang the test suite.
    script = (
        'import os,sys,threading; '
        'threading.Timer(5, lambda: os._exit(99)).start(); '
        'sys.stderr.buffer.write(b"x" * 1048576); sys.stderr.buffer.flush(); '
        'audio=sys.stdin.buffer.read(); '
        'open(sys.argv[1], "wb").write(audio); os._exit(0)'
    )
    monkeypatch.setattr(export.shutil, 'which', lambda _: sys.executable)
    monkeypatch.setattr(export, '_quiet_command', lambda cmd, path: [sys.executable, '-c', script, path])
    proc = export.open_mp3_export_stream(str(output))
    try:
        proc.stdin.write(b'encoded audio')
        published = export.close_mp3_export_stream(proc)
        assert published == str(output)
        assert output.read_bytes() == b'encoded audio'
        assert len(proc._audiobook_export.capture.tail) <= export._STDERR_LIMIT
    finally:
        cleanup_ffmpeg_process(proc)


def test_interrupted_stream_removes_staging_without_publishing(tmp_path, monkeypatch):
    output = tmp_path / 'book.mp3'
    script = 'import sys; open(sys.argv[1], "wb").write(b"partial"); sys.stdin.buffer.read()'
    monkeypatch.setattr(export.shutil, 'which', lambda _: sys.executable)
    monkeypatch.setattr(export, '_quiet_command', lambda cmd, path: [sys.executable, '-c', script, path])
    proc = export.open_mp3_export_stream(str(output))
    proc.terminate()
    assert cleanup_ffmpeg_process(proc) is None
    assert not output.exists()
    assert not list(tmp_path.iterdir())
