const std = @import("std");
const state = @import("state.zig");
const scopes = @import("scopes.zig");

const Allocator = std.mem.Allocator;

pub const Review = struct {
    reviewer: []const u8,
    target: []const u8,
    round: u32,
    status: []const u8,
    merge: []const u8,
    reviewed_commit: []const u8,
    mission: ?[]const u8 = null,
    seq: u32 = 0,
};

pub const Worker = struct {
    name: []const u8,
    status: enum { busy, idle, unknown },
};

pub const Branch = struct {
    tip: []const u8,
    base_is_ancestor: bool,
    changed_files: []const []const u8,
    merge_touched_files: []const []const u8,
};

pub const Observations = struct {
    base_tip: []const u8,
    checked_out_branch: ?[]const u8,
    base_dirty_files: []const []const u8,
    branch: ?Branch,
};

pub const Block = struct {
    reason: []const u8,
    message: []const u8,
};

pub const Result = struct {
    ready: bool,
    noop: bool,
    blocks: []const Block,
    selected_review: ?Review,
};

pub fn selectReview(mission: state.Mission, mission_list: []const state.Mission, reviews: []const Review) ?Review {
    var sibling_count: usize = 0;
    var stamped_count: usize = 0;
    for (mission_list) |candidate| {
        if (std.mem.eql(u8, candidate.branch, mission.branch) and !std.mem.eql(u8, candidate.id, mission.id)) sibling_count += 1;
    }
    for (reviews) |review| {
        if (review.mission != null and std.mem.eql(u8, review.mission.?, mission.id)) stamped_count += 1;
    }
    var index = reviews.len;
    while (index > 0) {
        index -= 1;
        const review = reviews[index];
        if (stamped_count > 0) {
            if (review.mission) |id| {
                if (std.mem.eql(u8, id, mission.id)) return review;
            } else if (sibling_count == 0) {
                return review;
            }
        } else if (review.mission == null) {
            return review;
        }
    }
    return null;
}

fn isCompleted(mission: state.Mission) bool {
    return std.mem.eql(u8, mission.status, "completed");
}

