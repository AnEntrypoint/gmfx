# Interactive MCP server configuration

The user invoked this through `/mcp-config`. Either they want to log into
an MCP server that asked for OAuth, or they want to edit the `mcp.json`
that lists MCP servers. The work is small and local. Handle it on this
turn yourself, with no agents or planning todos.

Pick the flow from the user's message and your tool list:

- An `mcp__<server>__authenticate` tool is in your list, the user says
  "log in" / "auth" / "sign in", they invoke `/mcp-config login
  <server>`, or they quote a `needs login` status → **Login**.
- Add / edit / remove / list of an `mcp.json` entry → **Config edit**.
- Bare `/mcp-config` with no `authenticate` tool in your list →
  **Config edit**. If there were a pending login, the authenticate tool
  would be in your list.

## Login

Each MCP server that needs a login exposes one
`mcp__<server>__authenticate` tool. Call it for the server the user
means. If it is not in your tool list yet, load it first with
`select_tools`, or find it with `capability_search` scoped to that
server. Its own description owns the OAuth UX (printing the URL, blocking
on the callback, reconnecting on success). Surface its output verbatim,
including the authorization URL unchanged; the URL contains state and
PKCE parameters that break if edited.

If the user named a server that has no authenticate tool, say so in one
sentence and stop. Do **not** fall into config edit. They're trying to
log in to a server that isn't currently waiting for login; quietly
rewriting `mcp.json` would be the wrong fix. If multiple authenticate
tools exist and the user didn't name one, ask which.

## Config edit

Config lives in three files; on key collision, later entries in this
precedence order override earlier ones.

fx resolves the user-global directory as `FX_HOME` first, falling back
to `~/.fx`. Before touching the user-global file, resolve the actual
directory with the shell so you don't read or write the wrong one. Check
whether `FX_HOME` is set and fall back to `~/.fx` when it is empty:

```bash
echo "$FX_HOME"
echo "$HOME/.fx"
```

Use the first line when it is non-empty; otherwise use the second line.
In the rest of these instructions, `<FX_HOME>` means that resolved data
root. **Never assume `~/.fx`.**

- User-global: `<FX_HOME>/mcp.json`. Use for servers you want
  everywhere.
- Project-root: `<project root>/.mcp.json`, where project root is found
  by walking up from `<cwd>` to the nearest `.git`. Use for
  Claude-compatible, repo-shared, or cross-agent servers.
- Project-local: `<cwd>/.kimi-code/mcp.json`. Use for overrides in the
  current working directory.

Mention once that project-root and project-local stdio entries spawn
commands at session start, so they should only live in trusted repos,
and that fx holds a project server back until the user trusts the folder
or approves the server with `/mcp approve <name>`.

All three files wrap their entries the same way:

```json
{ "mcpServers": { "<name>": { /* entry */ } } }
```

An older user-global file may wrap its entries in `"mcp"` instead of
`"mcpServers"`. Keep whichever wrapper the file already uses.

A minimal stdio entry needs `command` (+ optional `args`, `env`, `cwd`).
For project-root `.mcp.json`, stdio entries run from the project root by
default; relative `cwd` values are resolved against the directory that
contains `.mcp.json`.
A minimal http entry needs `url`; add `bearerTokenEnvVar: "ENV_NAME"` for
servers that authenticate with a static bearer token from the
environment. Servers that use OAuth take no token field; the login flow
above handles them. `transport` is inferred from `command` vs `url`, so
omit it, except for a legacy SSE endpoint, which needs
`"transport": "sse"`. The less common fields are `enabled`,
`startupTimeoutMs`, `toolTimeoutMs`, `enabledTools`, `disabledTools`,
and `headers`.

When the user wants to change a timeout for *every* server, don't write
`startupTimeoutMs` / `toolTimeoutMs` into each entry. The global defaults
live in `<FX_HOME>/settings.json` (`"mcp": { "startup_timeout_ms": ...,
"tool_timeout_ms": ... }`) or the `KIMI_MCP_STARTUP_TIMEOUT_MS` /
`KIMI_MCP_TOOL_TIMEOUT_MS` env vars; per-server fields override them.
`MCP_TIMEOUT` (milliseconds) also sets the startup timeout when
`KIMI_MCP_STARTUP_TIMEOUT_MS` is unset.
`MCP_TIMEOUT` and `MCP_TOOL_TIMEOUT` are read the same way when the
`KIMI_` name is unset, and a server's `timeout` is read as its
`toolTimeoutMs`.
`MAX_MCP_OUTPUT_TOKENS` caps one MCP result at four bytes a token, and
`max_tool_result_bytes` in settings is the ceiling it cannot pass.
Every timeout must be an integer from `1` to `2147483647` milliseconds.

