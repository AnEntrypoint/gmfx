const std = @import("std");
const state = @import("state.zig");
const git = @import("git.zig");
const gate = @import("gate.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;

pub const merge_head_message = "cannot start a tower merge while MERGE_HEAD already exists; finish or abort the existing merge first";
pub const detached_checkout_message = "the main checkout is in a detached HEAD state; check out the recorded base branch before merging; nothing was merged";

fn splitLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try out.append(arena, trimmed);
    }
    return out.toOwnedSlice(arena);
}

fn workerRuntimes(arena: Allocator, st: state.State, mission_id: []const u8) ![]gate.Worker {
    var out: std.ArrayList(gate.Worker) = .empty;
    for (st.roster.agents) |agent| {
        if (agent.diedAt != null) continue;
        const owner = agent.missionId orelse continue;
        if (!std.mem.eql(u8, owner, mission_id)) continue;
        try out.append(arena, .{ .name = agent.name, .status = .unknown });
    }
    return out.toOwnedSlice(arena);
}

pub fn observe(arena: Allocator, root: []const u8, base: []const u8, mission: state.Mission, spawn_base: ?[]const u8) !gate.Observations {
    const base_tip = try git.branchTip(arena, root, base);
    const checked_out: ?[]const u8 = git.currentBranch(arena, root) catch null;
    const dirty_text = try git.run(arena, root, &.{ "status", "--porcelain" });
    var dirty: std.ArrayList([]const u8) = .empty;
    var dirty_lines = std.mem.splitScalar(u8, dirty_text, '\n');
    while (dirty_lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 4) continue;
        try dirty.append(arena, std.mem.trimEnd(u8, line[3..], "/"));
    }
    const has_branch = try git.branchExists(arena, root, mission.branch);
    if (!has_branch) {
        return .{ .base_tip = base_tip, .checked_out_branch = checked_out, .base_dirty_files = try dirty.toOwnedSlice(arena), .branch = null };
    }
    const tip = try git.branchTip(arena, root, mission.branch);
    const head_tip = try git.branchTip(arena, root, "HEAD");
    const base_is_ancestor = try git.isAncestor(arena, root, base_tip, tip);
    const spawn_is_ancestor = if (spawn_base) |spawn| try git.isAncestor(arena, root, spawn, tip) else false;
    const diff_base = if (spawn_is_ancestor) spawn_base.? else base_tip;
    const changed = try git.diffNameOnly(arena, root, diff_base, tip);
    const merge_touched = try git.diffNameOnly(arena, root, head_tip, tip);
    return .{
        .base_tip = base_tip,
        .checked_out_branch = checked_out,
        .base_dirty_files = try dirty.toOwnedSlice(arena),
        .branch = .{
            .tip = tip,
            .base_is_ancestor = base_is_ancestor,
            .changed_files = try splitLines(arena, changed),
            .merge_touched_files = try splitLines(arena, merge_touched),
        },
    };
}

pub fn evaluateMission(arena: Allocator, store: *Store, st: state.State, mission: state.Mission) !gate.Result {
    const observations = try observe(arena, store.root, st.base, mission, mission.spawnBase);
    const reviews = try store.reviewsFor(arena, mission.branch);
    const review_views = try arena.alloc(gate.Review, reviews.len);
    for (reviews, 0..) |review, index| review_views[index] = .{
        .reviewer = review.reviewer,
        .target = review.target,
        .round = review.round,
        .status = review.status,
        .merge = review.merge,
        .reviewed_commit = review.reviewed_commit,
        .mission = review.mission,
        .seq = review.seq,
    };
    const workers = try workerRuntimes(arena, st, mission.id);
    return gate.evaluate(arena, st.base, mission, st.missions, review_views, workers, observations);
}

pub const MergeOutcome = union(enum) {
    merged: []const u8,
    noop: []const u8,
};

