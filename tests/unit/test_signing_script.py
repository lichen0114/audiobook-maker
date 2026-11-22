"""Exercise the release script with fake signing/notary tools only."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


pytestmark = pytest.mark.unit
SCRIPT = Path(__file__).resolve().parents[2] / "desktop/packaging/sign-and-notarize.sh"


@pytest.fixture
def signing_environment(tmp_path):
    tools = tmp_path / "tools"
    tools.mkdir()
    log = tmp_path / "calls.jsonl"
    executable = f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['SIGNING_TEST_LOG'], 'a') as stream:
    stream.write(json.dumps([tool, args]) + '\\n')
if tool == 'uname':
    print('Darwin')
elif tool == 'file':
    name = pathlib.Path(args[-1]).name
    print('Mach-O 64-bit executable arm64' if name.startswith('python') or name == 'ffmpeg'
          else 'Mach-O 64-bit dynamically linked shared library arm64' if name.endswith('.dylib')
          else 'ASCII text')
elif tool == 'xcrun':
    if args[0] == '--find':
        print('/fake/' + args[1])
    elif args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'status': os.environ.get('SIGNING_TEST_STATUS', 'Accepted'), 'id': 'test-submission'}))
elif tool == 'plutil':
    print(json.loads(pathlib.Path(args[-1]).read_text())[args[1]])
'''
    for name in ["uname", "file", "xcrun", "codesign", "ditto", "plutil"]:
        command = tools / name
        command.write_text(executable)
        command.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
               SIGNING_IDENTITY="Developer ID Application: Test (TEST)",
               NOTARY_PROFILE="test-profile", SIGNING_TEST_LOG=str(log))
    return env, log


def run_script(target, env):
    return subprocess.run(["bash", str(SCRIPT), str(target)], env=env,
                          text=True, capture_output=True, timeout=20)


def calls(log):
    return [json.loads(line) for line in log.read_text().splitlines()]


def test_app_signs_nested_code_before_envelope_and_staples_only_after_acceptance(tmp_path, signing_environment):
    env, log = signing_environment
    app = tmp_path / "App With Spaces.app"
    python = app / "Contents/Resources/python/bin/python3.12"
    python.parent.mkdir(parents=True)
    python.write_text("fake interpreter")
    library = app / "Contents/Resources/libvoice.dylib"
    library.write_text("fake library")
    result = run_script(app, env)
    assert result.returncode == 0, result.stderr
    recorded = calls(log)
    signatures = [args for tool, args in recorded if tool == "codesign" and "--sign" in args]
    assert signatures[-1][-1] == str(app)
    assert {args[-1] for args in signatures[:-1]} == {str(python), str(library)}
    assert all("--timestamp" in args and "runtime" in args for args in signatures)
    assert "--entitlements" in next(args for args in signatures if args[-1] == str(python))
    submit = next(i for i, (tool, args) in enumerate(recorded) if tool == "xcrun" and args[:2] == ["notarytool", "submit"])
    staple = next(i for i, (tool, args) in enumerate(recorded) if tool == "xcrun" and args[:2] == ["stapler", "staple"])
    assert submit < staple


def test_rejected_notarization_does_not_staple_or_claim_success(tmp_path, signing_environment):
    env, log = signing_environment
    env["SIGNING_TEST_STATUS"] = "Invalid"
    dmg = tmp_path / "App.dmg"
    dmg.write_bytes(b"fake image")
    result = run_script(dmg, env)
    assert result.returncode != 0
    assert "Notarization status: Invalid" in result.stderr
    assert "Signed, notarized, and stapled" not in result.stdout
    assert not any(tool == "xcrun" and args[0] == "stapler" for tool, args in calls(log))


def test_dmg_mode_only_signs_the_existing_container(tmp_path, signing_environment):
    env, log = signing_environment
    dmg = tmp_path / "App.dmg"
    dmg.write_bytes(b"fake image")
    result = run_script(dmg, env)
    assert result.returncode == 0, result.stderr
    signatures = [args for tool, args in calls(log) if tool == "codesign" and "--sign" in args]
    assert len(signatures) == 1
    assert signatures[0][-1] == str(dmg)


def test_missing_credentials_fail_before_signing(tmp_path, signing_environment):
    env, log = signing_environment
    env.pop("NOTARY_PROFILE")
    result = run_script(tmp_path / "App.dmg", env)
    assert result.returncode != 0
    assert "NOTARY_PROFILE is required" in result.stderr
    assert not any(tool == "codesign" for tool, _args in calls(log))
