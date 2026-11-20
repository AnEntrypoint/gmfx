const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const exit_plan_mode_tool_name = "ExitPlanMode";
pub const approval_label = "Approve the plan and leave plan mode?";
pub const exit_requires_prompt_message = "Nobody can review this plan in a non-interactive run, so plan mode stays active for the rest of this run and you cannot edit files other than the plan file.";
pub const rejected_message = "Plan rejected by user. Plan mode remains active.";
pub const dismissed_message = "Plan approval dismissed. Plan mode remains active.";
pub const revisions_requested_message = "User requested revisions. Plan mode remains active.";
pub const not_active_message = "ExitPlanMode can only be called while plan mode is active. Only the user can turn plan mode on.";
pub const guidance = "Plan mode is a read-only planning state that only the user can turn on (for example with Shift-Tab or `/plan` in the terminal); you cannot enter it yourself, so if asked, tell the user how. When they ask you to plan first, wait for their go-ahead before changing code.";
pub const plan_file_relative = ".fx/plans/plan.md";
pub const max_plan_file_bytes: usize = 1024 * 1024;
pub const review_approve_label = "1. Approve";
pub const review_reject_label = "2. Reject";
pub const review_revise_label = "3. Revise";
pub const review_revise_prefix = "3. Revise, ";
pub const review_revise_placeholder = "and tell fx what to change in the plan";
pub const review_revise_amendment_label = review_revise_prefix ++ review_revise_placeholder;
const mutation_refusal_format = "Plan mode is on, so {s} is refused. Research with read-only tools, then call ExitPlanMode so the user can approve the plan.";
const write_refusal_format = "Plan mode is active. You may only write to the current plan file: {s}. Call ExitPlanMode to exit plan mode before editing other files.";
const task_stop_refusal = "TaskStop is not available in plan mode. Call ExitPlanMode to exit plan mode before stopping a background task.";
const cron_refusal_format = "{s} is not available in plan mode because it would mutate scheduled work that runs after plan exit. Call ExitPlanMode first.";
const missing_plan_format = "No plan file found. Write your plan to {s} first, then call ExitPlanMode.";
const revise_feedback_format = "User rejected the plan. Feedback:\n\n{s}";
const max_review_option_bytes = 80;
const max_review_location_bytes = 512;
const max_review_feedback_bytes = 4096;

pub const ReviewVerdict = enum { approved, revise, dismissed };

pub const Review = struct {
    verdict: ReviewVerdict,
    option_bytes: [max_review_option_bytes]u8 = undefined,
    option_len: usize = 0,
    location_bytes: [max_review_location_bytes]u8 = undefined,
    location_len: usize = 0,
    feedback_bytes: [max_review_feedback_bytes]u8 = undefined,
    feedback_len: usize = 0,

    pub fn approved(selected_option: ?[]const u8, saved_location: ?[]const u8) Review {
        var review: Review = .{ .verdict = .approved };
        review.option_len = copyBounded(&review.option_bytes, selected_option orelse "");
        review.location_len = copyBounded(&review.location_bytes, saved_location orelse "");
        return review;
    }

    pub fn revise(feedback_text: ?[]const u8) Review {
        var review: Review = .{ .verdict = .revise };
        review.feedback_len = copyBounded(&review.feedback_bytes, feedback_text orelse "");
        return review;
    }

    pub fn dismissed() Review {
        return .{ .verdict = .dismissed };
    }

    pub fn selectedOption(self: *const Review) ?[]const u8 {
        return if (self.option_len == 0) null else self.option_bytes[0..self.option_len];
    }

    pub fn savedLocation(self: *const Review) ?[]const u8 {
        return if (self.location_len == 0) null else self.location_bytes[0..self.location_len];
    }

    pub fn feedback(self: *const Review) ?[]const u8 {
        return if (self.feedback_len == 0) null else self.feedback_bytes[0..self.feedback_len];
    }
};

