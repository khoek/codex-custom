# codex-custom

This repository pins the upstream [OpenAI Codex](https://github.com/openai/codex)
repository as a submodule at commit `ac192cd7937b0d73edc6dffe009940ae53782dd4`
from upstream `main`. The custom version is `0.154.0-k.ac192cd7`. It carries a
small, ordered patch series:

1. [`patches/codex-customizations.patch`](patches/codex-customizations.patch)
   contains only the original UI, release version, and capacity-retry code
   changes.
2. [`patches/codex-customizations-tests.patch`](patches/codex-customizations-tests.patch)
   contains their corresponding test assertions and snapshots, including the
   custom version snapshots.
3. [`patches/exit-on-quota-exceeded.patch`](patches/exit-on-quota-exceeded.patch)
   adds the opt-in quota-exit behavior described below.
4. [`patches/start-immediately.patch`](patches/start-immediately.patch) adds the
   race-free `codex resume SESSION_ID --start-immediately` continuation mode.
5. [`patches/quota-handoff.patch`](patches/quota-handoff.patch) durably carries
   queued TUI input and the composer draft across a quota-triggered restart.
6. [`patches/auth-file.patch`](patches/auth-file.patch) adds the custom-build
   hidden credential-slot arguments. They select one auth file and join the
   generic broker lock protocol without moving the rest of Codex state.
7. [`patches/canonical-auth-refresh.patch`](patches/canonical-auth-refresh.patch)
   serializes reload, refresh, and persistence across processes that share a
   broker mutation lock.
8. [`patches/cybersecurity-abort-bell.patch`](patches/cybersecurity-abort-bell.patch)
   rings the terminal bell when a turn is aborted by the cybersecurity policy.

The original code patch sets the custom release version, retries typed
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
expected auto-dismissed UI and `0.154.0-k.ac192cd7` snapshot output.

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
codex+k (CODEX_UUID_WHICH_YOU_CAN_USE_TO_RESUME): supervised exit {"version":3,"outcome":"quota-exhausted","unavailable_until":1789000000,"handoff_path":"/…/rollout.jsonl.codex+k-…-handoff.json"}
```

Managed credential refresh failures also use this marker, with
`"outcome":"credential-invalid"` and `"unavailable_until":null`. Only terminal
expired, reused, revoked, or invalid-grant responses qualify. Quota reset times
come from the authority's exhausted usage windows; unavailable times are null.

An external supervisor should interpret the marker only after status `75` and
search backward through its captured PTY tail so terminal cleanup output after
the marker cannot hide the recovery request. A missing or malformed marker at
that status is a hard error. Marker-looking output accompanying any other status
is ordinary output.

The sidecar is written atomically with mode `0600` beside the rollout (or in the
persistent sessions directory if that path cannot be resolved). It contains the
exact model/config recovery arguments, each rejected steer, pending steer, and
queued follow-up as a separate message, plus unsent composer text, attachments,
mention bindings, and pending paste contents. A supervisor validates the
sidecar, performs any out-of-process recovery required by its own policy, and
passes the path to the hidden
`codex resume ... --start-immediately --restore-input-handoff PATH` option. Codex
restores each saved message into the normal queue independently, starts the first
one, and puts the unfinished draft back in the composer. The sidecar is retained
after restore for at-least-once delivery if the restarted process exits again
before all queued input is delivered. Retryable errors, model-capacity errors,
and runs without the flag retain their existing behavior. The flag can be
supplied to a fresh interactive run or to `codex resume` and `codex fork`.

The start-immediately patch reactivates a paused, blocked, or usage-limited goal,
then submits `You were interrupted, continue work`. If the resumed turn is still
running, Codex orders its interruption before the locally queued continuation;
even if the old turn completes concurrently, the interrupt cannot land on the
new turn.

Versions use `<major>.<next-stable-minor>.0-k.<commit-first8>`. Take the latest
stable upstream release, increment its minor version, and reset the patch version
to zero. Append `-k.` and the first eight characters of the pinned upstream commit.
For example, stable `0.153.4` and commit `ac192cd7937b…` produce
`0.154.0-k.ac192cd7`. Builds use that exact commit; installation never fetches
a moving upstream branch.

The auth-file patch exposes one complete, generic managed-credential protocol:
`--auth-file PATH`, `--credential-protocol-version 2`,
`--credential-use-lock PATH`, `--credential-use-lock-mode shared|exclusive`,
`--credential-mutation-lock PATH`,
`--credential-startup-socket PATH`, and `--credential-startup-nonce HEX`.
These hidden global arguments are process-local and cannot leak into commands
launched by Codex. Supplying any one requires the complete set, and unsupported
protocol versions are rejected. Managed credentials always use file storage,
including when configuration selects keyring storage. The auth file is used for
reads, writes, refreshes, and deletes; relative auth paths are
resolved under `CODEX_HOME`. Sessions, SQLite, configuration, plugins, and
skills continue to use the ordinary `CODEX_HOME`.

The two lock files are created and managed by the credential provider, not
Codex. Codex opens them without `create` and requires private, single-link,
caller-owned regular files. It connects to the private startup socket, sends
`READY <nonce>`, and receives `GO <nonce>` with the caller's already locked use
descriptor via `SCM_RIGHTS`. Shared and exclusive modes both transfer without
an unlock/relock gap. No credential is accessed before the descriptor arrives.
Codex retains its descriptor until process exit, including app-server runs;
normal exit, forced termination, and crashes therefore unlock through ordinary
OS cleanup. Every credential write or delete acquires the mutation file
exclusively. A provider can safely replace or reclaim a slot by acquiring the
use file exclusively and then the mutation file exclusively. All participants
use that lock order. Managed auth writes atomically replace and durably flush
the shared file, so concurrent consumers never read a partial token update.

The canonical-auth-refresh patch keeps the mutation lock across the complete
reload, authority request, and persistence transaction. A second process then
reloads the newly issued refresh token instead of replaying a stale one. Codex
does not create an adjacent `.refresh.lock`; the explicit broker mutation lock
is the sole managed-credential refresh lock. Invocations without any downstream
credential arguments retain the ordinary Codex auth path and behavior.
OAuth refresh failures retain response bodies only long enough to classify them internally; logs
and returned transient errors expose only the HTTP status and a closed, nonsecret failure class.
No backend body, error code, or free-form message is emitted.

The cybersecurity-abort-bell patch emits an unconditional terminal BEL when a
typed `CyberPolicy` rejection reaches the dedicated abort notice. It does not
depend on desktop-notification settings or whether the terminal is focused.

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

The custom version is stamped into the patched Cargo workspace and package.
The exact source commit and patch digest are also recorded in the installed
release directory name. Running `codex update` from this custom package does not
replace it: Codex cannot detect a supported update method and asks for a manual update.
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
    patches/codex-customizations.patch \
    patches/codex-customizations-tests.patch \
    patches/exit-on-quota-exceeded.patch \
    patches/start-immediately.patch \
    patches/quota-handoff.patch \
    patches/auth-file.patch \
    patches/canonical-auth-refresh.patch \
    patches/cybersecurity-abort-bell.patch >"$patch_bundle"
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
git -C codex apply --reverse ../patches/cybersecurity-abort-bell.patch
git -C codex apply --reverse ../patches/canonical-auth-refresh.patch
git -C codex apply --reverse ../patches/auth-file.patch
git -C codex apply --reverse ../patches/quota-handoff.patch
git -C codex apply --reverse ../patches/start-immediately.patch
git -C codex apply --reverse ../patches/exit-on-quota-exceeded.patch
git -C codex apply --reverse ../patches/codex-customizations-tests.patch
git -C codex apply --reverse ../patches/codex-customizations.patch
# Restore Cargo-generated local-package version metadata.
git -C codex restore -- codex-rs/Cargo.lock
```

## Bumping Codex

Keep the committed submodule checkout clean; apply the patches only for building
and testing.

1. Reverse the patches in reverse order if they are applied, then verify
   `git -C codex status --short` is empty.
2. Fetch upstream `main` with `git -C codex fetch origin main --no-tags`, then pin
   it with `git -C codex checkout --detach FETCH_HEAD`. Record the full commit in
   this README.
3. Determine the latest stable upstream release and derive the custom version
   using the convention above. Update the workspace version in
   `codex-customizations.patch` and the existing version snapshots in
   `codex-customizations-tests.patch`. Cargo updates local-package lockfile
   versions in the disposable build worktree.
4. Run the ordered `git apply --check` command above. Refresh affected patches
   while preserving their order and boundaries. Remove patches whose fixes are
   now implemented upstream, together with their installer and documentation
   references.
5. Apply the remaining patches and run `just fmt` from `codex/codex-rs`. Run every
   focused test plus the `codex-tui` and `codex-cli` crate suites. Auth-file
   selection is process-local, so upstream auth tests cannot inherit it from a
   supervising Codex process. Unset `CODEX_SQLITE_HOME` and `NO_COLOR` for test
   commands so database paths stay within the test homes and color assertions
   use their expected terminal output. Set `BROWSER=/bin/true` to prevent local
   OAuth fixtures from opening the desktop browser. Run tests with `umask 077` so temporary
   IDE socket directories satisfy the permission checks.
6. Reverse the patches in reverse order and verify the submodule is clean.
   Commit the migrated patches and updated submodule pin, then record the final
   version bump in a separate commit. Push both and update the parent repository's
   submodule pointer.
