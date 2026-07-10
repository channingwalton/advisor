#!/usr/bin/env bash
# Tests for the repo-root `justfile`.
#
# Covers the rename of `commit-check` -> `check` (and its alias `cc`) and the
# removal of the `create-dmg` alias for `dmg`. See ../justfile.
#
# Static checks always run. Dynamic checks that exercise the actual `just`(1)
# command runner only run if `just` is installed (see README.md's "If `just`
# is installed" developer shortcuts section) - they are skipped, not failed,
# otherwise.
#
# Usage: bash test/justfile_test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
justfile="$repo_root/justfile"

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
bad() { fail=$((fail + 1)); echo "not ok - $1"; }

# --- Static checks: parse the justfile text, no `just` binary required ------

if grep -qE '^check:' "$justfile"; then
    ok "defines a 'check' recipe"
else
    bad "defines a 'check' recipe"
fi

if grep -qE '^commit-check:' "$justfile"; then
    bad "'commit-check' recipe should have been renamed to 'check'"
else
    ok "'commit-check' recipe no longer exists"
fi

if grep -qE '^alias cc := check$' "$justfile"; then
    ok "'cc' aliases 'check'"
else
    bad "'cc' aliases 'check'"
fi

if grep -qE '^alias cc := commit-check$' "$justfile"; then
    bad "'cc' should no longer alias 'commit-check'"
else
    ok "'cc' no longer aliases 'commit-check'"
fi

if grep -qE '^alias create-dmg := dmg$' "$justfile"; then
    bad "'create-dmg' alias for 'dmg' should have been removed"
else
    ok "'create-dmg' alias for 'dmg' no longer exists"
fi

if grep -qE '^dmg:' "$justfile"; then
    ok "'dmg' recipe is untouched by the rename"
else
    bad "'dmg' recipe is untouched by the rename"
fi

# The renamed recipe's body (the actual build/test steps) must be unchanged.
expected_check_body='    cd App && swift package clean
    rm -rf sidecar/dist
    cd App && swift build
    cd App && swift test
    cd sidecar && npm ci --include=dev
    cd sidecar && npm run build
    cd sidecar && npm test
    git diff --check'
actual_check_body="$(awk '/^check:/{flag=1; next} /^[a-zA-Z_-]+:/{flag=0} flag' "$justfile")"
if [ "$actual_check_body" = "$expected_check_body" ]; then
    ok "'check' recipe body matches the former 'commit-check' body"
else
    bad "'check' recipe body matches the former 'commit-check' body"
fi

# --- Dynamic checks: require the `just` binary on PATH ----------------------

if command -v just >/dev/null 2>&1; then
    list_output="$(cd "$repo_root" && just --list)"

    if echo "$list_output" | grep -qE '(^|[[:space:]])check([[:space:]]|$)'; then
        ok "'just --list' shows 'check'"
    else
        bad "'just --list' shows 'check'"
    fi

    if echo "$list_output" | grep -q 'commit-check'; then
        bad "'just --list' should not show 'commit-check'"
    else
        ok "'just --list' does not show 'commit-check'"
    fi

    if echo "$list_output" | grep -q 'create-dmg'; then
        bad "'just --list' should not show 'create-dmg'"
    else
        ok "'just --list' does not show 'create-dmg'"
    fi

    cc_show_tmp="$(mktemp)"
    check_show_tmp="$(mktemp)"
    trap 'rm -f "$cc_show_tmp" "$check_show_tmp"' EXIT

    if (cd "$repo_root" && just --show cc) >"$cc_show_tmp" 2>&1 \
        && (cd "$repo_root" && just --show check) >"$check_show_tmp" 2>&1; then
        if diff -q "$cc_show_tmp" "$check_show_tmp" >/dev/null; then
            ok "'cc' resolves to the same recipe body as 'check'"
        else
            bad "'cc' resolves to the same recipe body as 'check'"
        fi
    else
        bad "'just --show cc' and 'just --show check' both succeed"
    fi

    if (cd "$repo_root" && just --show create-dmg) >/dev/null 2>&1; then
        bad "'just --show create-dmg' should fail now the alias is removed"
    else
        ok "'just --show create-dmg' fails now the alias is removed"
    fi

    if (cd "$repo_root" && just --show commit-check) >/dev/null 2>&1; then
        bad "'just --show commit-check' should fail now the recipe is renamed"
    else
        ok "'just --show commit-check' fails now the recipe is renamed"
    fi
else
    echo "skip - 'just' binary not found on PATH; skipping dynamic just(1) checks"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]