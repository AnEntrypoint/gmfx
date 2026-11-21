
Status: specification, written against fx source at the checkout in /workspace/fx/fx. Every row is tagged `exists` (verified by reading or grepping the named source path) or `planned` (not in the tree). freddie (/workspace/freddie, packages/util/runtime) codes against this file. Nothing here is a promise beyond the tags.

## 0. Ground truth today

- fx embeds txiki.js: build.zig runs cmake on native/txiki and links libfx_txiki.a, libfx_quickjs_ng.a and libuv.a. exists.
- The embedded runner is src/core/runcode/runcode.zig. It is reached by the model tool run_code (src/tools/runcode/run_code.zig) and by the CLI subcommand `fx run-code --file <path> [--deadline-ms N] [--format esm|cjs] [--permission-mode <mode>]` (src/main.zig, runCli). exists.
- The body sees one global, `gm`, built by src/core/runcode/runcode_bootstrap.js from a catalog: one entry per registered tool (kind `tool`) plus 22 host verbs (kind `host`). Tool verbs are synchronous, return the result text, and throw `Error(reply.error)` on failure. Host verbs return `{ok, ...}` objects. exists.
- Hard-coded aliases in the bootstrap: `run_shell -> Bash`, `grep -> grep_files`, `find -> glob_files`, `fetch -> FetchURL`. exists.
- Body deadline: `deadline_ms` default 120000, max 3600000. Result JSON: `{ok:true,value,console,console_dropped}` or `{ok:false,error,console,console_dropped}`. exists.
- Loader today: `require` of relative files (fx.read_text), bare specifiers through `fx.resolve` (src/core/runcode/resolve.zig) which resolves into the embedded `@freddie/freddie-runtime` copy (src/core/runcode/cordis/*.js, listed in cordis.zig), `node:` and `tjs:` refused with a message naming gm verbs. ES modules via `format: "esm"` with hoisted imports (imports.zig). exists.
- Not present anywhere in the tree (grep for js-root, FX_JS_ROOT, import.meta.hot, rollback, .fx/js, fx:host): the `fx:host` module, JS root resolution, import map, hot reload, last-known-good. All planned.
- txiki network, TLS, websocket, http server, hashing, miniz are stubs: native/txiki/glue/txiki_stubs.c defines empty tjs__mod_tls_init, tjs__mod_httpclient_init, tjs__mod_httpserver_init, tjs__mod_ws_init, tjs__mod_hashing_init, tjs__mod_miniz_init. exists (as stubs).

## 1. Module shape and versioning

```js
import host from 'fx:host'
import { version, capabilities, tools, agent, fetch, serve, fs, watch, proc, pty, timers, dns, crypto, sqlite, loader, reload } from 'fx:host'
```

`fx:host` is generated from one Zig table. Each row names a path (`tools.Bash`, `fs.readFile`), an arg schema, a result schema, a permission class, a capability id and a status. The module is the only host entry; `node:` and `tjs:` specifiers are refused (section 5).

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

Today's body-level behaviour: run_code is itself `irreversible` and not read-only, and its description states one approval covers the whole body and every verb it calls. The `--permission-mode` flag of `fx run-code` sets the mode for the body. So per-call prompts inside a body are not exercised in the shipped path; the per-call gate is what dispatchToolCall enforces for the mode given. For `fx:host` the contract is stricter (per call gate, never body-level amnesty): planned.

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
| FxUnsupported | ERR_FX_UNSUPPORTED | capability absent (existing code in cordis/fx_runtime.js) | `name` |
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
| G1 | Host verbs (fs_*, run_command, random_bytes, hash_digest) bypass the permission gate | closed: every host verb passes host_verb_gate.refusal (table in src/core/runcode/host_verb_gate.zig) before dispatch |
Status: specification, written against fx source at the checkout in /workspace/fx/fx. Every row is tagged `exists` (verified by reading or grepping the named source path) or `planned` (not in the tree). freddie (/workspace/freddie, packages/util/runtime) codes against this file. Nothing here is a promise beyond the tags.

## 0. Ground truth today

- fx embeds txiki.js: build.zig runs cmake on native/txiki and links libfx_txiki.a, libfx_quickjs_ng.a and libuv.a. exists.
- The embedded runner is src/core/runcode/runcode.zig. It is reached by the model tool run_code (src/tools/runcode/run_code.zig) and by the CLI subcommand `fx run-code --file <path> [--deadline-ms N] [--format esm|cjs] [--permission-mode <mode>]` (src/main.zig, runCli). exists.
- The body sees one global, `gm`, built by src/core/runcode/runcode_bootstrap.js from a catalog: one entry per registered tool (kind `tool`) plus 22 host verbs (kind `host`). Tool verbs are synchronous, return the result text, and throw `Error(reply.error)` on failure. Host verbs return `{ok, ...}` objects. exists.
- Hard-coded aliases in the bootstrap: `run_shell -> Bash`, `grep -> grep_files`, `find -> glob_files`, `fetch -> FetchURL`. exists.
- Body deadline: `deadline_ms` default 120000, max 3600000. Result JSON: `{ok:true,value,console,console_dropped}` or `{ok:false,error,console,console_dropped}`. exists.
- Loader today: `require` of relative files (fx.read_text), bare specifiers through `fx.resolve` (src/core/runcode/resolve.zig) which resolves into the embedded `@freddie/freddie-runtime` copy (src/core/runcode/cordis/*.js, listed in cordis.zig), `node:` and `tjs:` refused with a message naming gm verbs. ES modules via `format: "esm"` with hoisted imports (imports.zig). exists.
- Not present anywhere in the tree (grep for js-root, FX_JS_ROOT, import.meta.hot, rollback, .fx/js, fx:host): the `fx:host` module, JS root resolution, import map, hot reload, last-known-good. All planned.
- txiki network, TLS, websocket, http server, hashing, miniz are stubs: native/txiki/glue/txiki_stubs.c defines empty tjs__mod_tls_init, tjs__mod_httpclient_init, tjs__mod_httpserver_init, tjs__mod_ws_init, tjs__mod_hashing_init, tjs__mod_miniz_init. exists (as stubs).

## 1. Module shape and versioning

```js
import host from 'fx:host'
import { version, capabilities, tools, agent, fetch, serve, fs, watch, proc, pty, timers, dns, crypto, sqlite, loader, reload } from 'fx:host'
```

`fx:host` is generated from one Zig table. Each row names a path (`tools.Bash`, `fs.readFile`), an arg schema, a result schema, a permission class, a capability id and a status. The module is the only host entry; `node:` and `tjs:` specifiers are refused (section 5).

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

Today's body-level behaviour: run_code is itself `irreversible` and not read-only, and its description states one approval covers the whole body and every verb it calls. The `--permission-mode` flag of `fx run-code` sets the mode for the body. So per-call prompts inside a body are not exercised in the shipped path; the per-call gate is what dispatchToolCall enforces for the mode given. For `fx:host` the contract is stricter (per call gate, never body-level amnesty): planned.

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
| FxUnsupported | ERR_FX_UNSUPPORTED | capability absent (existing code in cordis/fx_runtime.js) | `name` |
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

