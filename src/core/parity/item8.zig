const std = @import("std");

const cron_reason = "CronCreate, CronList and CronDelete are native tools in src/tools/cron/, registered in src/builtins/tools.zig and scheduled by src/core/cron/runtime.zig";
const wakeup_reason = "no ScheduleWakeup tool exists in src/; a delayed one-shot run is a CronCreate entry, and a bounded wait inside a turn is WaitFor";
const background_reason = "Bash takes run_in_background in src/builtins/tools.zig; the task is read with TaskOutput, listed with TaskList, waited on with WaitFor and stopped with TaskStop";
const ultracode_reason = "no ultracode workflow runner exists in src/, so the Workflow script runner is not part of the binary";

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    return std.fmt.allocPrint(alloc, "{{\"item\":8,\"kind\":\"scheduling-background\",\"offline\":true,\"status\":\"open\",\"ok\":false,\"entries\":[{{\"name\":\"CronCreate\",\"status\":\"present\",\"reason\":\"{s}\"}},{{\"name\":\"CronDelete\",\"status\":\"present\",\"reason\":\"{s}\"}},{{\"name\":\"CronList\",\"status\":\"present\",\"reason\":\"{s}\"}},{{\"name\":\"ScheduleWakeup\",\"status\":\"open\",\"reason\":\"{s}\"}},{{\"name\":\"run_in_background\",\"status\":\"present\",\"reason\":\"{s}\"}},{{\"name\":\"ultracode\",\"status\":\"open\",\"reason\":\"{s}\"}}]}}", .{ cron_reason, cron_reason, cron_reason, wakeup_reason, background_reason, ultracode_reason });
}
