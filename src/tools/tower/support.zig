const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tower_store = @import("../../core/tower/store.zig");
const tower_mode = @import("../../core/tower/mode.zig");

pub const Allocator = std.mem.Allocator;
pub const DispatchContext = tool_dispatch.DispatchContext;
pub const DecodeResult = tool_dispatch.DecodeResult;
pub const DispatchError = tool_dispatch.DispatchError;
pub const ToolInput = tool_dispatch.ToolInput;
pub const ToolResult = tool_dispatch.ToolResult;
pub const Store = tower_store.Store;

pub fn Box(comptime T: type) type {
    return struct {
        parsed: std.json.Parsed(T),

        const Self = @This();

        pub fn wrap(alloc: Allocator, parsed: std.json.Parsed(T)) Allocator.Error!ToolInput {
            const slot = try alloc.create(Self);
            slot.* = .{ .parsed = parsed };
            return .{ .ptr = slot, .deinit_fn = deinit };
        }

        fn deinit(ptr: *anyopaque, alloc: Allocator) void {
            const slot: *Self = @ptrCast(@alignCast(ptr));
            slot.parsed.deinit();
            alloc.destroy(slot);
        }
    };
}

pub fn decodeArguments(comptime T: type, ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const source = if (args_json.len == 0) "{}" else args_json;
    const parsed = std.json.parseFromSlice(T, ctx.allocator, source, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments do not match the tool schema") };
    };
    return .{ .input = try Box(T).wrap(ctx.allocator, parsed) };
}

pub fn valueOf(comptime T: type, input: ToolInput) *const T {
    return &input.as(Box(T)).parsed.value;
}

pub fn nowMs() i64 {
    return io_mod.milliTimestamp();
}

pub fn storeFor(ctx: DispatchContext) Store {
    return .{ .root = ctx.workspace_root };
}

pub fn success(ctx: DispatchContext, text: []const u8) DispatchError!ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, text) };
}

pub fn failure(ctx: DispatchContext, text: []const u8) DispatchError!ToolResult {
    return .{ .failure = try ctx.allocator.dupe(u8, text) };
}

pub fn refused(ctx: DispatchContext, message: []const u8) DispatchError!ToolResult {
    return failure(ctx, message);
}

pub fn modeInactive(ctx: DispatchContext) DispatchError!?ToolResult {
    if (tower_mode.isActive()) return null;
    return try failure(ctx, tower_mode.not_active_message);
}

pub fn fail(ctx: DispatchContext, store: *const Store, err: anyerror) DispatchError!ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.TowerRefused) return failure(ctx, store.refusal);
    return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "tower operation failed: {s}", .{@errorName(err)}) };
}
