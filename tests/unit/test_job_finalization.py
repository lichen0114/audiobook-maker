"""A successfully published audiobook remains successful if housekeeping fails."""
from dataclasses import replace
from pathlib import Path
import shutil
import sys
from unittest.mock import MagicMock

import pytest

from audiobook_backend.cli import DEFAULT_MAIN_DEPS, main, parse_args


@pytest.mark.skipif(not shutil.which('ffmpeg'), reason='ffmpeg required')
def test_cleanup_errors_warn_after_success(monkeypatch, tmp_path):
    output = tmp_path / 'finished.mp3'
    source = Path(__file__).resolve().parents[1] / 'fixtures/sample.epub'
    monkeypatch.setattr(sys, 'argv', ['app.py', '--input', str(source), '--output', str(output),
                                    '--backend', 'mock', '--checkpoint', '--no_rich', '--workers', '1'])
    args = parse_args()
    events = MagicMock()
    def failed_cleanup(_path):
        raise PermissionError('saved progress is read-only')
    deps = replace(DEFAULT_MAIN_DEPS, parse_args=lambda: args,
                   event_emitter_cls=lambda **kwargs: events,
                   cleanup_checkpoint=failed_cleanup,
                   cleanup_backend=lambda backend: RuntimeError('model cleanup failed'))
    main(deps)
    assert output.is_file() and output.stat().st_size > 0
    assert any(call.args[0] == 'done' for call in events.emit.call_args_list)
    assert events.warn.call_count == 2
    events.error.assert_not_called()
