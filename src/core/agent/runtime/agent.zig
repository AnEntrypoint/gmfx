const std = @import("std");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const types = @import("../../shared/types.zig");
const checkpoint_codec = @import("checkpoint.zig");
const session_codec = @import("../../session/session_codec.zig");
const runtime_prompt_context = @import("prompt_context.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const text_utils = @import("../../shared/text_utils.zig");
const todo_list = @import("../../todo/todo_list.zig");

const Allocator = std.mem.Allocator;

pub const Agent = struct {
    history: std.ArrayList(types.HistoryTurn) = .empty,
    turn_usage: types.Usage = .{},
    fresh: bool = true,
    request_token_calibration: ?RequestTokenCalibrationState = null,
    request_fixed_tokens: ?usize = null,
    request_byte_limit: ?RequestByteLimitState = null,
    todo: todo_list.State = .{},

    pub fn deinit(self: *Agent, alloc: Allocator) void {
        self.clearHistory(alloc);
        self.history.deinit(alloc);
        self.todo.deinit();
        self.* = undefined;
    }

    pub fn openTodosForCompaction(self: *const Agent, arena: Allocator, history: []const types.HistoryTurn) Allocator.Error![]const u8 {
        return todo_list.compactionSection(arena, try self.todo.current(arena, history));
    }

    pub fn startTurn(self: *Agent) void {
        self.fresh = false;
        self.turn_usage = .{};
    }

    pub fn checkpoint(self: *const Agent, alloc: Allocator, meta: checkpoint_codec.Meta) checkpoint_codec.Error![]u8 {
        return checkpoint_codec.encode(alloc, self.history.items, self.turn_usage, meta);
    }

    pub fn checkpointNamingImages(
        self: *const Agent,
        alloc: Allocator,
        meta: checkpoint_codec.Meta,
        stored: *const session_codec.StoredImages,
    ) checkpoint_codec.Error![]u8 {
        return checkpoint_codec.encodeNamingImages(alloc, self.history.items, self.turn_usage, meta, stored);
    }

    pub fn restoreCheckpoint(
        self: *Agent,
        alloc: Allocator,
        bytes: []const u8,
    ) (checkpoint_codec.Error || error{AgentNotFresh})!checkpoint_codec.Meta {
        if (!self.fresh or self.history.items.len != 0) {
            return error.AgentNotFresh;
        }
        var decoded = try checkpoint_codec.decode(alloc, bytes);
        defer decoded.deinit(alloc);
        var previous = self.history;
        self.history = .fromOwnedSlice(decoded.history);
        decoded.history = &.{};
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);
        self.turn_usage = decoded.usage;
        self.fresh = false;
        const meta = decoded.meta;
        decoded.meta = .{};
        return meta;
    }

    pub fn observeUsage(self: *Agent, usage: types.Usage) void {
        self.turn_usage.add(usage);
    }

    pub fn appendHistoryEntry(
        self: *Agent,
        alloc: Allocator,
        turn: types.HistoryTurn,
    ) Allocator.Error!void {
        const copy = try types.dupeHistoryTurn(alloc, turn);
        errdefer types.freeHistoryTurn(alloc, copy);
        try self.history.append(alloc, copy);
        self.fresh = false;
    }

    pub fn clearHistory(self: *Agent, alloc: Allocator) void {
        for (self.history.items) |turn| types.freeHistoryTurn(alloc, turn);
        self.history.clearRetainingCapacity();

        self.request_token_calibration = null;
        self.request_byte_limit = null;
    }

    pub fn requestByteLimit(self: *const Agent, model: []const u8) ?usize {
        const state = self.request_byte_limit orelse return null;
        if (!std.mem.eql(u8, state.modelSlice(), model)) return null;
        return state.bytes;
    }

    pub fn lowerRequestByteLimit(self: *Agent, model: []const u8, bytes: usize) void {
        if (model.len == 0 or model.len > max_request_calibration_model_bytes) {
            debug_trace.logf("agent", "request size limit not learned: unmatchable model id len={d}", .{model.len});
            return;
        }
        const limit = if (self.requestByteLimit(model)) |current| @min(current, bytes) else bytes;
        var state = RequestByteLimitState{ .model_len = model.len, .bytes = limit };
        @memcpy(state.model[0..model.len], model);
        self.request_byte_limit = state;
    }

    pub fn storeRequestTokenCalibration(
        self: *Agent,
        model: []const u8,
        cost: runtime_prompt_context.RequestTokenCalibration,
    ) void {
        if (model.len == 0 or model.len > max_request_calibration_model_bytes) {
            if (self.request_token_calibration != null)
                debug_trace.logf("agent", "dropping request token calibration: unmatchable model id len={d}", .{model.len});
            self.request_token_calibration = null;
            return;
        }
        var state = RequestTokenCalibrationState{ .model_len = model.len, .cost = cost };
        @memcpy(state.model[0..model.len], model);
        self.request_token_calibration = state;
    }

    pub fn snapshotHistory(
        self: *const Agent,
        alloc: Allocator,
    ) Allocator.Error![]types.HistoryTurn {
        const copy = try alloc.alloc(types.HistoryTurn, self.history.items.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |turn| types.freeHistoryTurn(alloc, turn);
            alloc.free(copy);
        }
        for (self.history.items, 0..) |turn, index| {
            copy[index] = try types.dupeHistoryTurn(alloc, turn);
            copied += 1;
        }
        return copy;
    }

    pub fn restoreHistory(
        self: *Agent,
        alloc: Allocator,
        history: []const types.HistoryTurn,
    ) Allocator.Error!void {
        var replacement: std.ArrayList(types.HistoryTurn) = .empty;
        errdefer {
            for (replacement.items) |turn| types.freeHistoryTurn(alloc, turn);
            replacement.deinit(alloc);
        }
        try replacement.ensureTotalCapacity(alloc, history.len);
        for (history) |turn| {
            replacement.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
        }

        var previous = self.history;
        self.history = replacement;
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);

        self.request_token_calibration = null;
        self.request_byte_limit = null;
        self.fresh = false;
    }
};