fn copyBounded(buffer: []u8, text: []const u8) usize {
    const len = @min(buffer.len, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    return len;
}

pub const State = struct {
    active: std.atomic.Value(bool) = .init(false),
    review_busy: std.atomic.Value(bool) = .init(false),
    review: ?Review = null,

    pub fn isActive(self: *const State) bool {
        return self.active.load(.seq_cst);
    }

    pub fn set(self: *State, enabled: bool) void {
        self.active.store(enabled, .seq_cst);
    }

    pub fn leave(self: *State) bool {
        return self.active.swap(false, .seq_cst);
    }

    pub fn recordReview(self: *State, review: Review) void {
        self.claimReview();
        defer self.review_busy.store(false, .seq_cst);
        self.review = review;
    }

    pub fn takeReview(self: *State) ?Review {
        self.claimReview();
        defer self.review_busy.store(false, .seq_cst);
        const review = self.review;
        self.review = null;
        return review;
    }

    fn claimReview(self: *State) void {
        while (self.review_busy.swap(true, .seq_cst)) std.atomic.spinLoopHint();
    }
};

pub fn mutationRefusal(alloc: Allocator, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, mutation_refusal_format, .{tool_name});
}

pub fn isPlanFileTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit_file");
}

pub fn toolRefusal(alloc: Allocator, tool_name: []const u8, workspace_root: []const u8) ![]u8 {
    if (isPlanFileTool(tool_name)) {
        const path = try planFilePath(alloc, workspace_root);
        defer alloc.free(path);
        return std.fmt.allocPrint(alloc, write_refusal_format, .{path});
    }
    if (std.mem.eql(u8, tool_name, "TaskStop")) return alloc.dupe(u8, task_stop_refusal);
    if (std.mem.eql(u8, tool_name, "CronCreate") or std.mem.eql(u8, tool_name, "CronDelete")) {
        return std.fmt.allocPrint(alloc, cron_refusal_format, .{tool_name});
    }
    return mutationRefusal(alloc, tool_name);
}

pub fn missingPlanMessage(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    const path = try planFilePath(alloc, workspace_root);
    defer alloc.free(path);
    return std.fmt.allocPrint(alloc, missing_plan_format, .{path});
}

pub fn reviseResult(alloc: Allocator, feedback_text: ?[]const u8) ![]u8 {
    const text = feedback_text orelse return alloc.dupe(u8, revisions_requested_message);
    return std.fmt.allocPrint(alloc, revise_feedback_format, .{text});
}

pub fn planFilePath(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    if (workspace_root.len == 0) return alloc.dupe(u8, plan_file_relative);
    return std.Io.Dir.path.resolveAlloc(alloc, &.{ workspace_root, plan_file_relative });
}

pub fn isPlanFilePath(alloc: Allocator, workspace_root: []const u8, path: []const u8) bool {
    if (path.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = planFilePath(arena, workspace_root) catch return false;
    const candidate = std.Io.Dir.path.resolveAlloc(arena, &.{ workspace_root, path }) catch return false;
    if (workspace_root.len == 0) return std.mem.eql(u8, candidate, target);
    const real_target = realpathOfExistingPrefix(arena, target) catch return false;
    const real_root = realpathOfExistingPrefix(arena, workspace_root) catch return false;
    const expected_target = std.Io.Dir.path.resolveAlloc(arena, &.{ real_root, plan_file_relative }) catch return false;
    if (!std.mem.eql(u8, real_target, expected_target)) return false;
    if (std.mem.eql(u8, candidate, target)) return true;
    const real_candidate = realpathOfExistingPrefix(arena, candidate) catch return false;
    return std.mem.eql(u8, real_candidate, real_target);
}

fn realpathOfExistingPrefix(alloc: Allocator, path: []const u8) ![]u8 {
    var existing = path;
    while (true) {
        const real = io_mod.realpathAlloc(alloc, existing) catch {
            existing = std.Io.Dir.path.dirname(existing) orelse return alloc.dupe(u8, path);
            continue;
        };
        defer alloc.free(real);
        const missing_tail = std.mem.trimStart(u8, path[existing.len..], "/");
        if (missing_tail.len == 0) return alloc.dupe(u8, real);
        return std.Io.Dir.path.join(alloc, &.{ real, missing_tail });
    }
}

pub fn callWritesPlanFile(alloc: Allocator, tool_name: []const u8, arguments_json: []const u8, workspace_root: []const u8) bool {
    if (!isPlanFileTool(tool_name)) return false;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const Arguments = struct { path: ?[]const u8 = null };
    const parsed = std.json.parseFromSliceLeaky(Arguments, arena_state.allocator(), arguments_json, .{ .ignore_unknown_fields = true }) catch return false;
    return isPlanFilePath(alloc, workspace_root, parsed.path orelse return false);
}

pub fn preparePlanFile(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    const path = try planFilePath(alloc, workspace_root);
    errdefer alloc.free(path);
    if (std.Io.Dir.path.dirname(path)) |directory| try io_mod.makeDirRecursive(directory);
    return path;
}

pub fn clearPlanFile(alloc: Allocator, workspace_root: []const u8) !void {
    const path = try preparePlanFile(alloc, workspace_root);
    defer alloc.free(path);
    try io_mod.writeFileAtomic(alloc, path, "");
}

pub fn readPlanFile(alloc: Allocator, workspace_root: []const u8) ?[]u8 {
    if (workspace_root.len == 0) return null;
    const path = planFilePath(alloc, workspace_root) catch return null;
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(alloc, &file, max_plan_file_bytes) catch return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        alloc.free(text);
        return null;
    }
    return text;
}