pub fn mergeBranch(arena: Allocator, store: *Store, branch: []const u8, now_ms: i64) !MergeOutcome {
    var st = try store.load(arena);
    var open_id: ?[]const u8 = null;
    var closed_seen = false;
    for (st.missions) |mission| {
        if (!std.mem.eql(u8, mission.branch, branch)) continue;
        if (store_mod.isClosed(mission)) {
            closed_seen = true;
            continue;
        }
        open_id = mission.id;
    }
    const id = open_id orelse {
        if (closed_seen) return store.refuse(try std.fmt.allocPrint(arena, "merge blocked: branch \"{s}\" resolves only to closed mission(s)", .{branch}));
        return store.refuse(try std.fmt.allocPrint(arena, "no tower mission owns branch \"{s}\"", .{branch}));
    };
    const mission = st.findMission(id).?;
    const result = try evaluateMission(arena, store, st, mission.*);
    if (!result.ready and !result.noop) {
        try store.appendLog(arena, now_ms, "tower", "merge.blocked", try std.fmt.allocPrint(arena, " mission={s} reason={s}", .{ id, result.blocks[0].reason }));
        return store.refuse(result.blocks[0].message);
    }
    if (result.noop) {
        mission.status = "merged";
        try store.saveRendered(arena, st);
        try store.appendLog(arena, now_ms, "tower", "merge.noop", try std.fmt.allocPrint(arena, " mission={s}", .{id}));
        return .{ .noop = id };
    }
    const message = try std.fmt.allocPrint(arena, "Merge {s} ({s})", .{ branch, id });
    const head = git.mergeNoFf(arena, store.root, branch, message) catch |err| switch (err) {
        error.MergeHeadExists => return store.refuse(merge_head_message),
        error.RecoveryRequired => return store.refuse(try std.fmt.allocPrint(arena, "recovery-required: merge of {s} could not be cleanly aborted; inspect the main checkout", .{branch})),
        error.GitFailed => return store.refuse(try std.fmt.allocPrint(arena, "git merge of {s} failed; nothing was marked merged", .{branch})),
        else => return err,
    };
    mission.status = "merged";
    try store.saveRendered(arena, st);
    try store.appendLog(arena, now_ms, "tower", "merge", try std.fmt.allocPrint(arena, " mission={s} head={s}", .{ id, head }));
    return .{ .merged = head };
}

pub const RebaseOutcome = union(enum) {
    up_to_date: []const u8,
    rebased: struct { from: []const u8, to: []const u8 },
};

pub fn rebaseMission(arena: Allocator, store: *Store, id: []const u8, now_ms: i64) !RebaseOutcome {
    var st = try store.load(arena);
    const mission = st.findMission(id) orelse {
        return store.refuse(try std.fmt.allocPrint(arena, "unknown mission \"{s}\"", .{id}));
    };
    if (store_mod.isClosed(mission.*)) return store.refuse(try std.fmt.allocPrint(arena, "mission {s} is {s} — a closed mission cannot be rebased", .{ id, mission.status }));
    if (std.mem.eql(u8, mission.kind, "survey")) return store.refuse(try std.fmt.allocPrint(arena, "mission {s} is a survey and has no branch to rebase", .{id}));
    const busy_workers = try workerRuntimes(arena, st, id);
    if (busy_workers.len > 0) return store.refuse(try std.fmt.allocPrint(arena, "rebase blocked: worker(s) cannot be observed authoritatively for mission {s}", .{id}));
    if (!(try git.branchExists(arena, store.root, mission.branch))) {
        return store.refuse(try std.fmt.allocPrint(arena, "mission {s} branch \"{s}\" does not exist", .{ id, mission.branch }));
    }
    const worktree_path = try store.absolute(arena, mission.worktree);
    if (!store.dirExists(arena, mission.worktree)) {
        return store.refuse(try std.fmt.allocPrint(arena, "mission {s} worktree {s} is not present", .{ id, mission.worktree }));
    }
    if (try git.isWorktreeDirty(arena, worktree_path)) {
        return store.refuse(try std.fmt.allocPrint(arena, "mission {s} worktree has uncommitted changes; commit or stash them before rebasing", .{id}));
    }
    const base_tip = try git.branchTip(arena, store.root, st.base);
    const tip = try git.branchTip(arena, store.root, mission.branch);
    if (try git.isAncestor(arena, store.root, base_tip, tip)) return .{ .up_to_date = base_tip };

    const output = try git.execute(arena, worktree_path, &.{ "rebase", st.base });
    defer output.deinit(arena);
    if (output.exit_code != 0) {
        _ = git.execute(arena, worktree_path, &.{ "rebase", "--abort" }) catch {};
        const blocker = try std.fmt.allocPrint(arena, "rebase onto {s} conflicted and was aborted", .{st.base});
        mission.blockers = try appendBlocker(arena, mission.blockers, blocker);
        mission.status = "blocked";
        try store.saveRendered(arena, st);
        try store.appendLog(arena, now_ms, "tower", "rebase.conflict", try std.fmt.allocPrint(arena, " mission={s}", .{id}));
        return store.refuse(try std.fmt.allocPrint(arena, "rebase of mission {s} conflicted and was aborted; the mission is marked blocked", .{id}));
    }
    const new_tip = try git.branchTip(arena, store.root, mission.branch);
    mission.lastRebase = .{ .fromCommit = tip, .toCommit = new_tip };
    try store.saveRendered(arena, st);
    try store.appendLog(arena, now_ms, "tower", "rebase", try std.fmt.allocPrint(arena, " mission={s} from={s} to={s}", .{ id, tip, new_tip }));
    return .{ .rebased = .{ .from = tip, .to = new_tip } };
}

