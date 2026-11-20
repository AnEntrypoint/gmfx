const std = @import("std");
const support = @import("support.zig");
const tower_mode = @import("../../core/tower/mode.zig");
const store_mod = @import("../../core/tower/store.zig");
const state = @import("../../core/tower/state.zig");
const paths = @import("../../core/tower/paths.zig");
const git = @import("../../core/tower/git.zig");
const spawn = @import("../../core/tower/spawn.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const Allocator = std.mem.Allocator;
const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;

pub const description = "Spawn a tower worker on a mission (in its own git worktree) or a reviewer on a branch. The agent runs in the background; its completion arrives as a notification.";

pub const host_unavailable_message = "TowerSpawn cannot start the tower agent: this dispatch context carries no subagent runtime. Nothing was created.";
pub const blank_name_message = "tower agent name must not be blank or carry surrounding whitespace";
pub const kind_message = "TowerSpawn kind must be worker or reviewer";
pub const worker_mission_message = "worker spawns require mission_id";
pub const reviewer_target_message = "reviewer spawns require review_target";
pub const base_unmerged_message = "the base checkout has unmerged paths (an in-progress merge, rebase, or cherry-pick) — finish or abort it before spawning workers";
pub const base_detached_message = "the main checkout is in a detached HEAD state with uncommitted changes, and a WIP snapshot would carry detached-HEAD content into the mission branch — check out the recorded base or commit/stash the changes before spawning workers";
pub const base_off_branch_format = "the main checkout is not on the recorded base \"{s}\" but has uncommitted changes, and a WIP snapshot would carry other branch content into the mission branch — switch back to \"{s}\" or commit/stash the changes before spawning workers";
pub const unowned_branch_format = "branch \"{s}\" exists in git but is not owned by any tower mission (it appeared after planning) — refusing to build the worker on unrelated history; delete or rename that branch if it is stale, or re-plan the mission under a new title";

const whitespace = " \t\r\n";

const Args = struct {
    name: []const u8,
    kind: []const u8,
    model: ?[]const u8 = null,
    mission_id: ?[]const u8 = null,
    review_target: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

fn blank(text: ?[]const u8) bool {
    const value = text orelse return true;
    return std.mem.trim(u8, value, whitespace).len == 0;
}

pub fn validateArgs(args: Args) ?[]const u8 {
    const name = std.mem.trim(u8, args.name, whitespace);
    if (name.len == 0 or name.len != args.name.len) return blank_name_message;
    const kind = spawn.parseKind(args.kind) orelse return kind_message;
    switch (kind) {
        .worker => if (blank(args.mission_id)) return worker_mission_message,
        .reviewer => if (blank(args.review_target)) return reviewer_target_message,
    }
    return null;
}

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Args, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    if (validateArgs(support.valueOf(Args, value).*)) |refusal| {
        value.deinit(ctx.allocator);
        return .{ .failure = try ctx.allocator.dupe(u8, refusal) };
    }
    return decoded;
}

pub fn call(ctx: DispatchContext, erased: ToolInput) DispatchError!ToolResult {
    return spawnWith(ctx, erased);
}

pub fn spawnWith(ctx: DispatchContext, erased: ToolInput) DispatchError!ToolResult {
    if (try support.modeInactive(ctx)) |refusal| return refusal;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = support.storeFor(ctx);
    return run(ctx, arena, &store, support.valueOf(Args, erased)) catch |err| support.fail(ctx, &store, err);
}

fn run(
    ctx: DispatchContext,
    arena: Allocator,
    store: *store_mod.Store,
    args: *const Args,
) !ToolResult {
    var st = try store.load(arena);
    const name = args.name;
    const kind = spawn.parseKind(args.kind) orelse return support.failure(ctx, kind_message);

    if (paths.isReservedAgentName(name)) {
        return support.failure(ctx, try std.fmt.allocPrint(arena, "tower agent name \"{s}\" is reserved by the tower protocol — pick a different name", .{name}));
    }
    if (rosterEntry(st, name)) |existing| {
        return support.failure(ctx, try std.fmt.allocPrint(arena, "tower agent \"{s}\" is already registered (agent_id: {s}, kind: {s}) — pick a different name", .{ name, existing.agentId, existing.kind }));
    }

    var mission_index: ?usize = null;
    switch (kind) {
        .worker => {
            const mission_id = args.mission_id orelse return support.failure(ctx, worker_mission_message);
            const index = missionIndex(st, mission_id) orelse return support.failure(ctx, try unknownMissionMessage(arena, st, mission_id));
            const mission = st.missions[index];
            if (store_mod.isClosed(mission)) {
                return support.failure(ctx, try std.fmt.allocPrint(arena, "mission {s} is {s} — terminal missions cannot spawn workers; no worktree or agent was created", .{ mission.id, mission.status }));
            }
            mission_index = index;
        },
        .reviewer => if (args.review_target == null) return support.failure(ctx, reviewer_target_message),
    }

    const launched = ctx.tower_launch orelse return support.failure(ctx, host_unavailable_message);

    var worktree_abs: ?[]const u8 = null;
    var spawn_base: ?[]u8 = null;
    var write_root: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var worktree_rel: ?[]const u8 = null;
    var prompt: []u8 = undefined;

    switch (kind) {
        .worker => {
            const mission = st.missions[mission_index.?];
            const abs = try store.absolute(arena, mission.worktree);
            worktree_abs = abs;
            worktree_rel = mission.worktree;
            branch = mission.branch;
            write_root = abs;
            if (!store.dirExists(arena, mission.worktree)) {
                spawn_base = git.addWorktreeForMission(arena, store.root, abs, mission.branch, st.base, mission.owner != null) catch |err| switch (err) {
                    error.BaseUnmerged => return support.failure(ctx, base_unmerged_message),
                    error.BaseDetached => return support.failure(ctx, base_detached_message),
                    error.BaseOffBranch => return support.failure(ctx, try std.fmt.allocPrint(arena, base_off_branch_format, .{ st.base, st.base })),
                    error.UnownedBranch => return support.failure(ctx, try std.fmt.allocPrint(arena, unowned_branch_format, .{mission.branch})),
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        note = try std.fmt.allocPrint(arena, "worktree setup warning (continuing): {s}", .{@errorName(err)});
                        break :blk null;
                    },
                };
                if (spawn_base) |sha| {
                    st.missions[mission_index.?].spawnBase = sha;
                    note = try std.fmt.allocPrint(arena, "base snapshot: {s} — the base checkout had uncommitted changes; they are committed as the branch's first commit (the checkout itself was left untouched)", .{sha[0..@min(7, sha.len)]});
                }
            }
            const mission_file = try missionRel(arena, mission.id, mission.slug);
            const mission_text = (try store.readRel(arena, mission_file)) orelse return support.failure(ctx, try std.fmt.allocPrint(arena, "mission file {s} is missing", .{mission_file}));
            prompt = try spawn.workerPrompt(arena, .{
                .name = name,
                .mission_id = mission.id,
                .mission_kind = mission.kind,
                .mission_text = mission_text,
                .worktree = abs,
                .branch = mission.branch,
                .base = st.base,
                .spawn_base = spawn_base,
                .repo_root = store.root,
                .scope = mission.scope,
                .extra = args.instructions,
            });
        },
        .reviewer => {
            const target = args.review_target.?;
            branch = target;
            var reviewed_text: ?[]const u8 = null;
            if (missionIndexByBranch(st, target)) |index| {
                const reviewed = st.missions[index];
                if (try store.readRel(arena, try missionRel(arena, reviewed.id, reviewed.slug))) |text| reviewed_text = text;
            }
            prompt = try spawn.reviewerPrompt(arena, .{
                .name = name,
                .target = target,
                .base = st.base,
                .repo_root = store.root,
                .mission_text = reviewed_text,
                .extra = args.instructions,
            });
        },
    }

    var options = launched.options;
    options.write_root = write_root;
    const result = try launched.host.launchTowerChild(arena, name, prompt, args.model, options);
    if (!result.success) {
        return support.failure(ctx, try std.fmt.allocPrint(arena, "tower spawn failed: {s}", .{result.body}));
    }

    const now_ms = support.nowMs();
    var roster: std.ArrayList(state.RosterEntry) = .empty;
    try roster.appendSlice(arena, st.roster.agents);
    try roster.append(arena, .{
        .name = name,
        .agentId = name,
        .kind = args.kind,
        .missionId = if (mission_index) |index| st.missions[index].id else null,
        .reviewTarget = if (kind == .reviewer) args.review_target else null,
        .worktree = worktree_rel,
        .branch = branch,
        .spawnedAt = try paths.isoTimestamp(arena, now_ms),
    });
    st.roster.agents = try roster.toOwnedSlice(arena);
    if (mission_index) |index| st.missions[index].owner = name;
    try store.saveRendered(arena, st);
    try store.appendLog(arena, now_ms, "tower", "spawn", try std.fmt.allocPrint(arena, " name={s} kind={s} agent={s} mission={s}", .{
        name,
        args.kind,
        name,
        if (mission_index) |index| st.missions[index].id else "none",
    }));

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.print("name: {s}\nkind: {s}\nagent_id: {s}\nstatus: running\n", .{ name, args.kind, name });
    if (args.model) |model| try writer.print("model: {s}\n", .{model});
    if (mission_index) |index| {
        const mission = st.missions[index];
        try writer.print("mission: {s} — {s}\nbranch: {s}\nworktree: {s}\n", .{ mission.id, mission.title, mission.branch, worktree_abs.? });
    } else {
        try writer.print("review_target: {s}\n", .{args.review_target.?});
    }
    if (note) |text| try writer.print("{s}\n", .{text});
    try writer.writeAll("\n");
    try writer.writeAll(switch (kind) {
        .worker => "The worker runs in the background; its completion arrives as a notification. Use TowerInbox or TowerStatus only when a decision needs them. If it dies, check the reason before any retry.",
        .reviewer => "The reviewer runs in the background; its completion arrives as a notification. A reviewer is one-shot: after it finishes, spawn a fresh reviewer with a new name rather than resuming it.",
    });
    return support.success(ctx, out.written());
}

