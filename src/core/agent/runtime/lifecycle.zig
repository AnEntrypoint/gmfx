const std = @import("std");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const hooks = @import("../../hooks/hooks.zig");
const types = @import("../../shared/types.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const PermissionObserver = @import("deps.zig").PermissionObserver;

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

const PreToolUseDispatchError = Allocator.Error || error{
    Cancelled,
    LifecycleFailedClosed,
};

pub const LifecycleContext = struct {
    view: hooks.RuntimeView,
    scope: hooks.Scope,
    outcome_allocator: Allocator,
};

pub const StopCheckpoint = struct {
    turn_id: u64,
    step_index: usize,
    assistant_text: []const u8,
    provider_disposition: types.ProviderCompletionDisposition,
    can_continue: bool,
};

pub const PostTurnEndCheckpoint = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition,
    error_name: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const AttentionRequiredCheckpoint = struct {
    turn_id: u64,
    kind: hooks.AttentionKind,
};

pub const UserPromptSubmitCheckpoint = struct {
    turn_id: u64,
    prompt_text: []const u8,
    is_steer: bool,
};

pub const TurnOrigin = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
};

pub const TurnStartedCheckpoint = struct {
    turn_id: u64,
    origin: TurnOrigin,
    prompt: []const u8,
};

pub const ToolObservationCheckpoint = struct {
    turn_id: u64,
    call: ToolCall,
    failed: bool,
    output: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

const PreToolUseCheckpoint = struct {
    turn_id: u64,
    step_index: usize,
    call: ToolCall,
};

pub const PreparedToolBlockKind = enum {
    malformed_arguments,
    lifecycle_block,
    lifecycle_failed_closed,
    route_unavailable,
    required_vision,
};

pub const PreparedToolCall = union(enum) {
    provider_executed: ToolCall,
    ready: ToolCall,
    blocked: struct {
        call: ToolCall,
        model_output: ?[]u8,
        kind: PreparedToolBlockKind,
    },

    pub fn call(self: PreparedToolCall) ToolCall {
        return switch (self) {
            .provider_executed => |tool_call| tool_call,
            .ready => |tool_call| tool_call,
            .blocked => |blocked| blocked.call,
        };
    }

    pub fn takeBlockedOutput(self: *PreparedToolCall) ?[]u8 {
        return switch (self.*) {
            .blocked => |*blocked| blk: {
                const output = blocked.model_output;
                blocked.model_output = null;
                break :blk output;
            },
            else => null,
        };
    }

    pub fn deinit(self: *PreparedToolCall, alloc: Allocator) void {
        switch (self.*) {
            .provider_executed => |tool_call| types.freeToolCall(alloc, tool_call),
            .ready => |tool_call| types.freeToolCall(alloc, tool_call),
            .blocked => |blocked| {
                types.freeToolCall(alloc, blocked.call);
                if (blocked.model_output) |output| alloc.free(output);
            },
        }
        self.* = undefined;
    }

    pub fn deinitOutput(self: *PreparedToolCall, alloc: Allocator) void {
        switch (self.*) {
            .blocked => |*blocked| {
                if (blocked.model_output) |output| alloc.free(output);
                blocked.model_output = null;
            },
            else => {},
        }
    }
};

test "PreparedToolCall exposes only consuming blocked output access" {
    try std.testing.expect(!@hasDecl(PreparedToolCall, "blockedOutput"));
}

test "non-object function arguments are blocked before hooks with safe replay input" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,
        fn run(raw: *anyopaque, _: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .continue_;
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "observe", .ctx = &capture, .run = Capture.run });
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    for ([_][]const u8{ "[]", "[1]", "42", "null", "true", "\"text\"" }) |arguments| {
        const call = ToolCall{ .id = "rejected", .name = "read_file", .arguments_json = arguments };
        var prepared = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, call);
        defer prepared.deinit(alloc);
        try std.testing.expect(prepared == .blocked);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
        try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
        try std.testing.expectEqualStrings("rejected", prepared.call().id);
        try std.testing.expectEqualStrings("read_file", prepared.call().name);
        try std.testing.expect(prepared.call().argument_integrity != .valid);
        try std.testing.expect(std.mem.find(u8, prepared.blocked.model_output.?, "object") != null);
        try std.testing.expectEqualStrings(arguments, call.arguments_json);
    }

    const arguments = " {\"items\":[1,{\"nested\":true}]} ";
    var valid = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "valid",
        .name = "read_file",
        .arguments_json = arguments,
    });
    defer valid.deinit(alloc);
    try std.testing.expect(valid == .ready);
    try std.testing.expectEqualStrings(arguments, valid.call().arguments_json);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "non-object calls blocked by policy retain the policy result and safe replay input" {
    const alloc = std.testing.allocator;
    const call = ToolCall{ .id = "held", .name = "read_file", .arguments_json = "[]" };
    var prepared = try makePreparedBlocked(alloc, call, .lifecycle_block, "policy held this call");
    defer prepared.deinit(alloc);
    try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
    try std.testing.expect(prepared.call().argument_integrity != .valid);
    try std.testing.expect(std.mem.find(u8, prepared.blocked.model_output.?, "policy held this call") != null);
    try std.testing.expectEqualStrings("[]", call.arguments_json);
}

