const std = @import("std");
const io_mod = @import("../shared/io.zig");
const paths = @import("paths.zig");
const state = @import("state.zig");
const frontmatter = @import("frontmatter.zig");
const git = @import("git.zig");
const scopes = @import("scopes.zig");
const render = @import("render.zig");

const Allocator = std.mem.Allocator;

pub const max_file_bytes: usize = 4 * 1024 * 1024;
pub const max_review_rounds: usize = 5;
pub const mission_title_slug_len: usize = 40;

pub const not_initialized_message = "tower is not initialized in this repository — run TowerInit first";
pub const state_lost_message = "tower state was lost: .tower/comms/state.json is missing — run TowerInit to start a new workspace";
pub const state_unreadable_message = "tower state file .tower/comms/state.json could not be parsed";
pub const not_repository_message = "tower requires a git repository";
pub const no_commits_message = "the repository has no commits yet — create an initial commit first";
pub const detached_base_message = "cannot determine the base branch from a detached HEAD — pass the base branch explicitly";
pub const plan_empty_message = "TowerPlan needs at least one mission";
pub const complete_empty_message = "TowerComplete report must not be empty";
pub const complete_caller_message = "cannot use TowerComplete — only the worker who owns a mission can complete it";
pub const self_send_message = "cannot send an inbox message to yourself";
pub const review_status_pattern_message = "review status must be clean, p1-<n>items or p2-<n>items";
pub const review_merge_message = "review merge must be merge, fix-then-merge or hold";