test "plan mode state toggles and leave reports whether it was active" {
    var state: State = .{};
    try std.testing.expect(!state.isActive());

    state.set(true);
    try std.testing.expect(state.isActive());
    try std.testing.expect(state.leave());
    try std.testing.expect(!state.isActive());
    try std.testing.expect(!state.leave());
}

test "plan mode refusal names the refused tool and the way out" {
    const message = try mutationRefusal(std.testing.allocator, "write_file");
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.startsWith(u8, message, "Plan mode is on, so write_file is refused."));
    try std.testing.expect(std.mem.indexOf(u8, message, exit_plan_mode_tool_name) != null);
}

test "plan mode refusals name the plan file for writes and the blocked work for task and cron tools" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { tool: []const u8, expected: []const u8 }{
        .{ .tool = "write_file", .expected = "Plan mode is active. You may only write to the current plan file: /work/repo/.fx/plans/plan.md. Call ExitPlanMode to exit plan mode before editing other files." },
        .{ .tool = "edit_file", .expected = "Plan mode is active. You may only write to the current plan file: /work/repo/.fx/plans/plan.md. Call ExitPlanMode to exit plan mode before editing other files." },
        .{ .tool = "TaskStop", .expected = "TaskStop is not available in plan mode. Call ExitPlanMode to exit plan mode before stopping a background task." },
        .{ .tool = "CronCreate", .expected = "CronCreate is not available in plan mode because it would mutate scheduled work that runs after plan exit. Call ExitPlanMode first." },
        .{ .tool = "CronDelete", .expected = "CronDelete is not available in plan mode because it would mutate scheduled work that runs after plan exit. Call ExitPlanMode first." },
        .{ .tool = "Bash", .expected = "Plan mode is on, so Bash is refused. Research with read-only tools, then call ExitPlanMode so the user can approve the plan." },
    };
    for (cases) |case| {
        const message = try toolRefusal(alloc, case.tool, "/work/repo");
        defer alloc.free(message);
        try std.testing.expectEqualStrings(case.expected, message);
    }
}

test "plan file path matching normalises relative, dotted and absolute spellings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const absolute = try planFilePath(alloc, workspace);
    defer alloc.free(absolute);
    const dotted = try std.fmt.allocPrint(alloc, "{s}/src/../.fx/plans/./plan.md", .{workspace});
    defer alloc.free(dotted);
    const sibling = try std.fmt.allocPrint(alloc, "{s}/.fx/plans/other.md", .{workspace});
    defer alloc.free(sibling);

    try std.testing.expect(isPlanFilePath(alloc, workspace, ".fx/plans/plan.md"));
    try std.testing.expect(isPlanFilePath(alloc, workspace, "./.fx/plans/plan.md"));
    try std.testing.expect(isPlanFilePath(alloc, workspace, absolute));
    try std.testing.expect(isPlanFilePath(alloc, workspace, dotted));
    try std.testing.expect(!isPlanFilePath(alloc, workspace, sibling));
    try std.testing.expect(!isPlanFilePath(alloc, workspace, "notes.md"));
    try std.testing.expect(!isPlanFilePath(alloc, workspace, ""));
    try std.testing.expect(callWritesPlanFile(alloc, "write_file", "{\"path\":\"./.fx/plans/plan.md\",\"content\":\"draft\"}", workspace));
    try std.testing.expect(callWritesPlanFile(alloc, "edit_file", "{\"path\":\".fx/plans/plan.md\"}", workspace));
    try std.testing.expect(!callWritesPlanFile(alloc, "Bash", "{\"path\":\".fx/plans/plan.md\"}", workspace));
    try std.testing.expect(!callWritesPlanFile(alloc, "write_file", "{\"path\":\"notes.md\"}", workspace));
}