test "non-object provider-executed input remains provider owned" {
    const alloc = std.testing.allocator;
    const context = LifecycleContext{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    var prepared = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "native",
        .name = "native_tool",
        .arguments_json = "[]",
        .provenance = .provider_executed,
        .provider_result = "recorded result",
    });
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared == .provider_executed);
    try std.testing.expectEqualStrings("[]", prepared.call().arguments_json);
    try std.testing.expectEqualStrings("recorded result", prepared.call().provider_result.?);
}

fn checkNonObjectPreparationAllocationFailures(alloc: Allocator) !void {
    var prepared = try prepareToolCallForLifecycle(alloc, .{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    }, null, 1, 0, .{ .id = "call", .name = "read_file", .arguments_json = "[1]" });
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared == .blocked);
    try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
}

test "non-object preparation cleans every failed allocation" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkNonObjectPreparationAllocationFailures, .{});
}

fn expectMalformedFeedback(model_output: []const u8, failure: []const u8, raw: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, model_output, raw) == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, model_output, .{});
    defer parsed.deinit();
    const details = parsed.value.object.get("error").?.object.get("details").?.object;
    try std.testing.expectEqualStrings(failure, details.get("failure").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(raw.len)), details.get("received_bytes").?.integer);
}

test "malformed function arguments report the diagnosed input they replaced" {
    const alloc = std.testing.allocator;
    const context = LifecycleContext{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const raw = "{\"path\":\"src/main.zig\",\"offset\":";
    var from_raw = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "raw",
        .name = "read_file",
        .arguments_json = raw,
    });
    defer from_raw.deinit(alloc);
    try std.testing.expect(from_raw == .blocked);
    try std.testing.expectEqualStrings("{}", from_raw.call().arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, from_raw.call().argument_integrity);
    try expectMalformedFeedback(from_raw.blocked.model_output.?, "truncated", raw);

    const provider_raw = "{\"path\":\"a\",}";
    const provider_diagnostic = try types.ToolArgumentDiagnostic.diagnose(alloc, provider_raw);
    var from_provider = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "provider",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
        .argument_diagnostic = provider_diagnostic,
    });
    defer from_provider.deinit(alloc);
    try std.testing.expect(from_provider == .blocked);
    try expectMalformedFeedback(from_provider.blocked.model_output.?, "syntax_error", provider_raw);
}

fn checkMalformedPreparationAllocationFailures(alloc: Allocator) !void {
    var prepared = try prepareToolCallForLifecycle(alloc, .{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    }, null, 1, 0, .{ .id = "call", .name = "read_file", .arguments_json = "{\"path\":[[[" });
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared == .blocked);
    try std.testing.expect(prepared.call().argument_diagnostic != null);
}

test "malformed preparation cleans every failed allocation" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkMalformedPreparationAllocationFailures, .{});
}

pub noinline fn prepareToolCallForLifecycle(
    result_allocator: Allocator,
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    turn_id: u64,
    step_index: usize,
    call: ToolCall,
) !PreparedToolCall {
    return prepareToolCallFromCheckpoint(
        result_allocator,
        lifecycle,
        cancel_flag,
        .{
            .turn_id = turn_id,
            .step_index = step_index,
            .call = call,
        },
    );
}

fn prepareToolCallFromCheckpoint(
    result_allocator: Allocator,
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) !PreparedToolCall {
    const call = checkpoint.call;
    if (call.provenance == .provider_executed) {
        return .{ .provider_executed = try types.dupeToolCall(result_allocator, call) };
    }
    const integrity = if (call.argument_integrity == .valid)
        try types.ToolArgumentIntegrity.classifyFunctionInput(result_allocator, call.arguments_json)
    else
        call.argument_integrity;
    if (integrity != .valid) {
        var rejected = call;
        rejected.argument_integrity = integrity;

        if (integrity == .malformed_json and call.argument_integrity == .valid) {
            rejected.argument_diagnostic = try types.ToolArgumentDiagnostic.diagnose(result_allocator, call.arguments_json);
        }
        return makePreparedBlocked(
            result_allocator,
            rejected,
            .malformed_arguments,
            null,
        );
    }

    var outcome = dispatchPreToolUseCheckpoint(
        lifecycle,
        cancel_flag,
        checkpoint,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.LifecycleFailedClosed => makePreparedBlocked(
                result_allocator,
                call,
                .lifecycle_failed_closed,
                null,
            ),
        };
    };
    defer outcome.deinit(lifecycle.outcome_allocator);
    if (cancelRequested(cancel_flag)) return error.Cancelled;

    return preparedCallFromPreToolUseOutcome(result_allocator, call, outcome);
}

