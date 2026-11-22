"""Preview uses a bounded synthesis input and never overwrites an audiobook."""
from argparse import Namespace
from types import SimpleNamespace
from unittest.mock import MagicMock
import json

import numpy as np
import pytest

from audiobook_backend.models import ParsedSection
from audiobook_backend.preview import create_preview


def context(tmp_path):
    args = Namespace(output=str(tmp_path / 'book.mp3'), preview_seconds=0.01, voice='af_heart',
                     speed=1.0, lang_code='a', split_pattern=r'\n+', format='mp3',
                     bitrate='192k', normalize=False)
    section = ParsedSection('One', 'hello ' * 200, section_id='one')
    prepared = SimpleNamespace(chapters=[section], resolved_backend='mock', chunk_chars=600,
                               resolved_device='cpu')
    backend = MagicMock(sample_rate=24000)
    backend.generate.return_value = iter([np.ones(1000, dtype=np.int16)])
    def export(pcm, output, **kwargs):
        from pathlib import Path
        assert len(Path(pcm).read_bytes()) == 480
        Path(output).write_bytes(b'preview audio')
        return output
    deps = SimpleNamespace(prepare_job=MagicMock(return_value=prepared), preparation_deps=None,
                            create_backend=MagicMock(return_value=backend),
                            start_heartbeat_emitter=MagicMock(return_value=(MagicMock(), MagicMock())),
                            export_pcm_file_to_mp3=export, cleanup_backend=MagicMock(),
                            cleanup_spool_path=MagicMock())
    return args, deps, backend, MagicMock()


def test_cache_hit_and_voice_change(tmp_path):
    args, deps, backend, events = context(tmp_path)
    from pathlib import Path
    Path(args.output).write_bytes(b'original audiobook')
    create_preview(args, deps, events)
    assert len(backend.generate.call_args.kwargs['text'].split()) == 100
    assert Path(args.output).read_bytes() == b'original audiobook'
    events.emit.assert_called_with('done', output=events.emit.call_args.kwargs['output'], preview=True, cached=False)
    deps.create_backend.reset_mock()
    create_preview(args, deps, events)
    deps.create_backend.assert_not_called()
    assert events.emit.call_args.kwargs['cached']
    args.voice = 'af_bella'
    backend.generate.return_value = iter([np.ones(1000, dtype=np.int16)])
    create_preview(args, deps, events)
    deps.create_backend.assert_called_once()
    assert not events.emit.call_args.kwargs['cached']
    args.voice = 'af_heart'
    deps.create_backend.reset_mock()
    create_preview(args, deps, events)
    deps.create_backend.assert_not_called()
    assert events.emit.call_args.kwargs['cached']


def test_failed_initialization_cleans_up_and_does_not_cache(tmp_path):
    args, deps, backend, events = context(tmp_path)
    backend.initialize.side_effect = RuntimeError('offline without model')
    with pytest.raises(RuntimeError, match='offline'):
        create_preview(args, deps, events)
    deps.cleanup_backend.assert_called_once_with(backend)
    stop, thread = deps.start_heartbeat_emitter.return_value
    stop.set.assert_called_once()
    thread.join.assert_called_once()
    from pathlib import Path
    assert not Path(args.output + '.preview.json').exists()


def test_malformed_cache_does_not_prevent_preview(tmp_path):
    args, deps, backend, events = context(tmp_path)
    create_preview(args, deps, events)
    cache = next(tmp_path.glob('*.preview.json'))
    cache.write_text('[]')
    backend.generate.return_value = iter([np.ones(1000, dtype=np.int16)])
    create_preview(args, deps, events)
    assert not events.emit.call_args.kwargs['cached']
