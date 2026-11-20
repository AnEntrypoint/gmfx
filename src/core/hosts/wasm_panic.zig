const std = @import("std");

pub const panic = std.debug.FullPanic(panicToStderr);

fn panicToStderr(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    std.debug.print("panic: {s}\n", .{msg});
    @trap();
}