pub fn dispatchStopCheckpoint(
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: StopCheckpoint,
) error{Cancelled}!hooks.StopOutcome {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    var outcome = lifecycle.view.runStop(
        lifecycle.outcome_allocator,
        .{
            .invocation = .{
                .scope = lifecycle.scope,
                .turn_id = checkpoint.turn_id,
                .cancel_flag = cancel_flag,
            },
            .step_index = checkpoint.step_index,
            .assistant_text = checkpoint.assistant_text,
            .provider_disposition = checkpoint.provider_disposition,
            .can_continue = checkpoint.can_continue,
        },
    );
    errdefer outcome.deinit(lifecycle.outcome_allocator);
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    return outcome;
}

pub fn dispatchPostTurnEndCheckpoint(
    lifecycle: LifecycleContext,
    checkpoint: PostTurnEndCheckpoint,
) void {
    lifecycle.view.runPostTurnEnd(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .outcome = checkpoint.outcome,
        .provider_disposition = checkpoint.provider_disposition,
        .error_name = checkpoint.error_name,
        .error_message = checkpoint.error_message,
    });
}

pub fn dispatchAttentionRequiredCheckpoint(
    lifecycle: LifecycleContext,
    checkpoint: AttentionRequiredCheckpoint,
) void {
    lifecycle.view.runAttentionRequired(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .kind = checkpoint.kind,
    });
}

pub fn dispatchUserPromptSubmitCheckpoint(
    lifecycle: LifecycleContext,
    checkpoint: UserPromptSubmitCheckpoint,
) hooks.UserPromptSubmitAction {
    return lifecycle.view.runUserPromptSubmit(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .prompt_text = checkpoint.prompt_text,
        .is_steer = checkpoint.is_steer,
    });
}

pub fn dispatchTurnStartedCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: TurnStartedCheckpoint,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    var fields: std.ArrayList(hooks.external.Field) = .empty;
    try fields.append(arena, .{ .key = "turn_id", .value = unsignedIntegerValue(checkpoint.turn_id) });
    try fields.append(arena, .{ .key = "origin_kind", .value = .{ .string = checkpoint.origin.kind } });
    if (checkpoint.origin.name) |name| {
        try fields.append(arena, .{ .key = "origin_name", .value = .{ .string = name } });
    }
    try fields.append(arena, .{ .key = "prompt", .value = .{ .string = checkpoint.prompt } });
    lifecycle.view.runObservation(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .event = .TurnStarted,
        .matcher_value = checkpoint.origin.kind,
        .fields = fields.items,
    });
}

pub const PermissionRequestCheckpoint = struct {
    turn_id: u64,
    call: ToolCall,
};

pub const PermissionResultCheckpoint = struct {
    turn_id: u64,
    call: ToolCall,
    decision: types.ToolPermissionDecision,
};

pub const UserPromptQueuedCheckpoint = struct {
    turn_id: u64,
    prompt_id: u64,
    prompt: []const u8,
    queue_length: usize,
};

pub const PermissionBridge = struct {
    lifecycle: LifecycleContext,

    pub fn observer(self: *PermissionBridge) PermissionObserver {
        return .{ .ctx = self, .request = request, .result = result };
    }

    fn request(ctx: *anyopaque, turn_id: u64, call: ToolCall) void {
        const self: *PermissionBridge = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.lifecycle.outcome_allocator);
        defer arena.deinit();
        dispatchPermissionRequestCheckpoint(self.lifecycle, arena.allocator(), .{ .turn_id = turn_id, .call = call }) catch {};
    }

    fn result(ctx: *anyopaque, turn_id: u64, call: ToolCall, decision: types.ToolPermissionDecision) void {
        const self: *PermissionBridge = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.lifecycle.outcome_allocator);
        defer arena.deinit();
        dispatchPermissionResultCheckpoint(self.lifecycle, arena.allocator(), .{ .turn_id = turn_id, .call = call, .decision = decision }) catch {};
    }
};

pub fn dispatchPermissionRequestCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: PermissionRequestCheckpoint,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    lifecycle.view.runObservation(.{
        .invocation = .{ .scope = lifecycle.scope, .turn_id = checkpoint.turn_id },
        .event = .PermissionRequest,
        .matcher_value = checkpoint.call.name,
        .fields = try toolFields(arena, checkpoint.call),
    });
}

