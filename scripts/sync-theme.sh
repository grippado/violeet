#!/usr/bin/env bash
#
# Pull Violeeter in from its own repository.
#
# The theme is developed in grippado/violeeter and copied here — see
# vendor/violeeter/README.md for why a copy rather than a submodule. This script
# is the copy, so that "how do I update the theme" has one answer and it is not
# "remember which two files".
#
# Usage: scripts/sync-theme.sh [path/to/violeeter]
#        Defaults to a checkout beside this repository.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"

SOURCE="${1:-$REPO_ROOT/../violeeter}"
if [[ ! -f "$SOURCE/violeeter.json" ]]; then
    echo "no violeeter checkout at $SOURCE" >&2
    echo "clone it:  git clone https://github.com/grippado/violeeter $SOURCE" >&2
    exit 1
fi

# Generated files first, so a stale dist/ cannot be what gets copied in.
if command -v python3 >/dev/null 2>&1; then
    (cd "$SOURCE" && python3 build.py >/dev/null && python3 build.py --check >/dev/null) || {
        echo "upstream theme fails its own contrast check; not syncing" >&2
        exit 1
    }
fi

cp "$SOURCE/violeeter.json" vendor/violeeter/violeeter.json
cp "$SOURCE/dist/violeeter.css" vendor/violeeter/violeeter.css

# The page is served from docs/ and cannot reach into vendor/.
cp vendor/violeeter/violeeter.json docs/violeeter.json
cp vendor/violeeter/violeeter.css docs/violeeter.css

echo "==> synced Violeeter $(python3 -c "import json;print(json.load(open('vendor/violeeter/violeeter.json'))['version'])" 2>/dev/null || echo "")"

# The app carries its own transcription of the palette, and the test that
# compares the two is the thing that keeps them honest. Running it here means a
# sync that drifts the theme fails at the moment of syncing, rather than later
# and somewhere else.
if command -v swift >/dev/null 2>&1; then
    echo "==> checking the app's palette still matches"
    (cd app && swift test --filter Violeeter 2>&1 | tail -3)
fi