test "plan file path matching follows a symlinked directory and refuses a plan file that leaves the workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.fx/plans");
    try tmp.dir.createDirPath(io_mod.getIo(), "escaped/.fx");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const workspace = try std.fmt.allocPrint(alloc, "{s}/repo", .{root});
    defer alloc.free(workspace);
    try tmp.dir.symLink(io_mod.getIo(), "repo/.fx/plans", "plans-link", .{ .is_directory = true });
    const through_link = try std.fmt.allocPrint(alloc, "{s}/plans-link/plan.md", .{root});
    defer alloc.free(through_link);
    try std.testing.expect(isPlanFilePath(alloc, workspace, through_link));

    const outside = try std.fmt.allocPrint(alloc, "{s}/outside-plans", .{root});
    defer alloc.free(outside);
    try tmp.dir.createDirPath(io_mod.getIo(), "outside-plans");
    try tmp.dir.symLink(io_mod.getIo(), outside, "escaped/.fx/plans", .{ .is_directory = true });
    const escaped_workspace = try std.fmt.allocPrint(alloc, "{s}/escaped", .{root});
    defer alloc.free(escaped_workspace);
    try std.testing.expect(!isPlanFilePath(alloc, escaped_workspace, ".fx/plans/plan.md"));
}

test "plan file is prepared on entry, cleared to empty, and read back only when it has text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const path = try preparePlanFile(alloc, workspace);
    defer alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.fx/plans/plan.md"));
    try std.testing.expect(readPlanFile(alloc, workspace) == null);

    try io_mod.writeFileAtomic(alloc, path, "1. Edit the parser.\n");
    const stored = readPlanFile(alloc, workspace).?;
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("1. Edit the parser.\n", stored);

    try clearPlanFile(alloc, workspace);
    try std.testing.expect(readPlanFile(alloc, workspace) == null);
    try std.testing.expect(readPlanFile(alloc, "") == null);
}

test "plan review is recorded once and taken once" {
    var state: State = .{};
    try std.testing.expect(state.takeReview() == null);

    state.recordReview(.approved("Split work", "session.md"));
    const approved_review = state.takeReview().?;
    try std.testing.expectEqual(ReviewVerdict.approved, approved_review.verdict);
    try std.testing.expectEqualStrings("Split work", approved_review.selectedOption().?);
    try std.testing.expectEqualStrings("session.md", approved_review.savedLocation().?);
    try std.testing.expect(state.takeReview() == null);

    state.recordReview(.revise("cover the tokenizer too"));
    const revise_review = state.takeReview().?;
    try std.testing.expectEqualStrings("cover the tokenizer too", revise_review.feedback().?);

    state.recordReview(.dismissed());
    try std.testing.expectEqual(ReviewVerdict.dismissed, state.takeReview().?.verdict);
    try std.testing.expect(Review.revise(null).feedback() == null);
}

test "revise result carries the feedback or says revisions were requested" {
    const alloc = std.testing.allocator;
    const with_feedback = try reviseResult(alloc, "cover the tokenizer too");
    defer alloc.free(with_feedback);
    try std.testing.expectEqualStrings("User rejected the plan. Feedback:\n\ncover the tokenizer too", with_feedback);
    const without_feedback = try reviseResult(alloc, null);
    defer alloc.free(without_feedback);
    try std.testing.expectEqualStrings(revisions_requested_message, without_feedback);
}
