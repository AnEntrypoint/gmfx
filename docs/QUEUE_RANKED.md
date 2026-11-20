# Queue ranked: every reachable non-present matrix row

Generated from docs/kimi-parity-matrix.md (rows with status partial or missing). Rank order: section priority (queue stretch, permission modes, hooks, MCP, skills, sessions, print and ACP, slash commands, plugins, then the Claude Code audit rows CC1 to CC4), then partial before missing, then matrix order. Rows gated by the superagent WIP (Q17) or the 87fee744 Phase B gate are listed in the ledger as blocked, not here.

Total: 186 rows. Rows closed by the 2026-11-12 Phase A collection (built, present or kept-different) are recorded in docs/PENDING_VALIDATION.md and no longer listed here; held rows keep their place with status held.

| rank | row | status | section | gap (first 160 characters) |
| --- | --- | --- | --- | --- |
| 38 | 28 | held | 08 Permission modes: Kimi (eb2035f) vs fx | Add start-permission prompt for goal and swarm runs |
| 68 | 25 | partial | 05 MCP client parity (Kimi eb2035f vs fx) | wrong missing claim: fx reads an environment key (1273) with parseSelectedEnvironment (1040), but it is named environment, not environment_id |
| 99 | 20 | held | 09 Skills and discovery parity | Audit correction: Toggle key is builtinProductSkills (configSection.ts:28), not builtin_product_skills |
| 101 | 31 | held | 09 Skills and discovery parity | Audit correction: Scopes and experimentalFlag are types.ts:3 and types.ts:28-30, not types.ts:21-23 |
| 127 | 10 | partial | Parity 11: print mode and ACP server | Audit correction: Kimi source is apps/kimi-code/src/cli/main.ts:257-270 (apps/kimi-code/src/main.ts is a 33-line file) |
| 128 | 14 | partial | Parity 11: print mode and ACP server | max_agent_steps exists (settings_keys.zig:103, 0 = no limit) but default is unlimited, not 100000; no print wait ceiling; partial, not missing |
| 129 | 21 | partial | Parity 11: print mode and ACP server | Advertise image true unconditionally as Kimi does |
| 130 | 22 | partial | Parity 11: print mode and ACP server | Advertise delete, fork, additionalDirectories once implemented |
| 131 | 25 | partial | Parity 11: print mode and ACP server | Advertise http and sse true |
| 132 | 28 | partial | Parity 11: print mode and ACP server | Map modes to default/plan/auto/yolo IDs |
| 133 | 29 | partial | Parity 11: print mode and ACP server | model option is at acp/server.zig:3592-3596; cited 3388 is an unrelated value parse; no thinking option exists in acp/server.zig |
| 134 | 34 | partial | Parity 11: print mode and ACP server | Intentional brand; confirm acceptable |
| 137 | 9 | missing | Parity 11: print mode and ACP server | Add session-occupied exit 4 and JSON error line |
| 138 | 11 | missing | Parity 11: print mode and ACP server | Add goal mode exit codes if goal feature is ported |
| 139 | 13 | missing | Parity 11: print mode and ACP server | Port print background policy (exit/drain/steer) |
| 140 | 15 | missing | Parity 11: print mode and ACP server | Confirm native exit is clean; add drain guard if output can truncate |
| 141 | 17 | missing | Parity 11: print mode and ACP server | Add `acp --login [--region]` device-code flow |
| 142 | 19 | missing | Parity 11: print mode and ACP server | Advertise terminal login auth method |
| 143 | 20 | missing | Parity 11: print mode and ACP server | Implement authenticate and logout methods |
| 144 | 23 | missing | Parity 11: print mode and ACP server | Implement session/fork |
| 155 | 18 | partial | Slash command parity: Kimi Code (eb2035f) vs fx | Audit correction: Typed Kimi subcommands are list, install, marketplace, info, mcp, enable/disable, remove, reload (plugins.ts:114-199); toggle, details and the |
| 158 | 23 | partial | Slash command parity: Kimi Code (eb2035f) vs fx | Accept optional instruction argument |
| 173 | 24 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Audit correction: Kimi forms are status, pause/resume/cancel, replace <objective>, next <objective>, next manage, or <objective>; bare manage is not a form (goa |
| 174 | 25 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Add /init |
| 176 | 38 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Add /import-sessions |
| 177 | 40 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Add /web |
| 178 | 41 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Add /desktop with `install-desktop` alias |
| 179 | 42 | missing | Slash command parity: Kimi Code (eb2035f) vs fx | Add /remote-control with `rc` alias |
| 181 | 9 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | source kinds are resolved at source.zig:24-33 matching Kimi, but its only caller manager.zig install is unreachable, so partial |
| 182 | 11 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | install with staging, id check and rollback exists but has no caller; no /plugins install; zip and github sources rejected |
| 183 | 12 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | store paths and atomic installed.json version 1 exist and are read by /plugins; the managed copy root is only written by the unreachable install |
| 185 | 14 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | list, reload, enable, disable, remove and mcp enable/disable exist; install, marketplace, info and the picker are missing |
| 186 | 16 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | a trust gate (PluginTrustRequired) exists in the unreachable install, but there is no prompt and no official-source exemption |
| 187 | 17 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | remove exists without a confirm dialog; fx also deletes the managed copy, which Kimi remove() does not (manager.ts:405-414) |
| 189 | 23 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | store-only load and a reload diff exist, but plugins_command.zig:92 passes an empty previous-id list so added and removed are never a real diff |
| 190 | 24 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | plugin skill roots exist only in contributions.zig skillRoots, which has no caller; the live mechanism is generic skill roots at src/builtins/skills.zig:16-17 |
| 191 | 28 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | markdown loader with plugin:name slash names, frontmatter and ARGUMENTS expansion exists, but collect has no caller; builtins/commands.zig is not plugin-sourced |
| 192 | 29 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | plugin hooks are parsed with plugin-root cwd but hookDefinitions has no caller; KIMI_PLUGIN_ROOT and KIMI_CODE_HOME env are absent |
| 193 | 30 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | plugin MCP is wired (mcp.zig:103) with plugin-id:server naming; default cwd and KIMI_PLUGIN_ROOT env are absent; matrix fx cite mcp.zig:23-24 is wrong |
| 194 | 32 | partial | 12 PLUGINS parity (Kimi eb2035f vs fx) | id-sorted list and per-plugin error isolation exist; MCP uses the sorted list instead of installed.json order; contributions are unwired |
| 198 | 22 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Add GitHub update check and notice |
| 199 | 25 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Add plugin agent roots |
| 200 | 26 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Load sessionStart skill at session start |
| 201 | 27 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Add plugin system prompt section to prompt build |
| 202 | 31 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Add guarded plugin entry runner if plugins run node code |
| 203 | 33 | missing | 12 PLUGINS parity (Kimi eb2035f vs fx) | Merge plugin commands into fx slash command table |
| 221 | CC1.25 | partial | CC1 Hooks, permissions, memory | Finish: Read-only tools (File reads, Grep) need no approval inside working directories. Bash needs approval except a built-in set of read-only commands. File ed |
| 222 | CC1.26 | partial | CC1 Hooks, permissions, memory | Finish: allow, ask and deny rules are evaluated in order deny, then ask, then allow; the first match decides; an allow rule cannot carve an exception out of a d |
| 223 | CC1.28 | partial | CC1 Hooks, permissions, memory | Finish: Identifiers default, acceptEdits, plan, auto, dontAsk, bypassPermissions; default is set via permissions.defaultMode in settings files. |
| 225 | CC1.30 | partial | CC1 Hooks, permissions, memory | Finish: Identifiers default (Manual, reads only), acceptEdits (edits and common filesystem commands in working directory), plan, auto (classifier review), dontA |
| 226 | CC1.31 | partial | CC1 Hooks, permissions, memory | Finish: Shift+Tab cycles default, acceptEdits, plan; dontAsk is not in the cycle. CLI flag --permission-mode accepts the mode identifiers. Settings key permissi |
| 227 | CC1.32 | partial | CC1 Hooks, permissions, memory | Finish: Interactive terminal and VS Code sessions start in auto with Claude Code v2.1.283 or later; claude -p and Agent SDK runs start in default. auto and bypa |
| 228 | CC1.33 | partial | CC1 Hooks, permissions, memory | Finish: Must be enabled at launch with --permission-mode bypassPermissions, --dangerously-skip-permissions, or permissions.defaultMode in user, --settings or ma |
| 229 | CC1.34 | partial | CC1 Hooks, permissions, memory | Add --permission-mode plan, Shift-Tab, the plan file, and read-only shell commands |
| 230 | CC1.35 | partial | CC1 Hooks, permissions, memory | Finish: A classifier reviews actions before they run. Requires a supported model and plan. Administrators disable it with permissions.disableAutoMode set to dis |
| 231 | CC1.40 | partial | CC1 Hooks, permissions, memory | Finish: permissions.ask rules such as Bash(git push *) always force a prompt, even in auto mode, because an explicit ask rule is evaluated before the classifier |
| 232 | CC1.41 | partial | CC1 Hooks, permissions, memory | Finish: Locations in load order: managed policy (/etc/claude-code/CLAUDE.md on Linux, /Library/Application Support/ClaudeCode/CLAUDE.md on macOS), ~/.claude/CLA |
| 233 | CC1.42 | partial | CC1 Hooks, permissions, memory | Finish: CLAUDE.md and CLAUDE.local.md are loaded at launch from the working directory and every ancestor directory, concatenated root first; CLAUDE.local.md fol |
| 234 | CC1.45 | partial | CC1 Hooks, permissions, memory | Finish: AGENTS.md is read only when no CLAUDE.md or CLAUDE.local.md exists in the working directory or above (default claude-md-or-agents-md); other values are |
| 235 | CC1.46 | partial | CC1 Hooks, permissions, memory | Finish: --add-dir does not load CLAUDE.md from the added directory unless CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 is set. |
| 236 | CC1.49 | partial | CC1 Hooks, permissions, memory | Finish: User ~/.claude/settings.json, shared project .claude/settings.json, project local .claude/settings.local.json, and managed managed-settings.json. |
| 237 | CC1.50 | partial | CC1 Hooks, permissions, memory | Finish: Highest first: managed, command line (--settings), project local, shared project, user. List keys such as permissions.allow are merged across files, not |
| 238 | CC1.51 | partial | CC1 Hooks, permissions, memory | Finish: Keys permissions.allow, permissions.ask, permissions.deny (arrays), permissions.defaultMode, permissions.additionalDirectories, permissions.disableBypas |
| 239 | CC1.52 | partial | CC1 Hooks, permissions, memory | Finish: Key hooks, plus disableAllHooks (boolean) which turns off hooks, the custom status line and the @ file suggestion command at once. |
| 240 | CC1.55 | partial | CC1 Hooks, permissions, memory | Finish: /permissions shows the resolved allow and deny rules currently in effect. |
| 241 | CC1.56 | partial | CC1 Hooks, permissions, memory | Finish: /doctor is a setup checkup that reports invalid settings files, unused extensions and CLAUDE.md content, with proposed fixes. |
| 245 | CC1.27 | missing | CC1 Hooks, permissions, memory | Implement: Rules are Tool or Tool(specifier), for example Bash(npm run build), Read(./.env), WebFetch(domain:example.com), with * wildcards and a :* suffix. |
| 246 | CC1.37 | missing | CC1 Hooks, permissions, memory | Implement: rm and rmdir on critical paths prompt in default, acceptEdits and plan, are approved or denied with a two-minute countdown in auto and bypassPermissi |
| 247 | CC1.38 | missing | CC1 Hooks, permissions, memory | Implement: autoMode.environment, autoMode.allow, autoMode.soft_deny and autoMode.hard_deny arrays, with the literal string $defaults to splice in built-in rules |
| 248 | CC1.39 | missing | CC1 Hooks, permissions, memory | Implement: autoMode.classifyAllShell set to true suspends every Bash and PowerShell allow rule while auto mode is active. |
| 249 | CC1.43 | missing | CC1 Hooks, permissions, memory | Implement: @path/to/import expands inline, relative to the importing file, with a maximum depth of four hops. Imports inside code spans or fenced code blocks ar |
| 250 | CC1.44 | missing | CC1 Hooks, permissions, memory | Implement: All .md files under .claude/rules/ are discovered recursively; rules with paths frontmatter load only when matching files are opened. |
| 251 | CC1.47 | missing | CC1 Hooks, permissions, memory | Implement: On by default in local sessions. Toggled by /memory and saved as autoMemoryEnabled in ~/.claude/settings.json; disabled by CLAUDE_CODE_DISABLE_AUTO_M |
| 252 | CC1.48 | missing | CC1 Hooks, permissions, memory | Implement: Stored at ~/.claude/projects/<project>/memory/ with a MEMORY.md index; the first 200 lines or 25KB of MEMORY.md load at session start; autoMemoryDire |
| 253 | CC1.53 | missing | CC1 Hooks, permissions, memory | Implement: Keys autoMemoryEnabled (boolean), autoMemoryDirectory (path), claudeMdExcludes (paths or patterns to skip), claudeMd (managed only). |
| 254 | CC1.54 | missing | CC1 Hooks, permissions, memory | Implement: /memory lists memory file locations across user and project scopes, opens each in an editor, opens the auto memory folder and holds the auto memory t |
| 255 | CC1.57 | missing | CC1 Hooks, permissions, memory | Implement: /hooks lists every hook registered for the session, grouped by event. |
| 256 | CC1.58 | missing | CC1 Hooks, permissions, memory | Implement: /context shows everything in the context window by category, including memory files, with /context all to expand. |
| 257 | CC1.59 | missing | CC1 Hooks, permissions, memory | Implement: claude --safe-mode disables CLAUDE.md, skills, hooks and MCP servers; --setting-sources user and CLAUDE_CONFIG_DIR give a clean configuration. |
| 260 | CC2.3 | held | CC2 MCP, skills, subagents, plugins | Finish: SSE is deprecated. claude mcp add --transport http falls back to SSE when the server refuses HTTP (v2.1.265+); earlier versions use --transport sse. |
| 290 | CC2.6 | missing | CC2 MCP, skills, subagents, plugins | Implement: Use type 'ws' in .mcp.json or add-json; accepts url, headers, headersHelper, timeout, alwaysLoad; no OAuth; not accepted by --transport. |
| 292 | CC2.14 | held | CC2 MCP, skills, subagents, plugins | Implement: headersHelper is a command that prints a JSON object of headers to stdout; Claude Code gives it 10 seconds and runs it on each connection. A 401/403 |
| 293 | CC2.19 | held | CC2 MCP, skills, subagents, plugins | Implement: A main-conversation MCP call still running after 2 minutes moves to a background task shown in /tasks. CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS sets the th |
| 294 | CC2.20 | held | CC2 MCP, skills, subagents, plugins | Implement: A server declares the claude/channel capability and is opted in at startup with --channels. |
| 295 | CC2.21 | held | CC2 MCP, skills, subagents, plugins | Implement: Long jobs run by the server under the MCP tasks extension; the call returns once the server accepts the task. Requires Claude Code v2.1.304+ and is i |
| 308 | CC2.41 | held | CC2 MCP, skills, subagents, plugins | Implement: A fork inherits the full conversation and reuses the parent prompt cache. Fork mode is on by default from v2.1.302; Agent(fork) in permissions.deny s |
| 319 | CC2.59 | held | CC2 MCP, skills, subagents, plugins | Implement: Shell subcommands install, enable, disable, uninstall and update plugins with --scope user (default for install), project or local. Marketplace subco |
| 320 | CC2.60 | held | CC2 MCP, skills, subagents, plugins | Implement: User scope writes enabledPlugins to ~/.claude/settings.json; project scope writes .claude/settings.json; local scope writes .claude/settings.local.js |
| 333 | CC3.6 | held | CC3 Built-in tools, sessions, interactive mode, defaults | Finish: Read takes a file path and returns numbered lines; PNG, JPEG, GIF and WebP are returned as images (128 MB limit); PDFs use a pages parameter (up to 20 p |
| 355 | CC3.51 | held | CC3 Built-in tools, sessions, interactive mode, defaults | Finish: Sessions are named with claude -n <name> or --name, renamed with /rename, and renamed in the picker with Ctrl+R. |
| 357 | CC3.53 | held | CC3 Built-in tools, sessions, interactive mode, defaults | Finish: /branch [name] copies the conversation so far and switches into the copy; claude --continue --fork-session or --resume --fork-session forks from the CLI |
| 384 | CC3.10 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: NotebookEdit edits Jupyter cells by cell_id with modes replace (default), insert (requires cell_type code or markdown) and delete. |
| 387 | CC3.23 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: EnterPlanMode switches to plan mode to design an approach before coding. |
| 388 | CC3.27 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Monitor runs a command in the background and feeds each output line back to Claude. |
| 389 | CC3.28 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: PowerShell executes PowerShell commands natively where available. |
| 390 | CC3.29 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: EnterWorktree creates or enters an isolated git worktree; ExitWorktree returns to the original directory. |
| 391 | CC3.30 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: LSP gives code intelligence through language servers: definitions, references and type errors. |
| 392 | CC3.31 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Workflow runs a dynamic workflow script that orchestrates many subagents in the background. |
| 393 | CC3.32 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: ToolSearch loads deferred tools; SendMessage sends a message to a teammate, a resumable subagent or another session. |
| 408 | CC3.72 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: With --resume or --continue, creates a new session ID instead of reusing the original. |
| 409 | CC3.73 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Sets a display name for the session, shown in /resume and the terminal title. |
| 410 | CC3.74 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Uses a specific session ID for the conversation; the value must be a UUID. |
| 411 | CC3.76 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: --tools restricts built-in tools to the named set; --allowedTools auto-approves tools; --disallowedTools removes tools from context. |
| 412 | CC3.77 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: --max-turns limits agentic turns in print mode (no limit by default); --max-budget-usd stops the run at an estimated spend. |
| 413 | CC3.78 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: --output-format takes text (default), json or stream-json; --permission-mode begins in default, acceptEdits, plan, auto, dontAsk, bypassPermissions o |
| 414 | CC3.79 | held | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Days Claude Code keeps transcripts before deleting them; default 30, minimum 1. |
| 421 | CC3.91 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: enable_file_checkpointing / enableFileCheckpointing records file backups for Write, Edit and NotebookEdit; rewind_files() / rewindFiles() restores fi |
| 422 | CC3.93 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: A SessionStore adapter with append and load methods mirrors transcripts to an external backend so another host can resume a session. |
| 423 | CC3.95 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: After compaction Claude Code re-reads up to five recently modified files; invoked skill bodies are re-injected, capped at 5,000 tokens per skill and |
| 425 | CC3.103 | missing | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: --output-format takes text (default), json or stream-json; --json-schema validates structured output. |
| 426 | CC3.104 | held | CC3 Built-in tools, sessions, interactive mode, defaults | Implement: Transcripts, file snapshots and other session data are deleted once older than cleanupPeriodDays, default 30 days, minimum 1; file-history keeps snap |
| 435 | CC4.4 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /model [model] switches the model and saves it as the default for new sessions; with -p a model argument is required and is not saved; s in the picker a |
| 436 | CC4.6 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /permissions manages allow, ask and deny tool-permission rules; alias /allowed-tools. |
| 440 | CC4.14 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /statusline configures the status line; run with no argument to auto-configure from the shell prompt. |
| 445 | CC4.39 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /fork [prompt] copies the current conversation into a new background session and keeps working here. |
| 446 | CC4.40 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /feedback [report] sends product feedback; alias /bug (and /share). |
| 447 | CC4.42 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Documented launch forms: claude, claude query, claude -p query (query then exit), piped stdin with -p, claude -c, claude -r session query, plus subcomma |
| 448 | CC4.43 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --print or -p prints the response without interactive mode; combined with -p, --bg is rejected with an error naming the conflict. |
| 449 | CC4.44 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --continue or -c loads the most recent conversation in the current directory; skips sessions created with claude -p or the SDK; -p --continue includes t |
| 450 | CC4.46 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --model sets the model for the session with an alias such as sonnet, opus, haiku or fable, or a full model name; overrides the model setting and ANTHROP |
| 451 | CC4.47 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --effort sets the effort level for the session: low, medium, high, xhigh, max or ultracode; overrides modelSettings and effortLevel for the session and |
| 452 | CC4.48 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --permission-mode begins in a mode: default, acceptEdits, plan, auto, dontAsk, bypassPermissions or manual (alias of default); overrides defaultMode fro |
| 453 | CC4.50 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --output-format selects print-mode output: text (default), json, or stream-json; json includes session metadata and a result field. |
| 454 | CC4.57 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --system-prompt and --system-prompt-file replace the default prompt; --append-system-prompt and --append-system-prompt-file append to it; all work in in |
| 455 | CC4.59 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Add -p or --print to any claude command to run it non-interactively; exit code 0 on success and non-zero on failure; an invalid flag is reported on stde |
| 456 | CC4.62 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --output-format text (default), json (result, session ID and metadata) or stream-json (newline-delimited JSON); --json-schema returns output in structur |
| 457 | CC4.67 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: --continue continues the most recent conversation and --resume with a session ID continues a specific one; -p --continue and -p --resume keep the run in |
| 458 | CC4.70 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: app:interrupt is Ctrl+C; app:exit is Ctrl+D (press twice within 800ms); app:toggleTodos is Ctrl+T; app:toggleTranscript is Ctrl+O; app:redraw is unbound |
| 459 | CC4.80 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Ctrl+O toggles the transcript viewer; q, Ctrl+C or Esc exits it; Ctrl+E toggles show-all in the classic renderer only. |
| 460 | CC4.91 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Four settings files: ~/.claude/settings.json (user), .claude/settings.json (shared project, committed), .claude/settings.local.json (project local, kept |
| 461 | CC4.92 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Settings can be changed in the /config menu, by editing a settings file, or for one session with --settings, a per-key flag such as --model, or an envir |
| 462 | CC4.93 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Highest first: managed settings, command line (--settings), project local, shared project, user; list keys such as permissions.allow merge across scopes |
| 463 | CC4.94 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Run /status to see the Setting sources line listing each settings file loaded for the session. |
| 464 | CC4.95 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: model sets the default model for new sessions; overridden by --model, then ANTHROPIC_MODEL; default unset. |
| 465 | CC4.96 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: effortLevel sets the default effort (low, medium, high, xhigh); overridden by --effort and CLAUDE_CODE_EFFORT_LEVEL; modelSettings stores a per-model ef |
| 466 | CC4.98 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: permissions.defaultMode sets the starting permission mode: default, acceptEdits, plan, auto, dontAsk, bypassPermissions or manual; overridden by --permi |
| 467 | CC4.99 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: permissions.allow, permissions.ask and permissions.deny hold rule lists such as Bash(npm run build) and Read(./.env); deny is evaluated first, then ask, |
| 468 | CC4.100 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: theme sets the color theme: auto, dark, light, the -daltonized and -ansi variants, or custom:<slug>; default dark. |
| 469 | CC4.102 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: statusLine is an object with type set to command, a command to run, optional padding (default 0) and refreshInterval (minimum 1); the command receives s |
| 470 | CC4.116 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Six modes: default (Manual, reads only), acceptEdits (reads and file edits), plan, auto (classifier-reviewed), dontAsk (denies anything that would promp |
| 471 | CC4.118 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: A terminal session takes its mode from --permission-mode or --dangerously-skip-permissions first, then permissions.defaultMode in a settings file, then |
| 472 | CC4.124 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Aliases include default, best (same as opus), fable, sonnet, opus, haiku, sonnet[1m], opus[1m] and opusplan; /model opens the picker, Enter saves the de |
| 473 | CC4.126 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Effort levels are low, medium, high, xhigh and max (per model); default medium for Fable 5.2, Opus 5.5, Sonnet 5.5 and Haiku 5.5, xhigh for Opus 4.7, hi |
| 474 | CC4.129 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: /rewind or double Esc with empty input opens the rewind menu with Restore code and conversation, Restore conversation, Restore code, Summarize from here |
| 475 | CC4.130 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Set statusLine in user or project settings to type command with a command path; optional padding (default 0) and refreshInterval (minimum 1); /statuslin |
| 476 | CC4.132 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Rules name a tool and a pattern, such as Bash(npm run build) for an exact command, Bash(npm run *) for a prefix with a space before the star, and Read(. |
| 477 | CC4.136 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Ctrl+O enters transcript mode, / searches, n and N jump between matches, [ writes the conversation to native scrollback, v opens it in an editor. |
| 478 | CC4.137 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Config files live in ~/.claude (settings.json, keybindings.json, output-styles/, themes/, projects/) with ~/.claude.json alongside; CLAUDE_CONFIG_DIR mo |
| 479 | CC4.139 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: claude --continue reopens the most recent session in the current directory; claude --resume opens the picker; claude --resume name resumes it directly; |
| 480 | CC4.141 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: Name a session with claude -n name or --name at startup, or /rename name during a session; the name appears in the prompt bar and resumes with claude -- |
| 481 | CC4.153 | partial | CC4 Commands, CLI, settings, keybindings, output modes | Finish: An example personal settings file sets model, modelSettings, editorMode, theme, statusLine, spinnerTipsEnabled, preferredNotifChannel, permissions.allow |
| 485 | CC4.22 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /theme changes the color theme, including an auto option that follows the terminal background and custom themes from ~/.claude/themes/. |
| 486 | CC4.23 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /output-style [style] lists output styles or switches to one, for example /output-style concise; requires v2.1.269 or later. |
| 487 | CC4.24 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /keybindings opens the keyboard shortcuts file ~/.claude/keybindings.json. |
| 488 | CC4.25 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /btw [question] asks a side question without adding it to the conversation history. |
| 489 | CC4.26 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /background [prompt] detaches the session to run as a background agent; alias /bg. |
| 497 | CC4.51 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --input-format text or stream-json, --include-partial-messages and --verbose for streaming print mode; --include-partial-messages requires --print an |
| 498 | CC4.52 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --settings takes a settings JSON file path or inline JSON that overrides the same keys in settings files for one session; file must be 2 MiB or less. |
| 499 | CC4.53 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --allowedTools and --disallowedTools (alias --allowed-tools and --disallowed-tools) set tools that run without prompting and deny rules; bare names r |
| 500 | CC4.54 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --dangerously-skip-permissions skips permission prompts; equivalent to --permission-mode bypassPermissions. |
| 501 | CC4.55 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --bare minimal mode skips auto-discovery of hooks, skills, plugins, MCP servers, auto memory and CLAUDE.md; --max-turns and --max-budget-usd cap prin |
| 502 | CC4.56 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --verbose enables verbose logging with full turn-by-turn output and overrides the viewMode setting for the session. |
| 503 | CC4.58 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: --system-prompt-snapshot off rebuilds the system prompt on every request; on (default) reuses the recorded prompt for a conversation until compaction |
| 507 | CC4.64 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: stream-json emits a system/init event with model, tools, MCP servers and plugins, and a system/api_retry event before each retry. |
| 520 | CC4.79 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: / at the start runs a command or skill; ! at the start enters shell mode; @ opens file path autocomplete; ? on empty input toggles the shortcut help |
| 521 | CC4.81 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Vim mode is enabled with /config Editor mode or the editorMode setting set to vim; vimInsertModeRemaps maps a two-key INSERT sequence such as jj to E |
| 525 | CC4.85 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Prompt suggestions are on by default (promptSuggestionEnabled true); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false turns them off; print mode generates |
| 526 | CC4.86 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /btw asks a question from the current context without adding it to history and without tool access; x clears the earlier exchanges in the overlay. |
| 527 | CC4.87 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: A one-line recap appears after about three minutes away; /recap generates one on demand; automatic recap is turned off in /config and capped at 400 c |
| 528 | CC4.88 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: autoContinueAtUsageLimit defaults to true and continues the task after a claude.ai usage limit resets; it can be turned off in /config or set to fals |
| 530 | CC4.90 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Ctrl+T toggles Claude's task checklist; CLAUDE_CODE_TASK_LIST_ID names a shared task list directory under ~/.claude/tasks/. |
| 532 | CC4.101 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: editorMode sets prompt key bindings: normal (default) or vim. |
| 534 | CC4.104 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: cleanupPeriodDays sets how many days session transcripts are kept (default 30, minimum 1); autoMemoryEnabled defaults to true. |
| 535 | CC4.105 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: env is a block of environment variables applied to sessions and subprocesses; several telemetry variables are ignored when set in project or local se |
| 539 | CC4.109 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Variables are set in the shell before launching claude or under the env key of settings.json; values in a settings env block override the same variab |
| 553 | CC4.127 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Default model is Opus 5.5 for Pro, Max, Ultra, Team, Enterprise and Anthropic API accounts, and Sonnet 4.5 on Microsoft Foundry; an organization defa |
| 559 | CC4.138 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Transcripts under projects/<project>/<session>.jsonl and other application data are deleted once older than cleanupPeriodDays (default 30, minimum 1) |
| 563 | CC4.144 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: /voice enables dictation and takes an optional mode argument hold, tap or off; the voice settings object holds enabled, mode (hold or tap) and autoSu |
| 564 | CC4.145 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Hold mode is the default; Space is the default voice:pushToTalk key in the Chat context; holding Space records and releasing inserts the transcript. |
| 565 | CC4.146 | held | CC4 Commands, CLI, settings, keybindings, output modes | Implement: The dictation key is the voice:pushToTalk action in the Chat context of keybindings.json and replaces the default Space binding. |
| 566 | CC4.147 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Ctrl+J or backslash then Enter inserts a newline in every terminal; /terminal-setup installs a Shift+Enter binding in VS Code, Cursor, Devin Desktop, |
| 567 | CC4.148 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: preferredNotifChannel set to terminal_bell makes Claude Code send the bell character; iterm2, kitty and ghostty forward desktop notifications over SS |
| 570 | CC4.151 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: Enable Vim editing via /config Editor mode or editorMode set to vim; set Editor mode back to normal to turn it off. |
| 571 | CC4.152 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: maxProseWidth sets a column cap for prose wrapping with a minimum of 40. |
| 573 | CC4.155 | missing | CC4 Commands, CLI, settings, keybindings, output modes | Implement: A managed-settings.json file sets forceLoginMethod, forceLoginOrgUUID, availableModels, enforceAvailableModels, permissions.deny, allowManagedPermiss |
| 576 | I4 | held | Phase A: double-Esc undo and help panel (reference eb2035f) | Limit stated in the error and tool description. Open: JPEG and WebP decoders are not in fx. No code change in this pass; the image-reading pass is dropped by th |