pub fn evaluate(
    arena: Allocator,
    base_name: []const u8,
    mission: state.Mission,
    mission_list: []const state.Mission,
    reviews: []const Review,
    workers: []const Worker,
    observations: Observations,
) !Result {
    const selected = if (std.mem.eql(u8, mission.kind, "build")) selectReview(mission, mission_list, reviews) else null;
    var blocks: std.ArrayList(Block) = .empty;
    if (!isCompleted(mission)) {
        try blocks.append(arena, .{ .reason = "not-completed", .message = try std.fmt.allocPrint(arena, "merge blocked: mission {s} is {s} — only a completed mission can merge", .{ mission.id, mission.status }) });
    }
    var open_count: usize = 0;
    for (mission.tasks) |task| {
        if (!task.done and task.dropped != true) open_count += 1;
    }
    if (open_count > 0) {
        var listed: std.ArrayList(u8) = .empty;
        for (mission.tasks) |task| {
            if (task.done or task.dropped == true) continue;
            if (listed.items.len > 0) try listed.appendSlice(arena, ", ");
            try listed.print(arena, "\"{s}\"", .{task.text});
        }
        try blocks.append(arena, .{ .reason = "open-tasks", .message = try std.fmt.allocPrint(arena, "merge blocked: mission {s} has {d} open task(s): {s}", .{ mission.id, open_count, listed.items }) });
    }
    if (mission.blockers.len > 0) {
        const joined = try std.mem.join(arena, " | ", mission.blockers);
        try blocks.append(arena, .{ .reason = "blockers", .message = try std.fmt.allocPrint(arena, "merge blocked: mission {s} has {d} blocker(s): {s}", .{ mission.id, mission.blockers.len, joined }) });
    }
    var busy: std.ArrayList(u8) = .empty;
    var unknown: std.ArrayList(u8) = .empty;
    for (workers) |worker| {
        switch (worker.status) {
            .busy => {
                if (busy.items.len > 0) try busy.appendSlice(arena, ", ");
                try busy.appendSlice(arena, worker.name);
            },
            .unknown => {
                if (unknown.items.len > 0) try unknown.appendSlice(arena, ", ");
                try unknown.appendSlice(arena, worker.name);
            },
            .idle => {},
        }
    }
    if (busy.items.len > 0) {
        try blocks.append(arena, .{ .reason = "worker-busy", .message = try std.fmt.allocPrint(arena, "merge blocked: worker(s) {s} are mid-turn — wait for every mission worker to become idle before merging", .{busy.items}) });
    }
    if (unknown.items.len > 0) {
        try blocks.append(arena, .{ .reason = "worker-unknown", .message = try std.fmt.allocPrint(arena, "merge blocked: worker runtime for {s} cannot be observed authoritatively — unknown is not idle; retry from the main tower agent", .{unknown.items}) });
    }
    if (blocks.items.len > 0) return .{ .ready = false, .noop = false, .blocks = blocks.items, .selected_review = selected };

    const branch = observations.branch orelse {
        return single(arena, selected, "branch-missing", try std.fmt.allocPrint(arena, "merge blocked: mission {s} branch \"{s}\" does not exist — spawn a worker and complete the mission before merging", .{ mission.id, mission.branch }));
    };

    var unmerged: std.ArrayList(u8) = .empty;
    for (mission.deps) |dep| {
        const dependency = findMission(mission_list, dep) orelse continue;
        if (std.mem.eql(u8, dependency.status, "merged") or std.mem.eql(u8, dependency.status, "abandoned")) continue;
        if (unmerged.items.len > 0) try unmerged.appendSlice(arena, ", ");
        try unmerged.appendSlice(arena, dep);
    }
    if (unmerged.items.len > 0) {
        return single(arena, selected, "deps-unmerged", try std.fmt.allocPrint(arena, "merge blocked: dependencies not merged yet ({s}) — merge in Dependency Flow order", .{unmerged.items}));
    }

    if (std.mem.eql(u8, mission.kind, "survey")) {
        if (branch.changed_files.len > 0) {
            const shown = branch.changed_files[0..@min(5, branch.changed_files.len)];
            return single(arena, selected, "read-only-survey", try std.fmt.allocPrint(arena, "merge blocked: survey mission {s} is read-only but {s} has {d} changed file(s): {s} — investigate the worker; if the changes are worth keeping, move them onto a build mission's branch", .{ mission.id, mission.branch, branch.changed_files.len, try std.mem.join(arena, ", ", shown) }));
        }
        return .{ .ready = blocks.items.len == 0, .noop = blocks.items.len == 0, .blocks = blocks.items, .selected_review = selected };
    }

    if (!branch.base_is_ancestor) {
        return single(arena, selected, "stale-base", try std.fmt.allocPrint(arena, "merge blocked: {s} is behind base \"{s}\" — the base moved after this branch spawned, so merging now could land code that was never built or reviewed against the current base; run TowerRebase(mission=\"{s}\") first (it rebases in the mission worktree, refuses while the worker is mid-turn or the worktree is dirty, and a conflict-free rebase waives the re-review), then retry the merge", .{ mission.branch, base_name, mission.id }));
    }
    const review = selected orelse {
        return single(arena, selected, "no-review", try std.fmt.allocPrint(arena, "merge blocked: {s} has no review — assign a reviewer first", .{mission.branch}));
    };
    if (std.mem.eql(u8, review.merge, "hold")) {
        return single(arena, selected, "review-hold", try std.fmt.allocPrint(arena, "merge blocked: latest applicable review (round {d} by {s}) says hold — do not merge until a later clean review with merge approval supersedes it", .{ review.round, review.reviewer }));
    }
    if (!std.mem.eql(u8, review.status, "clean")) {
        return single(arena, selected, "not-clean", try std.fmt.allocPrint(arena, "merge blocked: latest review (round {d} by {s}) is \"{s}\" — a clean round is required", .{ review.round, review.reviewer, review.status }));
    }
    if (review.merge.len > 0 and !std.mem.eql(u8, review.merge, "merge")) {
        return single(arena, selected, "review-not-approved", try std.fmt.allocPrint(arena, "merge blocked: latest clean review (round {d} by {s}) has merge verdict \"{s}\" — fix-then-merge is not approval; only a clean review with merge verdict \"merge\" can pass", .{ review.round, review.reviewer, review.merge }));
    }
    if (reviewBinding(mission, review, branch.tip) == .stale_tip) {
        return single(arena, selected, "tip-moved", try std.fmt.allocPrint(arena, "merge blocked: {s} moved since the clean review (reviewed {s}, tip {s}) — re-review required", .{ mission.branch, prefix(review.reviewed_commit, 7), prefix(branch.tip, 7) }));
    }
    var sibling_names: std.ArrayList(u8) = .empty;
    for (mission_list) |candidate| {
        if (!std.mem.eql(u8, candidate.branch, mission.branch) or std.mem.eql(u8, candidate.id, mission.id)) continue;
        if (sibling_names.items.len > 0) try sibling_names.appendSlice(arena, ", ");
        try sibling_names.print(arena, "{s} ({s})", .{ candidate.id, candidate.status });
    }
    if (review.mission == null and sibling_names.items.len > 0) {
        return single(arena, selected, "review-mission-mismatch", try std.fmt.allocPrint(arena, "merge blocked: \"{s}\" is shared with other mission record(s) {s}, and the latest clean review (round {d} by {s}) predates mission-stamped reviews — re-review {s} so the gate can tell which mission was audited", .{ mission.branch, sibling_names.items, review.round, review.reviewer, mission.id }));
    }
    var out_of_scope: std.ArrayList(u8) = .empty;
    var out_count: usize = 0;
    for (branch.changed_files) |file| {
        if (matchesAnyScope(file, mission.scope)) continue;
        if (out_count > 0) try out_of_scope.appendSlice(arena, ", ");
        try out_of_scope.appendSlice(arena, file);
        out_count += 1;
    }
    if (out_count > 0) {
        return single(arena, selected, "out-of-scope", try std.fmt.allocPrint(arena, "merge blocked: {s} changed files outside mission {s} scope ({s}): {s} — the tower must widen the mission scope (TowerMission scope patch) or revert those changes", .{ mission.branch, mission.id, try std.mem.join(arena, ", ", mission.scope), out_of_scope.items }));
    }
    if (observations.checked_out_branch == null) {
        return single(arena, selected, "base-mismatch", try std.fmt.allocPrint(arena, "merge blocked: the main checkout is in a detached HEAD state — check out the recorded base branch \"{s}\" before merging; nothing was merged", .{base_name}));
    }
    if (!std.mem.eql(u8, observations.checked_out_branch.?, base_name)) {
        return single(arena, selected, "base-mismatch", try std.fmt.allocPrint(arena, "merge blocked: the main checkout is on \"{s}\", not the recorded base \"{s}\" — switch it back (`git checkout {s}`) and retry, or when development has moved to \"{s}\", re-anchor the workspace to it first (/tower {s}, or TowerInit with base=\"{s}\"); nothing was merged", .{ observations.checked_out_branch.?, base_name, base_name, observations.checked_out_branch.?, observations.checked_out_branch.?, observations.checked_out_branch.? }));
    }
    var dirty_hits: std.ArrayList(u8) = .empty;
    var dirty_count: usize = 0;
    for (branch.merge_touched_files) |file| {
        if (!contains(observations.base_dirty_files, file)) continue;
        if (dirty_count > 0) try dirty_hits.appendSlice(arena, ", ");
        try dirty_hits.appendSlice(arena, file);
        dirty_count += 1;
    }
    if (dirty_count > 0) {
        return single(arena, selected, "base-dirty", try std.fmt.allocPrint(arena, "merge blocked: the main checkout has uncommitted changes in file(s) this merge would overwrite: {s} — commit or stash them first, then retry; nothing was merged", .{dirty_hits.items}));
    }
    return .{ .ready = blocks.items.len == 0, .noop = false, .blocks = blocks.items, .selected_review = selected };
}

