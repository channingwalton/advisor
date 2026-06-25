set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias create-dmg := dmg

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

install:
    cd App && sh install.sh
