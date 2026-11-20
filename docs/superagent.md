# Superagent

`superagent` is fx's native dispatch layer. It sits between the user and all managed
agents. It is not a subagent and not a replacement for a root fx session.

A managed agent is a persistent independent root fx agent in the same fx process. It has
its own `Agent`, worker, saved session, tools, permissions, and subagent host. It receives
each assignment as a normal user prompt through the same submission path a user uses,
and stays alive between assignments. The superagent talks to the user, decides what each
root should do, starts and stops those roots, and reports their state.

## Use it

Run fx in a directory beside the projects to orchestrate, then load the `superagent`
skill:

```sh
fx
/skill superagent
```

The native tool is `superagent`, with actions `list_projects`, `start`, `stop`, `status`,
`instruct`, and `journal`. `start` creates one persistent root agent once. `instruct`
sends a normal user prompt to that root's worker and takes an optional `queue` of later
prompts. `status` reads the worker's internal
state. `journal` opens the root's history in slices on request. `stop` shuts down that
root without killing an external process.

The CLI provides setup and debugging:

```sh
fx superagent projects
fx superagent status
```

No Claude Code, external MCP server, PTY, Unix socket, pane polling, or transcript
scraping is required for native fx peers.

## Why it is not `Agent`

`Agent` creates a subagent inside one fx conversation. It inherits narrowed authority,
shares the parent runtime, and returns a report into the parent's context. A superagent
peer is a root agent instance owned by the app, with its own conversation and subagent
tree. Prompts sent by a superagent arrive at that peer exactly as prompts typed by a user
do.

## Internal events

fx owns the peer's `Agent`, `WorkerRuntime`, session persistence, and lifecycle. Start,
busy/idle state, queued prompts, and stop come from internal worker and session state.
No process is launched per instruction.

## Blocked roots, restarts and models

- **A blocked root says so.** When a root's request ends on a usage or credit limit, or the
  root asks its owner a question, the superagent receives one event `root NAME is blocked and
  waits for its owner` with the question. A turn that failed or was interrupted without a
  reply also comes back as an event (`ended its turn on a failure`, `had its turn
  interrupted`). The state line of the event carries `blocked` or `failed`.
- **A limit ends the turn.** HTTP 402, a quota or usage-limit error code or message, and a
  rate limit whose `Retry-After` is over five minutes are not retried. In the TUI the root
  asks what to do; in `fx ask` the run ends with `"blocked":"limit"` in its JSON result and a
  `blocked:` line on stderr; hooks receive `AttentionRequired` with kind `limit`.
- **Roots survive a restart.** The superagent keeps one ledger per workspace under
  `~/.fx/superagent/`: each root's name, folder, session, last prompt and whether a turn was
  running, plus the host's pid and start stamp. At start fx reads it. When the recorded host
  is gone (the pid is dead, or the pid is alive but its start stamp differs), fx resumes the
  superagent's own session, brings every root back on its saved session, sends a cut turn's
  prompt again with a note that it was cut, and posts one restart event. A pid that exists is
  not taken as proof: the stamp must match. Leaving fx with `/exit` releases the ledger, so
  the next start resumes nothing.
- **A project keeps its model.** `/model` and the model picker save the model under
  `workspaces["<project>"].models` in `~/.fx/settings.json` as well as globally. A root starts
  and resumes with its project's model; `--model` and `FX_MODEL` still win.

## The superagent's view of a root

The superagent sees a root the way a hyperagent dispatcher sees its peers: by its final
response and its state, never by its working tokens.

- **A root comes back as one event.** The superagent's model receives one superagent event
  when a root stops, goes idle without a report, or needs its owner. The event carries the
  root's name, its state line (alive, session, prompt), the `REPORT:` lines of the turn ends
  fx carried by itself, and the final response. Tool calls, streamed text and reasoning are
  not included. The event is posted with the same path as a subagent report.
- **A root is gone as an event.** Stopping a root, or replacing it with a new start, posts
  one event that the root is gone. A root that dies without a stop posts no event today.
- **Status is state only.** `status` reports alive, busy, cwd, session and prompt id. It
  carries no output, so reading it never pushes peer output into the superagent's context.
- **The journal is opened on request.** `journal` returns the root's history in slices of
  `limit` bytes from `offset`, with the total length. It is read only when the owner asks,
  and it is never pushed into the superagent's context on its own.
- **Instruct passes the owner's words.** The superagent passes a root what the owner asked
  for, with the owner's standing rules verbatim. Every prompt ends with a
  `REPORT: finished|open|blocked` line.

## The loop runs in code

