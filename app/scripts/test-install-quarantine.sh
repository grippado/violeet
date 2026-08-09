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
# `Ghostty.app` shares no substring with `violeet` and none with `iterm`
# either: it is the app no glob, no substring match and no case fold could ever
# name, so it is the fixture that stays untouched under every gate this test can
# imagine — which is exactly what makes it the one that fails only if discovery
# stops filtering altogether and starts trashing whatever Spotlight answered.
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
# The install target is in the answer file from the start, and that is the
# whole point of listing it here rather than appending it after the run: the
# stub filters by existence, so during discovery the target does not exist yet
# and is not reported, and by the time the script runs its closing check it
# does. Without this line the only invariant `install.sh` asserts about itself
# — that exactly one bundle survives — was being checked against a Spotlight
# that could not see the bundle just installed. It counted zero real copies, so
# a regression where `cp -R` put nothing in place produced exactly the same
# number as success.
readonly INSTALLED="${FAKE_APPS}/violeet.app"
printf '%s\n' "${BYSTANDERS[@]}" "$STRAY" "$STRAY_CAPS" "$INSTALLED" > "$MDFIND_ANSWER"
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
# here — and it does: the run is asserted to print no `Spotlight still knows`
# warning at all, which only holds because the closing count now goes through
# `is_ours` and therefore ignores `violeet-old.app` and `My violeet.app`.
#
# Matching is a case-insensitive *substring* of the search term with the `.app`
# stripped, and being loose here is the point, not a shortcut. `mdfind -name`
# matches the display name, and macOS drops the extension from the display name
# of every application bundle, so the real thing hands this script neighbours
# like `violeet-old.app` whether it wants them or not.
#
# An exact-match stub was tried first and was worse: it never hands the gate a
# name that merely *contains* the bundle name, so `is_ours` can be swapped for a
# substring match and this test still passes. The stub feeding the gate its
# hardest cases matters more than the stub being tidy.
#
# Method, so the claim is re-checkable: mutate `is_ours` in `install.sh`, run
# this test, expect it red. Three mutations were run against the loose stub and
# all three died — `is_ours` reduced to a substring match fails on
# `My violeet.app`; made case-sensitive, it fails on `Violeet.app`; removed
# altogether, it fails on two bystanders. The baseline passes clean. Against
# the exact-match stub the first of the three survived, which is what condemned
# it. (Recorded in commit `bbca112`.)
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

# -------------------------------------------------------------------------
# The harness
# -------------------------------------------------------------------------

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# `stat -f '%d:%i'` is device and inode: the one pair that survives a rename and
# does not survive being recreated. Taken before anything runs, because after
# the fact there is nothing left to compare against.
ident_of() { stat -f '%d:%i' "$1"; }
declare -a BYSTANDER_IDS=()
for b in "${BYSTANDERS[@]}"; do BYSTANDER_IDS+=("$(ident_of "$b")"); done

trash_listing() { find "${FAKE_HOME}/.Trash" -mindepth 1 -maxdepth 1 | sort; }

# One run of the installer. The output is echoed indented and kept, because two
# of the assertions are about what it printed and not about what it moved.
run_install() {
    local log="$1"
    local status=0
    env HOME="${FAKE_HOME}" PATH="${SANDBOX}/bin:${PATH}" \
        "$COPY" "$SOURCE_ZIP" > "$log" 2>&1 || status=$?
    sed 's/^/    | /' "$log"
    return "$status"
}

assert_bystanders_intact() {
    local label="$1" b
    for b in "${BYSTANDERS[@]}"; do
        if [[ -d "$b" ]]; then
            pass "${label}: left alone: $b"
        else
            fail "${label}: installer moved a bundle that is not violeet: $b"
        fi
    done
}

# The Trash, checked by identity rather than by name.
#
# Checking the name here cannot fail, and for a while it looked like it could:
# `install.sh` renames everything it moves to `violeet-<version>-<pid>-<n>.app`,
# so a `case` accepting `violeet-*` accepts every arrival there can ever be,
# somebody else's terminal included. The device:inode pair recorded above is the
# thing that rename does not touch, so this catches what the bystander loop
# cannot: a bundle moved to the Trash *and recreated* at its old path, which
# leaves `[[ -d "$b" ]]` true while the original is gone.
#
# Both sides live inside a single `mktemp -d`, so a move here is always a rename
# within one filesystem and never a copy-and-delete; the inode is stable by
# construction, and that is what makes the comparison sound.
assert_no_bystander_in_trash() {
    local label="$1" trashed id known hit=0
    while IFS= read -r trashed; do
        [[ -e "$trashed" ]] || continue
        id="$(ident_of "$trashed")"
        for known in "${BYSTANDER_IDS[@]}"; do
            if [[ "$id" == "$known" ]]; then
                fail "${label}: a bystander is in the Trash as $trashed"
                hit=1
            fi
        done
    done < <(trash_listing)
    if [[ "$hit" -eq 0 ]]; then
        pass "${label}: no bystander reached the Trash"
    fi
}

