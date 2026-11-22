#!/usr/bin/env bash
# Optional Developer ID distribution step. This script never creates or changes
# signing identities, keychains, credentials, or notarization profiles.
# Sign/staple the .app BEFORE creating a DMG, then invoke again on that DMG.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sign-and-notarize.sh /absolute/path/AudiobookMaker.app
       sign-and-notarize.sh /absolute/path/AudiobookMaker.dmg

Required environment:
  SIGNING_IDENTITY  Existing Developer ID Application identity (with private key)
  NOTARY_PROFILE   Existing notarytool keychain-profile name

The .app mode signs nested code inside-out, notarizes a temporary ZIP, and
staples the accepted ticket to the app. Create your DMG from that stapled app.
The .dmg mode signs, notarizes, and staples an already assembled disk image.
It does not modify or re-sign the app inside that image.
USAGE
}

fail() { printf 'sign-and-notarize: %s\n' "$*" >&2; exit 1; }

if [[ $# == 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage
  exit 0
fi
[[ $# == 1 ]] || { usage >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
[[ -n "${SIGNING_IDENTITY:-}" ]] || fail 'SIGNING_IDENTITY is required.'
[[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || fail 'Use a Developer ID Application signing identity.'
[[ -n "${NOTARY_PROFILE:-}" ]] || fail 'NOTARY_PROFILE is required.'
[[ -e "$1" && ! -L "$1" ]] || fail 'Provide an existing app or disk image, not a symlink.'

directory="$(cd "$(dirname "$1")" && pwd -P)"
target="$directory/$(basename "$1")"
case "$target" in
  *.app) [[ -d "$target/Contents" ]] || fail 'App bundle has no Contents directory.'; mode=app ;;
  *.dmg) [[ -f "$target" ]] || fail 'Disk image must be a regular file.'; mode=dmg ;;
  *) fail 'Expected a .app bundle or .dmg file.' ;;
esac

for command in codesign ditto file plutil xcrun; do
  command -v "$command" >/dev/null || fail "Required command is missing: $command"
done
xcrun --find notarytool >/dev/null || fail 'Install Xcode with notarytool.'
xcrun --find stapler >/dev/null || fail 'Install Xcode with stapler.'

work="$(mktemp -d "${TMPDIR:-/tmp}/audiobook-notary.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

notarize() {
  local upload="$1"
  local result="$work/notary-result.json"
  if ! xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" \
       --wait --output-format json > "$result"; then
    cat "$result" >&2
    fail 'Notarization submission failed; the artifact has not been stapled.'
  fi
  local status
  status="$(plutil -extract status raw -o - "$result")" || fail 'Could not read notarization status.'
  if [[ "$status" != Accepted ]]; then
    cat "$result" >&2
    local submission
    submission="$(plutil -extract id raw -o - "$result")" || submission=""
    if [[ -n "$submission" ]]; then
      xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    fail "Notarization status: $status; the artifact has not been stapled."
  fi
}

if [[ "$mode" == app ]]; then
  # The relocated espeak dependency uses DYLD_LIBRARY_PATH. Scope this exception
  # to the bundled Python interpreter; every shipped dylib is signed below.
  # Do not disable library validation or allow unsigned executable memory.
  python_entitlements="$work/python-entitlements.plist"
  cat > "$python_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict></plist>
PLIST

  # Skip symlinks so aliases are covered by the signature on their actual file.
  while IFS= read -r -d '' binary; do
    description="$(file -b "$binary")"
    if [[ "$description" != *Mach-O* ]]; then continue; fi
    case "$description" in
      *executable*|*'shared library'*|*bundle*) ;;
      *) continue ;;
    esac
    case "$binary" in
      "$target"/Contents/Resources/python/bin/python*)
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
          --entitlements "$python_entitlements" "$binary" ;;
      *) codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$binary" ;;
    esac
  done < <(find "$target" -depth -type f -print0)

  while IFS= read -r -d '' bundle; do
    if [[ "$bundle" == "$target" ]]; then continue; fi
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$bundle"
  done < <(find "$target" -depth -type d \( -name '*.framework' -o -name '*.app' \
           -o -name '*.xpc' -o -name '*.bundle' \) -print0)

  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$target"
  codesign --verify --deep --strict --verbose=2 "$target"
  ditto -c -k --keepParent "$target" "$work/AudiobookMaker.zip"
  notarize "$work/AudiobookMaker.zip"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
else
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$target"
  codesign --verify --verbose=2 "$target"
  notarize "$target"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
fi

printf 'Signed, notarized, and stapled: %s\n' "$target"