pub const Store = struct {
    root: []const u8,
    refusal: []const u8 = "",

    pub fn refuse(self: *Store, message: []const u8) error{TowerRefused} {
        self.refusal = message;
        return error.TowerRefused;
    }

    pub fn absolute(self: Store, arena: Allocator, rel: []const u8) ![]u8 {
        const root = if (std.Io.Dir.path.isAbsolute(self.root)) self.root else try std.Io.Dir.path.join(arena, &.{ try std.process.currentPathAlloc(io_mod.getIo(), arena), self.root });
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
    }

    pub fn readRel(self: Store, arena: Allocator, rel: []const u8) !?[]u8 {
        const path = try self.absolute(arena, rel);
        return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    pub fn writeRel(self: Store, arena: Allocator, rel: []const u8, text: []const u8) !void {
        const path = try self.absolute(arena, rel);
        if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), parent);
        try io_mod.writeFileAtomic(arena, path, text);
    }

    pub fn dirExists(self: Store, arena: Allocator, rel: []const u8) bool {
        const path = self.absolute(arena, rel) catch return false;
        var dir = std.Io.Dir.cwd().openDir(io_mod.getIo(), path, .{}) catch return false;
        dir.close(io_mod.getIo());
        return true;
    }

    pub fn isInitialized(self: Store, arena: Allocator) bool {
        const bytes = self.readRel(arena, paths.state_file) catch return false;
        return bytes != null;
    }

    pub fn appendLog(self: Store, arena: Allocator, now_ms: i64, actor: []const u8, action: []const u8, details: []const u8) !void {
        const existing: []const u8 = (try self.readRel(arena, paths.activity_log)) orelse "";
        const stamp = try paths.isoTimestamp(arena, now_ms);
        const line = try std.fmt.allocPrint(arena, "{s} {s} {s}{s}\n", .{ stamp, actor, action, details });
        const text = try std.mem.concat(arena, u8, &.{ existing, line });
        try self.writeRel(arena, paths.activity_log, text);
    }

    pub fn load(self: *Store, arena: Allocator) !state.State {
        const bytes = (try self.readRel(arena, paths.state_file)) orelse {
            if (self.dirExists(arena, paths.tower_root)) return self.refuse(state_lost_message);
            return self.refuse(not_initialized_message);
        };
        return state.decode(arena, bytes) catch self.refuse(state_unreadable_message);
    }

    pub fn save(self: Store, arena: Allocator, st: state.State) !void {
        try self.writeRel(arena, paths.state_file, try state.encode(arena, st));
    }

    pub fn saveRendered(self: Store, arena: Allocator, st: state.State) !void {
        try self.save(arena, st);
        try self.writeRel(arena, paths.missions_index, try render.missionsIndex(arena, st));
        for (st.missions) |mission| {
            const file = try paths.missionFileName(arena, mission.id, mission.slug);
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.missions_dir, file });
            try self.writeRel(arena, rel, try render.missionFile(arena, mission));
        }
    }

    pub fn ensureDirectories(self: Store, arena: Allocator) !void {
        const dirs = [_][]const u8{
            paths.inbox_dir,    paths.findings_dir, paths.reviews_dir,
            paths.missions_dir, paths.log_dir,      paths.worktrees_dir,
        };
        for (dirs) |rel| {
            const path = try self.absolute(arena, rel);
            try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), path);
        }
    }

    pub fn repositoryCheck(self: *Store, arena: Allocator) !void {
        const inside = git.run(arena, self.root, &.{ "rev-parse", "--is-inside-work-tree" }) catch return self.refuse(not_repository_message);
        if (!std.mem.eql(u8, inside, "true")) return self.refuse(not_repository_message);
        const commits = git.run(arena, self.root, &.{ "rev-list", "-n", "1", "--all" }) catch return self.refuse(no_commits_message);
        if (commits.len == 0) return self.refuse(no_commits_message);
    }

    pub const InitResult = struct {
        created: bool,
        base: []const u8,
    };

    pub fn init(self: *Store, arena: Allocator, requested_base: ?[]const u8, now_ms: i64) !InitResult {
        try self.repositoryCheck(arena);
        if (self.isInitialized(arena)) {
            const existing = try self.load(arena);
            return .{ .created = false, .base = existing.base };
        }
        const base = if (requested_base) |name| blk: {
            if (!(try git.branchExists(arena, self.root, name))) {
                return self.refuse(try std.fmt.allocPrint(arena, "base branch \"{s}\" does not exist as a local branch", .{name}));
            }
            break :blk name;
        } else git.currentBranch(arena, self.root) catch return self.refuse(detached_base_message);

        try self.ensureDirectories(arena);
        try self.excludeTowerRoot(arena);
        const created_at = try paths.isoTimestamp(arena, now_ms);
        const st = state.State{ .base = base, .createdAt = created_at };
        try self.saveRendered(arena, st);
        try self.writeRel(arena, paths.activity_log, "");
        try self.appendLog(arena, now_ms, "tower", "init", try std.fmt.allocPrint(arena, " base={s}", .{base}));
        return .{ .created = true, .base = base };
    }

    fn excludeTowerRoot(self: Store, arena: Allocator) !void {
        const exclude_rel = git.run(arena, self.root, &.{ "rev-parse", "--git-path", "info/exclude" }) catch return;
        const exclude_path = if (std.Io.Dir.path.isAbsolute(exclude_rel)) exclude_rel else try self.absolute(arena, exclude_rel);
        const existing: []const u8 = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), exclude_path, arena, .limited(max_file_bytes)) catch "";
        if (std.mem.indexOf(u8, existing, paths.tower_root ++ "/") != null) return;
        const separator = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
        const updated = try std.fmt.allocPrint(arena, "{s}{s}{s}/\n", .{ existing, separator, paths.tower_root });
        try io_mod.writeFileAtomic(arena, exclude_path, updated);
    }

    pub const PlanItem = struct {
        title: []const u8,
        scope: []const []const u8,
        tasks: []const []const u8 = &.{},
        context: ?[]const u8 = null,
        deps: []const []const u8 = &.{},
        kind: []const u8 = "build",
    };

    pub fn plan(self: *Store, arena: Allocator, items: []const PlanItem, now_ms: i64) ![]const state.Mission {
        if (items.len == 0) return self.refuse(plan_empty_message);
        var st = try self.load(arena);
        const base_count = st.missions.len;
        var list: std.ArrayList(state.Mission) = .empty;
        try list.appendSlice(arena, st.missions);
        for (items, 0..) |item, index| {
            if (paths.hasNonAsciiCharacters(item.title)) {
                return self.refuse(try std.fmt.allocPrint(arena, "mission title \"{s}\" contains non-ASCII characters", .{item.title}));
            }
            const number = base_count + index + 1;
            const id = try std.fmt.allocPrint(arena, "M{d}", .{number});
            const slug = try paths.slugify(arena, item.title, mission_title_slug_len);
            const branch = try std.fmt.allocPrint(arena, "feat/{s}", .{slug});
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing.branch, branch)) {
                    return self.refuse(try std.fmt.allocPrint(arena, "branch \"{s}\" is already used by mission {s}", .{ branch, existing.id }));
                }
            }
            if (try git.branchExists(arena, self.root, branch)) {
                return self.refuse(try std.fmt.allocPrint(arena, "branch \"{s}\" already exists in git but is not owned by any tower mission", .{branch}));
            }
            var deps: std.ArrayList([]const u8) = .empty;
            for (item.deps) |dep| {
                if (findIn(list.items, dep) == null) {
                    return self.refuse(try std.fmt.allocPrint(arena, "mission {s} depends on unknown mission {s}", .{ id, dep }));
                }
                try deps.append(arena, dep);
            }
            const tasks = try arena.alloc(state.Task, item.tasks.len);
            for (item.tasks, 0..) |text, task_index| tasks[task_index] = .{ .text = text };
            try list.append(arena, .{
                .id = id,
                .title = item.title,
                .slug = slug,
                .kind = item.kind,
                .scope = item.scope,
                .branch = branch,
                .worktree = try std.fmt.allocPrint(arena, "{s}/wt-{d}", .{ paths.worktrees_dir, number }),
                .deps = try deps.toOwnedSlice(arena),
                .context = item.context,
                .tasks = tasks,
            });
        }
        try addAutoDeps(arena, list.items, base_count);
        if (try self.scopeConflict(arena, list.items)) |message| return self.refuse(message);
        st.missions = try list.toOwnedSlice(arena);
        try self.saveRendered(arena, st);
        try self.appendLog(arena, now_ms, "tower", "plan", try std.fmt.allocPrint(arena, " missions={d}", .{items.len}));
        return st.missions[base_count..];
    }

    fn scopeConflict(self: Store, arena: Allocator, list: []state.Mission) !?[]const u8 {
        _ = self;
        for (list) |mission| {
            if (std.mem.eql(u8, mission.kind, "survey")) continue;
            for (mission.scope) |raw| {
                if (scopes.scopeStem(raw).len == 0) {
                    return try std.fmt.allocPrint(arena, "mission {s} scope \"{s}\" covers the whole repo — narrow it down", .{ mission.id, raw });
                }
            }
        }
        for (list, 0..) |a, i| {
            if (std.mem.eql(u8, a.kind, "survey") or isClosed(a)) continue;
            for (list[i + 1 ..]) |b| {
                if (std.mem.eql(u8, b.kind, "survey") or isClosed(b)) continue;
                if (!scopesOverlapMissions(a, b)) continue;
                if (depPathExists(list, a.id, b.id) or depPathExists(list, b.id, a.id)) continue;
                return try std.fmt.allocPrint(arena, "mission scopes overlap: {s} vs {s} without a dependency between them — split the shared files into exactly one mission, or wire a dependency so the merges serialize", .{ a.id, b.id });
            }
        }
        return null;
    }

    pub const Patch = struct {
        note: ?[]const u8 = null,
        blocker: ?[]const u8 = null,
        clear_blockers: bool = false,
        status: ?[]const u8 = null,
        task_done: ?[]const u8 = null,
        task_drop: ?[]const u8 = null,
        task_drop_reason: ?[]const u8 = null,
        scope: ?[]const []const u8 = null,
    };

    pub fn isEmptyPatch(patch: Patch) bool {
        return patch.note == null and patch.blocker == null and !patch.clear_blockers and patch.status == null and
            patch.task_done == null and patch.task_drop == null and patch.scope == null;
    }

    pub fn patchMission(self: *Store, arena: Allocator, id: []const u8, patch: Patch, now_ms: i64) !state.Mission {
        var st = try self.load(arena);
        const mission = st.findMission(id) orelse {
            var known: std.ArrayList(u8) = .empty;
            for (st.missions) |item| {
                if (known.items.len > 0) try known.appendSlice(arena, ", ");
                try known.appendSlice(arena, item.id);
            }
            return self.refuse(try std.fmt.allocPrint(arena, "unknown mission \"{s}\" — known missions: {s}", .{ id, known.items }));
        };
        if (patch.status) |status| {
            if (std.mem.eql(u8, status, "merged")) return self.refuse("cannot transition to merged through a generic mission patch");
            if (isClosed(mission.*) and !std.mem.eql(u8, status, mission.status)) {
                return self.refuse(try std.fmt.allocPrint(arena, "mission {s} is {s} — merged and abandoned are terminal", .{ id, mission.status }));
            }
        }
        if (patch.blocker != null and isClosed(mission.*)) {
            return self.refuse(try std.fmt.allocPrint(arena, "mission {s} is {s} — merged and abandoned are terminal", .{ id, mission.status }));
        }
        if (patch.note) |note| mission.notes = try appendOne(arena, mission.notes, note);
        if (patch.clear_blockers) mission.blockers = &.{};
        if (patch.blocker) |blocker| {
            mission.blockers = try appendOne(arena, mission.blockers, blocker);
            mission.status = "blocked";
        }
        if (patch.task_done) |needle| {
            const task = firstOpenTask(mission.tasks, needle) orelse
                return self.refuse(try std.fmt.allocPrint(arena, "mission {s} has no open task matching \"{s}\"", .{ id, needle }));
            task.done = true;
        }
        if (patch.task_drop) |needle| {
            const reason = patch.task_drop_reason orelse return self.refuse("dropping a task requires a reason");
            const task = firstOpenTask(mission.tasks, needle) orelse
                return self.refuse(try std.fmt.allocPrint(arena, "mission {s} has no open task matching \"{s}\"", .{ id, needle }));
            task.dropped = true;
            mission.notes = try appendOne(arena, mission.notes, try std.fmt.allocPrint(arena, "dropped task \"{s}\": {s}", .{ task.text, reason }));
        }
        if (patch.scope) |scope| {
            mission.scope = scope;
            if (try self.scopeConflict(arena, st.missions)) |message| return self.refuse(message);
        }
        if (patch.status) |status| {
            if (std.mem.eql(u8, status, "completed") and patch.blocker == null) {
                try self.assertCompletable(arena, mission.*);
            }
            mission.status = status;
        }
        const copy = mission.*;
        try self.saveRendered(arena, st);
        try self.appendLog(arena, now_ms, "tower", "mission.update", try std.fmt.allocPrint(arena, " mission={s}", .{id}));
        return copy;
    }

    fn assertCompletable(self: *Store, arena: Allocator, mission: state.Mission) !void {
        var open: usize = 0;
        for (mission.tasks) |task| {
            if (!task.done and task.dropped != true) open += 1;
        }
        if (open > 0) return self.refuse(try std.fmt.allocPrint(arena, "mission {s} has {d} open task(s)", .{ mission.id, open }));
        if (mission.blockers.len > 0) return self.refuse(try std.fmt.allocPrint(arena, "mission {s} has {d} blocker(s)", .{ mission.id, mission.blockers.len }));
    }

    pub fn recipientExists(st: state.State, name: []const u8) bool {
        if (std.mem.eql(u8, name, paths.tower_name) or std.mem.eql(u8, name, paths.broadcast_name)) return true;
        for (st.roster.agents) |agent| {
            if (std.mem.eql(u8, agent.name, name)) return true;
        }
        return false;
    }

    pub const SendInput = struct {
        to: []const u8,
        subject: []const u8,
        body: []const u8,
        scope: ?[]const u8 = null,
        action: ?[]const u8 = null,
        consent_ref: ?[]const u8 = null,
    };

    pub fn send(self: *Store, arena: Allocator, input: SendInput, now_ms: i64) ![]const u8 {
        const st = try self.load(arena);
        if (std.mem.eql(u8, input.to, paths.tower_name)) return self.refuse(self_send_message);
        if (!recipientExists(st, input.to)) {
            return self.refuse(try std.fmt.allocPrint(arena, "unknown recipient \"{s}\"", .{input.to}));
        }
        const stamp = try paths.dateStamp(arena, now_ms);
        const file_name = try paths.inboxFileName(arena, stamp, paths.tower_name, input.to, input.subject);
        var pairs: std.ArrayList(frontmatter.Pair) = .empty;
        try pairs.appendSlice(arena, &.{
            .{ .key = "type", .value = "inbox" },
            .{ .key = "message_id", .value = try newMessageId(arena) },
            .{ .key = "from", .value = paths.tower_name },
            .{ .key = "to", .value = input.to },
            .{ .key = "subject", .value = input.subject },
            .{ .key = "sent_at", .value = try paths.isoTimestamp(arena, now_ms) },
        });
        if (input.scope) |value| try pairs.append(arena, .{ .key = "scope", .value = value });
        if (input.action) |value| try pairs.append(arena, .{ .key = "action", .value = value });
        if (input.consent_ref) |value| try pairs.append(arena, .{ .key = "consent_ref", .value = value });
        const header = try frontmatter.render(arena, pairs.items);
        const text = try std.fmt.allocPrint(arena, "{s}\n\n{s}\n", .{ header, std.mem.trim(u8, input.body, " \t\r\n") });
        const rel = try writeUnique(self.*, arena, paths.inbox_dir, file_name, text);
        try self.appendLog(arena, now_ms, "tower", "inbox.send", try std.fmt.allocPrint(arena, " to={s} ref={s}", .{ input.to, rel }));
        return rel;
    }

    pub const Message = struct {
        file: []const u8,
        message_id: []const u8,
        from: []const u8,
        to: []const u8,
        subject: []const u8,
        sent_at: []const u8,
        scope: ?[]const u8,
        action: ?[]const u8,
        consent_ref: ?[]const u8,
        body: []const u8,
    };

    pub fn listInbox(self: *Store, arena: Allocator) ![]Message {
        var out: std.ArrayList(Message) = .empty;
        const path = try self.absolute(arena, paths.inbox_dir);
        var dir = std.Io.Dir.cwd().openDir(io_mod.getIo(), path, .{ .iterate = true }) catch return out.items;
        defer dir.close(io_mod.getIo());
        var it = dir.iterate();
        while (try it.next(io_mod.getIo())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
            const bytes = dir.readFileAlloc(io_mod.getIo(), entry.name, arena, .limited(max_file_bytes)) catch continue;
            const parsed = try frontmatter.parse(arena, bytes);
            if (!std.mem.eql(u8, parsed.get("type") orelse "", "inbox")) continue;
            const to = parsed.get("to") orelse continue;
            if (!std.mem.eql(u8, to, paths.tower_name) and !std.mem.eql(u8, to, paths.broadcast_name)) continue;
            const id = parsed.get("message_id") orelse "";
            try out.append(arena, .{
                .file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.inbox_dir, entry.name }),
                .message_id = id,
                .from = parsed.get("from") orelse "",
                .to = to,
                .subject = parsed.get("subject") orelse "",
                .sent_at = parsed.get("sent_at") orelse "",
                .scope = parsed.get("scope"),
                .action = parsed.get("action"),
                .consent_ref = parsed.get("consent_ref"),
                .body = parsed.body,
            });
        }
        std.mem.sort(Message, out.items, {}, newerFirst);
        return out.items;
    }

    pub fn ackInbox(self: *Store, arena: Allocator, ids: []const []const u8, now_ms: i64) !usize {
        _ = now_ms;
        var st = try self.load(arena);
        var acked: std.ArrayList([]const u8) = .empty;
        if (st.inboxAckIds) |existing| try acked.appendSlice(arena, existing);
        var grew = false;
        for (ids) |id| {
            if (containsString(acked.items, id)) continue;
            try acked.append(arena, id);
            grew = true;
        }
        if (grew) {
            st.inboxAckIds = try acked.toOwnedSlice(arena);
            try self.save(arena, st);
        }
        return unreadCount(st, try self.listInbox(arena));
    }

    pub fn unreadCount(st: state.State, messages: []const Message) usize {
        var count: usize = 0;
        for (messages) |message| {
            if (st.inboxAckIds == null or !containsString(st.inboxAckIds.?, message.message_id)) count += 1;
        }
        return count;
    }

    pub const FindingInput = struct {
        finding_type: []const u8,
        title: []const u8,
        severity: ?[]const u8 = null,
        summary: []const u8,
        location: ?[]const u8 = null,
        details: []const u8,
        suggested_fix: []const u8,
    };

    pub fn fileFinding(self: *Store, arena: Allocator, input: FindingInput, now_ms: i64) ![]const u8 {
        const valid_types = [_][]const u8{ "bug", "improve", "vuln", "idea" };
        if (!containsString(&valid_types, input.finding_type)) {
            return self.refuse("finding type must be one of bug, improve, vuln, idea");
        }
        const stamp = try paths.dateStamp(arena, now_ms);
        const file_name = try paths.findingFileName(arena, stamp, paths.tower_name, input.finding_type, input.title);
        const severity = input.severity orelse "medium";
        const location = input.location orelse "(not specified)";
        const text = try std.fmt.allocPrint(
            arena,
            "# Finding: {s}\n\n**Date**: {s}\n**Agent**: {s}\n**Type**: {s}\n**Severity**: {s}\n**Mission**: (none)\n\n## Summary\n\n{s}\n\n## Location\n\n{s}\n\n## Details\n\n{s}\n\n## Suggested Fix / Action\n\n{s}\n",
            .{ input.title, stamp, paths.tower_name, input.finding_type, severity, input.summary, location, input.details, input.suggested_fix },
        );
        const rel = try writeUnique(self.*, arena, paths.findings_dir, file_name, text);
        try self.appendLog(arena, now_ms, "tower", "finding.file", try std.fmt.allocPrint(arena, " ref={s}", .{rel}));
        return rel;
    }

    pub const ReviewInput = struct {
        target: []const u8,
        status: []const u8,
        merge: []const u8,
        findings: []const u8,
        checks: []const []const u8 = &.{},
        decision: []const u8,
    };

    pub fn submitReview(self: *Store, arena: Allocator, input: ReviewInput, reviewed_commit: []const u8, now_ms: i64) ![]const u8 {
        if (!validReviewStatus(input.status)) return self.refuse(review_status_pattern_message);
        if (!std.mem.eql(u8, input.merge, "merge") and !std.mem.eql(u8, input.merge, "fix-then-merge") and !std.mem.eql(u8, input.merge, "hold")) {
            return self.refuse(review_merge_message);
        }
        var st = try self.load(arena);
        const reviewer = paths.tower_name;
        const existing = try listReviews(self.*, arena, st);
        var rounds: usize = 0;
        var seq: u32 = 0;
        for (existing) |review| {
            seq = @max(seq, review.seq);
            if (std.mem.eql(u8, review.reviewer, reviewer) and std.mem.eql(u8, review.target, input.target)) rounds += 1;
        }
        if (rounds >= max_review_rounds) {
            return self.refuse(try std.fmt.allocPrint(arena, "{s} has already been through {d} review rounds on {s}", .{ reviewer, max_review_rounds, input.target }));
        }
        const round = rounds + 1;
        const mission_id = resolveOpenMissionByBranch(st.missions, input.target);
        const date = try paths.dateDash(arena, now_ms);
        const file_name = try paths.reviewFileName(arena, input.target, reviewer, @intCast(round));

        var pairs: std.ArrayList(frontmatter.Pair) = .empty;
        try pairs.appendSlice(arena, &.{
            .{ .key = "date", .value = date },
            .{ .key = "reviewer", .value = reviewer },
            .{ .key = "target", .value = input.target },
            .{ .key = "round", .value = try std.fmt.allocPrint(arena, "{d}", .{round}) },
            .{ .key = "seq", .value = try std.fmt.allocPrint(arena, "{d}", .{seq + 1}) },
            .{ .key = "status", .value = input.status },
            .{ .key = "merge", .value = input.merge },
            .{ .key = "reviewed_commit", .value = reviewed_commit },
        });
        if (mission_id) |id| try pairs.append(arena, .{ .key = "mission", .value = id });
        var checks: std.ArrayList(u8) = .empty;
        for (input.checks) |check| try checks.print(arena, "- [x] {s}\n", .{check});
        if (input.checks.len == 0) try checks.appendSlice(arena, "- [x] (reviewer reported no formal checks)\n");
        const header = try frontmatter.render(arena, pairs.items);
        const text = try std.fmt.allocPrint(arena, "{s}\n\n## Findings\n\n{s}\n\n## Checks\n\n{s}\n## Decision\n\n{s}\n", .{ header, input.findings, checks.items, input.decision });
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.reviews_dir, file_name });
        try self.writeRel(arena, rel, text);
        if (!std.mem.eql(u8, input.status, "clean")) {
            if (mission_id) |id| {
                if (st.findMission(id)) |mission| {
                    if (std.mem.eql(u8, mission.status, "completed")) {
                        mission.status = "active";
                        try self.saveRendered(arena, st);
                        try self.appendLog(arena, now_ms, reviewer, "mission.rework", try std.fmt.allocPrint(arena, " mission={s}", .{id}));
                    }
                }
            }
        }
        try self.appendLog(arena, now_ms, reviewer, "review.write", try std.fmt.allocPrint(arena, " ref={s}", .{rel}));
        return rel;
    }

    pub fn completeMission(self: *Store, report: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, report, " \t\r\n");
        if (trimmed.len == 0) return self.refuse(complete_empty_message);
        return self.refuse(complete_caller_message);
    }

    pub fn reviewsFor(self: *Store, arena: Allocator, target: []const u8) ![]ReviewRecord {
        const st = try self.load(arena);
        const all = try listReviews(self.*, arena, st);
        var out: std.ArrayList(ReviewRecord) = .empty;
        for (all) |review| {
            if (std.mem.eql(u8, review.target, target)) try out.append(arena, review);
        }
        return out.items;
    }

    pub const ReviewRecord = struct {
        reviewer: []const u8,
        target: []const u8,
        round: u32,
        status: []const u8,
        merge: []const u8,
        reviewed_commit: []const u8,
        mission: ?[]const u8,
        seq: u32,
    };

    pub fn writeTextOnce(self: Store, arena: Allocator, rel: []const u8, text: []const u8) !void {
        try self.writeRel(arena, rel, text);
    }
};