const Binding = enum { exact_tip, clean_rebase_waived, stale_tip };

fn reviewBinding(mission: state.Mission, review: Review, tip: []const u8) Binding {
    if (std.mem.eql(u8, review.reviewed_commit, tip)) return .exact_tip;
    if (mission.lastRebase) |waiver| {
        if (std.mem.eql(u8, waiver.fromCommit, review.reviewed_commit) and std.mem.eql(u8, waiver.toCommit, tip)) return .clean_rebase_waived;
    }
    return .stale_tip;
}

fn single(arena: Allocator, selected: ?Review, reason: []const u8, message: []const u8) !Result {
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .reason = reason, .message = message };
    return .{ .ready = false, .noop = false, .blocks = blocks, .selected_review = selected };
}

fn findMission(list: []const state.Mission, id: []const u8) ?state.Mission {
    for (list) |mission| {
        if (std.mem.eql(u8, mission.id, id)) return mission;
    }
    return null;
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn prefix(text: []const u8, length: usize) []const u8 {
    return text[0..@min(length, text.len)];
}

fn matchesAnyScope(file: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (globMatch(pattern, file)) return true;
    }
    return false;
}

pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        var rest = pattern[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        var start: usize = 0;
        while (true) {
            if (globMatch(rest, text[start..])) return true;
            if (start >= text.len) return false;
            start += 1;
        }
    }
    if (pattern[0] == '*') {
        var start: usize = 0;
        while (true) {
            if (globMatch(pattern[1..], text[start..])) return true;
            if (start >= text.len or text[start] == '/') return false;
            start += 1;
        }
    }
    if (text.len == 0) return false;
    if (pattern[0] == '?') {
        if (text[0] == '/') return false;
        return globMatch(pattern[1..], text[1..]);
    }
    if (pattern[0] != text[0]) return false;
    return globMatch(pattern[1..], text[1..]);
}

test "Tower gate glob matches globstar and single star like picomatch" {
    try std.testing.expect(globMatch("src/**", "src/core/tower/gate.zig"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/core/main.zig"));
    try std.testing.expect(!globMatch("docs/*", "src/main.zig"));
    try std.testing.expect(scopes.scopesOverlap(&.{"src/core"}, &.{"src/core/tower"}));
}

test "Tower gate blocks a merge with open tasks before any git observation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tasks = [_]state.Task{.{ .text = "write tests" }};
    const mission = state.Mission{
        .id = "M1",
        .title = "Parser",
        .slug = "parser",
        .branch = "feat/parser",
        .worktree = ".tower/worktrees/wt-1",
        .status = "completed",
        .tasks = &tasks,
    };
    const result = try evaluate(arena, "main", mission, &.{mission}, &.{}, &.{}, .{
        .base_tip = "a",
        .checked_out_branch = "main",
        .base_dirty_files = &.{},
        .branch = null,
    });
    try std.testing.expect(!result.ready);
    try std.testing.expectEqualStrings("open-tasks", result.blocks[0].reason);
}
