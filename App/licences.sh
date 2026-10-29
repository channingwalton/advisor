#!/bin/sh
# Make every package in the bundled sidecar's node_modules carry its licence
# text (package.sh runs this after the prune). Copies the texts that
# sidecar/licences/<package>/ supplies, for packages that ship without one,
# into those packages, then fails, naming them, if any package still has no
# licence file.
#
# Usage: licences.sh <node_modules> <supplements>
set -e
modules=$1
supplements=$2

# True if the folder holds a licence file: LICENSE, LICENCE, COPYING or
# UNLICENSE, in any case, with or without a suffix.
has_licence() {
    for file in "$1"/*; do
        case $(basename "$file" | tr '[:upper:]' '[:lower:]') in
            licen[cs]e* | copying* | unlicense*) return 0 ;;
        esac
    done
    return 1
}

# Copy each supplied file the package lacks; never overwrite one it ships. A
# text for a program the package bundles is named <program>.LICENSE, so that
# has_licence does not take it for the package's own. A supply that is no
# longer needed is reported, not fatal: it changes no text that ships.
for dir in "$supplements"/*/ "$supplements"/@*/*/; do
    [ -d "$dir" ] || continue
    name=${dir#"$supplements"/}
    name=${name%/}
    case $name in @*/*) ;; @*) continue ;; esac
    target=$modules/$name
    if [ ! -f "$target/package.json" ]; then
        echo "warning: $name is not bundled; remove its supplied licences ($dir)" >&2
        continue
    fi
    if has_licence "$target" && has_licence "$dir"; then
        echo "warning: $name ships its own licence; remove the one supplied for it ($dir)" >&2
    fi
    # File by file, so a supplied folder merges into one the package has.
    (cd "$dir" && find . -type f) | while read -r file; do
        [ -e "$target/$file" ] && continue
        mkdir -p "$(dirname "$target/$file")"
        cp "$dir$file" "$target/$file"
    done
done

missing=0
# Every package in a node_modules folder, scoped and nested ones too.
check() {
    for pkg in "$1"/*/ "$1"/@*/*/; do
        pkg=${pkg%/}
        [ -f "$pkg/package.json" ] || continue
        if ! has_licence "$pkg"; then
            echo "error: no licence file in ${pkg#"$modules"/}" >&2
            missing=1
        fi
        if [ -d "$pkg/node_modules" ]; then
            check "$pkg/node_modules"
        fi
    done
}
check "$modules"
if [ "$missing" -ne 0 ]; then
    echo "Add each missing text under sidecar/licences/<package>/ (see its README.md)." >&2
    exit 1
fi
