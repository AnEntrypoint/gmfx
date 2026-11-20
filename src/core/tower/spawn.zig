const std = @import("std");

const Allocator = std.mem.Allocator;
const profile = @import("profile.zig");
const profiles = @import("../profiles/profiles.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");

pub const Launch = struct {
    host: *subagent_tool_host.Runtime,
    options: subagent_tool_host.ExecuteOptions,
};

pub const Kind = enum { worker, reviewer };

pub const survey_kind = "survey";

pub fn parseKind(text: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, text);
}

pub const WorkerBriefing = struct {
    name: []const u8,
    mission_id: []const u8,
    mission_kind: []const u8,
    mission_text: []const u8,
    worktree: []const u8,
    branch: []const u8,
    base: []const u8,
    spawn_base: ?[]const u8 = null,
    repo_root: []const u8,
    scope: []const []const u8,
    extra: ?[]const u8 = null,
};

pub const ReviewerBriefing = struct {
    name: []const u8,
    target: []const u8,
    base: []const u8,
    repo_root: []const u8,
    mission_text: ?[]const u8 = null,
    extra: ?[]const u8 = null,
};

pub fn workerPrompt(arena: Allocator, briefing: WorkerBriefing) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    const scope = try std.mem.join(arena, ", ", briefing.scope);
    const mission = std.mem.trim(u8, briefing.mission_text, " \t\r\n");
    const survey = std.mem.eql(u8, briefing.mission_kind, survey_kind);

    if (survey) {
        try writer.print("You are \"{s}\", a tower worker agent in a multi-agent workspace, assigned a READ-ONLY survey mission.\n\n", .{briefing.name});
    } else {
        try writer.print("You are \"{s}\", a tower worker agent in a multi-agent workspace.\n\n", .{briefing.name});
    }
    try writer.writeAll("# Your workplace\n");
    try writer.print("- Your private git worktree: {s}\n", .{briefing.worktree});
    try writer.print("- Your branch: {s} (base: {s})\n", .{ briefing.branch, briefing.base });
    if (briefing.spawn_base) |sha| {
        try writer.print("- Your branch starts from snapshot commit {s}: the base checkout's uncommitted changes (WIP), captured at spawn so you can build on them. That commit is your foundation — never revert, amend, or claim it as your own work; your own commits go on top of it.\n", .{sha[0..@min(7, sha.len)]});
    }
    try writer.print(
        "- Your working directory is the main checkout, NOT your worktree — address the worktree explicitly: every Read/Write/Edit/Grep/Glob path must be absolute and under {s}, and every Bash command must `cd {s}` first. A write guard hard-denies any Write or Edit outside it; reads are unrestricted: you may read the main checkout ({s}) or another agent's worktree when coordination calls for it.\n",
        .{ briefing.worktree, briefing.worktree, briefing.repo_root },
    );
    if (survey) {
        try writer.print("- Scope — what you investigate (read-only; reserves nothing): {s}\n\n", .{scope});
    } else {
        try writer.print("- Scope — the only files you may change: {s}\n\n", .{scope});
    }
    try writer.print("# Your mission\n\n{s}\n\n", .{mission});

    if (survey) {
        try writer.writeAll(
            \\# Read-only discipline
            \\- Your scope marks what you investigate, not what you may change. You MUST NOT modify, add, or delete any file in the repo, and your branch must end with zero commits — a changed file makes the merge gate reject your mission as a read-only violation.
            \\- Your deliverables are knowledge: record findings as TowerMission notes, send summaries to the tower and to dependent agents with TowerSend, and file TowerFinding for out-of-scope discoveries.
            \\
            \\# Communication protocol
            \\- Ambiguity is escalated, not guessed: if the mission leaves substantive doubt about what to investigate, TowerSend(to="tower", subject="clarify-request", body=what needs pinning down) BEFORE acting — the tower relays to the human; you never ask the user directly.
            \\
            \\
        );
    } else {
        try writer.writeAll(
            \\# Communication protocol
            \\- Found something notable outside your scope? File it with TowerFinding instead of fixing it.
            \\- Keep your mission current with TowerMission: task_done as you finish tasks, note for decisions, blocker when stuck.
            \\- Ambiguity is escalated, not guessed: if the mission and its Context leave substantive doubt about what to build, TowerSend(to="tower", subject="clarify-request", body=what needs pinning down) BEFORE acting — the tower relays to the human; you never ask the user directly.
            \\
            \\
        );
    }

    if (survey) {
        try writer.writeAll(
            \\# When the survey is done
            \\1. Call TowerInbox once and fold anything new into your summary — TowerComplete refuses while unread messages wait in your inbox.
            \\2. Call TowerComplete(report=the full survey result). It records completed and stores survey-summary to the tower in one protocol flow — do not substitute a TowerMission status patch or a manual TowerSend.
            \\3. Finish with a structured final summary: what you covered, key facts with file:line references, open questions.
            \\
        );
    } else {
        try writer.print(
            \\# When the mission is done
            \\1. `git add` + `git commit` your mission's changes in the worktree (source files only — no build outputs).
            \\2. Before completing, call TowerInbox once and incorporate anything new into the delivery — TowerComplete refuses while unread messages wait in your inbox. Re-read your mission too (TowerMission(id="{s}") with no patch fields): the tower may have changed its tasks mid-flight.
            \\3. Call TowerComplete(report=what you changed and why, reconciled against the mission tasks item by item — the reviewer maps each task to your diff). It records completed and stores review-request to the tower in one protocol flow — do not substitute a TowerMission status patch or a manual TowerSend.
            \\4. Finish with a structured final summary: files changed, key decisions, open follow-ups.
            \\
        , .{briefing.mission_id});
    }
    try writeExtra(writer, briefing.extra);
    return out.toOwnedSlice();
}