pub fn dispatchPermissionResultCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: PermissionResultCheckpoint,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    var fields: std.ArrayList(hooks.external.Field) = .empty;
    try fields.appendSlice(arena, try toolFields(arena, checkpoint.call));
    try fields.append(arena, .{ .key = "decision", .value = .{ .string = @tagName(checkpoint.decision) } });
    lifecycle.view.runObservation(.{
        .invocation = .{ .scope = lifecycle.scope, .turn_id = checkpoint.turn_id },
        .event = .PermissionResult,
        .matcher_value = checkpoint.call.name,
        .fields = fields.items,
    });
}

pub fn dispatchUserPromptQueuedCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: UserPromptQueuedCheckpoint,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    var fields: std.ArrayList(hooks.external.Field) = .empty;
    try fields.append(arena, .{ .key = "prompt_id", .value = unsignedIntegerValue(checkpoint.prompt_id) });
    try fields.append(arena, .{ .key = "prompt", .value = .{ .string = checkpoint.prompt } });
    try fields.append(arena, .{ .key = "queue_length", .value = unsignedIntegerValue(checkpoint.queue_length) });
    lifecycle.view.runObservation(.{
        .invocation = .{ .scope = lifecycle.scope, .turn_id = checkpoint.turn_id },
        .event = .UserPromptQueued,
        .matcher_value = checkpoint.prompt,
        .fields = fields.items,
    });
}

fn toolFields(arena: Allocator, call: ToolCall) ![]const hooks.external.Field {
    const fields = try arena.alloc(hooks.external.Field, 3);
    fields[0] = .{ .key = "tool_name", .value = .{ .string = call.name } };
    fields[1] = .{ .key = "tool_input", .value = try toolInputValue(arena, call.arguments_json) };
    fields[2] = .{ .key = "tool_call_id", .value = .{ .string = call.id } };
    return fields;
}

pub fn dispatchToolObservationCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: ToolObservationCheckpoint,
) !void {
    try runToolObservation(lifecycle, arena, checkpoint, null);
}

pub fn dispatchToolObservationRevision(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: ToolObservationCheckpoint,
    model_output: []const u8,
) !?[]const u8 {
    if (!lifecycle.view.hasObservation()) return null;
    var outcome: hooks.ObservationOutcome = .{ .alloc = arena };
    defer outcome.deinit();
    try runToolObservation(lifecycle, arena, checkpoint, &outcome);
    return revisedToolOutput(arena, model_output, outcome);
}

pub fn revisedToolOutput(arena: Allocator, model_output: []const u8, outcome: hooks.ObservationOutcome) !?[]const u8 {
    if (outcome.updated_tool_output == null and !outcome.blocked and outcome.additional_context == null) return null;
    var text: std.ArrayList(u8) = .empty;
    const base: []const u8 = if (outcome.updated_tool_output) |replacement| clipToHookLimit(replacement) else model_output;
    try text.appendSlice(arena, base);
    if (outcome.blocked) {
        const reason: []const u8 = if (outcome.reason) |owned| owned else "";
        try appendHookNote(arena, &text, if (reason.len != 0) reason else "Blocked by PostToolUse hook");
    }
    if (outcome.additional_context) |context| try appendHookNote(arena, &text, context);
    return text.items;
}

fn appendHookNote(arena: Allocator, text: *std.ArrayList(u8), note: []const u8) !void {
    const rendered = try hooks.external.renderHookResult(arena, .PostToolUse, clipToHookLimit(note));
    if (text.items.len != 0) try text.appendSlice(arena, "\n\n");
    try text.appendSlice(arena, rendered);
}

fn clipToHookLimit(text: []const u8) []const u8 {
    if (text.len <= hooks.Limits.context_bytes) return text;
    var end: usize = hooks.Limits.context_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn runToolObservation(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: ToolObservationCheckpoint,
    outcome: ?*hooks.ObservationOutcome,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    var fields: std.ArrayList(hooks.external.Field) = .empty;
    try fields.append(arena, .{ .key = "tool_name", .value = .{ .string = checkpoint.call.name } });
    try fields.append(arena, .{ .key = "tool_input", .value = try toolInputValue(arena, checkpoint.call.arguments_json) });
    try fields.append(arena, .{ .key = "tool_call_id", .value = .{ .string = checkpoint.call.id } });
    if (checkpoint.failed) {
        try fields.append(arena, .{ .key = "error", .value = try toolErrorValue(arena, checkpoint.output) });
    } else {
        try fields.append(arena, .{ .key = "tool_output", .value = .{ .string = hooks.external.toolOutputPreview(checkpoint.output) } });
    }
    lifecycle.view.runObservation(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
            .cancel_flag = checkpoint.cancel_flag,
        },
        .event = if (checkpoint.failed) .PostToolUseFailure else .PostToolUse,
        .matcher_value = checkpoint.call.name,
        .fields = fields.items,
        .outcome = outcome,
    });
}

