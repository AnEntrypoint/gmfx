# Native fx orchestration and browser `run_code` route

fx's instructivity, orchestration, MCP-like verbs, and browser automation are one native flow. There is no separate `gm` concept in fx: calls that used to be described as gm `run_code`, Playwriter verbs, or MCP orchestrator verbs are fx's single native code-run route. Legacy names may appear only in historical parity notes or external compatibility config; they do not describe a separate user-facing service.

## Single route

All practical code, tool, MCP-like, and browser CDP actions funnel through one native `run_code` boundary:

- `src/core/browser/orchestrator.zig` owns the native run snapshot, route kind, state, current tool/job/session, pending approval, browser/CDP target, and progress.
- `src/core/browser/execute.zig` frames and settles one native step.
- `src/core/browser/cdp.zig` owns the Birdman-compatible CDP envelope.
- `src/core/browser/session.zig` owns run/step ordering.
- `src/ui/render.zig` renders the snapshot as one optional compact BLUF statusline segment.

The native route launches no gm, Playwriter, Node, or external MCP process. Direct CLI tools remain ergonomic wrappers over the same normal-computer model; the agent sees one route to code runs, not separate orchestrator verbs.

## Dynamic BLUF

The TUI shows one quiet line when a native run is active:

```text
fx run <id> · <route> · <state> · <current tool/job> · step <n> <done>/<total> · approval
```

State markers:

- `queued`, `running`, `needs approval`, `browser`, `done`, `failed`
- routes: `tool`, `mcp`, `browser`, `shell`, `file`, `code`
- ` · approval` appears only when an approval is pending

The BLUF is empty when no native run exists. Details stay collapsed by default; the footer keeps this as one statusline item rather than writing live updates into the transcript. Existing full-transcript/session views remain the expanded detail path.


## gm / Playwriter launcher mismatch

The active gm config in this environment used:

```json
{"command": "node", "args": ["${HOME}/.gmnew/current/pw/bin/playwriter-project"]}
```

With `HOME=/config`, Node resolves that argument as a module path under `/config/.gmnew/current/pw/bin/playwriter-project`, which does not exist. That is the exact `MODULE_NOT_FOUND` cause behind `gm.playwriter_execute` failing to start the `playwriter` MCP server. The working checkout is `/workspace/pw`, and `/workspace/pw/docs/CONSUMERS.md` documents the direct entry:

```json
{"command": "node", "args": ["/workspace/pw/bin/playwriter-project"]}
```

That config belongs to gm under `/config`, outside this repository, so fx does not edit it. A gm consumer must replace the stale `${HOME}` path with the absolute checkout path, or use the pinned install path that actually exists. fx itself does not depend on this launcher.

## Native fx boundary

The native Zig boundary lives under `src/core/browser/`:

- `cdp.zig` owns typed CDP request envelopes: `id`, `method`, `params`, and optional `sessionId`. It can encode the exact JSON shape Birdman expects and parse responses by id.
- `session.zig` owns a native run/step ledger: a session has ordered steps with a target, method, and lifecycle state. This is the orchestration boundary equivalent to enough of gm to drive browser work without a separate gm process.
- `execute.zig` owns the `execute`-like vertical slice: it combines a CDP request, a session step, and a deterministic result projection. It performs no process launch and has no Node dependency.

A live host, such as thebird's in-page bridge, supplies the transport. fx does not spawn that transport. The host sends CDP JSON to Birdman and returns the matching response; fx owns request ids, session ids, and step bookkeeping.

## Birdman / thebird contract

`/workspace/birdman/client/birdman.js` exposes `connect()`, `targets()`, `open()`, `attach()`, `send(method, params, sessionId)`, and `transport()`. Browser-level methods use `Target.*`; session-level methods include `sessionId`.

`/workspace/thebird/web/playwriter-in-page.js` already implements the browser-side half of this contract:

- `rpc(method, params, sessionId)` sends `{ id, method, params, sessionId }` through `birdman.transport().send(JSON.stringify(...))`.
- `createPage` calls `Target.createTarget`, then `Target.getTargets`.
- page operations call `Target.attachToTarget` with `flatten: true`, then send `Runtime.evaluate` or another CDP method with the returned `sessionId`.
- `targets` calls `Target.getTargets`.
- `closePage` calls `Target.closeTarget`.

The native fx client sends the same JSON envelope. A thebird host should expose one native operation to fx, for example `fx.browser.execute`, that takes the same shape as a Playwriter `execute` call and maps its bridge calls to Birdman through this transport. No `gm.playwriter_execute` call and no `/workspace/pw` process are needed. If the extension is not granted on the orchestrator tab, `connect()` fails with `The Birdman extension did not answer. Click its toolbar button on this tab.`; fx reports that as a browser-unavailable state.

## Agent-facing mental model

The agent sees normal computer actions: open a page, evaluate or click in a tab, list tabs, close a page, and inspect the result. It does not see gm run ids, MCP server names, sandbox paths, or Node launcher details. Hosts may implement the transport in a page, extension bridge, or local CDP socket; the typed boundary stays the same.

## Current vertical slice and limits

The native slice is deterministic and process-free: it proves request framing, id matching, session bookkeeping, sequencing, status projection, and error handling in Zig tests through an injected fake transport. The `attach` action frames `Target.attachToTarget` with `flatten: true`, and `cdp.resultStringAlloc` reads the returned `sessionId` for later page steps. It does not yet open a real browser socket from the CLI. A live hookup is a transport adapter that consumes and returns the JSON envelopes defined here; no external process is required. The full Playwright API and arbitrary JavaScript sandboxing are intentionally out of scope for this slice.

## Transport seam and sequences

`execute.Transport` is the injected seam: a context pointer and a `send_fn(context, alloc, request_json)` that returns the raw reply bytes. `execute.runStep` frames the request, sends it, decodes the reply by id, and settles the step. A transport error marks the step failed and propagates. `Orchestrator.runSequence` runs ordered commands under one run id and stops at the first CDP error reply. It writes the replies into a caller-owned slice and returns how many it wrote. The tests use `fake_transport.zig` and need no browser.

## Browser status

`Orchestrator.browserStatus()` returns a read-only `BrowserStatus{ state, tab_count }`, exported from `browser.zig` as `BrowserStatus` and `BrowserState`.

- `state` is `none` before any successful reply, `busy` while a step is in flight, and `idle` otherwise.
- `tab_count` is the page count from `Target.getTargets`. It goes up by one after a successful `Target.createTarget` and down by one after a successful `Target.closeTarget`.

The TUI status writer reads this value. It never mutates the orchestrator.