pub fn reviewerPrompt(arena: Allocator, briefing: ReviewerBriefing) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.print("You are \"{s}\", a tower reviewer agent in a multi-agent workspace.\n\n", .{briefing.name});
    try writer.writeAll("# Your assignment\n");
    try writer.print("Review branch \"{s}\" against base \"{s}\".\n", .{ briefing.target, briefing.base });
    try writer.print(
        "- Work read-only in the main checkout ({s}): `git diff {s}...{s}`, `git log {s}..{s}`, and read files as needed.\n- Do NOT modify any code.\n\n",
        .{ briefing.repo_root, briefing.base, briefing.target, briefing.base, briefing.target },
    );
    if (briefing.mission_text) |mission| {
        try writer.print(
            "# Mission under review — verify the diff against this intent, not only against code health\n\n{s}\n\n",
            .{std.mem.trim(u8, mission, " \t\r\n")},
        );
        try writer.writeAll(
            \\# Review checklist (in priority order)
            \\1. Intent — does the diff deliver the mission above? Map every task to the changes; healthy code that answers the wrong requirement or silently drops a task is a finding, not a pass.
            \\2. Security
            \\3. Data integrity
            \\4. Performance
            \\5. Error handling
            \\6. Code quality
            \\
            \\
        );
    } else {
        try writer.writeAll(
            \\# Review checklist (in priority order)
            \\1. Security
            \\2. Data integrity
            \\3. Performance
            \\4. Error handling
            \\5. Code quality
            \\
            \\
        );
    }
    try writer.print(
        \\# When done — TowerReview is the only mandatory protocol step
        \\1. Submit your verdict with TowerReview: {{ target: "{s}", status: "clean" | "p1-Nitems" | "p2-Nitems", merge: "merge" | "fix-then-merge" | "hold", findings, checks, decision }}. Only a clean review with merge verdict "merge" on the exact branch tip lets the tower merge. Standard review-result notifications are stored automatically — do not send a second manual TowerSend.
        \\Then finish with a structured summary of the review.
        \\
    , .{briefing.target});
    try writeExtra(writer, briefing.extra);
    return out.toOwnedSlice();
}

fn writeExtra(writer: *std.Io.Writer, extra: ?[]const u8) std.Io.Writer.Error!void {
    const text = std.mem.trim(u8, extra orelse return, " \t\r\n");
    if (text.len == 0) return;
    try writer.print("\n# Additional instructions from the tower\n{s}\n", .{text});
}

test "Tower spawn kinds are worker and reviewer only" {
    try std.testing.expectEqual(Kind.worker, parseKind("worker").?);
    try std.testing.expectEqual(Kind.reviewer, parseKind("reviewer").?);
    try std.testing.expect(parseKind("Worker") == null);
    try std.testing.expect(parseKind("") == null);
}