fn missionRel(arena: Allocator, id: []const u8, slug: []const u8) ![]u8 {
    const file = try paths.missionFileName(arena, id, slug);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.missions_dir, file });
}

fn rosterEntry(st: state.State, name: []const u8) ?state.RosterEntry {
    for (st.roster.agents) |agent| {
        if (std.mem.eql(u8, agent.name, name)) return agent;
    }
    return null;
}

fn missionIndex(st: state.State, id: []const u8) ?usize {
    for (st.missions, 0..) |mission, index| {
        if (std.mem.eql(u8, mission.id, id)) return index;
    }
    return null;
}

fn missionIndexByBranch(st: state.State, branch: []const u8) ?usize {
    for (st.missions, 0..) |mission, index| {
        if (std.mem.eql(u8, mission.branch, branch)) return index;
    }
    return null;
}

fn unknownMissionMessage(arena: Allocator, st: state.State, id: []const u8) ![]u8 {
    if (st.missions.len == 0) {
        return std.fmt.allocPrint(arena, "unknown mission \"{s}\" — known missions: (none planned yet)", .{id});
    }
    const ids = try arena.alloc([]const u8, st.missions.len);
    for (st.missions, ids) |mission, *slot| slot.* = mission.id;
    return std.fmt.allocPrint(arena, "unknown mission \"{s}\" — known missions: {s}", .{ id, try std.mem.join(arena, ", ", ids) });
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerSpawn",
    .description = description,
    .model_schema = .{
        .name = "TowerSpawn",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "name", .json_type = .string, .description = "Unique tower name for the agent, for example agent-build or reviewer-a. Used for inbox addressing and mission ownership." },
                .{ .name = "kind", .json_type = .string, .description = "worker executes a mission in its worktree; reviewer reviews one branch.", .shape = &.{ .enum_values = &.{ "worker", "reviewer" } } },
                .{ .name = "model", .json_type = .string, .description = "Model alias for this spawn. Pass only when the user explicitly requests a model." },
                .{ .name = "mission_id", .json_type = .string, .description = "Required for workers: the mission id from TowerPlan, for example M1." },
                .{ .name = "review_target", .json_type = .string, .description = "Required for reviewers: the branch to review, for example feat/parser." },
                .{ .name = "instructions", .json_type = .string, .description = "Extra tower instructions appended to the generated briefing." },
            },
            .required = &.{ "name", "kind" },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = true,
    .action_label = "Spawning tower agent",
    .completed_action_label = "Spawned tower agent",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "TowerSpawn refuses unknown keys, a missing name and a missing kind" {
    const ctx = DispatchContext{ .allocator = std.testing.allocator };
    const missing_name = try decode(ctx, "{\"kind\":\"worker\",\"mission_id\":\"M1\"}");
    try std.testing.expect(missing_name == .failure);
    std.testing.allocator.free(missing_name.failure);
    const missing_kind = try decode(ctx, "{\"name\":\"agent-build\",\"mission_id\":\"M1\"}");
    try std.testing.expect(missing_kind == .failure);
    std.testing.allocator.free(missing_kind.failure);
    const extra = try decode(ctx, "{\"name\":\"agent-build\",\"kind\":\"worker\",\"mission_id\":\"M1\",\"extra\":1}");
    try std.testing.expect(extra == .failure);
    std.testing.allocator.free(extra.failure);
}