fn appendBlocker(arena: Allocator, list: []const []const u8, value: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = value;
    return out;
}

pub const TeardownOptions = struct {
    force: bool = false,
    exclude: []const []const u8 = &.{},
    dry_run: bool = false,
};

pub const TeardownLine = struct {
    mission: []const u8,
    outcome: []const u8,
};

pub fn teardown(arena: Allocator, store: *Store, options: TeardownOptions, now_ms: i64) ![]TeardownLine {
    const st = try store.load(arena);
    var lines: std.ArrayList(TeardownLine) = .empty;
    for (st.missions) |mission| {
        if (containsName(options.exclude, mission.id) or containsName(options.exclude, mission.branch)) {
            try lines.append(arena, .{ .mission = mission.id, .outcome = "kept: excluded" });
            continue;
        }
        if (!store.dirExists(arena, mission.worktree)) {
            try lines.append(arena, .{ .mission = mission.id, .outcome = "already removed" });
            continue;
        }
        const path = try store.absolute(arena, mission.worktree);
        if (!options.force and try git.isWorktreeDirty(arena, path)) {
            try lines.append(arena, .{ .mission = mission.id, .outcome = "kept: uncommitted changes" });
            continue;
        }
        if (options.dry_run) {
            try lines.append(arena, .{ .mission = mission.id, .outcome = "would remove" });
            continue;
        }
        git.worktreeRemove(arena, store.root, path) catch {
            try lines.append(arena, .{ .mission = mission.id, .outcome = "failed to remove" });
            continue;
        };
        try store.appendLog(arena, now_ms, "tower", "worktree.remove", try std.fmt.allocPrint(arena, " mission={s} ref={s}", .{ mission.id, mission.worktree }));
        try lines.append(arena, .{ .mission = mission.id, .outcome = "removed" });
    }
    return lines.toOwnedSlice(arena);
}

fn containsName(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

pub fn statusText(arena: Allocator, store: *Store) ![]u8 {
    const st = try store.load(arena);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "# Tower status\n\nBase: {s} — Mode: {s}\n\n## Missions\n", .{ st.base, st.mode });
    if (st.missions.len == 0) try out.appendSlice(arena, "(none)\n");
    for (st.missions) |mission| {
        try out.print(arena, "- {s} {s} [{s}] branch {s}", .{ mission.id, mission.title, mission.status, mission.branch });
        if (!store_mod.isClosed(mission)) {
            const result = try evaluateMission(arena, store, st, mission);
            if (result.ready or result.noop) {
                try out.appendSlice(arena, " — merge ready\n");
            } else {
                try out.print(arena, " — {s}\n", .{result.blocks[0].reason});
            }
        } else {
            try out.append(arena, '\n');
        }
    }
    try out.appendSlice(arena, "\n## Roster\n");
    if (st.roster.agents.len == 0) try out.appendSlice(arena, "(none)\n");
    for (st.roster.agents) |agent| {
        try out.print(arena, "- {s} ({s})\n", .{ agent.name, agent.kind });
    }
    return out.toOwnedSlice(arena);
}

test "Tower store_git reports an uninitialized repository as a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var store = Store{ .root = "/nonexistent-tower-root" };
    try std.testing.expectError(error.TowerRefused, statusText(arena_state.allocator(), &store));
    try std.testing.expectEqualStrings(store_mod.not_initialized_message, store.refusal);
}
