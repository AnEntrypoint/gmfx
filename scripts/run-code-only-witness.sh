#!/bin/sh
set -u
fx_bin=${1:?usage: run-code-only-witness.sh <fx-binary> [repo]}
repo=${2:-$(cd "$(dirname "$0")/.." && pwd)}
case $fx_bin in /*) ;; *) fx_bin=$(pwd)/$fx_bin ;; esac
tmux_root=$(mktemp -d)
trap 'rm -rf "$tmux_root"' EXIT
fails=0
index=0
for file in acp.test.ts ask-presentation.test.ts configured-providers.test.ts file-tool-paths.test.ts gateway-stream-lifecycle.test.ts mcp-auth.test.ts mcp-stdio.test.ts sessions.test.ts subagent-hooks.test.ts superagent-view.test.ts tui-command-permissions.test.ts tui-gateway-stream-lifecycle.test.ts tui-host-instances.test.ts ultrafast-fake-gateway.test.ts vision-route-fake-gateway.test.ts web-fetch-fake-network.test.ts web-search-fake-gateway.test.ts; do
    index=$((index + 1))
    mkdir -p "$tmux_root/$index"
    if (cd "$repo/tests/e2e" && FX_E2E_BIN=$fx_bin TMUX_TMPDIR=$tmux_root/$index bun test --max-concurrency 1 "./$file"); then
        printf 'PASS %s\n' "$file"
    else
        printf 'FAIL %s\n' "$file"
        fails=$((fails + 1))
    fi
done
printf 'RUN_CODE_ONLY_DONE %s\n' "$fails"
[ "$fails" -eq 0 ]
