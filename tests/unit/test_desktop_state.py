import json
from pathlib import Path

import pytest

from audiobook_backend import desktop_state as state


def invoke(monkeypatch, capsys, root, *args):
    monkeypatch.setenv("AUDIOBOOK_STATE_DIR", str(root))
    monkeypatch.setattr("sys.argv", ["desktop_state", *args])
    state.main()
    output = capsys.readouterr().out
    return json.loads(output) if output else None


def test_empty_library_has_private_paths(monkeypatch, capsys, tmp_path):
    root = tmp_path / "support"
    result = invoke(monkeypatch, capsys, root, "load")
    assert result["books"] == []
    assert result["state_dir"] == str(root)
    assert result["save_allowed"] is True
    assert root.is_dir()


def test_atomic_library_roundtrip_and_existing_outputs(monkeypatch, capsys, tmp_path):
    audio = tmp_path / "book.m4b"
    audio.write_bytes(b"audio")
    value = {"version": 1, "books": [{"id": 1, "output": str(audio)}]}
    invoke(monkeypatch, capsys, tmp_path, "save", json.dumps(value))
    loaded = invoke(monkeypatch, capsys, tmp_path, "load")
    assert loaded["books"][0]["output_exists"] is True
    audio.unlink()
    assert invoke(monkeypatch, capsys, tmp_path, "load")["books"][0]["output_exists"] is False
    assert not list(tmp_path.glob(".pending-*"))


def test_corrupt_library_is_preserved_before_future_save(monkeypatch, capsys, tmp_path):
    original = b"{incomplete"
    (tmp_path / "library.json").write_bytes(original)
    loaded = invoke(monkeypatch, capsys, tmp_path, "load")
    assert loaded["warning"]
    assert loaded["save_allowed"]
    backups = list(tmp_path.glob("library.corrupt-*.json"))
    assert len(backups) == 1 and backups[0].read_bytes() == original
    invoke(monkeypatch, capsys, tmp_path, "save", '{"version":1,"books":[]}')
    assert backups[0].read_bytes() == original


def test_failed_backup_disables_saving(monkeypatch, capsys, tmp_path):
    (tmp_path / "library.json").write_text("bad")
    monkeypatch.setattr(state.shutil, "copyfile", lambda *args: (_ for _ in ()).throw(OSError("denied")))
    loaded = invoke(monkeypatch, capsys, tmp_path, "load")
    assert not loaded["save_allowed"]
    assert (tmp_path / "library.json").read_text() == "bad"


def test_staged_save_and_section_validation(monkeypatch, capsys, tmp_path):
    staging = tmp_path / "pending-library.json"
    staging.write_text('{"version":1,"books":[]}')
    invoke(monkeypatch, capsys, tmp_path, "save_file", str(staging))
    assert json.loads((tmp_path / "library.json").read_text())["books"] == []
    invoke(monkeypatch, capsys, tmp_path, "prepare", "7", '["section-a"]')
    assert json.loads((tmp_path / "books/7/sections.json").read_text()) == ["section-a"]
    with pytest.raises(ValueError, match="section selection"):
        invoke(monkeypatch, capsys, tmp_path, "prepare", "7", '[2]')
    with pytest.raises(ValueError, match="invalid desktop"):
        invoke(monkeypatch, capsys, tmp_path, "save", '{"version":2,"books":[]}')


def test_run_replaces_launcher_and_keeps_exact_arguments(monkeypatch, capsys, tmp_path):
    request = tmp_path / "request.json"
    args = ["--input", "A Book's EPUB.epub", "--title", "中文"]
    directory = tmp_path / "books/3"
    request.write_text(json.dumps({"directory": str(directory), "root": str(tmp_path), "script": "app.py", "selection": ["section-a"], "args": args, "env": {"AUDIOBOOK_TEST_ENV": "yes"}}))
    calls = []
    monkeypatch.setattr(state.os, "execv", lambda *call: calls.append(call))
    monkeypatch.chdir(tmp_path)
    invoke(monkeypatch, capsys, tmp_path, "run", str(request))
    assert calls[0][1][1:] == ["app.py", *args]
    assert json.loads((directory / "sections.json").read_text()) == ["section-a"]
    assert state.os.environ["AUDIOBOOK_TEST_ENV"] == "yes"
    monkeypatch.delenv("AUDIOBOOK_TEST_ENV")


def test_stop_before_launcher_exec_prevents_the_job(monkeypatch, capsys, tmp_path):
    pid_file = tmp_path / "attempt-123.pid"
    monkeypatch.setattr(state.time, "sleep", lambda _: None)
    invoke(monkeypatch, capsys, tmp_path, "stop", str(pid_file))
    request = tmp_path / "request.json"
    request.write_text(json.dumps({"directory": str(tmp_path), "pid_file": str(pid_file), "root": str(tmp_path), "script": "app.py", "selection": None, "args": [], "env": {}}))
    calls = []
    monkeypatch.setattr(state.os, "execv", lambda *call: calls.append(call))
    invoke(monkeypatch, capsys, tmp_path, "run", str(request))
    assert not calls
    assert json.loads(pid_file.read_text())["pid"] > 1


def test_stop_signals_the_recorded_attempt(monkeypatch, capsys, tmp_path):
    pid_file = tmp_path / "attempt-456.pid"
    pid_file.write_text('{"pid":12345}')
    calls = []
    monkeypatch.setattr(state.os, "kill", lambda *call: calls.append(call))
    invoke(monkeypatch, capsys, tmp_path, "stop", str(pid_file))
    assert calls == [(12345, state.signal.SIGTERM)]
    assert Path(str(pid_file) + ".stop").exists()