pub const ToolBatchCheckpoint = struct {
    turn_id: u64,
    calls: []const ToolCall,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub fn dispatchToolBatchCheckpoint(
    lifecycle: LifecycleContext,
    arena: Allocator,
    checkpoint: ToolBatchCheckpoint,
) !void {
    if (!lifecycle.view.hasObservation()) return;
    if (checkpoint.calls.len == 0) return;
    var tool_calls = std.json.Array.init(arena);
    for (checkpoint.calls) |call| {
        var entry: std.json.Value = .{ .object = .empty };
        try entry.object.put(arena, "tool_name", .{ .string = call.name });
        try entry.object.put(arena, "tool_call_id", .{ .string = call.id });
        try tool_calls.append(entry);
    }
    const fields = [_]hooks.external.Field{
        .{ .key = "turn_id", .value = unsignedIntegerValue(checkpoint.turn_id) },
        .{ .key = "tool_calls", .value = .{ .array = tool_calls } },
    };
    lifecycle.view.runObservation(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
            .cancel_flag = checkpoint.cancel_flag,
        },
        .event = .PostToolBatch,
        .fields = &fields,
    });
}

fn unsignedIntegerValue(value: u64) std.json.Value {
    return .{ .integer = std.math.cast(i64, value) orelse std.math.maxInt(i64) };
}

fn toolInputValue(arena: Allocator, arguments_json: []const u8) !std.json.Value {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .object = .empty },
    };
    return switch (parsed) {
        .object => parsed,
        else => .{ .object = .empty },
    };
}

fn toolErrorValue(arena: Allocator, output: []const u8) !std.json.Value {
    var error_value: std.json.Value = .{ .object = .empty };
    try error_value.object.put(arena, "code", .{ .string = "internal" });
    try error_value.object.put(arena, "message", .{ .string = output });
    try error_value.object.put(arena, "retryable", .{ .bool = false });
    return error_value;
}

test "turn started observation carries the turn id, origin kind, origin name and prompt" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        seen: usize = 0,
        event: ?hooks.external.Event = null,
        matcher_is_origin: bool = false,
        field_count: usize = 0,
        has_origin_name: bool = false,
        turn_id: i64 = 0,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.seen += 1;
            self.event = input.event;
            self.matcher_is_origin = std.mem.eql(u8, input.matcher_value, "system_trigger");
            self.field_count = input.fields.len;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "origin_name")) self.has_origin_name = true;
                if (std.mem.eql(u8, field.key, "turn_id")) self.turn_id = field.value.integer;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    try dispatchTurnStartedCheckpoint(context, arena_state.allocator(), .{
        .turn_id = 7,
        .origin = .{ .kind = "system_trigger", .name = "subagent" },
        .prompt = "report",
    });
    try std.testing.expectEqual(@as(usize, 1), capture.seen);
    try std.testing.expectEqual(hooks.external.Event.TurnStarted, capture.event.?);
    try std.testing.expect(capture.matcher_is_origin);
    try std.testing.expectEqual(@as(usize, 4), capture.field_count);
    try std.testing.expect(capture.has_origin_name);
    try std.testing.expectEqual(@as(i64, 7), capture.turn_id);
}

test "turn started observation omits origin name when the origin has none" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        field_count: usize = 0,
        has_origin_name: bool = false,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.field_count = input.fields.len;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "origin_name")) self.has_origin_name = true;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    try dispatchTurnStartedCheckpoint(context, arena_state.allocator(), .{
        .turn_id = 1,
        .origin = .{ .kind = "user" },
        .prompt = "hello",
    });
    try std.testing.expectEqual(@as(usize, 3), capture.field_count);
    try std.testing.expect(!capture.has_origin_name);
}

