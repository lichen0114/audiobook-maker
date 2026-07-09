# Audiobook Maker — native macOS app

A genuinely native macOS front-end for the Kokoro TTS backend, built on
[`vercel-labs/native`](https://github.com/vercel-labs/native) (Native SDK).
It reuses the repo's Python backend (`../app.py`) **unchanged**: the app
spawns `app.py` with flags and parses its newline-delimited JSON event
stream, exactly like the Ink CLI in `../cli`.

- View: `src/app.native` (declarative markup) — a library window, not a wizard.
- Logic: `src/main.zig` — `Model` / `Msg` / `update`, the effects wiring, and
  the boot/spawn glue. Draws real pixels through Metal; ~4 MB binary, no WebView.

## Architecture

```
app.native (view)  ──►  Model/Msg/update (main.zig)  ──►  fx.spawn "/bin/sh -c …"
      ▲                          │                                  │
      └── rebuild ◄── fold ◄── EffectLine / EffectExit ◄── app.py JSON events
```

The effects channel caps argv at 16 entries and exposes no env/cwd knob, so
every backend call is routed through `/bin/sh -c "<command>"` (see `shell.zig`),
which also carries the `cd <root>`, the environment assignments, and POSIX
quoting. All filesystem work (root detection, `*.epub` listing, checkpoint
deletion) is done in that shell — Zig 0.16 puts `std.fs` behind `std.Io`, which
`update` never sees.

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
native test     # 15 unit tests (argv, event parser, shell quoting, views, update)
native build    # ReleaseFast binary → zig-out/bin/
native check    # validate src/app.native + app.zon against the model contract
native package --target macos --signing identity --identity "Developer ID Application: …"
```

Run it against the repo so boot detection finds `app.py`:
`AUDIOBOOK_PROJECT_ROOT=/path/to/audiobook_maker ./zig-out/bin/desktop`
(or just launch from the repo root). The app's Setup screen tells you what to
install if the Python venv, Kokoro, or FFmpeg are missing (`../setup.sh`).

## What works

- Boot detection (project root + interpreter + `hw.memsize` + preflight) in one spawn.
- Setup gate mirroring the CLI's `SetupRequired`, with per-check fix hints.
- Add books via the native file picker (`osascript choose file`) or a path field;
  directories are scanned with `ls`.
- Automatic per-book inspection (`--inspect_job`) → chapters / chars / chunks /
  resolved backend / checkpoint status.
- Batch config (voice, speed, format, bitrate, normalize, backend, GPU, checkpoint).
- Sequential conversion queue with live phase / % / per-file progress, streamed
  from the backend's JSON events; native completion notification + Reveal in Finder.
- Checkpoint **resume / start-fresh** choice; duplicate-output **blocking**.

Verified end-to-end: 16/16 Zig tests; the real backends drive a full conversion
(PyTorch and MLX, MP3 + M4B with chapters); the packaged `.app` runs completely
self-contained (its own Python + MLX + espeak + ffmpeg, no repo, no system deps)
and produces a valid MP3 when driven through its GUI via the automation harness.

## Deferred (documented, not yet built)

- **Apple-Silicon recovery ladder** — the CLI's retry-with-safer-profile on a
  recoverable native crash (`tts-runner.ts:runTTS`). The hook (per-book error
  state + `EffectExit.reason`) is in place; the retry loop is not wired yet.
- **Cover art thumbnails** — needs a small backend addition (`--dump_cover
  <path>` emitting `metadata:cover_path`); today the detail pane shows a glyph.
- **Inline M4B title/author overrides** — chapters + metadata already flow from
  the EPUB; editable override fields are not built (would add per-book
  `TextBuffer`s).
- **Notarization** — the DMG is ad-hoc signed (Gatekeeper right-click-Open on
  first launch). A Developer ID + `xcrun notarytool` step would make it open
  cleanly; wire it into `.github/workflows/release.yml` when an account exists.
- **First-run model download UX** — the first conversion silently downloads the
  ~330 MB voice model (appears to sit at "Generating speech"); a dedicated
  "Preparing…" state would be friendlier.
