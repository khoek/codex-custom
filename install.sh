#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
codex_dir="$repo_dir/codex"
code_patch_file="$repo_dir/patches/codex-customizations.patch"
test_patch_file="$repo_dir/patches/codex-customizations-tests.patch"
quota_patch_file="$repo_dir/patches/exit-on-quota-exceeded.patch"
start_patch_file="$repo_dir/patches/start-immediately.patch"
handoff_patch_file="$repo_dir/patches/quota-handoff.patch"
auth_patch_file="$repo_dir/patches/auth-file.patch"
install_root="${CODEX_CUSTOM_INSTALL_ROOT:-$HOME/.local/lib/codex-custom}"
launcher_dir="$HOME/.local/bin"
launcher="$launcher_dir/codex"
stage_dir=
build_tree=
current_link=
launcher_link=
patch_bundle=

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

sha256_files() {
    if command -v sha256sum >/dev/null 2>&1; then
        cat "$@" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        cat "$@" | shasum -a 256 | awk '{print $1}'
    else
        die "missing required command: sha256sum or shasum"
    fi
}

current_install_matches() {
    current_target=$(readlink "$install_root/current" 2>/dev/null) || return 1
    case "$current_target" in
        releases/*-"$commit_short"-"$patch_digest_short") ;;
        *) return 1 ;;
    esac

    [ -x "$install_root/current/bin/codex" ] &&
        [ -x "$install_root/current/bin/codex-code-mode-host" ] &&
        [ -x "$install_root/current/codex-path/rg" ] &&
        [ -L "$launcher" ] &&
        [ "$(readlink "$launcher")" = "$install_root/current/bin/codex" ] &&
        "$launcher" --version >/dev/null 2>&1
}

replace_path_with_symlink() {
    link_path=$1
    link_target=$2
    temporary_link=$3

    rm -f -- "$temporary_link"
    ln -s "$link_target" "$temporary_link"

    if mv -Tf "$temporary_link" "$link_path" 2>/dev/null; then
        return
    fi

    if mv -hf "$temporary_link" "$link_path" 2>/dev/null; then
        return
    fi

    rm -f -- "$link_path"
    mv -f -- "$temporary_link" "$link_path"
}

ensure_codex_on_bash_path() {
    bashrc="$HOME/.bashrc"

    if [ -f "$bashrc" ]; then
        while IFS= read -r bashrc_line || [ -n "$bashrc_line" ]; do
            if [ "$bashrc_line" = '# >>> Codex installer >>>' ]; then
                return
            fi
        done <"$bashrc"
    fi

    if [ -s "$bashrc" ]; then
        printf '\n' >>"$bashrc"
    fi
    printf '%s\n' \
        '# >>> Codex installer >>>' \
        'export PATH="$HOME/.local/bin:$PATH"' \
        '# <<< Codex installer <<<' >>"$bashrc"
}

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM

    if [ -n "$build_tree" ]; then
        case "$build_tree" in
            "$install_root"/.stage.*/source)
                if ! git -C "$codex_dir" worktree remove --force "$build_tree"; then
                    printf 'error: could not remove temporary codex worktree: %s\n' "$build_tree" >&2
                    exit_status=1
                fi
                ;;
            *)
                printf 'warning: refusing to remove unexpected build worktree: %s\n' "$build_tree" >&2
                exit_status=1
                ;;
        esac
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

    if [ -n "$build_tree" ]; then
        if ! git -C "$codex_dir" worktree prune; then
            printf 'warning: could not prune temporary worktree metadata\n' >&2
            exit_status=1
        fi
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

    if [ -n "$patch_bundle" ]; then
        rm -f -- "$patch_bundle"
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in awk cat cut git readlink; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing required command: $command_name"
done

[ -f "$codex_dir/codex-rs/Cargo.toml" ] ||
    die "codex submodule is not initialized; run: git -C \"$repo_dir\" submodule update --init --recursive"
[ -f "$code_patch_file" ] || die "missing patch: $code_patch_file"
[ -f "$test_patch_file" ] || die "missing patch: $test_patch_file"
[ -f "$quota_patch_file" ] || die "missing patch: $quota_patch_file"
[ -f "$start_patch_file" ] || die "missing patch: $start_patch_file"
[ -f "$handoff_patch_file" ] || die "missing patch: $handoff_patch_file"
[ -f "$auth_patch_file" ] || die "missing patch: $auth_patch_file"

if [ -n "$(git -C "$codex_dir" status --porcelain)" ]; then
    die "codex submodule has local changes; restore it to the pinned clean state before installing"