test "TowerSpawn validates the kind and the kind's required field" {
    try std.testing.expectEqualStrings(kind_message, validateArgs(.{ .name = "a", .kind = "boss" }).?);
    try std.testing.expectEqualStrings(worker_mission_message, validateArgs(.{ .name = "a", .kind = "worker" }).?);
    try std.testing.expectEqualStrings(worker_mission_message, validateArgs(.{ .name = "a", .kind = "worker", .mission_id = "  " }).?);
    try std.testing.expectEqualStrings(reviewer_target_message, validateArgs(.{ .name = "r", .kind = "reviewer" }).?);
    try std.testing.expect(validateArgs(.{ .name = "r", .kind = "reviewer", .review_target = "feat/parser" }) == null);
    try std.testing.expect(validateArgs(.{ .name = "agent-build", .kind = "worker", .mission_id = "M1" }) == null);
}

test "TowerSpawn refuses a blank or padded agent name" {
    try std.testing.expectEqualStrings(blank_name_message, validateArgs(.{ .name = "", .kind = "worker", .mission_id = "M1" }).?);
    try std.testing.expectEqualStrings(blank_name_message, validateArgs(.{ .name = " agent ", .kind = "worker", .mission_id = "M1" }).?);
}

test "TowerSpawn refuses with the not-initialized message when tower is absent" {
    tower_mode.enter();
    defer tower_mode.exit();
    const ctx = DispatchContext{ .allocator = std.testing.allocator, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"name\":\"agent-build\",\"kind\":\"worker\",\"mission_id\":\"M1\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    const result = try call(ctx, decoded.input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, result.failure);
}

test "TowerSpawn refuses with the host-unavailable message when no subagent host is wired" {
    tower_mode.enter();
    defer tower_mode.exit();
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const store = store_mod.Store{ .root = root };
    var missions = [_]state.Mission{.{ .id = "M1", .title = "Parser", .slug = "parser", .branch = "feat/parser", .worktree = ".tower/worktrees/wt-1" }};
    try store.save(arena, .{ .base = "main", .createdAt = "2026-11-09T00:00:00.000Z", .missions = &missions });
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = root };
    const decoded = try decode(ctx, "{\"name\":\"agent-build\",\"kind\":\"worker\",\"mission_id\":\"M1\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(alloc);
    const result = try call(ctx, decoded.input);
    defer result.deinit(alloc);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(host_unavailable_message, result.failure);
    try std.testing.expect(!store.dirExists(arena, ".tower/worktrees/wt-1"));
}

test "TowerSpawn needs approval and is reversible" {
    const ctx = DispatchContext{ .allocator = std.testing.allocator };
    const decoded = try decode(ctx, "{\"name\":\"agent-build\",\"kind\":\"worker\",\"mission_id\":\"M1\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(std.testing.allocator);
    try std.testing.expect(spec.requires_approval);
    try std.testing.expect(!isIrreversible(decoded.input));
    try std.testing.expect(!readsOnly(decoded.input));
}
