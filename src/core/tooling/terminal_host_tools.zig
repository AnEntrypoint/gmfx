const std = @import("std");
const host_tool_runtime = @import("host_tool_runtime.zig");
const tool_dispatch = @import("tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub var active: host_tool_runtime.Runtime = .{};

const JoinedRegistry = struct {
    base: []const tool_dispatch.Tool,
    tools: []tool_dispatch.Tool,
};

var joined_registries: std.ArrayList(JoinedRegistry) = .empty;

pub fn replaceActive(next: host_tool_runtime.Runtime) void {
    forgetJoinedRegistries();
    active.deinit();
    active = next;
}

fn forgetJoinedRegistries() void {
    for (joined_registries.items) |joined| std.heap.c_allocator.free(joined.tools);
    joined_registries.clearAndFree(std.heap.c_allocator);
}

pub fn registryWithActive(base: tool_dispatch.Registry) tool_dispatch.Registry {
    if (active.tools.len == 0) return base;
    for (joined_registries.items) |joined| {
        if (joined.base.ptr == base.tools.ptr and joined.base.len == base.tools.len) return .{ .tools = joined.tools };
    }
    const alloc = std.heap.c_allocator;
    const tools = alloc.alloc(tool_dispatch.Tool, base.tools.len + active.tools.len) catch return base;
    @memcpy(tools[0..base.tools.len], base.tools);
    @memcpy(tools[base.tools.len..], active.tools);
    joined_registries.append(alloc, .{ .base = base.tools, .tools = tools }) catch {
        alloc.free(tools);
        return base;
    };
    return .{ .tools = tools };
}

test "the registry seen by tool admission holds the host's tools after the built-in ones, and only while the host has some" {
    const alloc = std.testing.allocator;
    var built_in = try parseInitialize(alloc,
        \\{"tools":[{"name":"read_file","description":"Read","inputSchema":{"type":"object"}}]}
    );
    defer built_in.deinit();
    const base: tool_dispatch.Registry = .{ .tools = built_in.tools };

    try std.testing.expectEqual(base.tools.ptr, registryWithActive(base).tools.ptr);

    replaceActive(try parseInitialize(alloc,
        \\{"tools":[{"name":"bash","description":"Run","inputSchema":{"type":"object"},"writes":true}]}
    ));
    defer replaceActive(.{});
    const joined = registryWithActive(base);
    try std.testing.expectEqual(@as(usize, 2), joined.tools.len);
    try std.testing.expectEqualStrings("read_file", joined.tools[0].name);
    const host_bash = joined.lookup("bash").?;
    try std.testing.expect(host_bash.requires_approval);
    try std.testing.expect(host_bash.executor_kind == .host);
    try std.testing.expectEqual(joined.tools.ptr, registryWithActive(base).tools.ptr);

    replaceActive(.{});
    try std.testing.expectEqual(base.tools.ptr, registryWithActive(base).tools.ptr);
}

pub const ParseError = host_tool_runtime.ParseError || error{InvalidTerminalInitialize};

pub fn parseInitialize(backing: Allocator, bytes: []const u8) ParseError!host_tool_runtime.Runtime {
    var parsed = std.json.parseFromSlice(std.json.Value, backing, bytes, .{}) catch return error.InvalidTerminalInitialize;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTerminalInitialize;
    const tools = parsed.value.object.get("tools") orelse return .{};
    return host_tool_runtime.Runtime.init(backing, tools);
}

test "core.terminal_host_tools reads the tool names and input schemas from the initialize input" {
    const alloc = std.testing.allocator;
    var runtime = try parseInitialize(alloc,
        \\{"tools":[{"name":"lookup","description":"Find a record","inputSchema":{"type":"object","properties":{"id":{"type":"string"}}}}]}
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), runtime.tools.len);
    try std.testing.expectEqualStrings("lookup", runtime.order[0]);
    try std.testing.expectEqualStrings("lookup", runtime.dynamic_tools[0].name);
    try std.testing.expectEqualStrings("Find a record", runtime.dynamic_tools[0].description);
    const properties = runtime.dynamic_tools[0].input_schema.object.get("properties").?;
    try std.testing.expect(properties.object.get("id") != null);
}

test "core.terminal_host_tools accepts an initialize input without tools as an empty set" {
    const alloc = std.testing.allocator;
    var runtime = try parseInitialize(alloc, "{}");
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime.tools.len);
}

test "core.terminal_host_tools rejects malformed initialize input" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidTerminalInitialize, parseInitialize(alloc, "not json"));
    try std.testing.expectError(error.InvalidTerminalInitialize, parseInitialize(alloc, "[]"));
    try std.testing.expectError(error.InvalidHostToolName, parseInitialize(alloc,
        \\{"tools":[{"name":"bad name","description":"x","inputSchema":{"type":"object"}}]}
    ));
}