fn listReviews(store: Store, arena: Allocator, st: state.State) ![]Store.ReviewRecord {
    _ = st;
    var out: std.ArrayList(Store.ReviewRecord) = .empty;
    const path = try store.absolute(arena, paths.reviews_dir);
    var dir = std.Io.Dir.cwd().openDir(io_mod.getIo(), path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io_mod.getIo());
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const bytes = dir.readFileAlloc(io_mod.getIo(), entry.name, arena, .limited(max_file_bytes)) catch continue;
        const parsed = try frontmatter.parse(arena, bytes);
        try out.append(arena, .{
            .reviewer = parsed.get("reviewer") orelse continue,
            .target = parsed.get("target") orelse continue,
            .round = std.fmt.parseInt(u32, parsed.get("round") orelse "0", 10) catch 0,
            .status = parsed.get("status") orelse "",
            .merge = parsed.get("merge") orelse "",
            .reviewed_commit = parsed.get("reviewed_commit") orelse "",
            .mission = parsed.get("mission"),
            .seq = std.fmt.parseInt(u32, parsed.get("seq") orelse "0", 10) catch 0,
        });
    }
    std.mem.sort(Store.ReviewRecord, out.items, {}, reviewOlderFirst);
    return out.items;
}

fn reviewOlderFirst(_: void, a: Store.ReviewRecord, b: Store.ReviewRecord) bool {
    return a.seq < b.seq;
}

