const std = @import("std");
const support = @import("support.zig");
const tower_mode = @import("../../core/tower/mode.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

pub const description = "Initialize a tower multi-agent workspace in the current repository.";
const base_empty_message = "TowerInit base must be a non-empty branch name.";

const Args = struct {
    base: ?[]const u8 = null,
};

pub fn decode(ctx: support.DispatchContext, args_json: []const u8) support.DispatchError!support.DecodeResult {
    const decoded = try support.decodeArguments(Args, ctx, args_json);
    switch (decoded) {
        .failure => return decoded,
        .input => |input| {
            const args = support.valueOf(Args, input);
            if (args.base) |base| {
                if (base.len == 0) {
                    input.deinit(ctx.allocator);
                    return .{ .failure = try ctx.allocator.dupe(u8, base_empty_message) };
                }
            }
            return decoded;
        },
    }
}

pub fn call(ctx: support.DispatchContext, erased: support.ToolInput) support.DispatchError!support.ToolResult {
    if (try support.modeInactive(ctx)) |refusal| return refusal;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    const args = support.valueOf(Args, erased);
    const result = store.init(arena, args.base orelse tower_mode.pinnedBase(), support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    const text = if (result.created)
        try std.fmt.allocPrint(arena, "tower workspace initialized on base {s}", .{result.base})
    else
        try std.fmt.allocPrint(arena, "tower workspace already initialized — existing state preserved (base {s})", .{result.base});
    return support.success(ctx, text);
}

pub fn readsOnly(_: support.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: support.ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerInit",
    .description = description,
    .model_schema = .{
        .name = "TowerInit",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "base", .json_type = .string, .description = "Local base branch to build on. Defaults to the current branch.", .bounds = &.{ .min_length = 1 } },
            },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "TowerInit refuses unknown keys and an empty base" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const unknown = try decode(ctx, "{\"unknown\":true}");
    try std.testing.expect(unknown == .failure);
    try std.testing.expectEqualStrings("arguments do not match the tool schema", unknown.failure);
    std.testing.allocator.free(unknown.failure);
    const empty = try decode(ctx, "{\"base\":\"\"}");
    try std.testing.expect(empty == .failure);
    try std.testing.expectEqualStrings(base_empty_message, empty.failure);
    std.testing.allocator.free(empty.failure);
}

test "TowerInit is refused while tower mode is inactive" {
    tower_mode.exit();
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(tower_mode.not_active_message, result.failure);
}
