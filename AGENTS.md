# AGENTS.md

Instructions for AI coding agents working with this codebase.

For the agent operating workflow (git fetch and push, commit subjects, build and check commands, secrets), see `docs/AGENT-INTERFACE.md`.

## Declaring Work Ready

Do not say the work is "ready", "done", "good to go", "complete", or similar until you have personally run the binary and exercised the change on its happy path. A passing test suite is necessary, not sufficient — tests in this repo do not always construct the full runtime, attach a TTY, or spawn background threads, so they will not catch startup crashes, render regressions, or thread-lifetime bugs.

Before reporting the work as ready:

1. Build succeeds.
2. Focused tests for the changed path pass locally.
3. **CI** passes for the exact current commit, including the **macOS arm64** check. See **CI on Pull Requests**.
4. Run the built binary locally and drive at least one real interaction that exercises the change end to end.
5. Confirm the process did not abort, stderr is clean, and the behavior matches what you are about to tell the user.

If you cannot run the binary in your environment, say so explicitly and ask the user to verify. Do not silently skip this step and declare the work ready. "The tests pass" is not a substitute for running the app.

### Always use the built binary in this repo

When running fx for verification, **always use the freshly-built binary at** **`./zig-out/bin/fx`** from this checkout. Never run `fx` from `PATH`, never rely on the installed copy at `~/.local/bin/fx`, and never assume an installed copy reflects your change.

* The user may have an older `fx` on their PATH (e.g. installed via `fx upgrade` or the install script). Running that one will not exercise your edits.

* When a user reports "still not working" after you believe you fixed something, do not assume they are running the wrong binary. Assume your fix is incomplete and investigate further. If you genuinely suspect a PATH mismatch, ask — do not silently copy binaries onto their `PATH`.

* In any shell invocation — tmux, direct run, scripts — reference fx as `/Users/<you>/path/to/repo/zig-out/bin/fx` (absolute) or `./zig-out/bin/fx` (when cwd is the repo root). Bare `fx` is always wrong for dev verification.

## Language and Toolchain

This project is written in **Zig 0.17+**. The main binary has no Node.js runtime, no `package.json` at the root, and no JavaScript build step.

Build and test commands:

```bash
zig build
zig build test
zig build test -Dtest-area=core
zig build install-test
./zig-out/bin/fx-test
zig build run
zig fmt src/
zig fmt --check src/
```

`zig build test` runs the minimal unit set, the `core.shared.`, `core.config.`, `mcp_server.` and `usage.` tests. `zig build test -Dtest-area=<area>` runs one area instead: `minimal` (`core.shared.`, `core.config.`, `mcp_server.`, `usage.`), `core` (`core.`), `ui` (`ui.`), `gateway` (`gateway.`), `tools` (`tools.`, `builtins.`), `mcp` (`mcp`), `acp` (`acp.`), `usage` (`usage.`), `permissions` (`core.permissions.`), `tooling` (`core.tooling.`) or `session` (`core.session.`). `zig build install-test` builds the full unit test binary at `zig-out/bin/fx-test` without running it, and `./zig-out/bin/fx-test` runs every unit test. The full suite is not a push gate: `.github/workflows/nightly-full.yml` runs it on a schedule. `zig build run` builds and runs fx. `zig fmt src/` formats the source, and `zig fmt --check src/` is the formatting check CI runs.

The test suites under `tests/` use Bun but are separate from the Zig codebase. `tests/tla/` holds the TLA+ models.

## Code Style

* Format all Zig source with `zig fmt src/` before committing.

* Do not use emojis in code, output, or documentation. Unicode symbols (e.g. checkmark, arrow) are acceptable.

* In documentation, never use double hyphens (`--`) as a dash. Use an emdash (—) sparingly, or rewrite to avoid dashes.

* Use the `technical-writer` skill (`.fx/skills/technical-writer/SKILL.md`) when you write or edit prose, including documentation, commit messages, PR titles and descriptions, and issues. Where the skill and this section differ, such as on em dashes, this section takes precedence.

* CLI flags use kebab-case (e.g. `--no-save`, `--json`). Never use camelCase for flags.

* Follow Zig naming: `camelCase` for functions, `snake_case` for variables, fields, and file names, and `PascalCase` for types.

* Keep `pub` surface area minimal. Only mark declarations `pub` when they are used outside the file.

* Never commit personal home-directory paths, real team IDs, internal team slugs, or personal project slugs. `scripts/check-public-surface.sh` rejects them in CI. Use `/Users/example/` in fixtures.

## Architecture

Key rules:

* `src/main.zig` is the composition root. Do not add leaf feature logic here.

* `src/core/` owns contracts, runtimes, config, sessions, permissions, MCP, skills.

* `src/core/compactor/` owns context compaction. Outside code imports only its front door, `compactor.zig`, and the compactor imports only shared basics and model configuration; its caller hands in the model caller, the record store, and the session's projection of saved turns into chat messages. `scripts/check-compactor-boundary.sh` enforces this in CI.

* `src/core/indexer/` is the native workspace indexer. It reads git's ignore rules, repository layout, and git config as data and never starts a process, so a repository's configuration cannot make it run a program. Outside code imports only its front door, `indexer.zig`, and the indexer imports only the standard library, its own files, `io.zig`, and `debug_trace.zig`. `@`-completion, `glob_files`, and `grep_files` list files only through it and never start a process. `scripts/check-indexer-boundary.sh` enforces this in CI.

* `src/core/recovery/` decides how one model request recovers: when to retry, how long to wait, when to try another way, what the status line says, and what to save so the request survives a closed window or a crash. fx reports events to `step` and carries out the plan it returns. The module performs no I/O, reads no clock, and never allocates. Outside code imports only its front door, `recovery.zig`, and the module imports only the standard library. `tests/tla/recovery/Recovery.tla` models it, and `scripts/check-recovery-boundary.sh` enforces the boundary in CI.

* `src/core/agents/` owns `Agent`, one conversation's own state: its session, worker, stream, prompts, submission, title, totals, attachments, diffs, and undo stack. `App.main_agent` holds the main conversation's. Outside code imports only its front door, `agents.zig`, and the folder never imports `src/ui/`, the terminal runtime, or `main.zig`, nor a file that imports `src/ui/` or `main.zig` itself, because the app that shows an agent owns the screen. Generic helpers probe these fields with `agents.hasAgentField`, not `@hasField`, and test apps nest them under `main_agent` the same way. `scripts/check-agents-boundary.sh` enforces the imports in CI.

* `src/core/shell_command/safe_git.zig` runs git for the `fx pr` and `fx issue` snapshot and for the agent's direct read-only `git status`, `git diff`, and `git log` when the command does not use the user's own shell environment. It turns off every program a repository's own config can name and refuses to run when git would use a different repository than the one fx read. In `auto` mode a git command it refuses is returned to the agent without running. When safe git refuses, the `fx pr` snapshot reports `in_git_repo` as true with every section unavailable, so `fx pr` still starts and its agent inspects the files directly; `fx git-snapshot --json` reports `git_refused` instead. Commands that run in a shell use git with the repository's full config: git in the shell tool's default `user` environment, and the routine commands `auto` mode runs without review, such as `git status` with other flags, `git fetch`, or `npm test`.

* `src/mcp/` is the MCP engine. Its files import only `std` and each other, and the host passes in `std.Io` and every other service through `src/mcp/host.zig`. fx connects to it through `src/core/mcp_host/`. `src/core/mcp/` holds the MCP types, config parsing, schema checks, search, and tool naming that the host, the tools, ACP, and the UI share.

* `src/tools/` owns built-in tool implementations. Generic tool contracts and dispatch live in `src/core/tooling/`. Default tool specs are centralized in `src/core/tooling/tool_specs.zig` or `src/builtins/tools.zig`, not in individual tool files.

* `src/ui/` owns terminal rendering, event loop, input, transcript. It must not own product state.

* `src/gateway/` owns provider transport. It must not absorb product-state logic.

* `src/acp/` owns the ACP (Agent Client Protocol) JSON-RPC 2.0 server.

* `src/core/terminal/` ends owned terminals on exit within bounded grace and join limits. A backend whose PTY output has not ended by the join deadline, for example because a process that left the terminal still holds the PTY, has its output reader abandoned, and `Runtime.deinit` then always waits for every backend and frees every session.

* `src/wasm_core_main.zig`, `src/wasm_term_main.zig`, and `src/napi_core_main.zig` are the libfx SDK entry points. Read `sdk/AGENTS.md` before changing them or anything under `sdk/`. The remote/browser terminal WebAssembly surface is disabled by default: normal `zig build`, CI, dev releases, and libfx packages do not build or ship `fx-term.wasm`; `build.zig` requires `-Dwasm-surface=term -Dremote-terminal=true` to build it explicitly.

### Adding a Feature

Before implementing, answer in order:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified in the macOS arm64 PGSO corpus?

If unclear, define the contract first.

Every root `tests/e2e/*.test.ts` file must have exactly one classification in
`scripts/pgso/corpus.json`:

* **Training:** common or performance-sensitive product behavior that should
  influence LLVM's hot and cold decisions

* **Verification-only:** important correctness, recovery, security, or rare
  behavior that the final candidate must pass without making it hot

* **Intentional exclusion:** nondeterministic, live-network, credentialed,
  sound-related, or harness-only coverage, with a concrete reason

New tests inside an already classified file inherit that file's classification,
but feature work must reconsider whether the existing classification still
matches the file's product role. When removing a feature or E2E owner, remove
its stale corpus entry. Normal PR CI loads the corpus and rejects missing,
duplicate, stale, or unclassified files without running the expensive PGSO
qualification. It also runs `scripts/pgso/tests/test_corpus.py`, whose
training, verification, and exclusion lists must name the same files in the
same order as the corpus.

Every root E2E file also needs a weight in `tests/e2e/ci-shard-weights.json`.
CI fails on a missing or stale entry.

### Adding a Command

1. Add the command kind in `src/core/slash_commands/command_specs.zig` and its spec, including usage, summary, and options, in `src/builtins/commands.zig`
2. Add dispatch wiring in `src/core/cli/cli_surface.zig`
3. Add a snapshot type if it has structured output
4. Render text and JSON from the same snapshot via `src/core/output/output_contracts.zig`

Do not scatter help text or argument parsing across multiple files.

Use the `fx-cli-shape` skill (`.fx/skills/fx-cli-shape/SKILL.md`) when you add, rename, remove, or review a user-facing control: a command, argument, flag, setting, env var, slash command, JSON output field, or exit code. It covers which mechanism to use, the name on every surface, and the controls that need a maintainer's approval.

## Configuration and State

Profile configuration and runtime state lives under `~/.fx/`. Project `.fx.json` contains committed project defaults only.

Config precedence (highest wins):

1. Command-line flags, where a command supports them
2. Environment variables such as `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
3. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
4. `~/.fx/settings.json` top-level (profile global settings)
5. `<workspace>/.fx.json` (committed project defaults)
6. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `max_agent_steps`, `max_tool_result_bytes`, `context`, `provider_order`, and `provider_strict`, parsed by `parseProjectSafeFields` in `src/core/config/config_runtime.zig`. The project layer never parses profile-owned keys, such as provider and model selection, permissions, and interface preferences.

Runtime state lives under `~/.fx/sessions/<session-id>/` (`session.json`, `background/`, `subagent/`, `logs/`). Sessions are global and portable across workspaces. Each session tracks its `workspace_root`, which updates when resumed in a different workspace. Subagent children are internal sessions registered in their parent's session log as `child_spawned` and `child_finished` events, written by `Session.appendChildLines`. Older v1 sessions kept that registry in `subagent/children.json`, which `v1_conversion.zig` converts. Session discovery skips managed children, and they cannot be resumed directly.

Saved sessions are intentional durable state, not a bounded cache. A footer count such as `fx 1/26` counts open instances in one interactive process, not saved sessions; `openInstanceCount` in `src/core/app/app_agents_runtime.zig` builds that count from the first open root plus live child instances. fx keeps every saved root until the user archives or deletes it. `fx sessions purge [--cwd <path>] [--older-than <days>] [-y]` is the explicit cleanup: without `-y` it dry-runs, and with `--older-than <days>` it selects only sessions whose `updated_at_ms` is older than that window. `deleteSaved` refuses busy sessions, so an active/current session is preserved. Automatic doctor sweeping removes only orphaned side folders for sessions with no log after at least 24 hours, plus `.trash` entries and `.tmp` entries older than one hour; it never deletes a saved root session.

## Permissions

Security is permission-first. All sensitive tool behavior must integrate with `src/core/permissions/permissions.zig`.

* `permission_mode` is `ask` (alias `manual`, shown as Always Ask), `yolo` (Ask When Needed; `full-access` is its picker name), `auto` (Never Ask), or `dontAsk`. Auto runs everything a deny rule does not block, denies AskUserQuestion, and holds only `unsafe_git`; it calls no model reviewer (the classifier is `.disabled()` unless a test overrides it), so the reviewer bullets below describe code that auto mode does not reach. Ask and yolo prompt for configured ask rules, sensitive files, `.git` paths and dangerous commands; the dangerous-command ask comes before allow rules and in-memory session grants, but after an exact saved-session allow. In ask mode, `write_file` and `edit_file` inside the workspace of a git work tree run without a prompt

* A run with no prompter denies an approval-required call to the model and continues; the exit code follows the turn outcome. `fx -p` forces auto and rejects `--yolo`, `--auto` and `--plan`; `fx ask` keeps the configured mode

* Every untrusted folder gets the trust prompt before an interactive session starts (`gateBeforeSession` in `src/core/app/app_mcp_runtime.zig`); e2e harnesses set `KIMI_CODE_TRUST_WORKSPACE=1`. Esc on a goal or swarm start prompt declines that tool and keeps the turn running; Esc on any other approval prompt cancels the turn

* `@hasDecl` does not see a non-`pub` declaration of a struct defined in a test, so a test double whose method is probed with `@hasDecl` must declare it `pub`

* Configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* Session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; list and revoke those rules by their stable IDs

* Routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy. Every remaining unresolved `auto` action receives one narrow security review using the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and other static root tools omit task text. Reviewed commands, shell input, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority. Shell input reviews also include the owned receiving session's launch command, working directory, and bounded current screen after verifying session authority, including on resume. The launch command describes startup only; screen content remains untrusted evidence and input still receives its own review

* The reviewer returns `caution` only for prompt injection, where instructions planted in untrusted text make the action delete or overwrite files, send data out, install or run outside code, weaken security, or use credentials the user did not ask for, or system harm, where the action would break, compromise, or hack the user's machine or the runner. Each caution names its category and quotes its evidence. fx keeps a prompt-injection caution only when the quote appears in untrusted tool output or a receiver screen and not in the user's own requests or the pending action, since an action that contains the quoted text is editing, writing, or searching it rather than following it, and a system-harm caution only when the quote appears in the pending action or meets that prompt-injection rule; it clears every other caution. A caution that passes these checks holds the action unless one fresh review of the same request returns `clear`, so a single misjudged quote cannot block; that review's own quote is not checked, and when it cannot complete, the hold stands. Destructive, risky, external, public, remote, unrequested, or task-conflicting actions therefore clear unless they are one of those harms. Following any text is never prompt injection when the action only reads, searches, builds, tests, or runs a local tool's own steps, such as a CLI's next subcommand, a git hint, or a workflow tool's next command. Current-turn `ask_user_question` answers reach the reviewer as user answers and never count as injection evidence. The optional `typesafeai/jev` reviewer answers without quotes, so its decisions are kept as returned. A `clear` review authorizes only the exact unchanged action. A `caution`, incomplete-evidence result, or unavailable review holds only that action, returns guidance to the agent, and never opens a human permission screen, disables tools, or ends the turn

* Exact cautions and deterministic incomplete-evidence results are reused only for the current turn. An unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable review opportunity per turn; changed actions remain independently reviewable until the bounded current-turn review budget is exhausted. Each review accepts exactly one valid structured decision even with accompanying prose and may retry one malformed completion within the current attempt's deadline. A transport timeout, transient transport failure, or failed transport call is retried once with a fresh 30-second deadline; permanent transport failures, valid cautions, and cancellation are never retried. Legacy `permission_request_id` input is rejected without prompting

* Host-generated review holds retain their advice for the agent and transcript, but carry a saved `review_feedback` marker that excludes them from later security evidence, including after recovery. Old unmarked results remain untrusted evidence; never infer the marker from output text. Quoted review accusations are not proof of an attack, and handling plans or test instructions as data is not itself prompt injection

* A command form that fx runs without review, through `command_effect.plan` or `command_effect.knownReversibleAutoCommand`, must be listed in `parity_review_free_commands` in `src/core/shell_command/command_effect.zig`. The shell parity tests check that sh, dash, bash, and zsh, with and without `extendedglob`, run each one exactly as fx parsed it, and the nightly `shell_parity` fuzz target checks generated commands the same way

Do not bypass the permission system for new tools.

## CI on Pull Requests

Do not run the complete deterministic test suite locally as the default development loop. Run the focused test for the changed path, build the binary, and exercise that path with `./zig-out/bin/fx`.

After the focused checks pass, create a clean checkpoint commit locally. Do not push a feature branch or open a draft PR from this checkout for the two-phase work; the only push is the Phase B push to origin `main`, made once and only when the Phase B witnesses are green. Linux is the gate for every change because most fx behavior is identical on every platform:

* `.github/workflows/ci.yml` runs on Linux x86_64. It checks formatting, the PGSO corpus, the public surface, and the agents, compactor, indexer, and recovery boundaries, model-checks request recovery and the empty-reply nudge, runs the minimal unit set (`zig build test`, ReleaseSafe), runs the E2E files in four weighted shards plus the MCP conformance baseline, and qualifies the SDK packages. A failed E2E file is retried once. A file that passes only on retry gets a warning annotation; investigate it as a possible race. `Build & Test` fails when any SDK job fails.
* The supported unit-test gate is `zig build test` in its default listen mode, with `--summary all`, which is the command `ci.yml` runs. Running the built test binary directly in terminal mode is not a gate. In a Debug build run that way on 2026-11-08, 17 `app_render_runtime` cases failed in terminal mode (for example `core.app.app_render_runtime.test.core.app_render_runtime requested-frame flush commits and acknowledges one snapshot...FAIL (TestUnexpectedResult)`), while the listen-mode gate passed them, so a terminal-mode failure there is outside the supported gate.
* `.github/workflows/binary-size.yml` builds each release target on its native runner, reports the size change, and smoke-tests every target's binary.
* `.github/workflows/bench.yml` enforces the startup latency budget with `benchmarks/check_budgets.py`.

Linux jobs install Zig through `.github/actions/setup-zig`, which restores the Zig cache that runs on `main` save with `.github/actions/save-zig-cache`. Pull requests never save a Zig cache through these actions, so they cannot push `main`'s entries out of the repository's cache quota. The PGSO workflow keeps its own cache through `.github/actions/setup-pgso`.

macOS runs only when `scripts/detect-macos-need.sh` finds a change that can behave differently there, such as a Zig file with a macOS, BSD, or Linux code path, `build.zig`, the macOS signing script, the native SDK addon, or a platform E2E file. If the detector cannot read the change, the `macOS arm64` check fails instead of passing. When the change does not need macOS, the check passes without starting a macOS runner. To request macOS for any other change, add the `ci:macos` label or run `gh workflow run macos.yml --ref <branch>`. The label needs triage access and the dispatch needs write access, so an outside contributor asks in the PR and a maintainer starts the run. Every E2E file that branches on `process.platform` or `platform()` being `darwin` or `linux` must appear in `tests/e2e/macos-platform-tests.json`, and `tests/e2e/ci-shards.test.ts` enforces that.

[gm-read: truncated at 19935 of 25051 bytes; pass offset: 195 and limit: 37 to read the rest]
## Iteration-time housekeeping

Iteration time grows unless each loop keeps cutting it. This is part of the work, not a separate task.

- Measure the loop: how much of the time the agent is busy, turns that end early with work open, the gap from a turn's end to the next prompt, and commands that repeat with their wall time. Measure on a regular rhythm and whenever progress feels slow.
- Fix the largest measured waste in the cycle that finds it. A slow test file gets split so one failing row can be run alone.
- Record the wall time of each build and check. Prove a change with the narrowest check that can fail for it. Rerun a failing row alone. Run the full set once before the push.
- Never sleep to wait. Block once on the job's PID with a timeout, or do the next reachable item while it runs.
- Name the longest step in the report and what was done about it.

## Validation

Debug and reproduce the failing path before writing any test. A test written before the cause is known pins the symptom, not the fault.

Iterate on a running process, not on the full suite. Start `./zig-out/bin/fx serve` or a live gateway and send the one request that exercises the path. When a unit test is the right check, run only the area the change touches with `zig build test -Dtest-area=<area>`.

Run the minimal set (`zig build test`) on each push. `ci.yml` runs it on pushes to `main` and on every pull request, and its Build & Test job requires that run to succeed.

Run the full suite only in `.github/workflows/nightly-full.yml`, which runs on a schedule and can be dispatched by hand with `gh workflow run nightly-full.yml`, or when a change touches a surface that only the full suite covers.

Record a per-step time in `docs/PENDING_VALIDATION.md` for each test kept: the command, the test count, the wall-clock seconds and the date.

## Stopping Processes

Stop a process only by its own PID. Find it with `pgrep -f <pattern>` or `ps -eo pid,args`, check that the line is the process you started, then run `kill <pid>`. Never use `pkill`, `killall` or `pkill -0`. A name match can hit another agent's process or the shell that runs the command.

## Deliberate host-only exclusions

Generated with and Co-Authored-By attribution lines are excluded because /config/.claude/CLAUDE.md INVARIANT 4 says attribute all work to lanmower only, especially in git, and no one else.

EnterWorktree and ExitWorktree are excluded because /config/.claude/CLAUDE.md INVARIANT 7 says work on main in the shared checkout and do not clone a repository or make fake worktrees.

playwriter is excluded because the served gm skill says playwriter is this project's browser control and must be driven only through its verbs inside run_code, not reimplemented as an fx host surface.

### src/core/session

- A single row that fails `Summary.persistable()` makes `decodeRows` reject the whole `.resume-catalog` file, and `Loaded.load` then treats the cache as absent, so one bad row discards every reused entry. Source: `src/core/session/session_catalog_cache.zig`
- `listActionableCatalog` never writes `.resume-catalog`, since the only write in that file is inside a test, so production code only reads the cache. Reused rows are matched by stat fingerprint without opening their sessions. Source: `src/core/session/session_catalog_cache.zig`
- `ActionableSessionCatalog.invalid_ids` feeds `v1_conversion.listRoots`, which lists each unconverted v1 root with its folder time and does not convert it, so v1 sessions appear beside v2 ones until they are converted (decision D59). Source: `src/core/session/v1_conversion.zig`
- `loadSchemaV3ReadOnly` opens `events.jsonl` read-only, reads the `commit.<generation>.json` watermark, replays the committed prefix, and archives any history-only recovery checkpoint in memory only, so this function never writes the v3 log. Source: `src/core/session/session_migration.zig`
- The v3 import never reads the `session.json` manifest, which is a derived projection, and trusts only the watermark. Source: `src/core/session/session_migration.zig`
- `replayCommittedPrefix` replays up to an explicit committed byte count and ignores later bytes. Its read-only callers are `session_migration.loadSchemaV3ReadOnly` and the schema-3 recovery path in `session_store.zig`, so it is not limited to the legacy importer. Source: `src/core/session/session_replay.zig`
- `readSubagentChildIdentityWithin` reads at most `max_bytes` from the log start and stops at the first newline. A first line longer than `max_bytes`, or one with no newline, fails with `error.TruncatedEventFrame`, so listing cost is bounded and does not grow with the log; its only caller is `session_log.zig`. Source: `src/core/session/session_replay.zig`
- v2 artifact handles carry the full 64-hex SHA-256 digest of the body, which names its blob, while v1 handles keep only the first 8 bytes (16 hex digits) (decision D44). Source: `src/core/session/artifact_digest.zig`
- A blob-backed web fetch store runs no reconcile scan, so its `limits` count only the bytes and files this process reserves, not blobs already on disk. Source: `src/core/session/web_fetch_artifacts.zig`
- `validateSessionId` rejects `v2` in any letter case, so no v1 session can take the name of the v2 root folder, and the v1 scans in `session_store.zig` skip any name that fails this check. Source: `src/core/session/session_layout.zig`
- A manifest is stale when its recorded `event_log_bytes` differs from the committed log size, and stat identity such as inode or ctime plays no part, so copying or restoring a session does not by itself make its manifest stale. Source: `src/core/session/session_projection.zig`
- `mayBelongToWorkspace` rejects a line only when every `"workspace_root":"` key in it has an unescaped value that differs from the workspace root. A key inside a JSON string is always escaped and cannot match, so the prefilter never rejects a real record, and lines with an escaped value or a key written with spaces go to the full parse. Source: `src/core/session/prompt_history_store.zig`
- `detectStaleShellHandles` flags a restored shell id only when the live managed-execution registry does not own it, so handles started by this process stay valid across an in-process resume. Source: `src/core/session/session.zig`
- A stale-shell flag set by the resume paths is taken with a queued prompt, and it is handed back with `returnStaleShellHandles` if that prompt is dropped before its turn, so the note is not lost; the note is queued as a system message with `context_note` set (decision D93). Source: `src/core/session/session.zig`
- `unversioned_history_len` is referenced only in `session.zig` and is never persisted, so `restore` recomputes it from the restored history. Source: `src/core/session/session.zig`
- `commitCompactedHistory` stores the prepared slice as the agent's history, so it takes ownership of that slice. The ACP caller in `src/acp/prompt.zig` appends the journal entry first, calls this function only after that, and clears its own ownership flag after the call. Source: `src/core/session/session.zig`
- Restored steering is rebuilt as user-role text with `restored_steering` set, and a subagent frame in it gets `ordinary` origin instead of `user_turn`, so a subagent's report is never attributed to the user. Source: `src/core/session/session.zig`
- `permission_rules_dropped` is set only when a salvaged v1 member's saved permission rules could not be read, so the recovered copy has none (decision D72). Source: `src/core/session/session_adapter.zig`
- A session directory with no `authority.json` marker whose `session.json` is a schema-3 manifest for that id is reported as `error.SessionNotFound` and is never read as legacy. Source: `src/core/session/session_authority.zig`
- The read-only handle from `openSessionFile` stays a consistent snapshot even if an atomic replacement unlinks the file afterwards, because the open file keeps its contents. Source: `src/core/session/session_authority.zig`
- Blob results have no ranged reader: `statManaged` asserts a non-blob store, and `readStoredTextManaged` reads a blob whole up to `stored_text_max_bytes` (decision D44). Source: `src/core/session/result_store.zig`
- A compactor record read from a v2 blob returns at most `max_bytes` from the blob's start, so it can be much shorter than the blob (decision D50). Source: `src/core/session/result_store.zig`
- `openAndVerify` returns null, and never deletes the cache file, for an absent, invalid, foreign-session, foreign-schema, or watermark-mismatched history cache. Source: `src/core/session/history_snapshot.zig`
- Fields added after the last release that wrote caches must be optional, because released caches decode without them, and `absentFromCaches` must list exactly those fields; today the only entry is `CommittedFilePresentation.review_lines`. Source: `src/core/session/history_snapshot.zig`
- v2 command output is spooled to an unlinked temporary file under `/tmp`, outside the session, and is moved into the session's blobs with `putBlobFile` when it is kept. Source: `src/core/session/command_replay_store.zig`
- A command replay handle is `fx-command-replay-` followed by a random per-run id and the blob hash, so two commands with identical output get distinct handles, and `artifact_digest.blobHash` reads the hash back from the end (decisions D44 and D91). Source: `src/core/session/command_replay_store.zig`
- `Capture.discard` deletes the spool file of a retained capture, whereas `releaseRetained` only frees the descriptor handle and leaves the spool file in place. Source: `src/core/session/command_replay_store.zig`
- `Reader.nextByte` reads through one fixed 8 KiB internal buffer, so replay memory does not grow with the callback count or the frame size. Source: `src/core/session/command_replay_store.zig`
- `CandidateIterator.nextId` is not thread safe, so each worker must advance it through `CatalogRead.nextId` in `session_catalog_cache.zig`, which holds `iterator_mutex`. Source: `src/core/session/session_store.zig`
- A schema-v3 session with an unreadable manifest is listed from its committed log only when that replay succeeds. A stale projection is replaced by a committed-log replay, and when the replay fails the stale summary stays and the candidate is left unchanged (`replayCommittedLog`). Source: `src/core/session/session_discovery.zig`
- A legacy session fenced by `authority.pending.json` is listed from its legacy snapshot by `classifyFencedLegacyCandidate`, so an interrupted upgrade stays visible in listings. Source: `src/core/session/session_discovery.zig`
- A `model_call` record is placed by the tool step boundary and the steering count it was saved with, so a model call saved before a steering message stays ahead of that message (decision D96). Source: `src/core/session/session_event.zig`
- The `/status` panel reports a session as saved only when it is on disk, and the TLA+ model `tests/tla/session/ShellSession.tla` checks this as `StatusSavedIsOnDisk`, run by `tests/tla/session/check.sh`. Source: `src/core/session/session_commands.zig`
- `Task.done` is stored with release ordering after the worker writes its results, and `isDone` reads it with acquire, so results may be read only after `isDone` reports true or after `join`. Source: `src/core/session/session_title_generation.zig`
- Listing reads at most `listed_first_event_max_bytes` of a legacy log's first event to find the child identity, so listing never scans a log for that identity. Source: `src/core/session/session_log.zig`
- `setRuntimeContext` accepts a turn's runtime context only once, and only before any step, call, result, steering, or context note of that turn; a later attempt fails with `InvalidConversationFrame` (decision D94). Source: `src/core/session/session_log.zig`
- `appendContextNote` refuses a note once the turn has any tool call or tool result, so a note can only come before the turn's tool activity. Source: `src/core/session/session_log.zig`
- `discardEmptyLegacyFileEvidence` drops file evidence entries with an empty path, which an older format kept, and returns how many it dropped; `v1_conversion.zig` calls it during conversion. Source: `src/core/session/session_log.zig`
- A v2 capability retains the session's blob store when it is created and releases it on deinit, so the blob store outlives every capability that uses it. Source: `src/core/session/session_child_store.zig`
- A v2 capability has no side folder, and its terminal folder is opened on first use and created only by a writable capability, so a read-only capability never creates it. Source: `src/core/session/session_child_store.zig`
- `openBlobFile` returns the blob's file without checking its bytes against the name, so a caller that needs integrity must verify the bytes itself. Source: `src/core/session/session_child_store.zig`
- `resolve` gives a name that embeds a blob hash precedence over any compactor record of the same name, so records cannot shadow blob names. Source: `src/core/session/session_child_store.zig`
- `moveTerminalFolder` skips a terminal folder that was already moved, and the side folder is deleted only after its contents are moved, so an interrupted move leaves the side folder for the next open. Source: `src/core/session/session_adapter.zig`
- `sweepRoot` removes a side folder only when its session has no log and the folder is at least 24 hours old, because a younger folder may belong to a session whose first turn has not yet written its log (decision D36). Source: `src/core/session/session_adapter.zig`
- `Store.deinit` frees the manager that every `Session` points into through `.env`, so all sessions must be closed before the store is deinitialized. Source: `src/core/session/session_adapter.zig`
- `conversionProblem` returns text that points into `store.problem`, so the text is valid only until the next read or check that resets `store.problem`. Source: `src/core/session/session_adapter.zig`
- `traceWiring` lines are checked by `tests/tla/session_manager/trace/check_wiring_traces.py`. Source: `src/core/session/session_adapter.zig`
- `write` places the `compaction_records` lines before the batch's events, so an event that cites compaction records never lands without them (decision D50). Source: `src/core/session/session_adapter.zig`
- `write` attaches every pending blob to the batch through `listPending`, so a blob lost before it is listed shows up as damage to verify and recover (decision D39). Source: `src/core/session/session_adapter.zig`
- `BlobHost` takes `life` before `mutex`: `put` calls `remember` while holding `life`, and `detach` releases `life` before taking `mutex`. Source: `src/core/session/session_adapter.zig`
- `newHandle` tries up to 8 generated ids and skips any id that a v1 session folder already has, so a new session cannot shadow an unconverted v1 session (`NoShadow` in `tests/tla/session_manager/V1Conversion.tla`). Source: `src/core/session/session_adapter.zig`
- `readSession` reads through `Manager.peek`, which takes no session lock. Source: `src/core/session/session_adapter.zig`
- A resume that leaves the lock wait unset waits 2000 ms by default (`v1_conversion.lock_wait_ms`), while `resumeSessionWithoutWaiting` passes 0, so a busy session fails at once (decision D38). Source: `src/core/session/session_adapter.zig`
- `listPage` adds an unconverted v1 root only when v2 does not hold it (`holdsV2`), so a session never appears twice in a page (decisions D59 and D62). Source: `src/core/session/session_adapter.zig`
- `recover` forks the source at its `.last_good` point through `openFork` and does not write the source. Source: `src/core/session/session_adapter.zig`
- The v2 `recover` path never sets `permission_rules_dropped`, which stays false, and only the salvage path sets it from a v1 member's `rules_dropped` (decision D72). Source: `src/core/session/session_adapter.zig`
- `Doctor.unconverted` counts the v1 roots that v2 does not hold (decision D73). Source: `src/core/session/session_adapter.zig`
- `hasInterruptedTurn` reports true for an open turn or for a last turn ended by a crash or close, reports false while another process holds the session busy, and writes nothing. Source: `src/core/session/session_adapter.zig`
- `archive_legacy_recovery` moves a `history_only` recovery checkpoint into history as an interrupted turn and clears the checkpoint, so legacy recovery evidence survives without a replay. Source: `src/core/session/session_codec.zig`
- The view returned by `interruptedTurn` borrows the checkpoint's user, assistant, and execution data, so it is valid only while the checkpoint lives. Source: `src/core/session/session_codec.zig`
- `ImageBlobReader.take` accepts only the next unread blob, in order, so one blob cannot decode into several images. Source: `src/core/session/session_codec.zig`
- An image name is the 64-character SHA-256 hex digest of the image bytes, and `StagedImages.add` rejects bytes whose hash does not match their name. The journal in `src/acp/libfx_journal.zig` uses the attachment's `snapshot_sha256` as that name. Source: `src/core/session/session_codec.zig`
- `StagedImages.add` frees the bytes itself only for a duplicate name, so on an `ImageNameMismatch` error the caller still owns them. Source: `src/core/session/session_codec.zig`
- The journal writes a delta only when the new execution hashes extend the previous progress, which `ExecutionHashes.extends` checks for user, tool steps, files, and steering. Source: `src/core/session/session_codec.zig`
- A checkpoint whose cause is `system_resumed` loads as `connectivity_lost`, so checkpoints written by an older build still load. Source: `src/core/session/session_codec.zig`
- `validateInlineImageBytes` checks inline image bytes for non-emptiness, a size bound, and a sniffed media type, and `loadVerifiedSnapshot` in `src/core/images/image_attachments.zig` checks the stored digest of inline bytes when a request needs them. Source: `src/core/session/session_codec.zig`
- `removeFolder` renames a converted member folder into `trash+v1`, beside the v1 session folders, and then deletes it there, so a v1 writer waiting on that folder finds it gone. Refusals are traced and reported as `false` rather than as an error (decision D60). Source: `src/core/session/v1_conversion.zig`
- `strayChildren` lists a child whose parent is not a v1 root and leaves it in place, skips a child whose kind or parent link cannot be read, and records an unreadable parent kind as `unreadable` (decision D88). Source: `src/core/session/v1_conversion.zig`
- An unreadable remembered-session bookmark makes `rememberedId` return `RememberedSessionUnavailable` (decision D86). Source: `src/core/session/v1_conversion.zig`
- `rootIds`, `strayChildren`, `rememberedId`, `readDetail`, and `listRoots` open the v1 store with `initReadOnlyFromHome`, so these read helpers never convert a v1 session. Source: `src/core/session/v1_conversion.zig`
- `noLatestError` in `session_adapter.zig` returns `NoReadableSessions` instead of `NoSavedSessions` when `hasUnreadable` reports an unreadable v1 session (decision D76). Source: `src/core/session/session_adapter.zig`
- `hasFolder` treats only `FileNotFound` as absent and propagates other stat errors, so a new v2 id never takes a v1 id it could not check (`NoShadow` in `tests/tla/session_manager/V1Conversion.tla`). Source: `src/core/session/v1_conversion.zig`
- `lockFamily` locks the root first and then its children, read from `children.json` or, when there is no registry, from the relationship index, and it records a child whose folder is gone as absent. Source: `src/core/session/v1_conversion.zig`
- `lockMember` returns null when the folder is gone or was replaced while waiting, which the converter traces as a vanished session. Source: `src/core/session/v1_conversion.zig`
- `tryLockLeftover` takes the lock with zero wait and returns null when the session is busy or gone, matching the `CClean` action in `tests/tla/session_manager/V1Conversion.tla`. Source: `src/core/session/v1_conversion.zig`
- `FrameReader.finish` replaces an open turn with the recovery checkpoint's interrupted turn when the checkpoint loads for the log's last sequence, and it drops a checkpoint that has no open turn with a `RecoveryDropped` trace (decision D56). Source: `src/core/session/v1_conversion.zig`
- An open v1 turn with no end is imported with an appended `interrupted` event whose reason is `failed` (decisions D1 and D77). Source: `src/core/session/session_adapter.zig`
- `coveredSteps` counts `keep_tool_steps` and `keep_steering` through `session_log.ConversationProgress` (decision D87). Source: `src/core/session/v1_conversion.zig`
- `listedTime` returns the later of the session's `updated_at` and, when it has history, the `events.jsonl` modification time. Source: `src/core/session/v1_conversion.zig`
- A v1 member read with `Rules.required` fails when `permissions.json` cannot be read, while `Rules.drop_unreadable` drops the saved rules and sets `rules_dropped` (decision D72). Source: `src/core/session/v1_conversion.zig`
- `fingerprintOf` skips the lock, liveness, recovery, and cache files, and adds `subagent/children.json` and the client files to the fingerprint (decision D60). Source: `src/core/session/v1_conversion.zig`
- `readSalvage` reads a damaged v1 root's recoverable state as a member, so `recover` can import it under a new id (decision D64). Source: `src/core/session/v1_conversion.zig`
- A `session.json` larger than `session_codec.max_session_metadata_bytes` is read through `readOlderFormat` instead of being refused (decision D61). Source: `src/core/session/v1_conversion.zig`
- `withImages` stores readable image bytes inside the converted prompt and keeps the path of a missing image, and an unreadable image file makes the member refuse conversion (decisions D44 and D82). Source: `src/core/session/v1_conversion.zig`
- `capturePathOnly` returns false when an image snapshot cannot be captured, and the image is dropped while conversion continues (decision D82). Source: `src/core/session/v1_conversion.zig`
### src/core/slash_commands

