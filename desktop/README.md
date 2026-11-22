# Audiobook Maker — native macOS app

A genuinely native macOS front-end for the Kokoro TTS backend, built on
[`vercel-labs/native`](https://github.com/vercel-labs/native) (Native SDK).
It reuses the repo's Python backend (`../app.py`) **unchanged**: the app
launches `app.py` through an argument-safe Python helper and parses its newline-delimited JSON event
stream, exactly like the Ink CLI in `../cli`.

- View: `src/app.native` (declarative markup) — a library window, not a wizard.
- Logic: `src/main.zig` — `Model` / `Msg` / `update`, the effects wiring, and
  the boot/spawn glue. Draws real pixels through Metal; ~4 MB binary, no WebView.

## Architecture

```
app.native (view)  ──►  Model/Msg/update (main.zig)  ──►  JSON request → Python launcher
      ▲                          │                                  │
      └── rebuild ◄── fold ◄── EffectLine / EffectExit ◄── app.py JSON events
```

Backend requests are written as JSON via the SDK file effects, then
`audiobook_backend/desktop_state.py run` prepares the section selection and
replaces itself with the backend. This avoids the SDK's 16-argument / 2 KiB
argv limits and preserves filenames and Unicode exactly. Boot checks still
use the quoted shell helper. User pause and skip actions signal the exact
attempt with SIGTERM and wait for its terminal event; per-attempt stop
markers cover cancellation before the backend has started.

Module map (Zig ports of the CLI's TypeScript utils):

| File | Ports from | Role |
|------|------------|------|
| `config.zig` | `types/profile.ts` + `tts-runner.ts` argv | `TtsConfig`, voices, argv builder |
| `events.zig` | `parseOutputLine` / `ProgressInfo` | JSON event → typed `Event` |
| `shell.zig`  | — | `/bin/sh -c` command assembly + quoting |
| `apple_host.zig` | `apple-host.ts` | Apple-Silicon detection |
| `main.zig` | `App.tsx` + `batch-planner/scheduler/preflight` | TEA model, effects, views |

## Download (for users)

Grab **AudiobookMaker.dmg** from the [Releases page](../../releases), open it, and
drag the app into Applications. Apple Silicon (M1 or newer) only.

It's an unsigned build, so on first launch macOS Gatekeeper will warn — **right-click
the app → Open** once (or run `xattr -dr com.apple.quarantine "/Applications/AudiobookMaker.app"`).
The first conversion downloads the ~330 MB Kokoro voice model; after that it works offline.

Nothing else to install — Python, the MLX voice runtime, and ffmpeg are all inside the app.

## Build the .app yourself

```sh
brew install espeak-ng          # relocated into the bundle by the packager
desktop/packaging/package.sh     # -> desktop/dist/AudiobookMaker.dmg (~350 MB)
```

`package.sh` builds the native binary, downloads a relocatable Python
(python-build-standalone), installs the MLX runtime (`packaging/requirements-mlx-app.txt`,
torch-free), bundles a static ffmpeg + a relocated espeak-ng, copies the Python
backend, ad-hoc signs, and produces the DMG. CI does the same on every `v*` tag
(`.github/workflows/release.yml`).

## Commands

```sh
native dev      # build + run with markup hot reload
native test     # native unit and lifecycle regression tests (argv, event parser, shell quoting, views, update)
native build    # ReleaseFast binary → zig-out/bin/
native check    # validate src/app.native + app.zon against the model contract
native package --target macos --signing identity --identity "Developer ID Application: …"
```

Run it against the repo so boot detection finds `app.py`:
`AUDIOBOOK_PROJECT_ROOT=/path/to/audiobook_maker ./zig-out/bin/desktop`
(or just launch from the repo root). The app's Setup screen tells you what to
install if the Python venv, Kokoro, or FFmpeg are missing (`../setup.sh`).

## What works

- A persistent library under `~/Library/Application Support/Audiobook Maker`,
  with atomic JSON saves, corrupt-state backups, per-book settings, and saved
  section selections. Set `AUDIOBOOK_STATE_DIR` for isolated testing.
- EPUB import with spine reading order, cover thumbnails, title/author edits,
  cover replacement, estimated listening time and temporary disk use, and an
  expandable list of included sections and text samples.
- Narrator picker, bounded speed controls, and a cached preview of up to 30
  seconds from the first included section; separate sample and audiobook
  playback with Stop controls.
- M4B with chapters and automatic progress saving by default. MP3 and advanced
  engine/quality controls remain available.
- Per-book output folder selection, remembered for new books. The initial
  destination is `~/Music/Audiobook Maker`. Existing files are kept by default;
  the library tracks the actual filename returned by the exporter.
- Primary **Create Audiobook** for the selected book, **Create All** for the
  batch, and explicit **Apply Settings to Unstarted Books**. Running jobs use
  immutable request snapshots.
- **Pause and Save** (or **Stop Queue** if progress saving was disabled),
  **Skip Current**, **Cancel Preview**, and **Retry This Book**. Pausing never
  starts the next book. Relaunch restores the library and inspects checkpoints;
  it does not automatically restart conversion.
- Model preparation/loading phases and real download byte counts when the
  model host supplies a total, plus actionable per-book errors.
- Missing-source relinking, native completion notification, and Reveal in Finder.
- Stable book IDs and unique attempt keys; obsolete process events cannot
  mutate a different book after a list change or retry.

## Verification and limits

`native test` covers configuration, event parsing, shell quoting, rendering,
per-book isolation, immutable running settings, pause acknowledgement, stale
attempt events, restored jobs/IDs, and selected-book request snapshots. Python
unit tests cover atomic library writes, corrupt-state recovery, launcher
argument fidelity, and the stop-before-launch race.

The library currently holds up to 24 books and reports the limit explicitly.
Up to 96 sections can be reviewed individually. Larger books show a warning
and use the backend's default reading selection. The disk/time numbers are
rough estimates, not guaranteed requirements or measured completion times.
Playback is basic Play/Stop using macOS audio support, without seeking or a
waveform. Ordinary EPUB imports use the native picker or path entry; drag and
drop is not implemented.

Signing/notarization still requires a Developer ID account. The package remains
ad-hoc signed unless release credentials are configured. The packaged app is
MLX-only; it does not offer the development CLI's PyTorch CPU recovery ladder.
Model-host networking errors are shown with retry guidance; preparation retries
reuse files already cached by the model host.
