"""Model readiness and byte progress, using only fake local Hub downloads."""

from pathlib import Path
from types import SimpleNamespace
import sys
from unittest.mock import MagicMock

import pytest

from backends.model_preparation import prepare_model_files, preload_local_voices, voice_filenames


def test_cached_model_never_checks_network(tmp_path, monkeypatch):
    import huggingface_hub as hub

    model = tmp_path / 'model'
    model.write_bytes(b'cached weights')
    monkeypatch.setattr(hub, 'try_to_load_from_cache', lambda repo, name: str(model))
    download = MagicMock(side_effect=AssertionError('network must not be called'))
    monkeypatch.setattr(hub, 'hf_hub_download', download)
    progress = []
    paths = prepare_model_files('test/model', ['weights'], lambda **event: progress.append(event))
    assert paths == {'weights': str(model)}
    download.assert_not_called()
    assert progress[-1]['status'] == 'cached'
    assert progress[-1]['total_bytes'] == len(b'cached weights')


def test_download_reports_actual_bytes_and_known_total(tmp_path, monkeypatch):
    import huggingface_hub as hub

    monkeypatch.setattr(hub, 'try_to_load_from_cache', lambda repo, name: None)
    sizes = {'config.json': 6, 'weights': 10}
    calls = []

    def download(repo, name, *, dry_run=False, tqdm_class=None):
        calls.append((name, dry_run))
        if dry_run:
            return SimpleNamespace(file_size=sizes[name])
        with tqdm_class(total=sizes[name], unit='B') as bar:
            bar.update(sizes[name] // 2)
            bar.update(sizes[name] - sizes[name] // 2)
        path = tmp_path / name
        path.write_bytes(b'x' * sizes[name])
        return str(path)

    monkeypatch.setattr(hub, 'hf_hub_download', download)
    progress = []
    paths = prepare_model_files('test/model', list(sizes), lambda **event: progress.append(event))
    assert list(paths) == list(sizes)
    assert progress[-1]['downloaded_bytes'] == 16
    assert progress[-1]['total_bytes'] == 16
    assert all(event['downloaded_bytes'] <= 16 for event in progress)
    assert calls == [('config.json', True), ('weights', True), ('config.json', False), ('weights', False)]


def test_partial_cache_downloads_only_missing_voice(tmp_path, monkeypatch):
    import huggingface_hub as hub

    cached = tmp_path / 'weights'
    cached.write_bytes(b'cached model')
    monkeypatch.setattr(hub, 'try_to_load_from_cache', lambda repo, name: str(cached) if name == 'weights' else None)
    downloaded = []

    # Older supported Hub versions do not expose dry_run. Counts remain honest
    # and indeterminate until a download finishes.
    def download(repo, name, *, tqdm_class=None):
        downloaded.append(name)
        path = tmp_path / 'voice'
        path.write_bytes(b'voice')
        return str(path)

    monkeypatch.setattr(hub, 'hf_hub_download', download)
    progress = []
    prepare_model_files('test/model', ['weights', 'voice'], lambda **event: progress.append(event))
    assert downloaded == ['voice']
    assert cached.read_bytes() == b'cached model'
    assert progress[-1]['downloaded_bytes'] == 5
    assert progress[-1]['total_bytes'] == 0


def test_download_failure_is_actionable_and_keeps_cached_files(tmp_path, monkeypatch):
    import huggingface_hub as hub

    cached = tmp_path / 'weights'
    cached.write_bytes(b'cached model')
    monkeypatch.setattr(hub, 'try_to_load_from_cache', lambda repo, name: str(cached) if name == 'weights' else None)

    def download(repo, name, *, tqdm_class=None):
        raise OSError('network unavailable')

    monkeypatch.setattr(hub, 'hf_hub_download', download)
    progress = []
    with pytest.raises(RuntimeError, match='Check your connection and available disk space'):
        prepare_model_files('test/model', ['weights', 'voice'], lambda **event: progress.append(event))
    assert progress[-1]['status'] == 'error'
    assert 'completed downloads are kept' in progress[-1]['message']
    assert cached.exists()


def test_preload_voices_uses_local_paths_and_preserves_voice_names():
    assert voice_filenames('af_heart,bf_emma', '.pt') == ['voices/af_heart.pt', 'voices/bf_emma.pt']
    assert voice_filenames('/local/voice.pt', '.pt') == []
    pack = object()
    pipeline = SimpleNamespace(voices={}, load_voice=MagicMock(return_value=pack))
    preload_local_voices(pipeline, 'af_heart', {'voices/af_heart.pt': '/cached/voice.pt'}, '.pt')
    pipeline.load_voice.assert_called_once_with('/cached/voice.pt')
    assert pipeline.voices['af_heart'] is pack


def test_mlx_initialization_loads_prepared_snapshot_with_explicit_model_type(tmp_path, monkeypatch):
    from backends import kokoro_mlx

    model = object()
    pipeline = SimpleNamespace(voices={}, load_voice=MagicMock(return_value=object()))
    load = MagicMock(return_value=model)
    pipeline_constructor = MagicMock(return_value=pipeline)
    tts = SimpleNamespace(load=load)
    monkeypatch.setitem(sys.modules, 'mlx_audio', SimpleNamespace(tts=tts))
    monkeypatch.setitem(sys.modules, 'mlx_audio.tts', tts)
    monkeypatch.setitem(sys.modules, 'mlx_audio.tts.models.kokoro', SimpleNamespace(KokoroPipeline=pipeline_constructor))
    paths = {'config.json': str(tmp_path / 'config.json'),
             'kokoro-v1_0.safetensors': str(tmp_path / 'weights'),
             'voices/af_heart.safetensors': str(tmp_path / 'voice.safetensors')}
    prepare = MagicMock(return_value=paths)
    monkeypatch.setattr(kokoro_mlx, 'prepare_model_files', prepare)
    backend = kokoro_mlx.KokoroMLXBackend()
    progress = []
    backend.model_progress_callback = lambda **event: progress.append(event)
    backend.initialize()
    load.assert_called_once_with(tmp_path, model_type='kokoro')
    pipeline_constructor.assert_called_once_with(lang_code='a', model=model, repo_id='prince-canuma/Kokoro-82M')
    assert 'af_heart' in pipeline.voices
    assert [event['status'] for event in progress] == ['loading', 'ready']


def test_pytorch_initialization_passes_local_model_files(tmp_path, monkeypatch):
    from backends import kokoro_pytorch

    model = MagicMock()
    model.to.return_value.eval.return_value = model
    pipeline = SimpleNamespace(voices={}, load_voice=MagicMock(return_value=object()))
    constructor = MagicMock(return_value=model)
    pipeline_constructor = MagicMock(return_value=pipeline)
    monkeypatch.setitem(sys.modules, 'kokoro', SimpleNamespace(KModel=constructor, KPipeline=pipeline_constructor))
    monkeypatch.setitem(sys.modules, 'torch', SimpleNamespace())
    paths = {'config.json': str(tmp_path / 'config.json'),
             'kokoro-v1_0.pth': str(tmp_path / 'weights.pth'),
             'voices/af_heart.pt': str(tmp_path / 'voice.pt')}
    monkeypatch.setattr(kokoro_pytorch, 'prepare_model_files', MagicMock(return_value=paths))
    backend = kokoro_pytorch.KokoroPyTorchBackend()
    backend.initialize(device='cpu')
    constructor.assert_called_once_with(config=paths['config.json'], model=paths['kokoro-v1_0.pth'])
    model.to.assert_called_once_with('cpu')
    pipeline_constructor.assert_called_once_with(lang_code='a', model=model)
    assert 'af_heart' in pipeline.voices