- The old allowlist scope spellings `user` and `local` still work and print a deprecation warning built from `deprecated_until`, and their replacements are `global` and `workspace`. Source: `src/core/slash_commands/command_specs.zig`
### src/core/tooling

- A cached web fetch reference is removed and treated as a miss when its `store_id` differs from the active store's id. Source: `src/core/tooling/web_fetch_runtime.zig`
### tests/fixtures/v1-sessions

- The `remembered` fixture session `rtXn8_Z6_NNt`, under `tests/fixtures/v1-sessions/remembered/sessions/`, was produced by `tests/fixtures/v1-sessions/generate.ts`, which defaults the writer to `v0.0.14`, and it carries the history cache that release wrote. Source: `tests/fixtures/v1-sessions/generate.ts`

### src/core/subagent

- `ProfileCache.find` returns a child's profile only after `ProfileCache.get` has loaded it during authority resolution, so a lookup before resolution returns null. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A child's permission mode comes from its own screen choice first, then its profile's mode (which wins even when looser than the inherited mode), then the parent's current mode, then the mode its work was sent under. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A child with no mode of its own or from its profile follows its parent's current mode on each resolve, and falls back to the mode its work was sent under when no parent mode is available; for a user-typed turn the mode passed in stands in for the work's mode. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- `Resolver.currentMode` reads the children registry without the store lock that `resolve` takes, so callers must not assume it is serialized with a save. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A profile that sets tools or MCP servers takes them from `HostResolver.base_fn` when it is set, so it can grant more than its parent has; without `base_fn` it only narrows the parent's set. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- `ProfileCache` loads a child's profile once and keeps it for the life of the process, so a running child keeps its profile when the profile is saved again; without explicit roots, profiles resolve from the fx home and the current directory. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A profile that cannot be loaded, or a child with a profile but no `ProfileCache`, makes authority resolution fail with `HostAuthorityUnavailable` rather than fall back to wider authority. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A profile that sets MCP servers narrows both the integrations and the MCP view to those servers, and an integration name that the MCP view does not know is treated as a server name. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- An instance's own profile narrows the authority its whole tree starts from in the same way. (`/workspace/fx/fx/src/core/subagent/authority.zig`)
- A child reply's usage is added to the child's own session `set usage` total and never to the parent's, as design record D92 in `tests/tla/session_manager/system-design.md` specifies. (`/workspace/fx/fx/src/core/subagent/agent_adapter.zig`)
- `lost` is written only by crash repair and by the v1 import, and `v2Outcome` refuses to save it into a registry. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- `started_by` on a work is the parent unless the user typed the turn on the child's screen or the child's own child woke it; a missing or unreadable value means the parent. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- Each save of the parent's child registry writes only the child lines that changed, and a finish is written before a new spawn on the same child. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- The work message of unfinished children is never written to the parent's log; the log keeps only the work id, agent name, profile and request fingerprint. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- The `V2Children` `state` mutex is separate from its `lock` and guards the in-memory `registry` and `seeds`, which `closedName` reads under that mutex. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- Seeds keep the preferences and language for a child whose log does not exist yet, and a child's instructions are not stored in the parent's log. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- `planLines` writes the finish of a changed work before the spawn of the new work, and writes nothing for a change of phase alone. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- `registryFromChildren` rebuilds only the children that are not yet closed and fails with `StateTooLarge` when more than `max_children` are open. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- Every `child_spawned` line repeats the child's agent name, profile and request fingerprint, because folding keeps only the newest line for a child. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- A `child_spawned` line that names a `report` rule marks its work as one whose end owes the parent a report; crash repair writes its finish without fx data, so that rule on the spawn is what lets a crash-closed work report. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- A `child_finished` line without a `report` field owes no report, so an upgraded fx wakes no parent for old finishes. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- Closing an idle child appends a spawn with no report rule followed by a finish whose data is `closed` true. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- `isDiscoveredManagedChildSession` trusts a true `subagent_child` identity first, then any subagent control marker, and only then falls back to the legacy identity read. (`/workspace/fx/fx/src/core/subagent/child_state.zig`)
- `AdmissionSnapshot` is the authority for one child turn, captured once by `captureAdmission` and treated as immutable afterwards; the type does not enforce this. (`/workspace/fx/fx/src/core/subagent/domain.zig`)
- `liveMcpViewFrom` moves the snapshot's `mcp_view` into the returned view and sets the snapshot's copy to null, so the deferred deinit of the snapshot does not free it. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- `resolveLiveToolActionFor` takes a fresh authority snapshot for every call, so the child's admitted tools and integrations bound each decision. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- `HostedRelease.release` sets its event before decrementing the count, because a waiter that reads zero may free the `HostedRelease` at once. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- `TurnContext.deinit` releases `hosted_release`, so a turn holds its child agent until the turn context is deinitialized. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- A hosted `TurnContext` has no child session, so `beginTurn` does nothing for it. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- `commitFailed` drops a child turn whose prepare or commit fails and traces the stage and the underlying error, which the returned error hides; this applies to every child turn. (`/workspace/fx/fx/src/core/subagent/execution.zig`)
- `Runtime.create` recovers abandoned child work (`managed.recoverInterrupted`) before it returns. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `rebindHost` must be called whenever the host context moves, because a report sink left on the old context would post into freed memory. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `closeTree` makes works that end afterwards owe no report, so it must run before their turns are cancelled; `noteQuitting` must run before fx quit stops any child. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `awaitMailOrQuiet` rechecks its cancel flag every 50 ms, so a signal handler can set the flag without waking anything. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- Mailbox trace lines name a root owner `main`; a subagent owner is named by its own id. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `resumeReports` posts the reports that the parent's log still owes, oldest first, and must run after the report sink is in place. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- When a busy child's next turn starts, all of its waiting messages join that one turn as one work, separated by blank lines. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- A turn that the user starts on a child's own screen is recorded as a work with an `fxuser:` id, and that work owes the parent a report only under the `every_turn` rule or when it fails, is interrupted or is lost. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- A user's stop on a child's screen drops the parent's messages waiting for that child at once. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `closeChild` writes the close to the parent's log only once no work of the child is still running. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- A creation-time model override is resolved against the model catalog before the child session exists, and only for the gateway provider; other providers pass the raw name through. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- `lost_result` is the report for work that a crash lost before the child started it; it says the work never ran and may be sent again. (`/workspace/fx/fx/src/core/subagent/tool_host.zig`)
- A message with instructions to a running or awaiting-approval persistent child is rejected, while a plain message steers that child; one-off children take no messages. (`/workspace/fx/fx/src/core/subagent/model_contract.zig`)
- `matchCatalogModel` matches an exact case-insensitive catalog ID first, reports tied best substring matches as ambiguous, and lists at most `max_model_match_candidates` close candidates. (`/workspace/fx/fx/src/core/subagent/model_contract.zig`)
- `Provider.execute` returns a `Result` whose body the caller frees with the allocator it passed in. (`/workspace/fx/fx/src/core/subagent/tool_provider.zig`)
- A provider must not keep the request pointer after `execute` returns, because the caller owns the request. (`/workspace/fx/fx/src/core/subagent/tool_provider.zig`)
- Report text is built from a fixed header, and the child's output passes through the same output limits as a tool result before it is sent. (`/workspace/fx/fx/src/core/subagent/reports.zig`)
- A child's `Rule` decides when it reports on its own: failed, interrupted or lost work always reports; `final` and `every_turn` report work that the parent or the child's own child started; `every_turn` also reports turns the user started; `never` reports only failures. (`/workspace/fx/fx/src/core/subagent/reports.zig`)
- A parent stop never produces a report of its own, because the parent's stop call already answers it. (`/workspace/fx/fx/src/core/subagent/reports.zig`)
- `PendingFold` counts a finish as owed when its data says `report: true`, or when crash repair closed a work this fx started with a report rule; a finish of work an older fx started owes nothing. (`/workspace/fx/fx/src/core/subagent/reports.zig`)
- `Pending` borrows its strings from the report lines, which must outlive the fold. (`/workspace/fx/fx/src/core/subagent/reports.zig`)
- A slot runs a child's works one after another on one thread: the end hook returns true when it installed the next work, and the slot stays running until no next work is installed. (`/workspace/fx/fx/src/core/subagent/managed_owner.zig`)
- A hosted slot uses the child agent's own worker, so stopping its turn only cancels the turn and leaves the worker running. (`/workspace/fx/fx/src/core/subagent/managed_owner.zig`)
- Whether a work's end owes its parent a report is decided by `reports.reportable` under the child's report rule and starter, and after `closeTree` no work owes a report because nobody is left to take one. (`/workspace/fx/fx/src/core/subagent/managed_owner.zig`)
- A user's stop on a child's screen records `user_stop` as the cancel cause, and an fx quit records `fx_quit` only when no user stop applies. (`/workspace/fx/fx/src/core/subagent/managed_owner.zig`)
- Parent messages that an ended turn never took become leftover works, and they are dropped when the turn was stopped by the parent or the user, the owner or slot is closing, the tree is closed, or fx is quitting. (`/workspace/fx/fx/src/core/subagent/managed_owner.zig`)
### src/core/session_manager

