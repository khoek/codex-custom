#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
codex_dir="$repo_dir/codex"
patch_file="$repo_dir/patches/auto-dismiss-safety-buffering-prompts.patch"
install_root="${CODEX_CUSTOM_INSTALL_ROOT:-$HOME/.local/lib/codex-custom}"
launcher_dir="$HOME/.local/bin"
launcher="$launcher_dir/codex"
patch_applied=0
stage_dir=
current_link=
launcher_link=

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM

    if [ "$patch_applied" -eq 1 ]; then
        if ! git -C "$codex_dir" apply --reverse "$patch_file"; then
            printf 'error: could not restore the clean Codex submodule; reverse this patch manually:\n' >&2
            printf '  git -C %s apply --reverse %s\n' "$codex_dir" "$patch_file" >&2
            exit_status=1
        fi
    fi

    if [ -n "$stage_dir" ]; then
        case "$stage_dir" in
            "$install_root"/.stage.*)
                rm -rf -- "$stage_dir"
                ;;
            *)
                printf 'warning: refusing to remove unexpected staging path: %s\n' "$stage_dir" >&2
                exit_status=1
                ;;
        esac
    fi

    if [ -n "$current_link" ]; then
        case "$current_link" in
            "$install_root"/.current.*)
                rm -f -- "$current_link"
                ;;
        esac
    fi

    if [ -n "$launcher_link" ]; then
        case "$launcher_link" in
            "$launcher_dir"/.codex-custom.*)
                rm -f -- "$launcher_link"
                ;;
        esac
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in awk cargo chmod cut date git install ln mktemp mv python3 sha256sum strip uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing required command: $command_name"
done

[ -f "$codex_dir/codex-rs/Cargo.toml" ] ||
    die "Codex submodule is not initialized; run: git -C \"$repo_dir\" submodule update --init --recursive"
[ -f "$patch_file" ] || die "missing patch: $patch_file"

if [ -n "$(git -C "$codex_dir" status --porcelain)" ]; then
    die "Codex submodule has local changes; restore it to the pinned clean state before installing"
fi

git -C "$codex_dir" apply --check "$patch_file" ||
    die "the customization patch no longer applies to the pinned Codex revision"

if [ -n "${OPENSSL_DIR:-}" ]; then
    [ -f "$OPENSSL_DIR/include/openssl/ssl.h" ] ||
        die "OPENSSL_DIR does not contain include/openssl/ssl.h: $OPENSSL_DIR"
elif ! command -v pkg-config >/dev/null 2>&1 ||
    ! pkg-config --exists openssl; then
    die "OpenSSL development files are missing; on Ubuntu/Debian run: sudo apt install libssl-dev pkg-config"
fi

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        target=x86_64-unknown-linux-gnu
        ;;
    Linux:aarch64 | Linux:arm64)
        target=aarch64-unknown-linux-gnu
        ;;
    *)
        die "this installer currently supports native x86_64 or arm64 Linux builds"
        ;;
esac

if command -v bwrap >/dev/null 2>&1; then
    bwrap_path=$(command -v bwrap)
    set -- --bwrap-bin "$bwrap_path"
else
    set --
fi

if [ -e "$launcher" ] && [ ! -L "$launcher" ]; then
    die "refusing to replace non-symlink launcher: $launcher"
fi

install -d "$install_root/releases" "$launcher_dir"
stage_dir=$(mktemp -d "$install_root/.stage.XXXXXX")
package_dir="$stage_dir/package"

git -C "$codex_dir" apply "$patch_file"
patch_applied=1

commit=$(git -C "$codex_dir" rev-parse HEAD)
patch_digest=$(sha256sum "$patch_file" | awk '{print $1}')
build_stamp=$(date -u +%Y%m%dT%H%M%SZ)
release_name="$build_stamp-$(printf '%s' "$commit" | cut -c1-12)-$(printf '%s' "$patch_digest" | cut -c1-12)"
release_dir="$install_root/releases/$release_name"

printf 'Building Codex %s with customization %s...\n' "$commit" "$patch_digest"
python3 "$codex_dir/scripts/build_codex_package.py" \
    --target "$target" \
    --variant codex \
    --cargo-profile release \
    --package-dir "$package_dir" \
    "$@"

strip --strip-unneeded \
    "$package_dir/bin/codex" \
    "$package_dir/bin/codex-code-mode-host"
chmod 0755 \
    "$package_dir/bin/codex" \
    "$package_dir/bin/codex-code-mode-host" \
    "$package_dir/codex-path/rg"
if [ -f "$package_dir/codex-resources/bwrap" ]; then
    chmod 0755 "$package_dir/codex-resources/bwrap"
fi
if [ -f "$package_dir/codex-resources/zsh/bin/zsh" ]; then
    chmod 0755 "$package_dir/codex-resources/zsh/bin/zsh"
fi

[ -x "$package_dir/bin/codex" ] || die "package builder did not produce bin/codex"
[ -x "$package_dir/bin/codex-code-mode-host" ] ||
    die "package builder did not produce bin/codex-code-mode-host"
[ -x "$package_dir/codex-path/rg" ] ||
    die "package builder did not produce codex-path/rg"

mv "$package_dir" "$release_dir"

current_link="$install_root/.current.$$"
ln -s "releases/$release_name" "$current_link"
mv -Tf "$current_link" "$install_root/current"

launcher_link="$launcher_dir/.codex-custom.$$"
ln -s "$install_root/current/bin/codex" "$launcher_link"
mv -Tf "$launcher_link" "$launcher"

printf '\nInstalled custom Codex:\n'
printf '  package: %s\n' "$release_dir"
printf '  launcher: %s -> %s\n' "$launcher" "$install_root/current/bin/codex"
"$launcher" --version
printf '\nRun `hash -r` in shells that cached the old command path.\n'
