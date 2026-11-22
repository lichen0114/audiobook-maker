"""User-visible preparation, preview cache, and selected chapter export."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
BOOK = ROOT / 'tests/fixtures/sample.epub'
pytestmark = pytest.mark.skipif(not shutil.which('ffmpeg'), reason='ffmpeg required')


def run(tmp_path, *flags):
    result = subprocess.run([sys.executable, str(ROOT / 'app.py'), '--input', str(BOOK),
                             '--output', str(tmp_path / 'book.mp3'), '--backend', 'mock',
                             '--event_format', 'json', '--no_rich', '--workers', '1', *flags],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]


def test_preview_is_bounded_cached_and_invalidated(tmp_path):
    first = run(tmp_path, '--preview', '--preview_seconds', '0.25')
    done = next(event for event in first if event['type'] == 'done')
    assert done['preview'] and not done['cached']
    assert Path(done['output']).stat().st_size > 0
    if shutil.which('ffprobe'):
        probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                '-of', 'default=nw=1:nk=1', done['output']],
                               capture_output=True, text=True, check=True)
        assert float(probe.stdout) < 0.4
    again = run(tmp_path, '--preview', '--preview_seconds', '0.25')
    assert next(e for e in again if e['type'] == 'done')['cached']
    changed = run(tmp_path, '--preview', '--preview_seconds', '0.25', '--voice', 'af_bella')
    assert not next(e for e in changed if e['type'] == 'done')['cached']


def test_selection_reaches_inspection_and_m4b_chapters(tmp_path):
    inspection = next(e['result'] for e in run(tmp_path, '--inspect_job') if e['type'] == 'inspection')
    sections = [s for s in inspection['sections'] if s['included']]
    assert len(sections) == 3
    selection = tmp_path / 'selection.json'
    selection.write_text(json.dumps([sections[1]['id']]))
    filtered = next(e['result'] for e in run(tmp_path, '--inspect_job', '--sections_file', str(selection))
                    if e['type'] == 'inspection')
    assert filtered['chapter_count'] == 1
    assert [s['title'] for s in filtered['sections'] if s['included']] == ['Chapter 2']
    events = run(tmp_path, '--format', 'm4b', '--output', str(tmp_path / 'selected.m4b'),
                 '--sections_file', str(selection), '--checkpoint')
    output = next(e['output'] for e in events if e['type'] == 'done')
    if shutil.which('ffprobe'):
        probe = subprocess.run(['ffprobe', '-v', 'error', '-show_chapters', '-of', 'json', output],
                               capture_output=True, text=True, check=True)
        assert [c['tags']['title'] for c in json.loads(probe.stdout)['chapters']] == ['Chapter 2']


def test_existing_audiobook_is_preserved(tmp_path):
    output = tmp_path / 'book.mp3'
    output.write_bytes(b'existing audiobook')
    events = run(tmp_path)
    actual = next(e['output'] for e in events if e['type'] == 'done')
    assert actual != str(output)
    assert output.read_bytes() == b'existing audiobook'
    assert Path(actual).stat().st_size > 0