fn newerFirst(_: void, a: Store.Message, b: Store.Message) bool {
    return std.mem.order(u8, a.sent_at, b.sent_at) == .gt;
}

fn validReviewStatus(status: []const u8) bool {
    if (std.mem.eql(u8, status, "clean")) return true;
    if (status.len < 9) return false;
    if (!std.mem.startsWith(u8, status, "p1-") and !std.mem.startsWith(u8, status, "p2-")) return false;
    if (!std.mem.endsWith(u8, status, "items")) return false;
    const digits = status[3 .. status.len - "items".len];
    if (digits.len == 0) return false;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn writeUnique(store: Store, arena: Allocator, dir_rel: []const u8, file_name: []const u8, text: []const u8) ![]const u8 {
    const stem = file_name[0 .. file_name.len - 3];
    var attempt: usize = 1;
    while (attempt <= 100) : (attempt += 1) {
        const name = if (attempt == 1)
            try std.fmt.allocPrint(arena, "{s}.md", .{stem})
        else
            try std.fmt.allocPrint(arena, "{s}-{d}.md", .{ stem, attempt });
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, name });
        if ((try store.readRel(arena, rel)) != null) continue;
        try store.writeRel(arena, rel, text);
        return rel;
    }
    return error.TooManyCollisions;
}

