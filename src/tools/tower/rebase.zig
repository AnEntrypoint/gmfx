const std = @import("std");
const support = @import("support.zig");
const store_mod = @import("../../core/tower/store.zig");
const store_git = @import("../../core/tower/store_git.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;

pub const description = "Rebase a mission branch onto the current base branch, inside the mission's own worktree.";

const Args = struct {
    mission: []const u8,
};

pub fn decode(ctx: support.DispatchContext, args_json: []const u8) support.DispatchError!support.DecodeResult {
    return support.decodeArguments(Args, ctx, args_json);
}

pub fn call(ctx: support.DispatchContext, erased: support.ToolInput) support.DispatchError!support.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    const args = support.valueOf(Args, erased);
    const outcome = store_git.rebaseMission(arena, &store, args.mission, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try outcomeText(arena, args.mission, outcome));
}

fn outcomeText(arena: Allocator, mission: []const u8, outcome: store_git.RebaseOutcome) ![]u8 {
    return switch (outcome) {
        .up_to_date => |sha| std.fmt.allocPrint(arena, "mission {s} already up to date with base at {s}", .{ mission, sha }),
        .rebased => |moved| std.fmt.allocPrint(arena, "rebased mission {s}: {s} -> {s}", .{ mission, moved.from, moved.to }),
    };
}

pub fn readsOnly(_: support.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: support.ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerRebase",
    .description = description,
    .model_schema = .{
        .name = "TowerRebase",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "mission", .json_type = .string, .description = "Mission id to rebase, for example M1." },
            },
            .required = &.{"mission"},
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

test "TowerRebase refuses unknown keys and a missing mission" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const missing = try decode(ctx, "{}");
    try std.testing.expect(missing == .failure);
    std.testing.allocator.free(missing.failure);
    const extra = try decode(ctx, "{\"mission\":\"M1\",\"extra\":2}");
    try std.testing.expect(extra == .failure);
    std.testing.allocator.free(extra.failure);
}

test "TowerRebase renders up-to-date and rebased outcomes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const current = try outcomeText(arena, "M1", .{ .up_to_date = "9f8e7d" });
    try std.testing.expectEqualStrings("mission M1 already up to date with base at 9f8e7d", current);
    const moved = try outcomeText(arena, "M1", .{ .rebased = .{ .from = "a1b2c3", .to = "d4e5f6" } });
    try std.testing.expectEqualStrings("rebased mission M1: a1b2c3 -> d4e5f6", moved);
}

test "TowerRebase reports a nonexistent workspace as not initialized" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"mission\":\"M1\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.failure);
}
