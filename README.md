# codex-custom

This repository pins the upstream [OpenAI Codex](https://github.com/openai/codex)
repository as a submodule and carries one small local patch:
[`patches/auto-dismiss-safety-buffering-prompts.patch`](patches/auto-dismiss-safety-buffering-prompts.patch).

The patch suppresses both safety-buffering selection boxes:

- `Retry with a faster model` / `Dismiss and keep waiting` / `Learn more`
- `Dismiss and keep waiting` / `Learn more`

It does this at the TUI boundary, immediately after Codex creates the selection
view, by dismissing that view exactly as the no-op `Dismiss and keep waiting`
choice would. It deliberately does **not** disable or bypass server-side safety
buffering, change models, cancel the turn, or hide the ordinary working status.
Codex continues waiting for the original response.

## Current pin

The `codex` submodule is pinned to upstream commit
`fe01054a28fa4bd04716d9ceadb410f2443a50ce` from `main`.

Initialize a checkout and apply the customization:

```sh
git submodule update --init --recursive
git -C codex apply --check ../patches/auto-dismiss-safety-buffering-prompts.patch
git -C codex apply ../patches/auto-dismiss-safety-buffering-prompts.patch
```

Build from the upstream Cargo workspace:

```sh
cd codex/codex-rs
cargo build
```

To return the submodule to its pinned clean state:

```sh
git -C codex apply --reverse ../patches/auto-dismiss-safety-buffering-prompts.patch
```

## Bumping Codex

Keep the committed submodule checkout clean; apply the patch only for building
and testing.

1. Reverse the patch if it is applied, then verify `git -C codex status --short`
   is empty.
2. Run `git -C codex fetch origin main` and
   `git -C codex checkout <new-upstream-commit>`.
3. Run the `git apply --check` command above. If it fails, reproduce the same
   one-view dismissal in
   `codex-rs/tui/src/chatwidget/safety_buffering.rs`, update its focused tests
   and snapshots, and regenerate the patch from the submodule's clean diff.
4. Apply the patch, run `just fmt` from `codex/codex-rs`, then run
   `just test -p codex-tui safety_buffering` (and preferably
   `just test -p codex-tui`).
5. Reverse the patch again, verify the submodule is clean, and commit the new
   submodule pointer together with the refreshed patch and this README's pin.

At the current pin, upstream `main` has an unrelated test-only type mismatch in
`codex-rs/tui/src/app/tests.rs`: one `AppServerEvent::ServerRequest` construction
is missing `Box::new`. Verification used that one-line fix temporarily and
excluded it from this patch. The focused suite passed all 13 tests; the full TUI
run passed 3,246 tests, with six unrelated IDE-context socket tests failing or
timing out in this environment.
