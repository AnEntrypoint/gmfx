#!/bin/sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
anchor() {
    sed -n "$2p" "$R/$1" | grep -qF "$3" || { echo "ANCHOR_MISSING $1:$2 $3"; exit 1; }
}
anchor src/core/cli/cli_ask.zig 2356 'fn goalExitCode(status: goal_state.Status) u8 {'
anchor src/core/cli/cli_ask.zig 2301 'result.exit_code = goalExitCode(snapshot.status);'
anchor src/core/cli/cli_ask.zig 2371 'result.exit_code = goalExitCode(.paused);'
anchor src/core/slash_commands/command_router.zig 218 '.tower => .{ .tower = towerAction(payload) },'
anchor src/core/slash_commands/command_router.zig 318 '.tower => |action| if (handlers.handle_tower) |handle|'
anchor src/builtins/commands.zig 847 '.kind = .tower, .command = "/tower"'
grep -qF 'Queue rank 138 (Parity 11 row 11, goal exit codes): held' "$R/docs/PENDING_VALIDATION.md" || { echo LEDGER_138_MISSING; exit 1; }
echo CHECK_RANK138_HELD_OK
