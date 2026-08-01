#!/usr/bin/env bash
#
# Build aiterm.app and wrap it in a .dmg and a .zip.
#
# # Why SwiftPM and not xcodebuild
#
# The app is a SwiftUI executable with one dependency. SwiftPM can build it; the
# only thing Xcode adds is the bundle layout, which is four directories and a
# plist. Assembling that here buys one build path instead of two: this script is
# what CI runs *and* what a contributor runs, so a packaging bug cannot hide on
# the side nobody exercises. It also means the repository does not need Xcode
# installed to produce a release — Command Line Tools are enough.
#
# `project.yml` still exists and still generates an Xcode project. That is for
# people who want to debug in the IDE, not for shipping.
#
# # Signing
#
# Signing is optional and detected, not configured. With a Developer ID in the
# keychain the bundle is signed with the hardened runtime and is ready to be
# notarized; without one it is ad-hoc signed, which is enough to *run* but not
# enough to survive Gatekeeper on a machine that did not build it. The script
# says which of the two happened rather than leaving it to be discovered later
# by a user seeing "app is damaged".
#
# Usage:
#   scripts/package.sh [--version X.Y.Z] [--output DIR] [--skip-dmg]
#
# Environment:
#   AITERM_SIGN_IDENTITY   Codesign identity. Empty or unset means ad-hoc.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="aiterm"
EXECUTABLE="AITerm"
BUNDLE_ID="digital.opengateway.aiterm"
VERSION=""
OUTPUT_DIR="dist"
BUILD_DMG=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-dmg) BUILD_DMG=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "package.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Version comes from the tag when CI is building one, else from the closest tag,
# else 0.0.0. Never hand-edited into the plist, so a release cannot ship a
# version string that disagrees with the tag it was cut from.
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")"
fi
VERSION="${VERSION#v}"

# CFBundleVersion must increase monotonically for updaters to work. The commit
# count is the cheapest monotonic number a git checkout already has.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "1")"

echo "==> aiterm $VERSION (build $BUILD_NUMBER)"

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

# Universal, so one download works on both architectures. Shipping arm64-only
# would silently exclude every Intel Mac, and that is not a decision worth
# making by omission.
#
# Built one architecture at a time and joined with `lipo`, rather than with
# SwiftPM's `--arch a --arch b`. That form delegates to Xcode's build system,
# which is not present in a Command Line Tools install — so it would make a full
# Xcode a requirement for cutting a release. Two builds and a `lipo` cost a
# minute and keep the toolchain requirement at Command Line Tools.
SLICES=()
for arch in arm64 x86_64; do
  echo "==> Building release slice: $arch"
  swift build --configuration release --arch "$arch" --disable-sandbox
  slice="$(swift build --configuration release --arch "$arch" --show-bin-path)/$EXECUTABLE"
  [[ -f "$slice" ]] || { echo "package.sh: no $arch binary at $slice" >&2; exit 1; }
  SLICES+=("$slice")
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

BINARY="$STAGING/$EXECUTABLE"
echo "==> Joining slices into a universal binary"
lipo -create "${SLICES[@]}" -output "$BINARY"
lipo -info "$BINARY"

# ---------------------------------------------------------------------------
# Assemble the bundle
# ---------------------------------------------------------------------------

APP="$STAGING/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
cp Sources/AITerm/Info.plist "$APP/Contents/Info.plist"
# The icon, when there is one. Not fatal if missing: a bundle without an icon
# still runs, and a build that stopped because of artwork would be a build
# stopped for the least important reason there is.
if [[ -f Resources/aiterm.icns ]]; then
  cp Resources/aiterm.icns "$APP/Contents/Resources/aiterm.icns"
else
  echo "==> no Resources/aiterm.icns; the bundle will use the generic icon"
fi

# `APPL????` is what a bundle's PkgInfo has said since before any of this
# mattered. Some tooling still looks for the file; none of it looks inside.
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

IDENTITY="${AITERM_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with: $IDENTITY"
  # The hardened runtime is required for notarization. It does not conflict with
  # spawning PTYs — that is the sandbox, which stays off (see project.yml).
  codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> Signing ad-hoc (no AITERM_SIGN_IDENTITY set)"
  echo "    This build runs on the machine that made it. On any other machine"
  echo "    Gatekeeper will refuse it until the quarantine flag is removed:"
  echo "      xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-universal.zip"
rm -f "$ZIP"
# `ditto` rather than `zip`: it preserves the resource forks and the code
# signature, which `zip` does not, and it is what `notarytool` expects.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

if [[ "$BUILD_DMG" == "1" ]]; then
  DMG="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-universal.dmg"
  rm -f "$DMG"

  DMG_ROOT="$STAGING/dmg"
  mkdir -p "$DMG_ROOT"
  cp -R "$APP" "$DMG_ROOT/"
  # The drag-to-install convention. A symlink, so the image stays small.
  ln -s /Applications "$DMG_ROOT/Applications"

  hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -ov -format UDZO \
    -quiet \
    "$DMG"
  echo "==> $DMG"
fi

echo "==> Done"
