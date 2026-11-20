const std = @import("std");
const support = @import("support.zig");
const store_mod = @import("../../core/tower/store.zig");
const store_git = @import("../../core/tower/store_git.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;

pub const description = "Merge a tower mission branch into the base branch (--no-ff).";

const Args = struct {
    branch: []const u8,
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
    const outcome = store_git.mergeBranch(arena, &store, args.branch, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try outcomeText(arena, args.branch, outcome));
}

fn outcomeText(arena: Allocator, branch: []const u8, outcome: store_git.MergeOutcome) ![]u8 {
    return switch (outcome) {
        .merged => |head| std.fmt.allocPrint(arena, "merged {s} at {s}", .{ branch, head }),
        .noop => |id| std.fmt.allocPrint(arena, "survey {s} closed with no changes", .{id}),
    };
}

pub fn readsOnly(_: support.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: support.ToolInput) bool {
    return true;
}

pub const spec = ToolSpec{
    .name = "TowerMerge",
    .description = description,
    .model_schema = .{
        .name = "TowerMerge",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "branch", .json_type = .string, .description = "Mission branch to merge, for example feat/parser." },
            },
            .required = &.{"branch"},
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

test "TowerMerge refuses unknown keys and a missing branch" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const missing = try decode(ctx, "{}");
    try std.testing.expect(missing == .failure);
    std.testing.allocator.free(missing.failure);
    const extra = try decode(ctx, "{\"branch\":\"feat/parser\",\"extra\":1}");
    try std.testing.expect(extra == .failure);
    std.testing.allocator.free(extra.failure);
}

test "TowerMerge renders merged and survey outcomes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const merged = try outcomeText(arena, "feat/parser", .{ .merged = "abc123" });
    try std.testing.expectEqualStrings("merged feat/parser at abc123", merged);
    const survey = try outcomeText(arena, "feat/survey", .{ .noop = "M2" });
    try std.testing.expectEqualStrings("survey M2 closed with no changes", survey);
}

test "TowerMerge is irreversible and reports a nonexistent workspace as not initialized" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"branch\":\"feat/parser\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    try std.testing.expect(isIrreversible(decoded.input));
    try std.testing.expect(!readsOnly(decoded.input));
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.failure);
}
