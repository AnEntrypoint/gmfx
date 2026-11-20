#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/superagent"

reaching_in="$({
  git grep --untracked -n -E '@import\("([^"]*/)?(core|\.\.)/superagent/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v -E 'superagent/(runtime|command)\.zig"\)' | grep -v -E '^src/main\.zig:.*superagent/app_host\.zig"\)' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Orchestration is reached through %s/runtime.zig. Outside the folder only runtime.zig and command.zig may be imported, and only src/main.zig binds app_host.zig:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

external_orchestrators="$(git grep --untracked -n -i -E 'gm-core|\.gmnew|gm\.mjs|/workspace/gm\b|hyperagent|airc( |-)(send|spawn|peer)' -- src ":(exclude)src/core/parity" || true)"
if [[ -n "$external_orchestrators" ]]; then
  printf 'fx runs its own orchestration. No gm or hyperagent binary, path or call may appear under src:\n%s\n' "$external_orchestrators" >&2
  exit 1
fi

spawned_orchestrators="$(git grep --untracked -n -E '"(gm|hyperagent|airc)"' -- src/core/execution src/core/superagent src/tools/superagent src/core/tower || true)"
if [[ -n "$spawned_orchestrators" ]]; then
  printf 'No orchestrator executable may be named in the execution, superagent or tower code:\n%s\n' "$spawned_orchestrators" >&2
  exit 1
fi

spawned_processes="$(git grep --untracked -n -E 'std\.process\.(Child|spawn|run|execv)|process\.Child|\.spawnChild\(|fork\(\)|execve\(|posix_spawn|openpty|forkpty' -- "$folder" src/tools/superagent || true)"
if [[ -n "$spawned_processes" ]]; then
  printf 'The superagent starts no process, pane or PTY. Its peers are roots inside the fx process:\n%s\n' "$spawned_processes" >&2
  exit 1
fi

signalled_processes="$(git grep --untracked -n -E '(posix|linux|std\.c)\.kill\(|killProcessTree|terminateTree' -- "$folder" src/tools/superagent || true)"
if [[ -n "$signalled_processes" ]]; then
  printf 'The superagent signals no process. It waits on a process id a root names and nothing more:\n%s\n' "$signalled_processes" >&2
  exit 1
fi

other_trees="$(git grep --untracked -n -E '\.orch\b|/workspace/[a-z]' -- "$folder" src/tools/superagent || true)"
if [[ -n "$other_trees" ]]; then
  printf 'The superagent names no path of another project or orchestrator:\n%s\n' "$other_trees" >&2
  exit 1
fi

loop_in_skill="$(git grep --untracked -n -i -E 'waits once|next queued|sends the next step|carries each root' -- .fx/skills/superagent || true)"
if [[ -n "$loop_in_skill" ]]; then
  printf 'The superagent skill says how to call the tool. The loop is code and is described in docs/superagent.md:\n%s\n' "$loop_in_skill" >&2
  exit 1
fi
