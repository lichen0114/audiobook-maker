#!/usr/bin/env bash
#
# Build a self-contained AudiobookMaker.app (Apple Silicon) that bundles:
#   - the Native SDK binary
#   - a relocatable Python (python-build-standalone)
#   - the MLX voice runtime + all deps (no torch)
#   - a static ffmpeg
#   - the Python backend source (app.py, audiobook_backend/, backends/)
#
# The Kokoro voice model (~330 MB) is NOT bundled; mlx-audio downloads it into
# ~/Library/Caches on the first conversion. Output: dist/AudiobookMaker.app and
# dist/AudiobookMaker.dmg. Ad-hoc signed (no Apple Developer ID required).
#
# Usage:  desktop/packaging/package.sh
# Env:    PY_URL / FFMPEG_SRC to override auto-detection.
set -euo pipefail

APP_DISPLAY="Audiobook Maker"
BIN_NAME="audiobook-maker"
BUNDLE_ID="dev.native_sdk.audiobook_maker"
VERSION="${VERSION:-0.1.0}"
PY_SERIES="3.12"

DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DESKTOP/.." && pwd)"
DIST="$DESKTOP/dist"
WORK="$DIST/work"
APP="$DIST/AudiobookMaker.app"
RES="$APP/Contents/Resources"
REQ="$DESKTOP/packaging/requirements-mlx-app.txt"

echo "==> [1/8] building the native binary"
( cd "$DESKTOP" && native build --yes )
BIN="$DESKTOP/zig-out/bin/$BIN_NAME"
[ -x "$BIN" ] || { echo "native binary not found at $BIN"; exit 1; }

echo "==> [2/8] assembling the .app skeleton"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon (best-effort png -> icns)
if command -v sips >/dev/null && [ -f "$DESKTOP/assets/icon.png" ]; then
  sips -s format icns "$DESKTOP/assets/icon.png" --out "$RES/AppIcon.icns" >/dev/null 2>&1 || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key><string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.5</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST

echo "==> [3/8] fetching a relocatable Python ($PY_SERIES)"
mkdir -p "$WORK"
if [ -z "${PY_URL:-}" ]; then
  # browser_download_url percent-encodes the '+', so match loosely.
  PY_URL=$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
    | grep -oE "https://[^\"]*cpython-${PY_SERIES}\.[0-9][^\"]*aarch64-apple-darwin-install_only\.tar\.gz" \
    | head -1)
fi
[ -n "$PY_URL" ] || { echo "could not resolve python-build-standalone URL; set PY_URL"; exit 1; }
echo "    $PY_URL"
curl -fsSL "$PY_URL" -o "$WORK/python.tar.gz"
tar -xzf "$WORK/python.tar.gz" -C "$RES"    # -> $RES/python/
PYBIN="$RES/python/bin/python3"
[ -x "$PYBIN" ] || { echo "bundled python missing at $PYBIN"; exit 1; }

echo "==> [4/8] installing the MLX runtime into the bundle (no torch)"
"$PYBIN" -m pip install --upgrade pip >/dev/null
"$PYBIN" -m pip install -r "$REQ" imageio-ffmpeg
# Belt-and-suspenders: the phonemizer's transformer path is optional; drop torch.
"$PYBIN" -m pip uninstall -y torch curated-transformers spacy-curated-transformers curated-tokenizers >/dev/null 2>&1 || true
# Patch the Kokoro istftnet length-drift crash (broadcast_shapes on certain chunks).
"$PYBIN" "$DESKTOP/packaging/patch_mlx.py" "$RES/python/lib/python${PY_SERIES}/site-packages"

echo "==> [5/8] bundling ffmpeg"
if [ -n "${FFMPEG_SRC:-}" ]; then
  cp "$FFMPEG_SRC" "$RES/ffmpeg"
else
  FF=$("$PYBIN" -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())")
  cp "$FF" "$RES/ffmpeg"
fi
chmod +x "$RES/ffmpeg"

echo "==> [5b/8] fixing espeak-ng (the pip dylib has a broken build-time data path)"
# misaki's G2P loads espeakng_loader's libespeak-ng.dylib, whose compiled-in
# data path points at the wheel's CI build dir (nonexistent at runtime) and
# ignores overrides. Swap in Homebrew's working library, relocated so it's
# self-contained. Requires: brew install espeak-ng  (pulls pcaudiolib).
BREW_ESPEAK="$(brew --prefix espeak-ng 2>/dev/null)/lib/libespeak-ng.1.dylib"
BREW_PCAUDIO="$(brew --prefix pcaudiolib 2>/dev/null)/lib/libpcaudio.0.dylib"
LOADER="$RES/python/lib/python${PY_SERIES}/site-packages/espeakng_loader"
if [ -f "$BREW_ESPEAK" ] && [ -f "$BREW_PCAUDIO" ] && [ -d "$LOADER" ]; then
  cp "$BREW_ESPEAK" "$LOADER/libespeak-ng.dylib"
  cp "$BREW_PCAUDIO" "$RES/libpcaudio.0.dylib"
  chmod u+w "$LOADER/libespeak-ng.dylib" "$RES/libpcaudio.0.dylib"
  LIB="$LOADER/libespeak-ng.dylib"
  install_name_tool -id @loader_path/libespeak-ng.dylib "$LIB"
  # Rewrite the self-ref and the libpcaudio ref (the latter to a bare name so
  # DYLD_LIBRARY_PATH=Resources resolves it even from phonemizer's temp copy).
  otool -L "$LIB" | awk 'NR>1{print $1}' | while read -r dep; do
    case "$dep" in
      *libespeak-ng*) install_name_tool -change "$dep" @loader_path/libespeak-ng.dylib "$LIB" 2>/dev/null || true ;;
      *libpcaudio*)   install_name_tool -change "$dep" libpcaudio.0.dylib "$LIB" 2>/dev/null || true ;;
    esac
  done
  install_name_tool -id libpcaudio.0.dylib "$RES/libpcaudio.0.dylib"
  codesign --force --sign - "$RES/libpcaudio.0.dylib" "$LIB" 2>/dev/null || true
else
  echo "    WARNING: Homebrew espeak-ng/pcaudiolib not found — run 'brew install espeak-ng'."
  echo "             Without it, the phonemizer will fail at runtime."
fi

echo "==> [6/8] copying the Python backend source"
mkdir -p "$RES/backend"
cp "$REPO/app.py" "$REPO/checkpoint.py" "$RES/backend/"
cp -R "$REPO/audiobook_backend" "$REPO/backends" "$RES/backend/"
# Trim caches to shrink the bundle.
find "$RES" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RES/python" -type d -name "test" -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> [7/8] ad-hoc code-signing"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    (codesign warning ignored; ad-hoc signature applied where possible)"

echo "==> [8/8] building the DMG"
DMG="$DIST/AudiobookMaker.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_DISPLAY" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

APP_SIZE=$(du -sh "$APP" | awk '{print $1}')
DMG_SIZE=$(du -sh "$DMG" | awk '{print $1}')
echo ""
echo "Built: $APP ($APP_SIZE)"
echo "       $DMG ($DMG_SIZE)"
echo "Distribute the .dmg. First launch downloads the ~330 MB voice model."