fn newMessageId(arena: Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    io_mod.getIo().random(&bytes);
    return std.fmt.allocPrint(arena, "{x}", .{std.mem.readInt(u64, &bytes, .little)});
}

fn containsString(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn appendOne(arena: Allocator, list: []const []const u8, value: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = value;
    return out;
}

fn firstOpenTask(tasks: []state.Task, needle: []const u8) ?*state.Task {
    for (tasks) |*task| {
        if (task.done or task.dropped == true) continue;
        if (std.mem.indexOf(u8, task.text, needle) != null) return task;
    }
    return null;
}

fn findIn(list: []const state.Mission, id: []const u8) ?usize {
    for (list, 0..) |mission, index| {
        if (std.mem.eql(u8, mission.id, id)) return index;
    }
    return null;
}

pub fn isClosed(mission: state.Mission) bool {
    return std.mem.eql(u8, mission.status, "merged") or std.mem.eql(u8, mission.status, "abandoned");
}

fn scopesOverlapMissions(a: state.Mission, b: state.Mission) bool {
    return scopes.scopesOverlap(a.scope, b.scope);
}

fn depPathExists(list: []const state.Mission, from: []const u8, to: []const u8) bool {
    var seen: [256][]const u8 = undefined;
    var seen_len: usize = 0;
    var queue: [256][]const u8 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = from;
    tail += 1;
    while (head < tail) {
        const current = queue[head];
        head += 1;
        if (std.mem.eql(u8, current, to)) return true;
        if (containsString(seen[0..seen_len], current)) continue;
        if (seen_len < seen.len) {
            seen[seen_len] = current;
            seen_len += 1;
        }
        const index = findIn(list, current) orelse continue;
        const mission = list[index];
        if (isClosed(mission)) continue;
        for (mission.deps) |dep| {
            if (tail < queue.len) {
                queue[tail] = dep;
                tail += 1;
            }
        }
    }
    return false;
}

fn addAutoDeps(arena: Allocator, list: []state.Mission, base_count: usize) !void {
    for (list[base_count..]) |*fresh| {
        if (std.mem.eql(u8, fresh.kind, "survey")) continue;
        var deps: std.ArrayList([]const u8) = .empty;
        try deps.appendSlice(arena, fresh.deps);
        for (list[0..base_count]) |older| {
            if (std.mem.eql(u8, older.kind, "survey") or isClosed(older)) continue;
            if (!scopesOverlapMissions(fresh.*, older)) continue;
            if (depPathExists(list, fresh.id, older.id) or depPathExists(list, older.id, fresh.id)) continue;
            if (!containsString(deps.items, older.id)) try deps.append(arena, older.id);
        }
        fresh.deps = try deps.toOwnedSlice(arena);
    }
}

fn resolveOpenMissionByBranch(list: []const state.Mission, branch: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_number: usize = 0;
    for (list) |mission| {
        if (isClosed(mission) or !std.mem.eql(u8, mission.branch, branch)) continue;
        const number = std.fmt.parseInt(usize, mission.id[1..], 10) catch 0;
        if (best == null or number > best_number) {
            best = mission.id;
            best_number = number;
        }
    }
    return best;
}

test "Tower store refuses a plan with no missions and an empty complete report" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var store = Store{ .root = "/nonexistent-tower-root" };
    try std.testing.expectError(error.TowerRefused, store.plan(arena_state.allocator(), &.{}, 0));
    try std.testing.expectEqualStrings(plan_empty_message, store.refusal);
    try std.testing.expectError(error.TowerRefused, store.completeMission("  \n"));
    try std.testing.expectEqualStrings(complete_empty_message, store.refusal);
}