test "Tower worker prompt names the worktree, branch, scope and mission" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scope = [_][]const u8{ "src/core/tower", "src/tools/tower" };
    const prompt = try workerPrompt(arena, .{
        .name = "agent-build",
        .mission_id = "M1",
        .mission_kind = "build",
        .mission_text = "  # M1 Parser\n\nWrite the parser.  ",
        .worktree = "/repo/.tower/worktrees/wt-1",
        .branch = "feat/parser",
        .base = "main",
        .repo_root = "/repo",
        .scope = &scope,
        .extra = "Keep the diff small.",
    });
    try std.testing.expect(std.mem.indexOf(u8, prompt, "You are \"agent-build\", a tower worker agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Your private git worktree: /repo/.tower/worktrees/wt-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Your branch: feat/parser (base: main)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Scope — the only files you may change: src/core/tower, src/tools/tower") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# M1 Parser\n\nWrite the parser.\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TowerMission(id=\"M1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Additional instructions from the tower\nKeep the diff small.\n") != null);
}

test "Tower survey prompt is read-only and has no worker completion step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scope = [_][]const u8{"src/core/**"};
    const prompt = try workerPrompt(arena, .{
        .name = "scout",
        .mission_id = "M2",
        .mission_kind = survey_kind,
        .mission_text = "Map the spawn path.",
        .worktree = "/repo/.tower/worktrees/wt-2",
        .branch = "feat/scout",
        .base = "main",
        .repo_root = "/repo",
        .scope = &scope,
    });
    try std.testing.expect(std.mem.indexOf(u8, prompt, "assigned a READ-ONLY survey mission") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Scope — what you investigate (read-only; reserves nothing): src/core/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# When the survey is done") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# When the mission is done") == null);
}

test "Tower role text reaches a child once, through its profile system prompt, not its first message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const worker = profiles.builtin(profiles.tower_worker_name).?;
    const system = try profiles.systemPrompt(arena, &worker, "base prompt");
    const scope = [_][]const u8{"src/core/tower"};
    const prompt = try workerPrompt(arena, .{
        .name = "agent-build",
        .mission_id = "M1",
        .mission_kind = "build",
        .mission_text = "Write the parser.",
        .worktree = "/repo/.tower/worktrees/wt-1",
        .branch = "feat/parser",
        .base = "main",
        .repo_root = "/repo",
        .scope = &scope,
    });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, prompt, profile.role));
    const child_text = try std.mem.concat(arena, u8, &.{ system, "\n\n", prompt });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, child_text, profile.role));
}

test "Tower worker prompt carries the spawn base when the branch starts from a snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scope = [_][]const u8{"src/core/tower"};
    const prompt = try workerPrompt(arena, .{
        .name = "agent-build",
        .mission_id = "M1",
        .mission_kind = "build",
        .mission_text = "Write the parser.",
        .worktree = "/repo/.tower/worktrees/wt-1",
        .branch = "feat/parser",
        .base = "main",
        .spawn_base = "0123456789abcdef",
        .repo_root = "/repo",
        .scope = &scope,
    });
    try std.testing.expect(std.mem.indexOf(u8, prompt, profile.role) == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Your branch starts from snapshot commit 0123456: the base checkout's uncommitted changes (WIP)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "A write guard hard-denies any Write or Edit outside it") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Communication protocol") != null);
}

test "Tower reviewer prompt carries the target, base and the checklist for the kind of review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bare = try reviewerPrompt(arena, .{
        .name = "rev-a",
        .target = "feat/parser",
        .base = "main",
        .repo_root = "/repo",
    });
    try std.testing.expect(std.mem.indexOf(u8, bare, "Review branch \"feat/parser\" against base \"main\".") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "git diff main...feat/parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "1. Security\n2. Data integrity") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "TowerReview: { target: \"feat/parser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "# Mission under review") == null);

    const with_mission = try reviewerPrompt(arena, .{
        .name = "rev-b",
        .target = "feat/parser",
        .base = "main",
        .repo_root = "/repo",
        .mission_text = "Parse tokens.",
    });
    try std.testing.expect(std.mem.indexOf(u8, with_mission, "# Mission under review — verify the diff against this intent") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_mission, "1. Intent — does the diff deliver the mission above?") != null);
}
