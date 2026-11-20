const std = @import("std");
const observation = @import("../agent/runtime/observation.zig");
const diff_mod = @import("../output/diff.zig");
const permission_request = @import("permission_request.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const HookAnswers = struct {
    context: *anyopaque,
    take_fn: *const fn (*anyopaque, Allocator, []const u8) ?permission_request.OwnedPermissionResponse,
    asks_fn: *const fn (*anyopaque, []const u8) bool,

    pub fn take(self: HookAnswers, alloc: Allocator, call_id: []const u8) ?permission_request.OwnedPermissionResponse {
        return self.take_fn(self.context, alloc, call_id);
    }

    pub fn asks(self: HookAnswers, call_id: []const u8) bool {
        return self.asks_fn(self.context, call_id);
    }
};

pub const Prompter = struct {
    observer: ?*observation.Observer = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    hook_answers: ?HookAnswers = null,
    context: *anyopaque,
    request_fn: *const fn (
        *anyopaque,
        Allocator,
        permission_request.PermissionRequest,
        types.ToolCall,
        ?*const diff_mod.FileReview,
        ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse,
    retain_grant_fn: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,

    pub fn request(
        self: Prompter,
        alloc: Allocator,
        request_value: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const diff_mod.FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        if (self.hook_answers) |answers| {
            if (answers.take(alloc, call.id)) |answered| return answered;
        }
        const wait = if (self.observer) |observer| observer.beginWait(.{ .kind = .approval, .call_id = call.id, .external_id = if (request_value.id == 0) null else request_value.id, .prompt = request_value.label }) else null;
        const response = self.request_fn(
            self.context,
            alloc,
            request_value,
            call,
            review,
            grant_offer,
        ) catch |err| {
            if (wait) |value| value.end(if (err == error.Cancelled) .cancelled else .failed, &.{}, @errorName(err));
            return err;
        };
        if (wait) |value| value.end(if (self.cancel_flag != null and self.cancel_flag.?.load(.seq_cst)) .cancelled else if (response.decision.isDenied()) .denied else .accepted, if (response.feedback) |feedback| &.{feedback} else &.{}, null);
        return response;
    }

    pub fn hookAsks(self: Prompter, call_id: []const u8) bool {
        const answers = self.hook_answers orelse return false;
        return answers.asks(call_id);
    }

    pub fn retainGrant(self: Prompter, tool_name: []const u8, target_path: []const u8) anyerror!bool {
        const retain = self.retain_grant_fn orelse return false;
        try retain(self.context, tool_name, target_path);
        return true;
    }
};

test "approval observer pairs actual prompt attempts without changing their decisions" {
    const Fixture = struct {
        decision: types.ToolPermissionDecision = .once,
        failure: bool = false,
        fn request(raw: *anyopaque, alloc: Allocator, _: permission_request.PermissionRequest, _: types.ToolCall, _: ?*const diff_mod.FileReview, _: ?[]const types.PermissionGrant) !permission_request.OwnedPermissionResponse {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.failure) return error.Cancelled;
            return permission_request.OwnedPermissionResponse.init(alloc, self.decision, null);
        }
    };
    var capture: @import("../agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "approval-call" };
    var observer = capture.observer();
    var fixture: Fixture = .{};
    const prompter = Prompter{ .context = &fixture, .request_fn = Fixture.request, .observer = &observer };
    const call = types.ToolCall{ .id = "approval-call", .name = "Bash", .arguments_json = "{}" };
    for ([_]types.ToolPermissionDecision{ .once, .deny }) |decision| {
        fixture.decision = decision;
        var response = try prompter.request(std.testing.allocator, .{ .id = 42, .label = "Allow?" }, call, null, null);
        defer response.deinit();
        try std.testing.expectEqual(decision, response.decision);
    }
    fixture.failure = true;
    try std.testing.expectError(error.Cancelled, prompter.request(std.testing.allocator, .{ .label = "Allow?" }, call, null, null));
    try std.testing.expectEqual(@as(usize, 3), capture.count(.wait_start));
    try std.testing.expectEqual(capture.count(.wait_start), capture.count(.wait_end));
    try std.testing.expect(!capture.invalid);
}

test "a hook answer for the call settles the prompt without asking and other calls still ask" {
    const Fixture = struct {
        asked: usize = 0,
        answered_call: []const u8 = "hook-call",
        forced_call: []const u8 = "ask-call",
        fn request(raw: *anyopaque, alloc: Allocator, _: permission_request.PermissionRequest, _: types.ToolCall, _: ?*const diff_mod.FileReview, _: ?[]const types.PermissionGrant) !permission_request.OwnedPermissionResponse {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.asked += 1;
            return permission_request.OwnedPermissionResponse.init(alloc, .once, null);
        }
        fn take(raw: *anyopaque, alloc: Allocator, call_id: []const u8) ?permission_request.OwnedPermissionResponse {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.eql(u8, call_id, self.answered_call)) return null;
            return permission_request.OwnedPermissionResponse.init(alloc, .deny, null);
        }
        fn asks(raw: *anyopaque, call_id: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return std.mem.eql(u8, call_id, self.forced_call);
        }
    };
    var fixture: Fixture = .{};
    const prompter = Prompter{
        .context = &fixture,
        .request_fn = Fixture.request,
        .hook_answers = .{ .context = &fixture, .take_fn = Fixture.take, .asks_fn = Fixture.asks },
    };
    var answered = try prompter.request(std.testing.allocator, .{ .label = "Allow?" }, .{ .id = "hook-call", .name = "ExitPlanMode", .arguments_json = "{}" }, null, null);
    defer answered.deinit();
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, answered.decision);
    try std.testing.expectEqual(@as(usize, 0), fixture.asked);

    var asked = try prompter.request(std.testing.allocator, .{ .label = "Allow?" }, .{ .id = "other-call", .name = "Bash", .arguments_json = "{}" }, null, null);
    defer asked.deinit();
    try std.testing.expectEqual(types.ToolPermissionDecision.once, asked.decision);
    try std.testing.expectEqual(@as(usize, 1), fixture.asked);

    try std.testing.expect(prompter.hookAsks("ask-call"));
    try std.testing.expect(!prompter.hookAsks("other-call"));
    const plain = Prompter{ .context = &fixture, .request_fn = Fixture.request };
    try std.testing.expect(!plain.hookAsks("ask-call"));
}
