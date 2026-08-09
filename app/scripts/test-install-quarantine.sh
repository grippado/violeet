#!/usr/bin/env bash
#
# Does `install.sh` move anything that is not a violeet bundle?
#
# The install script discovers paths instead of being handed them, and what it
# discovers it moves to the Trash. That is a fine trade as long as discovery
# cannot name somebody else's app — and for a while it could: two globs
# inherited from a fork hunted for `*iterm*.app` and quarantined the result.
# They never fired on the machine they were written on, purely because the glob
# was case-sensitive and the bundle is called `iTerm.app`.
#
# So this test asks the only question that matters: hand the installer a
# machine full of other people's bundles, and see whether any of them move.
#
# It never touches the real /Applications or the real Trash. It runs a *copy*
# of install.sh with `INSTALL_DIR` rewritten into a temporary directory, with
# `HOME` pointed at that directory too, and with `mdfind` stubbed so Spotlight's
# answer is something this test chose. The stub deliberately reports the other
# apps as well: a gate that only works because discovery happened to stay quiet
# is the bug this test exists to catch.
#
# Usage: app/scripts/test-install-quarantine.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly UNDER_TEST="${SCRIPT_DIR}/install.sh"

SANDBOX="$(mktemp -d)"
readonly SANDBOX
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

readonly FAKE_HOME="${SANDBOX}/home"
readonly FAKE_APPS="${SANDBOX}/Applications"
mkdir -p "${FAKE_HOME}/.Trash" "${FAKE_HOME}/Applications" "${FAKE_APPS}" "${SANDBOX}/bin"

# A bundle is just a directory as far as this script is concerned, and the
# `[[ -d ]]` guard in the loop is why that matters.
make_bundle() { mkdir -p "$1/Contents"; }

# The bystanders. `iTerm.app` is the real name on disk; `iterm2.app` is spelled
# the way the old glob expected, so it stands in for the rename or the
# `nocaseglob` that would have made the old code fire for real.
readonly BYSTANDERS=(
    "${FAKE_HOME}/Applications/iTerm.app"
    "${FAKE_APPS}/iTerm.app"
    "${FAKE_HOME}/Applications/iterm2.app"
    "${FAKE_APPS}/Ghostty.app"
)
for b in "${BYSTANDERS[@]}"; do make_bundle "$b"; done

# One genuine stray violeet, so a pass cannot be "it moved nothing at all".
readonly STRAY="${FAKE_HOME}/Applications/violeet.app"
make_bundle "$STRAY"

# What gets installed. A zip, because that is what `make install` hands over,
# and because the argument shapes are not equivalent: given a bundle directly,
# `install.sh` leaves `STAGING` empty, its `EXIT` trap ends on a false test, and
# the script exits 1 after a completely successful install. That is a real wart
# but it is not what this test is about, so the test takes the path the Makefile
# takes rather than working around it.
readonly SOURCE_BUNDLE="${SANDBOX}/src/violeet.app"
make_bundle "$SOURCE_BUNDLE"
readonly SOURCE_ZIP="${SANDBOX}/src/violeet.zip"
ditto -ck --keepParent "$SOURCE_BUNDLE" "$SOURCE_ZIP"

# Spotlight, replaced by a stub that answers with every bundle in the sandbox,
# bystanders included. The answer lives in a data file rather than inside the
# stub, so no quoting of sandbox paths has to survive a here-document.
readonly MDFIND_ANSWER="${SANDBOX}/mdfind-answer.txt"
printf '%s\n' "${BYSTANDERS[@]}" "$STRAY" > "$MDFIND_ANSWER"
cat > "${SANDBOX}/bin/mdfind" <<EOF
#!/usr/bin/env bash
cat "${MDFIND_ANSWER}"
EOF
chmod +x "${SANDBOX}/bin/mdfind"

# The copy under test, pointed away from the real /Applications.
readonly COPY="${SANDBOX}/install-under-test.sh"
sed "s|^readonly INSTALL_DIR=.*|readonly INSTALL_DIR=\"${FAKE_APPS}\"|" \
    "$UNDER_TEST" > "$COPY"
chmod +x "$COPY"
if ! grep -q "readonly INSTALL_DIR=\"${FAKE_APPS}\"" "$COPY"; then
    echo "FAIL: could not redirect INSTALL_DIR; refusing to run against the real one" >&2
    exit 1
fi

echo "==> running install.sh in ${SANDBOX}"
set +e
env HOME="${FAKE_HOME}" PATH="${SANDBOX}/bin:${PATH}" \
    "$COPY" "$SOURCE_ZIP" > "${SANDBOX}/run.log" 2>&1
run_status=$?
set -e
sed 's/^/    | /' "${SANDBOX}/run.log"

# -------------------------------------------------------------------------
# The assertions
# -------------------------------------------------------------------------

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

if [[ "$run_status" -eq 0 ]]; then
    pass "install.sh exited 0"
else
    fail "install.sh exited ${run_status}"
fi

for b in "${BYSTANDERS[@]}"; do
    if [[ -d "$b" ]]; then
        pass "left alone: $b"
    else
        fail "installer moved a bundle that is not violeet: $b"
    fi
done

# Nothing that is not a violeet bundle may show up in the Trash either, which
# catches a move that also recreated the original.
while IFS= read -r trashed; do
    [[ -e "$trashed" ]] || continue
    case "$(basename "$trashed")" in
        violeet-*) ;;
        *) fail "non-violeet bundle in the Trash: $trashed" ;;
    esac
done < <(find "${FAKE_HOME}/.Trash" -mindepth 1 -maxdepth 1)

if [[ -d "$STRAY" ]]; then
    fail "the stray violeet.app was not quarantined; the test proves nothing"
else
    pass "stray violeet.app was quarantined"
fi

if [[ -d "${FAKE_APPS}/violeet.app" ]]; then
    pass "violeet.app installed"
else
    fail "violeet.app was not installed"
fi

if [[ "$failures" -eq 0 ]]; then
    echo "==> install.sh moved only violeet bundles"
else
    echo "==> ${failures} failure(s)" >&2
    exit 1
fi
