const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");

const strict_env = "FX_TEST_INPUT_LOOP_NETWORK_GUARD";

threadlocal var on_input_loop: bool = false;

pub fn enter() void {
    on_input_loop = true;
}

pub fn leave() void {
    on_input_loop = false;
}

pub fn noteNetworkRequest(kind: []const u8) void {
    if (!on_input_loop) return;
    debug_trace.logf("network", "request on input loop kind={s}", .{kind});
    if (strict()) std.debug.panic("network request on the input loop: {s}", .{kind});
}

fn strict() bool {
    const value = io_mod.getenv(strict_env) orelse return false;
    return std.mem.eql(u8, value, "1");
}

test "input loop guard marks only the thread that entered" {
    try std.testing.expect(!on_input_loop);
    enter();
    defer leave();
    try std.testing.expect(on_input_loop);

    const Probe = struct {
        fn run(seen: *bool) void {
            seen.* = on_input_loop;
        }
    };
    var worker_seen = true;
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&worker_seen});
    thread.join();
    try std.testing.expect(!worker_seen);
}

test "input loop guard passes requests made off the input loop" {
    try std.testing.expect(!on_input_loop);
    noteNetworkRequest("test");
}
