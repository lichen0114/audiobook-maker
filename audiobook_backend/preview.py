"""Short, configuration-keyed book samples through the production synthesis path."""
import hashlib
import json
import os
import tempfile
from pathlib import Path

from .export import audio_to_int16
from .job import build_checkpoint_config


def create_preview(args, deps, events):
    prepared = deps.prepare_job(args, inspect_checkpoint_state=False, deps=deps.preparation_deps)
    # Bound input as well as output so preview cannot synthesize an entire book.
    excerpt = " ".join(prepared.chapters[0].text.split()[:100])
    seconds = min(float(getattr(args, "preview_seconds", 30)), 30)
    identity = build_checkpoint_config(args, prepared.resolved_backend, prepared.chunk_chars,
                                       prepared.resolved_device,
                                       selected_section_ids=[s.section_id for s in prepared.chapters])
    key = hashlib.sha256(json.dumps({"excerpt": excerpt, "config": identity, "seconds": seconds},
                                   sort_keys=True).encode()).hexdigest()
    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    output = output.with_name(f"{output.stem}-preview-{key[:16]}.mp3")
    cache = Path(str(output) + ".preview.json")
    try:
        cached = json.loads(cache.read_text())
        if isinstance(cached, dict) and cached.get("key") == key and isinstance(cached.get("output"), str) and Path(cached["output"]).is_file() and Path(cached["output"]).stat().st_size > 0:
            events.emit("done", output=cached.get("output", str(output)), preview=True, cached=True)
            return
    except (OSError, ValueError):
        pass

    backend = None
    pcm_path = None
    stop, thread = deps.start_heartbeat_emitter(events, thread_name="preview-heartbeat")
    try:
        events.emit("phase", phase="PREPARING_MODEL")
        backend = deps.create_backend(prepared.resolved_backend)
        backend.model_progress_callback = lambda **payload: events.emit("model_progress", **payload)
        backend.requested_voice = args.voice
        events.emit("phase", phase="LOADING_MODEL")
        backend.initialize(lang_code=args.lang_code, device=prepared.resolved_device)
        events.emit("phase", phase="INFERENCE")
        remaining = int(backend.sample_rate * seconds)
        with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as pcm:
            pcm_path = pcm.name
            for audio in backend.generate(text=excerpt, voice=args.voice, speed=args.speed,
                                          split_pattern=args.split_pattern):
                samples = audio_to_int16(audio)[:remaining]
                pcm.write(samples.tobytes())
                remaining -= len(samples)
                if remaining <= 0:
                    break
        events.emit("phase", phase="EXPORTING")
        actual = deps.export_pcm_file_to_mp3(pcm_path, str(output), sample_rate=backend.sample_rate,
                                            bitrate=args.bitrate, normalize=args.normalize)
        actual = actual if isinstance(actual, str) else str(output)
        with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, delete=False) as manifest:
            json.dump({"key": key, "output": actual}, manifest)
            manifest.flush()
            os.fsync(manifest.fileno())
            manifest_path = manifest.name
        os.replace(manifest_path, cache)
        events.emit("done", output=actual, preview=True, cached=False)
    finally:
        stop.set()
        thread.join(timeout=1)
        deps.cleanup_backend(backend)
        deps.cleanup_spool_path(pcm_path)