fi

commit=$(git -C "$codex_dir" rev-parse HEAD)
patch_digest=$(sha256_files \
    "$code_patch_file" \
    "$test_patch_file" \
    "$quota_patch_file" \
    "$start_patch_file" \
    "$handoff_patch_file" \
    "$auth_patch_file")
commit_short=$(printf '%s' "$commit" | cut -c1-12)
patch_digest_short=$(printf '%s' "$patch_digest" | cut -c1-12)
commit_display=$(printf '%s' "$commit" | cut -c1-8)
patch_digest_display=$(printf '%s' "$patch_digest" | cut -c1-8)

if current_install_matches; then
    printf 'codex %s with customization %s is already installed; skipping.\n' \
        "$commit_display" "$patch_digest_display"
    ensure_codex_on_bash_path
    exit 0
fi

for command_name in cargo chmod date install ln mktemp mv python3 strip uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing required command: $command_name"
done

patch_bundle=$(mktemp "${TMPDIR:-/tmp}/codex-custom-patch-series.XXXXXX")
cat \
    "$code_patch_file" \
    "$test_patch_file" \
    "$quota_patch_file" \
    "$start_patch_file" \
    "$handoff_patch_file" \
    "$auth_patch_file" >"$patch_bundle"
git -C "$codex_dir" apply --check "$patch_bundle" ||
    die "the customization patch series no longer applies to the pinned codex revision"

host_platform="$(uname -s):$(uname -m)"
case "$host_platform" in
    Linux:x86_64)
        target=x86_64-unknown-linux-gnu
        strip_style=linux
        ;;
    Linux:aarch64 | Linux:arm64)
        target=aarch64-unknown-linux-gnu
        strip_style=linux
        ;;
    Darwin:x86_64)
        target=x86_64-apple-darwin
        strip_style=darwin
        ;;
    Darwin:arm64 | Darwin:aarch64)
        target=aarch64-apple-darwin
        strip_style=darwin
        ;;
    *)
        die "unsupported native build platform: $host_platform"
        ;;
esac

if [ -n "${OPENSSL_DIR:-}" ]; then
    [ -f "$OPENSSL_DIR/include/openssl/ssl.h" ] ||
        die "OPENSSL_DIR does not contain include/openssl/ssl.h: $OPENSSL_DIR"
elif [ "$strip_style" = linux ] &&
    { ! command -v pkg-config >/dev/null 2>&1 ||
        ! pkg-config --exists openssl; }; then
    die "OpenSSL development files are missing; on Ubuntu/Debian run: sudo apt install libssl-dev pkg-config"
fi

if [ "$strip_style" = linux ] && command -v bwrap >/dev/null 2>&1; then
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
build_tree="$stage_dir/source"
package_dir="$stage_dir/package"

git -C "$codex_dir" worktree add --detach "$build_tree" HEAD
git -C "$build_tree" apply "$patch_bundle"
rm -f -- "$patch_bundle"
patch_bundle=

build_stamp=$(date -u +%Y%m%dT%H%M%SZ)
release_name="$build_stamp-$commit_short-$patch_digest_short"
release_dir="$install_root/releases/$release_name"

printf 'Building codex %s with customization %s...\n' "$commit_display" "$patch_digest_display"
CARGO_TARGET_DIR="$codex_dir/codex-rs/target" \
python3 "$build_tree/scripts/build_codex_package.py" \
    --target "$target" \
    --variant codex \
    --cargo-profile release \
    --package-dir "$package_dir" \
    "$@"

case "$strip_style" in
    darwin)
        strip -S -x \
            "$package_dir/bin/codex" \
            "$package_dir/bin/codex-code-mode-host"
        ;;
    linux)
        strip --strip-unneeded \
            "$package_dir/bin/codex" \
            "$package_dir/bin/codex-code-mode-host"
        ;;
esac
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
replace_path_with_symlink \
    "$install_root/current" \
    "releases/$release_name" \
    "$current_link"

launcher_link="$launcher_dir/.codex-custom.$$"
replace_path_with_symlink \
    "$launcher" \
    "$install_root/current/bin/codex" \
    "$launcher_link"

printf '\nInstalled custom codex:\n'
printf '  package: %s\n' "$release_dir"
printf '  launcher: %s -> %s\n' "$launcher" "$install_root/current/bin/codex"
"$launcher" --version
ensure_codex_on_bash_path
printf '\nRun `hash -r` in shells that cached the old command path.\n'