test "user prompt submit checkpoint returns the handler action and allows without handlers" {
    const alloc = std.testing.allocator;
    const Append = struct {
        const text = "<hook_result hook_event=\"UserPromptSubmit\">\nnote\n</hook_result>";

        fn run(_: *anyopaque, _: hooks.UserPromptSubmitInput) hooks.HandlerError!hooks.UserPromptSubmitAction {
            return .{ .append = text };
        }
    };
    var marker: u8 = 0;
    var empty_runtime = hooks.Runtime.init(alloc);
    defer empty_runtime.deinit();
    const empty_context = LifecycleContext{
        .view = empty_runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const allowed = dispatchUserPromptSubmitCheckpoint(empty_context, .{ .turn_id = 1, .prompt_text = "hi", .is_steer = false });
    try std.testing.expect(std.meta.activeTag(allowed) == .allow);

    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerUserPromptSubmit(.{ .name = "append", .ctx = &marker, .run = Append.run });
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const action = dispatchUserPromptSubmitCheckpoint(context, .{ .turn_id = 1, .prompt_text = "hi", .is_steer = true });
    try std.testing.expect(std.meta.activeTag(action) == .append);
    try std.testing.expectEqualStrings(Append.text, action.append);
}

test "tool observation reports PostToolUse with a capped output preview" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        event: ?hooks.external.Event = null,
        matcher_is_tool: bool = false,
        output_len: usize = 0,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.event = input.event;
            self.matcher_is_tool = std.mem.eql(u8, input.matcher_value, "read_file");
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "tool_output")) self.output_len = field.value.string.len;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const long_output = &@as([3000]u8, @splat('a'));
    try dispatchToolObservationCheckpoint(context, arena_state.allocator(), .{
        .turn_id = 3,
        .call = .{ .id = "call_read", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
        .failed = false,
        .output = long_output,
    });
    try std.testing.expectEqual(hooks.external.Event.PostToolUse, capture.event.?);
    try std.testing.expect(capture.matcher_is_tool);
    try std.testing.expectEqual(@as(usize, 2000), capture.output_len);
}

test "tool observation hands the turn's cancel flag to PostToolUse and PostToolUseFailure" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        flags: [2]?*std.atomic.Value(bool) = .{ null, null },
        seen: usize = 0,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.flags[self.seen] = input.invocation.cancel_flag;
            self.seen += 1;
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    var turn_cancel = std.atomic.Value(bool).init(false);
    for ([_]bool{ false, true }) |failed| {
        try dispatchToolObservationCheckpoint(context, arena_state.allocator(), .{
            .turn_id = 3,
            .call = .{ .id = "call_read", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
            .failed = failed,
            .output = "out",
            .cancel_flag = &turn_cancel,
        });
    }
    try std.testing.expectEqual(@as(usize, 2), capture.seen);
    try std.testing.expect(capture.flags[0] == &turn_cancel);
    try std.testing.expect(capture.flags[1] == &turn_cancel);
}

test "tool observation reports PostToolUseFailure with an internal error object" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        event: ?hooks.external.Event = null,
        error_code: []const u8 = "",
        has_tool_output: bool = false,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.event = input.event;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "tool_output")) self.has_tool_output = true;
                if (std.mem.eql(u8, field.key, "error")) self.error_code = field.value.object.get("code").?.string;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    try dispatchToolObservationCheckpoint(context, arena_state.allocator(), .{
        .turn_id = 3,
        .call = .{ .id = "call_bad", .name = "read_file", .arguments_json = "{}" },
        .failed = true,
        .output = "boom",
    });
    try std.testing.expectEqual(hooks.external.Event.PostToolUseFailure, capture.event.?);
    try std.testing.expectEqualStrings("internal", capture.error_code);
    try std.testing.expect(!capture.has_tool_output);
}

test "tool observation input keeps object arguments and drops other shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const object = try toolInputValue(arena, "{\"path\":\"a.txt\"}");
    try std.testing.expectEqualStrings("a.txt", object.object.get("path").?.string);
    const array = try toolInputValue(arena, "[1]");
    try std.testing.expectEqual(@as(usize, 0), array.object.count());
    const malformed = try toolInputValue(arena, "{\"path\":");
    try std.testing.expectEqual(@as(usize, 0), malformed.object.count());
}

fn dispatchPreToolUseCheckpoint(
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) PreToolUseDispatchError!hooks.PreToolUseOutcome {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    return lifecycle.view.runPreToolUse(
        lifecycle.outcome_allocator,
        preToolUseInputFromCheckpoint(lifecycle.scope, cancel_flag, checkpoint),
    ) catch |err| {
        if (cancelRequested(cancel_flag)) return error.Cancelled;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HandlerFailed,
            error.Cancelled,
            error.InvalidHandlerOutput,
            error.HandlerOutputTooLarge,
            => error.LifecycleFailedClosed,
        };
    };
}

fn preToolUseInputFromCheckpoint(
    scope: hooks.Scope,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) hooks.PreToolUseInput {
    return .{
        .invocation = .{
            .scope = scope,
            .turn_id = checkpoint.turn_id,
            .cancel_flag = cancel_flag,
        },
        .step_index = checkpoint.step_index,
        .call_id = checkpoint.call.id,
        .tool_name = checkpoint.call.name,
        .arguments_json = checkpoint.call.arguments_json,
    };
}