`src/core/superagent/runtime.zig` decides what happens at each root's turn end, and
`app_host.zig` carries the decision out. No skill or prompt text carries this behaviour.

| the turn ended with | fx does |
|---|---|
| a job the root left running (a background task, or a live `PID <n>` named in its report) | waits once, up to 30 minutes (`task.root_job_wait_s` in `~/.fx/settings.json`, in seconds, sets another time), then sends the job's result on the same session |
| a background task that finished after the model last looked | sends its result on the same session |
| `REPORT: finished` or no report, and a queued prompt | sends the next queued prompt on the same session |
| `REPORT: finished` and nothing queued | stops the root and posts the event; a later `instruct` resumes its saved session |
| no report and nothing queued | leaves the root idle and posts the event |
| `REPORT: open` | sends the next step, up to three times in a row, then hands the root to its owner |
| `REPORT: blocked` | sends one step that tells the root to decide a reversible blocker itself, then hands the root to its owner |
| a failure, an interrupt, a pause, a limit or a question | posts the event; the queue stays |

A root can also end without a turn end: its instance is closed with `/close`, or its worker
ends. fx sees that on its next pass, writes a `stop` line with `by: root`, posts
`root NAME died without a stop` with the reason, and acts:

| the root died with | fx does |
|---|---|
| a turn fx sent still running | starts it again on its saved session and sends that turn again, then the queue |
| a wait on a job | starts it again and tells it the job's result was not read |
| only queued prompts | starts it again and sends the next queued prompt |
| no work, or a second death before a turn ended | leaves it stopped; an `instruct` resumes its session |

A wait on a background task ends on the task's own notice. A wait on a named process id is one
`pidfd` poll with the timeout on its own thread. Neither sleeps in a loop.

The ledger `~/.fx/superagent/<workspace>.json` keeps each root's queue and its counts of sends
and turn ends, so a restart brings the queue back. Beside it, `<workspace>.journal.jsonl` gets
one line for every send, turn end, wait and stop:

```json
{"at_ms":1794434696329,"root":"loopproj","session":"nTdAv98Rds4P","event":"send","by":"runtime","decision":"","report":"","queued":0,"text":"LOOP-ITEM-TWO: do the second item"}
```

`by` is `owner` for a prompt the superagent's model sent, `runtime` for one fx sent,
`restart` for a cut turn fx sent again after a restart, and `root` for a turn end. The journal is cut to empty when it passes 1 MiB.

## The state machine, the checks and the isolation witness

Each root has one typed state in `src/core/superagent/machine.zig`: `idle`, `turn_open`,
`waiting_job`, `stopped` or `dead`. `step(state, event)` gives the next state or refuses the
event, and the host changes a root's state only through it. `admit` decides prompt admission
from the same facts: a free root is sent the prompt, a root with running work, a job wait or a
queue gets it queued, and a root that is not alive refuses it.

| event | from | to |
|---|---|---|
| `prompt_sent` | `idle`, `turn_open` | `turn_open` |
| `turn_ended` | `turn_open`, `idle` | `idle` (`waiting_job` stays) |
| `job_wait_began` | `idle` | `waiting_job` |
| `job_wait_settled` | `waiting_job` | `idle` |
| `stop_asked` | any | `stopped` |
| `died` | `idle`, `turn_open`, `waiting_job` | `dead` |

`src/core/superagent/host_checks.zig` holds the memory and process checks. A new root is
refused when `MemAvailable` in `/proc/meminfo` is under `task.root_min_free_mb` (512 by
default, 0 for no check). A process id named in a report is waited on only when it is alive
and is not fx itself. `status` ends with one host line: free memory, the floor, whether a new
root would be admitted, and the count of fx's own child processes.

The superagent starts no external process and has no launch template: every peer is a root
inside the fx process. It only waits on a process id a root names; it never signals one.
`tests/e2e/superagent-isolation.test.ts` is the witness. It starts a root, lets it run a
command, lists every descendant of the fx process and every path fx and its descendants hold
open, and fails if a path is under `/workspace/hyperagent` or a descendant is another
orchestrator's binary. `scripts/check-superagent-boundary.sh` fails the build if the
superagent code names a process spawn.

## Iteration-time housekeeping

The superagent measures each managed agent the way a dispatcher does: the share of time busy, turns that ended early with work open, the gap from a turn's end to the next prompt, and commands that repeat with their wall time. It fixes the largest measured waste in the cycle that finds it, and tells each agent to keep its own loop short. Each agent records the wall time of its builds and checks, proves a change with the narrowest check, reruns a failing row alone, runs the full set once before the push, never sleeps to wait, and names its longest step in its report.
