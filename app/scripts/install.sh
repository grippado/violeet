#!/usr/bin/env bash
#
# Install a built violeet into /Applications, and make sure it is the only one.
#
# # Why this is not `cp`
#
# It was `cp` for a while, and the failure it produced is the reason this file
# exists: Spotlight kept opening **v0.3.0** long after v0.9.0 was installed.
# Not a caching problem — there were six copies of the bundle on the machine,
# in `~/Applications` and in scratch directories, all of them registered with
# LaunchServices. Spotlight was not stale, it was ranking a real, older app.
#
# A version people cannot open is a version that was not shipped, so this
# script's job is not "copy the bundle" but "leave exactly one on disk".
#
# # Why bundles go to the Trash
#
# Anything found outside the install location is *moved to the Trash*, never
# deleted. This walks over paths it discovered rather than paths it was given,
# and a discovery bug that deletes is unrecoverable while a discovery bug that
# moves is an annoyance. The Trash is the difference.
#
# Usage: app/scripts/install.sh [path/to/violeet.app | path/to/dist.zip]
#        With no argument, the newest zip in app/dist is used.

set -euo pipefail

readonly INSTALL_DIR="/Applications"
readonly BUNDLE_NAME="violeet.app"
readonly TARGET="${INSTALL_DIR}/${BUNDLE_NAME}"

readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

here() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
readonly APP_DIR="$(here)"

version_of() {
    defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------------------
# 1. Work out what to install
# ---------------------------------------------------------------------------

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
    SOURCE="$(ls -t "${APP_DIR}"/dist/*.zip 2>/dev/null | head -1 || true)"
    if [[ -z "$SOURCE" ]]; then
        echo "no build to install: pass a path, or run scripts/package.sh first" >&2
        exit 1
    fi
fi

STAGING=""
cleanup() { [[ -n "$STAGING" ]] && rm -rf "$STAGING"; }
trap cleanup EXIT

if [[ "$SOURCE" == *.zip ]]; then
    STAGING="$(mktemp -d)"
    ditto -xk "$SOURCE" "$STAGING"
    BUNDLE="${STAGING}/${BUNDLE_NAME}"
else
    BUNDLE="$SOURCE"
fi

if [[ ! -d "$BUNDLE" ]]; then
    echo "not a bundle: $BUNDLE" >&2
    exit 1
fi

readonly NEW_VERSION="$(version_of "$BUNDLE")"
echo "==> installing ${NEW_VERSION}"

# ---------------------------------------------------------------------------
# 2. Find every other copy on the machine
# ---------------------------------------------------------------------------
#
# `mdfind` finds what Spotlight can open, which is the whole point — a bundle
# Spotlight has never indexed cannot be the one it launches. The fixed paths
# are there because a *just*-created bundle may not be indexed yet, and because
# `~/Applications` is where the copy that caused this actually was.

declare -a FOUND=()
while IFS= read -r path; do
    [[ -d "$path" ]] && FOUND+=("$path")
done < <(
    {
        mdfind -name "violeet.app" 2>/dev/null || true
        mdfind -name "Violeet.app" 2>/dev/null || true
        ls -d "${HOME}/Applications/"*iterm*.app 2>/dev/null || true
        ls -d "${INSTALL_DIR}/"*iterm*.app 2>/dev/null || true
    } | sort -u
)

QUARANTINED=0
# `"${FOUND[@]:-}"` looks like a safe expansion under `set -u` and is not: with
# an empty array it yields one *empty string* rather than nothing, so the loop
# runs once with `path=""`, every guard below passes vacuously, and the script
# tries to move a file with no name to the Trash. Seen for real the first time
# there were no stray copies to clean up — which is to say, on a clean machine.
# `${FOUND[@]+"${FOUND[@]}"}` expands to nothing at all when the array is empty.
for path in ${FOUND[@]+"${FOUND[@]}"}; do
    [[ -n "$path" ]] || continue
    # The one being installed, and the place it is going, are not strays.
    [[ "$path" == "$TARGET" ]] && continue
    [[ "$path" == "$BUNDLE" ]] && continue
    [[ -n "$STAGING" && "$path" == "$STAGING"* ]] && continue
    # A bundle inside a mounted disk image is read-only and disappears on
    # eject; touching it would fail and it cannot outlive the session anyway.
    [[ "$path" == /Volumes/* ]] && continue

    echo "    · moving to Trash: $(version_of "$path")  $path"
    # A timestamped name, because the Trash already holding an `violeet.app`
    # would otherwise make this fail — or worse, overwrite.
    mv "$path" "${HOME}/.Trash/violeet-$(version_of "$path")-$$-${QUARANTINED}.app"
    QUARANTINED=$((QUARANTINED + 1))
done

# ---------------------------------------------------------------------------
# 3. Install, and tell LaunchServices
# ---------------------------------------------------------------------------

if [[ -d "$TARGET" ]]; then
    echo "    · replacing $(version_of "$TARGET")"
    rm -rf "$TARGET"
fi
cp -R "$BUNDLE" "$TARGET"

# Without this, LaunchServices keeps its record of the bundles just removed and
# can still resolve a name to one of them until it notices on its own.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
fi

echo "==> ${TARGET} is ${NEW_VERSION}"
[[ "$QUARANTINED" -gt 0 ]] && echo "==> ${QUARANTINED} older copies moved to the Trash"

# The check that matters: after all that, is there exactly one?
REMAINING="$(mdfind -name "violeet.app" 2>/dev/null | grep -c . || true)"
if [[ "$REMAINING" -gt 1 ]]; then
    echo "!!  Spotlight still knows ${REMAINING} bundles; re-run after it reindexes" >&2
fi