fn preparedCallFromPreToolUseOutcome(
    alloc: Allocator,
    call: ToolCall,
    outcome: hooks.PreToolUseOutcome,
) !PreparedToolCall {
    return switch (outcome) {
        .unchanged => .{ .ready = try types.dupeToolCall(alloc, call) },
        .rewritten => |arguments_json| .{
            .ready = try dupeToolCallWithArguments(
                alloc,
                call,
                arguments_json,
            ),
        },
        .blocked => |reason| try makePreparedBlocked(
            alloc,
            call,
            .lifecycle_block,
            reason,
        ),
    };
}

pub fn dupeBlockedToolCall(alloc: Allocator, call: ToolCall) !ToolCall {
    var replay = call;
    if (call.provenance != .provider_executed) {
        replay.argument_integrity = if (call.argument_integrity == .valid)
            try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, call.arguments_json)
        else
            call.argument_integrity;
        if (replay.argument_integrity != .valid) replay.arguments_json = "{}";
    }
    return types.dupeToolCall(alloc, replay);
}

fn makePreparedBlocked(
    alloc: Allocator,
    call: ToolCall,
    kind: PreparedToolBlockKind,
    reason: ?[]const u8,
) !PreparedToolCall {
    const owned_call = try dupeBlockedToolCall(alloc, call);
    errdefer types.freeToolCall(alloc, owned_call);
    const model_output = switch (kind) {
        .malformed_arguments => if (call.argument_integrity == .non_object_json)
            try tool_result_errors.nonObjectToolArgumentsJson(alloc, call.name)
        else
            try tool_result_errors.malformedToolArgumentsJson(alloc, call.name, call.argument_diagnostic),
        .lifecycle_block => try tool_result_errors.preToolUseBlockedJson(
            alloc,
            call.name,
            reason.?,
        ),
        .lifecycle_failed_closed => try tool_result_errors.preToolUseFailedClosedJson(
            alloc,
            call.name,
        ),
        .route_unavailable, .required_vision => unreachable,
    };
    return .{ .blocked = .{
        .call = owned_call,
        .model_output = model_output,
        .kind = kind,
    } };
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

fn dupeToolCallWithArguments(
    alloc: Allocator,
    call: ToolCall,
    arguments_json: []const u8,
) !ToolCall {
    var copy = try types.dupeToolCall(alloc, call);
    errdefer types.freeToolCall(alloc, copy);
    const rewritten = try alloc.dupe(u8, arguments_json);
    alloc.free(copy.arguments_json);
    copy.arguments_json = rewritten;
    copy.argument_integrity = .valid;
    copy.argument_diagnostic = null;
    return copy;
}

test "permission request and result observations carry the tool and the decision" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        events: [2]?hooks.external.Event = .{ null, null },
        seen: usize = 0,
        matchers: [2][]const u8 = .{ "", "" },
        decision: []const u8 = "",
        has_tool_input: bool = false,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.events[self.seen] = input.event;
            self.matchers[self.seen] = input.matcher_value;
            self.seen += 1;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "decision")) self.decision = field.value.string;
                if (std.mem.eql(u8, field.key, "tool_input")) self.has_tool_input = field.value == .object;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const call = ToolCall{ .id = "call-1", .name = "shell.run", .arguments_json = "{\"command\":\"ls\"}" };
    try dispatchPermissionRequestCheckpoint(context, arena_state.allocator(), .{ .turn_id = 3, .call = call });
    try dispatchPermissionResultCheckpoint(context, arena_state.allocator(), .{ .turn_id = 3, .call = call, .decision = .once });
    try std.testing.expectEqual(@as(usize, 2), capture.seen);
    try std.testing.expectEqual(hooks.external.Event.PermissionRequest, capture.events[0].?);
    try std.testing.expectEqual(hooks.external.Event.PermissionResult, capture.events[1].?);
    try std.testing.expectEqualStrings("shell.run", capture.matchers[0]);
    try std.testing.expectEqualStrings("once", capture.decision);
    try std.testing.expect(capture.has_tool_input);
}

test "user prompt queued observation carries the prompt id, text and queue length" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        event: ?hooks.external.Event = null,
        matcher: []const u8 = "",
        prompt_id: i64 = -1,
        queue_length: i64 = -1,

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.event = input.event;
            self.matcher = input.matcher_value;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "prompt_id")) self.prompt_id = field.value.integer;
                if (std.mem.eql(u8, field.key, "queue_length")) self.queue_length = field.value.integer;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    try dispatchUserPromptQueuedCheckpoint(context, arena_state.allocator(), .{
        .turn_id = 4,
        .prompt_id = 9,
        .prompt = "after this",
        .queue_length = 2,
    });
    try std.testing.expectEqual(hooks.external.Event.UserPromptQueued, capture.event.?);
    try std.testing.expectEqualStrings("after this", capture.matcher);
    try std.testing.expectEqual(@as(i64, 9), capture.prompt_id);
    try std.testing.expectEqual(@as(i64, 2), capture.queue_length);
}

