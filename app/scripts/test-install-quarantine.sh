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
# `violeet-old.app` and `My violeet.app` are the boundary: both contain the
# bundle name, neither *is* it. They are what tells a name gate apart from a
# substring match, and a substring match here is how the LAB-53 family of bugs
# gets you.
readonly BYSTANDERS=(
    "${FAKE_HOME}/Applications/iTerm.app"
    "${FAKE_APPS}/iTerm.app"
    "${FAKE_HOME}/Applications/iterm2.app"
    "${FAKE_APPS}/Ghostty.app"
    "${FAKE_HOME}/Applications/violeet-old.app"
    "${FAKE_APPS}/My violeet.app"
)
for b in "${BYSTANDERS[@]}"; do make_bundle "$b"; done

# Two genuine strays, so a pass cannot be "it moved nothing at all".
#
# The second one is capitalised on purpose. Without it the whole lowercasing
# branch of `is_ours` is dead code as far as this test is concerned: swap the
# comparison for a case-sensitive one and everything still passes. It is also
# the case `mdfind -name "Violeet.app"` exists to catch.
#
# It lives in a directory of its own, and that is not tidiness. The default
# macOS filesystem is case-insensitive, so `Violeet.app` next to the stray or
# next to the install target would *be* the same directory as `violeet.app`,
# and the fixture would silently collide with the very thing it is testing
# against.
readonly FAKE_ELSEWHERE="${SANDBOX}/Elsewhere"
mkdir -p "$FAKE_ELSEWHERE"
readonly STRAY="${FAKE_HOME}/Applications/violeet.app"
make_bundle "$STRAY"
readonly STRAY_CAPS="${FAKE_ELSEWHERE}/Violeet.app"
make_bundle "$STRAY_CAPS"

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
printf '%s\n' "${BYSTANDERS[@]}" "$STRAY" "$STRAY_CAPS" > "$MDFIND_ANSWER"
# The stub answers the question it was asked, instead of replaying a fixed
# list. Two things follow from that, and both matter.
#
# It filters by existence, because real Spotlight does not report a bundle that
# was just moved to the Trash. And it honours `-name`, because the script asks
# twice for different things: once to discover copies, and once at the end to
# check that exactly one survived. A stub that answers both with everything
# makes that closing check report six on a successful run, and a warning that
# fires on success is one people learn to skip past. That check is the only
# invariant the script asserts about itself, so it deserves to mean something
# here.
#
# Matching is a case-insensitive *substring* of the search term with the `.app`
# stripped, and being loose here is the point, not a shortcut. `mdfind -name`
# matches the display name, and macOS drops the extension from the display name
# of every application bundle, so the real thing hands this script neighbours
# like `violeet-old.app` whether it wants them or not.
#
# An exact-match stub was tried first and was worse: it never hands the gate a
# name that merely *contains* the bundle name, so `is_ours` can be swapped for a
# substring match and this test still passes. Verified by mutation. The stub
# feeding the gate its hardest cases matters more than the stub being tidy.
cat > "${SANDBOX}/bin/mdfind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
want=""
[[ "${1:-}" == "-name" ]] && want="${2:-}"
want="$(printf '%s' "${want%.app}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
while IFS= read -r p; do
    [[ -e "$p" ]] || continue
    name="$(printf '%s' "${p##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [[ -z "$want" || "$name" == *"$want"* ]] && printf '%s\n' "$p"
done < "__ANSWER__"
EOF
# The path is patched in rather than interpolated by the here-document, so the
# body above can stay quoted and none of its own `$` need escaping.
sed -i.bak "s|__ANSWER__|${MDFIND_ANSWER}|" "${SANDBOX}/bin/mdfind"
rm -f "${SANDBOX}/bin/mdfind.bak"
chmod +x "${SANDBOX}/bin/mdfind"

# The copy under test, pointed away from everything global it touches.
#
# `INSTALL_DIR` is the obvious one. `LSREGISTER` is the one that is easy to
# miss: it is an absolute path to a real binary that exists on every macOS, and
# the script hands it the freshly installed `TARGET`. Left alone, running this
# test registers a bundle living under `mktemp -d` in the machine's real
# LaunchServices database, and the cleanup trap then deletes the directory it
# just registered. The leftover is a record pointing at a path that no longer
# exists, which is precisely the disease this installer was written to cure.
readonly COPY="${SANDBOX}/install-under-test.sh"
readonly NO_LSREGISTER="${SANDBOX}/bin/no-lsregister"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NO_LSREGISTER"
chmod +x "$NO_LSREGISTER"
sed -e "s|^readonly INSTALL_DIR=.*|readonly INSTALL_DIR=\"${FAKE_APPS}\"|" \
    -e "s|^readonly LSREGISTER=.*|readonly LSREGISTER=\"${NO_LSREGISTER}\"|" \
    "$UNDER_TEST" > "$COPY"
chmod +x "$COPY"
# Both substitutions are guarded, for the same reason the first one always was:
# if a refactor of install.sh stops either line from matching, the test has to
# refuse to run rather than run against the real thing.
if ! grep -q "readonly INSTALL_DIR=\"${FAKE_APPS}\"" "$COPY"; then
    echo "FAIL: could not redirect INSTALL_DIR; refusing to run against the real one" >&2
    exit 1
fi
if ! grep -q "readonly LSREGISTER=\"${NO_LSREGISTER}\"" "$COPY"; then
    echo "FAIL: could not neutralise lsregister; refusing to touch the real LaunchServices" >&2
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

# The one that keeps the lowercasing honest. If this passes while a
# case-sensitive comparison is in place, something is wrong with the fixture,
# not with the gate.
if [[ -d "$STRAY_CAPS" ]]; then
    fail "the capitalised Violeet.app was not quarantined; is_ours is not case-insensitive"
else
    pass "capitalised Violeet.app was quarantined"
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
