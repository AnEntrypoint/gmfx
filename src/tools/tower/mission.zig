const std = @import("std");
const support = @import("support.zig");
const state = @import("../../core/tower/state.zig");
const store_mod = @import("../../core/tower/store.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;

pub const description = "Read or update a tower mission.";
const statuses = [_][]const u8{ "planned", "active", "completed", "blocked", "paused", "merged", "abandoned" };
const status_message = "TowerMission status must be planned, active, completed, blocked, paused, merged or abandoned";

const Args = struct {
    id: []const u8,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
    blocker: ?[]const u8 = null,
    clear_blockers: bool = false,
    task_done: ?[]const u8 = null,
    task_drop: ?[]const u8 = null,
    task_drop_reason: ?[]const u8 = null,
    scope: ?[]const []const u8 = null,
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
    const status = args.status orelse return null;
    if (contains(&statuses, status)) return null;
    return status_message;
}

pub fn call(ctx: support.DispatchContext, erased: support.ToolInput) support.DispatchError!support.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    const args = support.valueOf(Args, erased);
    const mission = resolve(arena, &store, args.*, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try renderMission(arena, mission));
}

fn resolve(arena: Allocator, store: *Store, args: Args, now_ms: i64) !state.Mission {
    const patch = toPatch(args);
    if (Store.isEmptyPatch(patch)) return readMission(arena, store, args.id);
    return store.patchMission(arena, args.id, patch, now_ms);
}

fn readMission(arena: Allocator, store: *Store, id: []const u8) !state.Mission {
    const st = try store.load(arena);
    const found = st.findMission(id) orelse return store.refuse(try std.fmt.allocPrint(arena, "unknown mission \"{s}\"", .{id}));
    return found.*;
}

fn toPatch(args: Args) Store.Patch {
    return .{
        .note = args.note,
        .blocker = args.blocker,
        .clear_blockers = args.clear_blockers,
        .status = args.status,
        .task_done = args.task_done,
        .task_drop = args.task_drop,
        .task_drop_reason = args.task_drop_reason,
        .scope = args.scope,
    };
}

fn renderMission(arena: Allocator, mission: state.Mission) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "# {s} {s}\n- status: {s}\n- branch: {s}\n- worktree: {s}\n- owner: {s}\n- tasks:", .{
        mission.id, mission.title, mission.status, mission.branch, mission.worktree, mission.owner orelse "(none)",
    });
    if (mission.tasks.len == 0) try out.appendSlice(arena, " (none)");
    for (mission.tasks) |task| {
        try out.print(arena, "\n  - {s} {s}", .{ taskMark(task), task.text });
    }
    try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

fn taskMark(task: state.Task) []const u8 {
    if (task.dropped == true) return "[-]";
    return if (task.done) "[x]" else "[ ]";
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

pub const spec = ToolSpec{
    .name = "TowerMission",
    .description = description,
    .model_schema = .{
        .name = "TowerMission",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .string, .description = "Mission id, for example M1." },
                .{ .name = "status", .json_type = .string, .description = "Set the mission status. merged is set by TowerMerge, not here.", .shape = &.{ .enum_values = &statuses } },
                .{ .name = "note", .json_type = .string, .description = "Append a note to the mission." },
                .{ .name = "blocker", .json_type = .string, .description = "Record a blocker; this sets the mission to blocked." },
                .{ .name = "clear_blockers", .json_type = .boolean, .description = "Remove all recorded blockers." },
                .{ .name = "task_done", .json_type = .string, .description = "Text that matches an open task to mark done." },
                .{ .name = "task_drop", .json_type = .string, .description = "Text that matches an open task to drop; needs task_drop_reason." },
                .{ .name = "task_drop_reason", .json_type = .string, .description = "Why the matched task is dropped." },
                .{ .name = "scope", .json_type = .array, .description = "Replace the mission's scope paths.", .shape = &.{ .array_values = .{ .json_type = .string } } },
            },
            .required = &.{"id"},
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

test "TowerMission refuses unknown keys, unknown statuses and a missing id" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator };
    const refused = [_][]const u8{
        "{\"id\":\"M1\",\"unknown\":true}",
        "{\"id\":\"M1\",\"status\":\"done\"}",
        "{}",
    };
    for (refused) |args_json| {
        const decoded = try decode(ctx, args_json);
        try std.testing.expect(decoded == .failure);
        std.testing.allocator.free(decoded.failure);
    }
}

test "TowerMission reads a nonexistent workspace as not initialized" {
    const ctx = support.DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"id\":\"M1\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.failure);
}

test "TowerMission renders owner and task states" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tasks = [_]state.Task{
        .{ .text = "write tests", .done = true },
        .{ .text = "docs", .dropped = true },
        .{ .text = "ship" },
    };
    const mission = state.Mission{
        .id = "M1",
        .title = "Parser",
        .slug = "parser",
        .branch = "feat/parser",
        .worktree = ".tower/worktrees/wt-1",
        .status = "active",
        .owner = "worker-1",
        .tasks = &tasks,
    };
    const body = try renderMission(arena_state.allocator(), mission);
    try std.testing.expectEqualStrings(
        "# M1 Parser\n- status: active\n- branch: feat/parser\n- worktree: .tower/worktrees/wt-1\n- owner: worker-1\n- tasks:\n  - [x] write tests\n  - [-] docs\n  - [ ] ship\n",
        body,
    );
}
