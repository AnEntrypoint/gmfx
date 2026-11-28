# fx:host interface

Status: specification, written against fx source at the checkout in /workspace/fx/fx. Every row is tagged `exists` (verified by reading or grepping the named source path) or `planned` (not in the tree). freddie (/workspace/freddie, packages/util/runtime) codes against this file. Nothing here is a promise beyond the tags.

## 0. Ground truth today

- fx embeds txiki.js: build.zig runs cmake on native/txiki and links libfx_txiki.a, libfx_quickjs_ng.a and libuv.a. exists.
- The embedded runner is src/core/runcode/runcode.zig. It is reached by the model tool run_code (src/tools/runcode/run_code.zig) and by the CLI subcommand `fx run-code --file <path> [--deadline-ms N] [--format esm|cjs] [--permission-mode <mode>]` (src/main.zig, runCli). exists.
- The body sees one global, `gm`, built by src/core/runcode/runcode_bootstrap.js from a catalog: one entry per registered tool (kind `tool`) plus 22 host verbs (kind `host`). Tool verbs are synchronous, return the result text, and throw `Error(reply.error)` on failure. Host verbs return `{ok, ...}` objects. exists.
- Each catalog entry is `{name, description, kind, input_schema}`: kind `tool` per registered tool (schema from its model_schema), `host` per host verb (description and schema from the host_verbs.zig table), `mcp` per MCP tool the session's catalog lists (mcp_list_tools), dispatched through tool_dispatch under its own name. `gm.verbs()` returns the catalog, `gm.verbs({names:true})` the names, `gm.verbs({name})` one entry, and an unknown name throws `unknown verb: <name>`. A context with `admitted_tool_names` (a subagent's allowlist, or a main profile's narrowed tools) lists only admitted verbs, and a call to any other registered tool or gated host verb returns `EFX_TOOL_NOT_ADMITTED` before dispatch. exists.
- Hard-coded aliases in the bootstrap: `run_shell -> Bash`, `grep -> grep_files`, `find -> glob_files`, `fetch -> FetchURL`. exists.
- Body deadline: `deadline_ms` default 120000, max 3600000. Result JSON: `{ok:true,value,console,console_dropped}` or `{ok:false,error,console,console_dropped}`. exists.
- Loader today: `require` of relative files (fx.read_text), bare specifiers through `fx.resolve` (src/core/runcode/resolve.zig), which first consults the Node alias table (src/core/runcode/host_module.zig, section 4.2), then node_modules package exports, then the embedded `@freddie/freddie-runtime` copy (src/core/runcode/cordis/*.js, listed in cordis.zig). `node:X` and a bare Node built-in name `X` resolve through that one table for both `import` (runcode_shim.c normalize_module) and `require` (runcode_bootstrap.js). `tjs:` loads txiki built-ins under `import` and is refused by `require`. ES modules via `format: "esm"` with hoisted imports (imports.zig). exists.
- `fx:host` exists in its first form (section 1.0). Not present anywhere in the tree (grep for js-root, FX_JS_ROOT, import.meta.hot, rollback, .fx/js): JS root resolution, import map, hot reload, last-known-good. All planned.
- txiki network, TLS, websocket, http server, hashing, miniz are stubs: native/txiki/glue/txiki_stubs.c defines empty tjs__mod_tls_init, tjs__mod_httpclient_init, tjs__mod_httpserver_init, tjs__mod_ws_init, tjs__mod_hashing_init, tjs__mod_miniz_init. exists (as stubs).

## 0.1 On edgejs (specs/edgejs-swap.md; docs/edgejs-engine.md)

Decision 2026-11-23: edgejs is go behind a flag for fx only (`fx run-code --engine edge`, opt-in, policy gate, +59 MB). The txiki route below stays the contract and the default; the sections marked "txiki route" describe what edgejs would make Node provide instead, and are not removed.

What stays in fx:host on edgejs:
- `version` and `capabilities` (section 1), so a host can omit what it lacks.
- `tools.<name>(args)` (section 2): every native fx tool as a verb behind the Zig permission gate. On edgejs it reaches JavaScript as the N-API host function `fxHost.call(name, argsJson)`, installed by native/edgejs/fx_edge.cc and dispatched by src/core/runcode/edge.zig to the same Verbs.invoke run_code uses. exists, unbuilt.
- The agent core (section 3) in the shape libfx exposes, with custom providers over `openai-chat-completions` or `anthropic-messages` (the Anthropic-compatible endpoint exists: src/core/config/configured_provider.zig).
- The loader's JS root and the reload protocol (sections 5.1 to 5.3 and 6): edgejs has no module-resolution or hot-reload hook of its own, so fx keeps them, through module.registerHooks.

What Node provides instead, and so leaves fx:host: the system services of section 4 (fs, net, http, https, tls, dns, crypto, child_process, worker_threads, zlib, sqlite, fetch, timers, fs.watch); pty is the one service Node lacks and stays a gap. The alias table of section 4.2 becomes the identity: every node: name resolves to edgejs's own module.

Open question: one permission gate when Node networking and spawn run inside the runtime. Each option has a check in scripts/edgejs-witness.sh, unrun until gm's edgejs build lands:
- A. Verbs only: permission-bearing Node modules (child_process, net, http, https, tls, dgram, dns, fs, worker_threads, inspector, cluster, http2) are refused at resolve time unless the mode is yolo, and the work goes through `fxHost.call`. One gate, but freddie's node: imports of those modules fail outside yolo.
- B. Routing: the same Node APIs are kept and each permission-bearing call is forwarded to the matching gated verb. Node names and behaviour stay, at the cost of one wrapper per API; this is the option that meets the Node-compatibility goal if its wrappers cover freddie's calls.
- C. Safe mode under Wasmer: edgejs's own sandbox. Not testable on the native quickjs build (EDGE_QUICKJS_WEBASSEMBLY off).

## 1. Module shape and versioning

```js
import host from 'fx:host'
import { version, capabilities, tools, agent, fetch, serve, fs, watch, proc, pty, timers, dns, crypto, sqlite, loader, reload } from 'fx:host'
```

### 1.0 Built today

src/core/runcode/host_module.zig holds one table: one row per Node built-in name in scope, mapping it to `fx:host/<name>` or marking it a gap (section 4.2). The JavaScript of `fx:host` and of every `fx:host/<name>` module is generated from that table at comptime; the tool list is read at run time from the run_code catalog. exists.

- `version`: `{ interface: 1, minor: 0, host: 'fx' }` (frozen). `hostVersion` and `table` are planned.
- `capabilities`: a frozen list, `'tools'`, `'verbs'`, then every provided Node module name. The object form of 1.2 is planned.
- `tools.<name>(args)`: every tool verb in the catalog (kind `tool`), the same function as `gm.<name>`, dispatched through tool_dispatch and its permission gate.
- `verbs.<name>(args)`: the 22 host verbs (kind `host`), each through host_verb_gate.refusal before host_verbs.call.
- `modules`: Node module name to its implementation object, taken from src/core/runcode/cordis/fx_runtime.js (fx's implementation over the host verbs).
- `fx:host/<name>`: default export is `modules[name]`, named exports are the row's export list. `node:<name>` and `<name>` resolve to it unchanged.
- The default export is a frozen object of the five fields. `require('fx:host')` returns it in a cjs body, and `require` of a Node name returns `modules[name]`.

The rest of this section is the planned full shape.

`fx:host` is generated from one Zig table. Each row names a path (`tools.Bash`, `fs.readFile`), an arg schema, a result schema, a permission class, a capability id and a status. The module is the only host entry; Node built-in names resolve to it through the alias table (section 4.2).

### 1.1 Version

```js
host.version = { interface: 1, minor: 0, host: 'fx', hostVersion: '<fx version>', table: '<sha256 of the generated table>' }
```

- `interface` changes only on a breaking change to an existing row. `minor` increases when rows are added. A consumer asserts `host.version.interface === 1` and feature-tests on `capabilities`.
- `host` identifies the implementer: `fx` or `thebird`.
- planned. Nothing in src/ emits this today.

### 1.2 Capability table

`host.capabilities` is a frozen object mapping capability id to `{ present: boolean, since: minor, status: 'exists' | 'planned' | 'absent' }`. A host that lacks a capability omits the namespace; `present` is false and the namespace property is `undefined`. A call to an absent namespace never reaches Zig. The generic freddie adapter registers Cordis services only for present ids.

| id | namespace | fx CLI | thebird (browser port) | status in fx tree |
| --- | --- | --- | --- | --- |
| tools.file | tools.read_file, write_file, edit_file, glob_files, grep_files, ReadMediaFile | yes | subset by workspace | exists (src/tools/filesystem) |
| tools.shell | tools.Bash, TaskOutput, TaskStop, WaitFor, TaskList | yes | no | exists |
| tools.web | tools.FetchURL, WebSearch | yes | fetch only | exists (src/tools/web) |
| tools.agent | tools.Agent, AgentSwarm, superagent | yes | no | exists |
| tools.session | tools.TodoList, Skill, read_tool_result, AskUserQuestion, NotifyUser, ExitPlanMode, Cron*, goal tools, Tower* | yes | partial | exists |
| tools.browser | tools.Browser | yes | no | exists (src/tools/browser) |
| tools.mcp | tools.capability_search, select_tools, ReadMcpResourceTool | yes | no | exists |
| agent.core | agent | yes | yes (libfx wasm) | exists as libfx; in-process binding planned |
| agent.persistence | agent persistence | yes | yes | exists as libfx Persistence; fx:host binding planned |
| net.fetch | fetch | yes | yes | planned (txiki httpclient stubbed) |
| net.tls | fetch over https, serve with cert | yes | no | planned |
| net.server | serve | yes | no | planned |
| net.ws | websocket client and server | yes | partial | planned |
| fs | fs | yes | virtual fs | exists (22 verbs, sync only) |
| watch | watch | yes | no | planned |
| proc | proc.spawn | yes | no | exists for run_command only; streaming spawn planned |
| pty | pty | yes | no | exists inside src/core/terminal/native_session.zig; not exposed |
| timers | timers | yes | yes | exists in txiki (libuv); not table-bound |
| dns | dns | yes | no | planned |
| crypto | crypto | yes | yes | partial: random_bytes, hash_digest exist |
| sqlite | sqlite | yes | no | planned |
| loader | loader | yes | yes | planned |
| reload | reload | yes | yes | planned |

## 2. Tools: host.tools.<name>(args)

### 2.1 Calling convention

- Key is the exact registry name from src/builtins/tools.zig (the name a model sees), for example `host.tools.Bash`, `host.tools.FetchURL`. Today the same name is `gm.Bash`. exists.
- `host.tools.<name>(args)` takes a JSON object and returns a Promise of the result. Today the sync form returns the result text only; the structured form below is planned.
- Result shape, planned: `{ ok: true, text: string, images: [{mimeType, data?, sourceRef?}], details?: object }`. Today only `text` is returned (bootstrap returns `reply.text`), and images and details are dropped.
- `host.tools.$list()` returns the catalog (today: `gm.verbs()`). exists as gm.verbs.

### 2.2 The permission gate

Every `host.tools.*` call is dispatched through `tool_dispatch.dispatchToolCall` (src/tools/runcode/run_code.zig, invokeVerb) which runs `admitToolCall` (src/core/tooling/tool_admission.zig) and the gate in src/core/permissions/permission_gate.zig. JavaScript has no path to a tool that skips it. exists for tool verbs.

Gate inputs, from source:

- Mode: `PermissionMode = ask | auto | yolo | dontAsk` (src/core/shared/types.zig). `ask` and `dontAsk` deny anything not read-only; `yolo` disables checks.
- Per tool: `reads_only_fn`, `irreversible_fn`, `requires_approval`, `approval_policy (standard | ask_only | auto_deny_on_ask)`, `permission_target_kind (none | path_existing | path_optional_existing | path_create_parent | path_existing_parent | command_cwd | url)`.
- Rule name: `permissionNameForTool`: read_file -> read, write_file and edit_file -> edit, glob_files -> glob, grep_files -> grep, run_command -> bash, FetchURL -> FetchURL, Skill and install_skill -> skill, else the tool name.
- Decision: `Action = allow | deny | ask` with `ToolPermissionDenialReason = user_denied | auto_denied | review_caution | review_evidence_incomplete | review_unavailable | policy_denied | permission_required | dont_ask_denied`.

Per-call behaviour: run_code is admitted as the carrier and needs no approval of its own. Each verb a body calls is gated on its own: the tool runtime gives the body an inner call gate (src/core/tooling/tool_runtime.zig, InnerCallGateState) that runs PreToolUse hooks under the verb's name, asks the same permission path a model tool call uses (TUI prompt, ACP session/request_permission, configured rules, auto review; headless ask refuses), executes the verb, then runs PostToolUse. Host verbs are asked through the model tool of their class. Inner call ids are `{parent_call_id}:{n}`. The `--permission-mode` flag of `fx run-code` sets the mode for a body run outside a session, where no gate exists and dispatchToolCall decides by mode.

### 2.3 Errors

Denial and failure throw (or reject with) instances of the named classes below, all subclasses of `FxHostError` with `name`, `code`, `message`. Today a verb failure is a plain `Error(reply.error)`; the named classes are planned.

| name | code | when | extra fields |
| --- | --- | --- | --- |
| FxPermissionDenied | EFX_PERMISSION_DENIED | gate action `deny` | `reason`: one of the eight ToolPermissionDenialReason names, `tool`, `target`, `text` |
| FxPermissionRequired | EFX_PERMISSION_REQUIRED | action `ask` and no prompter is attached (headless host) | `tool`, `target`, `grantSuggestions` |
| FxPolicyDenied | EFX_POLICY_DENIED | reason `policy_denied` (rules, plan mode, sensitive file) | `rule` |
| FxUnknownTool | EFX_UNKNOWN_TOOL | name not in the registry or not model-visible to this session | `name` |
| FxInvalidArgs | EFX_INVALID_ARGS | decode or validate failed | `field`, `message` |
| FxToolFailed | EFX_TOOL_FAILED | tool ran and returned `status: failure` | `text`, `details` |
| FxDeadline | EFX_DEADLINE | body or call deadline passed | `deadlineMs`, `scope: 'body' | 'call'` |
| FxUnsupported | ERR_FX_UNSUPPORTED | capability absent (existing code in cordis/fx_runtime.js) | `target` |
| FxCanceled | EFX_CANCELED | abort signal or cancel | none |
| FxDenied | EFX_DENIED | a loader or service call refused by scope (path outside the JS root, host or port not allowed) | `target`, `class` |

The deadline messages today are "the body passed its JavaScript deadline before this call" (src/core/runcode/runcode.zig) and the code `ERR_FX_UNSUPPORTED` / `EFXHOST` in src/core/runcode/cordis/fx_runtime.js. Both are mapped into the table above when the classes land.

### 2.4 Tool table

Class legend (from `activity_kind`, `requires_approval`, `permission_target_kind` in src/builtins/tools.zig): R read-only no prompt; L list; W write (approval required); C command (approval required unless the command policy admits it); N network; A agent; Q question to the user; M meta. "Target" is the `permission_target_kind` checked against workspace scope and rules.

| host.tools name | args (required marked *) | result | class, target | exists |
| --- | --- | --- | --- | --- |
| glob_files | pattern*:string, path, mode ('count'|...), head_limit:int, offset:int, include_ignored:bool | text: matching paths | L, path_optional_existing | yes |
| grep_files | pattern*:string, path, literal, word, regex, glob, include, type, output_mode, case_insensitive, head_limit, offset, multiline, include_ignored, mode, context_lines | text | R, path_optional_existing | yes |
| read_file | path*:string, start_line, line_count, line_offset, column_offset, n_lines, max_chars | text with numbered lines, or image | R, path_existing | yes |
| ReadMediaFile | path*:string, region:object, full_resolution:bool | image result | R, path_existing | yes |
| write_file | path*, content*, mode ('append') | text | W, path_create_parent | yes |
| edit_file | path*, old_string*, new_string*, replace_all:bool | text | W, path_existing_parent | yes |
| FetchURL | url*:string, timeout:int, query:string, regex:bool | text (untrusted) | N, url (rule name FetchURL) | yes |
| WebSearch | query*:string | text (untrusted) | N (rule name WebSearch) | yes |
| Bash | command*:string, cwd, timeout:int (fg default 60 max 3600; bg default 600 max 86400), description, run_in_background:bool, disable_timeout:bool, name | text; background returns task id | C, command_cwd (rule name bash) | yes |
| TaskOutput | task_id*, wait:int, tail:int | text | C | yes |
| TaskStop | task_id*, reason | text | C, approval required | yes |
| TaskList | active_only:bool, limit:int | text | R | yes |
| WaitFor | timeout*:int, task_id, pid:int | text | R | yes |
| Skill | skill*:string, args:string | loaded instructions | R (rule name skill) | yes |
| install_skill | source*:string, skill:string | text | W, approval required | yes |
| Agent | prompt, description, subagent_type, resume, run_in_background:bool, fork:bool, model | text | A | yes |
| AgentSwarm | description*, subagent_type, prompt_template, items:array, fork, resume_agent_ids:object, model | text | A (model_visible false) | yes |
| superagent | action*:string, agent, prompt, cwd, session, queue:array, offset, limit | text | A | yes |
| AskUserQuestion | questions*:array, background:bool | answers | Q | yes |
| TodoList | todos:array | text | R | yes |
| NotifyUser | message*:string, title | text | R | yes |
| ExitPlanMode | plan:string, options:array | decision | Q | yes |
| vision | focus*:string | text | R, approval_policy ask_only | yes |
| read_tool_result | handle, query, start_byte, byte_count | text | R, internal | yes |
| capability_search | query*:string, server:string | text | R, internal | yes |
| select_tools | names*:array | text | R, internal | yes |
| ReadMcpResourceTool | server*:string, uri*:string | text | R, internal | yes |
| CronCreate | cron, prompt, recurring (others unextracted) | text | approval required | yes |
| CronList | none | text | L | yes |
| CronDelete | id (unverified name) | text | approval required | yes |
| CreateGoal | objective*, completionCriterion, replace:bool | text | R | yes (src/tools/goal/specs.zig) |
| GetGoal | none | text | R | yes |
| SetGoalBudget | value*:int, unit*:'turns'|'tokens'|'milliseconds'|'seconds'|'minutes'|'hours' | text | R | yes |
| UpdateGoal | status*:string | text | R | yes |
| Browser | action*:string, url, target_id, session_id, expression | text | C, approval required, runtime provider browser | yes |
| TowerInit, TowerPlan, TowerSpawn, TowerMission, TowerStatus, TowerMerge, TowerRebase, TowerTeardown, TowerInbox, TowerSend, TowerFinding, TowerReview, TowerComplete | per src/tools/tower/*.zig | text | A | yes (registry_with_tower) |
| run_code | not exposed as a host tool (excluded by buildCatalog) | | | n/a |

Where an args column is not exhaustive (Agent, Browser, Cron*, Tower*), the authority is the `model_schema` of the ToolSpec in src/builtins/tools.zig or the named file. Generating the `.d.ts` from that schema is planned (docs/host-interface.d.ts is hand-written to match).

Host verbs (22, src/core/runcode/host_verbs.zig, exists): process_info, fs_exists, fs_stat, fs_read, fs_write, fs_read_range, fs_write_at, fs_readdir, fs_mkdir, fs_mkdtemp, fs_remove, fs_rename, fs_copy, fs_realpath, fs_readlink, fs_symlink, fs_link, fs_chmod, fs_truncate, run_command, random_bytes, hash_digest. G1 closed: `run_code.invokeVerb` calls `host_verb_gate.refusal` (src/core/runcode/host_verb_gate.zig) before `host_verbs.call`; the gate builds the equivalent model tool call and runs it through `tool_dispatch.admitToolCall`, the same admission a model tool call gets, without executing it. Mapping, one row per verb (a missing or duplicate row is a compile error and a test failure): none = process_info, random_bytes, hash_digest; read (as read_file on `path`) = fs_exists, fs_stat, fs_read, fs_read_range, fs_readdir, fs_realpath, fs_readlink; write (as write_file on every path field) = fs_write, fs_write_at, fs_mkdir, fs_mkdtemp (`prefix`), fs_remove, fs_rename and fs_copy (`from`, `to`), fs_symlink, fs_link (`path`, `existing`), fs_chmod, fs_truncate; execute (as the Bash tool, `action` run, command built from `file` and `args`) = run_command. Non-interactive ask and dontAsk refuse write and execute rows without prompting; yolo admits them. Denial reply: `{"ok":false,"code":"EFX_PERMISSION_DENIED","verb":...,"error":<tool_permission_denied JSON text>}`.

## 3. Agent core: host.agent

Shape follows sdk/types/libfx.d.cts (libfx API version 2, `fxSdkApiVersion`). Today libfx runs headless over ACP through the N-API addon (src/napi_core_main.zig, sdk/node.js, sdk/engine.js) and has no native tools and no permissions; its tools are JS host tools. The `fx:host` binding runs the same shape in process, against fx's native loop, tools and gate: planned. Names and shapes below are verified against libfx.d.cts.

```ts
agent(options: FxAgentOptions): FxAgent
```

- Options: `name`, `tools`, `instructions`, `hooks`, `durability`, `checkpoint`, `fetch`, `modelCatalog`, `onEvent`, model choice (`model`, `effort`, `fast`, `ultrafast`) and one provider: gateway (default), `codex`, `grok` (with `credentials()`), or a custom provider.
- In `fx:host` an extra option `nativeTools: boolean | string[]` (planned) lets the session use fx's native tools through the gate; absent, the agent is headless exactly like libfx.

### 3.1 Agent and session

| member | signature | status |
| --- | --- | --- |
| agent.session | `(id?: string, options?: {context, model, instructions}) => FxSession` | exists in libfx |
| agent.newSessionId | `() => Promise<string>` | exists in libfx |
| agent.prompt | `(input, {messageId, signal}) => FxTurn` | exists in libfx |
| agent.checkpoint | `() => Promise<Uint8Array>` | exists in libfx |
| agent.wakeHandler | `() => (Request) => Promise<Response>` | exists in libfx |
| agent.close | `() => Promise<void>` | exists in libfx |
| session.prompt | `(input, {messageId, signal}) => FxTurn` | exists in libfx |
| session.steer | `(input, {messageId}) => Promise<{messageId}>` | exists in libfx |
| session.cancel | `() => Promise<void>` | exists in libfx |
| session.resume | `() => FxResumeTurn` | exists in libfx |
| session.stream | `(cursor?: number) => ReadableStream<Uint8Array>` (NDJSON FxStreamLine) | exists in libfx |
| session.checkpoint | `() => Promise<Uint8Array>` | exists in libfx |

`FxTurn` has `accepted`, `result`, `messageId`, `readable`, and is an async iterable of events. `FxTurnResult.stopReason`: end_turn, max_output_tokens, max_model_turns, refused, cancelled, error, unknown. Low-level `FxEngine` (prompt, resume, followUp, checkpoint, close; turn cancel, steer, withdraw) exists in libfx and is exposed as `host.agent.engine(options)`: planned binding.

### 3.2 Events

Turn events (`FxTurnEvent`): text_delta, reasoning_delta, user_message, tool_start, tool_end. Engine and session diagnostics (`FxEngineEvent`, `FxSessionEvent`): runtime.*, transport.*, permission.request, permission.resolve, journal.*, checkpoint.*, output.*, session.error, session.fenced, session.forwarded, session.refused, session.deadline, ui.error. All exist in libfx.d.cts. In `fx:host` the native loop's events are projected onto these types: planned. fx's own session events live in src/core/session/session_event.zig and are not these types (G4).

### 3.3 Custom tools

`FxHostTool`: `{ name, description, inputSchema, execute(input, {signal, executionId, sessionId, context, observation}), idempotent?, writes? }`; the web search provider tool is `{ name: 'web_search', providerExecuted: true }`. The execute return becomes an `FxToolResult` (`text`, `images`, `isError`). exists in libfx.

In the in-process binding, a custom tool is registered into the Zig registry as a JS-callback tool and passes the same gate as a native tool, with `writes` mapping to `requires_approval` and `idempotent` to `host_idempotent`: planned. Registration is dynamic (`dynamic_tool` appears in docs/txiki-embedding.md; no source registration path from JS exists).

### 3.4 Custom providers

`FxCustomProvider`: `{ provider: { name, baseUrl, protocol?, models? }, credentials?(req) => {apiKey} }`. `protocol` is `"openai-chat-completions"` (default) or `"anthropic-messages"`; endpoint path is `/chat/completions` or `/messages`; non-https base URLs are allowed only for loopback (sdk/custom-provider.js, lines on protocolFields and endpointPaths). exists in libfx. For the CLI, the `providers` settings key (src/core/config/settings_keys.zig) with `protocol`, `base_url`, `auth`, `tool_choice_mode`, `reviewer_model`, `model_metadata` (src/core/config/configured_provider.zig, `Protocol` enum with both values; messages codec in src/gateway/messages_protocol.zig). exists. Registering a provider whose transport is a JS function (not a URL) is planned.

### 3.5 Hooks

libfx hooks: `hooks: { onEvent(FxHookEvent), onError?, captureContent?, parent? }` where events are versioned (`version: 1`) with types turn.start, turn.end, step.*, model.start, model.admitted, model.output_start, model.end, tool.start, permission.start, permission.end, tool.end, tool.result, wait.start, wait.end, mcp.*, delegation, journal.*. exists in libfx.d.cts (observe only). fx native command hooks (src/core/hooks, src/builtins/hooks/command.zig): HookKind `pre_tool_use | stop | post_turn_end | attention_required | user_prompt_submit | observation`, configured as commands, scopes interactive, ask, acp, subagent. exists. A JS handler registered into the native hook table, able to veto `pre_tool_use`: planned (`host.agent.hooks.on(kind, fn)`).

### 3.6 Persistence and resume

libfx `Persistence` interface: `load() => {checkpoint?, journal?, head?}`, `append({expected, idempotencyKey, data, barrier, marks?}) => {cursor}`, `saveCheckpoint?`, plus `createMemoryPersistence()`, `FxFencedError` (code FX_FENCED), `FxJournalVersionError` (FX_JOURNAL_VERSION). exists in libfx. `checkpoint` option and `session.checkpoint()` carry opaque bytes. fx's own session store is a directory per session with events.jsonl (src/core/session/session_layout.zig, session_replay.zig) and ACP methods session/new, load, resume, close, list, fork, delete (src/acp/server.zig). exists. Resume through the native store from JS: planned (`host.agent.sessions.list|open|fork|delete`). The journal format of libfx is not the native events.jsonl and not freddie's event-sourced format (G4).

## 4. System services (txiki route)

Today every service marked planned is a txiki stub or absent. Each is generated from the table, gated, and implemented over Zig, not libuv or mbedtls, so one network stack and one permission model exist.

Class for gating: each service call is classified like a tool (read, write, command, network, listen) and goes through the same gate and rule names. Host verbs pass host_verb_gate today; the per-service classes for network and listen are planned.

| namespace | API | status |
| --- | --- | --- |
| fetch | `fetch(input, init)` WHATWG shape over src/core/shared/http_pool.zig and std.http; rule name FetchURL for url class; TLS by Zig std.crypto.tls | planned (tools.FetchURL exists as a text tool) |
| serve | `serve({host, port, tls?, fetch(req) => Response, websocket?: {open,message,close,error}}) => {port, close(), reload(handler)}` | planned (only ad hoc loopback listeners exist: core/auth/browser_callback.zig, core/shared/local_address.zig) |
| websocket | `new WebSocket(url)` client; server through `serve`; Zig has a client handshake in src/core/browser/birdman.zig | planned |
| fs | `readFile, writeFile, appendFile, readdir, stat, lstat, mkdir, mkdtemp, rm, rename, copy, realpath, readlink, symlink, link, chmod, truncate, open (read, write at offset)`; async; arg shapes mirror host verbs | exists as the 22 sync host verbs (base64 payloads); async binding and gate planned |
| watch | `watch(path, {recursive}, cb) => {close()}` events `create|change|remove|rename` | planned (only an mtime and size fingerprint check for instruction files: src/builtins/instruction_watch.zig) |
| proc | `spawn({cmd, args, cwd, env, stdin, signal}) => {pid, stdout, stderr, stdin, exited, kill(sig)}` | planned (host verb run_command is run-to-completion with 16 MiB output cap) |
| pty | `pty.open({cmd, args, cwd, env, cols, rows}) => {write, onData, resize, kill, exited}` | planned (openPty in src/core/terminal/native_session.zig) |
| timers | `setTimeout, setInterval, setImmediate, clear*`, `performance.now()` | exists (txiki libuv); bounded by body deadline |
| dns | `dns.lookup(host, {family})`, `dns.resolve` | planned (cordis fx_runtime fails dns.lookup and dns.resolve) |
| crypto | `randomBytes(n)`, `hash(algorithm, bytes)`, `hmac`, `subtle` WebCrypto | partial: random_bytes (max 1 MiB) and hash_digest exist; hmac, subtle planned (txiki webcrypto init is a stub) |
| sqlite | `sqlite.open(path, {readonly}) => {exec, prepare(sql) => {all, get, run}, close}` | planned (no sqlite in tree) |
| os | `platform, arch, homedir, tmpdir, hostname, cpus, networkInterfaces` | exists via process_info (partly; networkInterfaces fails in cordis) |
| zlib | `inflate, deflate, gzip, gunzip, brotli, zstd` | planned (miniz stub) |

### 4.1 freddie runtime mapping

The seam is packages/util/runtime (freddie), whose `txikiRuntime` object has these members, all of which must map: fs, fsPromises, path, crypto, stream, buffer, url, util, utilTypes, module, childProcess, os, workerThreads, asyncHooks, vm, http, https, zlib, inspector, stringDecoder, perfHooks, timersPromises, net, dnsPromises, process. The runtime's own src/node.js imports the 25 `node:` modules for the Node install; everything else in freddie outside the runtime imports `node:path` (9), `node:url` (6), `node:module` (6), `node:fs` (6), `node:crypto` (6), `node:fs/promises` (3), `node:child_process` (1) (grep of freddie packages and framework). Raw `tjs.*` names used by freddie's src/txiki.js: stat, lstat, open, readLink, readFile, readDir, remove, rename, copyFile, makeDir, makeTempDir, realPath, symlink, link, chmod, spawn, kill, exit, exePath, cwd, homeDir, tmpDir, env, args, pid, ppid, lookup, system.cpus, system.networkInterfaces.

| freddie runtime member | fx:host entry | status |
| --- | --- | --- |
| fs, fsPromises (read, write, stat, readdir, mkdir, mkdtemp, rm, rename, copy, realpath, readlink, symlink, link, chmod, truncate, open) | fs.* | exists as host verbs; async binding planned |
| fs.watch, fs.watchFile, unwatchFile | watch | planned (named gap G5) |
| fs.createReadStream, fsPromises.opendir | fs.open plus stream built in JS | planned (cordis runtime fails both) |
| path, url, util, utilTypes, stringDecoder, timersPromises, perfHooks | pure JavaScript inside freddie's runtime | no host entry. perf_hooks.performance needs `timers.now` (cordis fails it); util.parseArgs is JS |
| buffer | pure JS over Uint8Array plus host base64/hex | no host entry; Buffer.from, alloc, byteLength fail in cordis today (G6) |
| stream | pure JS | no host entry; Readable, Writable, PassThrough, pipeline fail in cordis today (G6) |
| crypto | crypto.* | partial (randomBytes, hash exist; hmac, subtle, timingSafeEqual planned) |
| childProcess (spawn, exec, execFile) | proc.spawn | exec-style run_command exists; spawn named gap G7 (cordis fails child_process.spawn) |
| os | os.* | exists partial |
| process (env, argv, cwd, pid, ppid, exit, platform, hrtime) | process_info host verb, `proc.exit` | process_info exists; process.exit fails today (G8) |
| http, https (client) | fetch | planned; https.get, https.request fail in cordis |
| http.createServer, https.createServer | serve | planned (named gap G3) |
| net | net.connect, net.listen (TCP socket) | planned: named gap G9 |
| dnsPromises | dns.* | planned |
| zlib | zlib.* | planned (named gap G10: gzip, brotli, zstd all fail in cordis) |
| workerThreads (Worker, MessageChannel) | host.worker | named gap G11 (no Worker; fx would use QuickJS contexts or a subagent) |
| asyncHooks (AsyncLocalStorage) | language support in the engine | named gap G12; cordis fails it |
| vm (Script, createContext, runInContext) | host.eval | named gap G13 |
| module (createRequire, stripTypeScriptTypes) | loader | planned; createRequire fails today |
| inspector | none | named gap G14 (Session): drop or stub in freddie |

### 4.2 Node alias table (txiki route; the identity on edgejs)

One table, src/core/runcode/host_module.zig. `node:<name>` and the bare `<name>` resolve to the same target, for `import` and `require` alike, before any node_modules lookup. A gap row, or a `node:` name with no row, fails with `'<specifier>' is not provided by fx:host yet; it is on the gap list in docs/host-interface.md`. A bare name with no row is a package name and goes to node_modules. Zig tests next to the table check that every row resolves in both forms, that `node:fs` and `fs` agree, that an unknown name is the named error, and that the table, the generated `fx:host` module list and fx_runtime.js agree; src/tools/runcode/run_code.zig imports every provided module in both forms and checks that no named export is undefined. Provided (exists):

| Node name (also `node:<name>`) | target | fxRuntime member | named exports |
| --- | --- | --- | --- |
| child_process | fx:host/child_process | childProcess | execFile, execFileSync, spawn, spawnSync |
| crypto | fx:host/crypto | crypto | createHash, randomBytes, randomUUID |
| fs | fx:host/fs | fs | accessSync, closeSync, constants, copyFileSync, createReadStream, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, readlinkSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, unlinkSync, unwatchFile, watchFile, writeFileSync, writeSync |
| fs/promises | fx:host/fs/promises | fsPromises | access, chmod, constants, cp, link, lstat, mkdir, mkdtemp, open, opendir, readFile, readdir, realpath, rename, rm, stat, truncate, unlink, writeFile |
| net | fx:host/net | net | isIP |
| os | fx:host/os | os | availableParallelism, constants, homedir, networkInterfaces, platform, release, tmpdir |
| path | fx:host/path | path | basename, delimiter, dirname, extname, format, isAbsolute, join, normalize, parse, posix, relative, resolve, sep, toNamespacedPath, win32 |
| process | fx:host/process | process | default only |
| string_decoder | fx:host/string_decoder | stringDecoder | StringDecoder |
| timers/promises | fx:host/timers/promises | timersPromises | scheduler, setTimeout |
| url | fx:host/url | url | URL, URLSearchParams, fileURLToPath, pathToFileURL |
| util | fx:host/util | util | TextDecoder, inspect, isDeepStrictEqual, parseArgs, parseEnv, promisify |
| util/types | fx:host/util/types | utilTypes | isPromise |

freddie's runtime src/node.js imports all 25 names, so freddie's install-node composition root loads inside fx only once every gap row below is closed; until then the embedded copy maps install-node to install-fx (src/core/runcode/cordis.zig), which installs fx_runtime.js directly.

Gap list (named error at import):

| Node name | gap |
| --- | --- |
| async_hooks | G12 (AsyncLocalStorage) |
| buffer | G6 (Buffer over Uint8Array) |
| dns/promises | planned `dns` service |
| http | G3 (`serve`) and planned `fetch` |
| https | G3 (`serve`) and planned `fetch` |
| inspector | G14 |
| module | planned loader (`createRequire`) |
| perf_hooks | needs `timers.now` |
| stream | G6 (Readable, Writable, PassThrough, pipeline) |
| vm | G13 |
| worker_threads | G11 |
| zlib | G10 |

A provided module can still carry functions that throw `ERR_FX_UNSUPPORTED` when called (fs.createReadStream, fs.watchFile, fs/promises.opendir, child_process.spawn, os.networkInterfaces, util.parseArgs, path.win32 members, process.exit); those stay on the gap rows of section 7.

## 5. Module loader: host.loader

### 5.1 JS root resolution

First hit wins, in this order. planned.

1. `--js-root <dir>` on the fx command line.
2. `FX_JS_ROOT` environment variable.
3. `<project>/.fx/js`, where `<project>` is the workspace root fx resolved.
4. `~/.fx/js` (home resolved through FX_HOME when set, as in src/main.zig `useFxHomeFromEnv`).

The root must be an absolute directory. `host.loader.root` reports the chosen path and the rule that chose it. A root with no `fx.json` manifest is valid (freddie's checkout is a valid root). The bootstrap module is `<root>/bootstrap.js`.

### 5.2 Import map

One import map, `<root>/fx.importmap.json`, standard shape `{"imports": {...}, "scopes": {...}}`. Resolution of a bare specifier: scopes, then imports, then `<root>/node_modules` package exports (the logic in src/core/runcode/resolve.zig handles exports and subpath patterns for the embedded package and is reused). The embedded `@freddie/freddie-runtime` copy under src/core/runcode/cordis stays as a fallback below the root only until the freddie runtime is rewritten on `fx:host`.

### 5.3 import.meta.hot

```ts
interface ImportMetaHot {
  readonly data: Record<string, unknown>
  accept(deps?: string | string[], cb?: (mods: unknown[]) => void): void
  dispose(cb: (data: Record<string, unknown>) => void): void
  invalidate(reason?: string): void
  decline(): void
}
```

Present on every module loaded from the root, absent on `fx:host` itself. `data` is the hand-off bag: what `dispose` writes is what the next instance of the module reads. planned.

### 5.4 Node names and refused specifiers (txiki route)

`node:*` and bare Node built-in names resolve through the alias table (4.2); the gap rows fail with the named error. `tjs:*` loads txiki built-ins under `import` and is refused by `require`. exists. Planned: allowed specifiers limited to `fx:host`, relative and absolute file paths inside the root, import-map entries and package names under `<root>/node_modules`; a path outside the root (resolved through realpath) refused with `FxDenied` unless the gate allows reading it. Dynamic `import()` follows the same rules.

## 6. Reload protocol: host.reload

All planned.

1. Watch. `host.watch` on the root (recursive, debounced 50 ms, ignoring node_modules and dotted directories) feeds the loader.
2. Graph. The loader keeps a module graph: nodes are resolved file paths with content hash; edges are import and `accept` relations. A changed file marks itself and every transitive importer dirty.
3. Boundary. Walk up from the changed module to the nearest module that called `import.meta.hot.accept` for it (or itself). Modules with `decline` or no accepting ancestor trigger a full reload of the root (the bootstrap is re-evaluated). `invalidate` forces the next boundary up.
4. Re-evaluate. For each dirty module in dependency order: run its registered `dispose(data)` callbacks (children first), then evaluate the new source as a new instance, then call `accept` callbacks with the new exports.
5. Dependents. For Cordis, freddie's framework/hmr maps a changed module to the plugins that depend on it: dispose those plugins, then apply them again with the new module. The host does not know Cordis; it gives the module graph (`reload.dependents(path)`) and the events (`reload.on('applied'|'failed', fn)`).
6. Hand-off. Plugin state crosses a reload through exactly one declared object, `import.meta.hot.data`: `dispose` writes it, the new instance reads it. State not placed there is dropped. Values must be structured-cloneable or live handles the host marks `transferable` (open sockets, ptys, watchers owned by the module are closed on dispose unless transferred).
7. Failure. If any step throws (syntax error, evaluation throw, an `accept` callback throw, a plugin apply error), the old instances stay running, nothing from the failed batch is committed, and the host emits `reload.failed` and writes the error into the active session as a system message of the form `{type: 'reload.failed', path, phase: 'parse' | 'evaluate' | 'accept' | 'apply', error: {name, message, stack}}` so the agent can see and fix its own change. The file stays on disk; the next save retries.
8. Failed starts. A start is the first full evaluation of the bootstrap. A start is healthy when the bootstrap resolves and `host.reload.markHealthy()` is called (or 5 seconds pass with no failure event).

### 6.1 Last known good

- On every healthy start, the host snapshots the root content-addressed: each file stored by sha256 under `~/.fx/js-lkg/objects/<sha256>`, with a manifest `~/.fx/js-lkg/manifest.json` mapping relative path to hash plus the import map hash and `host.version.table`. Old snapshots are pruned to the last 3 manifests.
- `fx js rollback [--to <manifest id>]` restores the root from the snapshot: it writes the files back (and removes files not in the manifest, listing them first), then reloads. Exit status 0 on success.
- If the bootstrap fails to start twice in a row (counter stored next to the manifest), the third start restores the last-known-good snapshot automatically and prints one line on stderr and into the session: `fx: JS root failed to start twice, restored last known good <id>`. The broken tree is kept at `~/.fx/js-lkg/failed/<timestamp>/`.
- `fx js doctor` reports root resolution, import map errors, manifest state, and failed-start counter.

None of this exists in the tree (grep for rollback, last known good, js-root: no hits).

## 7. Gaps

| id | gap | state in tree |
| --- | --- | --- |
| G1 | Host verbs (fs_*, run_command, random_bytes, hash_digest) bypass the permission gate | closed: every host verb passes host_verb_gate.refusal (table in src/core/runcode/host_verb_gate.zig) before dispatch |
| G2 | No OS sandbox beyond the permission layer | confirmed: grep of src for seccomp, landlock, sandbox-exec, bwrap, unshare finds nothing |
| G3 | No HTTP or WebSocket server for a host application (`serve`); txiki httpserver, ws and tls are stubs | confirmed |
| G4 | freddie's event-sourced session format is not reusable as is: fx stores events.jsonl per session (src/core/session) and libfx has its own journal (`Persistence`); three formats exist. The plan keeps freddie's format only as a projection of fx's sessions | confirmed |
| G5 | No native file watcher exposed to JS | planned |
| G6 | Buffer and stream implementations are missing in the cordis copy (fail() entries) | verified |
| G7 | Streaming `proc.spawn` | planned |
| G8 | `process.exit` and process lifecycle from JS | planned |
| G9 | Raw TCP sockets (`net`) | planned |
| G10 | zlib (gzip, brotli, zstd) | planned |
| G11 | Worker threads | named gap |
| G12 | AsyncLocalStorage | named gap |
| G13 | `vm` | named gap |
| G14 | `inspector` | named gap |
| G15 | Per-call gate for `fx:host` calls inside a body | done |
| G16 | Structured tool results (images, details) and named error classes | planned |
| G17 | JS-implemented custom tools and providers registered into the Zig registry | planned |
| G18 | JS hooks that can veto in the native hook table | planned |
| G19 | `fx js` subcommands (run, rollback, doctor), `fx freddie`, `fx plugin add` | planned (only `fx run-code` exists) |
| G20 | Table-driven generation of `fx:host` and of the `.d.ts` from ToolSpec schemas | partial: the module and the Node alias modules are generated from host_module.zig; arg and result schemas and the `.d.ts` are planned |

Correction to the owner's plan: an Anthropic-compatible custom endpoint is no longer a gap. src/core/config/configured_provider.zig defines `Protocol = openai-chat-completions | anthropic-messages`, src/gateway/messages_protocol.zig implements the codec, and libfx's sdk/custom-provider.js accepts `protocol`. What remains planned is a provider whose transport is a JS function.

## 8. Browser: fx on thebird's single edge.js instance (Stage 3 of specs/edge-js.md)

Status: design for thebird to implement; nothing in this section is built on either side yet. fx-core.wasm and fx-term.wasm keep bundling no JS engine. The page owns exactly one edge.js instance (the pin in section 9) and fx reaches it through new `fx_*` imports in the existing `fx` import module (web/vendor/fx/wasm-runtime.js, next to `fx_host_tool_call`). A network log with a second engine wasm is a failed witness.

### 8.1 What fx needs from the engine

`run_code`, `fx js`, `fx freddie` and the `fx:host` modules all reduce to one operation: run one script or body to completion on an edge.js environment, with `fx:host` verb calls going back to fx, a console sink, a deadline and an exit code. The native route does this in one process (native/edgejs/fx_edge.cc: `fxHost.call(name, argsJson)` is a synchronous native function). The browser route keeps the same operation and moves the two directions across the wasm boundary.

### 8.2 Imports (fx wasm calls the page; every one is `WebAssembly.Suspending`)

| import | arguments | result |
| --- | --- | --- |
| `fx_js_available()` | none | 1 when the page holds an edge.js instance or can load one, else 0. Does not load the engine. |
| `fx_js_run(reqPtr, reqLen, outPtr, outCap, statusPtr)` | `req` is JSON: `{ run_id, file?, body?, format: "esm" \| "cjs", deadline_ms, argv: [..], cwd, env: {..}, permission_mode, handle }` | length of the report JSON written to `out`; the report is the one the native runner prints: `{ ok, value, console, console_dropped, error?, exit_code? }`. A negative value is an error (-1 no engine, -2 cancelled, -3 report larger than `outCap`, in which case the page keeps it for the read pair below). `status[0]` bit 0 is set when the engine failed to start. |
| `fx_js_result_read(offset, ptr, cap)` and `fx_js_result_release()` | as `fx_host_tool_result_read` and `fx_host_tool_result_release` | the same chunked read of an oversized report |
| `fx_js_cancel(runIdPtr, runIdLen)` | run id | stops the run: the page rejects pending verb calls and interrupts the environment |

The first `fx_js_run` is what loads the engine (streamed, cached, behind the page's own loading UI); `fx_js_available` never does.

### 8.3 Exports (the page calls the fx wasm; this is how a script reaches the verbs)

| export | arguments | result |
| --- | --- | --- |
| `fx_verb_call(handle, namePtr, nameLen, argsPtr, argsLen, outPtr, outCap)` | `handle` is the value from the run request; `args` is the verb's JSON arguments | length of the reply JSON written to `out`, or a negative code as for `fx_host_tool_call` |
| `fx_verb_reply_read(offset, ptr, cap)` and `fx_verb_reply_release()` | as above | chunked read when the reply is larger than `outCap` |

`fx_verb_call` dispatches through the same Zig path as native `fx_edge_host_call`: the verb table in src/core/runcode/host_verbs.zig, the gate in host_verb_gate.zig first. The permission gate therefore stays in fx on both routes; the page does not decide what a verb may do.

Re-entrancy: `fx_js_run` suspends the fx stack (JSPI) while the engine runs, and the engine calls `fx_verb_call` on the same wasm instance while that stack is suspended. fx guarantees that `fx_verb_call` uses no state that a suspended frame holds open: the run context lives behind `handle`, in a table, not on the suspended stack. thebird must call `fx_verb_call` only between a `fx_js_run` and its return.

### 8.4 Inside the engine (prelude, loaded once per environment)

- `fxHost.call(name, argsJson)` is a synchronous function on native. In the browser the page defines it as a JSPI-suspending function that awaits `fx_verb_call`; where a script runs on a stack that cannot suspend, `fxHost.callAsync(name, argsJson)` returns a promise with the same reply. fx's JS (bootstrap and `fx:host` modules) uses `callAsync` only where it must and `call` everywhere else, so one source serves both routes.
- The same prelude refuses the Node I/O modules outside yolo, exactly as docs/edgejs-engine.md describes for the native route (it is a policy gate, not a sandbox). In the browser the Node `fs`, `net` and `child_process` modules are backed by thebird's workspace and network layers; fx treats them as untrusted for permission purposes and routes writes through verbs.
- One environment per run: each edge `Run*` call re-bootstraps Node, so every `fx_js_run` creates a fresh environment on the shared engine and frees it afterwards. This costs a Node bootstrap per call; thebird reports the warm figure. It does not create a second engine.
- The console sink, the deadline (a page timer that interrupts the environment) and `process.exit` are the prelude's, so the report is identical on both routes. The parity suite and freddie's conformance suite are the equivalence test between them.

### 8.5 What thebird provides

1. One edge.js instance for the page, created before or at the first `fx_js_run`, shared with thebird's own `node` and `tjs`-style shell commands (they call the same `edge.run`).
2. The two import groups above in wasm-runtime.js, behind an option (`options.edge`) so a page without an engine keeps `fx_js_available()` at 0 and fx reports "no JS engine" for run_code instead of failing.
3. Streaming load and a cache for the engine bytes; time to shell does not wait for it.

### 8.6 Witness (Stage 3)

A live page where `fx ask` runs bash and a `run_code` body that calls `fx:host` verbs and `node -e` on the same edge instance, with one engine wasm request in the network log and its size recorded, plus a red check: a build that bundles an engine into fx-core.wasm or loads a second engine produces two engine requests.

## 9. Engine pin (shared with gm and thebird)

One edge.js pin is recorded once for gm, fx and thebird. Today fx links the tree gm built for its spike: edge.js 0.2.5 (`VERSION.txt`), QuickJS-NG engine, tree at /workspace/tmp/gm/edgejs/src (no `.git`, so no commit id is available from it). The commit id and the archive sha256 belong to gm's pin file; fx adopts them unchanged and does not keep its own. Until gm records them, fx's build input is `-Dedgejs=<dir>` against that tree.
