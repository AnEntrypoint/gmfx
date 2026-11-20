const std = @import("std");
const support = @import("support.zig");
const state = @import("../../core/tower/state.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;
const Store = support.Store;

pub const description = "Split the tower goal into missions. Each mission gets an id (M1, M2, …), a branch (feat/<slug>), and an isolated git worktree (.tower/worktrees/wt-N).";
const kinds = [_][]const u8{ "build", "survey" };
const table_header = "| id | title | branch | worktree | status |\n|---|---|---|---|---|\n";
const empty_message = "TowerPlan needs at least one mission";
const scope_message = "TowerPlan every mission needs at least one scope path";
const kind_message = "TowerPlan kind must be build or survey";

const MissionArgs = struct {
    title: []const u8,
    scope: []const []const u8,
    tasks: []const []const u8 = &.{},
    context: ?[]const u8 = null,
    deps: []const []const u8 = &.{},
    kind: []const u8 = "build",
};

const Args = struct {
    missions: []const MissionArgs,
};

pub fn decode(ctx: support.DispatchContext, args_json: []const u8) support.DispatchError!support.DecodeResult {
    const decoded = try support.decodeArguments(Args, ctx, args_json);
    switch (decoded) {
        .failure => return decoded,
        .input => |input| {
            const message = refusalFor(support.valueOf(Args, input).*) orelse return decoded;
            input.deinit(ctx.allocator);
            return .{ .failure = try ctx.allocator.dupe(u8, message) };
        },
    }
}

fn refusalFor(args: Args) ?[]const u8 {
    if (args.missions.len == 0) return empty_message;
    for (args.missions) |mission| {
        if (mission.scope.len == 0) return scope_message;
        if (!contains(&kinds, mission.kind)) return kind_message;
    }
    return null;
}

pub fn call(ctx: support.DispatchContext, erased: support.ToolInput) support.DispatchError!support.ToolResult {
    if (try support.modeInactive(ctx)) |refusal| return refusal;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    const args = support.valueOf(Args, erased);
    const items = try planItems(arena, args.missions);
    const created = store.plan(arena, items, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try renderTable(arena, created));
}

fn planItems(arena: Allocator, missions: []const MissionArgs) ![]Store.PlanItem {
    const items = try arena.alloc(Store.PlanItem, missions.len);
    for (missions, items) |mission, *item| {
        item.* = .{
            .title = mission.title,
            .scope = mission.scope,
            .tasks = mission.tasks,
            .context = mission.context,
            .deps = mission.deps,
            .kind = mission.kind,
        };
    }
    return items;
}

fn renderTable(arena: Allocator, missions: []const state.Mission) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, table_header);
    for (missions) |mission| {
        try out.print(arena, "| {s} | {s} | {s} | {s} | {s} |\n", .{ mission.id, mission.title, mission.branch, mission.worktree, mission.status });
    }
    return out.toOwnedSlice(arena);
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

pub fn readsOnly(_: support.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: support.ToolInput) bool {
    return false;
}

const mission_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "title", .json_type = .string, .description = "Short mission title, ASCII only." },
        .{ .name = "scope", .json_type = .array, .description = "Repository paths or globs this mission may change.", .bounds = &.{ .min_items = 1 }, .shape = &.{ .array_values = .{ .json_type = .string } } },
        .{ .name = "tasks", .json_type = .array, .description = "Task descriptions for the mission.", .shape = &.{ .array_values = .{ .json_type = .string } } },
        .{ .name = "context", .json_type = .string, .description = "Extra briefing for the mission's worker." },
        .{ .name = "deps", .json_type = .array, .description = "Ids of earlier missions this one depends on.", .shape = &.{ .array_values = .{ .json_type = .string } } },
        .{ .name = "kind", .json_type = .string, .description = "build (default) or survey.", .shape = &.{ .enum_values = &kinds } },
    },
    .required = &.{ "title", "scope" },
    .additional_properties = false,
};

pub const spec = ToolSpec{
    .name = "TowerPlan",
    .description = description,
    .model_schema = .{
        .name = "TowerPlan",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "missions", .json_type = .array, .description = "Missions to create, in order.", .bounds = &.{ .min_items = 1 }, .shape = &.{ .array_objects = &mission_schema } },
            },
            .required = &.{"missions"},
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

test "TowerPlan refuses unknown keys, empty mission lists, scopes and kinds" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const refused = [_][]const u8{
        "{\"missions\":[],\"extra\":1}",
        "{\"missions\":[]}",
        "{\"missions\":[{\"title\":\"Parser\",\"scope\":[]}]}",
        "{\"missions\":[{\"title\":\"Parser\",\"scope\":[\"src/parser\"],\"kind\":\"other\"}]}",
    };
    for (refused) |args_json| {
        const decoded = try decode(ctx, args_json);
        try std.testing.expect(decoded == .failure);
        std.testing.allocator.free(decoded.failure);
    }
}

test "TowerPlan renders the new missions as a compact table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const missions = [_]state.Mission{.{
        .id = "M1",
        .title = "Parser",
        .slug = "parser",
        .branch = "feat/parser",
        .worktree = ".tower/worktrees/wt-1",
        .status = "planned",
    }};
    const table = try renderTable(arena_state.allocator(), &missions);
    try std.testing.expectEqualStrings(
        "| id | title | branch | worktree | status |\n|---|---|---|---|---|\n| M1 | Parser | feat/parser | .tower/worktrees/wt-1 | planned |\n",
        table,
    );
}

test "TowerPlan is refused while tower mode is inactive" {
    const tower_mode = @import("../../core/tower/mode.zig");
    tower_mode.exit();
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"missions\":[{\"title\":\"Parser\",\"scope\":[\"src/parser\"]}]}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(tower_mode.not_active_message, result.failure);
}
