const std = @import("std");

const sandbox_reason = "fx has no dangerouslyDisableSandbox switch; a sandbox bypass would skip the permission system that every sensitive tool must pass through (AGENTS.md Permissions)";
const hooks_reason = "no file under src/ reads hooks.json, so this entry has no implementation in the binary";

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    return std.fmt.allocPrint(alloc, "{{\"item\":9,\"kind\":\"sandbox-hooks\",\"offline\":true,\"status\":\"open\",\"ok\":false,\"sandbox_bypass\":false,\"entries\":[{{\"name\":\"dangerouslyDisableSandbox\",\"status\":\"open\",\"reason\":\"{s}\"}},{{\"name\":\"hooks.json\",\"status\":\"open\",\"reason\":\"{s}\"}}]}}", .{ sandbox_reason, hooks_reason });
}
