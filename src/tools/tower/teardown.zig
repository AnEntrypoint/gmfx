const std = @import("std");
const support = @import("support.zig");
const store_mod = @import("../../core/tower/store.zig");
const store_git = @import("../../core/tower/store_git.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;

pub const description = "Tear down the tower workspace after all missions are merged (or abandoned).";

const Args = struct {
    force: bool = false,
    exclude: []const []const u8 = &.{},
    dry_run: bool = false,
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
    const options = store_git.TeardownOptions{ .force = args.force, .exclude = args.exclude, .dry_run = args.dry_run };
    const lines = store_git.teardown(arena, &store, options, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try renderLines(arena, lines));
}

fn renderLines(arena: Allocator, lines: []const store_git.TeardownLine) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        try out.print(arena, "{s}: {s}\n", .{ line.mission, line.outcome });
    }
    return out.toOwnedSlice(arena);
}

pub fn readsOnly(_: support.ToolInput) bool {
    return false;
}

pub fn isIrreversible(input: support.ToolInput) bool {
    return !support.valueOf(Args, input).dry_run;
}

pub const spec = ToolSpec{
    .name = "TowerTeardown",
    .description = description,
    .model_schema = .{
        .name = "TowerTeardown",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "force", .json_type = .boolean, .description = "Remove worktrees even when they have uncommitted changes." },
                .{ .name = "exclude", .json_type = .array, .description = "Mission ids or branches to keep.", .shape = &.{ .array_values = .{ .json_type = .string } } },
                .{ .name = "dry_run", .json_type = .boolean, .description = "Report what would be removed without removing anything." },
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

test "TowerTeardown refuses unknown keys and mistyped flags" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const unknown = try decode(ctx, "{\"mission\":\"M1\"}");
    try std.testing.expect(unknown == .failure);
    std.testing.allocator.free(unknown.failure);
    const mistyped = try decode(ctx, "{\"force\":\"yes\"}");
    try std.testing.expect(mistyped == .failure);
    std.testing.allocator.free(mistyped.failure);
}

test "TowerTeardown is irreversible unless it is a dry run" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const dry = try decode(ctx, "{\"dry_run\":true}");
    try std.testing.expect(dry == .input);
    defer dry.input.deinit(std.testing.allocator);
    try std.testing.expect(!isIrreversible(dry.input));
    try std.testing.expect(!readsOnly(dry.input));
    const live = try decode(ctx, "{}");
    try std.testing.expect(live == .input);
    defer live.input.deinit(std.testing.allocator);
    try std.testing.expect(isIrreversible(live.input));
}

test "TowerTeardown renders one line per mission outcome" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lines = [_]store_git.TeardownLine{
        .{ .mission = "M1", .outcome = "removed" },
        .{ .mission = "M2", .outcome = "kept: uncommitted changes" },
    };
    const body = try renderLines(arena_state.allocator(), &lines);
    try std.testing.expectEqualStrings("M1: removed\nM2: kept: uncommitted changes\n", body);
}

test "TowerTeardown reports a nonexistent workspace as not initialized" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.failure);
}
