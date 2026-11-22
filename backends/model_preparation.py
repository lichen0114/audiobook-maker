"""Prepare Kokoro files through public Hugging Face APIs with honest progress."""

import inspect
import os
import time
from typing import Callable, Optional


ProgressCallback = Optional[Callable[..., None]]


def emit_model_progress(callback: ProgressCallback, status: str, *, downloaded_bytes: int = 0,
                        total_bytes: int = 0, message: str = '') -> None:
    if callback is not None:
        callback(status=status, downloaded_bytes=downloaded_bytes,
                 total_bytes=total_bytes, message=message)


def prepare_model_files(repo_id: str, filenames: list[str],
                        callback: ProgressCallback = None) -> dict[str, str]:
    """Reuse local model files without a network request, downloading only misses.

    A zero total means the installed Hub SDK cannot supply a complete byte
    estimate. Counts come from its actual download progress, never a timer.
    """
    from huggingface_hub import hf_hub_download, try_to_load_from_cache
    from tqdm.auto import tqdm

    paths: dict[str, str] = {}
    missing = []
    for filename in dict.fromkeys(filenames):
        cached = try_to_load_from_cache(repo_id, filename)
        if isinstance(cached, str) and os.path.isfile(cached):
            paths[filename] = cached
        else:
            missing.append(filename)
    if not missing:
        size = sum(os.path.getsize(path) for path in paths.values())
        emit_model_progress(callback, 'cached', downloaded_bytes=size, total_bytes=size,
                            message='Model and selected voice are cached; no model download needed.')
        return paths

    emit_model_progress(callback, 'downloading', message='Checking files for the voice model download…')
    completed_bytes = 0
    total_bytes = 0
    last_report = 0.0

    class DownloadProgress(tqdm):
        def __init__(self, *args, **kwargs):
            # Keep tqdm's counters, suppress terminal rendering. Disabling tqdm
            # would disable its counters too.
            kwargs['disable'] = False
            super().__init__(*args, **kwargs)

        def display(self, *args, **kwargs):
            return None

        def update(self, n=1):
            result = super().update(n)
            self.report()
            return result

        def report(self, force=False):
            nonlocal last_report
            if getattr(self, 'unit', None) != 'B':
                return
            now = time.monotonic()
            if force or now - last_report >= 0.25:
                last_report = now
                emit_model_progress(callback, 'downloading',
                                    downloaded_bytes=completed_bytes + int(self.n),
                                    total_bytes=total_bytes,
                                    message='Downloading voice model files…')

        def close(self):
            if hasattr(self, 'n') and not getattr(self, '_model_progress_closed', False):
                self.report(force=True)
                self._model_progress_closed = True
            return super().close()

    try:
        # New Hub versions expose a read-only metadata pass, providing an exact
        # total for missing files. Older SDKs use an indeterminate byte count.
        if 'dry_run' in inspect.signature(hf_hub_download).parameters:
            sizes = [hf_hub_download(repo_id, filename, dry_run=True).file_size
                     for filename in missing]
            total_bytes = sum(sizes)
            emit_model_progress(callback, 'downloading', total_bytes=total_bytes,
                                message='Downloading voice model files…')
        for filename in missing:
            path = hf_hub_download(repo_id, filename, tqdm_class=DownloadProgress)
            paths[filename] = path
            completed_bytes += os.path.getsize(path)
            emit_model_progress(callback, 'downloading', downloaded_bytes=completed_bytes,
                                total_bytes=total_bytes, message='Downloading voice model files…')
    except Exception as exc:
        message = ('The voice model is not fully downloaded. Check your connection and available '
                   'disk space, then retry; completed downloads are kept. ' + str(exc))
        emit_model_progress(callback, 'error', downloaded_bytes=completed_bytes,
                            total_bytes=total_bytes, message=message)
        raise RuntimeError(message) from exc
    return paths


def voice_filenames(voice: str, suffix: str) -> list[str]:
    """Local voice files already bypass the Hub in both supported pipelines."""
    return [f'voices/{name.strip()}{suffix}' for name in voice.split(',')
            if name.strip() and not name.strip().endswith(suffix)]


def preload_local_voices(pipeline, voice: str, paths: dict[str, str], suffix: str) -> None:
    # Loading by local filename prevents the SDK from performing an unnecessary
    # metadata request for an already cached voice.
    for name in voice.split(','):
        name = name.strip()
        filename = f'voices/{name}{suffix}'
        if filename in paths:
            pipeline.voices[name] = pipeline.load_voice(paths[filename])
