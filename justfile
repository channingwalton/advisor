set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias create-dmg := dmg
alias cc := commit-check

default:
    @just --list

commit-check:
    cd App && swift package clean
    rm -rf sidecar/dist
    cd App && swift build
    cd App && swift test
    cd sidecar && npm ci --include=dev
    cd sidecar && npm run build
    cd sidecar && npm test
    git diff --check

dmg:
    cd App && sh dmg.sh

# Cut a release: build the DMG, sync the website's version/size line,
# commit that sync, and tag vVERSION. Bump VERSION first; push manually.
release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(tr -d '[:space:]' < VERSION)
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
        echo "error: tag v$version already exists — bump VERSION first" >&2
        exit 1
    fi
    # www/index.html must be clean: the release commit must contain only the
    # version-line sync, never sweep up unrelated edits.
    if ! git diff --quiet -- www/index.html || ! git diff --quiet --staged -- www/index.html; then
        echo "error: www/index.html has uncommitted changes — commit or stash them first" >&2
        exit 1
    fi
    just dmg
    dmg="App/dist/Advisor-$version.dmg"
    size_mb=$(( ($(stat -f%z "$dmg") + 524288) / 1048576 ))
    sed -i '' -E "s/Version [^<]+ MB/Version $version · $size_mb MB/" www/index.html
    grep -q "Version $version · $size_mb MB" www/index.html \
        || { echo "error: website version line not updated" >&2; exit 1; }
    if ! git diff --quiet -- www/index.html; then
        git commit -m "release: v$version" -- www/index.html
    fi
    git tag "v$version"
    echo "==> v$version released: $dmg ($size_mb MB)"
    echo "    website synced; now: git push && git push origin v$version"

install:
    cd App && sh install.sh

run:
    App/.build/debug/Advisor