If the user only wants to **see** what's configured, read all three files,
show a merged view with enough source-path context to inspect or remove a
server from the file that actually declared it, and stop. No scope
prompt, no write.

For changes, the flow is:

1. **Pick a scope.** Infer it from the user's words when you can
   (global / everywhere / all projects → user-global; root / repo /
   shared / cross-agent / Claude / `.mcp.json` → project-root; cwd /
   current directory / `.kimi-code` → project-local). When the request is
   genuinely scope-less, use one `AskUserQuestion` to ask user-global vs
   project-root vs project-local, defaulting to user-global. Use plain
   text for every other question; `AskUserQuestion` is a poor fit for
   free-form input. If the user dismisses the scope question, stop; you
   can't safely guess where they wanted the change.
2. **Read and announce.** Read the target file (a missing or empty file
   is fine; you'll create `{ "mcpServers": {} }`). If JSON parsing fails,
   surface the error verbatim and stop. Silently overwriting a broken
   file could destroy work. Then show the user the target path, what's
   currently in it, and the entry you're about to write or delete. This
   is for transparency, not a confirmation gate. The edit permission
   prompt is the real gate, and your message is what gives the user
   context when that prompt appears. In auto and full-access modes there
   is no prompt, which is those modes' explicit contract.
3. **Write and tell them how to reload MCP servers.** Preserve unrelated
   entries and the wrapper. MCP servers load at session start, so tell
   the user to start a new session (for example `/new`) or restart `fx`
   for the change to take effect. A server removed from the config stays
   listed as `removed` in the open session, and calls to its tools fail
   with a removal notice.

## Less common entry forms

- `${VAR}` and `${VAR:-default}` expand in `command`, `args`, `env`,
  `url` and `headers` of a project server the user approved and of every
  user-global server. A variable that is unset and has no default skips
  that server with a note that names the variable.
- `headersHelper` on an http or sse entry is a shell command that prints
  one JSON object of header names and string values. fx runs it each
  time it loads its servers, gives it ten seconds, and tells it the
  server in `CLAUDE_CODE_MCP_SERVER_NAME` and
  `CLAUDE_CODE_MCP_SERVER_URL`. A failed or non-JSON answer holds the
  server back.
- A stdio server is told the project root in `CLAUDE_PROJECT_DIR`.
- `"type": "ws"` (WebSocket) is not supported; the entry is skipped with
  a note. `fx mcp add --transport` takes `http`, `sse` or `stdio`, and
  `--scope user` / `--scope project` are the same as `--global` /
  `--project`.
- `fx mcp add --scope local` keeps a server for the current project
  only: it is written to `<FX_HOME>/mcp.json` under
  `"projects": { "<project path>": { "mcpServers": { ... } } }`, never
  into the repository, and it wins over a server of the same name in
  the project or user-global file.

## Managed policy

An administrator can restrict MCP servers for every user of a machine
with two files in `/etc/fx` (`/Library/Application Support/fx` on macOS,
`C:\Program Files\fx` on Windows). Never write these files for the
user; say that they are the administrator's.

- `managed-mcp.json`, with the same `mcpServers` wrapper: when it
  exists, only its servers load. An empty `mcpServers` turns MCP off.
- `managed-settings.json`: `managedMcpServers` adds https `http` or
  `sse` servers above every other source (no `command`, `args`, `env`
  or `headersHelper`); `allowedMcpServers` and `deniedMcpServers` are
  lists of `{ "serverName": ... }`, `{ "serverCommand": [...] }` or
  `{ "serverUrl": "https://*.example.com/*" }`. No allowlist allows
  every server, an empty one allows none, and the denylist always wins.

A server the policy blocks is named in a note on `fx mcp list`.

## Secrets

Don't store secrets (tokens, keys, passwords) as literals in
`mcp.json`. It's a plain config file on disk. http servers should use
`bearerTokenEnvVar` to reference an env var instead; if a stdio entry
must inline one in `env`, warn the user before writing.
