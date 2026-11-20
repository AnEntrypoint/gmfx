const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const goal = @import("../../core/goal/state.zig");
const shared = @import("shared.zig");
const serialize = @import("serialize.zig");

const Allocator = std.mem.Allocator;
const DispatchContext = tool_dispatch.DispatchContext;
const ToolInput = tool_dispatch.ToolInput;
const ToolResult = tool_dispatch.ToolResult;

pub const description =
    \\Create a durable goal that the runtime pursues across multiple turns. Call it only when the user explicitly asks you to start a goal or work autonomously toward an outcome, or a host goal-intake prompt asks you to create one. Do not create a goal for greetings, ordinary questions, or requests without a checkable end state.
    \\
    \\When the request is vague, ask the user for the missing completion criterion first; if they clearly insist after you warn them that the wording is vague or risky, create the goal anyway. Include `completionCriterion` when the user provides one, or when it can be stated without inventing new requirements. Keep `objective` concise and reference long task descriptions by file path. Creating fails if a goal already exists; pass `replace: true` only when the user explicitly wants to abandon the current goal and start a new one.
;

const invalid_arguments_message = "CreateGoal arguments must be an object with objective (non-empty string), optional completionCriterion (string) and optional replace (boolean).";
const changed_goal_message = "Goal not created: the current goal changed.";
const allowed_fields = [_][]const u8{ "objective", "completionCriterion", "replace" };

pub const Input = struct {
    objective: []u8,
    completion_criterion: ?[]u8,
    replace: bool,
    goal_id_at_decode: ?u64,

    pub fn deinit(self: Input, alloc: Allocator) void {
        alloc.free(self.objective);
        if (self.completion_criterion) |text| alloc.free(text);
    }
};

fn optionalString(object: std.json.ObjectMap, name: []const u8) error{InvalidArguments}!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidArguments,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) error{InvalidArguments}!bool {
    const value = object.get(name) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidArguments,
    };
}

pub fn decode(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = (try shared.parseObject(ctx.allocator, args_json)) orelse
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    defer parsed.deinit();
    const object = parsed.value.object;
    if (shared.unknownField(object, &allowed_fields) != null) {
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    }
    const objective_text = (optionalString(object, "objective") catch
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message)) orelse
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    if (objective_text.len == 0) return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const criterion_text = optionalString(object, "completionCriterion") catch
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const replace = optionalBool(object, "replace") catch
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);

    const objective = try ctx.allocator.dupe(u8, objective_text);
    errdefer ctx.allocator.free(objective);
    const completion_criterion: ?[]u8 = if (criterion_text) |text| try ctx.allocator.dupe(u8, text) else null;
    errdefer if (completion_criterion) |text| ctx.allocator.free(text);
    const input = Input{
        .objective = objective,
        .completion_criterion = completion_criterion,
        .replace = replace,
        .goal_id_at_decode = if (ctx.goal) |view| view.state.currentId() else null,
    };
    return .{ .input = try shared.wrap(Input, ctx.allocator, input) };
}

pub fn call(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!ToolResult {
    const input = erased.as(Input);
    const view = ctx.goal orelse return shared.unavailable(ctx.allocator);
    if (view.state.currentId() != input.goal_id_at_decode) {
        return shared.successResult(ctx.allocator, changed_goal_message);
    }
    const snapshot = view.state.create(
        view.alloc,
        view.now_ms,
        input.objective,
        input.completion_criterion,
        input.replace,
    ) catch |err| return shared.goalFailure(ctx.allocator, err);
    return .{ .success = try serialize.renderGoalResult(ctx.allocator, snapshot) };
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

fn decodeInput(alloc: Allocator, ctx: DispatchContext, args_json: []const u8) !ToolInput {
    const decoded = try decode(ctx, args_json);
    switch (decoded) {
        .input => |input| return input,
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectSuccessContaining(result: ToolResult, needle: []const u8) !void {
    switch (result) {
        .success => |body| try std.testing.expect(std.mem.indexOf(u8, body, needle) != null),
        else => return error.TestUnexpectedResult,
    }
}

fn expectFailureText(result: ToolResult, expected: []const u8) !void {
    switch (result) {
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
        else => return error.TestUnexpectedResult,
    }
}

test "CreateGoal decodes objective, completion criterion and replace" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const input = try decodeInput(alloc, ctx, "{\"objective\":\"ship it\",\"completionCriterion\":\"tests pass\",\"replace\":true}");
    defer input.deinit(alloc);
    const values = input.as(Input);
    try std.testing.expectEqualStrings("ship it", values.objective);
    try std.testing.expectEqualStrings("tests pass", values.completion_criterion.?);
    try std.testing.expect(values.replace);
}

test "CreateGoal rejects an empty objective, a missing objective and an unknown field" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const cases = [_][]const u8{
        "{\"objective\":\"\"}",
        "{}",
        "{\"objective\":\"x\",\"budget\":3}",
        "{\"objective\":\"x\",\"replace\":\"yes\"}",
    };
    for (cases) |args_json| {
        const decoded = try decode(ctx, args_json);
        switch (decoded) {
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
            .failure => |failure| {
                defer alloc.free(failure);
                try std.testing.expectEqualStrings(invalid_arguments_message, failure);
            },
        }
    }
}

test "CreateGoal creates the goal through the session view and returns it" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"objective\":\"ship it\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessContaining(result, "\"objective\": \"ship it\"");
    try expectSuccessContaining(result, "\"status\": \"active\"");
    try std.testing.expect(state.currentId() != null);
}

test "CreateGoal fails with the runtime message when a goal already exists" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "first", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"objective\":\"second\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectFailureText(result, "A goal already exists; use replace to start a new one");
}

test "CreateGoal reports a changed goal when the current goal moved after decode" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "first", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"objective\":\"second\",\"replace\":true}");
    defer input.deinit(alloc);
    state.clear(alloc);
    _ = try state.create(alloc, 0, "third", null, false);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessContaining(result, changed_goal_message);
}

test "CreateGoal is unavailable without a goal view" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const input = try decodeInput(alloc, ctx, "{\"objective\":\"ship it\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectFailureText(result, shared.main_agent_only_message);
}
