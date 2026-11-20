const std = @import("std");

pub const StepState = enum { pending, sent, completed, failed };

pub const Step = struct {
    id: usize,
    request_id: []const u8,
    method: []const u8,
    target_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    state: StepState = .pending,
};

fn dupeOptional(alloc: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try alloc.dupe(u8, value) else null;
}

fn freeStep(alloc: std.mem.Allocator, step: Step) void {
    alloc.free(step.request_id);
    if (step.target_id) |text| alloc.free(text);
    if (step.session_id) |text| alloc.free(text);
}

pub const Run = struct {
    id: []const u8,
    steps: std.ArrayList(Step) = .empty,
    next_id: usize = 1,

    pub fn deinit(self: *Run, alloc: std.mem.Allocator) void {
        for (self.steps.items) |step| freeStep(alloc, step);
        self.steps.deinit(alloc);
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn begin(self: *Run, alloc: std.mem.Allocator, request_id: []const u8, method: []const u8, target_id: ?[]const u8, session_id: ?[]const u8) !usize {
        const owned_request_id = try alloc.dupe(u8, request_id);
        errdefer alloc.free(owned_request_id);
        const owned_target_id = try dupeOptional(alloc, target_id);
        errdefer if (owned_target_id) |text| alloc.free(text);
        const owned_session_id = try dupeOptional(alloc, session_id);
        errdefer if (owned_session_id) |text| alloc.free(text);
        const id = self.next_id;
        try self.steps.append(alloc, .{
            .id = id,
            .request_id = owned_request_id,
            .method = method,
            .target_id = owned_target_id,
            .session_id = owned_session_id,
        });
        self.next_id += 1;
        return id;
    }

    pub fn markSent(self: *Run, id: usize) bool {
        const step = self.findStep(id) orelse return false;
        if (step.state != .pending) return false;
        step.state = .sent;
        return true;
    }

    pub fn finish(self: *Run, id: usize, failed: bool) bool {
        const step = self.findStep(id) orelse return false;
        if (step.state != .sent) return false;
        step.state = if (failed) .failed else .completed;
        return true;
    }

    pub fn findStep(self: *Run, id: usize) ?*Step {
        for (self.steps.items) |*step| if (step.id == id) return step;
        return null;
    }
};

pub const Session = struct {
    id: []const u8,
    runs: std.ArrayList(Run) = .empty,

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        for (self.runs.items) |*run| run.deinit(alloc);
        self.runs.deinit(alloc);
        self.* = undefined;
    }

    pub fn startRun(self: *Session, alloc: std.mem.Allocator, run_id: []const u8) !*Run {
        const owned_id = try alloc.dupe(u8, run_id);
        errdefer alloc.free(owned_id);
        try self.runs.append(alloc, .{ .id = owned_id });
        return &self.runs.items[self.runs.items.len - 1];
    }

    pub fn findRun(self: *Session, run_id: []const u8) ?*Run {
        for (self.runs.items) |*run| {
            if (std.mem.eql(u8, run.id, run_id)) return run;
        }
        return null;
    }

    pub fn inFlight(self: *const Session) bool {
        for (self.runs.items) |run| {
            for (run.steps.items) |step| if (step.state == .sent) return true;
        }
        return false;
    }
};

test "native_browser session drives one ordered step pending to sent to completed" {
    const alloc = std.testing.allocator;
    var session = Session{ .id = "run-1" };
    defer session.deinit(alloc);
    const run = try session.startRun(alloc, "open-page");
    const step_id = try run.begin(alloc, "thebird-1", "Target.createTarget", null, null);
    try std.testing.expectEqual(StepState.pending, run.steps.items[0].state);
    try std.testing.expect(run.markSent(step_id));
    try std.testing.expect(session.inFlight());
    try std.testing.expect(run.finish(step_id, false));
    try std.testing.expectEqual(StepState.completed, run.steps.items[0].state);
    try std.testing.expectEqualStrings("Target.createTarget", run.steps.items[0].method);
    try std.testing.expect(!session.inFlight());
}

test "native_browser session refuses out of order transitions and unknown steps" {
    const alloc = std.testing.allocator;
    var session = Session{ .id = "run-2" };
    defer session.deinit(alloc);
    const run = try session.startRun(alloc, "guard");
    const step_id = try run.begin(alloc, "r-1", "Page.enable", "T-1", "S-1");
    try std.testing.expect(!run.finish(step_id, false));
    try std.testing.expect(run.markSent(step_id));
    try std.testing.expect(!run.markSent(step_id));
    try std.testing.expect(!run.markSent(99));
    try std.testing.expect(run.finish(step_id, true));
    try std.testing.expect(!run.finish(step_id, false));
    try std.testing.expectEqual(StepState.failed, run.steps.items[0].state);
    try std.testing.expectEqualStrings("T-1", run.steps.items[0].target_id.?);
}

test "native_browser session owns run and step strings after the caller frees them" {
    const alloc = std.testing.allocator;
    var session = Session{ .id = "run-4" };
    defer session.deinit(alloc);
    const run_id = try alloc.dupe(u8, "borrowed");
    const request_id = try alloc.dupe(u8, "r-owned");
    const target_id = try alloc.dupe(u8, "T-owned");
    const run = try session.startRun(alloc, run_id);
    _ = try run.begin(alloc, request_id, "Page.enable", target_id, null);
    alloc.free(run_id);
    alloc.free(request_id);
    alloc.free(target_id);
    const found = session.findRun("borrowed").?;
    try std.testing.expectEqualStrings("r-owned", found.steps.items[0].request_id);
    try std.testing.expectEqualStrings("T-owned", found.steps.items[0].target_id.?);
    try std.testing.expect(found.steps.items[0].session_id == null);
}

test "native_browser session finds runs by id and keeps step ids per run" {
    const alloc = std.testing.allocator;
    var session = Session{ .id = "run-3" };
    defer session.deinit(alloc);
    _ = try session.startRun(alloc, "first");
    const second = try session.startRun(alloc, "second");
    const id_a = try second.begin(alloc, "a", "Target.getTargets", null, null);
    const id_b = try second.begin(alloc, "b", "Target.getTargets", null, null);
    try std.testing.expectEqual(@as(usize, 1), id_a);
    try std.testing.expectEqual(@as(usize, 2), id_b);
    try std.testing.expect(session.findRun("missing") == null);
    try std.testing.expectEqual(@as(usize, 2), session.findRun("second").?.steps.items.len);
}