test "Tower store validates review status and merge verdicts" {
    try std.testing.expect(validReviewStatus("clean"));
    try std.testing.expect(validReviewStatus("p1-2items"));
    try std.testing.expect(validReviewStatus("p2-10items"));
    try std.testing.expect(!validReviewStatus("p3-1items"));
    try std.testing.expect(!validReviewStatus("p1-items"));
    try std.testing.expect(!validReviewStatus("dirty"));
}

test "Tower store picks the highest open mission on a branch" {
    const list = [_]state.Mission{
        .{ .id = "M1", .title = "a", .slug = "a", .branch = "feat/a", .worktree = "w1", .status = "merged" },
        .{ .id = "M2", .title = "b", .slug = "b", .branch = "feat/a", .worktree = "w2", .status = "active" },
        .{ .id = "M3", .title = "c", .slug = "c", .branch = "feat/a", .worktree = "w3", .status = "planned" },
    };
    try std.testing.expectEqualStrings("M3", resolveOpenMissionByBranch(&list, "feat/a").?);
    try std.testing.expect(resolveOpenMissionByBranch(&list, "feat/none") == null);
}

test "Tower store adds an auto dependency for overlapping scopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list = [_]state.Mission{
        .{ .id = "M1", .title = "a", .slug = "a", .branch = "feat/a", .worktree = "w1", .scope = &.{"src/core/**"} },
        .{ .id = "M2", .title = "b", .slug = "b", .branch = "feat/b", .worktree = "w2", .scope = &.{"src/core/tower"} },
    };
    try addAutoDeps(arena, &list, 1);
    try std.testing.expectEqual(@as(usize, 1), list[1].deps.len);
    try std.testing.expectEqualStrings("M1", list[1].deps[0]);
}
