const std = @import("std");
const foreground_text = @import("foreground_text.zig");
const io_mod = @import("../shared/io.zig");
const model_contract = @import("model_contract.zig");
const tool_provider = @import("tool_provider.zig");

const Allocator = std.mem.Allocator;

pub const busy_retry_limit: usize = 100;
pub const busy_retry_delay_ms: u64 = 50;

pub const Outcome = enum { completed, failed, cancelled, transport_error };

pub const Reply = struct {
    outcome: Outcome,
    text: []const u8,
    agent: []const u8 = "",
    error_code: ?[]const u8 = null,
    turn_cancelled: bool = false,
};

pub const Message = struct {
    agent: []const u8,
    prompt: []const u8,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    invocation_id: []const u8,
    continues: bool = false,
};

pub fn send(
    arena: Allocator,
    provider: tool_provider.Provider,
    cancel_flag: ?*std.atomic.Value(bool),
    message: Message,
) Allocator.Error!Reply {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return .{ .outcome = .cancelled, .text = "", .agent = message.agent, .turn_cancelled = true };
        }
        var request = model_contract.validateRequest(arena, .{ .message = .{
            .agent = message.agent,
            .message = message.prompt,
            .model = if (message.continues) null else message.model,
            .profile = if (message.continues) null else message.profile,
            .foreground = true,
        } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .outcome = .failed,
                .text = try arena.print("The subagent request was rejected: {s}.", .{@errorName(err)}),
                .agent = message.agent,
                .error_code = "invalid_request",
            },
        };
        const result = provider.execute(arena, &request, message.invocation_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return .{ .outcome = .cancelled, .text = "", .agent = message.agent, .turn_cancelled = true },
        };
        var reply = try classifyBody(arena, result.body);
        if (reply.agent.len == 0) reply.agent = message.agent;
        if (message.continues and attempt < busy_retry_limit) {
            if (reply.error_code) |code| {
                if (childBusy(code)) {
                    io_mod.sleep(busy_retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
            }
        }
        return reply;
    }
}

fn childBusy(code: []const u8) bool {
    return std.mem.eql(u8, code, "child_already_running") or std.mem.eql(u8, code, "child_busy");
}

pub fn classifyBody(arena: Allocator, body: []const u8) Allocator.Error!Reply {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .outcome = .failed, .text = body, .error_code = "unreadable_result" },
    };
    if (parsed != .object) return .{ .outcome = .failed, .text = body, .error_code = "unreadable_result" };
    const error_code: ?[]const u8 = if (parsed.object.get("error_code")) |value|
        (if (value == .string) value.string else null)
    else
        null;
    const result_text: ?[]const u8 = if (parsed.object.get("result")) |value|
        (if (value == .string) value.string else null)
    else
        null;
    const text = result_text orelse return .{
        .outcome = .failed,
        .text = try arena.print("The subagent did not run: {s}.", .{error_code orelse "no result"}),
        .error_code = error_code orelse "no_result",
    };
    const shaped = foreground_text.parse(text) orelse return .{
        .outcome = .failed,
        .text = text,
        .error_code = error_code orelse "not_a_foreground_result",
    };
    const outcome: Outcome = switch (shaped.stop_reason) {
        .completed => .completed,
        .cancelled => .cancelled,
        .stopped => .failed,
        .failed => if (shaped.failureReason()) |reason|
            (if (foreground_text.isTransportFailure(reason)) Outcome.transport_error else Outcome.failed)
        else
            .failed,
    };
    return .{
        .outcome = outcome,
        .text = shaped.output,
        .agent = shaped.agent,
        .error_code = error_code,
    };
}

const TestProvider = struct {
    bodies: []const []const u8,
    calls: usize = 0,
    last_agent: [64]u8 = undefined,
    last_agent_len: usize = 0,
    saw_profile: bool = false,

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: *model_contract.Request,
        _: []const u8,
    ) tool_provider.ExecuteError!tool_provider.Result {
        const self: *TestProvider = @ptrCast(@alignCast(raw.?));
        const body = self.bodies[@min(self.calls, self.bodies.len - 1)];
        self.calls += 1;
        const agent = request.message.agent;
        @memcpy(self.last_agent[0..agent.len], agent);
        self.last_agent_len = agent.len;
        self.saw_profile = request.message.profile != null;
        return .{ .status = .success, .body = try alloc.dupe(u8, body) };
    }

    fn provider(self: *TestProvider) tool_provider.Provider {
        return .{ .context = self, .execute_fn = execute };
    }
};

