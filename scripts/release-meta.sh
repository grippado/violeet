#!/usr/bin/env bash
#
# What a release says about itself, resolved once and read from two places.
#
# The release body and docs/latest-release.json describe the same tags, so they
# resolve the changelog through the same chain here rather than through two
# copies that drift apart the first time one of them is fixed.
#
# Usage:
#   scripts/release-meta.sh changelog <tag>   the tag's changelog, as published
#   scripts/release-meta.sh json <tag>        docs/latest-release.json contents
#
# `json` reads release metadata with `gh`, so it needs GH_TOKEN (or a logged-in
# gh) to fill published_at and html_url. Without a release for a tag those two
# degrade to null and the tag page, never to an invented date.

set -euo pipefail

# The summary is cut by character count, and `${#s}` counts characters under a
# UTF-8 locale and bytes outside one. Without this the same tag is truncated at
# two different places, and a cut landing inside a multibyte character puts an
# orphan byte on the page.
export LC_ALL=en_US.UTF-8

# Normally the repository is the one this file lives in. The release workflow
# copies the script out of the checkout before switching branches, and that copy
# has no repository above it, so it falls back to the one it was called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    ROOT="$(git rev-parse --show-toplevel)"
fi
cd "$ROOT"

SUMMARY_MAX=140
NO_CHANGELOG="Sem changelog registrado para esta tag."

CHANGELOG=""
CHANGELOG_SOURCE="none"

# The chain: what a human wrote on the tag, else the subject of the commit it
# points at, else a plain statement that there is nothing. It reads, it never
# writes: no summarizing, no invented prose.
resolve_changelog() {
    local tag="$1"
    CHANGELOG=""
    CHANGELOG_SOURCE="none"

    if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
        # The test is the object type, not whether the string came back empty:
        # on a lightweight tag `%(contents)` does not return nothing, it quietly
        # returns the whole message of the commit underneath. v0.1.1 is such a
        # tag, and it would otherwise publish a full commit body, sign-off
        # trailer included, as if it were a changelog.
        if [[ "$(git cat-file -t "$tag")" == "tag" ]]; then
            CHANGELOG="$(git for-each-ref --format='%(contents)' "refs/tags/$tag")"
            if [[ "$CHANGELOG" =~ [^[:space:]] ]]; then
                CHANGELOG_SOURCE="tag_message"
            fi
        fi
        if [[ ! "$CHANGELOG" =~ [^[:space:]] ]]; then
            CHANGELOG="$(git log -1 --format=%s "$tag")"
            if [[ "$CHANGELOG" =~ [^[:space:]] ]]; then
                CHANGELOG_SOURCE="commit_subject"
            fi
        fi
    fi

    if [[ ! "$CHANGELOG" =~ [^[:space:]] ]]; then
        CHANGELOG="$NO_CHANGELOG"
        CHANGELOG_SOURCE="none"
    fi
}