assert_installed() {
    local label="$1"
    if [[ -d "$INSTALLED" ]]; then
        pass "${label}: violeet.app installed"
    else
        fail "${label}: violeet.app was not installed"
    fi
}

# The closing check of `install.sh` is the only invariant it asserts about
# itself, and a warning that fires on a good run is one people learn to skip
# past. So a good run is asserted to be silent.
assert_no_spotlight_warning() {
    local label="$1" log="$2"
    if grep -q 'Spotlight still knows' "$log"; then
        fail "${label}: the closing check warned on a successful run"
    else
        pass "${label}: no bogus Spotlight warning"
    fi
}

assert_exit_zero() {
    local label="$1" status="$2"
    if [[ "$status" -eq 0 ]]; then
        pass "${label}: exited 0"
    else
        fail "${label}: exited ${status}"
    fi
}

# -------------------------------------------------------------------------
# Run 1: a machine full of other people's bundles
# -------------------------------------------------------------------------

echo "==> running install.sh in ${SANDBOX}"
run_status=0
run_install "${SANDBOX}/run.log" || run_status=$?

assert_exit_zero "first run" "$run_status"
assert_bystanders_intact "first run"
assert_no_bystander_in_trash "first run"
assert_installed "first run"
assert_no_spotlight_warning "first run" "${SANDBOX}/run.log"

# Exactly the two strays, and nothing else. The identity check above says no
# bystander arrived; this says nothing else did either, including anything the
# fixtures do not know about.
trashed_count="$(trash_listing | grep -c . || true)"
if [[ "$trashed_count" -eq 2 ]]; then
    pass "first run: exactly the two strays are in the Trash"
else
    fail "first run: expected 2 bundles in the Trash, found ${trashed_count}"
fi

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

# -------------------------------------------------------------------------
# The runs that are not the first one
# -------------------------------------------------------------------------
#
# Everything above happens once, with two strays on disk and Spotlight
# answering. The three runs below are the shapes a real machine also has, and
# each of them reaches a branch nothing else here touches. They share one
# expectation, so it is written once: exit 0, the bundle installed, the
# bystanders untouched, and no new arrival in the Trash — there are no strays
# left to quarantine after the first run, so any movement at all is a bug.
#
# Not covered, and not pretended to be: the locale. The installer runs as a
# child of this process and inherits its locale, so the `LC_ALL=C` inside
# `is_ours` cannot be made to matter from out here without a `tr_TR.UTF-8` the
# runner is not guaranteed to have.
trash_before="$(trash_listing)"
assert_trash_unchanged() {
    local label="$1"
    if [[ "$(trash_listing)" == "$trash_before" ]]; then
        pass "${label}: nothing new in the Trash"
    else
        fail "${label}: something was moved to the Trash with no strays left"
    fi
}

follow_up_run() {
    local label="$1" log="${SANDBOX}/$2"
    local status=0
    echo "==> ${label}"
    run_install "$log" || status=$?
    assert_exit_zero "$label" "$status"
    assert_installed "$label"
    assert_bystanders_intact "$label"
    assert_no_bystander_in_trash "$label"
    assert_trash_unchanged "$label"
    assert_no_spotlight_warning "$label" "$log"
}

# Running it twice in a row is the ordinary case for anyone who installs more
# than once, and it is the only way to reach the `rm -rf "$TARGET"` branch:
# the first run has nothing at the target to replace.
follow_up_run "second run (idempotence)" "run-2.log"

# A clean machine, where Spotlight finds nothing at all. `FOUND` ends up empty,
# which is the state that once made the loop run one time with `path=""` and try
# to move a file with no name to the Trash — the bug that `${FOUND[@]+...}` in
# `install.sh` exists to prevent, and which no other run here reaches.
: > "$MDFIND_ANSWER"
follow_up_run "third run (clean machine, Spotlight finds nothing)" "run-3.log"

# Spotlight off or broken. `install.sh` swallows the failure with
# `2>/dev/null || true` in both places it asks, so this has to degrade into "no
# copies found, nothing to do" and still install — not abort halfway.
printf '#!/usr/bin/env bash\necho "mdfind: unavailable" >&2\nexit 1\n' \
    > "${SANDBOX}/bin/mdfind"
chmod +x "${SANDBOX}/bin/mdfind"
follow_up_run "fourth run (mdfind unavailable)" "run-4.log"

if [[ "$failures" -eq 0 ]]; then
    echo "==> install.sh moved only violeet bundles"
else
    echo "==> ${failures} failure(s)" >&2
    exit 1
fi
