const std = @import("std");
const support = @import("support.zig");
const store_mod = @import("../../core/tower/store.zig");
const store_git = @import("../../core/tower/store_git.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

pub const description = "Show the tower dashboard: missions (status/owner), the agent roster, and each unmerged mission's structured merge-gate state.";

const Args = struct {};

pub fn decode(ctx: support.DispatchContext, args_json: []const u8) support.DispatchError!support.DecodeResult {
    return support.decodeArguments(Args, ctx, args_json);
}

pub fn call(ctx: support.DispatchContext, _: support.ToolInput) support.DispatchError!support.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    const text = store_git.statusText(arena, &store) catch |err| {
        if (err == error.TowerRefused) return support.success(ctx, store.refusal);
        return support.fail(ctx, &store, err);
    };
    return support.success(ctx, text);
}

pub fn readsOnly(_: support.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: support.ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerStatus",
    .description = description,
    .model_schema = .{
        .name = "TowerStatus",
        .description = description,
        .input_schema = .{
            .properties = &.{},
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .read,
    .requires_approval = false,
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "TowerStatus accepts no arguments and rejects extra keys" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const empty = try decode(ctx, "");
    try std.testing.expect(empty == .input);
    defer empty.input.deinit(std.testing.allocator);
    try std.testing.expect(readsOnly(empty.input));
    try std.testing.expect(!isIrreversible(empty.input));
    const extra = try decode(ctx, "{\"verbose\":true}");
    try std.testing.expect(extra == .failure);
    std.testing.allocator.free(extra.failure);
}

test "TowerStatus returns the not-initialized refusal as dashboard text" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .success);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.success);
}