pub const RequestByteLimitState = struct {
    model: [max_request_calibration_model_bytes]u8 = undefined,
    model_len: usize = 0,
    bytes: usize = 0,

    pub fn modelSlice(self: *const RequestByteLimitState) []const u8 {
        return self.model[0..self.model_len];
    }
};

const max_request_calibration_model_bytes: usize = 128;

pub const RequestTokenCalibrationState = struct {
    model: [max_request_calibration_model_bytes]u8 = undefined,
    model_len: usize = 0,
    cost: runtime_prompt_context.RequestTokenCalibration = .{
        .request = .{ .serialized_bytes = 0, .text_tokens = 0, .estimated_input_tokens = 0 },
        .exact_input_tokens = 0,
    },

    pub fn modelSlice(self: *const RequestTokenCalibrationState) []const u8 {
        return self.model[0..self.model_len];
    }
};

test "Agent request token calibration survives startTurn and dies with cleared history" {
    const alloc = std.testing.allocator;
    var agent: Agent = .{};
    defer agent.deinit(alloc);

    const cost = runtime_prompt_context.RequestTokenCalibration{
        .request = .{ .serialized_bytes = 400, .text_tokens = 100, .estimated_input_tokens = 100 },
        .exact_input_tokens = 90,
    };
    agent.storeRequestTokenCalibration("fixture/model", cost);
    try std.testing.expect(agent.request_token_calibration != null);
    try std.testing.expectEqualStrings("fixture/model", agent.request_token_calibration.?.modelSlice());
    try std.testing.expectEqual(@as(usize, 90), agent.request_token_calibration.?.cost.exact_input_tokens);

    agent.startTurn();
    try std.testing.expect(agent.request_token_calibration != null);

    agent.storeRequestTokenCalibration(text_utils.repeat("x", max_request_calibration_model_bytes + 1), cost);
    try std.testing.expectEqual(@as(?RequestTokenCalibrationState, null), agent.request_token_calibration);

    agent.storeRequestTokenCalibration("fixture/model", cost);
    agent.clearHistory(alloc);
    try std.testing.expectEqual(@as(?RequestTokenCalibrationState, null), agent.request_token_calibration);

    agent.storeRequestTokenCalibration("fixture/model", cost);
    try agent.restoreHistory(alloc, &.{});
    try std.testing.expectEqual(@as(?RequestTokenCalibrationState, null), agent.request_token_calibration);
}