test "permission bridge turns the callback into PermissionRequest then PermissionResult with the decision" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        events: [2]?hooks.external.Event = .{ null, null },
        turn_ids: [2]u64 = .{ 0, 0 },
        seen: usize = 0,
        decision: []const u8 = "",

        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.events[self.seen] = input.event;
            self.turn_ids[self.seen] = input.invocation.turn_id orelse 0;
            self.seen += 1;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "decision")) self.decision = field.value.string;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var bridge = PermissionBridge{ .lifecycle = .{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    } };
    const observer = bridge.observer();
    const call = ToolCall{ .id = "call-2", .name = "shell.run", .arguments_json = "{}" };
    observer.request(observer.ctx, 9, call);
    observer.result(observer.ctx, 9, call, .once);
    try std.testing.expectEqual(@as(usize, 2), capture.seen);
    try std.testing.expectEqual(hooks.external.Event.PermissionRequest, capture.events[0].?);
    try std.testing.expectEqual(hooks.external.Event.PermissionResult, capture.events[1].?);
    try std.testing.expectEqual(@as(u64, 9), capture.turn_ids[0]);
    try std.testing.expectEqualStrings("once", capture.decision);
}

test "a PostToolUse hook outcome replaces the tool output and appends its block reason and context" {
    const alloc = std.testing.allocator;
    const Reviser = struct {
        fn run(_: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const outcome = input.outcome orelse return;
            outcome.updated_tool_output = outcome.alloc.dupe(u8, "redacted") catch return error.Failed;
            outcome.blocked = true;
            outcome.reason = outcome.alloc.dupe(u8, "lint failed") catch return error.Failed;
            outcome.additional_context = outcome.alloc.dupe(u8, "see lint.log") catch return error.Failed;
        }
    };
    var marker: u8 = 0;
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "reviser", .ctx = &marker, .run = Reviser.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const revised = (try dispatchToolObservationRevision(context, arena_state.allocator(), .{
        .turn_id = 1,
        .call = .{ .id = "call-1", .name = "bash", .arguments_json = "{}" },
        .failed = false,
        .output = "secret",
    }, "secret")) orelse return error.TestExpectedRevision;
    try std.testing.expectEqualStrings(
        "redacted\n\n<hook_result hook_event=\"PostToolUse\">\nlint failed\n</hook_result>\n\n<hook_result hook_event=\"PostToolUse\">\nsee lint.log\n</hook_result>",
        revised,
    );
}

test "a tool output stays as it is when no PostToolUse hook answers" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const untouched: hooks.ObservationOutcome = .{ .alloc = arena_state.allocator() };
    try std.testing.expect((try revisedToolOutput(arena_state.allocator(), "output", untouched)) == null);

    var empty_runtime = hooks.Runtime.init(alloc);
    defer empty_runtime.deinit();
    const context = LifecycleContext{
        .view = empty_runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    try std.testing.expect((try dispatchToolObservationRevision(context, arena_state.allocator(), .{
        .turn_id = 1,
        .call = .{ .id = "call-1", .name = "bash", .arguments_json = "{}" },
        .failed = false,
        .output = "output",
    }, "output")) == null);

    const context_only: hooks.ObservationOutcome = .{
        .alloc = arena_state.allocator(),
        .additional_context = try arena_state.allocator().dupe(u8, "note"),
    };
    const appended = (try revisedToolOutput(arena_state.allocator(), "output", context_only)) orelse return error.TestExpectedRevision;
    try std.testing.expectEqualStrings("output\n\n<hook_result hook_event=\"PostToolUse\">\nnote\n</hook_result>", appended);
}

test "a parallel tool batch reports PostToolBatch once with every call in it" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        batches: usize = 0,
        call_count: usize = 0,
        fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input.event != .PostToolBatch) return;
            self.batches += 1;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "tool_calls")) self.call_count = field.value.array.items.len;
            }
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "capture", .ctx = &capture, .run = Capture.run });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .interactive, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    const calls = [_]ToolCall{
        .{ .id = "call-1", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "grep", .arguments_json = "{}" },
    };
    try dispatchToolBatchCheckpoint(context, arena_state.allocator(), .{ .turn_id = 4, .calls = &calls });
    try std.testing.expectEqual(@as(usize, 1), capture.batches);
    try std.testing.expectEqual(@as(usize, 2), capture.call_count);

    try dispatchToolBatchCheckpoint(context, arena_state.allocator(), .{ .turn_id = 4, .calls = &.{} });
    try std.testing.expectEqual(@as(usize, 1), capture.batches);
}
