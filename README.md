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
4. [`patches/start-immediately.patch`](patches/start-immediately.patch) adds the
   race-free `codex resume SESSION_ID --start-immediately` continuation mode.
5. [`patches/quota-handoff.patch`](patches/quota-handoff.patch) durably carries
   queued TUI input and the composer draft across a quota-triggered restart.
6. [`patches/auth-file.patch`](patches/auth-file.patch) adds the `+k`-only
   hidden `--auth-file PATH` option used by Kai to select a canonical enrolled
   account file without moving the rest of Codex state.
7. [`patches/canonical-auth-refresh.patch`](patches/canonical-auth-refresh.patch)
   serializes reload, refresh, and persistence across processes that share that
   canonical file.
8. [`patches/cybersecurity-abort-bell.patch`](patches/cybersecurity-abort-bell.patch)
   rings the terminal bell when a turn is aborted by the cybersecurity policy.
9. [`patches/resume-history-projection.patch`](patches/resume-history-projection.patch)
   preserves paginated history across repeated resumes and repairs projections
   already blocked by the affected ordinal replay.

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

For typed `ServerOverloaded` model-capacity errors, it keeps retrying sampling
and remote-compaction requests with exponential delays from 2 seconds up to 60
seconds. The retry remains interruptible and is separate from quota and
usage-limit errors.

The companion test patch has no runtime effect. It keeps the original
customizations' tests separate from their implementation and records the
expected auto-dismissed UI and `0.152.0+k` snapshot output.

The quota patch adds `--exit-on-quota-exceeded` to interactive Codex. With the
flag present, a terminal typed `UsageLimitExceeded` error from either the main
thread or any tracked subagent follows the normal notification path and then
requests the same shutdown-first exit used by an ordinary interactive quit.
After the app server, threads, terminal, and telemetry have been cleaned up,
the CLI emits one final unstyled line, flushes it, and returns process status
`75` (`EX_TEMPFAIL`) through normal unwinding. The status is the authoritative
quota signal; the line carries recovery data. The quota-handoff patch makes it
point at a durable companion file:

```text
codex+k (CODEX_UUID_WHICH_YOU_CAN_USE_TO_RESUME): quota exceeded {"version":2,"handoff_path":"/…/rollout.jsonl.codex+k-…-handoff.json"}
```

Kai only interprets the marker after status `75`, and searches backward through
the captured PTY tail so terminal cleanup output after the marker cannot hide
the recovery request. A missing or malformed marker at that status is a hard
error. Marker-looking output accompanying any other status is ordinary output.

The sidecar is written atomically with mode `0600` beside the rollout (or in the
persistent sessions directory if that path cannot be resolved). It contains the
exact model/config recovery arguments, each rejected steer, pending steer, and
queued follow-up as a separate message, plus unsent composer text, attachments,
mention bindings, and pending paste contents. Kai validates the sidecar, rotates
credentials, and passes its path to the hidden
`codex resume ... --start-immediately --restore-input-handoff PATH` option. Codex
restores each saved message into the normal queue independently, starts the first
one, and puts the unfinished draft back in the composer. The sidecar is retained
after restore for at-least-once delivery if the restarted process exits again
before all queued input is delivered. Retryable errors, model-capacity errors,
and runs without the flag retain their existing behavior. The flag can be
supplied to a fresh interactive run or to `codex resume` and `codex fork`.

Kai also repairs absolute rollout paths left in `state_5.sqlite` by an older
supervised run. Those paths can point into a deleted `.agent-*` home; the repair
rewrites them to the existing persistent `CODEX_HOME` location before resuming.

The start-immediately patch reactivates a paused, blocked, or usage-limited goal,
then submits `You were interrupted, continue work`. If the resumed turn is still
running, Codex orders its interruption before the locally queued continuation;
even if the old turn completes concurrently, the interrupt cannot land on the
new turn.

`+k` is SemVer build metadata. It visibly identifies the custom build without
making it sort below the corresponding official release, as a `-k` prerelease
suffix would.

The auth-file patch is deliberately small: the hidden global `--auth-file PATH`
option selects the file used for file-backed CLI credential reads, refreshes,
and deletes (relative values are resolved under `CODEX_HOME`) instead of
`CODEX_HOME/auth.json`. The option is parsed once into process-local state, so
commands launched by Codex cannot inherit it. Sessions, SQLite, configuration,
plugins, and skills still use the ordinary `CODEX_HOME`. Kai supplies the
option to each supervised `+k` child and quota app-server, selecting the
enrolled account's canonical writable profile file.

The canonical-auth-refresh patch adds an advisory OS file lock beside that
resolved credential file. A `+k` refresh acquires it before reloading from disk
and keeps it through the token request and persistence. A second Codex process
therefore reloads the newly issued refresh token instead of replaying a stale
one. Active `CODEX_HOME/auth.json` links and explicit `--auth-file` paths resolve
to the same lock when they refer to the same canonical file.

The cybersecurity-abort-bell patch emits an unconditional terminal BEL when a
typed `CyberPolicy` rejection reaches the dedicated abort notice. It does not
depend on desktop-notification settings or whether the terminal is focused.

The resume-history projection patch fixes
[#35746](https://github.com/openai/codex/issues/35746). Reverse rollout scans use
Codex's canonical value-first decoder, so a structured `token_count` containing
a fractional rate-limit percentage cannot make resume reuse the preceding
ordinal. For histories written by the buggy path, projection catch-up skips the
single replayed `thread_settings_applied` boundary record and continues from the
next monotonic ordinal; other ordinal regressions remain errors.

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
patch_bundle=$(mktemp "${TMPDIR:-/tmp}/codex-custom-patch-series.XXXXXX")
cat \
    ../patches/codex-customizations.patch \
    ../patches/codex-customizations-tests.patch \
    ../patches/exit-on-quota-exceeded.patch \
    ../patches/start-immediately.patch \
    ../patches/quota-handoff.patch \
    ../patches/auth-file.patch \
    ../patches/canonical-auth-refresh.patch \
    ../patches/cybersecurity-abort-bell.patch \
    ../patches/resume-history-projection.patch >"$patch_bundle"
git -C codex apply --check "$patch_bundle"
git -C codex apply "$patch_bundle"
rm -f -- "$patch_bundle"
```

Build directly from the upstream Cargo workspace:

```sh
cd codex/codex-rs
cargo build --release --bin codex --bin codex-code-mode-host
```

To return the submodule to its pinned clean state:

```sh
git -C codex apply --reverse ../patches/resume-history-projection.patch
git -C codex apply --reverse ../patches/cybersecurity-abort-bell.patch
git -C codex apply --reverse ../patches/canonical-auth-refresh.patch
git -C codex apply --reverse ../patches/auth-file.patch
git -C codex apply --reverse ../patches/quota-handoff.patch
git -C codex apply --reverse ../patches/start-immediately.patch
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
5. Apply all nine patches and run `just fmt` from `codex/codex-rs`. Run every
   focused test plus the `codex-tui` and `codex-cli` crate suites. Auth-file
   selection is process-local, so upstream auth tests cannot inherit it from a
   supervising Codex process.
6. Reverse all nine patches in reverse order, verify the submodule is clean,
   update the release tag and commit in this README, and commit the new submodule
   pointer together with the refreshed patches and this README's pin.
