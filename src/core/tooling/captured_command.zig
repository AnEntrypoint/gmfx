const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn isToolCall(
    alloc: Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) Allocator.Error!bool {
    if (std.mem.eql(u8, tool_name, "run_command")) return true;
    const legacy_terminal = std.mem.eql(u8, tool_name, "terminal");
    const shell = std.mem.eql(u8, tool_name, "Bash");
    if (!legacy_terminal and !shell) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    const action: []const u8 = if (object.get("action")) |value| blk: {
        if (value != .string) return false;
        break :blk value.string;
    } else blk: {
        if (legacy_terminal) return false;
        const command = object.get("command") orelse return false;
        if (command != .string) return false;
        break :blk "run";
    };
    if (legacy_terminal) return std.mem.eql(u8, action, "exec");
    if (!std.mem.eql(u8, action, "run")) return false;
    const tty = object.get("tty") orelse return true;
    return tty == .null or (tty == .bool and !tty.bool);
}

test "captured command classification recognizes shell run and historical records" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try isToolCall(
        alloc,
        "terminal",
        "{\"action\":\"exec\",\"command\":\"printf ok\"}",
    ));
    try std.testing.expect(!try isToolCall(
        alloc,
        "terminal",
        "{\"action\":\"start\",\"command\":\"printf ok\"}",
    ));
    try std.testing.expect(try isToolCall(
        alloc,
        "Bash",
        "{\"command\":\"printf ok\"}",
    ));
    try std.testing.expect(!try isToolCall(
        alloc,
        "Bash",
        "{\"command\":\"printf ok\",\"tty\":true}",
    ));
    try std.testing.expect(!try isToolCall(
        alloc,
        "Bash",
        "{\"action\":\"wait\",\"session_id\":\"shell-1\"}",
    ));
    try std.testing.expect(try isToolCall(alloc, "run_command", "{}"));
    try std.testing.expect(!try isToolCall(alloc, "read_file", "{}"));
    try std.testing.expect(!try isToolCall(alloc, "terminal", "not-json"));
    try std.testing.expect(!try isToolCall(alloc, "Bash", "not-json"));
}
