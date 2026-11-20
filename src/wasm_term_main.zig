const build_options = @import("build_options");
const fx = @import("main.zig");
const std = @import("std");
const terminal_host_tools = @import("core/tooling/terminal_host_tools.zig");
const host_tool_runtime = @import("core/tooling/host_tool_runtime.zig");

comptime {
    if (build_options.wasm_surface != .term) {
        @compileError("fx-term requires -Dwasm-surface=term");
    }
}

pub const panic = @import("core/hosts/wasm_panic.zig").panic;

pub fn main(init: std.process.Init) !void {
    try fx.runWasmTerminal(init);
}

export fn fx_terminal_alloc(len: usize) ?[*]u8 {
    const buffer = std.heap.c_allocator.alloc(u8, len) catch return null;
    return buffer.ptr;
}

export fn fx_terminal_free(ptr: [*]u8, len: usize) void {
    std.heap.c_allocator.free(ptr[0..len]);
}

export fn fx_terminal_initialize(bytes_ptr: [*]const u8, bytes_len: usize) i32 {
    const next = terminal_host_tools.parseInitialize(std.heap.c_allocator, bytes_ptr[0..bytes_len]) catch return -1;
    terminal_host_tools.replaceActive(next);
    return @intCast(terminal_host_tools.active.tools.len);
}
