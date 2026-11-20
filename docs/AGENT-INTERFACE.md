# Agent interface

How an AI agent works in this repository. `AGENTS.md` at the repository root is the source of truth; this document summarises the operating rules and points at the commands. If the two disagree, `AGENTS.md` wins and this file should be corrected.

## Scope and source of truth

- Read `AGENTS.md` before changing anything. Area files (for example `sdk/AGENTS.md`) apply to their own subtree and must be read before editing it.
- Work on the branch the checkout is on (`main` in the shared checkout). Do not create clones or worktrees to hold scratch copies of the repository.
- Keep each change to the narrowest set of files it needs. Leave changes made by other people in the working tree alone, and stage only the files and hunks that belong to your change.

## Git workflow

- Fetch before pushing: run `git fetch` and rebase or merge onto the remote branch, then push. A push that is behind the remote is refused, and the fix is to fetch and integrate, never to force.
- Push to `origin main` only after the checks in the next section pass for the commit being pushed.
- Commit subjects are one sentence that describes the change in plain words, for example "Reject empty session names at the create prompt". Do not name a file, function or diagnosis in the subject.
- The commit body explains how the change was made and why, in prose: the approach, the constraints it respects and the checks that were run.
- Stage explicit paths with `git add <path>`. Do not use `git add -A` or `git commit -a` in a checkout that has changes from other work.
- Commits are attributed to the configured git user only. Do not add co-author or tool attribution lines unless the repository or the user asks for them.
- Never rewrite published history on `main`.

## Build and checks

Run these from the repository root.

- `zig build` builds the binary at `./zig-out/bin/fx`. Use this binary for verification. Do not run a copy from `PATH`, because it does not contain your edits.
- `zig build test` runs the minimal unit set. This is the push gate and the command CI runs.
- `zig build test -Dtest-area=<area>` runs one area, such as `core`, `ui`, `tools` or `session`. Use it for the narrowest check that can fail for your change, and rerun a failing case on its own.
- `zig fmt src/` formats Zig source. `zig fmt --check src/` is the formatting check CI runs; format before committing.
- `zig build run` builds and runs fx.
- The full unit suite runs on a schedule in `.github/workflows/nightly-full.yml` and is not a push gate. Run it by hand only when a change touches a surface that only the full suite covers.
- Before reporting work as ready, build, run the focused tests, and exercise the changed path end to end with `./zig-out/bin/fx`. A passing test run alone does not show that the binary starts and behaves correctly.

When a process must be stopped, stop it by its own PID. Find it with `pgrep -f <pattern>` or `ps -eo pid,args`, confirm the line is yours, then run `kill <pid>`. Do not use `pkill` or `killall`.

## Secrets

- Credentials, tokens and API keys live in an external file outside the repository, readable only by its owner (mode 600). Point tools at that path with an environment variable or the tool's own configuration, and never copy the value into the repository.
- Never commit a secret. Do not put one in source, fixtures, docs, test data, commit messages, issue text or pull request descriptions.
- Never print a secret. Do not echo it, log it, paste it into a tool call's arguments or include it in a report. When a command needs a secret, have it read the file itself.
- If a secret is found in the repository or in output, stop, do not repeat it, and tell the owner so it can be revoked and rotated.

## Code rules that apply to every change

- Do not add comments to source files. Express intent through names and structure. Anything that cannot be expressed that way belongs in `AGENTS.md` or in the relevant docs file.
- Documentation files are created only when they are asked for or when the task requires them.
- Public surface and personal data: do not commit home-directory paths, real account identifiers or private project names. Fixtures use placeholder paths such as `/Users/example/`.

## Reporting

A completion report states the files changed, the commit hash, the push result, and anything that could not be done or verified, with the reason.