fn foregroundBody(arena: Allocator, agent: []const u8, outcome: @import("child_state.zig").Outcome, output: []const u8) ![]const u8 {
    const text = try foreground_text.format(arena, agent, "coder", outcome, output);
    return model_contract.encodeResultAlloc(arena, .{ .ok = outcome == .completed, .result = text });
}

test "foreground call classes a completed, failed, transport and rejected body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const completed = try classifyBody(arena, try foregroundBody(arena, "unit-1", .completed, "done"));
    try std.testing.expectEqual(Outcome.completed, completed.outcome);
    try std.testing.expectEqualStrings("done", completed.text);
    try std.testing.expectEqualStrings("unit-1", completed.agent);

    const transport = try classifyBody(arena, try foregroundBody(arena, "unit-1", .failed, "Subagent failed: StreamInterrupted. Earlier tool calls may have completed; their effects are not rolled back."));
    try std.testing.expectEqual(Outcome.transport_error, transport.outcome);

    const failed = try classifyBody(arena, try foregroundBody(arena, "unit-1", .failed, "Subagent failed: agent_turn_failed: SessionCommitFailed. Earlier tool calls may have completed; their effects are not rolled back."));
    try std.testing.expectEqual(Outcome.failed, failed.outcome);

    const cancelled = try classifyBody(arena, try foregroundBody(arena, "unit-1", .cancelled, "Its turn was cancelled before it finished."));
    try std.testing.expectEqual(Outcome.cancelled, cancelled.outcome);

    const rejected = try classifyBody(arena, "{\"ok\":false,\"result\":null,\"error_code\":\"child_closing\"}");
    try std.testing.expectEqual(Outcome.failed, rejected.outcome);
    try std.testing.expectEqualStrings("child_closing", rejected.error_code.?);
    try std.testing.expectEqualStrings("The subagent did not run: child_closing.", rejected.text);

    const unreadable = try classifyBody(arena, "not json");
    try std.testing.expectEqualStrings("unreadable_result", unreadable.error_code.?);
}

test "foreground call waits out a busy child when it continues one and sends no override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{
        "{\"ok\":false,\"result\":null,\"error_code\":\"child_already_running\"}",
        try foregroundBody(arena, "unit-1", .completed, "{\"key\":\"a\"}"),
    };
    var fixture = TestProvider{ .bodies = &bodies };
    const reply = try send(arena, fixture.provider(), null, .{
        .agent = "unit-1",
        .prompt = "repair",
        .profile = "coder",
        .invocation_id = "call:repair",
        .continues = true,
    });
    try std.testing.expectEqual(Outcome.completed, reply.outcome);
    try std.testing.expectEqualStrings("{\"key\":\"a\"}", reply.text);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(!fixture.saw_profile);
    try std.testing.expectEqualStrings("unit-1", fixture.last_agent[0..fixture.last_agent_len]);
}

test "foreground call starts nothing once the cancel flag is set and reports an invalid agent name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{"{}"};
    var fixture = TestProvider{ .bodies = &bodies };
    var cancel = std.atomic.Value(bool).init(true);
    const cancelled = try send(arena, fixture.provider(), &cancel, .{ .agent = "unit-1", .prompt = "go", .invocation_id = "call" });
    try std.testing.expectEqual(Outcome.cancelled, cancelled.outcome);
    try std.testing.expect(cancelled.turn_cancelled);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    const invalid = try send(arena, fixture.provider(), null, .{ .agent = "Bad Name", .prompt = "go", .invocation_id = "call" });
    try std.testing.expectEqual(Outcome.failed, invalid.outcome);
    try std.testing.expectEqualStrings("invalid_request", invalid.error_code.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