- I/O failures reach callers as `IoFault` with the OS cause (NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig) when it is known, and as `Io` otherwise (design record D29). (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- A child session takes the id that its parent's `child_spawned` line names (D34), a root always gets a fresh id, and a taken id makes the first turn's publish fail while leaving the existing session unchanged. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- The session picker resumes through `resumeSessionWithoutWaiting`, which passes a lock wait of 0, so a session open elsewhere shows as busy at once (D38). (`/workspace/fx/fx/src/core/session/session_adapter.zig`)
- `Manager.init` does no disk I/O and the sessions root opens on first use; the Manager must outlive every Session. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- Every Session must be closed and released before `Manager.deinit`. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `setTracing` and `setFault` do nothing unless storage hooks are compiled in, which only the session manager hook test module does (`build.zig`). (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- An index update that fails after a successful session change is reported as `index_stale` and never fails the change. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `Session.release` closes a still-open session and frees it, so no other thread may use it afterwards. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `openNew` keeps the new session in memory, and nothing touches disk until its first turn (D2). (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `openFork` copies the source only up to a turn boundary (D5) and never changes the source; with `at = .last_good` a damaged source forks up to its last good turn (D15), while a `.turn` point past the damage fails with `InvalidForkPoint`. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `openImport` returns `Exists` when the id is taken or was ever deleted, because a removed id must never come back. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `discardImport` removes only the `.tmp` staging of an abandoned import and never touches a published session (D59, D61). (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `appendAt` is valid only on an import before `publishImport`, and `publishImport` makes the whole import visible at once. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- Publishing a session records it as opened by its creating host, and a resume records it for the resuming host, so `-c` finds it; other index updates leave open times alone. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `blobPath` checks only that a blob file exists and returns its path for tools that open files by path (D49), while `getBlob` checks the bytes against the hash. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- The `language` setting must be a JSON string of 1 to 24 bytes once decoded (D18). (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- Hosts may interrupt a turn only with `cancel` or `failed`; the `closed` and `crash` interrupts and the `lost` child outcome are accepted only on import. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- Child `data` is capped at `max_child_data_bytes` (4 KiB) because snapshots fold the data of every child. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- Stored JSON may not have leading or trailing whitespace, so a reader gets back exactly the bytes that were stored. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `delete` removes a session's owned children before the session itself, and stops with `Busy` at the first open session in the tree, so children removed before that point stay removed. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `peek` reads a saved session's state without taking its lock, reads complete lines only, and leaves any torn tail in place. (`/workspace/fx/fx/src/core/session_manager/api.zig`)
- `title` and `language` are written into the index as raw JSON without re-encoding, so they must already be valid JSON strings. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- Resume writes a whole `put` record rather than an `opened` record (D42), though `opened` records are still folded when read from older indexes. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `plainTimes` accepts only the plain `[t,t,...]` form and returns null otherwise, so the caller falls back to the JSON parse with the same result. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- A tombstone is final: a later `put` for a deleted id is ignored when the index is folded. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `Catalog.load` reads the index without the index lock, which is safe because appends only add lines (cutting any torn tail first) or the file is replaced whole by rename, so a reader sees whole lines plus at most one torn line. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- A listed root session whose folder has disappeared is tombstoned and skipped, so the index heals itself. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `Catalog.rebuild` keeps the tombstones from the old index, so a deleted id stays deleted after a rebuild. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `writeFresh` replaces the index atomically, and its caller must hold `index.lock`. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `healIfGone` checks only that the session folder exists, not its log, because a published folder always holds its synced log (publish renames it in whole and delete renames it away). (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `sweep` removes every `.trash` entry and every `.tmp` entry older than one hour, since a younger `.tmp` entry may be a publish still in progress. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- `index.lock` is opened once for the manager's life and is never removed; its flock excludes other processes, its mutex excludes this process's threads, and a crash releases both. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- An append rewrites the index to one line per id only when it exceeds `index_compact_bytes` and twice its baseline, and then only if at least half its bytes are stale, so each fold is paid for by appended bytes. (`/workspace/fx/fx/src/core/session_manager/catalog.zig`)
- A complete line that fails its checks is torn only when nothing follows it; otherwise the scan reports corruption. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- `Log.open` reads only the file tail, bounded by three maximum-size lines plus a block, so its cost does not grow with the log; a writable open cuts a torn tail. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- `Log.append` writes a batch with one call, and `sync` is the durability point for every line appended so far. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- `lastLineEnd` returns the end of the last complete line, so readers never read a line that a writer is still writing. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- `ForwardReader` stops quietly at a torn final line (a bad line ending at its limit, or an unterminated tail), and returns `Corrupt` with `damaged_at` set for any other bad line or sequence gap, even the last one. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- `Line.bytes` is borrowed until the next call to `next`. (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- The log model harness caps runs at `max_lines` = 48 (`log.zig:838`), below the `MaxLines` = 64 in `tests/tla/session_manager/trace/SessionLogTrace.cfg`, which bounds the traces it checks (`trace/README.md:147`). (`/workspace/fx/fx/src/core/session_manager/log.zig`)
- A header whose version is newer than the one fx writes makes the session fail to open with `UnsupportedVersion`. (`/workspace/fx/fx/src/core/session_manager/schema.zig`)
- The session manager owns the set of line kinds and never interprets fx content in `data` or `value`; it only checks that they are valid JSON. (`/workspace/fx/fx/src/core/session_manager/schema.zig`)
- A header whose kind this version does not know still parses, with its name kept in `kind_name`. (`/workspace/fx/fx/src/core/session_manager/schema.zig`)
- `Fields.splitObject` is a fast path that falls back to the strict parser on anything unusual, so results never differ. (`/workspace/fx/fx/src/core/session_manager/schema.zig`)
- `fastValue` returns null for any value it does not decode plainly, which defers to the full parse. (`/workspace/fx/fx/src/core/session_manager/schema.zig`)
- A fork owns none of its source's children, since child lines at or before the fork seq belong to the source. (`/workspace/fx/fx/src/core/session_manager/fold.zig`)
- `plan` takes the state read-only and returns `InvalidTransition` without changing the caller's state; the manager assigns turn numbers, not the host. (`/workspace/fx/fx/src/core/session_manager/fold.zig`)
- `specValid` mirrors `Valid` in `tests/tla/session_manager/TurnLifecycle.tla`, so the spec and the code must change together. (`/workspace/fx/fx/src/core/session_manager/fold.zig`)
- `Event.session_id` is borrowed for the duration of the sink callback and is empty for root-wide events. (`/workspace/fx/fx/src/core/session_manager/diag.zig`)
- `opened_read_only` is reported at the damaged offset just before open fails with `Corrupt` or `UnsupportedVersion`, so no partial session is returned. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Blobs are created with mode 0400 (`createReadOnlyFile`), which blocks ordinary writes but not the owner's chmod or root, and a tool may open a blob by path. (`/workspace/fx/fx/src/core/session_manager/storage.zig`)
- `closeDerived` closes the index without syncing; a crash may lose its tail, and a rebuild re-derives it. (`/workspace/fx/fx/src/core/session_manager/storage.zig`)
- Folders that will be listed or synced are opened with iterate set, because a path-only handle cannot be fsynced on Linux. (`/workspace/fx/fx/src/core/session_manager/storage.zig`)
- `tryLock` takes a non-blocking exclusive flock, which the kernel releases when the process exits. (`/workspace/fx/fx/src/core/session_manager/storage.zig`)
- Every name passed to `Storage` must be one path component (non-empty, no slash, not `.` or `..`), enforced by assertion. (`/workspace/fx/fx/src/core/session_manager/storage.zig`)
- An append returns only after the fsync when its batch holds a durable-class event: a turn commit or interrupt, a child spawn or finish, or a `permissions`, `usage` or `moved_files` setting. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `putBlob` returns a blob's hash only after the blob file and its name are synced, and storing bytes that already exist costs one stat. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `putBlobFile` copies its source in 256 KiB chunks, so a large body is never held whole in memory. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Every blob that an item or setting refers to must already exist in the session before its line is written. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `readBlob` checks the bytes against the hash, so a damaged blob is reported and never returned; `blobExists` only stats the file. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `readPage` by id reads without the session lock and returns only complete valid lines, so a concurrent writer cannot disturb it. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- A page marked damaged stopped at a damaged line, so nothing after that line can be trusted. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `openFork` never changes its source; with `.last_good`, a damaged source forks up to its last good turn, and every source blob is hard-linked into the fork, copied when a link is refused. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Fork copies log lines byte for byte so their checksums hold, except snapshots, which are re-encoded from the fork's own fold because they record byte offsets. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `trashSession` refuses with `Busy` while the session is open anywhere, and the children of a session are trashed before the session itself. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `verifySession` checks every line's frame, checksum and seq, and each snapshot against the fold at its position, because a snapshot is only a cache. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `onDisk` is false for a session whose first publish failed, even though that publish may have landed (D90). (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Before its first turn a session writes nothing: settings wait in memory framed from seq 2, and any held lines dropped at close are reported as `held_lines_dropped`. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- The first turn and a fork publish through a staged `.tmp/{id}` folder, syncing the log and then the folder (which holds the lock file) before the rename into place, so a visible session always has a durable first line. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- A session in the failed phase has unknown durability until it is reopened, and the first fault cause is kept (D40). (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Only the first sync failure is kept, and `syncThrough` runs outside the session mutex so that appends from other threads continue during an fsync. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- A snapshot that does not fit in one line is skipped and reported as `snapshot_skipped`, and never fails the append whose batch is already written. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- The batch is written with one append whether or not an observer is attached; an observer only receives a `wrote_line` event per line afterwards. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `destroy` requires a closed session that no other thread still uses. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `abandon` releases the lock and files without writing anything, as a crash would; it is used when a resume fails midway and by crash tests. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `openResume` reads the header, the newest snapshot and the tail after it, so its cost does not grow with the session's age; a child session resumes only with the parent it was created under. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- Child lines at or before the fork seq belong to the fork's source, so a snapshot at or before it has its children cleared on load. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- An import's batches wait in memory until `publishImport` stages them together, so nothing of an import is visible before the publish. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `SeqCell` is a plain 64-bit atomic only where `usize` is 64 bits; on 32-bit targets such as the wasm build it uses a brief lock instead. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `Session.state`, `staged`, `updated_ms` and `fault` are guarded by the session mutex, and `written_seq` is written under that mutex and read under `sync_mutex`. (`/workspace/fx/fx/src/core/session_manager/session.zig`)
- `staysHeld` may answer stale, which is harmless because a publish always opens the root first (D2). (`/workspace/fx/fx/src/core/session_manager/session.zig`)
### src/core/session

- The session adapter moves a piece larger than 256 KiB into a blob, since a log line is capped at 4 MiB. (`/workspace/fx/fx/src/core/session/session_adapter.zig`)

### src/core/app

- A cooperative App host starts no agent worker thread, so queued prompts must be driven through `processNextCooperativePrompt`. `src/core/app/app_process_runtime.zig`
- The provider context and the renewal transport context must outlive a started lookup, because the fetch runs in a background `std.Io` task. `src/core/app/credits_lookup.zig`
- `Result.renewed` is passed to `adoptRenewedCredential`, which clones it, and `Result.deinit` frees it unconditionally, so the caller does not take ownership. `src/core/app/credits_lookup.zig`, `src/core/app/app_commands.zig`
- The `Credential` returned by `credential` and `fromCredential` borrows its strings from the auth runtime or the source credential, and its label from `label_buf`, so those must stay alive while it is used. `src/core/app/usage_host.zig`
- `adoptOwned` is a no-fail publication step: fallible preparation of the owned model must finish before the call, which takes ownership of the slice. `src/core/app/provider_runtime.zig`
- The model slice returned by `selection` is borrowed until the next mutation or deinit. `src/core/app/provider_runtime.zig`
- `gateway_http_pool` is heap-allocated so its pointer survives copies of the Runtime by value; it stays null when allocation fails, and the callers in `src/main.zig` check for null. `src/core/app/provider_runtime.zig`
- `StartupState` owns its copy of `provider_order` (freed in its deinit), so the borrowed launch-argument slice is duplicated on apply. `src/core/app/app_lifecycle.zig`
- `applyLaunchMode` seeds the main agent's permission mode from the launch profile, and callers must run it after `applyLaunchProfile`. `src/core/app/app_profile_runtime.zig`
- `pollLoadTransition` adopts a staged catalog revalidation and refreshes an open model menu, so catalog ids borrowed from the cache must not be held across the call. `src/core/app/model_cache_runtime.zig`
- `adoptOwnedCatalog` takes ownership of the caller's catalog list and leaves it empty, cancelling and joining any running fetch and discarding a staged result before it installs the catalog. `src/core/app/model_cache_runtime.zig`
- Ids returned by `modelCompletions` borrow the catalog's storage and stay valid only until `pollLoadTransition` or `adoptOwnedCatalog` replaces the catalog. `src/core/app/model_cache_runtime.zig`
- The API-key label in a `ColumnBuffer` points into the buffer's own `field` array, so the buffer must stay in place while its labels are read. `src/core/app/provider_picker_runtime.zig`
- The group names returned by `staleGroups` borrow from the `records` argument, so `records` must outlive those names. `src/core/app/host_record.zig`
- `Restore.others` is allocated by `chooseRestore` and freed by `Restore.deinit`, but its ids and profiles borrow from the records passed in. `src/core/app/host_record.zig`
- `setMode` never writes the persisted preference, and for a subagent it sets only that subagent's own mode under `authority_mutex`. `src/core/app/app_permission_runtime.zig`
- `initMode` sets the mode without taking `authority_mutex`, so it is for startup and launch-profile setup, before the instance's worker runs. `src/core/app/app_permission_runtime.zig`
- `viewOf` returns a `PermissionEngine` that shares the owner's grant list buffer and the app's rules, so calling `deinit` on the view would free storage still in use. `src/core/app/app_permission_runtime.zig`
- `startRemoteRevocation` moves the pending revocation out and leaves the caller's slot null, so the caller's release skips it; the revocation then runs off the input loop, and a refused start writes a warning. `src/core/app/app_auth_runtime.zig`
- The model picker's draft is stashed in `model_picker_draft`, and `settleModelPickerDraft` restores it once neither the model menu nor a model query owns the composer. `src/core/app/app_input_runtime.zig`
- The saved SIGTERM and SIGHUP actions are written only by `installAbnormalExitHandlers` and restored at shutdown, never from signal context. `src/core/app/app_lifecycle.zig`
- The close signal handler does one atomic compare-exchange and one `write(2)` to `close_pipe`, and the closer thread then marks the in-flight request as a clean close, so the next launch resumes it without counting a crash (`NoFalseCrashQuestion` in `tests/tla/recovery/Resume.tla`). `src/core/app/app_lifecycle.zig`
- The abnormal-exit handlers stay async-signal-safe: `abnormalExitHandlerWithRestore` calls only `write(2)`, `sigaction(2)` and `raise(3)`, and its restore sequences are compiled in. `src/core/app/app_lifecycle.zig`
- `installAbnormalExitHandlers` covers only SIGTERM and SIGHUP and does nothing without `shell_runtime.supports_resize_signal`, because interactive raw mode clears `ISIG`, so the terminal generates no SIGINT. `src/core/app/app_lifecycle.zig`, `src/ui/shell_runtime.zig`
- `resolveSettings` is shared by session startup and the `fx config` path, so both read settings the same way, and callers must set `agent_step_limit` to the default and `model_source` before calling it. `src/core/app/app_lifecycle.zig`, `src/core/cli/cli_surface.zig`
- The MCP host lifecycle is modeled in `tests/tla/mcp_host/HostLifecycle.tla`. `src/core/app/app_mcp_runtime.zig`
- `host_mutex` guards the host pointer, the lease counts, and the retired flag, and only `stop` runs after the lock is released. `src/core/app/app_mcp_runtime.zig`
- `handoff_alloc` is `std.heap.c_allocator` because hand-off entries are created on subagent threads and freed on the main loop, so the allocator must be thread-safe. `src/core/app/app_agents_runtime.zig`
- `postDelivery` returns `AgentGone` once `Handoffs.closed` is set at shutdown, and frees the report it created, so the poster never waits on the main loop. `src/core/app/app_agents_runtime.zig`
- A `ChildAgent` is normally freed only after its `bound` `HostedRelease` is released, because slot threads keep a pointer to `child.bound`; `deinitChildren` frees it after a bounded wait even if it is still held. `src/core/app/app_agents_runtime.zig`
- A subagent whose parent's permission mode cannot be resolved falls back to `ask`, so the child never runs looser than its parent. `src/core/app/app_session_runtime.zig`
- The newest turn left unfinished by a crash or close is noted and sent again as fx's resume note, and the recovery module decides whether it goes at once or asks first (`AutoResumes` in `tests/tla/recovery/Resume.tla`). `src/core/app/app_session_runtime.zig`
- A saved request older than the recovery threshold, or dated ahead of the clock beyond a small slack, asks before it is sent again (`OldAsks` in `tests/tla/recovery/Resume.tla`). `src/core/app/app_session_runtime.zig`
### src

- The process-exit shutdown joins the subagent child threads and the main worker thread, but the upgrader, file index and other background threads are only signalled to stop, so `app` must stay valid until process exit. `src/main.zig`
- On WebAssembly, `rebindAfterInit` replaces the usage host with `usage_host.cooperativeHost`, which stores the app's address, so the swap must happen after `App.init` has placed the app at its final location. `src/main.zig`
- `stopChildren` runs before the main worker thread is joined in the process-exit shutdown, because the main worker can be waiting on a subagent call. `src/main.zig`

### src/core/agent/presentation

- A table or code block sink takes ownership of its payload only when its `deliver` callback returns successfully, so the caller guards the payload with an `errdefer` on a `delivered` flag. Source: `/workspace/fx/fx/src/core/agent/presentation/payload.zig`
- `packedWordHash` only filters candidates, and `inPackedList` compares the exact bytes after a hash match, so a hash match alone must not be treated as a word match. Source: `/workspace/fx/fx/src/core/agent/presentation/code_highlight.zig`
### src/core/agent

- `question_answer.max_questions` (20) is the upper bound `decodeJson` enforces on `ask_user_question` answer arrays, while the tool schema advertises `max_tool_questions` (4) instead. Source: `/workspace/fx/fx/src/core/agent/question_answer.zig`
- Strings returned by `decodeJson` point into the output buffer or the arena, so both must outlive the returned answers. Source: `/workspace/fx/fx/src/core/agent/question_answer.zig`
- `link_id_counter` numbers OSC 8 links as `fx-N`, so a link that wraps onto another terminal row does not share an id with its neighbour, since terminals join segments that share an id. Source: `/workspace/fx/fx/src/core/agent/assistant_presentation.zig`
- `handleModelLine` sends every model line through `text_utils.appendTerminalSafeText`, so control bytes and C1 controls show as visible text and a reply cannot clear the screen or switch screens. Source: `/workspace/fx/fx/src/core/agent/assistant_presentation.zig`
- `Admission.admit` must be called exactly once, after request serialization and validation succeed and immediately before delivery of the request can begin. Source: `/workspace/fx/fx/src/core/agent/stream_provider.zig`
- `ProviderAttemptOwner` names the one layer that owns retries, so a model attempt owned by the agent is not retried again by the transport. Source: `/workspace/fx/fx/src/core/agent/stream_provider.zig`
- `Result.dupe` returns a fully owned copy, including diagnostics, that is released with `deinit` on the same allocator. Source: `/workspace/fx/fx/src/core/agent/stream_provider.zig`
- `carryContextNotes` attaches each context note to the end of the last tool result before it, so rules reach the model without a system message inside the conversation (design decision D93). Source: `/workspace/fx/fx/src/core/agent/stream_provider.zig`
- `setProviderRouting` copies the provider order into memory the worker owns. Source: `/workspace/fx/fx/src/core/agent/worker_runtime.zig`
- `takeQueuedPrompt` is the path for hosts that run turns themselves, as the `fx ask` CLI does, and the caller owns the prompt it returns. Source: `/workspace/fx/fx/src/core/agent/worker_runtime.zig`
- A steer interrupts the model stream immediately only when no steering wait boundary is active, and otherwise its delivery waits for the next boundary. Source: `/workspace/fx/fx/src/core/agent/worker_runtime.zig`
- `popQueuedSteerForEdit` returns null unless a turn is active and a steering wait boundary exists, because an immediate steer is already committed to its interrupt. Source: `/workspace/fx/fx/src/core/agent/worker_runtime.zig`
- `awaitsPermissionDecision` reports, under `worker_mutex`, whether a permission request is waiting for a decision. Source: `/workspace/fx/fx/src/core/agent/worker_runtime.zig`
### src/core/agent/runtime

- A `reconcile_tool` resend sets `tool_choice` to `none`, so no tool can run during reconciliation. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- `tool_result` is emitted after the result is appended to the engine's conversation, so it is not a durable-write receipt. Source: `/workspace/fx/fx/src/core/agent/runtime/observation.zig`
- `permission_start` and `permission_end` bracket the whole permission evaluation, which is not always a human wait. Source: `/workspace/fx/fx/src/core/agent/runtime/observation.zig`
- `step_index` resets at each step end, and `next_model` and `next_operation` are per-observer counters, so these ordinals are execution-local and must not be stored as durable operation IDs. Source: `/workspace/fx/fx/src/core/agent/runtime/observation.zig`
- `runBatchAttempt` takes the verified image snapshots the caller already checked, so a retry does not reopen source paths or re-authorize them. Source: `/workspace/fx/fx/src/core/agent/runtime/vision_executor.zig`
- The parsed schema of a selected dynamic tool is allocated in the `alloc` passed to `recordSelectedDynamicTool`, which must outlive every step that advertises the tool. Source: `/workspace/fx/fx/src/core/agent/runtime/gateway_step.zig`
- `text_tokens` in `RequestCost` is an uncalibrated serialization estimate that real provider usage can replace. Source: `/workspace/fx/fx/src/core/agent/runtime/prompt_context.zig`
- `identical_failure_escalation` is an optional pointer, and null disables escalation for callers that have no turn-scoped tracker. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_batch.zig`
- `LiveToolAuthority` is a borrowed value refreshed immediately before one tool action, and it is resolved only when `deps.live_tool_authority` is set. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_contracts.zig`
- `root_user_intent_context` is borrowed root-user evidence for subagent execution, and `main.zig` copies it from the active child run. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_contracts.zig`
- `authorized_image_catalog` is owned by the caller, so an executor must not keep the slice or any attachment pointer from it. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_contracts.zig`
- `current_turn_messages` is borrowed execution evidence, so the owning agent loop must keep it alive until the turn is committed. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_contracts.zig`
- `Outcome.text` and `failed.detail` are allocated with the caller's allocator, and `detail` is in `key=value` form, with secrets masked on the provider path. Source: `/workspace/fx/fx/src/core/agent/runtime/text_completion.zig`
- `Request.conversation` repeats the conversation's messages, instructions, tools and tool choice unchanged so the provider can reuse its cache, and `system` is not sent. The conversation is borrowed. Source: `/workspace/fx/fx/src/core/agent/runtime/text_completion.zig`
- `CompactorCaller.caller` returns a model caller that points at `self`, so the `CompactorCaller` must outlive the compaction. Source: `/workspace/fx/fx/src/core/agent/runtime/text_completion.zig`
- `captured_runtime_context` is carried by every save of a turn, so a streamed turn keeps one prefix (design decision D94, referenced by `runtime/tests/tool_flow.zig`). Source: `/workspace/fx/fx/src/core/agent/runtime/finalization.zig`
- `recordModelCall` traces a record it cannot copy or append as `dropped=saved_call_record` and skips it, so only the Ctrl+O view is affected. Source: `/workspace/fx/fx/src/core/agent/runtime/finalization.zig`
- `Agent` holds only provider-neutral conversation state, and its fields carry no session, credential or permission data. Source: `/workspace/fx/fx/src/core/agent/runtime/agent.zig`
- `request_token_calibration` survives across turns and is cleared by `clearHistory`, `restoreHistory`, a compaction install (orchestrator.zig sets it to null after compaction) and a store for an unmatchable model id, so the first request of a new turn can calibrate from real provider usage. Source: `/workspace/fx/fx/src/core/agent/runtime/agent.zig`
- `restoreCheckpoint` returns a `Meta` that the caller frees with `Meta.free`. Source: `/workspace/fx/fx/src/core/agent/runtime/agent.zig`
- `IdenticalFailureEscalationState` is kept per turn rather than per batch, so repeated failures are counted across steps that each run a single call. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_admission.zig`
- `record_tool_call_failed` is separate from `record_tool_call_rejected`, so content and preflight failures are not reported as permission rejections. Source: `/workspace/fx/fx/src/core/agent/runtime/tool_admission.zig`
- `Timing.claude` uses Anthropic's five-minute default cache lifetime and stops warming at a 30-minute cap. Source: `/workspace/fx/fx/src/core/agent/runtime/cache_warming.zig`
- A ping is planned a tenth of the lifetime before expiry, and a wake more than half of that margin late (15 seconds for Claude) stops warming instead of pinging an entry that may have expired. Source: `/workspace/fx/fx/src/core/agent/runtime/cache_warming.zig`
- `skipReason` skips warming for budget-based thinking, because a one-token ping could still spend the thinking budget. Source: `/workspace/fx/fx/src/core/agent/runtime/cache_warming.zig`
- `Warmer.create` allocates from `std.heap.c_allocator` because the warmer and its task outlive any caller scope. Source: `/workspace/fx/fx/src/core/agent/runtime/cache_warmer.zig`
- `pingBody` sets the top-level `maxOutputTokens` to 1 and leaves every other byte unchanged, so the ping matches the cached prefix, and it returns null for a body that is not one JSON object. Source: `/workspace/fx/fx/src/core/agent/runtime/cache_warmer.zig`
- `default_max_request_bytes` is 30 MiB, below the 32 MiB body limit that Claude routes reject. Source: `/workspace/fx/fx/src/core/agent/runtime/request_image_budget.zig`
- `default_max_request_images` is 100, the per-request image limit for Anthropic models. Source: `/workspace/fx/fx/src/core/agent/runtime/request_image_budget.zig`
- `blockCut` rounds the withheld cut up to a block end, where a block holds a quarter of `max_images` or of `max_request_bytes`, so the oldest withheld image does not move on every request. Source: `/workspace/fx/fx/src/core/agent/runtime/request_image_budget.zig`
- `withholdImagesPastLimit` decides what to withhold from the image sizes before building the request, so the request is never built with every image encoded at once. Source: `/workspace/fx/fx/src/core/agent/runtime/request_image_budget.zig`
- `LiveToolAuthorityProvider` returns slices that borrow the allocator it is given, which must stay alive through permission admission and tool execution. Source: `/workspace/fx/fx/src/core/agent/runtime/deps.zig`
- `request_prepared_file_mutation_permission` consumes the prepared value, so callers must not replay that value through the raw permission callback. Source: `/workspace/fx/fx/src/core/agent/runtime/deps.zig`
- `expectReplyablePromptTail` fails a model request whose prompt ends on an assistant message, and, unless `allow_continuation` is set, a user tail carrying `assistant_tail_continuation_prompt`. Source: `/workspace/fx/fx/src/core/agent/runtime/tests/support.zig`
- A compaction notes request repeats the agent's tools section, so the provider can reuse its cache. Source: `/workspace/fx/fx/src/core/agent/runtime/tests/gateway_flow.zig`
- Waits tick every `wait_tick_ms` (100) rather than every `tick_ms` (1000), so jittered waits are not all rounded up to the same whole second. Source: `/workspace/fx/fx/src/core/agent/runtime/request_recovery.zig`
- `unreadable_replies` is touched only by the request's own thread, and `registry_node` is guarded by `registry_mutex`, not by the request mutex. Source: `/workspace/fx/fx/src/core/agent/runtime/request_recovery.zig`
- `start` returns the first send, or null when the module must ask the user first. Source: `/workspace/fx/fx/src/core/agent/runtime/request_recovery.zig`
- `closeActive` writes a clean record for every registered request and waits at most `close_wait_ms` for each lock, so the next launch resumes those requests without counting a death. Source: `/workspace/fx/fx/src/core/agent/runtime/request_recovery.zig`
- `responding` is called from the transport's event callback, which cannot fail, so publication errors are traced rather than returned. Source: `/workspace/fx/fx/src/core/agent/runtime/request_recovery.zig`
- `max_safe_position` is 2^53 minus 1, the largest sequence or turn number a JavaScript host can hold exactly. Source: `/workspace/fx/fx/src/core/agent/runtime/journal.zig`
- Tool calls whose arguments arrive inside a `request` object are unwrapped to top-level arguments before use. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- Live MCP tools the model calls before loading them are advertised, so they reach normal MCP validation and permission instead of failing as unselected. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- Rules delivered for a tool call are queued as a context note that joins the turn after that step's results (design decision D93). Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- `persistFinalReplyCheckpoint` saves the final reply before the turn ends, so a crash before the end delivers the saved reply instead of asking the model again. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- `CompactionSource` saves the running turn through its `BeforeSummary` hook before automatic compaction sends anything, so a crash during compaction can recover the turn. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- `holdImagesToBlocks` rounds the withheld images up to a block end with `blockCut`, so the cached prompt keeps the same images until the cut reaches the next block. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- A conversation that ends on an assistant message is copied with a host continuation appended, because fx never asks a model to extend an assistant message. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- When fx cannot reach the model catalog at all, `catalogDownNotice` names the connection in one line first, since the same fault usually blocks the model request too. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`
- The catalog-down image line is matched by its wording, "aren't reaching the model", in `tests/tla/drivers/image_route/binary-to-spec.ts`, so changing that wording breaks the driver. Source: `/workspace/fx/fx/src/core/agent/runtime/orchestrator.zig`

### src/mcp

- `mcp.core` is public for the TLA labs under `tests/tla/drivers/mcp/labs`, which build against the `mcp` module from `src/mcp/mcp.zig`, while fx itself drives MCP through `mcp.engine` `src/mcp/mcp.zig`
- `next` scans servers from `cursor`, moves past the server it served, and returns events already queued before it scans, so one busy server cannot starve the others `src/mcp/engine.zig`
- `sweep` frees a retired server once the host has read its events and either it is no longer busy or 3.5 s (`3500` ms) have passed since it was retired. `deinit` closes every server and waits under the same limit `src/mcp/engine.zig`
- `wake` may be called from any thread and rings the bell so a waiting `next` returns early `src/mcp/engine.zig`
- `adoptCredential` loads a saved credential without starting the server, and `useCredential` starts it only after the adoption succeeds `src/mcp/engine.zig`
- `restoreCredential` asserts that no server object exists yet, so it must run before `signIn`, `finishSignIn`, `cancelSignIn`, `adoptCredential` or `signOut` creates one `src/mcp/engine.zig`
- A request that the auth gate gives up on for want of a sign-in ends as an HTTP 401, and a listen whose renewal fails ends as a broken stream `src/mcp/server.zig`
- `poll` reads at most 64 messages per call and rings the bell for the rest, so a fast server cannot starve other servers `src/mcp/server.zig`
- `reset` drops the HTTP connection and every request on it, and starts a new era run; for stdio it only stops the process `src/mcp/server.zig`
- `respond` takes one raw JSON answer per input request, in request order, and checks every elicitation answer before it accepts any of them `src/mcp/server.zig`
- An answer for an elicitation the table no longer holds is refused with `UnknownElicitation`, and content that fails the schema is refused with `InvalidAnswer` while the host still holds the elicitation `src/mcp/server.zig`
- A 2025 elicitation listed in a `-32042` error is asked only when it carries an `elicitationId` `src/mcp/server.zig`
- A server's `ping` gets an empty result, `elicitation/create` goes to the elicitation table, `roots/list` gets the workspace root when one is configured, and other server requests get `method_not_found` `src/mcp/server.zig`
- In a 2025 session, the `notifications/initialized` POST must end before any other send, and the session's requests wait until its first listening GET opens or `listen_wait_ms` (1 s) passes `src/mcp/server.zig`
- When a 2025 `initialize` times out, its stream is closed and the session fails with `initialize_timed_out` `src/mcp/server.zig`
- A refused stdio line that names an in-flight request fails that request with the reason, and any other refused line is passed to `keepStray` instead `src/mcp/server.zig`
- A listen ends gracefully only on a complete result, and any other answer refuses it `src/mcp/server.zig`
- `aux_base` (1 << 62) is the key base for requests nobody waits on, and request ids stay below it `src/mcp/server.zig`
- `useCredential` returns false without starting any auth step when `Auth.restore` rejects the saved credential `src/mcp/server.zig`
- An elicitation `parse` failure reaches the server as an unreadable request, which is answered with `invalid_params`, and in a 2026 input round it is reported as `malformed` `src/mcp/server.zig`
### src/mcp/io

- Trace writes must go through `trace.on`, which returns `null` at comptime unless the build is a test or the root declares `mcpv2_trace`, so the write is compiled out `src/mcp/io/trace.zig`
- Child writers pass each record to the root writer, which alone assigns sequence numbers, so one order holds across every server's child tracer `src/mcp/io/trace.zig`
- `trace.Writer` never flushes, so the owner of its underlying writer must flush it `src/mcp/io/trace.zig`
- `lines.read` clears the buffer first, so the returned `bytes` are valid only until the next read into that same buffer `src/mcp/io/lines.zig`
- An over-long line returns `too_long` with its first bytes in `bytes` and the rest unread, so a caller that stops never waits for a newline that may not come. `skipRest` reads through the next newline when the rest must be discarded `src/mcp/io/lines.zig`
- `SseLines` ends a line at a CR at once and skips a LF that arrives next, so an event ended by bare CRs is delivered without waiting for a LF that may never come `src/mcp/io/lines.zig`
- `SseLines.read` passes the new buffer size to `counter.grow` before it appends, so the byte budget counts the bytes first `src/mcp/io/lines.zig`
- A `Read` must end with `post` or `drop`, and an error from `grow` or `post`, such as cancellation, leaves it open, so the caller still calls `drop` `src/mcp/io/budget.zig`
- Only one reader at a time holds the large read, and the others wait in the `line` queue in arrival order `src/mcp/io/budget.zig`
- While a large read is in progress, a small `post` must leave `2 * allowance` bytes free for it `src/mcp/io/budget.zig`
- Posted messages are budgeted against `max_message` (16 MiB), but one message is always admitted when nothing else is counted `src/mcp/io/budget.zig`
- Posted bytes stay counted until the client's `poll` dequeues them and `giveBack` releases them `src/mcp/io/http.zig`
- A kept connection is not reused when the server has closed or reset it, which the client detects by unread bytes or a readable socket, and it is also dropped after `max_idle_ms` (60 s) of idleness, because a network can drop an idle connection without either end noticing `src/mcp/io/http.zig`
- The client asks only for `identity` encoding, so a compressed answer fails as unsupported instead of being parsed as JSON `src/mcp/io/http.zig`
- A `too_large` ending leaves the rest of the stream unread, and the request is not retried, because asking again would bring the same oversized message `src/mcp/io/http.zig`
- `Incoming` slices stay valid only until the next `next` or `poll` call, which frees the previous message's bytes `src/mcp/io/http.zig`
- `Host.log` is called synchronously from the stdio stderr reader task, so it must return promptly, because that reader reads no more stderr until the call returns `src/mcp/io/process.zig`
- `signalAllForExit` sets the `exiting` flag and sends SIGTERM to every stdio process at once, and a process that starts while the flag is set gets SIGTERM as it starts. It may be called from any thread `src/mcp/io/process.zig`
- The process-group helper is a `/bin/sh` started once in its own process group. When its stdin closes it sends SIGTERM to the groups it is still told about, then SIGKILL 2 s later, so fx's exit does not wait on it. The 2 s gap is a timing assumption that a freed pid is not reused that soon, and the code does not check it `src/mcp/io/process.zig`
- `everyone.mutex` is held while `signalAllForExit` calls `signal`, which takes `pid_lock`, so `pid_lock` must never be held while `everyone.mutex` is taken. `helper.tell` runs both with and without `pid_lock` held and takes only its own mutex `src/mcp/io/process.zig`
- If telling the helper about a process group fails, the helper is killed and never used again, so it cannot act on a stale group list `src/mcp/io/process.zig`
- A stdin send fails with `Full` when it would queue more than `max_line` bytes behind unwritten data, but one message of any size is still accepted `src/mcp/io/process.zig`
- The exit watcher waits at most 250 ms (`stderr_drain_ms`) for the stderr reader to reach the end of the pipe, so a child that keeps the pipe open cannot delay exit longer `src/mcp/io/process.zig`
- `Incoming` slices from `Process` stay valid until the next `next` or `poll` call, which frees the previous message's bytes `src/mcp/io/process.zig`
- `Process.init` stores `options`, so its slices must outlive the process, and `deinit` kills a running process without the polite steps, so call `stop` and wait for `stopped` first `src/mcp/io/process.zig`
- The exit status is stored under `pid_lock`, and callers read it with `exitStatus` `src/mcp/io/process.zig`
- Stdio backoff delays are shortened by the I/O layer to a random value between half and the full delay, so the core's `after_ms` is an upper bound `src/mcp/io/process.zig`
- `Client.init` parses `options.url` without copying it, so the URL bytes must outlive the client `src/mcp/io/http.zig`
### src/mcp/protocol

- `Parser.line` leaves `buf` as it is, so the caller takes or clears `buf` after each event, or the next event's data would start with old bytes `src/mcp/protocol/sse.zig`
- `Event.id` points into `Parser.last_id`, and the next valid `id:` line overwrites it, so a caller copies it before parsing another line `src/mcp/protocol/sse.zig`
- `Request.key` and `Round.state` keep their raw JSON string tokens with quotes, because `writeRetry` writes them back verbatim `src/mcp/protocol/mrtr.zig`
- `Round` slices point into the `result` buffer given to `parse`, so that buffer must outlive the round `src/mcp/protocol/mrtr.zig`
- `Page.next_cursor` keeps the raw JSON string token with its quotes, and the empty string `""` is a real cursor that differs from null `src/mcp/protocol/tools.zig`
- `List.reserve` must run before a tool is appended, so running out of memory never leaves a tool without an index entry `src/mcp/protocol/tools.zig`
- `Store.check_headers` is set per page from `!legacyEra()`, so the `x-mcp-header` check follows the protocol era rather than the transport. The first tool with an invalid annotation is kept in `first_bad`, which no production code in `src/mcp` reads yet `src/mcp/protocol/tools.zig`
- Client request ids start at 1 and never exceed `max_request_id` (2^53 - 1), the largest integer that a JavaScript number holds exactly `src/mcp/protocol/wire.zig`
- A response's `id` is kept only when it is a non-negative integer or a string of plain decimal digits, because some servers echo ids as strings. Otherwise it is null and the response cannot be matched `src/mcp/protocol/wire.zig`
- A missing `resultType` means complete, and an unknown one is `unrecognized`, which callers treat as invalid `src/mcp/protocol/wire.zig`
- `Writer` writes neither the line break nor a flush, so a caller writing a stdio message must add the newline that frames it and flush `src/mcp/protocol/wire.zig`
- `Elements` and `Fields` keep a scanner whose allocator points into their own stack buffer, so they must not move between `init` and the last `next` `src/mcp/protocol/wire.zig`
- `writeFailure` asserts that a code from -32000 to -32099 is one of -32022 to -32020, so a reserved code outside that set is refused in debug builds `src/mcp/protocol/wire.zig`
- `sendable` rejects header values with any control character other than tab, including every line break, so a header cannot split a request `src/mcp/protocol/http_headers.zig`
- A session id the client echoes must be visible ASCII and at most 1 KiB, and an invalid id from the server marks the session bad `src/mcp/protocol/http_headers.zig`
- An event id must be printable and at most 1 KiB, and an invalid one is not stored, so its stream cannot be resumed with `Last-Event-ID` `src/mcp/protocol/http_headers.zig`
- Form field keys, titles, descriptions, option strings and defaults are kept as raw JSON tokens with their quotes, so a consumer must write them back unchanged rather than quote them again `src/mcp/protocol/elicitation.zig`
### src/mcp/core

- A stdio connection starts only from `idle` or `stopped`, and starting from `stopped` resets its failure count, so a backoff never starts the process `src/mcp/core/stdio_conn.zig`
- Before detection ends, responses are accepted, because a legacy server can send requests such as ping during `initialize`, which the STDIO-09 rule requires the client to answer `src/mcp/core/stdio_conn.zig`
- `send` returns `NotRunning` or `ResponseNotAllowed`, and `start` returns `GenerationsExhausted`, before the connection changes `src/mcp/core/stdio_conn.zig`
- A request that a stdio process loses is ended by the `transport_lost` event, which `src/mcp/server.zig` sends for each affected request when the process is lost (`onProcessChanged`) `src/mcp/core/request.zig`
- The elicitation table emits no answer for an elicitation listed in a `-32042` error, because only `Origin.request` emits a `send` effect `src/mcp/core/elicitation.zig`
- A request the table cannot read, or whose mode is undeclared, is rejected with JSON-RPC `-32602`, and a readable, declared request that finds all 16 slots held is rejected with `-32603`, as `src/mcp/server.zig` maps the two `Reject` values `src/mcp/core/elicitation.zig`
- Slots are reused, so an `Id` pairs a slot with a number `n`, and `Table.find` matches both, so an answer for an elicitation whose slot was freed and reused is ignored `src/mcp/core/elicitation.zig`
- A URL elicitation whose completion arrives while the host still shows it is remembered, and its `complete` effect is emitted once the host accepts `src/mcp/core/elicitation.zig`
- `Catalog.step` returns `NotReady` or `Listing` before it changes any catalog state, so a rejected event leaves the catalog unchanged `src/mcp/core/catalog.zig`
- A new server process cannot start while a listing runs (`StepError.Listing`), and the stdio connection reports `lost` when a process exits, which ends the in-flight page request `src/mcp/core/catalog.zig`
- Callers must pass `now_ms` from a clock that never goes back, since the lapse check and the `u32` expiry delay computed in `finish` depend on it `src/mcp/core/catalog.zig`
- An `invalid_cursor` restarts the listing once. `restarts` resets when a `need` starts a new listing, so each listing gets its own restart `src/mcp/core/catalog.zig`
- A failed listing serves the last good list (`serve_last`) when one is cached and otherwise fails, and it never marks the cache fresh, so the next `need` lists again `src/mcp/core/catalog.zig`
- `max_calls` is 24, below the 32 logical request slots in `src/mcp/server.zig`, so listing, listen and detection can always find a slot `src/mcp/core/engine.zig`
- `Gate.step` returns `TooManyCalls` without changing state when an allowed call finds every call slot in use and the server is not failed `src/mcp/core/engine.zig`
- `traceKey` keeps trace keys below 2^31 for TLC, whose integers are 32-bit, by folding keys of 2^30 and up into the range from 2^30 to 2^31 `src/mcp/core/auth.zig`
- Issuers are numbered 1 to `max_issuers` (31), so their masks fit the bits the 32-bit trace integers allow `src/mcp/core/auth.zig`
- The authorization response counts as checked only when its `iss` matches, or when it is absent and the server does not advertise `iss` support `src/mcp/core/auth.zig`
- Over HTTP, a 404 with `-32601` marks a modern server without discovery, per rule HTTP-12 in `tests/tla/mcp/rules.md` `src/mcp/core/era.zig`
- An `initialize` error counts as a modern hint when its code is -32020, -32021 or -32022, or when its `supported` list or message names a preferred version `src/mcp/core/era.zig`
- Probe timers are never cancelled. A timer for an earlier probe is ignored because its number differs from the current probe `src/mcp/core/era.zig`
- A 404 on a request with a session id starts a new `initialize` only when it names the current session and no re-initialize is under way, following LHTTP-02 `src/mcp/core/http_legacy.zig`
- A `too_large` answer over the message limit ends the request as `lost`, because resuming would bring the same answer, per LHTTP-11 in `tests/tla/mcp/rules.md` `src/mcp/core/http_legacy.zig`
- Only idempotent requests are posted again after a broken stream, up to `max_attempts`. A `tools/call` whose stream breaks, or whose answer is too large, is delivered as `lost` with `maybe_ran` set `src/mcp/core/http_modern.zig`
- Over modern HTTP, a `-32020` answer to a `tools/call` is a mismatch, and the exchange relists and posts the call once more, delivering a second mismatch as a failure `src/mcp/core/http_modern.zig`
- `too_large` is the message-limit case of spec rule HTTP-14 in `tests/tla/mcp/rules.md`, and it is delivered as `lost` `src/mcp/core/http_modern.zig`
### src/mcp/auth

- `refusal` allows only HTTPS, or HTTP to a loopback host, and refuses an internal-address URL (private, link-local or metadata) unless both it and the MCP server are on loopback `src/mcp/auth/discovery.zig`
- `resourceAllowed` accepts resource metadata only when its `resource` has the server's origin and a path equal to the server's path or a whole-segment prefix of it `src/mcp/auth/discovery.zig`
- Authorization server metadata is accepted only when its `issuer` equals the requested issuer string and it lists `S256`, and its endpoints pass the discovery URL check `src/mcp/auth/discovery.zig`
- The token-failure message shows only the endpoint's own `error` and `error_description`, or a fixed reason, and never the token value `src/mcp/auth/oauth.zig`
- A refresh counts as refused only at a 200 or a 4xx other than 429, and only when `error` names `invalid_grant`, `invalid_client`, `unauthorized_client` or `invalid_refresh_token`. Any other answer keeps the stored tokens `src/mcp/auth/oauth.zig`
- Scope masks hold at most `max_scopes` (31) names, so each mask fits the bits the 32-bit trace integers allow `src/mcp/auth/oauth.zig`
- Sign-out posts a revocation of the refresh token, or of the access token when there is no refresh token, to the revocation endpoint, and forgets the tokens without waiting for the answer. Registrations stay `src/mcp/auth/client.zig`
- Client request keys start at `fetch_base` (3 << 62) and count up, above the `aux_base` (1 << 62) range `src/mcp/auth/client.zig`
- With `refresh_via_host`, a due refresh is announced as `refresh_due` and sent only when the host answers, while without it the refresh is sent at once `src/mcp/auth/client.zig`
- `restore` rejects a saved credential whose access token is invalid, or whose endpoints `discovery.fetchable` refuses for this server, and returns false `src/mcp/auth/client.zig`
- Sign-in data lives in `flow_arena`, which is reset when the next sign-in starts, and restored credential data lives in `cred_arena`, which is reset when a credential is restored `src/mcp/auth/client.zig`
- The scopes from a challenge are combined with the configured `scopes` for the next sign-in, since `challengeScopes` returns both as a union `src/mcp/auth/client.zig`

### src/core/mcp

- `Value` in `atomic_value.zig` is a plain struct on wasm builds, and the wasm executable is built with `single_threaded` set in `build.zig`, so no atomic is needed there. `src/core/mcp/atomic_value.zig`
- An empty `elicitation` capability object is read as form-mode support, a compatibility rule in `parseModernMcpCapabilities`. `src/core/mcp/elicitation.zig`
- `classifyHost` flags hosts with a punycode label (the `xn` prefix) or non-ASCII bytes, and the elicitation UI warns about them because they can disguise their destination. `src/core/mcp/elicitation.zig`
- The ACP prompt caller of `decideTransition` changes its pending state only when it returns `consume`, while the ACP legacy-URL caller in `server.zig` also removes its pending entry on `reject`. `src/acp/prompt.zig`, `src/acp/server.zig`
- The `instructions` argument of `definitionDigest` is always null in production, so the digest covers only the tool definition. `src/core/mcp/catalog_state.zig`
- Project `.mcp.json` is opened without following a final symlink and with hard links rejected, so a file over 1 MiB or one that fails those checks is reported as `UnreadableConfig`, while an absent file reads as `null`. `src/core/mcp/workspace_config.zig`
- A literal `Authorization` header in a profile MCP config is rejected with `McpConfigAuthorizationHeader`, which keeps bearer credentials out of profile config files, while a project `.mcp.json` entry may set one. `src/core/mcp/project_config.zig`
- When a profile has both `mcp` and `mcpServers`, fx reads only `mcpServers` and reports a non-empty `mcp` alias as ignored. `src/core/mcp/project_config.zig`
- `validateArguments` checks only that the arguments are a JSON object within the byte, nesting-depth and 4096-value limits, so argument schema checks are left to the server. `src/core/mcp/features/tools.zig`
- `tool_names.Registry` never removes an alias, so a retired tool name stays reserved, and the result of `serverName` borrows from the registry until `deinit`. `src/core/mcp/tool_names.zig`
- `withUnavailable` takes ownership of `page` and frees it when it returns a new slice, while a page that does not end in `}` comes back unchanged and is not freed. `src/core/mcp/tool_search.zig`
- The `fx mcp call` shell guidance is added to the model catalog only where `mcp_call_capability.supported` holds, which is Linux and macOS. `src/core/mcp/model_catalog.zig`
### src/core/mcp_host

- Callers of the menu must act on `Effect.open` and `Effect.back` by calling `startMenuTools` and `stopMenuTools`. `src/core/mcp_host/menu.zig`
- When a prompt is submitted without reloading MCP config from files, the next status refresh records the servers that need attention as seen, so later status lines do not repeat them. `src/core/app/input_submit_runtime.zig`, `src/core/app/app_mcp_runtime.zig`
- The status line shows no server counts until `startupSettled` holds, which happens when every starting server needs attention or 10 seconds have passed since the host started. `src/core/mcp_host/menu.zig`
- Server names and notices in the status line come from config and servers, so `writeSafe` replaces control bytes, 0x7f and C1 controls with `?` to keep terminal escapes inert. `src/core/mcp_host/menu.zig`
- The server screen hides a stored error when `needs_login` is set, because `attention()` already reports that the server needs a login. `src/core/mcp_host/menu.zig`
- Disabled and rejected servers never count as needing attention, since those states come from the user's own config or choice. `src/core/mcp_host/menu.zig`
- While filtering, `filterChanged` moves the cursor to the first tool row, past the choice rows, so Enter cannot run a choice by surprise. `src/core/mcp_host/menu.zig`
- On the Keychain backend the store lock is leased: each holder restamps it when taking it and before each Keychain read or write, and a waiter gives up once the holder's last stamp is 12 s old, which is the Keychain call budget plus slack. `src/core/mcp_host/credentials.zig`
- `Store.home` is borrowed by `detect` without a copy, so the home path must outlive the store. `src/core/mcp_host/credentials.zig`
- `Store.get` returns bytes the caller owns and frees with `secret.zeroAndFree`, while `Snapshot.get` slices are valid only until `Snapshot.deinit`. `src/core/mcp_host/credentials.zig`
- `Store.snapshot` reads the store once for many servers, so each server does not trigger its own Keychain read. `src/core/mcp_host/credentials.zig`
- `removeIfSame` deletes only when the stored digest matches, so a newer credential saved by another fx process survives. `src/core/mcp_host/credentials.zig`
- A busy refresh lock makes `tryRefreshLock` return null, so only one fx refreshes a given login at a time. `src/core/mcp_host/credentials.zig`
- `refreshHolderStopped` lets a waiter go ahead only `hold_slack_ms` after the later of the holder's refresh step deadline and the store lease deadline, as modelled by `NoGoAheadPastLiveRefresher` in `tests/tla/mcp_host/RefreshLease.tla`. `src/core/mcp_host/credentials.zig`
- The credential store treats a file that is not regular, such as a fifo, as `CredentialStoreUnreadable` and leaves it alone. `src/core/mcp_host/credentials.zig`
- `Catalog.servers` borrows the runtime's server slice, so the runtime must outlive the catalog. `src/core/mcp_host/model.zig`
- When a server is dropped on reload, the catalog generation advances by 2, so bindings and access views made before the reload stop matching. `src/core/mcp_host/model.zig`
- A list's generation is taken from the catalog serial whenever its tool digest changes, so a server that is removed and re-added never gets a generation an earlier binding carries. `src/core/mcp_host/model.zig`
- `callTool` refreshes a stale tool list before calling, so a tool the server removed is not sent; `toolSchema` reloads only for a tool name it does not know, so schema reads may use an older list. `src/core/mcp_host/model.zig`
- The subagent access rule has a TLA+ counterpart, `NotNarrower` in `tests/tla/mcp_host/SubagentAccess.tla`, which requires a same-run view to allow every tool its parent allows. `src/core/mcp_host/model.zig`
- A request whose protocol version differs from `protocol_version` is refused with `unsupported_version`, so a client from another fx build is not misread. `src/core/mcp_host/mcp_call.zig`
- `RequestId` comes from `State.next`, which only grows, so a request id is never reused. `src/core/mcp_host/mcp_call.zig`
- An abandoned request keeps its slot until its permission answer arrives (if it was abandoned before authorization) or its call result arrives (if it was abandoned during the call). `src/core/mcp_host/mcp_call.zig`
- `ownerOf` compares every registered token with `timing_safe.eql` and does not stop early, so token checks do not leak timing. `src/core/mcp_host/mcp_call.zig`
- `freeSlot` treats a full slot table as unreachable, which holds only because `refusal` returns `busy` at capacity before a slot is claimed. `src/core/mcp_host/mcp_call.zig`
- `max_effects` equals `max_slots` because one step emits at most one effect per held request. `src/core/mcp_host/mcp_call.zig`
- `Abstract` is the view that the TLA driver in `tests/tla/drivers/mcp_call/harness.zig` compares. `src/core/mcp_host/mcp_call.zig`
- Each bridge registration's token is 32 bytes from `io.random`, and the token alone identifies the owner that a request is attributed to. `src/core/mcp_host/mcp_call_bridge.zig`
- `Outcome` has no cancelled variant, so the bridge reports an error from the capability call as `failed`. `src/core/mcp_host/mcp_call_bridge.zig`
- The `stopped` event is applied when the last bridge registration unregisters, which ends the bridge session. `src/core/mcp_host/mcp_call_bridge.zig`
- `unregister` frees the registration, so the environment slices from `Registration.environment()` and the registration itself must not be used after it. `src/core/mcp_host/mcp_call_bridge.zig`
- `unregister` revokes the owner before it waits for in-use requests, so no new request can borrow a registration that is going away. `src/core/mcp_host/mcp_call_bridge.zig`
- On stop the accept task is awaited before connection tasks are cancelled, and only `acceptLoop` adds connection tasks, so no connection starts after the group is cancelled. `src/core/mcp_host/mcp_call_bridge.zig`
- Permission prompts for `call` operations run one at a time under `bridge.prompt`. `src/core/mcp_host/mcp_call_bridge.zig`
- While a registration's `hold` count is above zero, a shell call does not yield to the background. `src/core/mcp_host/mcp_call_bridge.zig`
- Request lines over `wire.max_request_bytes` are refused as too large, and malformed requests are refused by the shell before the core sees them. `src/core/mcp_host/mcp_call_bridge.zig`
- The core's refusals map through `Reason.fromRefusal`, while the shell alone decides the `malformed` and `too_large` reasons. `src/core/mcp_host/mcp_call_wire.zig`
- `writeRequest` writes `arguments_json` verbatim, so callers must pass a valid JSON object, which `parseRequest` requires. `src/core/mcp_host/mcp_call_wire.zig`
- `Context.gpa` is used by `Waiter.onNotice`, which runs on the runtime's owner thread, so it must be thread-safe. `src/core/mcp_host/verbs.zig`
- When `Hosts.sign_in_when_loaded` is set and an HTTP profile server is being added, `add` hands sign-in to the live host instead of signing in itself. `src/core/mcp_host/verbs.zig`
- On the CLI, a usage error from `list` or `show` with the JSON flag is written to stdout as an object with `kind`, `error` and `code`, so scripts can read why it failed. `src/core/mcp_host/verbs.zig`
- `list` and `show` both print the host's notes, so a skipped config entry is never silent. `src/core/mcp_host/verbs.zig`
- `add` writes the server to config before any sign-in starts, so a failed sign-in leaves the server in place with a hint to run `login`. `src/core/mcp_host/verbs.zig`
- `approve` output shows the stdio command a server runs, so the user approves the real command rather than a summary. `src/core/mcp_host/verbs.zig`
- `signalServersForExit` sends SIGTERM to every stdio server without waiting for them, so quitting does not block on server shutdown. `src/core/mcp_host/runtime.zig`
- A retired runtime still accepts requests so that calls begun on it can finish, and while any retired runtime has not finished `deinit`, other runtimes hold requests that could start a server. `src/core/mcp_host/runtime.zig`
- `refresh_answer_ms` uses the engine's default `refresh_ms`, because the config timeouts set only the start, idle and hard limits. `src/core/mcp_host/runtime.zig`
- `revoke_wait_ms` mirrors the engine's `close`, which waits up to 2000 ms for token revocation. `src/core/mcp_host/runtime.zig`
- Across processes one fx refreshes a login at a time under the store's refresh lock, and a waiter goes ahead only when the lock holder has stopped. `src/core/mcp_host/runtime.zig`
- `Runtime.start` reads `configs` and `inherited` only during the call, copying what it keeps into the runtime arena. `src/core/mcp_host/runtime.zig`
- The runtime's `gpa` is used from caller threads as well as the owner thread, so it must be thread-safe. `src/core/mcp_host/runtime.zig`
- The `Runtime` pointer must not move until `deinit`, because the engine context and the login tasks keep `&r`. `src/core/mcp_host/runtime.zig`
- Server names from `servers()` and reload lists live in `r.arena` until `deinit`. `src/core/mcp_host/runtime.zig`
- The fields `queue`, `stopping`, `snapshot`, and a request's `question` and `note` are guarded by `mutex`, while the other runtime state is touched only by the owner thread. `src/core/mcp_host/runtime.zig`
- `deinit` waits for `callers_inside` to reach zero before freeing, and `submit` and the `statuses` functions hold that count. `src/core/mcp_host/runtime.zig`
- Finished requests are woken by `flush` after `publish` refreshes the snapshot, except when `finish` cannot queue them, in which case they are woken at once. `src/core/mcp_host/runtime.zig`
- `Asker` callbacks run on the caller's thread inside `submit`, while `Notify` callbacks run only on the owner thread. `src/core/mcp_host/runtime.zig`
- `run` restores saved credentials first, and `statuses` waits for that, so `signed_in` is never reported before saved logins load; `statusesNow` skips the wait. `src/core/mcp_host/runtime.zig`
- `Runtime.start` never touches the credential store, and a `.detect` option is resolved on the owner thread in `restoreCredentials`. `src/core/mcp_host/runtime.zig`
- `applyReload` does all failable allocation before `dropServer` ends anything, so after `dropServer` only `engine.reload` can fail. `src/core/mcp_host/runtime.zig`
- `dropServer` cancels the server's calls, requeues its tool-list waits by name, and ends its sign-in, logout, refresh and URL waits, reporting `maybe_ran` from the engine for cancelled calls. `src/core/mcp_host/runtime.zig`
- An elicitation answer for a server that a reload replaced is dropped, because the replaced server gets a new id. `src/core/mcp_host/runtime.zig`
- Reload lifecycle is modelled in `tests/tla/mcp_host/HostLifecycle.tla`. `src/core/mcp_host/runtime.zig`
- `CredentialStoreUnreadable` makes sign-in and sign-out fail before anything changes. `src/core/mcp_host/runtime.zig`
- A logout whose saved login cannot be removed still signs this fx out, and `logout` returns the reason. `src/core/mcp_host/runtime.zig`
- A new login that cannot be saved raises a `not_saved` notice and works in this process only. `src/core/mcp_host/runtime.zig`
- The engine's `allow` hook always returns true, so permission filtering must happen earlier, in `model.zig` through `rulesDenyAllTargetsForPermission`. `src/core/mcp_host/runtime.zig`
- Holding a 2025 URL elicitation keeps its id only when a `url_completions` sink exists, and completion sends that id to the sink. `src/core/mcp_host/runtime.zig`
- 2026 input answers are returned to the engine in the order of the request keys, each one looked up by its key. `src/core/mcp_host/runtime.zig`
- The TUI sets `slash_commands`, so the model's sign-in step tells the user to run `/mcp login NAME` rather than a terminal command. `src/core/mcp_host/runtime.zig`
- `CallResult.ended.why` explains a transport failure while the server is down, an oversized reply, and a call ended by a reload. `src/core/mcp_host/runtime.zig`
- The Slack `scopes` and `callback_port` defaults apply only to a Slack-app server, which needs fx's Slack client_id and either Slack's MCP URL or the test stand-in origin. `src/core/mcp_host/config.zig`
- Slack-app listeners redirect via `localhost`, not `127.0.0.1`. `src/core/mcp_host/login.zig`
- No browser return matches a login until `Listener.expect` records its state, because `isOwn` rejects every return while no state is recorded. `src/core/mcp_host/login.zig`
- `accept` checks `io.checkCancel()` on each loop, so a login wait can be cancelled through `io`. `src/core/mcp_host/login.zig`
- `update` takes the profile lock `mcp.lock` before it reads or writes either file, while `replaceProfile` takes no lock itself, so a direct caller must hold the lock. `src/core/mcp_host/config_file.zig`
- `write` refuses a project `.mcp.json` that is a symlink or has more than one hard link, returning `Linked`. `src/core/mcp_host/config_file.zig`
- `read` caps config files at 1 MiB and refuses a non-regular file such as a fifo with `DurablePathUnsafe`. `src/core/mcp_host/config_file.zig`
- `Removed.url` is the removed HTTP server's URL, which keys its saved token, so `remove` can forget that credential. `src/core/mcp_host/config_file.zig`
- A profile file reads `mcp` or `mcpServers` but not both, since having both fails with `BothKeys`, while a project `.mcp.json` reads only `mcpServers`. `src/core/mcp_host/config_file.zig`
- The host's `gpa` must be thread-safe, because `Host.stop` destroys the host on a detached thread. `src/core/mcp_host/host.zig`
- `Host.stop` retires the host, then destroys it on a detached thread, or inline when the build is single-threaded or the spawn fails, so nothing may use the host after `stop`. `src/core/mcp_host/host.zig`
- Host notes are owned by the host's `gpa` and replaced under `notes_mutex`, and the host keeps the new notes even when the reload fails. `src/core/mcp_host/host.zig`
- Workspace (`.mcp.json`) servers' saved logins are keyed by the workspace root, while profile servers have no workspace key. `src/core/mcp_host/config.zig`
- A stdio server's environment drops inherited values that start with `()`, which keeps exported shell function definitions out of the child process. `src/core/mcp_host/config.zig`
- `keepServers` returns strings that point into `prior` when they are equal, so `prior` must outlive the result. `src/core/mcp_host/config.zig`
- ACP-issued servers are held as `unsupported`, while SSE servers are passed to the engine's `sse` transport. `src/core/mcp_host/config.zig`
- A header or bearer value that `mcp.http_headers.sendable` rejects holds the server as `invalid_env`, so control bytes never reach an HTTP header. `src/core/mcp_host/config.zig`
- `Server.command` is the stdio command shown to the user in `approve` output, so trust decisions see the command that will actually run. `src/core/mcp_host/verbs.zig`
### src/core/tooling

- `DispatchContext.scratch_allocator` is for work that must not outlive one call, such as the `grep_files` workspace scan, so it should return memory on free. `src/core/tooling/tool_dispatch.zig`
- `tool_runtime` sets `DispatchContext.mcp_call_capability` from the bridge, and only the shell tool reads it. `src/core/tooling/tool_dispatch.zig`
- Tool validation runs before the permission gate, and a validation failure returns without asking for permission. `src/core/tooling/tool_dispatch.zig`

### src/ui/transcript

- `installTranscriptArchive` takes ownership of the archived runtime, and `discardTranscriptArchive` frees it through `TranscriptArchive.deinit`. (`src/ui/transcript/runtime.zig`)
- `rebaseRetainedTranscript` clones the retained identity and duplicates the retained flow before it changes any live boundary or owned flow. (`src/ui/transcript/runtime.zig`)
- `pending_resume_source` is released when a transition commit takes over the flow, in `clearTranscript`, and on `deinit`. (`src/ui/transcript/runtime.zig`)
- Entry ids start at 1, so 0 is free as a sentinel: writers return 0 for empty text, as `writeTranscriptReturningEntryIdClassified` and `appendReplaceableTranscriptLineSilent` do. `clearTranscript` never resets `next_entry_id`, so ids stay unique across transcript resets within a session. (`src/ui/transcript/runtime.zig`, `src/ui/transcript/writer.zig`, `src/ui/transcript/store.zig`)
- `appendRawBytesEntry` stores the given bytes without copying them, so the caller must not free them after the call, and `clearTranscript` and entry `deinit` free them. (`src/ui/transcript/store.zig`, `src/ui/render_engine/transcript_blocks.zig`)
- `writeUserPromptCard` borrows `user` and `skill_tokens`, so the caller keeps ownership after success or error. `appendUserTurnOwned` frees the turn on failure and the entry owns it on success. (`src/ui/transcript/store.zig`)
- `swapSlot` asserts that it does not run mid-paint or during a scrollback handoff, so a caller that changes the agent on screen must request a terminal reset, as `app_agents_runtime.zig` does after attaching the session. (`src/ui/transcript/runtime.zig`, `src/core/app/app_agents_runtime.zig`)
- `commitVisibleTranscriptBeforeFreshSession` returns `SessionScrollbackHandoffUnavailable` from its precondition checks before it records a pending handoff, so the caller keeps the old transcript. (`src/ui/transcript/runtime.zig`)
- `bindDetachedCommitAllocator` asserts that `shadow_vt` is null, so a detached presentation never owns the shared shadow grid. (`src/ui/transcript/runtime.zig`)
- Mutation shadows borrow the parent's frozen prefix through `frozen_prefix_source` and do not carry `transcript_window`. (`src/ui/transcript/store.zig`)
- `advanceCursor` caps `cursor_row` at `layout.rows`, so scroll math must use `walk.end_row`. (`src/ui/transcript/runtime.zig`, `src/ui/transcript/writer.zig`)
- `controlBoundaryAt` trusts a `known` boundary only when its offset is at most `raw_offset` and does not compare bytes, so its caller must ensure `bytes[0..known.offset]` are the bytes the boundary was computed from. (`src/ui/transcript/painter.zig`)
- The `Abstract` view mirrors the TLA+ model's variables, with `prevFirst` set to -1 for the model's `None`, which the trace driver in `tests/tla/drivers/transcript_window/lib.ts` maps back. (`src/ui/transcript/transcript_window.zig`, `tests/tla/drivers/transcript_window/lib.ts`)
- `pending_diffs` entries in `resume_projection.zig` are freed with `std.heap.c_allocator`, so they must be released with that allocator. (`src/ui/transcript/resume_projection.zig`)
- The multi-word labels in `known_multiword_labels` mirror those composed by `permissionDeniedStatusLabel`, except `Timed out`, which that function does not produce. (`src/ui/transcript/tool_group_projection.zig`, `src/core/agent/runtime/tool_admission.zig`)

- `composeResolvedQuestionAnswers` borrows its answer pairs for the duration of the call, so the caller keeps them alive until it returns. (`src/ui/footer/question_ui.zig`)

- `Projection` borrows stored-result handles and reads their content through the session child capability when needed. (`src/ui/full_transcript_screen.zig`)
- `terminalTitleFor` keeps a pointer to the file it is given, so that file must outlive the title provider; `main.zig` passes the shell's `stdout_file`. (`src/ui/render.zig`, `src/main.zig`)

### src/ui/terminal

- Program-status messages are reduced to one line of at most `max_message_bytes` (256), with whitespace and control characters collapsed, invalid UTF-8 dropped, and a cut message ending in a marker, because a terminal discards a report whose message holds a control character. (`src/ui/terminal/program_status.zig`)
- Interactive mode disables autowrap (DECAWM, `CSI ?7l`) through `interactive_mode_enable_sequence`, and `src/ui/ask_presentation.zig` restores it (`CSI ?7h`) on exit. (`src/ui/terminal/terminal.zig`, `src/ui/ask_presentation.zig`)
- Theme detection sends the background query followed by a primary device attributes fence (`CSI c`). Terminals answer in order, and the 200 ms deadline applies to a terminal that answers neither. (`src/ui/terminal/theme_detection.zig`, `src/ui/terminal/terminal.zig`)
- `FX_THEME` values other than `light` and `dark` are returned as a theme name for the caller to resolve. (`src/ui/terminal/theme_detection.zig`)

### src/core/shared

- `spawn_inheriting_fd` does not close the borrowed `inherited_fd`, so the caller keeps ownership of it. The child receives the fd at `inherited_fd_target`, which is 64 (or 65 when the source fd is already 64), and `src/core/execution/process_tree.zig` reports that number as the descendant fd. (`src/core/shared/darwin_process_spawn.zig`)
- On Linux `pathForReexec` returns `/proc/self/exe`, so replacing the binary on disk does not break later re-execs. (`src/core/shared/self_exe.zig`)
- `pathForPeerReexec` prefers the on-disk executable path, a name that outlives this process, and falls back to `/proc/<pid>/exe` only when that path is not executable (for example after the binary was replaced) or cannot be resolved. (`src/core/shared/self_exe.zig`)
- In test builds both re-exec paths resolve to the installed `fx` binary named by the `test_paths` option (`product_exe` in `build.zig`), not the test binary. (`src/core/shared/self_exe.zig`)
- `sort` is a stable sort: elements that compare equal keep their input order. (`src/core/shared/sort_utils.zig`)
- `no_resize` refuses every in-place resize and remap, so allocator behaviour does not change the allocation sequence that a test observes, and allocation-failure tests can use it. (`src/core/shared/testing_allocator.zig`)
- `decodeUtf8Sequence` returns `error.InvalidUtf8` unless the slice is exactly one complete, well-formed sequence, so its length check rejects a lone non-ASCII byte or a lead byte whose length does not match before the fixed-length `std.unicode` decoders, whose asserts assume a matching lead byte, are reached. (`src/core/shared/display_width.zig`)
- `writeParamPath` stops at depth 16 (`max_param_path_depth`), which bounds recursion through nested `path` and `param` objects in an untrusted error body. (`src/core/shared/gateway_error_format.zig`)
- The view returned by `contextHistoryRange` borrows its turn payloads from `history`, and only the view slice plus any rebased or copied notes, model calls and steering are allocated in the arena, so `history` must outlive the view. (`src/core/shared/history_range.zig`)
- Context notes sit before the steering of the same step boundary, so a cut covers every earlier note and covers the notes at its own boundary only when it also covers a steering message there (design decision D93, `tests/tla/session_manager/system-design.md`). (`src/core/shared/history_range.zig`)
- Model call records are counted from the cut's first step and first steering message, the same way steering is, and calls from steps outside the cut are dropped with their step (design decision D96, `tests/tla/session_manager/system-design.md`). (`src/core/shared/history_range.zig`)
- `slack_ms` (2 s) is the grace a waiter adds beyond a holder's step bound: `src/core/mcp_host/credentials.zig` adds it on top of `call_budget_ms`, and `src/core/auth/oauth_session.zig` adds it to `mutation_step_ms`. (`src/core/shared/leased_lock.zig`)
- `restamp` refreshes a held lock's stamp, and `src/core/mcp_host/credentials.zig` calls it before it reads or writes the credential store. (`src/core/shared/leased_lock.zig`)
- A holder whose stamp write fails still holds the advisory lock, and its waiters time it from an older stamp or from their own start. (`src/core/shared/leased_lock.zig`)
- `stampFrom` treats a stamp that is not after the waiter's start, or that lies after now, as the waiter's start, which covers a damaged stamp or one left from before a reboot reset of the awake clock. (`src/core/shared/leased_lock.zig`)
- `Watch.stop` sets the event that `run` polls every 5 ms, so the watch returns `.stopped` promptly. The race helper calls it before `select.cancel()`, so a following cancel finds the watch finished or about to finish. (`src/core/shared/select_watch.zig`)
- `Watch.finish` stops the watch, takes its queued event, and asserts that the event is `.watch` and that `select.cancel()` has nothing left to cancel, so every other operation in the select must already be taken when it is called. (`src/core/shared/select_watch.zig`)
- The test-only `SignalCounter` installs its SIGIO handler with no `SA_RESTART` flag, so blocking syscalls in the cancel tests are interrupted. (`src/core/shared/select_watch.zig`)
- In test builds `localZoneAt` returns `test_zone`, so rendered local times do not depend on the machine's zone. Tests that set it restore `Zone.utc` with `defer`, as `src/core/output/full_transcript_metadata.zig` and `src/core/output/output_contracts.zig` do. (`src/core/shared/local_time.zig`)
- A zone name from the C library is printed only when `isPlainZoneName` accepts it (ASCII alphanumerics, `+` and `-`, at most 10 bytes). Otherwise the `+HHMM` offset is printed, which keeps unchecked zone text away from the terminal. (`src/core/shared/local_time.zig`)
- The zone name `localZoneAt` returns borrows C library storage, so `inZone` copies it into the `Reading` buffer and a `Reading` never keeps the pointer. (`src/core/shared/local_time.zig`)
- `Message` tracks ownership with `owns_content` and `owns_tool_calls`, and `deinit` frees only the parts marked owned, because `ToolCall` byte slices carry no ownership in their type. (`src/core/shared/message.zig`)
- Callers of `innerParse` must set `options.allocate`, because allocating sequence paths unwrap it with `.?` unless the sequence copies strings. (`src/core/shared/json_decode.zig`)
- Each `Field` table entry must stay 24 bytes, which the `table entries stay small` test asserts. (`src/core/shared/json_decode.zig`)
- `openExistingRegularFile` opens with `NOFOLLOW` and `NONBLOCK`, so a FIFO or other special file cannot block the open, then rejects anything that is not a regular file or has extra hard links before it makes the descriptor blocking again. (`src/core/shared/io.zig`)
- `setRawEnviron` keeps the environment block that `main` received as a fallback for reads, and libc does not free that original array, so those reads stay valid while the process changes its libc environment. (`src/core/shared/io.zig`)
- `setLibcEnviron` reads libc on every use and keeps no pointer into libc's environment array, since libc can move and free that array when the environment grows. Keys of 128 bytes or more fall back to `liveLibcEnviron`, whose slices are valid only until the next environment change. (`src/core/shared/io.zig`)
- `homeDir` uses `HOME` only when it is absolute, and otherwise falls back to the fx home parent, so profile paths are never built relative to the current folder. (`src/core/shared/io.zig`)
- `awakeMilliTimestamp` reads the awake clock, which is shared by all processes on the machine and does not advance during sleep, so it suits timeouts that one process sets and another reads. (`src/core/shared/io.zig`)
- When `DurableOps.pre_rename_cause` is set, a durable replace that fails before its rename records the stopping error there, because `DurableReplacePreRenameFailed` alone does not carry it. (`src/core/shared/io.zig`)
- `syncVerifiedDir` needs a directory opened with `iterate = true`, which the verified-directory openers in `io.zig` set. Without it, Linux opens an `O_PATH` descriptor and `fsync` fails with `EBADF`. (`src/core/shared/io.zig`)
- `openRealDirIfPresent` never follows a symlink and requires a real directory, but it does not check the folder's mode, so existing profile folders with looser permissions still open. (`src/core/shared/io.zig`)
- On Linux, `tcgetattr` and `tcsetattr` call the kernel directly, because libc's termios struct can be larger than the kernel-sized `std.posix.termios` and would overrun the caller's stack. (`src/core/shared/io.zig`)
- `reserveClosedStandardStreams` reopens any closed fd 0, 1 or 2 on `/dev/null` (read-only) before fx opens files, so a later open cannot take a standard fd number, and a write to a closed stdout fails instead of landing in that file. (`src/core/shared/io.zig`)
- `fx_home` is set by `useFxHome`, which `src/main.zig` calls, and is read without a lock afterwards, so it must not change while other code may be reading it. (`src/core/shared/profile_paths.zig`)
- `useFxHome` rejects a relative value, `/`, or the home folder itself, because the fx folder is kept private and must not be the root or the home folder. The stored slice is not copied, so the value must outlive the process. (`src/core/shared/profile_paths.zig`)
- Callers open `rootName()` inside the directory from `rootParent(home)` with `follow_symlinks = false`, as `src/core/session/session_log.zig` does, so the fx folder itself is not reached through a symlink. (`src/core/shared/profile_paths.zig`)
- The `terminal` folder holds hosted terminal state for v2 sessions, one folder per session id under the fx folder (design decision D45, `tests/tla/session_manager/system-design.md`). (`src/core/shared/profile_paths.zig`)
- An older session moves off the `session-files` side folder on its first writable open and keeps its old names resolving (design decision D47, `tests/tla/session_manager/system-design.md`), as the test `an older session moves off its side folder on its first writable open, and its old names still resolve (D47)` in `src/core/session/session_adapter.zig` shows. (`src/core/shared/profile_paths.zig`)
- Untrusted text shown in the terminal should pass through the terminal-safe encoders (`terminalSafe`, `appendTerminalSafeLine`, `appendTerminalSafeText`, `encodeTerminalSafe`), which show control and C1 bytes as `\xNN` or `\u{...}` text instead of letting the terminal act on them. (`src/core/shared/text_utils.zig`)
- `appendTerminalSafeText` keeps zero-width joiners, direction marks and other invisible format characters, which emoji sequences and some scripts need, while `appendTerminalSafeLine` escapes them. (`src/core/shared/text_utils.zig`)
- `dupeValidUtf8` is not terminal-safe: it escapes only bytes that are not valid UTF-8 and keeps control bytes, so its output must not be shown without further encoding. (`src/core/shared/text_utils.zig`)
- `IncrementalTerminalSafeEncoder` holds at most one unfinished UTF-8 sequence between appends, so bounded file pages can be streamed without emitting a raw partial byte. (`src/core/shared/text_utils.zig`)
- An OSC 8 link target must be printable ASCII with no space or DEL, so nothing in it can end the escape sequence. Callers check it before emitting a link, as `src/core/app/app_mcp_runtime.zig` does. (`src/core/shared/text_utils.zig`)
- Core producers that cannot import UI state read the active colors through `current()`, and `src/ui/render.zig` sets them with `activate` when a theme is applied. (`src/core/shared/theme.zig`)
- `setSource` records the custom theme file key, up to 64 bytes (longer names are logged and not kept), and whether the light or dark variant is pinned. `src/core/app/app_lifecycle.zig`, `src/ui/render.zig` and `src/core/cli/cli_ask.zig` call it. (`src/core/shared/theme.zig`)
- A parsed `Theme` copies its name into the allocator passed to `parse`, so that allocation must outlive the theme. (`src/core/shared/theme.zig`)
- Unknown theme JSON keys are ignored, because `assignSlotEscape` assigns only known slots, so newer theme files still load on older binaries. (`src/core/shared/theme.zig`)
- In editor-theme token colors an exact scope beats a dotted prefix, an equal score goes to the later entry (the override order VS Code uses), and space-separated compound selectors are skipped. (`src/core/shared/theme.zig`)
- `CredentialLease.host_managed` carries no secret or account bytes into the embedded runtime, so `secret()` returns null for it and only `direct` leases hold credential bytes. (`src/core/shared/types.zig`)
- `isRetryableServerStatus` treats every 5xx status except 501 and 505 as retryable, since those two mean an unsupported feature or HTTP version that a resend cannot fix. (`src/core/shared/types.zig`)
- Model call records sit at tool-step boundaries, and their replay order is specified by `tests/tla/full_detail/FullDetailOrder.tla`, whose `ReplayMatchesSaved` requires a replay to match the saved event prefix. (`src/core/shared/types.zig`)
- Provider and model strings and model-call text are checked with `validModelCallText` before they are saved or shown. It rejects empty text, text longer than `model_call_text_max_bytes` (256), invalid UTF-8, and ASCII control bytes. (`src/core/shared/types.zig`)
- `dupeToolResultMemory` deep-copies the slice-bearing fields, so a copy outlives a shorter-lived source, which parallel tool execution relies on (`src/core/agent/runtime/parallel_execution.zig`). (`src/core/shared/types.zig`)
- `ProviderFinishRaw` keeps only a bounded prefix of provider finish text and replaces any byte outside printable ASCII (space included) with `?`, so untrusted finish text cannot carry control bytes. (`src/core/shared/types.zig`)
- `PermissionMode.parse` accepts `yolo` alongside `ask`, `manual` and `auto`, and returns null for `full-access` and `full access`. (`src/core/shared/types.zig`)
- The matching rules (R1 to R12), laws and decisions for fuzzy matching are defined in `tests/tla/fuzzy_match/design/GOAL.md`, and the TLA+ model that checks the laws is in `tests/tla/fuzzy_match/spec`. (`src/core/shared/fuzzy_match.zig`)
- Bytes 0x80 and up count as word characters, and only ASCII punctuation separates words, so skipping separators never splits a UTF-8 sequence. (`src/core/shared/fuzzy_match.zig`)
- `Ranking` calls `context.matchAt` several times for one position, so it must return the same answer every time. A caller whose base order differs from its item order maps positions to items, as the skills menu does in `src/core/skills/skill_runtime.zig`. (`src/core/shared/fuzzy_match.zig`)
- A ranked match's field index must stay below `ranked_field_limit` (8), which `rankBucket` asserts, so callers size their field buffers with that constant. (`src/core/shared/fuzzy_match.zig`)
- The character-presence filter maps each byte to a bit, with letters folded to one bit and all bytes 0x80 and up sharing one bit, so a field missing any bit the query needs cannot match. The filter therefore never rejects a real match. (`src/core/shared/fuzzy_match.zig`)
- `runAtAscii` must agree with `runAt`: a byte 0x80 and up is a word character that no ASCII word character equals, so it ends a run exactly as the character comparison would. (`src/core/shared/fuzzy_match.zig`)
- `HttpPool` request paths (`openRequest`, `clientFor`, `closeIdleConnections`) may run on concurrent request threads, since std's connection pool is mutex-guarded and `setup_lock` and `ca_bundle_lock` guard the rest. (`src/core/shared/http_pool.zig`)
- Every connection setup holds `setup_lock` shared. `refreshTlsClock` advances `client.now` under the exclusive lock, using `tryLock` and skipping when a setup is running, because `ensureTlsReady` sets `client.now` only once, when the CA bundle first loads. (`src/core/shared/http_pool.zig`)
- Idle connections older than the 30 s `ttl_ms` are closed rather than reused, because a connection the peer closed gracefully fails only on the next write or response read. `openRequest` reports reuse so the gateway client can retry a reused connection that failed. (`src/core/shared/http_pool.zig`)
- `warmAsync` starts at most one detached warm thread per pool and does nothing in test builds. It does not copy `url`, so the string must stay valid while the warm thread runs. (`src/core/shared/http_pool.zig`)
- `takeIdleConnection` returns no pooled connection when a proxy carries the request, and it destroys any idle connection whose local address has left the machine (after a network change) rather than reusing it, since such a connection cannot answer again. (`src/core/shared/http_pool.zig`)
- `HttpPool.deinit` waits up to 500 ms for an in-flight warm thread, and if one is still running it returns `abandoned_warm_flight` without freeing the client, because that thread may still be inside connect or DNS and use the client. (`src/core/shared/http_pool.zig`)
- `writeScalar` encodes untrusted dynamic metadata once, at the final model-markup boundary, while instruction bodies and skill invocation output go through `writeCarriedEscaped` (`src/builtins/context.zig`, `src/core/skills/skill_invocation.zig`). (`src/core/shared/model_context_encoding.zig`)
- `decodeScalarAlloc` reverses `writeScalar` for tool listing text that leaves the model context, as `src/core/mcp/tool_lookup.zig` uses it. It decodes only the entities `writeScalar` writes, so the result can hold control bytes, and a caller that displays it must encode it again. (`src/core/shared/model_context_encoding.zig`)
- The carried block tag names (`scoped-rules`, `fx-context-update` and `fx-skill-used`) are defined here, so the blocks fx writes itself, such as the scoped-rules reminder (D93), the runtime-context update (D94) and a skill's saved note (D95), share the names that `hasCarriedTag` and `writeCarriedEscaped` check. (`src/core/shared/model_context_encoding.zig`)
- `writeCarriedEscaped` escapes every opening or closing carried tag so that it starts with `&lt;` instead of `<`, so only fx opens those blocks. It applies to instruction bodies (`src/builtins/context.zig`) and skill invocation output (`src/core/skills/skill_invocation.zig`). (`src/core/shared/model_context_encoding.zig`)
- `postMailWith` in `src/core/agent/worker_runtime.zig` refuses a new `.message` mail with `error.QueueFull` once an agent holds `queue_cap` (64) such messages, and only `.message` mail counts toward the cap, so reports and user input are never refused. Reserved posts skip the check. (`src/core/agent/worker_runtime.zig`, `src/core/shared/agent_frame.zig`)
### src/core/compactor

- The trace's `infoIf` records a decision event in the bounded 64-entry ring only when its `recorded` argument is true, so no-op evaluations pass false and do not evict rarer events, while every call still reaches the debug trace. The only caller is the compaction decision in `src/core/agent/runtime/orchestrator.zig`. (`src/core/compactor/trace.zig`)
- A `ModelCaller` with `sends_after_conversation` set makes `compact` ask for its room after the conversation, so the summary request can extend the conversation the provider already cached. `src/core/agent/runtime/text_completion.zig` sets it when the agent has a conversation. (`src/core/compactor/model.zig`)
- The text and failure detail of a `Reply` are allocated with the allocator passed to `send`, and `Summarizer` frees the failure detail with that allocator after writing it to the trace. (`src/core/compactor/model.zig`)
- The fallback model is tried only for the `gateway` provider and comes from the other provider family, because a provider that refused once will likely refuse the same conversation again. (`src/core/compactor/model.zig`)
- `compactedTokens` holds the compacted text to half the compaction point less the fixed part and the kept turns, so compaction frees at least half the room. (`src/core/compactor/window.zig`)
- `earlierFrom` parses a current-format checkpoint directly and reads a legacy one through its state file, which keeps the exact user messages so they are not summarized again. If that file is missing or does not match, the summary is kept as text and new records are numbered after the highest saved one. (`src/core/compactor/compactor.zig`)
- `Result` owns the arena behind its checkpoint, model text and retained history, so `Result.deinit` must be called. Its `retained_history` turns borrow payloads from `Request.history`, which must outlive it. (`src/core/compactor/compactor.zig`)
- `lint.check` marks a note or entry that fails a check with a `[check: ...]` suffix rather than dropping it, and `checkpoint.zig` tells the model to confirm marked items before relying on them. (`src/core/compactor/lint.zig`)
- A kept entry's quoted values are checked only when one of its citations names a turn or tool call of this compaction, and values are searched across all turns, tool calls and user messages, so a value under the wrong turn still passes. (`src/core/compactor/lint.zig`)
- Rule entries (`R` IDs) must quote the user's own words, and a rule whose quoted phrase is not in the user's messages is marked. (`src/core/compactor/lint.zig`)
- `Sources.highest` carries the earlier checkpoint's highest entry numbers, and `checkpoint.wasUsed` uses them to accept a `replaces` target that was used before even if it is no longer held. (`src/core/compactor/lint.zig`)
- `highestSaved` leaves out and traces any saved record numbered above `max_number`, and `checkpoint.parse` rejects counts above it, so a damaged number cannot overflow later numbering. (`src/core/compactor/records.zig`)
- Files named `result-source-*` are archives of earlier conversation, which search returns as archive parts rather than numbered records. (`src/core/compactor/records.zig`)
- A legacy checkpoint names its state file with a `fx-compaction-state-v1 <handle> <bytes> <sha256>` line, and `parseLegacyState` turns that file's user messages into unnumbered turns, returning null when the bytes or digest do not match or the file does not parse. (`src/core/compactor/checkpoint.zig`)
- `replacesPriorContext` is true for a current payload or a legacy `<context_handoff>` checkpoint, and the journal and worker runtime treat such a checkpoint as replacing the earlier history. (`src/core/compactor/checkpoint.zig`)
- `wasUsed` treats an entry ID as used when its number is above zero and no higher than the highest of its kind ever saved, even if that entry is no longer held. (`src/core/compactor/checkpoint.zig`)
- An entry replaces older entries by naming them after `replaces` in its text, a match that `replacedIds` makes case-insensitively, with `and` allowed between IDs. (`src/core/compactor/checkpoint.zig`)
- Every entry must have a well-formed ID that starts its text and is unique, or the payload fails `shapeProblem`. (`src/core/compactor/checkpoint.zig`)
- The first notes request follows the conversation when the model can be asked that way and the request fits `conversation_room`, so the provider can reuse its cache. Otherwise, or when that request fails, the turns are written out in the request. (`src/core/compactor/summarize.zig`)
- `compact` clears `conversation_room` for every part when the turns are split, so only a single request covering every turn can use the conversation position. (`src/core/compactor/summarize.zig`)
- `request_overhead_tokens` and `fold_overhead_tokens` are fixed estimates of the notes request overhead, and tests build their budgets from them, so they must stay in step with the real overhead. (`src/core/compactor/summarize.zig`)
- Rule candidates are found without a model, skipping questions, fenced code, long lines, lines that do not read as prose, and sentences a filed rule already quotes. The model decides which still apply, so candidates only add recall. (`src/core/compactor/ledger.zig`)
- A candidate sentence of fewer than seven words, or one that begins with a pronoun such as `it` or `that` after any leading filler words such as `so` or `never`, is joined with up to two sentences before it so the instruction keeps what it refers to. (`src/core/compactor/ledger.zig`)
- The request lists the exact headings to write and, when it is sent after the conversation, tells the model not to copy the tool-call lines, because a model shown an example heading may copy it. (`src/core/compactor/ledger.zig`)
- A request sent after the conversation is marked as coming from fx, because it reads like the user's next message. (`src/core/compactor/ledger.zig`)
- New entries are asked to number above the highest ID of each kind, and `read` renumbers any entry whose ID is taken or numbered far above that highest, so no ID names two entries. (`src/core/compactor/ledger.zig`)

### src/acp

- `_meta.fx.toolCall` on a tool call reports `internal` as a boolean and, for MCP calls, an `mcp` object with `server` and `tool`, so a client can identify the call without matching tool names. (`src/acp/types.zig`)
- `ShellResultView` parses the JSON that `formatSnapshotRaw` in `src/tools/shell/shell.zig` writes, using fields such as `state`, `output_delta`, and `output_truncated`, so those names are a contract between the two files. Unknown fields are ignored. (`src/acp/tool_call_presentation.zig`)
- An omitted `mcpServers` list parses to an empty set of configs, and the configs `parse` returns are owned by the caller and must be deinitialized. (`src/acp/mcp_servers.zig`)
- A failed `prepare` result owns its rendered diagnostic message, which the caller frees. (`src/acp/mcp_servers.zig`)
- The MCP tool-identity record lives in the session's `tool_identities` state for v2 sessions, and sessions without v2 write no `mcp-tool-identities.json` file.
- The identity record holds at most 1024 names; a new name past that bound is not recorded, and `parse` stops at the same bound. (`src/acp/tool_call_identities.zig`)
- JSON framing is newline-delimited, so `writeOneLine` replaces each raw CR or LF with a space, because JSON allows raw line breaks only as whitespace between tokens. (`src/acp/jsonrpc.zig`)
- On successful v2 activation the session takes ownership of the MCP host and the client system prompt, and on failure the caller still frees them. (`src/acp/sessions.zig`)
- A restored session whose stored client system prompt cannot be read fails the restore with an internal error instead of running without the client's instructions. (`src/acp/sessions.zig`)
- A restored tool-identity record that cannot be parsed is traced and replaced by an empty record. (`src/acp/sessions.zig`)
- A queued steer interrupts a streaming reply only when the step is in its reply phase with no tool call tracked in flight, and a tool call that cannot be tracked moves its step into the tools phase. (`src/acp/libfx_steering.zig`)
- At a cancel boundary `takeInterrupt` consumes the pending interrupt: a steer lets the turn continue with the steering, a handoff ends the turn, and a user cancel overrides both. (`src/acp/libfx_steering.zig`)
- `takeUnplacedInputs` removes the queued libfx inputs the model never saw, returns their ids, and stops acceptance, so a later steer fails with `SteeringNotActive`. (`src/acp/libfx_steering.zig`)
- After a user cancel, `cancelForUser` keeps the queue for the turn's end to report, `takeAll` returns nothing, and `withdraw` returns false when no queued input has that id. (`src/acp/libfx_steering.zig`)
- When the host does not store inputs durably (`inputs_durable` false), placing inputs makes the next progress a barrier, so a model request never carries an input the journal could lose. (`src/acp/libfx_journal.zig`)
- The yield clock arms on its first check after `startYieldClock`, so the first check never yields. (`src/acp/libfx_journal.zig`)
- A crash resume gives the model the interrupted notice before the accepted-but-unplaced inputs, and resets `consumed_provider_attempts` to zero so repeated crashes do not exhaust the provider attempt budget. (`src/acp/libfx_journal.zig`)
- A tool result is recorded only while a progress is open. (`src/acp/libfx_journal.zig`)
- An uncertain response with no recorded running call is dropped. (`src/acp/libfx_journal.zig`)
- Image windowing applies only when the host has an image store, since `dropOutsideWindow` returns early without one. (`src/acp/libfx_journal.zig`)
- The permission-mode and speed behaviour of the ACP server has TLA+ models in `tests/tla/acp`, namely `AcpPermissionModes.tla` and `AcpSpeed.tla`. (`src/acp/server.zig`)
- `setV2Preferences` writes provider, model, effort, and both speed flags in one `setPreferences` call, so every change rewrites the whole preference set. (`src/acp/server.zig`)
- `max_host_time_ms` is 2^53 - 1, the largest integer a JavaScript number holds exactly, so times a web host sends stay exact. (`src/acp/prompt.zig`)
### src/gateway

- Codex request bodies must not include `max_output_tokens`, a rule the Codex request test asserts. (`src/gateway/openai_codex.zig`)
- A provider's HTTP 413 behind a Gateway fallback appears as a `statusCode` 413 inside an attempt in the Gateway error body, and that is read as a size rejection. (`src/gateway/vercel_failure_diagnostics.zig`)
- Anthropic cache markers are sent only to models with the `anthropic/` prefix, and OpenAI prompt cache options only to GPT-5.6 and later models.
- Only `alibaba/`-prefixed models take their instructions as one system message at the start of the request.
- The Codex model catalog must list `reviewer_model` (`gpt-5.6-luna`), and its parser checks for it. (`src/gateway/openai_codex_models.zig`)
- The host stream transport calls `consumed_fn` only for a response that is not cancelled, completed, admitted, and free of a provider failure cause. (`src/gateway/host_stream_provider.zig`)
- Chat-completions `max_output_tokens` is sent as `max_tokens`, never as `max_completion_tokens`. (`src/gateway/chat_completions_protocol.zig`)
### src/core/gateway

- A provider that does not report its connection loads inline through `refreshIfDue` rather than on its own thread with a connect wait. (`src/core/gateway/gateway_provider.zig`)
- A catalog is due for refresh once `refresh_interval_ms` has passed since the last attempt, or when the clock has gone backwards. (`src/core/gateway/gateway_provider.zig`)

### src

- The length prefix written by `slices` must match the one `std.testing.Smith.slice` reads (a little-endian `u32`), so a buffer shorter than the seed does not get the seed back intact. (`src/fuzz_seed.zig`)
- The consumed identity changes only on a `consumed` event that `decide` applies to the current phase (which sets it) and on an explicit `cancel` (which clears it), so a completion still reports as consumed after a later `close` or `shutdown` until a cancel arrives. (`src/napi_fetch_state.zig`)
- `disposition` must be given the phase and the consumed identity from one synchronized read; its only caller, `FetchBridge.disposition` in `src/napi_core_main.zig`, reads both under the bridge mutex. (`src/napi_fetch_state.zig`)

## Facts: src/usage, src/gateway, src/core/app, src/ui/footer, src/core/cli, src/core/config, src/core/session, src/core/agent/runtime, src/core/agent, src/core/subagent, src/builtins/gateway, src/core/mcp_host, tests/tla/session_manager, src/core/terminal, src/core/tooling, src/ui/render_engine, src/ui/transcript, src, src/core/workspace

- The merged entry borrows its rows from both inputs, so it must not outlive them. `src/usage/cache.zig`
- `decode` returns null for malformed json, another schema version, another identity, or an entry that fails validation. It copies every string into its arena, so the input bytes can be freed right after. `src/usage/cache.zig`
- Day and BreakdownDay fields count days since 1970-01-01, converted from ChatGPT's YYYY-MM-DD dates by `report.civilDay`, so window bounds must use the same unit. `src/usage/codex.zig`
- The values returned by `fetchCodex` and `fetchGrok` borrow from the run's parts and are valid only until `Run.deinit`. `src/usage/usage.zig`
- `runQueuedFetch` takes the queued job under the mutex and runs it after releasing the mutex. On wasm the host fetch pulses the event loop through `usage_host.cooperativeHost`. `src/usage/usage.zig`
- `deinit` can run more than once, because it cancels, joins, and clears every owned field. `src/usage/usage.zig`
- `Credential.bearer` is copied into the dashboard session during `open`, so the caller may free its copy once `open` returns. `src/usage/usage.zig`
- `parseModelRows` copies every string into the `Rows` arena, so the caller may free the response body after it returns, but must call `Rows.deinit`. `src/usage/report.zig`

- `Credential.label` must never hold a secret. `src/ui/footer/usage_presentation.zig`

- On v2, each reply's usage is recorded as it arrives, so a run killed mid-turn keeps the usage already recorded (D92). `src/core/cli/cli_ask.zig`
- Prompt images are saved as session blobs when the turn starts (D89), and a failed save is traced while the prompt continues. `src/core/cli/cli_ask.zig`
- Every plain settings key must be listed in `resolved_keys` or `files_only_keys`, which the test named "every plain setting is resolved or deliberately shown from the files" enforces. `src/core/cli/cli_config.zig`
- The model, fast, ultrafast, and effort launch selections that reach the first turn are modelled in `tests/tla/cli/LaunchSelection.tla`. `src/core/cli/cli_surface.zig`
- The doctor reports old v1 sessions that it cannot convert as stuck, with the reason and the copy `fx session recover` would make (D73). `src/core/cli/doctor_runtime.zig`
- Command flag enums must use the same field names as `Flag`, because `fromId` maps a command flag id to `Flag` by tag name. `src/core/cli/agent_run_flags.zig`

### tests/tla/session_manager

- `fx session recover` copies the session up to its last good turn into a new root and leaves the source untouched (D15). `tests/tla/session_manager/system-design.md`
- `peek` reads a saved session without its lock and repairs nothing, and `fx session {id}` and doctor read through it (D37). `tests/tla/session_manager/system-design.md`
- v1 sessions convert when they are opened, including older v1 formats, and a slow conversion shows the notice (D61). `tests/tla/session_manager/system-design.md`
- `fx session` with the id option on a damaged v1 session fails with `InvalidSessionFormat`, naming the file and the reason, and points at `fx doctor` (D78). `tests/tla/session_manager/system-design.md`

- `closeOwnedTerminals` releases `mutex` before taking `backend_mutex`, and it is idempotent. `src/core/terminal/client.zig`
- After `closeOwnedTerminals` sets `backend_closed`, `openBackend` refuses with `RuntimeStopping`, so no terminal starts after the owned terminals were ended for exit. `src/core/terminal/client.zig`
- `finishActive` frees the worker and its intent before the wake broadcast that lets `deinit` finish, so a detached worker cannot touch the allocator after the runtime stops. `src/core/terminal/client.zig`
- `SupportedRegistry` stores `host_identity` without copying it, so the caller must keep it alive for the registry's lifetime. `src/core/terminal/native_session.zig`
- `closeAllForExit` sets `exiting` under the registry mutex, and later session starts are refused. `src/core/terminal/native_session.zig`
- `construct_start_persistence` checks only that `workspace_root` and `cwd` are absolute, so the caller must have decided admission before it runs. `src/core/terminal/operation.zig`
- `PreparedAuthority.view()` borrows its strings and proof until `deinit`. `src/core/terminal/operation.zig`
- The terminal lifecycle that reconcile applies is modelled in `tests/tla/terminal/TerminalLifecycle.tla`. `src/core/terminal/recovery.zig`
- v2 terminal folders live under the terminal directory (D45), and the session-files directory is a fallback for sessions not yet moved (D47). `src/core/terminal/store.zig`
- A full-screen single-line scroll rotates `row_origin` instead of copying cells, so physical cell indexes come from `rowBase`, `cellIndex`, or `physicalIndexForLogicalOffset`, never a raw offset. `src/core/terminal/engine.zig`
- Before its own `builtin` lines, zsh runs `unfunction builtin` when such a function exists, and bash runs `unset -f builtin`. A startup-file function named builtin therefore cannot replace the builtin. `src/core/terminal/shell_resolver.zig`
- Every zsh launch turns off the `equals` option right before the command, because the option expands an unquoted word starting with an equals sign into a command path. `src/core/terminal/shell_resolver.zig`
- `snapshotScript` runs the command single-quoted through `eval` after the replayed aliases exist, with stdin from `/dev/null`. `src/core/terminal/shell_resolver.zig`
- Snapshot capture writes NUL-delimited sections, and each marker carries a per-capture nonce that must be ASCII hex, so startup-file output cannot be mistaken for the payload. `src/core/terminal/shell_resolver.zig`
- Owner mutable fields are guarded by `mutex`, while `capture_fn` and `capture_environ` are fixed at construction and read without the lock. `src/core/terminal/shell_snapshot.zig`
- `acquire` cancellation or deadline ends only that caller's wait and never cancels the capture, so later callers still get the result. `src/core/terminal/shell_snapshot.zig`
- Snapshot capture never logs payload contents, because the environment may hold secrets. Its trace lines record only counts, sizes, and statuses. `src/core/terminal/shell_snapshot.zig`

- A user-environment captured command is not auto-run when `definesAnyWord` finds a snapshot alias or function in it, or when `startupNamesUnknown` is true after a failed capture. `src/core/tooling/tool_admission.zig`

- `ProviderContext` and `GatheredContextSnapshot` own their bytes, so callers deinit them with the allocator passed to the provider or gather call. `src/core/workspace/context_contract.zig`
- Only the main thread replaces or frees the active generation, and `loopCollectFacts` in `src/main.zig` calls `joinThreadIfDone` on every tick. `src/core/workspace/file_index.zig`
- Result paths borrow the active generation, which is destroyed when a newer one is adopted, so results must not be used after `joinThreadIfDone` adopts. `src/core/workspace/file_index.zig`
- Pruned ranking must match full scoring, which the test helper `expectPrunedRankingMatchesFullScoring` checks. `src/core/workspace/file_index.zig`
- The scratch allocator for `collectDirectoryMatches` and `countDirectoryMatchesWithIgnored` must be safe for concurrent use, because each parallel worker builds its own arena on it. `src/core/workspace/grep_search.zig`
- Each parallel worker owns its `ArenaAllocator`, and threads never share one. `src/core/workspace/grep_search.zig`
- Outcome slices point into worker arenas that `ParallelScan.deinit` frees, so the merge copies matches into the caller's arena before `deinit` runs. `src/core/workspace/grep_search.zig`
- The parallel grep claim, finish, fail, and merge steps are modelled in `tests/tla/indexer/GrepCut.tla`. `src/core/workspace/grep_search.zig`
- Each directory-completion request copies its raw query, lookup query, root, and home, so the lookup task never borrows editor or workspace data. `src/core/workspace/directory_completion_job.zig`
- `Job.reconcile` only abandons work, since `Task.stop` sets the cancel flag, and thread joins happen in `Task.deinit`. `src/core/workspace/directory_completion_job.zig`
- `NetworkCall.isError` is the single failure predicate used for the network lifetime counters. `src/core/workspace/network_metrics.zig`

### src/core/auth

- `Provider.context` is a raw pointer that must stay valid for the whole of each synchronous `validate` call. (`src/core/auth/api_key_validator.zig`)
- The `refresh_token` returned in `LocalLogout` is allocated with the caller's allocator, is owned by the caller, and is released with `secret.zeroAndFree` using that same allocator. (`src/core/auth/grok_oauth.zig`)
- A reduced OAuth scope grant is not an error: `login_flow` logs it through `debug_trace` after the token exchange and sign-in still completes. (`src/core/auth/login_flow.zig`)
- `Request.authorization` is not copied, so the caller must keep the slice alive until `execute` returns, since the gateway passes it straight into the HTTP client for that one request. (`src/core/auth/oauth_transport.zig`)
- `Response.body` is allocated with the allocator given to `Provider.execute`, and the caller owns it. `Response.deinit` zeroes the body before freeing it, because OAuth responses can carry tokens. (`src/core/auth/oauth_transport.zig`)
- `Cancellable` stores a pointer to its `cancel_flag` and sets it on every request it forwards, so the flag must outlive all requests sent through it. (`src/core/auth/oauth_transport.zig`)
- The sign-in lock is a lease. Its holder restamps it before each Keychain call and before each issuer request made by the sign-in flows, so a waiter judges the holder by the age of its last stamp. (`src/core/auth/oauth_session.zig`)
- `HostMutation` has no lock file, so its `restamp` does nothing. The lease protocol applies only to native builds, because `Mutation` selects `NativeMutation` on non-wasm targets. (`src/core/auth/oauth_session.zig`)
- `openCurrentWith` opens the login file with `no_follow`, so a symlink at the login file name is not followed. It reopens the file, up to `max_opens` times, when the opened file has no links left, because the file may be replaced or deleted between open and stat. (`src/core/auth/session_presence.zig`)
- The `CurrentFile` returned by `openCurrent` is owned by the caller, who must close its `file`. (`src/core/auth/session_presence.zig`)
- `await_request` tries up to `max_accepts_per_poll` (16) queued connections in one poll and returns the first one the `parse` function accepts, or null when none is ready. Unrelated connections get a reply, and idle ones are dropped; neither ends the poll. (`src/core/auth/browser_callback.zig`)
- Provider-specific parsing and error classification belong to the `parse` function the caller passes in. (`src/core/auth/browser_callback.zig`)
- A connection that sends nothing for `silence_ms` (250 ms) is dropped, so an idle browser connection holds up the poll for at most that long. (`src/core/auth/browser_callback.zig`)
- A browser form POST is accepted only when its `Origin` header equals the `form_origin` the caller passes, and only as a form-urlencoded POST to `/slack/oauth/callback` with a `127.0.0.1:<port>` host header. (`src/core/auth/browser_callback.zig`)
- `resolvePreferring` never replaces a non-null `preferred` source with automatic precedence: if that source is missing or fails to load, the result reports its status instead. `resolveForProvider` turns chatgpt and grok preferences into null on the gateway path, so those still use precedence there. (`src/core/auth/credentials.zig`)
- `loadSource` takes no `LoadMode`, and for `.fx_login` it calls `loadFxLoginCredential`, which refreshes an expired session. A load that must not refresh should use `loadPreferredSource` in `.stored` mode, which reads the saved login without refreshing. (`src/core/auth/credentials.zig`)
- The teams request sets `max_response_bytes` to `teams_response_max_bytes` (4 MiB) instead of the 64 KiB limit the gateway OAuth transport applies when no limit is given. (`src/core/auth/login_flow.zig`)
- `logout` calls `logoutLocally` first, which deletes the saved fx login and returns the session, and only then calls `revokeLoggedOutSession` on that session. `logout` releases the returned session with `Session.deinit` using the same allocator it was given. (`src/core/auth/login_flow.zig`)
- When started without a prepared login, the sign-in worker fetches the device code before it polls. The cooperative start path spawns no worker, so it returns `LoginFlowMissing` unless it is given a prepared login. (`src/core/auth/login_flow.zig`)
- Tests that point `HOME` at a fixture must disable the Keychain with `FX_DISABLE_KEYCHAIN`, as the `StartupCredentialTestEnv.install` helper does, because the Keychain item is keyed by service and account rather than `HOME`. Without this, a fixture fx login could migrate into the developer's real `FX_OAUTH_SESSION_V1` item. (`src/core/app/app_auth_runtime.zig`)
- The `refreshModelCredential` and `refreshGatewayCredential` callbacks skip an `.if_needed` refresh when the same source was verified within the last 30 seconds, while `.force` and `.reload` always refresh. A stale skip costs one unauthorized response, which the orchestrator's `.force` refresh and replay can recover when its replay decision allows it. (`src/acp/server.zig`, `src/core/app/app_callbacks.zig`, `src/core/auth/auth_runtime.zig`)
- `RemoteRevocation.deinit` frees its session or token with `std.heap.c_allocator`, so a revocation target must hold memory from that allocator. The app logout path obtains its session from `logoutLocally(std.heap.c_allocator)` in `src/core/app/app_auth_runtime.zig`. (`src/core/auth/auth_runtime.zig`)
- The API key save worker never writes `selected_credential`. It returns an `ApiKeySaveOutcome`, and the main thread adopts any loaded credential in `takeApiKeySaveResult`. (`src/core/auth/auth_runtime.zig`)
- The startup credential worker is the only writer of `StartupCredentialTask.outcome` while it runs, and `takeOutcome` joins the worker before it reads the outcome. (`src/core/auth/auth_runtime.zig`)
- `prepareCredential` returns null when no usable credential exists (invalid or absent), and returns an error for storage, persistence, authority, or temporary failures. (`src/core/auth/auth_runtime.zig`)
- A `Credential` returned by `prepareCredential` or `refreshCredentialForAccount` belongs to the caller, who must release it with `Credential.deinit`. (`src/core/auth/auth_runtime.zig`)
- `beginRemoteRevocation` takes ownership of its `RemoteRevocation` target on every call and releases it itself when it returns false, so the caller must not release it afterwards. (`src/core/auth/auth_runtime.zig`)
### src/core/indexer

- `save` deletes the snapshot file when every tree is empty, so a later `load` cannot restore stale entries; otherwise it replaces the file with a verified durable write. (`src/core/indexer/snapshot.zig`)
- `RepositoryWide.lists` is ordered lowest precedence first, with the global excludes file before `info/exclude`, so `ignore.decide` lets later lists override earlier ones. (`src/core/indexer/sources.zig`)
- The excludes file follows a final symlink only when its `core.excludesfile` entry comes from the system or global config scope. (`src/core/indexer/git_config.zig`)
- `loadDirectory` appends `/` itself to a non-empty `rule_dir`, so callers pass an empty string at the repository root and a path without a trailing slash everywhere else. (`src/core/indexer/sources.zig`)
- `Outcome.unavailable` reasons are static strings from `@errorName` or literals, so holders such as `sources.Unavailable.reason` can keep them without copying. (`src/core/indexer/bounded_read.zig`)
- `readUserAbsolute` follows a final symlink and opens only a regular file within the size cap, because user config paths may be links; `readAbsolute` and `readAt` never follow a final symlink. (`src/core/indexer/bounded_read.zig`)
- `readSized` allocates its buffer from the `stat` size plus one byte, and returns null so the caller streams the file when it grew after the `stat`. (`src/core/indexer/bounded_read.zig`)
- An unknown POSIX character class aborts the whole wildmatch, not just one branch. (`src/core/indexer/wildmatch.zig`)
- `max_steps` (20,000) bounds backtracking in wildmatch, and an exhausted budget counts as no match, so the path stays listed rather than hidden. (`src/core/indexer/wildmatch.zig`)
- `isPathExcluded` treats a path as excluded when any ancestor directory is excluded, because git never looks inside an excluded directory. (`src/core/indexer/ignore.zig`)
- `Pattern.literal_len` is the wildcard-free head that `matchPathname` compares directly, and only the remainder goes to `wildmatch`. (`src/core/indexer/ignore.zig`)
- `matchBasename` passes no pathname flag to `wildmatch`, because a basename never contains a slash. (`src/core/indexer/ignore.zig`)
- For v2 and v3 indexes the entry paths borrow from the data buffer, so the caller keeps `Index.data` alive while it uses the entries; `git_index.read` frees that buffer itself on a parse error. (`src/core/indexer/git_index.zig`)
- Repository discovery must accept exactly the directories git accepts, otherwise git would walk past a directory fx stopped at and read another repository's config. (`src/core/indexer/layout.zig`)
- A tree stamp is reusable only when its mtime and ctime are both at least two seconds older than the scan start, to cover coarse filesystem timestamps such as FAT's two-second granularity and small clock differences. (`src/core/indexer/tree.zig`)
- A source stamped with `identity_only` (the `.git` paths of the repository and its ancestors) is compared by inode alone when it is a directory, because a `.git` directory's times change with every git command. (`src/core/indexer/tree.zig`)
- `Tree.cap_reached` alone does not block reuse, because the cap cut is taken from the sorted entries after a complete walk; a walk that stopped at the collect limit sets `incomplete` instead. (`src/core/indexer/tree.zig`)
- Reuse checks the folders at, below, or above a subtree and always checks every source, because a `.gitignore` in a parent folder changes what the subtree lists. (`src/core/indexer/tree.zig`)
- A saved listing is reused only under the same values of the environment variables in `config_environment_names`, since the git config loaded depends on them. (`src/core/indexer/indexer.zig`)
- In `every_include` mode every `includeIf` counts as included, so no condition can hide a filter driver. (`src/core/indexer/git_config.zig`)
- Once the collect limit is reached, workers stop reading folders, so memory stays bounded; the result is marked incomplete and the folders read depend on thread timing. (`src/core/indexer/scan.zig`)
- The index bytes are allocated from the scan's own allocator rather than the result arena and are freed when the scan returns. (`src/core/indexer/scan.zig`)
- Source stamps for user-scope config files and the excludes file follow a final symlink, so an edit to the linked target invalidates the cached listing. (`src/core/indexer/scan.zig`)
- The scan's allocator is used by worker threads, so it must be safe to call from several threads. (`src/core/indexer/scan.zig`)
- Config loads are bounded to 10 include levels, 64 files, and 1 MiB total, so a self-including file cannot be read exponentially many times. (`src/core/indexer/git_config.zig`)
- A key with no `=` reads as boolean true, and `parseBool` returns null for a value it does not accept as a boolean. (`src/core/indexer/git_config.zig`)
- Skipped names are not applied inside a repository, because the skip check runs only when the scan is not in repository mode. (`src/core/indexer/scan.zig`)
### src/core/output

- `State.finality_floor` returns null for the `.append_only` policy or when no boundary is pending, and a null floor lets the whole prepared flow be released to native terminal history. (`src/core/output/transcript_release.zig`)
- `waitsForUser` is true only for a route recovery of kind `need_user`; `app_input_runtime` then makes Enter on an empty composer continue the request and Esc cancel it. (`src/core/output/worker_status.zig`)
- `syncWaitingClock` must run whenever the waiting state may change: a wait start freezes `waiting_since_ms`, and resume moves `turn_started_ms` forward by the length of the wait. (`src/core/output/activity_status.zig`)
- The label returned by `compactionProjection` points into `buf` or into static text, so `buf` must outlive the projection. (`src/core/output/activity_status.zig`)
- `OperationId` is a process-local counter starting at 1, separate from turn ids, since one turn can run several compactions. (`src/core/output/compaction_activity.zig`)
- `Feedback.err` keeps the original `anyerror` value so callers can match on the error itself. (`src/core/output/compaction_activity.zig`)
- `State.queued` resets `started_at_ms` for every origin, while `compactionClock` reads it only for manual compactions, so automatic compactions keep the turn clock. (`src/core/output/compaction_activity.zig`)
- A deferred full review is consumed once: its `DiffEntry.deferred` is cleared before the saved content is read. (`src/core/output/diff.zig`)
- `ReviewCapture` cannot return errors from its visitor, so an allocation failure sets `failed`, and `captureReviewLines` then returns `error.OutOfMemory`. (`src/core/output/diff.zig`)
- `previewLinesForPresentation` returns lines whose text borrows from the input rows, so the caller frees only the returned slice. (`src/core/output/diff.zig`)
- Captured rows must render to the same full diff text as the live review; `expectCapturedReviewMatchesLive` and `fuzzDiffRows` in `diff.zig` assert this. (`src/core/output/diff.zig`)
- `Anchor.archive` with `entry_index = maxInt(usize)` resolves to the last entry of the cycle, because `sourceRange` clamps the requested index to `total_entries - 1`. (`src/core/output/full_transcript_page.zig`)
- The footer uses `short_label` in place of `label` only when the row is narrower than the full label, so a status that ends in an action keeps that action visible when it is clipped. (`src/ui/footer/render_input.zig`)
- The `activity` slices in a `LifecycleSnapshot` point into presenter state, such as worker status buffers or transcript entry text, so they are valid only while that state is unchanged. The `tool_name` in a `LifecycleTransition.terminal_record` is owned by the tool activity state and freed when that record's name is replaced or the record is removed, so copy it if it must outlive a later lifecycle event for that call. (`src/core/output/activity_runtime.zig`)
- `stepModelCalls` gives the last call of a step to `after`, unless that call failed, in which case every call of the step goes to `before`. Earlier calls, including failed attempts and compaction calls, are in `before`. (`src/core/output/full_transcript_metadata.zig`)
- `usage_exit_code` (2) is the exit status for a bad command line, such as an unknown command or a bad `fx replay` argument, and `fx ask` uses it for an unknown provider given as a flag. A run whose command line was accepted but then failed exits with 1. (`src/core/output/output_contracts.zig`)
- `ShellSession.open.saved` is true only when the session log is on disk, which is what lets the session be reopened by its id with the resume flag. This is design decision D90 in `tests/tla/session_manager/system-design.md`. (`src/core/output/output_contracts.zig`)
- Both `panelRows` functions allocate every row and value from the allocator they are given, and every caller passes an arena. (`src/core/output/output_contracts.zig`)
- `CreditsSnapshot.deinit` frees `balance`, `used`, `plan` and `err_message` but never `raw_json`, so whoever sets `raw_json` must keep that memory alive itself. (`src/core/output/output_contracts.zig`)
### src/core/agent/runtime

- `ErrorProvenance` is written only on the failure path of a compaction and is reset to null at its start, so a stale value from an earlier failure is never reused. (`src/core/agent/runtime/orchestrator.zig`)
### src/core/agent

- `compaction_activity.State` is a field of `WorkerRuntime`, and `beginCompactionActivity` takes `worker_mutex` before changing it. (`src/core/agent/worker_runtime.zig`)
### src/core/app

- `back = 1` in a transcript archive anchor is the newest archived cycle, the one just before the held entries, and larger values reach further back. (`src/core/app/app_session_runtime.zig`)
### src/core/shared

- A waiter gives up only when the holder's last stamp is 17 s old (`mutation_lock_wait_ms`, the 15 s step plus `leased_lock.slack_ms`), so a holder that keeps restamping is never timed out, however long the whole operation takes. (`src/core/auth/oauth_session.zig`)
### src/core/config

- `Registry.parse` takes an already-built `std.json.Value`, which cannot show keys that another parser discarded, so callers must parse the JSON with duplicate keys rejected at every depth before calling it. (`src/core/config/configured_provider.zig`)
- The `Registry` returned by `Registry.parse` owns its storage, so the caller must release it with `Registry.deinit` using the same allocator that was passed to `parse`. (`src/core/config/configured_provider.zig`)
- Pointers from `Registry.get`, and the strings inside the returned `Definition`, are valid only until `Registry.deinit` runs. (`src/core/config/configured_provider.zig`)
- For a renamed object key such as `statusLine`, a child under the older name is shown only when the current name does not set that same child. (`src/core/config/settings_entries.zig`)
- Ultrafast is opt-in. `resolveUltrafastProviderOptions` returns `UltrafastUnavailable` instead of silently downgrading when the provider is not Gateway, the model is not an `openai/` model, or the Gateway metadata does not report `supports_ultrafast_mode`. (`src/core/config/model_capabilities.zig`)
- When `single_system_message` is set, which the Gateway policy does for `alibaba/` models, the Gateway request joins the leading system messages into one. (`src/core/config/model_capabilities.zig`)
- `provider_order` borrows its slugs, so they must stay alive until the Gateway request body has been serialized, because `writeProviderOptions` reads them at that point. (`src/core/config/model_capabilities.zig`, `src/gateway/vercel_protocol.zig`)
- Opening the home directory in read-only tightening mode removes group and other write access instead of refusing to load, and records it in `tightened`. The same is done for `settings.json`. If the change cannot be made, the open fails with `PrivateStatePermissionsUnsupported`. Startup then adds a note explaining the change, because other users could otherwise write to `~/.fx`. (`src/core/config/settings_store.zig`)
- If a user layer fails to parse, nothing from that layer is merged. Its `provider`, `providers` and `models` keys are then parsed alone, so a broken sibling such as a mistyped effort does not lose the configured connection. Workspace layers do not read `providers` definitions in that re-parse, and the original error is returned only when the routing keys themselves are invalid. (`src/core/config/config_runtime.zig`)
- `FX_PROVIDER_ORDER`, `FX_PROVIDER_STRICT` and `FX_REVIEW_MODEL` are applied after the settings merge and again after per-run overrides are merged, so they win over settings files. Invalid values are ignored with a debug trace. (`src/core/config/config_runtime.zig`)
- A `.fx.json` project file that sets a profile-only key has that key ignored, and fx records an `ignored_project_user_only_setting` diagnostic for it, which startup reports. (`src/core/config/settings_keys.zig`)
- A superseded key such as `model` (superseded by `models.gateway`) is still read by the loader, but the settings schema marks it deprecated and shell completion leaves it out. (`src/core/config/settings_keys.zig`)
- `findUnknown` checks key names and the names of children under switch keys only, so it does not judge value types. (`src/core/config/settings_keys.zig`)

### src/core/images

- `Event.turn_started` resets the route state to the new turn's support value, which clears any pending request left by the previous turn, as the `TurnStarted` action in `tests/tla/image_route/spec/ImageRoute.tla` also does. (`src/core/images/image_route.zig`)
- The image route core takes only the boolean flags of `Request` and `Support` values, never image bytes, so the shell must reduce each request to those flags before calling it. (`src/core/images/image_route.zig`)
- The `file-input` tag does not affect image routing: `supportFromCatalog` derives `Support` from `vision` alone, so a catalog listing vision gives native image input with or without file input. (`src/core/images/image_route.zig`)
- `abstract` returns the model variables `support`, `resolved`, `notified` and `pending`, and its `pending` slice points into the `State` it was built from, so the view is valid only while that state is alive. (`src/core/images/image_route.zig`)
- `expectLaws` runs on every step that `driveCore` takes, in both the fuzz test and the seeded random test, so the Zig tests check the core against the model's laws. (`src/core/images/image_route.zig`)
- Bytes read by `ImageBytes.read` are only the prefix that was copied, so callers must use the returned slice's length, not the buffer's. The prefix is short at the end of the data, and for base64 input it also stops at the first group that does not decode. (`src/core/images/image_data.zig`)
- The SDK prompt image limits `maxPromptImages` and `maxPromptImagesBytes` in `sdk/engine.js` must match the core constants `max_libfx_prompt_images` and `max_libfx_prompt_images_bytes`, which `fitsLibfxPrompt` in `src/acp/prompt.zig` checks against. (`src/core/images/image_attachments.zig`)
- `openVisionRegularFile` checks the source with `follow_symlinks = false` and opens it with `NOFOLLOW` on POSIX, so a symlink at the final path is refused and the capture reports `ImageTargetChanged`. (`src/core/images/image_attachments.zig`)
- The dimension cache copies each key with `cache_alloc` instead of borrowing the attachment's snapshot digest, so a cache entry outlives the attachment that produced it. (`src/core/images/image_attachments.zig`)
- `savedImagePath` returns the session blob path first, then the snapshot path, and null for inline-only images. It never returns the original attached path, which the user can change after attaching it. (`src/core/images/image_attachments.zig`)
- `withholdEarlierImages` removes withheld earlier images (`withheld_unknown` or `withheld_dead_end`) only from the request's copy of the messages, so the session keeps them. (`src/core/images/image_attachments.zig`)
- `withholdDroppedImages` and `noteAttachmentLocations` return the input `messages` unchanged when they change nothing; otherwise they copy the messages into the arena and edit only the copy, so session history is never modified. (`src/core/images/image_attachments.zig`)
- A prompt image saved in a session becomes its own blob named by its digest when its turn starts, as design decision D89 in `tests/tla/session_manager/system-design.md` specifies. (`src/core/images/image_attachments.zig`)
- Snapshot directories are opened with `iterate`, and `syncSnapshotDirectory` fsyncs the directory after the snapshot rename, a sync that an `O_PATH` descriptor on Linux would reject. (`src/core/images/image_attachments.zig`)
- A fork hard-links its source's blobs (`linkBlobs` in `src/core/session_manager/session.zig`, with a copy fallback), so a blob may have several links, while a snapshot file is accepted only with exactly one link. (`src/core/images/image_attachments.zig`)
- Blob paths are opened as named, without a no-follow walk of their parent folders, while snapshot paths are opened through `openDirectoryNoFollow`; neither file may be a symlink, since both opens pass `follow_symlinks = false`. (`src/core/images/image_attachments.zig`)
- `inlineCapturedSnapshot` turns a snapshot-backed attachment into one holding its verified bytes inline, and `inlineCapturedSnapshots` applies it to each attachment. The callers in `src/core/app/app_session_runtime.zig` and `src/core/cli/cli_ask.zig` invoke it only when a v2 session is open. (`src/core/images/image_attachments.zig`)
- `cloneVerifiedImageAttachment` gives an inline or blob-backed image its own copy of the verified bytes and writes no file, as design decision D84 in `tests/tla/session_manager/system-design.md` specifies. (`src/core/images/image_attachments.zig`)
- `load_inline_image_attachment` decodes a literal-payload token once before loading the image, and the caller owns the returned attachment. (`src/core/images/image_attachments.zig`)
- `resolve_authorized_images` returns pointers into its `catalog` argument, so the catalog must outlive the result, and the caller frees only the returned slice, with the same allocator. (`src/core/images/image_attachments.zig`)

### src/core/input

- `input_reset.State` holds pointers into Runtime fields, so it must not outlive the Runtime it was built from. Source: `src/core/input/input_reset.zig`
- `editor_state.State.deinit` must receive the same allocator that `setText` and `insertSlice` were called with, because the composer text is allocated through those methods. Source: `src/core/input/editor_state.zig`
- `Runtime.model_picker_draft` holds the composer state captured when the model picker borrows the composer, and `restoreModelPickerDraft` restores it when the flow is reopened or fails. Source: `src/core/input/runtime.zig`
- `composer_stash` capture moves the live composer state out and leaves it empty, and restore frees the flow-era state before moving the stash back. Source: `src/core/input/composer_stash.zig`
- `Query.query` holds the raw payload, so a lookup key must come from `decoded_query`. Source: `src/core/input/file_picker_path.zig`
- `effort_menu.State.open` copies the model name before changing any state, so a failed open leaves the menu unchanged, and close must receive the allocator passed to open. Source: `src/core/input/effort_menu.zig`
- stage takes ownership of the rows and frees any earlier staged rowset, and only acknowledge, given the exact captured revision, moves a staged rowset to presented and marks the selection trusted. Source: `src/core/input/file_completion_state.zig`
- A replayed terminal byte waits in `replay_byte_after_routing` until Core routes the action decoded before it, so admission and cancellation context come from the original byte boundary. Source: `src/core/input/input_action.zig`
- `takeNavigation` moves the draft out of the history, so the returned `NavigationSnapshot` belongs to the caller, who must deinit it. Source: `src/core/input/composer_history.zig`
- Prepared owns the staged replacement bytes until commit, and its deinit must receive the allocator passed to prepare. Source: `src/core/input/composer_text_replacement.zig`
- After commit, the prepared value holds the displaced editor buffer, which its deinit frees. Source: `src/core/input/composer_text_replacement.zig`
- `FileListingWait` holds the frame for up to 8 ms after a folder listing starts, so the keystroke that started it paints with its rows, as modelled in `tests/tla/indexer/ListingWait.tla`. Source: `src/core/input/picker_state.zig`
- `State.deinit` must be called with the allocator that `beginModelPickerFlow` was given. Source: `src/core/input/picker_state.zig`
- `ExpandResult.owned` is false when the expanded text is borrowed, so callers free only owned results. Source: `src/core/input/pasted_blocks.zig`
### src/core/shell_command

- `unsafe_compound_indicator` treats any input its scanner cannot read as unsafe, so it is conservative and does not model the full POSIX grammar. Source: `src/core/shell_command/command_lex.zig`
- `word_end` follows shell quoting and substitution rules, while `next_token` splits on whitespace alone, so `next_token` cannot find the end of an assignment value that contains spaces. Source: `src/core/shell_command/command_classification.zig`
- The git child environment uses a fixed `PATH` and locale, disables prompts, pagers and optional locks, and does not pass `GIT_DIR` or `GIT_CONFIG_PARAMETERS`. Source: `src/core/shell_command/safe_git.zig`
- `trustedExecutable` checks only fixed absolute git locations and never uses `PATH`, because `PATH` can include directories a repository controls. Source: `src/core/shell_command/safe_git.zig`
- `versionCheck` caches one result per executable for the process, and a probe with no output is not cached, so a transient failure does not disable git for the session. Source: `src/core/shell_command/safe_git.zig`
- `sameRepository` confirms that git resolves the same repository whose config fx read, so git cannot run with unread config. Source: `src/core/shell_command/safe_git.zig`
- Only an unquoted && token separates stages, so a quoted or escaped one is an argument. Source: `src/core/shell_command/command_effect.zig`
- The zsh parity case runs with the same unsetopt equals prelude that `shell_resolver` applies before each command. Source: `src/core/shell_command/command_effect.zig`
- dash is its own parity shell entry, and the `zsh with extendedglob` parity case runs with extendedglob, which makes ^ and # glob operators. Source: `src/core/shell_command/command_effect.zig`
- The CI and fuzz workflows set `FX_TEST_SHELL_PARITY_ALL_SHELLS`, which the parity test reads to require every shell. Source: `src/core/shell_command/command_effect.zig`
- `parity_review_free_commands` run unreviewed and must behave the same in every shell, and `parity_probe_commands` are near misses that run as parsed when fx runs them unreviewed. Source: `src/core/shell_command/command_effect.zig`
- `knownReversibleAutoCommand` accepts only a small set of ordinary commands for auto mode, and commands with dynamic shell syntax stay on the review path. Source: `src/core/shell_command/command_effect.zig`
### src/core/execution

- Config slices and callbacks must stay valid for the whole `executeCommand` call. Source: `src/core/execution/command_runner.zig`
- `Config.extra_environment` is applied after `AI_AGENT`, so an extra variable can override it. Source: `src/core/execution/command_runner.zig`
- `natural_completion_drain_max_bytes` (2 `MiB`) bounds the leftover drain, so output past that bound points to a detached process still writing. Source: `src/core/execution/command_runner.zig`
- `cleanupCompletedForegroundTarget` kills only attached descendants of a naturally completed command, so detached daemons keep running. Source: `src/core/execution/command_runner.zig`
- `ReplayMarkerFilter.install`'s slot must outlive the run, since the filter writes its state into that slot. Source: `src/core/execution/command_runner.zig`
- `spawnDetachedSession` keeps the child's stdin open as the supervisor's lifeline, which `finishDetachedSession` closes to end the session. Source: `src/core/execution/command_runner.zig`
- `finishDetachedSession` closes the lifeline so the supervisor stops the target and its tracked descendants, and the supervisor's process group is killed only if it still runs after `detached_session_exit_wait_ms`. Source: `src/core/execution/command_runner.zig`
- `approvalResetResult` reports a stale shell approval without running the command, so the next request asks for approval again. Source: `src/core/execution/command_runner.zig`
- A remembered shell grant carries the approval epoch it was made under, and `command_runner` asks again when that epoch no longer matches the current one. Source: `src/core/execution/command_runner.zig`
- `executePreparedCommand` takes the `PreparedCommand` by value and does not free its plan, so the caller still calls `PreparedCommand.deinit`. Source: `src/core/execution/local_executor.zig`
- A non-zero `yield_hold` count keeps `startCaptured` from ending at `yield_time_ms`, because the command is waiting on an fx mcp call; the shell bridge registration sets it. Source: `src/core/execution/managed_execution.zig`
- `terminateForProcessExit` force-stops every live command and joins their worker threads, so no command outlives fx. Source: `src/core/execution/managed_execution.zig`
- `joinEntry` serializes joins with a per-entry mutex, so concurrent callers return only after the worker thread has exited. Source: `src/core/execution/managed_execution.zig`
- A process whose session cannot be read stays attached so containment is kept, while attached processes stop at natural completion and detached ones in their own session keep running. Source: `src/core/execution/process_tree.zig`
- Before signalling a tracked process, the tracker checks its recorded identity, so a reused `PID` is not signalled. Source: `src/core/execution/process_tree.zig`
- The tracker sends `STOP` to parents before children, so a parent cannot start its next command after a child dies. Source: `src/core/execution/process_tree.zig`
### src/core/permissions

- `ApprovalPrompt.projection` returns a view that borrows the prompt's request and draft storage, so it must not be used across a later prompt mutation. Source: `src/core/permissions/approval_prompt.zig`
- The permission prompter is transport-neutral: policy evaluation and grant construction stay in tool admission, and transports only present requests and may retain grants through `retainGrant`. Source: `src/core/permissions/permission_prompter.zig`
- Amendment edits resolve their draft and cursor through `slotForChoice`, and the allow and deny ids (0 and 2) must match the ids used by `draftForChoice` and `cursorForChoice`. Source: `src/core/permissions/approval_amendment.zig`
- `PermissionRequest.tool_arguments_preview` is display-only: the approval UI and approval registry read it, no execution code reads it, and renderers must treat it as untrusted terminal input. Source: `src/core/permissions/permission_request.zig`
- `evaluatePreparedFileMutationTargets` takes ownership of the prepared targets, relinquishing the caller's copy, and rejects them unless their proof is valid. Source: `src/core/permissions/permissions.zig`
- `sessionGrantIsLive` keeps a bash session grant only while the shell owner reports it current, so a shell refresh retires the grants made before it. Source: `src/core/permissions/permissions.zig`
- `liveSessionGrants` returns a new slice that the caller frees, while the grant strings it contains stay borrowed from the input. Source: `src/core/permissions/permissions.zig`
- A caution decision is cleared unless it names `prompt_injection` or `system_harm` and quotes source evidence for that harm. Source: `src/core/permissions/auto_classifier.zig`
- `prompt_injection` quotes must come from untrusted tool output or a receiver screen, while `system_harm` quotes come from the pending action or must meet the injection rule. Source: `src/core/permissions/auto_classifier.zig`
- A caution clears only when one fresh unchecked review of the same request returns a valid non-caution decision, and any other outcome keeps the hold. Source: `src/core/permissions/auto_classifier.zig`
- `AskUserQuestion` answers are excluded from the untrusted evidence that prompt-injection quotes can come from. Source: `src/core/permissions/auto_classifier.zig`
- `trusted_root_context` is the only text the reviewer is given as trusted authority. Source: `src/core/permissions/auto_classifier.zig`
- Evidence quotes must match a run of at least 40 normalized bytes, and for long sources the run search covers only the first and last 16 `KiB`. Source: `src/core/permissions/auto_classifier.zig`
- `writeBoundedField` is a compile-time check that refuses a review-data label missing from `copied_field_labels`, so review data and the proof check cannot drift. Source: `src/core/permissions/auto_classifier.zig`
- `withoutFieldLabel` strips only labels that the review data uses, so a quoted instruction keeps its first word. Source: `src/core/permissions/auto_classifier.zig`
- Decide retries a transport failure once and a malformed completion once, and each retry is a separate review send. Source: `src/core/permissions/auto_classifier.zig`
- `rootUserRequestContext` returns the request part of a canonical root context before its permission-feedback section, borrowed from its input. Source: `src/core/permissions/auto_classifier_context.zig`
- Compacted summaries add no user-authored turns to the canonical root context, since only history entries whose user author is the user are collected. Source: `src/core/permissions/auto_classifier_context.zig`
- `buildAgentTurnRootUserContext` passes no current request, so the user's last request in history stands as current, and `Finished.user` is null when the turn was opened by someone other than the user. Source: `src/core/permissions/auto_classifier_context.zig`
- `buildToolExecutionRootUserContext` appends only trusted permission feedback to the root context. Source: `src/core/permissions/auto_classifier_context.zig`
### src/core/hosts

- The host's `fx_journal_flush` must return 0 only once it holds every event sent so far, and `flush()` maps any nonzero result to `error.JournalFlushFailed`. Source: `src/core/hosts/js_host_journal.zig`
- The host steering state is -1 when closed, and otherwise packs the queued count shifted left one bit with the handoff flag in the low bit. Source: `src/core/hosts/js_host_steering.zig`
- `takeAll` reads each host steer as an id, a newline, and text, and an empty id becomes null. Source: `src/core/hosts/js_host_steering.zig`
- `max_instruction_file_bytes` must match the `SDK`'s `workspaceInstructionFileLimit` in `sdk/wasm-runtime.js`, both 1 `MiB`. Source: `src/core/hosts/js_host_workspace.zig`
- The instruction-file read maps status 0 to a copied file, -6 to a missing file, -2 to host-unreadable and -4 to an unsafe path, and any other status to an unreadable error. Source: `src/core/hosts/js_host_workspace.zig`
- The instruction-file value from `instructionFiles` borrows home from the host metadata, so it must not outlive that metadata. Source: `src/core/hosts/js_host_workspace.zig`
- `native_secret_store`'s `isDisabled` delegates to the macOS keychain module, which owns the disable switch. Source: `src/core/hosts/native_secret_store.zig`
- A missing secret file loads as null, while other read errors propagate, so callers must not read a read error as absence. Source: `src/core/hosts/native_secret_store.zig`
- `storeInteractive` hands the secret to the macOS keychain's interactive prompt so plaintext stays out of fx, and returns false on other platforms. Source: `src/core/hosts/native_secret_store.zig`
- The account buffer must outlive any argv built from it, because the argv slices borrow it. Source: `src/core/hosts/native_keychain.zig`
- `abandonMcpKeychainRun` zeroes a late keychain result before freeing it, because it can hold credentials. Source: `src/core/hosts/native_keychain.zig`
- The store child is killed by a deferred `child.kill`, so it does not keep running when the store returns early. Source: `src/core/hosts/native_keychain.zig`
- Host port arguments are borrowed for the duration of the call, so the caller keeps ownership of url, label, text, path and value. Source: `src/core/hosts/host.zig`
- `UrlOpener.open` returns false when the host cannot open the `URL`, so callers keep a manual fallback. Source: `src/core/hosts/host.zig`
- The default `SecretStore` interactive write returns false, which tells callers the host has no interactive prompt. Source: `src/core/hosts/host.zig`
### src/core/shared

- The durable replace path creates its temp file with mode 0600 and checks that the result is a single-link regular file. Source: `src/core/shared/io.zig`
### src/core/recovery

- A closing signal saves the record with the clean-exit flag set, so the request resumes at the next launch. Source: `src/core/recovery/recovery.zig`
- `recovery.zig` takes time only as the `now_ms` argument, and a Start marked stale by the host asks the user instead of resending. Source: `src/core/recovery/recovery.zig`
- Offline, dropped, unreadable, server and rate-limited failures wait and resend, while rejected, sign-in, quota and content-filter failures ask the user, and a too-long failure compacts once. Source: `src/core/recovery/recovery.zig`
- Flags is a packed struct, so its bit layout is part of the saved record format. Source: `src/core/recovery/recovery.zig`
- Waits keep 80 to 100 percent of their table value, so no wait exceeds the 30 s largest backoff entry. Source: `src/core/recovery/recovery.zig`
- A resend keeps its retry status only for `handoff_ms` (2 s) while in flight and not yet flowing, so the status clears afterwards (`tests/tla/recovery/RecoveryTimed.tla` `HandsOff`). Source: `src/core/recovery/recovery.zig`
- Two abrupt in-flight deaths make the next launch ask the user instead of resending, a stale start asks first, and a clean-exit record resumes without asking (`tests/tla/recovery/Recovery.tla` `CrashLoopAsks` and `ResumesAfterClose`; `tests/tla/recovery/Resume.tla` `OldAsks`). Source: `src/core/recovery/recovery.zig`
- A new request shows no recovery status until a fault occurs (`tests/tla/recovery/Recovery.tla` `NoFalseAlarm`). Source: `src/core/recovery/recovery.zig`
- Once the answer is flowing, the recovery status is clear, so a retry warning never sits over a streamed answer (`tests/tla/recovery/Recovery.tla` `StatusHonest`). Source: `src/core/recovery/recovery.zig`
- Every send goes out with a save, so the record knows whether a send is in flight (`tests/tla/recovery/Recovery.tla` `SaveBeforeSend`). Source: `src/core/recovery/recovery.zig`
- A transient failure always waits before the next send (`tests/tla/recovery/Recovery.tla` `NoHotRetry`). Source: `src/core/recovery/recovery.zig`
- Compacting changes the request, so `compactAndSend` sends it at once with `compact_first` set rather than as a wait-then-resend. Source: `src/core/recovery/recovery.zig`
### src/core/agents

- `root_instance` is written only while it is null, from the main loop, so it is set once per subagent. Source: `src/core/agents/agent.zig`
- `Completion.finish` records the first outcome under its mutex, and result reads it under the same mutex, so a slot thread can read it safely before freeing. Source: `src/core/agents/child_run.zig`
### src/core/upgrade

- `TransferInterrupt` publishes the request socket and clears it under the same mutex, and `interrupt()` shuts down only a published socket. Source: `src/core/upgrade/upgrade_helpers.zig`
- `stop_join_budget_ms` caps how long `stop()` waits for the upgrade thread after cancellation, so a blocked network read cannot hold up process exit. Source: `src/core/upgrade/auto_upgrade.zig`
- `sweepStaleDownloadDirs` removes download directories older than one hour, which are left behind by a process that ended mid-download. Source: `src/core/upgrade/auto_upgrade.zig`
- `installUnlessStopped` holds `install_mutex` across its stop check and copy, and `stopForProcessExit` takes the same mutex, so an install in progress finishes before exit and none starts after it. Source: `src/core/upgrade/auto_upgrade.zig`
### src/core/mods

- `ToolRegistry.lookup` returns the first tool with a matching name, and nothing checks for duplicate names, so duplicates are a caller error. Source: `src/core/mods/registry.zig`
### src/core/profiles

- A null tools list places no restriction on the profile, so the agent keeps its parent's tools; in a list, `*` matches every tool and `!name` removes one. Source: `src/core/profiles/profiles.zig`
- A project profile's files must resolve inside the repository, or inside the project root when there is no repository, while home profiles are not confined. Source: `src/core/profiles/profiles.zig`
- The builtin main and agent profiles set no tools, `MCP` servers, or permission mode, so they inherit everything from the agent that starts them. Source: `src/core/profiles/profiles.zig`
- `readFile` reads only regular files, so a link to a terminal, pipe or device cannot hang fx. Source: `src/core/profiles/profiles.zig`
### src/core/skills

- `CanonicalSkillPaths` dedupes skills by canonical directory, so aliases collapse while distinct skills that share a name stay separate. Source: `src/core/skills/skill_runtime.zig`
- `configured_symlink_authorities` is process-wide and guarded by a mutex, because a workspace switch can replace it. Source: `src/core/skills/skill_runtime.zig`
- `setConfiguredSymlinkAuthorities` skips relative and .. entries and keeps entries that cannot be canonicalized verbatim, so they match once the directory appears. Source: `src/core/skills/skill_runtime.zig`
- `externalSymlinkAuthorities` parses `FX_SKILL_SYMLINK_AUTHORITIES` as colon-separated absolute paths and skips relative and .. entries. Source: `src/core/skills/skill_runtime.zig`
- `replaceLoaded` reserves menu index capacity before adopting the new catalog, so an allocation failure leaves the catalog unchanged. Source: `src/core/skills/skill_runtime.zig`
- `buildSkillPrompt` shows workspace paths relative to the workspace, so worktrees of one repository render the same catalog. Source: `src/core/skills/skill_runtime.zig`
- `catalog_namespace` hashes the skill names and shown paths, so it changes with the skill set and layout but not between worktrees of one repository. Source: `src/core/skills/skill_runtime.zig`
- Skill roots come from the nearest ancestor of the workspace that holds `.git`, so skills inside a nested checkout below a workspace root that is not itself a checkout are out of scope. Discovery reports each such root as a `nested_checkout` candidate diagnostic that the listing and the skill discovery warning name, instead of skipping it silently. Source: `src/core/skills/skill_runtime.zig`
- Skill matching splits query and field text into alphanumeric words and compares them after `lexical_relevance.stem`, so inflections such as `installation`, `installs` and `install` share one term. Source: `src/core/tooling/capability_retrieval.zig`
- `ExplicitPromptSection.used_note` is a short note that stands in for skill text in later turns, so the skill text is not resent (`D95` test in `skill_invocation.zig`). Source: `src/core/skills/skill_invocation.zig`
### src/builtins

- Workspace skill roots list `.fx/skills` first as the product root, followed by `.agents/skills` for other agent installs, so product roots come first in discovery order. Source: `src/builtins/skills.zig`
- configure sets the session and an idle pane once at startup, and later pane state comes from reconcile, which reports the busiest agent's state so one agent finishing cannot mark the pane idle while another works. Source: `src/builtins/hooks.zig`
- Without `build_options.builtin_tools`, the builtin tool registry holds name-only entries, so tool names stay reserved without their bodies being built. Source: `src/builtins/tools.zig`
- On macOS the detach command uses Perl's POSIX setsid after a fork, because macOS does not ship a setsid binary and the fork keeps setsid from failing for a process-group leader. Source: `src/builtins/tools.zig`
- `NativeConfigs` merges profile and project server configs and owns both the configs and their diagnostics. Source: `src/builtins/mcp.zig`
- `gatewayFailureKind` reports `request_too_large` for a 400 whose body shows a provider 413 attempt, since the gateway reports the last provider it tried. Source: `src/builtins/gateway.zig`
### src/builtins/hooks

- `dispatchAttentionRequired`'s `session_id` is the session of the agent that needs attention, which can be a background session rather than the one on screen. Source: `src/builtins/hooks/notifications.zig`
- herdr's `last_report` is guarded by the client mutex that `sendReport` holds while comparing and sending. Source: `src/builtins/hooks/herdr.zig`
- announce runs after the first state report at startup, and release clears the agent name and pane label so herdr stops showing fx. Source: `src/builtins/hooks/herdr.zig`
- herdr's `JSON`-RPC request id is written as a string by `writeId`, which herdr requires. Source: `src/builtins/hooks/herdr.zig`
### src/builtins/gateway

- `isJevModelId` accepts the gateway spelling `typesafe-ai/jev` as an alias of the review model id. Source: `src/builtins/gateway/typesafe_permission_reviewer.zig`
- `decisionArgumentsJson` puts the calibration figures in the rationale text, so the decision stays the only structured verdict. Source: `src/builtins/gateway/typesafe_permission_reviewer.zig`
### src/tools/agent

- The subagent *`_fields` lists are the field sets used by `rejectUnknown` and by the flat tool schema in `builtins/tools.zig`, so a new field must be added there too. Source: `src/tools/agent/subagent.zig`
### src/tools/shell

- The shell tool's `AdmissionConsistency` property in `tests/tla/shell_command/ShellContract.tla` requires that an accepted call is the call that was decoded and checked. Source: `src/tools/shell/shell.zig`
### src/tools/filesystem

- `read_file`'s raw image limit is the encoded image limit scaled by 3/4, since 3 raw bytes encode to 4 base64 characters. Source: `src/tools/filesystem/read_file.zig`
### src

- The main app's `shutdownForProcessExit` restores the terminal, requests persistence shutdown, stops the upgrader and file index, terminates managed executions, and joins the worker thread, leaving memory to process exit. Source: `src/main.zig`
- `closeOnHangup` does nothing when no main turn is running, and otherwise saves active request records and leaves the turn open for the next launch. Source: `src/main.zig`
- `installResumeProjection` passes `holds_previous_cycle` to the shell's transcript window (`self.shell`), not to the agent. Source: `src/main.zig`
- A bad `FX_HOME` (not absolute, the root, the home folder, or a path through a file) stops fx with a message before it reads or writes anything. Source: `src/main.zig`
- `max_bridge_request_body_bytes` is the fetch request limit minus the `URL`, `API` key and a 64 `KiB` allowance for other headers. Source: `src/napi_core_main.zig`
- `FetchBridge` returns -3 when a wait times out, which is how the core stream reader pulses cooperatively. Source: `src/napi_core_main.zig`
- `retry_after_seconds` is whole seconds, or -1 when the response has none, and `statusFn` reports it only for the matching streaming or successful terminal response. Source: `src/napi_core_main.zig`
- The provider option accepts gateway, codex, grok, or a `configuredProviders` name, and `configuredProviders` must define the selected provider without credentials. Source: `src/napi_core_main.zig`

## Hooks and MCP facts from the parity pass

- Hook session facts: `command.State` in `src/builtins/hooks/command.zig` keeps a mutex-guarded copy of the active session id and title (`noteSession`, `noteSessionTitle`). Hook scopes carry no title; `dispatch` fills `session_id` and `session_title` from the scope, else from that copy. Hosts call `openSession`, `switchSession` and `closeSession`; they do not build SessionStart or SessionEnd payloads themselves.
- Matched hooks run on one thread each (`executeConcurrently`), sequentially on wasi; the first block in configured order wins. UserPromptQueued runs on the TUI thread and the dispatch mutex is held while hooks run, so a slow hook stalls the UI. The desktop Notification hook fires only when sound is enabled.
- A session's MCP servers are fixed by name when its host starts (`Runtime.session_servers` in `src/core/mcp_host/runtime.zig`). A reload never registers a new name; a deleted name stays listed as `removed` with its last tool count. A changed config, an approval, or re-adding a removed name applies in the open session.
- MCP tools are top-level unless `tool_select` is on and the server is deferred (`applyToolLoading` in `src/builtins/mcp.zig`). The first step waits for each server's tool list, bounded by its startup timeout; a tool-list request fails at once while a server is in backoff after a failed start. The reconnect gate is in `src/mcp/core/engine.zig`, not `stdio_conn.zig`: unbounded, 5 s doubling to 300 s with jitter, and a permanently broken server reads as retrying, never failed.
- A profile that admits any `mcp__` tool also admits `capability_search` and `select_tools` unless it refuses them by name (`src/core/profiles/profiles.zig`).
- std's `receiveHead` rejects a content-encoding fx did not ask for, and `Request.deinit` then blocks draining a body of unknown length on a keep-alive connection; `src/mcp/io/http.zig` marks the connection closing first.
- New e2e files need an entry in `scripts/pgso/corpus.json` and `tests/e2e/ci-shard-weights.json`; `python3 -m scripts.pgso.corpus --manifest scripts/pgso/corpus.json --list` fails on an unclassified file.
- The 64-bit atomics in the MCP host do not build for the wasm terminal; guard any new call into it with `runtime_profile.allows(App, .mcp)`.

## Working habits

- A turn that ends while its job runs keeps its wait in the same turn. The job's result is read when it exits, and the turn ends only when no reachable step is left.
- A job is valid only for the tree it started on. When an edit lands after it starts, stop it by PID and run one job on the final tree.
- Shell text with quotes, pipes or sed expressions goes into a script file, not inline. A failed inline attempt costs a turn each time.
- A loop tick with nothing to do ends that tick, not an open run. Keep the run's waits and any pending prompt handled before a loop stops.
- Read state from a log tail or one wait, not from repeated status calls.
- Phase B builds the native binary and the core wasm surface when the touched code can compile for wasi. The remote/browser terminal wasm is disabled by default and is not a Phase B gate; only an explicit `zig build fx-term-wasm -Dwasm-surface=term -Dremote-terminal=true` can build it. Target-specific code (process ids, POSIX signal tables, threads) compiles for native only, so a native build does not prove a wasi build.

## Hook deadlines on wasi

- Native hooks are bounded by a watchdog thread that sends TERM, then KILL after 100ms (src/core/hooks/external_run.zig, runWatched). wasi has no threads or process signals, so that path is not compiled there.
- On wasi, runUnwatched bounds the hook cooperatively: it takes the hook's timeout as a deadline, and drain checks the deadline before every read of the hook's output. When the deadline has passed it kills the child with child.kill, reaps it, and reports timed_out, which external.decide treats as fail-open.
- The deadline cannot interrupt a read that is already blocked. A hook that writes nothing and never exits blocks its own read on wasi until it exits. Hooks that print at least once per deadline interval are bounded.

## Superagent loop and resumable validation

- The superagent loop is code, not prompt text. `src/core/superagent/runtime.zig` holds the decision (`reportOf`, `decide`, `wakesOwner`) and `app_host.zig` carries it out at each root turn end. The decision table is in `docs/superagent.md`. A change of behaviour goes into `decide` and its unit row, never into `command.system_prompt` or `.fx/skills/superagent/SKILL.md`. The skill holds only how to call the tool, and `scripts/check-superagent-boundary.sh` fails when loop text returns to it.
- A root's state is one `machine.State` (`src/core/superagent/machine.zig`); the host changes it only through `machine.step`, and `machine.admit` decides prompt admission. `host_checks.zig` holds the memory floor for a new root (`task.root_min_free_mb`, 512 by default, 0 for no check) and the rule for a named job process. The superagent starts and signals no process: the boundary check fails on a spawn or kill in its folder, and `tests/e2e/superagent-isolation.test.ts` lists the fx process's descendants and open paths and fails on a path under `/workspace/hyperagent` or a descendant that is another orchestrator's binary. The external harness templates and `fx superagent templates` are removed.
- Only a turn that fx sent to a root is decided by the loop. A turn the owner typed into a root's own view posts its event and leaves the root as it is.
- The roots ledger `~/.fx/superagent/<hash>.json` holds each root's queue; `<hash>.journal.jsonl` beside it has one line per send, turn end, wait and stop. Read the journal to see what the loop did; `by` is `owner`, `runtime`, `restart` or `root`.
- A root's background task notices are not delivered to the root between turns. The loop takes them at the turn end and attaches a notice sink only while it waits on that root's job.
- `scripts/phase_b.py` runs every validation group once per tree and records passes in `.git/phase-b-passes.jsonl`; a cut run continues at the first group that has not passed on the same inputs. `FX_E2E_BIN=<path>` points the e2e suite at a build outside `zig-out`, so a scratch build (`zig build -p /tmp/<name>`) can be tried while a validation run uses `zig-out`.
- An early end of a model stream (`error.IncompleteStream` and its provider variants) is a dropped connection: it is retried with the connection backoff, at most six times per request (`request_recovery.max_incomplete_replies`). A usage or credit limit is not retried and ends the turn blocked.
