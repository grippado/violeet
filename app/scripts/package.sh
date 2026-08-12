#!/usr/bin/env bash
#
# Build violeet.app and wrap it in a .dmg and a .zip.
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
#   VIOLEET_SIGN_IDENTITY   Codesign identity. Empty or unset means ad-hoc.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="violeet"
EXECUTABLE="Violeet"
BUNDLE_ID="digital.opengateway.violeet"
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

# Which commit this bundle came from. The version string does not identify a
# build during development — `0.9.2-dev` is cut a dozen times a day — so a bug
# report that quotes only the version points at a range and not a revision. The
# About panel shows this; `unknown` is left in place when there is no checkout,
# and the panel then shows nothing rather than a hash that is not one.
GIT_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
if [[ "$GIT_COMMIT" != "unknown" ]] && ! git diff --quiet HEAD 2>/dev/null; then
  # A build with uncommitted changes is not the commit it names, and saying so
  # here is cheaper than working it out from a bug report that does not
  # reproduce.
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi

echo "==> violeet $VERSION (build $BUILD_NUMBER)"

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
cp Sources/Violeet/Info.plist "$APP/Contents/Info.plist"
# The icon, when there is one. Not fatal if missing: a bundle without an icon
# still runs, and a build that stopped because of artwork would be a build
# stopped for the least important reason there is.
if [[ -f Resources/violeet.icns ]]; then
  cp Resources/violeet.icns "$APP/Contents/Resources/violeet.icns"
else
  echo "==> no Resources/violeet.icns; the bundle will use the generic icon"
fi

# The menu bar mark, as a PDF. Vector on purpose: `NSImage` scales a PDF without
# resampling, so one file serves every display instead of an @1x, an @2x and an
# @3x that is still soft on the display nobody has yet. Same tolerance as the
# icon above — missing artwork falls back in code, it does not fail a build.
if [[ -f Resources/violeet-menubar.pdf ]]; then
  cp Resources/violeet-menubar.pdf "$APP/Contents/Resources/violeet-menubar.pdf"
else
  echo "==> no Resources/violeet-menubar.pdf; the menu bar falls back to an SF Symbol"
fi

# Host marks for the editor panel's commit line. Same tolerance again: a missing
# one falls back to a generic glyph in code.
for host in Resources/host-*.png; do
  [[ -f "$host" ]] && cp "$host" "$APP/Contents/Resources/$(basename "$host")"
done

# ---------------------------------------------------------------------------
# The daemon travels inside the app
# ---------------------------------------------------------------------------
#
# Until this existed, a .dmg contained an app that could never find a daemon:
# there was no installer for one, the README said "run it", and the only
# machine where it worked was the one where somebody had put it under launchd
# by hand. Downloading the app and getting a permanently offline board is not a
# missing feature, it is a broken product.
#
# So the daemon and the CLI ship in `Contents/Resources`, universal like the
# app, and the app starts the daemon from there. Nothing outside the bundle has
# to exist. Updating the app updates the daemon, because the launchd job points
# at this path.
#
# Not a `LoginItem` bundle, which is the modern Apple answer: those need a real
# Developer ID to register at all, and this build is ad-hoc signed. A LaunchAgent
# plist works either way, and the app writes it on first run.

echo "==> Building the daemon and CLI"
DAEMON_SLICES=()
CLI_SLICES=()
for arch in arm64 x86_64; do
  target="$( [[ "$arch" == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin )"
  # `rustup target add` is a no-op when it is already there, and the build fails
  # with a clear message when rustup itself is missing.
  rustup target add "$target" >/dev/null 2>&1 || true
  (cd .. && cargo build --release --target "$target" --bin violeet-daemon --bin violeet) \
    || { echo "package.sh: cargo build failed for $target" >&2; exit 1; }
  DAEMON_SLICES+=("../target/$target/release/violeet-daemon")
  CLI_SLICES+=("../target/$target/release/violeet")
done

lipo -create "${DAEMON_SLICES[@]}" -output "$APP/Contents/Resources/violeet-daemon"
lipo -create "${CLI_SLICES[@]}" -output "$APP/Contents/Resources/violeet"
chmod +x "$APP/Contents/Resources/violeet-daemon" "$APP/Contents/Resources/violeet"
echo "==> daemon: $(lipo -archs "$APP/Contents/Resources/violeet-daemon")"

# `APPL????` is what a bundle's PkgInfo has said since before any of this
# mattered. Some tooling still looks for the file; none of it looks inside.
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :VioleetGitCommit $GIT_COMMIT" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

IDENTITY="${VIOLEET_SIGN_IDENTITY:-}"
ENTITLEMENTS="Sources/Violeet/Violeet.entitlements"

if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with: $IDENTITY"
  # The hardened runtime is required for notarization. It does not conflict with
  # spawning PTYs — that is the sandbox, which stays off (see project.yml).
  #
  # The entitlements are not optional under that runtime: it blocks audio input
  # before TCC is consulted, so a signed build without them has no dictation in
  # any tab no matter what Info.plist says. Passed on the ad-hoc path too, so
  # the bundle people actually test is the bundle that ships.
  codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> Signing ad-hoc (no VIOLEET_SIGN_IDENTITY set)"
  echo "    This build runs on the machine that made it. On any other machine"
  echo "    Gatekeeper will refuse it until the quarantine flag is removed:"
  echo "      xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" "$APP"
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
