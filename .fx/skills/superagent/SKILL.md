---
name: superagent
description: "Use when the user wants one fx session to coordinate several persistent independent root fx agents. This is the layer between the user and all agents, not a subagent."
---

# Superagent tool

Call `superagent` with one action at a time. A managed agent is a root inside this fx
process, not a subagent; do not use `Agent` for peer work.

| action | arguments | result |
|---|---|---|
| `list_projects` | none | the project folders beside the workspace |
| `start` | `agent` (the folder name), optional `cwd`, optional `session` to resume | one persistent root for that folder |
| `instruct` | `agent`, `prompt`, optional `queue` of later prompts in order | the prompt is sent, or queued behind running work; a missing root is started first |
| `status` | none | each root's state, then one host line |
| `stop` | `agent` | the root is shut down |
| `journal` | `agent`, `offset`, `limit` in bytes | a slice of the root's history; only when the owner asks |

End every prompt with `REPORT: finished|open|blocked — <one line> — witness: <totals>`.
One event arrives when a root stops, goes idle without a report, dies, or needs its owner.
Do not instruct a root again while its queue runs. `docs/superagent.md` describes what fx
does between a send and that event.
