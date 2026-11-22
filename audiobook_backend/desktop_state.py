"""Small filesystem boundary for the native desktop library (no TTS imports)."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import shutil
import signal


def state_dir():
    return Path(os.environ.get("AUDIOBOOK_STATE_DIR", str(Path.home() / "Library/Application Support/Audiobook Maker")))


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    root = state_dir()
    command = sys.argv[1]
    if command == "load":
        root.mkdir(parents=True, exist_ok=True)
        warning = ""
        save_allowed = True
        try:
            value = json.loads((root / "library.json").read_text(encoding="utf-8"))
            if not isinstance(value, dict) or value.get("version") != 1:
                raise ValueError("unsupported library version")
            if not isinstance(value.get("books"), list):
                raise ValueError("library books must be a list")
            for entry in value["books"]:
                if not isinstance(entry, dict) or not all(isinstance(entry.get(key, ""), str) for key in ("input", "output")):
                    raise ValueError("invalid saved book paths")
            if not isinstance(value.get("output_directory", ""), str):
                raise ValueError("invalid saved output directory")
        except FileNotFoundError:
            value = {"version": 1, "books": []}
        except (ValueError, OSError) as exc:
            value = {"version": 1, "books": []}
            backup = root / f"library.corrupt-{time.time_ns()}.json"
            try:
                shutil.copyfile(root / "library.json", backup)
                warning = f"Could not restore library: {exc}. Original saved as {backup.name}."
            except OSError:
                save_allowed = False
                warning = f"Could not restore library: {exc}. Saved data was kept; saving is disabled."
        for entry in value.get("books", []):
            if isinstance(entry, dict):
                entry["output_exists"] = Path(entry.get("output", "")).is_file()
        value.setdefault("output_directory", str(Path.home() / "Music/Audiobook Maker"))
        value["state_dir"] = str(root)
        value["warning"] = warning
        value["save_allowed"] = save_allowed
        print(json.dumps(value, ensure_ascii=False))
    elif command in ("save", "save_file"):
        value = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")) if command == "save_file" else json.loads(sys.argv[2])
        if value.get("version") != 1 or not isinstance(value.get("books"), list):
            raise ValueError("invalid desktop library")
        atomic_json(root / "library.json", value)
    elif command == "run":
        request = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
        directory = Path(request["directory"])
        directory.mkdir(parents=True, exist_ok=True)
        if request["selection"] is not None:
            atomic_json(directory / "sections.json", request["selection"])
        if request.get("pid_file"):
            pid_file = Path(request["pid_file"])
            atomic_json(pid_file, {"pid": os.getpid()})
            if Path(str(pid_file) + ".stop").exists():
                return
        os.chdir(request["root"])
        os.environ.update(request.get("env", {}))
        # Replace the launcher, so cancellation reaches Python's cleanup handler.
        os.execv(sys.executable, [sys.executable, request["script"], *request["args"]])
    elif command == "stop":
        pid_file = Path(sys.argv[2])
        atomic_json(Path(str(pid_file) + ".stop"), {"stop": True})
        for _ in range(20):
            try:
                pid = int(json.loads(pid_file.read_text(encoding="utf-8"))["pid"])
                if pid > 1:
                    os.kill(pid, signal.SIGTERM)
                break
            except FileNotFoundError:
                time.sleep(0.05)
            except ProcessLookupError:
                break
    elif command == "prepare":
        book_id = str(int(sys.argv[2]))
        selection = json.loads(sys.stdin.read()) if sys.argv[3] == "-" else json.loads(sys.argv[3])
        if selection is not None and (not isinstance(selection, list) or not all(isinstance(v, str) for v in selection)):
            raise ValueError("section selection must be a list of IDs")
        directory = root / "books" / book_id
        directory.mkdir(parents=True, exist_ok=True)
        if selection is not None:
            atomic_json(directory / "sections.json", selection)
    else:
        raise ValueError("unknown desktop state operation")


if __name__ == "__main__":
    main()
