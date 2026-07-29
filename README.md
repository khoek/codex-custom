# codex-custom

This repository pins the upstream [OpenAI Codex](https://github.com/openai/codex)
repository as a submodule and carries one small local patch:
[`patches/codex-customizations.patch`](patches/codex-customizations.patch).

The patch adds the downstream `+k` version marker and suppresses both
safety-buffering selection boxes:

- `Retry with a faster model` / `Dismiss and keep waiting` / `Learn more`
- `Dismiss and keep waiting` / `Learn more`

It does this at the TUI boundary, immediately after Codex creates the selection
view, by dismissing that view exactly as the no-op `Dismiss and keep waiting`
choice would. It deliberately does **not** disable or bypass server-side safety
buffering, change models, cancel the turn, or hide the ordinary working status.
Codex continues waiting for the original response.

`+k` is SemVer build metadata. It visibly identifies the custom build without
making it sort below the corresponding official release, as a `-k` prerelease
suffix would.

## Current pin

The `codex` submodule is pinned to the official `rust-v0.146.0` release at
commit `e363b08c9175ac1cbe5893615dd2cb9ddf95043b`.

## Install

On Ubuntu or Debian, install the native build prerequisites once:

```sh
sudo apt install libssl-dev pkg-config
```

Then build and activate the custom Codex:

```sh
./install.sh
```

The installer:

1. requires the pinned submodule to be clean;
2. creates a disposable Git worktree and applies the patch there, keeping the
   pinned submodule clean even when Cargo refreshes a release lockfile;
3. uses Codex's canonical package builder to include `codex-code-mode-host`,
   `rg`, `zsh`, and `bwrap`;
4. strips release debug information from the two locally built binaries;
5. restores the submodule to its clean pinned state, including after failures;
6. installs a timestamped package under
   `~/.local/lib/codex-custom/releases/`; and
7. atomically points `~/.local/bin/codex` at the new package.

It uses the existing `~/.codex` directory, so authentication, configuration,
sessions, skills, and plugins remain in place. The official standalone package
is not modified.

The custom build identifies itself as `codex-cli 0.146.0+k`. The exact source
commit and patch digest are also recorded in the installed release directory
name. Running `codex update` from this custom package does not replace it:
Codex cannot detect a supported update method and asks for a manual update.
Update this installation by bumping the pin as described below and running
`./install.sh` again.

Set `CODEX_CUSTOM_INSTALL_ROOT` to override the package location. The default is
`~/.local/lib/codex-custom`.

## Manual build

Initialize a checkout and apply the customization:

```sh
git submodule update --init --recursive
git -C codex apply --check ../patches/codex-customizations.patch
git -C codex apply ../patches/codex-customizations.patch
```

Build directly from the upstream Cargo workspace:

```sh
cd codex/codex-rs
cargo build --release --bin codex --bin codex-code-mode-host
```

To return the submodule to its pinned clean state:

```sh
git -C codex apply --reverse ../patches/codex-customizations.patch
```

## Bumping Codex

Keep the committed submodule checkout clean; apply the patch only for building
and testing.

1. Reverse the patch if it is applied, then verify `git -C codex status --short`
   is empty.
2. Choose an official `rust-v...` tag from
   [OpenAI Codex releases](https://github.com/openai/codex/releases). Prefer the
   latest stable release; use the newest prerelease tag only when intentionally
   opting into an alpha.
3. Run `git -C codex fetch origin tag <tag> --no-tags` and
   `git -C codex checkout --detach <tag>`.
4. Run the `git apply --check` command above. If it fails, reproduce the same
   one-view dismissal in
   `codex-rs/tui/src/chatwidget/safety_buffering.rs`, update its focused tests
   and snapshots, and regenerate the patch from the submodule's clean diff.
5. Apply the patch, run `just fmt` from `codex/codex-rs`, then run the focused
   safety-buffering tests with the repository's required `RUST_MIN_STACK`
   setting (and preferably run the complete `codex-tui` suite).
6. Reverse the patch again, verify the submodule is clean, update the release
   tag and commit in this README, and commit the new
   submodule pointer together with the refreshed patch and this README's pin.