ltrim() {
    local s="$1"
    printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

rtrim() {
    local s="$1"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# "violeet 0.4.2 — x", "v0.4.2: x" and "0.4.2 - x" all carry the same header,
# and the page already shows the version next to the summary. Only the part
# after the header is worth repeating.
strip_version_header() {
    local line="$1"
    local rest="$line"

    if [[ "$rest" == violeet\ * ]]; then
        rest="$(ltrim "${rest#violeet }")"
    fi
    rest="${rest#v}"

    if [[ ! "$rest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?(.*)$ ]]; then
        printf '%s' "$line"
        return
    fi
    rest="$(ltrim "${BASH_REMATCH[2]}")"

    local sep found=""
    for sep in ':' '—' '–' '-' '|'; do
        if [[ "$rest" == "$sep"* ]]; then
            found="$sep"
            break
        fi
    done
    if [[ -z "$found" ]]; then
        printf '%s' "$line"
        return
    fi

    rest="$(ltrim "${rest#"$found"}")"
    if [[ -z "$rest" ]]; then
        printf '%s' "$line"
        return
    fi
    printf '%s' "$rest"
}

# The JSON carries one line; the full body stays on the release, which is the
# one place it can grow without the page having to render it.
summarize() {
    local text="$1"
    local line
    line="$(printf '%s\n' "$text" | head -n 1)"
    line="$(rtrim "$(ltrim "$line")")"
    line="$(strip_version_header "$line")"
    if (( ${#line} > SUMMARY_MAX )); then
        line="$(rtrim "${line:0:SUMMARY_MAX-1}")…"
    fi
    printf '%s' "$line"
}

repo_url() {
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        printf '%s/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY"
        return
    fi
    local remote
    remote="$(git remote get-url origin)"
    remote="${remote%.git}"
    remote="${remote#git@github.com:}"
    remote="${remote#https://github.com/}"
    printf 'https://github.com/%s' "$remote"
}

# Semver order, never chronological. A tag created today can point at an old
# commit, so ordering by date would hand the page a historical release as the
# "previous" one of a version cut after it.
previous_tag() {
    local current="$1"
    local seen_current=0 first_other="" tag

    while read -r tag; do
        [[ -z "$tag" ]] && continue
        if [[ "$tag" == "$current" ]]; then
            seen_current=1
            continue
        fi
        # A prerelease is not a version the page offers, so it is not a version
        # the page went back from either.
        [[ "$tag" == *-* ]] && continue
        if (( seen_current )); then
            printf '%s' "$tag"
            return
        fi
        [[ -z "$first_other" ]] && first_other="$tag"
    done < <(git tag --list 'v[0-9]*' --sort=-v:refname)

    # The tag being released is normally the highest one there is; when it is
    # not in the list at all (a dispatch for a tag nobody pushed), the highest
    # released version is still the honest answer.
    if (( ! seen_current )); then
        printf '%s' "$first_other"
    fi
}

entry_json() {
    local tag="$1"
    local summary published_at html_url meta

    resolve_changelog "$tag"
    summary="$(summarize "$CHANGELOG")"

    if meta="$(gh release view "$tag" --json publishedAt,url 2> /dev/null)"; then
        published_at="$(printf '%s' "$meta" | jq -r '.publishedAt')"
        html_url="$(printf '%s' "$meta" | jq -r '.url')"
    else
        published_at=""
        html_url="$(repo_url)/releases/tag/$tag"
    fi

    jq -n \
        --arg version "${tag#v}" \
        --arg tag "$tag" \
        --arg published_at "$published_at" \
        --arg html_url "$html_url" \
        --arg summary "$summary" \
        --arg changelog_source "$CHANGELOG_SOURCE" \
        '{
            version: $version,
            tag: $tag,
            published_at: (if $published_at == "" then null else $published_at end),
            html_url: $html_url,
            summary: $summary,
            changelog_source: $changelog_source
        }'
}

# Two named fields and not a list: the page shows the last two versions and
# sends everyone else to the tag list. A list would be an invitation to grow.
release_json() {
    local tag="$1"
    local latest previous_ref previous

    latest="$(entry_json "$tag")"
    previous_ref="$(previous_tag "$tag")"
    if [[ -n "$previous_ref" ]]; then
        previous="$(entry_json "$previous_ref")"
    else
        previous="null"
    fi

    jq -n \
        --argjson latest "$latest" \
        --argjson previous "$previous" \
        --arg all_tags_url "$(repo_url)/tags" \
        '{latest: $latest, previous: $previous, all_tags_url: $all_tags_url}'
}

main() {
    local command="${1:-}"
    local tag="${2:-}"

    if [[ -z "$command" || -z "$tag" ]]; then
        echo "usage: scripts/release-meta.sh {changelog|json} <tag>" >&2
        exit 2
    fi

    case "$command" in
        changelog)
            resolve_changelog "$tag"
            printf '%s\n' "$CHANGELOG"
            ;;
        json)
            release_json "$tag"
            ;;
        *)
            echo "unknown command: $command" >&2
            exit 2
            ;;
    esac
}

main "$@"
