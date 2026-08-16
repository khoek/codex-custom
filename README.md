# codex-custom

This repository pins the upstream [OpenAI Codex](https://github.com/openai/codex)
repository as a submodule and carries a small, ordered patch series:

1. [`patches/codex-customizations.patch`](patches/codex-customizations.patch)
   contains only the original UI, version-marker, and capacity-retry code
   changes.
2. [`patches/codex-customizations-tests.patch`](patches/codex-customizations-tests.patch)
   contains their corresponding test assertions and snapshots, including the
   downstream version-marker snapshots.
3. [`patches/exit-on-quota-exceeded.patch`](patches/exit-on-quota-exceeded.patch)
   adds the opt-in quota-exit behavior described below.

The original code patch adds the downstream `+k` version marker, retries typed
model capacity errors, and suppresses three selection boxes:

- `Retry with a faster model` / `Dismiss and keep waiting` / `Learn more`
- `Dismiss and keep waiting` / `Learn more`
- `Approaching rate limits` / switch to a lower-cost model

Upstream status: safety-buffering auto-dismiss remains open
([#32139](https://github.com/openai/codex/issues/32139),
[#32815](https://github.com/openai/codex/issues/32815)); the rate-limit nudge has
a persistent opt-out ([#6433](https://github.com/openai/codex/pull/6433)).

For the safety-buffering prompts, it acts at the TUI boundary immediately after
Codex creates the selection view, dismissing that view exactly as the no-op
`Dismiss and keep waiting` choice would. It deliberately does **not** disable or
bypass server-side safety buffering, change models, cancel the turn, or hide the
ordinary working status. Codex continues waiting for the original response.

For the rate-limit model-switch prompt, it immediately performs the existing
`Keep current model (never show again)` action: the current model is preserved,
the view is dismissed, and `notice.hide_rate_limit_model_nudge = true` is
persisted to `config.toml`. This does not change rate-limit accounting,
informational threshold warnings, or hard-stop behavior.

For typed `ServerOverloaded` model-capacity errors, it keeps retrying the
sampling request with exponential delays from 2 seconds up to 60 seconds. The
retry remains interruptible and is separate from quota and usage-limit errors.

The companion test patch has no runtime effect. It keeps the original
customizations' tests separate from their implementation and records the
expected auto-dismissed UI and `0.147.0+k` snapshot output.

The quota patch adds `--exit-on-quota-exceeded` to interactive Codex. With the
flag present, a terminal typed `UsageLimitExceeded` error from either the main
thread or any tracked subagent follows the normal notification path and then
requests the same shutdown-first exit used by an ordinary interactive quit.
After the app server, threads, terminal, and telemetry have been cleaned up,
the CLI emits one final unstyled line and no other normal exit summary:

```text
codex+k (CODEX_UUID_WHICH_YOU_CAN_USE_TO_RESUME): quota exceeded
```

The UUID is the primary session ID accepted by `codex resume`. Retryable errors,
model-capacity errors, and runs without the flag retain their existing behavior.
The flag can be supplied to a fresh interactive run or to `codex resume` and
`codex fork`.

`+k` is SemVer build metadata. It visibly identifies the custom build without
making it sort below the corresponding official release, as a `-k` prerelease
suffix would.

## Install

Native macOS builds require the Xcode Command Line Tools. Install them once if
they are not already present:

```sh
xcode-select --install
```

On Ubuntu or Debian, install the native build prerequisites once:

```sh
sudo apt install libssl-dev pkg-config
```

Then build and activate the custom Codex:

```sh
./install.sh
```

The installer supports native arm64 and x86_64 builds on macOS and Linux. It:

1. requires the pinned submodule to be clean;
2. creates a disposable Git worktree and applies the patches in order there,
   keeping the pinned submodule clean even when Cargo refreshes a release
   lockfile;
3. uses Codex's canonical package builder to include `codex-code-mode-host`,
   `rg`, `zsh`, and, on Linux, `bwrap`;
4. strips release debug information from the two locally built binaries;
5. restores the submodule to its clean pinned state, including after failures;
6. installs a timestamped package under
   `~/.local/lib/codex-custom/releases/`; and
7. atomically points `~/.local/bin/codex` at the new package.

Rerunning the installer skips the build when the active package already matches
both the pinned Codex commit and the ordered patch-series digest and its launcher
and bundled executables are intact.

It uses the existing `~/.codex` directory, so authentication, configuration,
sessions, skills, and plugins remain in place. The official standalone package
is not modified.

The custom build appends `+k` to the upstream `codex-cli` version. The exact
source commit and patch digest are also recorded in the installed release
directory name. Running `codex update` from this custom package does not replace
it: Codex cannot detect a supported update method and asks for a manual update.
Update this installation by bumping the pin as described below and running
`./install.sh` again.

Set `CODEX_CUSTOM_INSTALL_ROOT` to override the package location. The default is
`~/.local/lib/codex-custom`.

## Manual build

Initialize a checkout and apply the customization:

```sh
git submodule update --init --recursive
git -C codex apply --check \
    ../patches/codex-customizations.patch \
    ../patches/codex-customizations-tests.patch \
    ../patches/exit-on-quota-exceeded.patch
git -C codex apply \
    ../patches/codex-customizations.patch \
    ../patches/codex-customizations-tests.patch \
    ../patches/exit-on-quota-exceeded.patch
```

Build directly from the upstream Cargo workspace:

```sh
cd codex/codex-rs
cargo build --release --bin codex --bin codex-code-mode-host
```

To return the submodule to its pinned clean state:

```sh
git -C codex apply --reverse ../patches/exit-on-quota-exceeded.patch
git -C codex apply --reverse ../patches/codex-customizations-tests.patch
git -C codex apply --reverse ../patches/codex-customizations.patch
```

## Bumping Codex

Keep the committed submodule checkout clean; apply the patches only for building
and testing.

1. Reverse the patches in reverse order if they are applied, then verify
   `git -C codex status --short` is empty.
2. Choose an official `rust-v...` tag from
   [OpenAI Codex releases](https://github.com/openai/codex/releases). Prefer the
   latest stable release; use the newest prerelease tag only when intentionally
   opting into an alpha.
3. Run `git -C codex fetch origin tag <tag> --no-tags` and
   `git -C codex checkout --detach <tag>`.
4. Run the ordered `git apply --check` command above. If it fails, refresh only
   the affected patch, preserving the same order and separation of concerns.
5. Apply all three patches, run `just fmt` from `codex/codex-rs`, then run the
   focused tests and the `codex-tui` and `codex-cli` crate suites.
6. Reverse all three patches in reverse order, verify the submodule is clean,
   update the release tag and commit in this README, and commit the new submodule
   pointer together with the refreshed patches and this README's pin.