test "Agent request size limit only lowers, follows the model, and dies with cleared history" {
    const alloc = std.testing.allocator;
    var agent: Agent = .{};
    defer agent.deinit(alloc);

    try std.testing.expectEqual(@as(?usize, null), agent.requestByteLimit("fixture/model"));
    agent.lowerRequestByteLimit("fixture/model", 4000);
    agent.lowerRequestByteLimit("fixture/model", 9000);
    try std.testing.expectEqual(@as(?usize, 4000), agent.requestByteLimit("fixture/model"));
    try std.testing.expectEqual(@as(?usize, null), agent.requestByteLimit("other/model"));
    agent.startTurn();
    try std.testing.expectEqual(@as(?usize, 4000), agent.requestByteLimit("fixture/model"));

    agent.lowerRequestByteLimit("other/model", 7000);
    try std.testing.expectEqual(@as(?usize, 7000), agent.requestByteLimit("other/model"));
    try std.testing.expectEqual(@as(?usize, null), agent.requestByteLimit("fixture/model"));

    agent.lowerRequestByteLimit(text_utils.repeat("x", max_request_calibration_model_bytes + 1), 10);
    try std.testing.expectEqual(@as(?usize, 7000), agent.requestByteLimit("other/model"));

    agent.clearHistory(alloc);
    try std.testing.expectEqual(@as(?usize, null), agent.requestByteLimit("other/model"));
    agent.lowerRequestByteLimit("other/model", 7000);
    try agent.restoreHistory(alloc, &.{});
    try std.testing.expectEqual(@as(?usize, null), agent.requestByteLimit("other/model"));
}

test "Agent startTurn consumes freshness and resets usage" {
    var agent: Agent = .{};
    agent.turn_usage = .{ .input_tokens = 4 };
    agent.startTurn();
    try std.testing.expect(!agent.fresh);
    try std.testing.expectEqual(@as(?u64, null), agent.turn_usage.input_tokens);
}

test "Agent accumulates per-turn usage with saturation" {
    var agent: Agent = .{};
    agent.startTurn();
    agent.observeUsage(.{ .input_tokens = 4, .output_tokens = 2 });
    agent.observeUsage(.{ .input_tokens = 3, .reasoning_tokens = 1 });
    try std.testing.expectEqual(@as(?u64, 7), agent.turn_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), agent.turn_usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), agent.turn_usage.reasoning_tokens);

    agent.observeUsage(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        agent.turn_usage.input_tokens,
    );
}

test "Agent history restore is transactional" {
    const alloc = testing_allocator.no_resize;
    var agent: Agent = .{};
    defer agent.deinit(alloc);

    try agent.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("old") },
        .assistant = @constCast("answer"),
    } });
    const replacement = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("new") },
        .assistant = @constCast("response"),
    } }};
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        agent.restoreHistory(failing.allocator(), &replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), agent.history.items.len);
    try std.testing.expectEqualStrings("old", agent.history.items[0].assistant.user.text);

    try agent.restoreHistory(alloc, &replacement);
    try std.testing.expectEqualStrings("new", agent.history.items[0].assistant.user.text);
}

test "Agent checkpoint restores only into a fresh owner" {
    const alloc = std.testing.allocator;
    var source: Agent = .{};
    defer source.deinit(alloc);
    try source.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("before") },
        .assistant = @constCast("after"),
    } });
    const bytes = try source.checkpoint(alloc, .{});
    defer alloc.free(bytes);

    var restored: Agent = .{};
    defer restored.deinit(alloc);
    (try restored.restoreCheckpoint(alloc, bytes)).free(alloc);
    try std.testing.expectEqualStrings("before", restored.history.items[0].assistant.user.text);
    try std.testing.expectError(error.AgentNotFresh, restored.restoreCheckpoint(alloc, bytes));
}

test "Agent checkpoint restore consumes freshness for empty history" {
    const alloc = std.testing.allocator;
    var source: Agent = .{};
    defer source.deinit(alloc);
    const bytes = try source.checkpoint(alloc, .{});
    defer alloc.free(bytes);

    var restored: Agent = .{};
    defer restored.deinit(alloc);
    (try restored.restoreCheckpoint(alloc, bytes)).free(alloc);
    try std.testing.expectError(error.AgentNotFresh, restored.restoreCheckpoint(alloc, bytes));
}

test {
    _ = @import("cron_drive.zig");
}
