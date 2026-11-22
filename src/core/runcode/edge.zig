const std = @import("std");
const runcode = @import("runcode.zig");

const prelude_source = @embedFile("edge_prelude.js");

extern fn fx_edge_run(argc: c_int, argv: [*]?[*:0]u8, prelude: [*:0]const u8, script: [*:0]const u8) c_int;

var current: ?runcode.Verbs = null;

export fn fx_edge_host_call(name: [*:0]const u8, args: [*:0]const u8) ?[*:0]u8 {
    const verbs = current orelse return null;
    const alloc = std.heap.c_allocator;
    const reply = verbs.invoke(verbs.context, alloc, std.mem.span(name), std.mem.span(args)) catch return null;
    defer alloc.free(reply);
    return (alloc.dupeZ(u8, reply) catch return null).ptr;
}

export fn fx_edge_host_free(reply: ?[*:0]u8) void {
    if (reply) |owned| std.heap.c_allocator.free(std.mem.span(owned));
}

pub fn prelude(alloc: std.mem.Allocator, deny_node_io: bool) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "const fxDenyNodeIo = {};\n{s}", .{ deny_node_io, prelude_source }, 0);
}

pub fn runCommand(alloc: std.mem.Allocator, args: []const []const u8, verbs: runcode.Verbs, deny_node_io: bool) !u8 {
    const cli = try runcode.parseCliArgs(args);
    const script = try alloc.dupeZ(u8, cli.file);
    defer alloc.free(script);
    const source = try prelude(alloc, deny_node_io);
    defer alloc.free(source);
    var name = "fx".*;
    var argv = [_]?[*:0]u8{ &name, null };
    current = verbs;
    defer current = null;
    return @intCast(fx_edge_run(1, &argv, source, script) & 0xff);
}

test "the edge prelude refuses Node I/O modules only when asked to" {
    const denied = try prelude(std.testing.allocator, true);
    defer std.testing.allocator.free(denied);
    try std.testing.expect(std.mem.startsWith(u8, denied, "const fxDenyNodeIo = true;\n"));
    const open = try prelude(std.testing.allocator, false);
    defer std.testing.allocator.free(open);
    try std.testing.expect(std.mem.startsWith(u8, open, "const fxDenyNodeIo = false;\n"));
}
