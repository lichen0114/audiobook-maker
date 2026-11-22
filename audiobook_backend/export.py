import os
import errno
import logging
import shutil
import subprocess
import tempfile
import threading
import sys
from typing import List, Optional

import numpy as np
from pydub import AudioSegment

from .metadata import _infer_cover_mime_type_from_path
from .models import BookMetadata, ChapterInfo

try:
    import torch
except ImportError:
    torch = None


DEFAULT_SAMPLE_RATE = 24000
_STDERR_LIMIT = 64 * 1024


def _rename_exclusive_macos(source: str, destination: str) -> None:
    """Use Darwin's atomic no-clobber rename on volumes without hard links."""
    import ctypes

    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # Defined by the macOS SDK's sys/stdio.h; available since macOS 10.12.
    rename_excl = 0x00000004
    if rename(os.fsencode(source), os.fsencode(destination), rename_excl) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def _publish_no_clobber(source: str, destination: str) -> None:
    try:
        os.link(source, destination)
    except OSError as exc:
        if sys.platform != 'darwin' or exc.errno not in {
            errno.EOPNOTSUPP, errno.ENOTSUP, errno.EPERM,
        }:
            raise
        _rename_exclusive_macos(source, destination)


class _OutputPublication:
    """Keep incomplete audio hidden and publish without clobbering another file."""

    def __init__(self, output_path: str, overwrite: bool = False):
        self.output_path = os.fspath(output_path)
        self.overwrite = overwrite
        self.published_path: Optional[str] = None
        self._cleanup_warned = False
        directory = os.path.dirname(os.path.abspath(self.output_path))
        stem, suffix = os.path.splitext(os.path.basename(self.output_path))
        fd, self.temp_path = tempfile.mkstemp(
            prefix=f'.{stem}-', suffix=f'.partial{suffix}', dir=directory,
        )
        os.close(fd)

    def publish(self) -> str:
        if os.path.getsize(self.temp_path) == 0:
            raise RuntimeError('ffmpeg produced no audio output')
        with open(self.temp_path, 'rb') as audio:
            os.fsync(audio.fileno())
        if self.overwrite:
            os.replace(self.temp_path, self.output_path)
            self.published_path = self.output_path
            self._sync_parent()
            return self.output_path

        stem, suffix = os.path.splitext(self.output_path)
        candidate = self.output_path
        number = 2
        while True:
            try:
                # Unlike rename, link fails atomically if the destination was
                # claimed between planning and publication. Both paths are on
                # the same filesystem because the temporary file is a sibling.
                _publish_no_clobber(self.temp_path, candidate)
                self.published_path = candidate
                self.discard()
                self._sync_parent()
                return candidate
            except FileExistsError:
                candidate = f'{stem} ({number}){suffix}'
                number += 1

    def _sync_parent(self) -> None:
        try:
            fd = os.open(os.path.dirname(os.path.abspath(self.output_path)), os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        except OSError:
            pass

    def discard(self) -> None:
        try:
            os.unlink(self.temp_path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            if self.published_path is None:
                raise
            if not self._cleanup_warned:
                logging.getLogger(__name__).warning(
                    'Audiobook saved to %s, but its temporary file could not be removed: %s',
                    self.published_path, exc,
                )
                self._cleanup_warned = True


def _quiet_command(cmd: List[str], temp_path: str) -> List[str]:
    return [cmd[0], '-hide_banner', '-nostats', '-loglevel', 'error', *cmd[1:-1], temp_path]


def _run_atomic_export(
    cmd: List[str], output_path: str, *, input_data: Optional[bytes] = None,
    overwrite: bool = False,
) -> str:
    publication = _OutputPublication(output_path, overwrite)
    try:
        kwargs = {'capture_output': True}
        if input_data is not None:
            kwargs['input'] = input_data
        proc = subprocess.run(_quiet_command(cmd, publication.temp_path), **kwargs)
        if proc.returncode != 0:
            err = proc.stderr.decode('utf-8', errors='replace')
            raise RuntimeError(f'ffmpeg failed: {err}')
        return publication.publish()
    finally:
        publication.discard()


class _StderrCapture:
    """Drain the child continuously, retaining only a bounded diagnostic tail."""

    def __init__(self, stream):
        self.stream = stream
        self.tail = bytearray()
        self.thread = threading.Thread(target=self._drain, name='ffmpeg-stderr', daemon=True)
        self.thread.start()

    def _drain(self) -> None:
        try:
            while data := self.stream.read(8192):
                self.tail.extend(data)
                if len(self.tail) > _STDERR_LIMIT:
                    del self.tail[:-_STDERR_LIMIT]
        except (OSError, ValueError):
            pass
        finally:
            self.stream.close()

    def finish(self, timeout: Optional[float] = None) -> bytes:
        self.thread.join(timeout=timeout)
        return bytes(self.tail)


class _StreamExportState:
    def __init__(self, publication: _OutputPublication, stderr):
        self.publication = publication
        self.capture = _StderrCapture(stderr) if stderr is not None else None


def discard_mp3_export_stream(proc: subprocess.Popen) -> None:
    """Clean staging audio after the process has exited or been terminated."""
    state = getattr(proc, '_audiobook_export', None)
    if isinstance(state, _StreamExportState):
        if state.capture is not None:
            state.capture.finish(timeout=1)
        state.publication.discard()


def audio_to_int16(audio) -> np.ndarray:
    """Convert audio tensor/array to int16 numpy array."""
    if torch is not None and isinstance(audio, torch.Tensor):
        if audio.device.type != "cpu":
            audio = audio.detach().cpu()
        else:
            audio = audio.detach()
        audio = audio.numpy()
    elif not isinstance(audio, np.ndarray):
        audio = np.asarray(audio)

    if audio.dtype != np.int16:
        audio = np.clip(audio, -1.0, 1.0)
        audio = (audio * 32767.0).astype(np.int16)
    return audio


def audio_to_segment(audio: np.ndarray, rate: int = DEFAULT_SAMPLE_RATE) -> AudioSegment:
    if audio.dtype != np.int16:
        audio = audio_to_int16(audio)
    return AudioSegment(
        audio.tobytes(),
        frame_rate=rate,
        sample_width=2,
        channels=1,
    )


def _escape_ffmetadata(text: str) -> str:
    text = text.replace("\\", "\\\\")
    text = text.replace("=", "\\=")
    text = text.replace(";", "\\;")
    text = text.replace("#", "\\#")
    text = text.replace("\n", "\\\n")
    return text


def generate_ffmetadata(
    metadata: BookMetadata,
    chapters: List[ChapterInfo],
    sample_rate: int = DEFAULT_SAMPLE_RATE,
) -> str:
    lines = [";FFMETADATA1"]

    lines.append(f"title={_escape_ffmetadata(metadata.title)}")
    lines.append(f"artist={_escape_ffmetadata(metadata.author)}")
    lines.append(f"album={_escape_ffmetadata(metadata.title)}")

    timebase = f"1/{sample_rate}"

    for chapter in chapters:
        lines.append("")
        lines.append("[CHAPTER]")
        lines.append(f"TIMEBASE={timebase}")
        lines.append(f"START={chapter.start_sample}")
        lines.append(f"END={chapter.end_sample}")
        lines.append(f"title={_escape_ffmetadata(chapter.title)}")

    return "\n".join(lines)


def _cover_tempfile_suffix(metadata: BookMetadata) -> str:
    if metadata.cover_mime_type:
        if "png" in metadata.cover_mime_type:
            return ".png"
        if "gif" in metadata.cover_mime_type:
            return ".gif"
    return ".jpg"


def _write_ffmetadata_tempfile(
    metadata: BookMetadata,
    chapters: List[ChapterInfo],
    sample_rate: int,
) -> str:
    metadata_content = generate_ffmetadata(metadata, chapters, sample_rate)
    metadata_file = tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".txt",
        delete=False,
    )
    metadata_file.write(metadata_content)
    metadata_file.close()
    return metadata_file.name


def _write_cover_tempfile(metadata: BookMetadata) -> Optional[str]:
    if metadata.cover_image is None:
        return None

    cover_file = tempfile.NamedTemporaryFile(
        suffix=_cover_tempfile_suffix(metadata),
        delete=False,
    )
    cover_file.write(metadata.cover_image)
    cover_file.close()
    return cover_file.name


def _build_m4b_ffmpeg_command(
    ffmpeg_path: str,
    audio_input_args: List[str],
    metadata_file: str,
    cover_file: Optional[str],
    bitrate: str,
    normalize: bool,
    output_path: str,
) -> List[str]:
    cmd = [
        ffmpeg_path,
        *audio_input_args,
        "-i", metadata_file,
    ]

    if cover_file:
        cmd.extend(["-i", cover_file])

    cmd.extend([
        "-map", "0:a",
        "-map_metadata", "1",
    ])

    if cover_file:
        cmd.extend([
            "-map", "2:v",
            "-c:v", "copy",
            "-disposition:v:0", "attached_pic",
        ])

    if normalize:
        cmd.extend(["-af", "loudnorm=I=-14:TP=-1:LRA=11"])

    cmd.extend([
        "-c:a", "aac",
        "-b:a", bitrate,
        "-movflags", "+faststart",
        "-y", output_path,
    ])
    return cmd


def export_pcm_to_mp3(
    pcm_data: np.ndarray,
    output_path: str,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    bitrate: str = "192k",
    normalize: bool = False,
    *,
    overwrite: bool = False,
) -> str:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise FileNotFoundError(
            "ffmpeg not found. Install with: brew install ffmpeg"
        )

    if pcm_data.size == 0:
        cmd = [
            ffmpeg_path,
            "-f", "lavfi",
            "-i", "anullsrc=r=24000:cl=mono",
            "-t", "0.1",
            "-b:a", bitrate,
            "-y", output_path,
        ]
        return _run_atomic_export(cmd, output_path, overwrite=overwrite)

    if pcm_data.dtype != np.int16:
        pcm_data = audio_to_int16(pcm_data)

    cmd = [
        ffmpeg_path,
        "-f", "s16le",
        "-ar", str(sample_rate),
        "-ac", "1",
        "-i", "pipe:0",
    ]

    if normalize:
        cmd.extend(["-af", "loudnorm=I=-14:TP=-1:LRA=11"])

    cmd.extend([
        "-b:a", bitrate,
        "-y", output_path,
    ])

    return _run_atomic_export(cmd, output_path, input_data=pcm_data.tobytes(), overwrite=overwrite)


def export_pcm_to_m4b(
    pcm_data: np.ndarray,
    output_path: str,
    metadata: BookMetadata,
    chapters: List[ChapterInfo],
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    bitrate: str = "192k",
    normalize: bool = False,
    *,
    overwrite: bool = False,
) -> str:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise FileNotFoundError(
            "ffmpeg not found. Install with: brew install ffmpeg"
        )

    if pcm_data.dtype != np.int16:
        pcm_data = audio_to_int16(pcm_data)

    temp_files = []
    try:
        metadata_file = _write_ffmetadata_tempfile(metadata, chapters, sample_rate)
        temp_files.append(metadata_file)
        cover_file = _write_cover_tempfile(metadata)
        if cover_file:
            temp_files.append(cover_file)

        if pcm_data.size == 0:
            audio_input_args = [
                "-f", "lavfi",
                "-t", "0.1",
                "-i", f"anullsrc=r={sample_rate}:cl=mono",
            ]
        else:
            audio_input_args = [
                "-f", "s16le",
                "-ar", str(sample_rate),
                "-ac", "1",
                "-i", "pipe:0",
            ]

        cmd = _build_m4b_ffmpeg_command(
            ffmpeg_path,
            audio_input_args,
            metadata_file,
            cover_file,
            bitrate,
            normalize,
            output_path,
        )

        return _run_atomic_export(cmd, output_path, input_data=pcm_data.tobytes(), overwrite=overwrite)

    finally:
        for temp_file in temp_files:
            try:
                os.remove(temp_file)
            except OSError:
                pass


def export_pcm_file_to_mp3(
    pcm_path: str,
    output_path: str,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    bitrate: str = "192k",
    normalize: bool = False,
    *,
    overwrite: bool = False,
) -> str:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise FileNotFoundError(
            "ffmpeg not found. Install with: brew install ffmpeg"
        )

    if not os.path.exists(pcm_path) or os.path.getsize(pcm_path) == 0:
        cmd = [
            ffmpeg_path,
            "-f", "lavfi",
            "-i", f"anullsrc=r={sample_rate}:cl=mono",
            "-t", "0.1",
            "-b:a", bitrate,
            "-y", output_path,
        ]
        return _run_atomic_export(cmd, output_path, overwrite=overwrite)

    cmd = [
        ffmpeg_path,
        "-f", "s16le",
        "-ar", str(sample_rate),
        "-ac", "1",
        "-i", pcm_path,
    ]

    if normalize:
        cmd.extend(["-af", "loudnorm=I=-14:TP=-1:LRA=11"])

    cmd.extend([
        "-b:a", bitrate,
        "-y", output_path,
    ])

    return _run_atomic_export(cmd, output_path, overwrite=overwrite)


def open_mp3_export_stream(
    output_path: str,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    bitrate: str = "192k",
    normalize: bool = False,
    *,
    overwrite: bool = False,
) -> subprocess.Popen:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise FileNotFoundError(
            "ffmpeg not found. Install with: brew install ffmpeg"
        )

    cmd = [
        ffmpeg_path,
        "-f", "s16le",
        "-ar", str(sample_rate),
        "-ac", "1",
        "-i", "pipe:0",
    ]

    if normalize:
        cmd.extend(["-af", "loudnorm=I=-14:TP=-1:LRA=11"])

    cmd.extend([
        "-b:a", bitrate,
        "-y", output_path,
    ])

    publication = _OutputPublication(output_path, overwrite)
    try:
        proc = subprocess.Popen(
            _quiet_command(cmd, publication.temp_path),
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        proc._audiobook_export = _StreamExportState(publication, proc.stderr)
        return proc
    except BaseException:
        publication.discard()
        raise


def close_mp3_export_stream(proc: subprocess.Popen) -> Optional[str]:
    state = getattr(proc, '_audiobook_export', None)
    try:
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except (BrokenPipeError, OSError):
            # Collect ffmpeg's actual error below instead of a broken-pipe
            # symptom from its input stream.
            pass
        return_code = proc.wait()
        if isinstance(state, _StreamExportState):
            stderr = state.capture.finish() if state.capture is not None else b''
        else:
            stderr = proc.stderr.read() if proc.stderr is not None else b''
        if return_code != 0:
            err = stderr.decode('utf-8', errors='replace')
            raise RuntimeError(f'ffmpeg failed: {err}')
        if isinstance(state, _StreamExportState):
            proc.published_output = state.publication.publish()
            return proc.published_output
        return None
    finally:
        if isinstance(state, _StreamExportState):
            state.publication.discard()


def export_pcm_file_to_m4b(
    pcm_path: str,
    output_path: str,
    metadata: BookMetadata,
    chapters: List[ChapterInfo],
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    bitrate: str = "192k",
    normalize: bool = False,
    *,
    overwrite: bool = False,
) -> str:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise FileNotFoundError(
            "ffmpeg not found. Install with: brew install ffmpeg"
        )

    temp_files = []
    try:
        metadata_file = _write_ffmetadata_tempfile(metadata, chapters, sample_rate)
        temp_files.append(metadata_file)

        has_audio = os.path.exists(pcm_path) and os.path.getsize(pcm_path) > 0
        if has_audio:
            audio_input_args = [
                "-f", "s16le",
                "-ar", str(sample_rate),
                "-ac", "1",
                "-i", pcm_path,
            ]
        else:
            audio_input_args = [
                "-f", "lavfi",
                "-t", "0.1",
                "-i", f"anullsrc=r={sample_rate}:cl=mono",
            ]

        cover_file = _write_cover_tempfile(metadata)
        if cover_file:
            temp_files.append(cover_file)

        cmd = _build_m4b_ffmpeg_command(
            ffmpeg_path,
            audio_input_args,
            metadata_file,
            cover_file,
            bitrate,
            normalize,
            output_path,
        )

        return _run_atomic_export(cmd, output_path, overwrite=overwrite)
    finally:
        for temp_file in temp_files:
            try:
                os.remove(temp_file)
            except OSError:
                pass

