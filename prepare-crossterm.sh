#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=${1:?usage: prepare-crossterm.sh CODEX_SOURCE_DIRECTORY}
crossterm_dir="$source_dir/.cache/crossterm"
crossterm_revision=ed1cdab335221515706178d68495bba2aed1924f

if [ -e "$crossterm_dir" ]; then
    printf 'error: dependency directory already exists: %s\n' "$crossterm_dir" >&2
    exit 1
fi

git init -q "$crossterm_dir"
git -C "$crossterm_dir" fetch --depth=1 \
    https://github.com/openai-oss-forks/crossterm.git "$crossterm_revision"
git -C "$crossterm_dir" checkout -q --detach FETCH_HEAD
git -C "$crossterm_dir" apply --check \
    "$repo_dir/patches/crossterm-terminal-colors.patch" \
    "$repo_dir/patches/crossterm-terminal-colors-tests.patch"
git -C "$crossterm_dir" apply \
    "$repo_dir/patches/crossterm-terminal-colors.patch" \
    "$repo_dir/patches/crossterm-terminal-colors-tests.patch"
