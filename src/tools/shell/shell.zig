const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const builtin = @import("builtin");
const command_admission = @import("../../core/permissions/command_admission.zig");
const command_contract = @import("../../core/execution/command_contract.zig");
const command_environment = @import("../../core/execution/command_environment.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const managed_contract = @import("../../core/execution/managed_execution_contract.zig");
const mcp_call_bridge = @import("../../core/mcp_host/mcp_call_bridge.zig");
const io_mod = @import("../../core/shared/io.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const terminal_identity = @import("../../core/terminal/identity.zig");
const terminal_action_executor = @import("../../core/terminal/action_executor.zig");
const terminal_managed_observer = @import("../../core/terminal/managed_observer.zig");
const terminal_operation = @import("../../core/terminal/operation.zig");
const terminal_store = @import("../../core/terminal/store.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");
const shell_snapshot = @import("../../core/terminal/shell_snapshot.zig");
const wait_habits = @import("../../core/shell_command/wait_habits.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const subagent_model_contract = @import("../../core/subagent/model_contract.zig");
const subagent_tool_provider = @import("../../core/subagent/tool_provider.zig");
const terminal_contracts = @import("../../core/terminal/contracts.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const result_commit = @import("../../core/tooling/result_commit.zig");
const result_store = @import("../../core/session/result_store.zig");
const types = @import("../../core/shared/types.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum {
    run,
    interact,
    stop,
};

const ShellKind = enum { executable };

pub const ShellInput = struct {
    kind: ShellKind,
    path: []const u8,
    clean_start: bool = false,
};

pub const Input = struct {
    action: Action,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    profile: ?command_environment.Profile = null,
    shell: ?ShellInput = null,
    tty: bool = false,
    yield_time_ms: u32 = managed_contract.default_yield_time_ms,
    timeout_ms: ?u64 = null,
    reload: bool = false,
    session_id: ?[]const u8 = null,
    chars: ?[]const u8 = null,
    force: bool = false,
    stop_reason: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    background: bool = false,
    tail_bytes: ?u32 = null,
};

pub const public_field_names: []const []const u8 = blk: {
    var names: []const []const u8 = &.{};
    for (@typeInfo(Input).@"struct".field_names) |field_name| {
        if (anyActionAllowsField(field_name)) names = names ++ &[_][]const u8{field_name};
    }
    break :blk names;
};

fn anyActionAllowsField(comptime field_name: []const u8) bool {
    for (std.enums.values(Action)) |action| {
        for (actionFieldContract(action).allowed) |allowed| {
            if (std.mem.eql(u8, field_name, allowed)) return true;
        }
    }
    return false;
}

pub const ActionFieldContract = struct {
    allowed: []const []const u8,
    required: []const []const u8,
    conflicts: []const tool_result_errors.TerminalActionFieldConflict = &.{},
};

pub fn actionFieldContract(action: Action) ActionFieldContract {
    return switch (action) {
        .run => .{
            .allowed = &.{ "action", "command", "cwd", "profile", "shell", "tty", "yield_time_ms", "timeout_ms", "reload" },
            .required = &.{ "action", "command" },
            .conflicts = &.{.{ "profile", "shell" }},
        },
        .interact => .{
            .allowed = &.{ "action", "session_id", "chars", "yield_time_ms" },
            .required = &.{ "action", "session_id" },
        },
        .stop => .{
            .allowed = &.{ "action", "session_id", "force" },
            .required = &.{ "action", "session_id" },
        },
    };
}

const OwnedInput = struct {
    arena_state: std.heap.ArenaAllocator.State,
    value: Input,

    fn deinit(self: *OwnedInput, alloc: Allocator) void {
        self.arena_state.promote(alloc).deinit();
        self.* = undefined;
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (try decode_input(ctx, args_json)) |input| return .{ .input = input };
    return .{ .failure = try request_correction(ctx.allocator, args_json, ctx.session_child_capability != null) };
}

const bash_foreground_default_timeout_s: i64 = 60;
const bash_foreground_max_timeout_s: i64 = 60 * 60;
const bash_background_default_timeout_s: i64 = 10 * 60;
const bash_background_max_timeout_s: i64 = 24 * 60 * 60;
const bash_foreground_default_timeout_env = "BASH_DEFAULT_TIMEOUT_MS";
const bash_foreground_max_timeout_env = "BASH_MAX_TIMEOUT_MS";
const bash_foreground_env_ceiling_refusal = "Bash timeout exceeds BASH_MAX_TIMEOUT_MS for a foreground command; use run_in_background for longer work.";
const bash_shape_failure = "Bash arguments must be a JSON object with command and the Bash fields only. Accepted fields: command, cwd, timeout, description, run_in_background, disable_timeout, name.";
const task_shape_failure = "Task arguments must be a JSON object with task_id.";
const task_output_shape_failure = "TaskOutput arguments must be a JSON object with task_id and optional wait and tail.";
const legacy_shell_max_yield_time_ms: u32 = 30_000;
const task_output_min_wait_s: i64 = 1;
const task_output_max_wait_s: i64 = managed_contract.max_wait_ceiling_ms / std.time.ms_per_s;
const task_output_wait_refusal = "TaskOutput wait must be an integer from 1 to 600 seconds.";
const task_output_max_tail_bytes: i64 = 32 * 1024;
const task_output_tail_refusal = "TaskOutput tail must be an integer from 1 to 32768 bytes.";
const bash_background_disabled_refusal = "Bash run_in_background is turned off here (CLAUDE_CODE_DISABLE_BACKGROUND_TASKS or setting task.background_disabled); run the command in the foreground.";
const bash_name_background_refusal = "Bash name applies only when run_in_background is true.";
const bash_name_shape_refusal = "Bash name must be 1 to 64 characters from A-Z, a-z, 0-9, underscore and hyphen.";
const default_stop_reason = "Stopped by TaskStop";

const BashArguments = struct {
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    timeout: ?i64 = null,
    description: ?[]const u8 = null,
    run_in_background: ?bool = null,
    disable_timeout: ?bool = null,
    name: ?[]const u8 = null,
};

const bash_field_names = blk: {
    const field_names = @typeInfo(BashArguments).@"struct".field_names;
    var names: [field_names.len][]const u8 = undefined;
    for (field_names, 0..) |field_name, index| names[index] = field_name;
    break :blk names;
};

fn bashShapeFailure(
    ctx: tool_dispatch.DispatchContext,
    scratch: Allocator,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(ctx, bash_shape_failure),
    };
    if (parsed != .object) return failureResult(ctx, bash_shape_failure);
    const unknown = tool_args.firstUnknownKey(parsed.object, &bash_field_names) orelse
        return failureResult(ctx, bash_shape_failure);
    return .{ .failure = try tool_args.unknownArgumentMessage(ctx.allocator, "Bash", unknown, &bash_field_names) };
}

const TaskOutputArguments = struct {
    task_id: ?[]const u8 = null,
    wait: ?i64 = null,
    tail: ?i64 = null,
};

const TaskStopArguments = struct {
    task_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

fn failureResult(ctx: tool_dispatch.DispatchContext, message: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, message) };
}

fn ownInput(
    alloc: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    input: Input,
) Allocator.Error!tool_dispatch.ToolInput {
    const owned = try alloc.create(OwnedInput);
    owned.* = .{
        .arena_state = arena_state.state,
        .value = input,
    };
    arena_state.state = .init;
    return .{
        .ptr = owned,
        .deinit_fn = inputDeinit,
    };
}

fn timeoutSecondsFromEnvMs(raw: ?[]const u8) ?i64 {
    const text = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    const milliseconds = std.fmt.parseInt(i64, text, 10) catch return null;
    if (milliseconds < 1) return null;
    const capped_ms = @min(milliseconds, bash_background_max_timeout_s * std.time.ms_per_s);
    return @divFloor(capped_ms + std.time.ms_per_s - 1, std.time.ms_per_s);
}

fn foregroundMaxTimeoutS(max_env: ?[]const u8) i64 {
    return timeoutSecondsFromEnvMs(max_env) orelse bash_foreground_max_timeout_s;
}

fn foregroundDefaultTimeoutS(default_env: ?[]const u8, max_env: ?[]const u8) i64 {
    const wanted = timeoutSecondsFromEnvMs(default_env) orelse bash_foreground_default_timeout_s;
    return @min(wanted, foregroundMaxTimeoutS(max_env));
}

fn foregroundTimeoutRefusal(timeout: i64, max_env: ?[]const u8) ?[]const u8 {
    if (timeout <= foregroundMaxTimeoutS(max_env)) return null;
    if (timeoutSecondsFromEnvMs(max_env) != null) return bash_foreground_env_ceiling_refusal;
    return "Bash timeout must be at most 3600 seconds for a foreground command; use run_in_background for longer work.";
}

fn bashProblem(arguments: BashArguments) ?[]const u8 {
    const command = arguments.command orelse return "Bash requires command.";
    if (command.len == 0) return "Bash command cannot be empty.";
    const background = arguments.run_in_background orelse false;
    if (background and managed_contract.taskSettings().background_disabled) return bash_background_disabled_refusal;
    if (arguments.timeout) |timeout| {
        if (timeout < 1) return "Bash timeout must be a positive number of seconds.";
        if (background and timeout > bash_background_max_timeout_s) return "Bash timeout must be at most 86400 seconds when run_in_background is true.";
        if (!background) {
            if (foregroundTimeoutRefusal(timeout, io_mod.getenv(bash_foreground_max_timeout_env))) |refusal| return refusal;
        }
    }
    if (background) {
        const description = arguments.description orelse return "Bash requires description when run_in_background is true.";
        if (std.mem.trim(u8, description, " \t\r\n").len == 0) return "Bash requires description when run_in_background is true.";
    }
    if (arguments.name) |name| {
        if (!background) return bash_name_background_refusal;
        if (!managed_contract.validTaskName(name)) return bash_name_shape_refusal;
    }
    return null;
}

fn backgroundDefaultTimeoutS(settings: managed_contract.TaskSettings) i64 {
    const configured = settings.background_timeout_s orelse return bash_background_default_timeout_s;
    if (configured == 0) return bash_background_default_timeout_s;
    return @intCast(@min(configured, @as(u64, @intCast(bash_background_max_timeout_s))));
}

fn foregroundYieldTimeMs(explicit_timeout_ms: ?u64, auto_background: bool) u32 {
    const timeout_ms = explicit_timeout_ms orelse return managed_contract.default_yield_time_ms;
    const wanted = if (auto_background)
        timeout_ms
    else
        @max(@as(u64, managed_contract.default_yield_time_ms), timeout_ms);
    return @intCast(@min(wanted, @as(u64, managed_contract.max_yield_time_ms)));
}

fn bashInput(arguments: BashArguments) Input {
    const settings = managed_contract.taskSettings();
    const background = arguments.run_in_background orelse false;
    const background_default_s = backgroundDefaultTimeoutS(settings);
    if (background) {
        const timeout_s: ?i64 = if (arguments.disable_timeout orelse false)
            null
        else
            arguments.timeout orelse background_default_s;
        return .{
            .action = .run,
            .command = arguments.command,
            .cwd = arguments.cwd,
            .yield_time_ms = 0,
            .timeout_ms = if (timeout_s) |seconds| @intCast(seconds * std.time.ms_per_s) else null,
            .task_name = arguments.name,
            .background = true,
        };
    }
    const explicit_timeout_ms: ?u64 = if (arguments.timeout) |seconds| @intCast(seconds * std.time.ms_per_s) else null;
    const foreground_default_s = foregroundDefaultTimeoutS(
        io_mod.getenv(bash_foreground_default_timeout_env),
        io_mod.getenv(bash_foreground_max_timeout_env),
    );
    const foreground_timeout_ms: u64 = explicit_timeout_ms orelse @intCast(foreground_default_s * std.time.ms_per_s);
    const background_default_ms: u64 = @intCast(background_default_s * std.time.ms_per_s);
    return .{
        .action = .run,
        .command = arguments.command,
        .cwd = arguments.cwd,
        .yield_time_ms = foregroundYieldTimeMs(explicit_timeout_ms, settings.auto_background_on_timeout),
        .timeout_ms = if (settings.auto_background_on_timeout)
            @max(foreground_timeout_ms, background_default_ms)
        else
            foreground_timeout_ms,
    };
}

test "BASH_DEFAULT_TIMEOUT_MS and BASH_MAX_TIMEOUT_MS set the foreground Bash default and ceiling" {
    try std.testing.expectEqual(bash_foreground_default_timeout_s, foregroundDefaultTimeoutS(null, null));
    try std.testing.expectEqual(@as(i64, 120), foregroundDefaultTimeoutS("120000", null));
    try std.testing.expectEqual(@as(i64, 2), foregroundDefaultTimeoutS(" 1001 ", null));
    try std.testing.expectEqual(bash_foreground_default_timeout_s, foregroundDefaultTimeoutS("soon", null));
    try std.testing.expectEqual(bash_foreground_default_timeout_s, foregroundDefaultTimeoutS("0", null));
    try std.testing.expectEqual(@as(i64, 30), foregroundDefaultTimeoutS("120000", "30000"));
    try std.testing.expectEqual(bash_foreground_max_timeout_s, foregroundMaxTimeoutS(null));
    try std.testing.expectEqual(@as(i64, 600), foregroundMaxTimeoutS("600000"));
    try std.testing.expectEqual(bash_background_max_timeout_s, foregroundMaxTimeoutS("999999999999"));
    try std.testing.expectEqual(@as(?[]const u8, null), foregroundTimeoutRefusal(600, "600000"));
    try std.testing.expectEqualStrings(bash_foreground_env_ceiling_refusal, foregroundTimeoutRefusal(601, "600000").?);
    try std.testing.expectEqual(@as(?[]const u8, null), foregroundTimeoutRefusal(3600, null));
    try std.testing.expect(foregroundTimeoutRefusal(3601, null) != null);
}

pub fn decodeBash(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arguments = std.json.parseFromSliceLeaky(BashArguments, arena_state.allocator(), args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bashShapeFailure(ctx, arena_state.allocator(), args_json),
    };
    if (bashProblem(arguments)) |problem| return failureResult(ctx, problem);
    return .{ .input = try ownInput(ctx.allocator, &arena_state, bashInput(arguments)) };
}

pub fn decodeTaskOutput(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arguments = std.json.parseFromSliceLeaky(TaskOutputArguments, arena_state.allocator(), args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(ctx, task_output_shape_failure),
    };
    const task_id = arguments.task_id orelse return failureResult(ctx, "TaskOutput requires task_id.");
    if (task_id.len == 0) return failureResult(ctx, "TaskOutput task_id cannot be empty.");
    if (arguments.wait) |wait| {
        if (wait < task_output_min_wait_s or wait > task_output_max_wait_s) return failureResult(ctx, task_output_wait_refusal);
    }
    if (arguments.tail) |tail| {
        if (tail < 1 or tail > task_output_max_tail_bytes) return failureResult(ctx, task_output_tail_refusal);
    }
    return .{ .input = try ownInput(ctx.allocator, &arena_state, .{
        .action = .interact,
        .session_id = task_id,
        .yield_time_ms = if (arguments.wait) |wait| @intCast(wait * std.time.ms_per_s) else 0,
        .tail_bytes = if (arguments.tail) |tail| @intCast(tail) else null,
    }) };
}

pub fn decodeTaskStop(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arguments = std.json.parseFromSliceLeaky(TaskStopArguments, arena_state.allocator(), args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(ctx, task_shape_failure),
    };
    const task_id = arguments.task_id orelse return failureResult(ctx, "TaskStop requires task_id.");
    if (task_id.len == 0) return failureResult(ctx, "TaskStop task_id cannot be empty.");
    const reason = arguments.reason orelse default_stop_reason;
    if (reason.len == 0) return failureResult(ctx, "TaskStop reason cannot be empty.");
    return .{ .input = try ownInput(ctx.allocator, &arena_state, .{
        .action = .stop,
        .session_id = task_id,
        .stop_reason = reason,
    }) };
}

fn withStopReason(
    ctx: tool_dispatch.DispatchContext,
    result: tool_dispatch.ToolResult,
    reason: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    switch (result) {
        .success => |body| {
            defer ctx.allocator.free(body);
            return .{ .success = try std.fmt.allocPrint(ctx.allocator, "reason: {s}\n{s}", .{ reason, body }) };
        },
        .failure => |body| {
            defer ctx.allocator.free(body);
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "reason: {s}\n{s}", .{ reason, body }) };
        },
        .rich => return result,
    }
}

fn decode_input(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!?tool_dispatch.ToolInput {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    var raw = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        args_json,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (raw != .object) return null;
    const raw_action = raw.object.get("action") orelse return null;
    if (raw_action != .string) return null;
    const action = std.meta.stringToEnum(Action, raw_action.string) orelse
        return null;
    elideKnownNullFields(&raw.object);

    var correction_scratch: ActionFieldCorrectionScratch = .{};
    defer correction_scratch.deinit(ctx.allocator);
    if (try actionFieldCorrection(
        ctx.allocator,
        action,
        raw.object,
        &correction_scratch,
    ) != null) return null;
    normalizeCompositeArgument(arena, &raw, "shell") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var input = std.json.parseFromValueLeaky(Input, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    input.yield_time_ms = if (raw.object.get("yield_time_ms") == null)
        defaultYieldTime(action)
    else
        boundedYieldTime(action, input.yield_time_ms);
    if (argument_problem(input) != null) return null;
    const owned = try ctx.allocator.create(OwnedInput);
    owned.* = .{
        .arena_state = arena_state.state,
        .value = input,
    };
    arena_state.state = .init;
    return .{
        .ptr = owned,
        .deinit_fn = inputDeinit,
    };
}

fn defaultYieldTime(action: Action) u32 {
    return switch (action) {
        .run => managed_contract.default_yield_time_ms,
        .interact => managed_contract.default_wait_ceiling_ms,
        .stop => 0,
    };
}

fn boundedYieldTime(action: Action, requested_ms: u32) u32 {
    return switch (action) {
        .run => @min(requested_ms, legacy_shell_max_yield_time_ms),
        .interact => @min(requested_ms, managed_contract.max_wait_ceiling_ms),
        .stop => requested_ms,
    };
}

fn effective_interact_yield_time(has_input: bool, requested_ms: u32) u32 {
    if (!has_input) {
        return @min(
            @max(requested_ms, managed_contract.default_wait_ceiling_ms),
            managed_contract.max_wait_ceiling_ms,
        );
    }
    return @min(requested_ms, legacy_shell_max_yield_time_ms);
}

fn request_correction(alloc: Allocator, args_json: []const u8, supports_tty: bool) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    if (args_json.len > 16 * 1024) {
        return correction_json(alloc, &.{"Arguments are too large to suggest a repair; submit the intended action with only its required fields."}, null);
    }
    const raw = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return correction_json(alloc, &.{"Shell arguments must be a JSON object."}, null),
    };
    if (raw != .object or raw.object.count() > 32) {
        return correction_json(alloc, &.{"Shell arguments must be one bounded object."}, null);
    }

    var problems: std.ArrayList([]const u8) = .empty;
    var repairable = true;
    var object = raw.object;

    if (raw.object.get("request")) |wrapper| {
        try problems.append(arena, "Put the action fields at the top level; shell takes no request wrapper.");
        var request = wrapper;
        if (request == .string) {
            request = std.json.parseFromSliceLeaky(std.json.Value, arena, request.string, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return correction_json(alloc, problems.items, null),
            };
        }
        if (request != .object or request.object.count() > 32) {
            return correction_json(alloc, problems.items, null);
        }
        object = request.object;
        var outer = raw.object.iterator();
        while (outer.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.eql(u8, name, "request")) continue;
            if (object.contains(name)) {
                repairable = false;
            } else {
                try object.put(arena, name, entry.value_ptr.*);
            }
        }
    }
    elideKnownNullFields(&object);
    const action_value = object.get("action");
    const action: Action = if (action_value) |value| blk: {
        if (value == .string) {
            if (std.meta.stringToEnum(Action, value.string)) |action| break :blk action;
        }
        try problems.append(arena, "action must be run, interact, or stop; put the shell command in command.");
        return correction_json(alloc, problems.items, null);
    } else blk: {
        try problems.append(arena, "action is required.");
        const command = object.get("command") orelse return correction_json(alloc, problems.items, null);
        if (command != .string or object.contains("session_id") or object.contains("chars") or object.contains("force")) {
            return correction_json(alloc, problems.items, null);
        }
        try object.put(arena, "action", .{ .string = "run" });
        break :blk .run;
    };

    var scratch: ActionFieldCorrectionScratch = .{};
    if (try actionFieldCorrection(arena, action, object, &scratch)) |correction| {
        for (correction.invalid_fields) |name| {
            try problems.append(arena, try arena.print(
                "{s} is not accepted for {s}.",
                .{ text_utils.utf8PrefixByBytes(name, 64), @tagName(action) },
            ));

            if (object.get(name).? != .null) repairable = false;
            _ = object.orderedRemove(name);
        }
        for (correction.missing_fields) |name| {
            try problems.append(arena, try arena.print("{s} is required for {s}.", .{ name, @tagName(action) }));
            repairable = false;
        }
        for (correction.conflicts) |conflict| {
            try problems.append(arena, try arena.print("Choose either {s} or {s}.", .{ conflict[0], conflict[1] }));
            repairable = false;
        }
    }

    var canonical: std.json.ObjectMap = .empty;
    const input_info = @typeInfo(Input).@"struct";
    inline for (input_info.field_names, input_info.field_types) |field_name, field_type| {
        if (object.get(field_name)) |original| {
            var value = original;
            const T = if (@typeInfo(field_type) == .optional) @typeInfo(field_type).optional.child else field_type;
            const expected = comptime switch (@typeInfo(T)) {
                .int => "an integer",
                .bool => "a boolean",
                .pointer => "a string",
                .@"enum" => "an advertised value",
                else => "an object matching its schema",
            };
            var type_reported = false;
            if (comptime @typeInfo(T) == .int) {
                if (value == .string) {
                    try problems.append(arena, field_name ++ " must be an integer.");
                    type_reported = true;
                    if (std.fmt.parseInt(T, value.string, 10)) |number| {
                        value = if (std.math.cast(i64, number)) |integer|
                            .{ .integer = integer }
                        else
                            .{ .number_string = try arena.print("{d}", .{number}) };
                    } else |_| {
                        repairable = false;
                    }
                }
            }
            if (std.json.parseFromValueLeaky(field_type, arena, value, .{})) |_| {
                if (comptime T == ShellInput) {
                    var shell: std.json.ObjectMap = .empty;
                    inline for (@typeInfo(ShellInput).@"struct".field_names) |member_name| {
                        if (value.object.get(member_name)) |supplied| {
                            try shell.put(arena, member_name, supplied);
                        }
                    }
                    value = .{ .object = shell };
                }
            } else |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (!type_reported) try problems.append(arena, field_name ++ " must be " ++ expected ++ ".");
                repairable = false;
            }
            try canonical.put(arena, field_name, value);
        }
    }
    var candidate = std.json.parseFromValueLeaky(Input, arena, .{ .object = canonical }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return correction_json(alloc, problems.items, null),
    };
    candidate.yield_time_ms = boundedYieldTime(candidate.action, candidate.yield_time_ms);
    if (argument_problem(candidate)) |problem| {
        try problems.append(arena, problem);
        repairable = false;
    }
    if (!supports_tty and (canonical.contains("tty") or canonical.contains("shell") or canonical.contains("chars"))) {
        try problems.append(arena, "Interactive Shell fields require a saved session.");
        repairable = false;
    }
    if (problems.items.len == 0) {
        try problems.append(arena, "Submit one Shell action.");
    }
    return correction_json(alloc, problems.items, if (repairable) canonical else null);
}

fn correction_json(
    alloc: Allocator,
    problems: []const []const u8,
    candidate: ?std.json.ObjectMap,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(.{ .@"error" = .{
        .code = "invalid_shell_request",
        .executed = false,
        .problems = problems,
        .instruction = if (candidate != null) @as(?[]const u8, "Call shell once using retry_with exactly.") else null,
        .retry_with = if (candidate) |object| @as(?std.json.Value, .{ .object = object }) else null,
    } }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn argument_problem(input: Input) ?[]const u8 {
    switch (input.action) {
        .run => {
            const command = input.command orelse return "command is required for run.";
            if (command.len == 0 or command.len > terminal_contracts.max_command_bytes) return "command must contain 1-65536 bytes.";
            if (input.timeout_ms == 0) return "timeout_ms must be at least 1; choose the intended deadline.";
            if (input.profile != null and input.shell != null) return "Choose either profile or shell.";
            if (!input.tty and input.shell != null) return "shell applies only with tty=true; remove shell for an ordinary command, or set tty=true for an interactive terminal.";
        },
        .interact => {
            if (input.chars) |chars| {
                if (chars.len > terminal_contracts.max_write_bytes) return "chars exceed 65536 bytes.";
            }
        },
        .stop => {},
    }
    return null;
}

fn normalizeCompositeArgument(
    alloc: Allocator,
    root: *std.json.Value,
    field_name: []const u8,
) !void {
    const value = root.object.getPtr(field_name) orelse return;
    try tool_args.normalizeCompositeObjectValue(alloc, value);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *OwnedInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn elideKnownNullFields(object: *std.json.ObjectMap) void {
    for (public_field_names[1..]) |field_name| {
        const value = object.get(field_name) orelse continue;
        if (value == .null or
            (value == .string and tool_args.isNullPlaceholderText(value.string)))
        {
            _ = object.orderedRemove(field_name);
        }
    }
}

const ActionFieldCorrectionScratch = struct {
    invalid_fields: std.ArrayList([]const u8) = .empty,
    missing_fields: [public_field_names.len][]const u8 = undefined,
    conflicts: [public_field_names.len]tool_result_errors.TerminalActionFieldConflict = undefined,

    fn deinit(self: *ActionFieldCorrectionScratch, alloc: Allocator) void {
        self.invalid_fields.deinit(alloc);
        self.* = undefined;
    }
};

fn actionFieldCorrection(
    alloc: Allocator,
    action: Action,
    object: std.json.ObjectMap,
    scratch: *ActionFieldCorrectionScratch,
) Allocator.Error!?tool_result_errors.TerminalActionFieldCorrection {
    const field_contract = actionFieldContract(action);
    try scratch.invalid_fields.ensureTotalCapacity(alloc, object.count());
    var fields = object.iterator();
    while (fields.next()) |entry| {
        var allowed = false;
        for (field_contract.allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) scratch.invalid_fields.appendAssumeCapacity(entry.key_ptr.*);
    }
    sort_utils.sort(
        []const u8,
        scratch.invalid_fields.items,
        {},
        struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan,
    );
    var missing_count: usize = 0;
    for (field_contract.required) |name| {
        if (object.get(name) != null) continue;
        scratch.missing_fields[missing_count] = name;
        missing_count += 1;
    }
    var conflict_count: usize = 0;
    for (field_contract.conflicts) |conflict| {
        if (object.get(conflict[0]) == null or object.get(conflict[1]) == null) continue;
        scratch.conflicts[conflict_count] = conflict;
        conflict_count += 1;
    }
    if (scratch.invalid_fields.items.len == 0 and
        missing_count == 0 and
        conflict_count == 0)
    {
        return null;
    }
    return .{
        .action = @tagName(action),
        .invalid_fields = scratch.invalid_fields.items,
        .missing_fields = scratch.missing_fields[0..missing_count],
        .allowed_fields = field_contract.allowed,
        .conflicts = scratch.conflicts[0..conflict_count],
    };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(OwnedInput).value;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    return switch (input.action) {
        .run => validateRun(ctx, arena, input),
        .interact => validateInteract(ctx, input),
        .stop => null,
    };
}

fn validateInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    if (argument_problem(input)) |problem| return try ctx.allocator.dupe(u8, problem);
    return null;
}

fn validateRun(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    if (argument_problem(input)) |problem| return try ctx.allocator.dupe(u8, problem);
    _ = resolveCwd(arena, ctx, input.cwd) catch |err| {
        return try ctx.allocator.print(
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        );
    };
    if (!input.tty) {
        _ = commandEnvironment(arena, ctx, input.profile) catch |err| {
            return try ctx.allocator.print(
                "shell run profile is invalid: {s}",
                .{@errorName(err)},
            );
        };
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => callRun(ctx, input),
        .interact => callInteract(ctx, input),
        .stop => if (input.stop_reason) |reason|
            withStopReason(ctx, try callStop(ctx, input), reason)
        else
            callStop(ctx, input),
    };
}

fn callRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (input.tty) {
        return callTtyRun(ctx, input);
    }
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const execution_authority = ctx.execution_authority orelse return unavailable(ctx);
    const authority = switch (execution_authority) {
        .run_command => |value| value,
        else => return unavailable(ctx),
    };
    const command = input.command orelse return unavailable(ctx);

    if (input.reload) shell_snapshot.processOwner().markDirty(.agent_reload);
    var request_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(request_arena_state);
    const request_arena = request_arena_state.allocator();
    const cwd = resolveCwd(request_arena, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try ctx.allocator.print(
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    const environment = commandEnvironment(
        request_arena,
        ctx,
        input.profile,
    ) catch |err| {
        return .{ .failure = try ctx.allocator.print(
            "shell run profile is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    var execution_id_buffer: [64]u8 = undefined;
    const execution_id = if (input.task_name) |task_name|
        task_name
    else
        runtime.generatedId(&execution_id_buffer) catch |err|
            return runtimeFailure(ctx, err);

    const bridge_registration: ?*mcp_call_bridge.Registration = if (comptime mcp_call_bridge.supported) registration: {
        const capability = ctx.mcp_call_capability orelse break :registration null;
        break :registration mcp_call_bridge.register(capability) catch |err| {
            debug_trace.logf("mcp-call", "shell call not registered with the bridge err={s}", .{@errorName(err)});
            break :registration null;
        };
    } else null;
    defer if (comptime mcp_call_bridge.supported) if (bridge_registration) |registration| mcp_call_bridge.unregister(registration);
    var prepared = runtime.startCaptured(ctx.allocator, .{
        .execution_id = execution_id,
        .command = command,
        .cwd = cwd,
        .environment = environment,
        .authority = authority,
        .extra_environment = if (bridge_registration) |registration| registration.environment() else &.{},
        .yield_hold = if (bridge_registration) |registration| &registration.hold else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .timeout_ms = if (input.timeout_ms) |value|
            std.math.cast(usize, value) orelse return unavailable(ctx)
        else
            ctx.command_timeout_ms,
        .command_artifact_dir = ctx.command_artifact_dir,
        .replay_capability = ctx.session_child_capability,
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .yield_time_ms = input.yield_time_ms,
        .cancel_flag = ctx.cancel_flag,
        .task_name = input.task_name,
        .background = input.background,
    }) catch |err| {
        if (err == error.Cancelled and
            ctx.cancel_flag != null and
            ctx.cancel_flag.?.load(.seq_cst))
        {
            return error.Cancelled;
        }
        if (try taskAdmissionRefusal(ctx.allocator, err, execution_id, runtime.runningTaskLimit())) |message| {
            return .{ .failure = message };
        }
        return runtimeFailure(ctx, err);
    };
    defer prepared.deinit(ctx.allocator);
    const result = try finishPrepared(ctx, runtime, &prepared, .command);
    const noticed = attachSnapshotNotice(ctx.allocator, result) catch |err| {
        result.deinit(ctx.allocator);
        return err;
    };
    return attachWaitNote(ctx.allocator, noticed, command) catch |err| {
        noticed.deinit(ctx.allocator);
        return err;
    };
}

fn taskAdmissionRefusal(
    alloc: Allocator,
    err: anyerror,
    task_name: []const u8,
    running_task_limit: usize,
) Allocator.Error!?[]u8 {
    if (err == error.TaskNameInUse) {
        return try std.fmt.allocPrint(
            alloc,
            "A background task named {s} already exists in this session; pick another name.",
            .{task_name},
        );
    }
    if (err == error.RunningTaskLimitReached) {
        return try std.fmt.allocPrint(
            alloc,
            "The limit of {d} running background tasks is reached (setting task.max_running_tasks). Wait for one with WaitFor or stop one with TaskStop, then start this task again.",
            .{running_task_limit},
        );
    }
    return null;
}

fn attachSnapshotNotice(
    alloc: Allocator,
    result: tool_dispatch.ToolResult,
) Allocator.Error!tool_dispatch.ToolResult {
    const body = switch (result) {
        .success, .failure => |value| value,
        .rich => return result,
    };
    if (body.len == 0 or body[body.len - 1] != '}') return result;
    const notice = (try shell_snapshot.processOwner().takeResultNotice(alloc)) orelse return result;
    defer alloc.free(notice);
    return appendResultField(alloc, result, "notice", notice);
}

fn attachWaitNote(
    alloc: Allocator,
    result: tool_dispatch.ToolResult,
    command: []const u8,
) Allocator.Error!tool_dispatch.ToolResult {
    if (!wait_habits.sleepsInPollLoop(command)) return result;
    return appendResultField(alloc, result, "wait_note", wait_habits.sleep_poll_note);
}

fn appendResultField(
    alloc: Allocator,
    result: tool_dispatch.ToolResult,
    comptime field: []const u8,
    text: []const u8,
) Allocator.Error!tool_dispatch.ToolResult {
    const body = switch (result) {
        .success, .failure => |value| value,
        .rich => return result,
    };
    if (body.len == 0 or body[body.len - 1] != '}') return result;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(body[0 .. body.len - 1]) catch return error.OutOfMemory;
    out.writer.writeAll(",\"" ++ field ++ "\":") catch return error.OutOfMemory;
    std.json.Stringify.value(text, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    const updated = try out.toOwnedSlice();
    alloc.free(body);
    return switch (result) {
        .success => .{ .success = updated },
        .failure => .{ .failure = updated },
        .rich => unreachable,
    };
}

fn callInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    switch (ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err)) {
        .indexed => {},
        .ended_with_owner => return terminalEndedWithOwner(ctx, session_id),
    }
    const chars = input.chars orelse "";
    const yield_time_ms = effective_interact_yield_time(chars.len != 0, input.yield_time_ms);
    if (runtime.isTombstone(session_id)) {
        if (chars.len != 0) return runtimeFailure(ctx, error.ExecutionTerminal);
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .command);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        return callTtyInteract(ctx, input, yield_time_ms);
    }
    if (chars.len != 0) return runtimeFailure(ctx, error.InvalidBackend);
    if (input.tail_bytes) |tail_bytes| {
        if (input.yield_time_ms != 0) {
            var waited = runtime.wait(
                ctx.allocator,
                session_id,
                yield_time_ms,
                ctx.cancel_flag,
            ) catch |err| return runtimeFailure(ctx, err);
            defer waited.deinit(ctx.allocator);
            runtime.cancelDelivery(
                waited.snapshot.execution_id,
                waited.reservation_id,
            ) catch |err| return runtimeFailure(ctx, err);
        }
        return readTaskTail(ctx, runtime, session_id, tail_bytes);
    }
    var prepared = runtime.wait(
        ctx.allocator,
        session_id,
        yield_time_ms,
        ctx.cancel_flag,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .command);
}

fn readTaskTail(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    task_id: []const u8,
    tail_bytes: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var tail = (runtime.tailOutput(ctx.allocator, task_id, tail_bytes) catch |err|
        return runtimeFailure(ctx, err)) orelse
        return runtimeFailure(ctx, error.ExecutionNotFound);
    defer tail.deinit(ctx.allocator);
    return .{ .success = formatTaskTail(ctx.allocator, task_id, tail) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    } };
}

const stale_tree_mark = "files changed after this task started";

fn formatTaskTail(
    alloc: Allocator,
    task_id: []const u8,
    tail: managed_execution.TailOutput,
) ![]u8 {
    var encoded: ?text_utils.EncodedText = null;
    defer if (encoded) |*value| value.deinit(alloc);
    const model_safe = text_utils.isModelSafeText(tail.bytes);
    if (!model_safe) {
        encoded = try text_utils.encodeTerminalSafe(
            alloc,
            tail.bytes,
            tail.bytes.len * 4 + 16,
        );
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .session_id = task_id,
        .state = snapshotStateName(tail.state),
        .total_bytes = tail.total_bytes,
        .tail_truncated = presentFlag(tail.truncated or (if (encoded) |value| value.truncated else false)),
        .output_terminal_safe = presentFlag(!model_safe),
        .running_ms = tail.running_ms,
        .idle_ms = tail.idle_ms,
        .stuck = presentFlag(tail.stuck),
        .stale = if (tail.tree_changed) @as(?[]const u8, stale_tree_mark) else null,
        .tail = if (encoded) |value| value.bytes else tail.bytes,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    return try out.toOwnedSlice();
}

pub fn readTaskOutput(
    ctx: tool_dispatch.DispatchContext,
    task_id: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callInteract(ctx, .{
        .action = .interact,
        .session_id = task_id,
        .yield_time_ms = 0,
    });
}

fn callStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    switch (ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err)) {
        .indexed => {},
        .ended_with_owner => return terminalEndedWithOwner(ctx, session_id),
    }
    if (runtime.stateFor(session_id) == null and !runtime.isTombstone(session_id)) {
        if (try stopBackgroundAgent(ctx, session_id)) |stopped_agent| return stopped_agent;
    }
    if (runtime.isTombstone(session_id)) {
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .stop);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        refreshTtyExecution(ctx, runtime, session_id, "") catch |err|
            return runtimeFailure(ctx, err);
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        return callTtyStop(ctx, input);
    }
    var prepared = runtime.stop(
        ctx.allocator,
        session_id,
        input.force,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn stopBackgroundAgent(
    ctx: tool_dispatch.DispatchContext,
    agent_name: []const u8,
) tool_dispatch.DispatchError!?tool_dispatch.ToolResult {
    const provider = ctx.subagent_provider orelse return null;
    var request = subagent_model_contract.validateRequest(ctx.allocator, .{ .stop = .{ .agent = agent_name } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer request.deinit(ctx.allocator);
    const outcome = try provider.execute(ctx.allocator, &request, ctx.tool_call_id);
    switch (outcome.status) {
        .success => {
            const stopped: tool_dispatch.ToolResult = .{ .success = outcome.body };
            return stopped;
        },
        .failure => {
            ctx.allocator.free(outcome.body);
            return null;
        },
    }
}

const BackgroundAgentStopFixture = struct {
    known_agent: []const u8,
    stop_requests: usize = 0,

    fn execute(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        request: *subagent_model_contract.Request,
        _: []const u8,
    ) subagent_tool_provider.ExecuteError!subagent_tool_provider.Result {
        const self: *BackgroundAgentStopFixture = @ptrCast(@alignCast(raw_context.?));
        self.stop_requests += 1;
        const known = request.* == .stop and std.mem.eql(u8, request.stop.agent, self.known_agent);
        return .{
            .status = if (known) .success else .failure,
            .body = try alloc.dupe(u8, if (known) "Stopped reviewer: its turn ended." else "child_unavailable"),
        };
    }
};

test "TaskStop stops a named background agent when no shell task has that ID" {
    const alloc = std.testing.allocator;
    var fixture = BackgroundAgentStopFixture{ .known_agent = "reviewer" };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .tool_call_name = "TaskStop",
        .subagent_provider = .{ .context = &fixture, .execute_fn = BackgroundAgentStopFixture.execute },
    };

    const stopped = (try stopBackgroundAgent(ctx, "reviewer")).?;
    defer alloc.free(stopped.success);
    try std.testing.expectEqualStrings("Stopped reviewer: its turn ended.", stopped.success);
    try std.testing.expectEqual(@as(usize, 1), fixture.stop_requests);

    try std.testing.expect((try stopBackgroundAgent(ctx, "builder")) == null);
    try std.testing.expectEqual(@as(usize, 2), fixture.stop_requests);

    try std.testing.expect((try stopBackgroundAgent(ctx, "")) == null);
    try std.testing.expectEqual(@as(usize, 2), fixture.stop_requests);

    try std.testing.expect((try stopBackgroundAgent(.{ .allocator = alloc, .tool_call_name = "TaskStop" }, "reviewer")) == null);
}

const ParsedTerminalExecution = struct {
    result: terminal_contracts.OwnedResult,

    fn deinit(self: *ParsedTerminalExecution, alloc: Allocator) void {
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

fn callTtyRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const owner = ctx.session_child_capability orelse return unavailable(ctx);
    const durable_session_id = ctx.terminal_owner_session_id orelse return unavailable(ctx);
    const command = input.command orelse return unavailable(ctx);
    const cwd = resolveCwd(ctx.allocator, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    defer ctx.allocator.free(@constCast(cwd));
    var shell_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(shell_arena_state);
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    const shell = ttyShell(shell_arena_state.allocator(), input, configured) catch |err|
        return runtimeFailure(ctx, err);
    const environment = shell_resolver.environmentForShellSpec(
        shell_arena_state.allocator(),
        configured,
        shell,
    ) catch |err| return runtimeFailure(ctx, err);
    requireTtyShellAuthority(ctx, .{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = environment,
        .execution_mode = .tty,
    }) catch |err| return runtimeFailure(ctx, err);
    runtime.reserveTtyCapacity() catch |err| return runtimeFailure(ctx, err);
    var capacity_reserved = true;
    defer if (capacity_reserved) runtime.releaseTtyCapacity();
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return unavailable(ctx);
    var persistence = terminal_operation.prepareStartPersistence(ctx.allocator, .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .cwd = cwd,
        .transport_role = ctx.terminal_transport_role,
        .backend = .native,
        .actor = .agent,
        .controls = .full(),
        .lifetime = .session,
    }) catch |err| return runtimeFailure(ctx, err);
    defer persistence.deinit();
    const request = terminal_contracts.ActionRequest{ .start = .{
        .cwd = cwd,
        .command = command,
        .shell = shell,
        .backend = .native,
        .return_when = if (input.yield_time_ms == 0) .started else .exit,
        .wait_ceiling_ms = @max(@as(u64, 1), input.yield_time_ms),
        .timeout_ms = input.timeout_ms,
        .persistence = persistence.view(),
    } };
    var executed = executeTerminal(ctx, request) catch |err|
        return runtimeFailure(ctx, err);
    defer executed.deinit(ctx.allocator);
    const started = switch (executed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, executed.result.view()),
        .success => |success| switch (success) {
            .start => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    var session_owned = true;
    defer if (session_owned) closeTtyBestEffort(ctx, started.session.session_id);
    const initial_state = terminal_managed_observer.snapshotState(started.session, started.outcome);
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        started.session.session_id,
        initial_state,
        null,
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    finalizeCompletedTty(ctx, started.session.session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.registerTty(ctx.allocator, .{
        .execution_id = started.session.session_id,
        .command = command,
        .cwd = cwd,
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = observed.state == .running,
        .capacity_reserved = true,
        .replay_capability = ctx.session_child_capability,
    }) catch |err| return runtimeFailure(ctx, err);
    capacity_reserved = false;
    session_owned = false;
    defer prepared.deinit(ctx.allocator);
    _ = owner;
    return finishPrepared(ctx, runtime, &prepared, .command);
}

fn callTtyInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
    yield_time_ms: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    if (runtime.isTombstone(session_id)) {
        return runtimeFailure(ctx, error.ExecutionTerminal);
    }
    var state: managed_execution.SnapshotState = .running;
    var accepted_bytes: ?u32 = null;
    const chars = input.chars orelse "";
    if (chars.len != 0) {
        if (runtime.backendFor(session_id) != .tty) {
            return runtimeFailure(ctx, error.InvalidBackend);
        }
        var ready = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
            .session_id = session_id,
            .return_when = .started,
            .safety_ceiling_ms = 20_000,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer ready.deinit(ctx.allocator);
        const ready_result = switch (ready.result.view()) {
            .failure => return cloneTerminalFailure(ctx, ready.result.view()),
            .success => |success| switch (success) {
                .wait => |value| value,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        if (ready_result.session.lifecycle != .running) {
            return runtimeFailure(ctx, error.TerminalNotReady);
        }

        var acquired = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .acquire,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer acquired.deinit(ctx.allocator);
        switch (acquired.result.view()) {
            .failure => return cloneTerminalFailure(ctx, acquired.result.view()),
            .success => |success| switch (success) {
                .write => {},
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        }
        var release_needed = true;
        defer if (release_needed) releaseTtyLease(ctx, session_id);

        var used = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .payload = .{ .text = chars },
            .lease = .use,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer used.deinit(ctx.allocator);
        accepted_bytes = switch (used.result.view()) {
            .failure => return cloneTerminalFailure(ctx, used.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.accepted_bytes,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };

        var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .release,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer released.deinit(ctx.allocator);
        const facts = switch (released.result.view()) {
            .failure => return cloneTerminalFailure(ctx, released.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.session,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        release_needed = false;
        state = terminal_managed_observer.snapshotState(facts, null);
    }
    const waiter_id = runtime.reserveExternalWait(session_id) catch |err|
        return runtimeFailure(ctx, err);
    defer runtime.releaseExternalWait(session_id, waiter_id);
    if (state == .running and yield_time_ms != 0) {
        var waited = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
            .session_id = session_id,
            .return_when = .exit,
            .safety_ceiling_ms = yield_time_ms,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer waited.deinit(ctx.allocator);
        const result = switch (waited.result.view()) {
            .failure => return cloneTerminalFailure(ctx, waited.result.view()),
            .success => |success| switch (success) {
                .wait => |value| value,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        state = terminal_managed_observer.snapshotState(result.session, result.outcome);
    }
    if (accepted_bytes != null and yield_time_ms == 0) {
        io_mod.sleep(100 * std.time.ns_per_ms);
    }
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        state,
        runtime.ttyCursorFor(session_id),
    ) catch |err|
        return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    if (runtime.externalWaitPreempted(session_id, waiter_id)) {
        return runtimeFailure(ctx, error.WaitPreempted);
    }
    finalizeCompletedTty(ctx, session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return if (accepted_bytes) |count|
        finishPreparedWithAccepted(ctx, runtime, &prepared, count)
    else
        finishPrepared(ctx, runtime, &prepared, .command);
}

fn callTtyStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    runtime.preemptWait(session_id);
    var signaled = executeAuthorizedTerminal(ctx, session_id, .{ .signal = .{
        .session_id = session_id,
        .signal = if (input.force) .kill else .terminate,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer signaled.deinit(ctx.allocator);
    switch (signaled.result.view()) {
        .failure => return cloneTerminalFailure(ctx, signaled.result.view()),
        .success => |success| switch (success) {
            .signal => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }

    var stopped_status: ?command_contract.CommandStatus = null;
    var waited = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = 2_000,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer waited.deinit(ctx.allocator);
    const wait_result = switch (waited.result.view()) {
        .failure => return cloneTerminalFailure(ctx, waited.result.view()),
        .success => |success| switch (success) {
            .wait => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    stopped_status = statusFromOutcome(wait_result.outcome);
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        terminal_managed_observer.snapshotState(wait_result.session, wait_result.outcome),
        runtime.ttyCursorFor(session_id),
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);

    var closed = executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = if (input.force) .force else .graceful,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, closed.result.view()),
        .success => |success| switch (success) {
            .close => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = .{ .stopped = stopped_status },
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn ttyShell(
    alloc: Allocator,
    input: Input,
    configured_login_shell: ?[]const u8,
) !terminal_contracts.ShellSpec {
    if (input.shell) |shell| return .{ .executable = .{
        .path = shell.path,
        .clean_start = shell.clean_start,
    } };
    return shell_resolver.profileShell(
        alloc,
        configured_login_shell,
        input.profile orelse .user,
    );
}

fn requireTtyShellAuthority(
    ctx: tool_dispatch.DispatchContext,
    command_ctx: command_admission.CommandContext,
) !void {
    const execution_authority = ctx.execution_authority orelse
        return error.CommandAuthorityContextMismatch;
    const command_authority = switch (execution_authority) {
        .run_command => |value| value,
        .ordinary, .file_mutation, .vision_paths => return error.CommandAuthorityContextMismatch,
    };
    const shell_allowed = switch (command_authority) {
        .shell_allowed => |value| value,
        .direct_only => return error.CommandAdmissionChanged,
    };
    if (!shell_allowed.fingerprint.matches(command_ctx)) {
        return error.CommandAuthorityContextMismatch;
    }
}

fn executeTerminal(
    ctx: tool_dispatch.DispatchContext,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    return .{ .result = try terminal_action_executor.execute(.{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .runtime = ctx.terminal_client orelse return error.TerminalUnavailable,
        .cancel_flag = ctx.cancel_flag,
    }, request) };
}

fn executeAuthorizedTerminal(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    var authority = try reloadTerminalAuthority(ctx, session_id);
    defer authority.deinit();
    const authorized: terminal_contracts.ActionRequest = switch (request) {
        .read => |value| .{ .read = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .write => |value| .{ .write = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .wait => |value| .{ .wait = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .signal => |value| .{ .signal = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .close => |value| .{ .close = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .screen => |value| .{ .screen = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .start, .inspect, .list, .resize => return error.InvalidTerminalRequest,
    };
    return executeTerminal(ctx, authorized);
}

fn reloadTerminalAuthority(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !terminal_operation.OwnedAuthorityClaim {
    const owner = ctx.session_child_capability orelse return error.TerminalAuthorityUnavailable;
    const durable_session_id = ctx.terminal_owner_session_id orelse
        return error.TerminalAuthorityUnavailable;
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return error.TerminalAuthorityUnavailable;
    return terminal_store.reloadOwnerAuthorityClaim(ctx.allocator, owner, .{
        .terminal_session_id = session_id,
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .actor = .agent,
    });
}

fn cloneTerminalFailure(
    ctx: tool_dispatch.DispatchContext,
    result: terminal_contracts.Result,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (result == .success) return runtimeFailure(ctx, error.InvalidTerminalResult);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    std.json.Stringify.value(result, .{}, &out.writer) catch
        return error.OutOfMemory;
    return .{ .failure = try out.toOwnedSlice() };
}

fn statusFromOutcome(
    outcome: terminal_contracts.ReturnOutcome,
) ?command_contract.CommandStatus {
    return switch (outcome) {
        .exited => |code| .{ .exit_code = code },
        .signal => |signal| .{ .signal = signal },
        .started, .condition_met, .safety_ceiling, .cancelled => null,
    };
}

fn releaseTtyLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = null,
    } }) catch |err| {
        debug_trace.logf(
            "shell",
            "TTY write lease release failed session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    released.deinit(ctx.allocator);
}

pub fn releaseAgentWriteLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !void {
    var released = try executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = null,
    } });
    defer released.deinit(ctx.allocator);
    switch (released.result.view()) {
        .success => |success| switch (success) {
            .write => {},
            else => return error.InvalidTerminalLeaseCleanupResult,
        },
        .failure => |failure| switch (failure.code) {
            .session_not_found, .lease_conflict => {},
            else => return error.TerminalLeaseCleanupFailed,
        },
    }
}

fn finalizeCompletedTty(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) !void {
    switch (state) {
        .completed => {},
        .running, .stopped, .lost => return,
    }
    var closed = try executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = .graceful,
        .authority = null,
    } });
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return error.TerminalCloseFailed,
        .success => |success| switch (success) {
            .close => {},
            else => return error.InvalidTerminalResult,
        },
    }
}

fn closeTtyBestEffort(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    var closed = executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = null,
    } }) catch |err| {
        debug_trace.logf(
            "shell",
            "unpublished TTY cleanup failed session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    closed.deinit(ctx.allocator);
}

fn finishPreparedWithAccepted(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    accepted_bytes: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        accepted_bytes,
        ctx.max_tool_result_bytes,
        replaySource(ctx, runtime),
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    errdefer ctx.allocator.free(body);
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch
        return runtimeFailure(ctx, error.ResultCommitFailed);
    return .{ .success = body };
}

fn ensureOwnedTtyIndexed(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
) !terminal_managed_observer.SyncOutcome {
    if (runtime.stateFor(session_id) != null) return .indexed;
    const observer = ttyObserverContext(ctx, runtime) orelse return .indexed;
    return terminal_managed_observer.syncOwned(observer, session_id);
}

fn terminalEndedWithOwner(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    std.json.Stringify.value(.{ .@"error" = .{
        .tool = "shell",
        .code = tool_result_errors.terminal_ended_error_code,
        .session_id = session_id,
        .message = "This terminal ended when the fx process that started it exited. It cannot be resumed. Start a new terminal with shell action run and tty true.",
        .retryable = false,
    } }, .{}, &out.writer) catch return error.OutOfMemory;
    return .{ .failure = try out.toOwnedSlice() };
}

fn refreshTtyExecution(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    command: []const u8,
) !void {
    return terminal_managed_observer.refresh(
        ttyObserverContext(ctx, runtime) orelse
            return error.TerminalAuthorityUnavailable,
        session_id,
        command,
    );
}

fn ttyObserverContext(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
) ?terminal_managed_observer.Context {
    return .{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .terminal_client = ctx.terminal_client orelse return null,
        .managed_runtime = runtime,
        .owner = ctx.session_child_capability orelse return null,
        .durable_session_id = ctx.terminal_owner_session_id orelse return null,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .max_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = ctx.cancel_flag,
    };
}

fn finishTerminalTtyStop(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    finalizeCompletedTty(ctx, session_id, state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = state,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn finishPrepared(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    action: enum { command, stop },
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        null,
        ctx.max_tool_result_bytes,
        replaySource(ctx, runtime),
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result is unavailable") };
    };
    errdefer ctx.allocator.free(body);
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result commit failed") };
    };
    const failed = switch (action) {
        .command => snapshotFailed(prepared.snapshot),
        .stop => stop_result_failed(prepared.snapshot.state),
    };
    return if (failed)
        .{ .failure = body }
    else
        .{ .success = body };
}

fn publishSnapshotMetadata(
    ctx: tool_dispatch.DispatchContext,
    snapshot: managed_execution.Snapshot,
) !void {
    if (ctx.command_result_json_sink == null and
        ctx.tool_result_memory_sink == null) return;
    const status: ?command_contract.CommandStatus = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => return,
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const timed_out = if (snapshot.error_name) |name|
        std.mem.eql(u8, name, "TimeoutExpired")
    else
        false;
    var memory = types.ToolResultMemory{
        .output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .stored_output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .truncated = snapshot.output_truncated,
    };
    if (ctx.tool_result_memory_sink != null) {
        if (snapshot.output_file) |handle| {
            memory.command_output_replay = .{ .available = .{
                .handle = try ctx.allocator.dupe(u8, handle),
                .framed_bytes = snapshot.output_framed_bytes,
            } };
        }
    }
    errdefer if (memory.command_output_replay) |replay| switch (replay) {
        .available => |descriptor| ctx.allocator.free(@constCast(descriptor.handle)),
        .unavailable => {},
    };
    const completed = switch (snapshot.state) {
        .completed => true,
        .running, .stopped, .lost => false,
    };
    if (timed_out) {
        memory.command_process_presentation = .timed_out;
    } else if (completed) {
        if (projection.signal) |signal| {
            memory.command_process_presentation = .{ .signal = signal };
        } else if (projection.exit_code) |exit_code| {
            if (exit_code != 0) {
                memory.command_process_presentation = .{ .exit_code = exit_code };
            }
        }
    }
    if (ctx.command_result_json_sink != null) {
        const command_result = command_contract.CommandResult{
            .command = snapshot.command,
            .cwd = snapshot.cwd,
            .exit_code = projection.exit_code,
            .signal = projection.signal,
            .timed_out = timed_out,
            .termination_indeterminate = projection.termination_indeterminate,
            .output_incomplete = snapshot.output_incomplete,
            .duration_ms = snapshot.duration_ms,
            .stdout_bytes = snapshot.stdout_bytes,
            .stderr_bytes = snapshot.stderr_bytes,
            .truncated = snapshot.output_truncated,
            .output_file = snapshot.output_file,
        };
        const command_result_json = try command_result.toJson(ctx.allocator);
        tool_dispatch.reportCommandResultJson(ctx, command_result_json);
    }
    if (ctx.tool_result_memory_sink != null) {
        tool_dispatch.reportToolResultMemory(ctx, memory);
    }
}

fn handoffPreparedDelivery(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    reservation_id: u64,
) !void {
    if (ctx.result_commit_sink == null) {
        return runtime.commitReservation(reservation_id);
    }
    tool_dispatch.reportResultCommit(ctx, result_commit.Token{
        .context = runtime,
        .identity = reservation_id,
        .commit_fn = commitManagedDelivery,
        .cancel_fn = cancelManagedDelivery,
    });
}

fn commitManagedDelivery(raw: *anyopaque, reservation_id: u64) !void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    return runtime.commitReservation(reservation_id);
}

fn cancelManagedDelivery(raw: *anyopaque, reservation_id: u64) void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    runtime.cancelReservation(reservation_id) catch |err| {
        debug_trace.logf(
            "shell",
            "managed delivery cancellation failed reservation={d} err={s}",
            .{ reservation_id, @errorName(err) },
        );
    };
}

fn formatSnapshot(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
) ![]u8 {
    return formatSnapshotWithLimit(
        alloc,
        snapshot,
        accepted_bytes,
        tool_result_limits.default_max_tool_result_bytes,
        null,
    );
}

const ReplaySource = union(enum) {
    saved: *session_child_store.SessionChildCapability,
    ephemeral: *command_replay_store.EphemeralStore,

    fn open(self: ReplaySource, alloc: Allocator, handle: []const u8) !command_replay_store.Reader {
        return switch (self) {
            .saved => |capability| command_replay_store.Reader.openHandle(alloc, capability, handle),
            .ephemeral => |store| command_replay_store.Reader.openEphemeralHandle(alloc, store, handle),
        };
    }
};

fn replaySource(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
) ReplaySource {
    return if (ctx.session_child_capability) |capability|
        .{ .saved = capability }
    else
        .{ .ephemeral = runtime.replayStore() };
}

const CondenseStats = struct {
    original_bytes: usize,
    dropped_lines: usize,
};

const replay_tail_window_bytes: usize = 64 * 1024;
const replay_tail_anchor_bytes: usize = 256;

fn condensedSnapshotOutput(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    replay: ?ReplaySource,
) Allocator.Error!?command_output_content.Condensed {
    const options: command_output_content.CondenseOptions = .{
        .full_output_available = snapshot.output_file != null,
    };
    if (snapshot.output_truncated and snapshot.backend == .captured) {
        if (replay) |source| {
            if (snapshot.output_file) |handle| {
                const from_replay = condenseFromReplay(alloc, snapshot, source, handle, options) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        debug_trace.logf(
                            "shell",
                            "command replay tail unavailable err={s}",
                            .{@errorName(err)},
                        );
                        break :blk null;
                    },
                };
                if (from_replay) |value| return value;
            }
        }
    }
    return command_output_content.condense(alloc, snapshot.output_delta, options);
}

fn condenseFromReplay(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    source: ReplaySource,
    handle: []const u8,
    options: command_output_content.CondenseOptions,
) !?command_output_content.Condensed {
    const delta = snapshot.output_delta;
    var reader = try source.open(alloc, handle);
    defer reader.deinit();

    var condenser = command_output_content.Condenser.init(alloc);
    defer condenser.deinit();
    var tail_window: std.ArrayList(u8) = .empty;
    defer tail_window.deinit(alloc);
    var matched_bytes: usize = 0;
    var replay_starts_with_delta = true;
    while (try reader.next(alloc)) |frame| {
        defer alloc.free(frame.payload);
        if (replay_starts_with_delta and matched_bytes < delta.len) {
            const compared = @min(delta.len - matched_bytes, frame.payload.len);
            if (std.mem.eql(u8, delta[matched_bytes..][0..compared], frame.payload[0..compared])) {
                matched_bytes += compared;
            } else {
                replay_starts_with_delta = false;
            }
        }
        if (replay_starts_with_delta) try condenser.append(frame.payload);
        try appendTailWindow(alloc, &tail_window, frame.payload);
    }
    if (replay_starts_with_delta and matched_bytes == delta.len) {
        return try condenser.finish(options);
    }

    var resumed = command_output_content.Condenser.init(alloc);
    defer resumed.deinit();
    try resumed.append(delta);
    try resumed.markUnknownGap();
    try resumed.append(replayTailAfterDelta(delta, tail_window.items));
    resumed.original_bytes = @max(
        resumed.original_bytes,
        snapshot.stdout_bytes +| snapshot.stderr_bytes,
    );
    return try resumed.finish(options);
}

fn appendTailWindow(
    alloc: Allocator,
    window: *std.ArrayList(u8),
    payload: []const u8,
) Allocator.Error!void {
    if (payload.len >= replay_tail_window_bytes) {
        window.clearRetainingCapacity();
        return window.appendSlice(alloc, payload[payload.len - replay_tail_window_bytes ..]);
    }
    try window.appendSlice(alloc, payload);
    if (window.items.len > 2 * replay_tail_window_bytes) {
        const excess = window.items.len - replay_tail_window_bytes;
        @memmove(window.items[0..replay_tail_window_bytes], window.items[excess..]);
        window.items.len = replay_tail_window_bytes;
    }
}

fn replayTailAfterDelta(delta: []const u8, window: []const u8) []const u8 {
    const recent = window[window.len -| replay_tail_window_bytes..];
    const anchor = delta[delta.len -| replay_tail_anchor_bytes..];
    const after_delta: usize = if (anchor.len == 0)
        0
    else if (std.mem.findLast(u8, recent, anchor)) |index|
        index + anchor.len
    else
        0;
    if (after_delta != 0 and recent[after_delta - 1] == '\n') return recent[after_delta..];
    const line_start = if (std.mem.findScalarPos(u8, recent, after_delta, '\n')) |newline|
        newline + 1
    else
        recent.len;
    return recent[line_start..];
}

const bash_inline_floor_bytes: usize = 1024;

fn bashInlineMaxBytes(max_bytes: usize, configured_chars: ?usize) usize {
    const fx_ceiling = @min(max_bytes, result_store.large_result_threshold_bytes);
    const configured = configured_chars orelse return fx_ceiling;
    return @min(fx_ceiling, @max(configured, bash_inline_floor_bytes));
}

test "BASH_MAX_OUTPUT_LENGTH and task.bash_output_max_chars lower the inline Bash output ceiling" {
    const budget = tool_result_limits.default_max_tool_result_bytes;
    const fx_ceiling = result_store.large_result_threshold_bytes;
    try std.testing.expectEqual(fx_ceiling, bashInlineMaxBytes(budget, null));
    try std.testing.expectEqual(@as(usize, 4000), bashInlineMaxBytes(budget, 4000));
    try std.testing.expectEqual(fx_ceiling, bashInlineMaxBytes(budget, 150_000));
    try std.testing.expectEqual(bash_inline_floor_bytes, bashInlineMaxBytes(budget, 10));
    try std.testing.expectEqual(@as(usize, 512), bashInlineMaxBytes(512, 4000));
}

fn formatSnapshotWithLimit(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    max_bytes: usize,
    replay: ?ReplaySource,
) ![]u8 {
    const inline_max_bytes = bashInlineMaxBytes(max_bytes, managed_contract.taskSettings().bash_output_max_chars);
    var condensed = try condensedSnapshotOutput(alloc, snapshot, replay);
    defer if (condensed) |*value| value.deinit(alloc);
    const stats: ?CondenseStats = if (condensed) |value| .{
        .original_bytes = value.original_bytes,
        .dropped_lines = value.dropped_lines,
    } else null;
    const visible_output: []const u8 = if (condensed) |value| value.text else snapshot.output_delta;
    const model_output = try text_utils.maskSecrets(alloc, visible_output);
    defer if (model_output.ptr != visible_output.ptr) alloc.free(model_output);
    if (try formatModelSafeSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        model_output,
        snapshot.output_truncated or condensed != null,
        inline_max_bytes,
        stats,
    )) |full| {
        if (full.len <= inline_max_bytes) return full;
        alloc.free(full);
    }

    var minimum: usize = 0;
    var maximum: usize = @min(model_output.len, inline_max_bytes);
    var best: ?[]u8 = null;
    errdefer if (best) |value| alloc.free(value);
    while (minimum <= maximum) {
        const content_budget = minimum + (maximum - minimum) / 2;
        const marker = "\n... bytes omitted; use full_output_handle for exact output ...\n";
        var projected_writer: std.Io.Writer.Allocating = .init(alloc);
        defer projected_writer.deinit();
        try text_utils.writeHeadTailBounded(
            &projected_writer.writer,
            model_output,
            content_budget,
            marker,
            .up,
        );
        const projected = try projected_writer.toOwnedSlice();
        defer alloc.free(projected);
        const candidate = (try formatModelSafeSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            projected,
            true,
            inline_max_bytes,
            stats,
        )) orelse {
            if (content_budget == 0) break;
            maximum = content_budget - 1;
            continue;
        };
        if (candidate.len <= inline_max_bytes) {
            if (best) |value| alloc.free(value);
            best = candidate;
            minimum = content_budget + 1;
        } else {
            alloc.free(candidate);
            if (content_budget == 0) break;
            maximum = content_budget - 1;
        }
    }
    if (best) |value| return value;
    return formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        "",
        true,
        false,
        stats,
    );
}

fn formatModelSafeSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
    max_encoded_bytes: usize,
    stats: ?CondenseStats,
) !?[]u8 {
    if (text_utils.isModelSafeText(output_delta)) {
        return try formatSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            output_delta,
            output_truncated,
            false,
            stats,
        );
    }
    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        output_delta,
        max_encoded_bytes,
    );
    defer encoded.deinit(alloc);
    if (encoded.truncated) return null;
    return try formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        encoded.bytes,
        output_truncated,
        true,
        stats,
    );
}

const zsh_parse_retry_guidance = "The shell could not parse this command (unmatched quote or syntax error), so nothing executed. Rewrite the command with corrected quoting or escaping and submit the full corrected command instead of rerunning the same text.";
const line_shell_parse_retry_guidance = "The shell could not parse this command (unmatched quote or syntax error). This shell runs a command line by line, so other lines may already have run. Check the output, then submit a corrected command instead of rerunning the same text, without repeating side effects that already happened.";
const usage_error_retry_guidance = "The command exited with a usage error (missing or invalid arguments). Rebuild the command with the required arguments explicitly set, then submit the corrected command instead of rerunning it unchanged.";

fn failureRetryGuidance(exit_code: ?i64, output: []const u8, whole_output: bool) ?[]const u8 {
    const code = exit_code orelse return null;
    if (code == 0) return null;
    if (shellParseRetryGuidance(output, whole_output)) |guidance| return guidance;
    if (hasUsageBannerOutput(output)) return usage_error_retry_guidance;
    return null;
}

const ShellFamily = enum { zsh, line_by_line };

fn shellParseRetryGuidance(output: []const u8, whole_output: bool) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const family = shellErrorFamily(trimmed) orelse continue;

        if (text_utils.containsIgnoreCase(trimmed, "condition expected")) continue;

        if (!(text_utils.containsIgnoreCase(trimmed, "unmatched") or
            text_utils.containsIgnoreCase(trimmed, "unexpected EOF while looking for matching") or
            text_utils.containsIgnoreCase(trimmed, "syntax error") or
            text_utils.containsIgnoreCase(trimmed, "parse error") or
            text_utils.containsIgnoreCase(trimmed, "unterminated quoted string"))) continue;
        switch (family) {
            .zsh => if (whole_output and std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), trimmed)) return zsh_parse_retry_guidance,
            .line_by_line => return line_shell_parse_retry_guidance,
        }
    }
    return null;
}

fn shellErrorFamily(line: []const u8) ?ShellFamily {
    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    const token = line[0..colon];
    if (token.len == 0 or std.mem.findScalar(u8, token, ' ') != null) return null;
    if (std.mem.eql(u8, token, "(eval)")) return .zsh;
    if (std.mem.eql(u8, token, "/dev/fd/0") and std.mem.startsWith(u8, line[colon + 1 ..], " eval:")) return .line_by_line;
    const base = if (std.mem.findLast(u8, token, "/")) |slash| token[slash + 1 ..] else token;
    if (std.mem.eql(u8, base, "zsh")) return .zsh;
    const line_shells = [_][]const u8{ "bash", "sh", "dash" };
    for (line_shells) |name| {
        if (std.mem.eql(u8, base, name)) return .line_by_line;
    }
    return null;
}

fn hasUsageBannerOutput(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var scanned: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (scanned >= 4) return false;
        scanned += 1;
        if (std.ascii.startsWithIgnoreCase(trimmed, "usage:")) return true;
    }
    return false;
}

fn formatSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
    escaped: bool,
    stats: ?CondenseStats,
) ![]u8 {
    const status = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => null,
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const timed_out = if (snapshot.error_name) |name| std.mem.eql(u8, name, "TimeoutExpired") else false;
    const retry_guidance: ?[]const u8 = if (snapshot.output_incomplete)
        "Command output is incomplete. Inspect external state and available output before retrying; do not blindly rerun a command that may have changed state."
    else switch (snapshot.state) {
        .lost => "Execution status is indeterminate. Inspect external state before retrying; do not blindly rerun a command that may have changed state.",
        .completed => failureRetryGuidance(
            projection.exit_code,
            snapshot.output_delta,
            snapshot.stdout_bytes +| snapshot.stderr_bytes == snapshot.output_delta.len,
        ),
        .running => null,
        .stopped => if (timed_out) timeoutRetryGuidance(snapshot.retained) else null,
    };
    const retained = snapshot.retained;
    const timeout_cause: ?[]u8 = if (timed_out) try timeoutCause(alloc, snapshot.timeout_ms) else null;
    defer if (timeout_cause) |value| alloc.free(value);
    const wait_hint: ?[]u8 = if (retained and snapshot.state == .running)
        try std.fmt.allocPrint(alloc, running_wait_hint_format, .{ snapshot.execution_id, snapshot.execution_id })
    else
        null;
    defer if (wait_hint) |value| alloc.free(value);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .session_id = if (retained) snapshot.execution_id else null,
        .state = snapshotStateName(snapshot.state),
        .backend = if (retained or snapshot.backend != .captured) @tagName(snapshot.backend) else null,
        .persistence = if (retained or snapshot.persistence != .process) @tagName(snapshot.persistence) else null,
        .output_truncated = presentFlag(output_truncated),
        .original_bytes = if (stats) |value| value.original_bytes else null,
        .dropped_lines = if (stats) |value| value.dropped_lines else null,
        .output_incomplete = presentFlag(snapshot.output_incomplete),
        .output_terminal_safe = presentFlag(escaped),
        .full_output_handle = snapshot.output_file,
        .exit_code = projection.exit_code,
        .signal = projection.signal,
        .termination_indeterminate = presentFlag(projection.termination_indeterminate),
        .duration_ms = snapshot.duration_ms,
        .running_ms = if (retained and snapshot.running_ms != 0) @as(?u64, snapshot.running_ms) else null,
        .idle_ms = if (retained and snapshot.idle_ms != 0) @as(?u64, snapshot.idle_ms) else null,
        .stuck = presentFlag(retained and snapshot.stuck),
        .stale = if (retained and snapshot.tree_changed) @as(?[]const u8, stale_tree_mark) else null,
        .log_path = if (retained) snapshot.log_path else null,
        .accepted_bytes = accepted_bytes,
        .@"error" = snapshot.error_name,
        .cause = timeout_cause,
        .retry_guidance = retry_guidance,
        .wait_hint = wait_hint,
        .output_delta = output_delta,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    return try out.toOwnedSlice();
}

const running_wait_hint_format = "Task {s} is still running. Call WaitFor with task_id \"{s}\" to block until it ends; do not poll with TaskOutput.";
const foreground_timeout_retry_guidance = "Rerun with a larger timeout (up to 3600 seconds), or with run_in_background true and wait with WaitFor.";
const background_timeout_retry_guidance = "Rerun with run_in_background true and a larger timeout (up to 86400 seconds) or disable_timeout true, and wait with WaitFor.";

fn timeoutRetryGuidance(background: bool) []const u8 {
    return if (background) background_timeout_retry_guidance else foreground_timeout_retry_guidance;
}

fn timeoutCause(alloc: Allocator, timeout_ms: ?u64) Allocator.Error![]u8 {
    const value = timeout_ms orelse
        return alloc.dupe(u8, "The command was stopped because it ran past its timeout.");
    if (value % std.time.ms_per_s == 0) {
        return std.fmt.allocPrint(
            alloc,
            "The command was stopped because it ran past its timeout of {d} s.",
            .{value / std.time.ms_per_s},
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "The command was stopped because it ran past its timeout of {d} ms.",
        .{value},
    );
}

fn presentFlag(value: bool) ?bool {
    return if (value) true else null;
}

fn snapshotStateName(state: managed_execution.SnapshotState) []const u8 {
    return switch (state) {
        .running => "running",
        .completed => "completed",
        .stopped => "stopped",
        .lost => "lost",
    };
}

fn snapshotFailed(snapshot: managed_execution.Snapshot) bool {
    if (snapshot.output_incomplete) return true;
    return switch (snapshot.state) {
        .running => false,
        .completed => |status| switch (status) {
            .exit_code => |code| code != 0,
            .signal, .indeterminate => true,
            .finished => false,
        },
        .stopped, .lost => true,
    };
}

fn stop_result_failed(state: managed_execution.SnapshotState) bool {
    return switch (state) {
        .lost => true,
        .stopped => |status| if (status) |value| switch (value) {
            .indeterminate => true,
            .exit_code, .signal, .finished => false,
        } else false,
        .running, .completed => false,
    };
}

test "shell stop fails closed only for lost or indeterminate outcomes" {
    try std.testing.expect(stop_result_failed(.lost));
    try std.testing.expect(stop_result_failed(.{ .stopped = .indeterminate }));
    try std.testing.expect(!stop_result_failed(.{ .stopped = .{ .signal = 9 } }));
    try std.testing.expect(!stop_result_failed(.{ .completed = .{ .exit_code = 0 } }));
}

fn runtimeFailure(
    ctx: tool_dispatch.DispatchContext,
    err: anyerror,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try ctx.allocator.print(
        "{{\"error\":{{\"tool\":\"shell\",\"code\":\"{s}\",\"retryable\":false}}}}",
        .{@errorName(err)},
    ) };
}

fn unavailable(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "{\"error\":{\"tool\":\"shell\",\"code\":\"unavailable\",\"retryable\":false}}",
    ) };
}

fn resolveCwd(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    requested: ?[]const u8,
) ![]const u8 {
    const scope = ctx.access_scope orelse
        workspace_access.AccessScope.primaryOnly(ctx.workspace_root);
    const value = requested orelse return arena.dupe(u8, scope.primary_directory);
    if (std.mem.eql(u8, value, ".")) {
        return arena.dupe(u8, scope.primary_directory);
    }
    return pathing.resolveWorkspaceOrExternalPath(
        arena,
        scope.primary_directory,
        value,
    );
}

fn commandEnvironment(
    alloc: Allocator,
    ctx: tool_dispatch.DispatchContext,
    profile: ?command_environment.Profile,
) !command_environment.Environment {
    if (ctx.captured_command_host == .workspace_clean) {
        if (profile != null) return error.InvalidWorkspaceInput;
        return .workspace_clean;
    }
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    return shell_resolver.environment(alloc, configured, profile);
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return input.action == .run and !input.tty;
}

pub fn isProcessLocal(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => !input.tty,
        .interact => input.chars == null or input.chars.?.len == 0,
        .stop => true,
    };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .interact => input.chars == null or input.chars.?.len == 0,
        .run, .stop => false,
    };
}

pub fn planReadOnly(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    if (input.action != .run or input.tty or input.profile != null or input.shell != null or input.cwd != null) return false;
    const command = input.command orelse return false;
    const decision = command_admission.defaultForRunCommand(ctx.allocator, .{
        .command = command,
        .resolved_cwd = ctx.workspace_root,
        .target_os = builtin.target.os.tag,
    }, .ask);
    return switch (decision) {
        .direct_only => true,
        .approval_required => false,
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn planReadOnlyForCommand(command: []const u8) !bool {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .tool_call_name = "Bash",
        .workspace_root = "/workspace",
    };
    const args = try std.fmt.allocPrint(alloc, "{{\"command\":{f}}}", .{std.json.fmt(command, .{})});
    defer alloc.free(args);
    const decoded = try decodeBash(ctx, args);
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
    };
    defer input.deinit(alloc);
    return planReadOnly(ctx, input);
}

test "plan mode admits read-only Bash commands and refuses writes" {
    try std.testing.expect(try planReadOnlyForCommand("ls -la"));
    try std.testing.expect(try planReadOnlyForCommand("git status"));
    try std.testing.expect(!try planReadOnlyForCommand("rm -rf build"));
    try std.testing.expect(!try planReadOnlyForCommand("echo hi > notes.txt"));
    try std.testing.expect(!try planReadOnlyForCommand("ls && rm -rf build"));
    try std.testing.expect(!try planReadOnlyForCommand("cat a.txt | tee b.txt"));
}

test "shell action fields are closed and command authority covers every run" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "action", "command", "cwd", "profile", "shell", "tty", "yield_time_ms", "timeout_ms", "reload" },
        actionFieldContract(.run).allowed,
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "action", "session_id", "chars", "yield_time_ms" },
        actionFieldContract(.interact).allowed,
    );
}

test "shell timeout minimum is enforced before correction and execution" {
    const alloc = std.testing.allocator;
    const zero = try decode(.{ .allocator = alloc }, "{\"action\":\"run\",\"command\":\"true\",\"timeout_ms\":0}");
    switch (zero) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, failure, .{});
            defer parsed.deinit();
            const detail = parsed.value.object.get("error").?.object;
            try std.testing.expectEqualStrings("invalid_shell_request", detail.get("code").?.string);
            try std.testing.expect(!detail.get("executed").?.bool);
            try std.testing.expect(detail.get("retry_with") == null);
        },
    }
    for ([_][]const u8{
        "{\"action\":\"run\",\"command\":\"true\"}",
        "{\"action\":\"run\",\"command\":\"true\",\"timeout_ms\":1}",
    }) |args| {
        const decoded = try decode(.{ .allocator = alloc }, args);
        switch (decoded) {
            .input => |input| input.deinit(alloc),
            .failure => |failure| {
                alloc.free(failure);
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "shell request correction suggests only unambiguous repairs without executing" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { input: []const u8, retry: ?[]const u8 }{
        .{ .input = "{\"command\":\"sleep 30\",\"timeout_ms\":\"40000\",\"yield_time_ms\":\"30000\"}", .retry = "{\"action\":\"run\",\"command\":\"sleep 30\",\"yield_time_ms\":30000,\"timeout_ms\":40000}" },
        .{ .input = "{\"request\":{\"command\":\"sleep 30\"},\"yield_time_ms\":\"30000\"}", .retry = "{\"action\":\"run\",\"command\":\"sleep 30\",\"yield_time_ms\":30000}" },
        .{ .input = "{\"action\":\"run\",\"command\":\"true\",\"background\":null}", .retry = "{\"action\":\"run\",\"command\":\"true\"}" },
        .{ .input = "{\"request\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"true\\\"}\"}", .retry = "{\"action\":\"run\",\"command\":\"true\"}" },
        .{ .input = "{\"request\":{\"action\":\"run\",\"command\":\"true\"}}", .retry = "{\"action\":\"run\",\"command\":\"true\"}" },
        .{ .input = "{\"action\":\"interact\",\"session_id\":\"shell-3\",\"yield_time_ms\":\"1000\",\"unused\":null}", .retry = "{\"action\":\"interact\",\"yield_time_ms\":1000,\"session_id\":\"shell-3\"}" },
        .{ .input = "{\"command\":\"true\",\"tty\":true}", .retry = null },
        .{ .input = "{}", .retry = null },
        .{ .input = "{\"action\":null,\"command\":\"true\"}", .retry = null },
        .{ .input = "{\"session_id\":\"shell-3\"}", .retry = null },
        .{ .input = "{\"command\":\"true\",\"session_id\":\"shell-3\"}", .retry = null },
        .{ .input = "{\"action\":\"run\",\"command\":\"true\",\"background\":true}", .retry = null },
        .{ .input = "{\"action\":\"run\",\"command\":\"true\",\"profile\":\"clean\",\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\"}}", .retry = null },
        .{ .input = "{\"request\":{\"action\":\"run\",\"command\":\"true\",\"yield_time_ms\":\"1000\",\"timeout_ms\":0}}", .retry = null },
        .{ .input = "{\"action\":\"run\",\"command\":\"true\",\"yield_time_ms\":4294967296}", .retry = null },
        .{ .input = "{\"action\":\"stop\",\"session_id\":\"shell-3\",\"force\":\"true\"}", .retry = null },
        .{ .input = "{\"request\":{\"action\":\"run\",\"command\":\"true\"},\"command\":\"false\"}", .retry = null },
        .{ .input = "{", .retry = null },
        .{ .input = "[]", .retry = null },
    };
    for (cases) |case| {
        const result = try decode(.{ .allocator = alloc }, case.input);
        const failure = switch (result) {
            .failure => |failure| failure,
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
        };
        defer alloc.free(failure);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, failure, .{});
        defer parsed.deinit();
        const detail = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings("invalid_shell_request", detail.get("code").?.string);
        try std.testing.expect(!detail.get("executed").?.bool);
        try std.testing.expect(detail.get("problems").?.array.items.len > 0);
        try std.testing.expect((try tool_result_errors.inspectTerminalActionFieldCorrection(alloc, failure)) != null);
        if (case.retry) |expected| {
            const json = try std.json.Stringify.valueAlloc(alloc, detail.get("retry_with").?, .{});
            defer alloc.free(json);
            try std.testing.expectEqualStrings(expected, json);
            const decoded = try decode(.{ .allocator = alloc }, json);
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |reason| {
                    alloc.free(reason);
                    return error.TestUnexpectedResult;
                },
            }
        } else {
            try std.testing.expect(detail.get("retry_with") == null);
        }
    }
}

fn check_request_correction_allocations(alloc: Allocator, args_json: []const u8) !void {
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .failure => |failure| alloc.free(failure),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

test "shell request correction releases partial allocations" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, check_request_correction_allocations, .{
        "{\"request\":{\"command\":\"true\"},\"yield_time_ms\":\"30000\"}",
    });
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, check_request_correction_allocations, .{
        "{\"command\":\"true\",\"tty\":true,\"shell\":{\"path\":\"/bin/bash\",\"kind\":\"executable\"}}",
    });
}

test "shell request correction canonicalizes nested shell members" {
    const alloc = std.testing.allocator;
    const first = try request_correction(alloc,
        \\{"command":"true","tty":true,"shell":{"kind":"executable","path":"/bin/bash","clean_start":false}}
    , true);
    defer alloc.free(first);
    const reordered = try request_correction(alloc,
        \\{"shell":{"clean_start":false,"path":"/bin/bash","kind":"executable"},"tty":true,"command":"true"}
    , true);
    defer alloc.free(reordered);
    try std.testing.expectEqualStrings(first, reordered);
    const omitted = try request_correction(alloc,
        \\{"command":"true","tty":true,"shell":{"path":"/bin/bash","kind":"executable"}}
    , true);
    defer alloc.free(omitted);
    try std.testing.expect(std.mem.find(u8, omitted, "clean_start") == null);
}

test "shell request correction bounds feedback and preserves input bytes" {
    const alloc = std.testing.allocator;
    const command = "printf '\u{1f308}\\n'; echo \"$VALUE\"";
    const key = text_utils.repeat("x", 63) ++ "\u{1f308}";
    const source = try std.json.Stringify.valueAlloc(alloc, .{
        .command = command,
        .x = null,
    }, .{});
    defer alloc.free(source);
    const correction = try request_correction(alloc, source, true);
    defer alloc.free(correction);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, correction, .{});
    defer parsed.deinit();
    const retry = parsed.value.object.get("error").?.object.get("retry_with").?.object;
    try std.testing.expectEqualStrings(command, retry.get("command").?.string);

    const long_key = try alloc.print("{{\"command\":\"true\",\"{s}\":null}}", .{key});
    defer alloc.free(long_key);
    const bounded = try request_correction(alloc, long_key, true);
    defer alloc.free(bounded);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
    const too_large = try alloc.alloc(u8, 16 * 1024 + 1);
    defer alloc.free(too_large);
    @memset(too_large, ' ');
    const failure = try request_correction(alloc, too_large, true);
    defer alloc.free(failure);
    try std.testing.expect(failure.len < 512);
    try std.testing.expect(std.mem.find(u8, failure, "retry_with") == null);

    const tty = try request_correction(alloc, "{\"command\":\"true\",\"tty\":true}", true);
    defer alloc.free(tty);
    try std.testing.expect(std.mem.find(u8, tty, "retry_with") != null);
}

test "shell interact classification follows optional input" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const cases = [_]struct {
        json: []const u8,
        reads_only: bool,
        process_local: bool,
    }{
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\"}",
            .reads_only = true,
            .process_local = true,
        },
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"\"}",
            .reads_only = true,
            .process_local = true,
        },
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"hello\\n\"}",
            .reads_only = false,
            .process_local = false,
        },
    };
    for (cases) |case| {
        const decoded = try decode(ctx, case.json);
        switch (decoded) {
            .failure => |failure| {
                defer alloc.free(failure);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqual(case.reads_only, readsOnly(input));
                try std.testing.expectEqual(case.process_local, isProcessLocal(input));
            },
        }
    }

    const oversized = try alloc.alloc(u8, terminal_contracts.max_write_bytes + 1);
    defer alloc.free(oversized);
    const failure = try validateInteract(ctx, .{
        .action = .interact,
        .session_id = "shell-1",
        .chars = oversized,
    }) orelse return error.TestUnexpectedResult;
    defer alloc.free(failure);
    try std.testing.expect(std.mem.find(u8, failure, "exceed") != null);
}

test "TTY execution requires matching shell authority" {
    const command_ctx = command_admission.CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .target_os = builtin.target.os.tag,
        .environment = .{ .clean = "/bin/bash" },
        .execution_mode = .tty,
    };
    try std.testing.expectError(
        error.CommandAdmissionChanged,
        requireTtyShellAuthority(.{
            .allocator = std.testing.allocator,
            .execution_authority = .{ .run_command = .{
                .direct_only = .init(command_ctx),
            } },
        }, command_ctx),
    );

    try requireTtyShellAuthority(.{
        .allocator = std.testing.allocator,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .auto_classifier,
        } } },
    }, command_ctx);

    var changed = command_ctx;
    changed.environment = .{ .user = "/bin/bash" };
    try std.testing.expectError(
        error.CommandAuthorityContextMismatch,
        requireTtyShellAuthority(.{
            .allocator = std.testing.allocator,
            .execution_authority = .{ .run_command = .{ .shell_allowed = .{
                .fingerprint = .init(command_ctx),
                .source = .auto_classifier,
            } } },
        }, changed),
    );
}

test "shell decoder preserves null omission and rejects cross action fields" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(
        ctx,
        "{\"action\":\"run\",\"command\":\"true\",\"cwd\":null,\"profile\":null,\"tty\":false,\"yield_time_ms\":0,\"timeout_ms\":null}",
    );
    switch (decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(isCapturedCommand(input));
        },
    }
    const invalid = try decode(
        ctx,
        "{\"action\":\"interact\",\"session_id\":\"shell-session\",\"command\":\"true\"}",
    );
    switch (invalid) {
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expect(std.mem.find(u8, failure, "invalid_shell_request") != null);
        },
    }
}

test "shell decoder applies action specific observation defaults" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const run_decoded = try decode(ctx, "{\"action\":\"run\",\"command\":\"true\"}");
    switch (run_decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                @as(u32, 30_000),
                input.as(OwnedInput).value.yield_time_ms,
            );
        },
    }
    const interact_decoded = try decode(
        ctx,
        "{\"action\":\"interact\",\"session_id\":\"shell-session\"}",
    );
    switch (interact_decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                @as(u32, 5_000),
                input.as(OwnedInput).value.yield_time_ms,
            );
        },
    }
}

test "shell interaction wait bounds empty observations without delaying writes" {
    const cases = [_]struct {
        has_input: bool,
        requested_ms: u32,
        expected_ms: u32,
    }{
        .{ .has_input = false, .requested_ms = 0, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 1_000, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 5_000, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 45_000, .expected_ms = 45_000 },
        .{ .has_input = false, .requested_ms = 300_000, .expected_ms = 300_000 },
        .{ .has_input = true, .requested_ms = 0, .expected_ms = 0 },
        .{ .has_input = true, .requested_ms = 1_000, .expected_ms = 1_000 },
        .{ .has_input = true, .requested_ms = 30_000, .expected_ms = 30_000 },
        .{ .has_input = true, .requested_ms = 300_000, .expected_ms = 30_000 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected_ms,
            effective_interact_yield_time(case.has_input, case.requested_ms),
        );
    }

    const overflow = try decode(
        .{ .allocator = std.testing.allocator },
        "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"yield_time_ms\":4294967296}",
    );
    switch (overflow) {
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
        .failure => |message| std.testing.allocator.free(message),
    }
}

test "shell caps a wait over the action limit instead of refusing the call" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const cases = [_]struct { args: []const u8, expected_ms: u32 }{
        .{ .args = "{\"action\":\"run\",\"command\":\"true\",\"yield_time_ms\":30001}", .expected_ms = legacy_shell_max_yield_time_ms },
        .{ .args = "{\"action\":\"run\",\"command\":\"true\",\"yield_time_ms\":300000}", .expected_ms = legacy_shell_max_yield_time_ms },
        .{ .args = "{\"action\":\"run\",\"command\":\"true\",\"yield_time_ms\":1000}", .expected_ms = 1_000 },
        .{
            .args = std.fmt.comptimePrint(
                "{{\"action\":\"interact\",\"session_id\":\"shell-1\",\"yield_time_ms\":{d}}}",
                .{managed_contract.max_wait_ceiling_ms + 1},
            ),
            .expected_ms = managed_contract.max_wait_ceiling_ms,
        },
        .{ .args = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"yield_time_ms\":45000}", .expected_ms = 45_000 },
    };
    for (cases) |case| {
        switch (try decode(ctx, case.args)) {
            .failure => |failure| {
                defer alloc.free(failure);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqual(case.expected_ms, input.as(OwnedInput).value.yield_time_ms);
            },
        }
    }
}

test "shell decoder rejects removed handoff and legacy actions" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const run_decoded = try decode(
        ctx,
        "{\"action\":\"run\",\"command\":\"sleep 30\",\"yield_time_ms\":0,\"handoff\":\"next_turn\"}",
    );
    switch (run_decoded) {
        .failure => |failure| alloc.free(failure),
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }

    const wait_decoded = try decode(
        ctx,
        "{\"action\":\"wait\",\"session_id\":\"shell-session\"}",
    );
    switch (wait_decoded) {
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
        },
    }
}

test "stopped execution is a successful shell observation without command failure metadata" {
    const alloc = std.testing.allocator;
    const statuses = [_]command_contract.CommandStatus{
        .{ .signal = 15 },
        .{ .exit_code = 143 },
    };
    for (statuses) |status| {
        var memory: ?types.ToolResultMemory = null;
        try publishSnapshotMetadata(.{
            .allocator = alloc,
            .tool_result_memory_sink = &memory,
        }, .{
            .execution_id = @constCast("shell-stopped"),
            .command = @constCast("sleep 60"),
            .cwd = @constCast("/tmp"),
            .retained = true,
            .state = .{ .stopped = status },
            .output_delta = @constCast(""),
            .output_truncated = false,
        });
        try std.testing.expect(memory != null);
        try std.testing.expect(memory.?.command_process_presentation == null);
    }
}

test "lost shell snapshot preserves indeterminate execution guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-lost"),
        .command = @constCast("mutating-command"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .lost,
        .output_delta = @constCast(""),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("termination_indeterminate").?.bool);
    try std.testing.expect(std.mem.find(
        u8,
        object.get("retry_guidance").?.string,
        "do not blindly rerun",
    ) != null);
}

test "a finished command that printed nothing reads as its status alone" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-quiet"),
        .command = @constCast("true"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(""),
        .output_truncated = false,
        .duration_ms = 12,
    }, null);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"state\":\"completed\",\"exit_code\":0,\"duration_ms\":12,\"output_delta\":\"\"}",
        body,
    );
}

test "a finished terminal run still names its backend" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-tty"),
        .command = @constCast("tty"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 7 } },
        .backend = .tty,
        .output_delta = @constCast("/dev/ttys001\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"state\":\"completed\",\"backend\":\"tty\",\"exit_code\":7,\"output_delta\":\"/dev/ttys001\\n\"}",
        body,
    );
}

test "a command still running names its session with the backend and persistence" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-live"),
        .command = @constCast("sleep 30"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .running,
        .output_delta = @constCast("partial\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"session_id\":\"shell-live\",\"state\":\"running\",\"backend\":\"captured\",\"persistence\":\"process\",\"wait_hint\":\"Task shell-live is still running. Call WaitFor with task_id \\\"shell-live\\\" to block until it ends; do not poll with TaskOutput.\",\"output_delta\":\"partial\\n\"}",
        body,
    );
}

test "completed shell snapshot reports incomplete output without losing status" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-incomplete"),
        .command = @constCast("mutating-command"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast("partial output"),
        .output_truncated = false,
        .output_incomplete = true,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("completed", object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 0), object.get("exit_code").?.integer);
    try std.testing.expect(object.get("output_incomplete").?.bool);
    try std.testing.expect(std.mem.find(
        u8,
        object.get("retry_guidance").?.string,
        "do not blindly rerun",
    ) != null);
}

test "completed shell snapshot with shell parse error carries rewrite guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-parse-error"),
        .command = @constCast("grep -rn '"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 1 } },
        .output_delta = @constCast("zsh:1: unmatched '\n"),
        .output_truncated = false,
        .stderr_bytes = "zsh:1: unmatched '\n".len,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("completed", object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings(
        zsh_parse_retry_guidance,
        object.get("retry_guidance").?.string,
    );
}

test "completed zsh parse error after earlier delivered output carries no guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-parse-error-later"),
        .command = @constCast("echo built; sleep 2; eval 'echo \"'"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 1 } },
        .output_delta = @constCast("(eval):1: unmatched \"\n"),
        .output_truncated = false,
        .stdout_bytes = "built\n".len,
        .stderr_bytes = "(eval):1: unmatched \"\n".len,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("retry_guidance") == null);
}

test "completed shell snapshot with usage error carries argument guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-usage-error"),
        .command = @constCast("grep -n"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 2 } },
        .output_delta = @constCast("usage: grep [-abcdDEFGHhIiJLlMmnOopqRSsUVvwXxZz] [-A num] [-B num]\n\t[-e pattern] [-f file] [--binary-files=value]\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings(
        usage_error_retry_guidance,
        object.get("retry_guidance").?.string,
    );
}

test "completed shell snapshot with ordinary failure has no retry guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-ordinary-failure"),
        .command = @constCast("grep needle /nonexistent"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 2 } },
        .output_delta = @constCast("grep: /nonexistent: No such file or directory\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("retry_guidance") == null);
}

test "failure guidance detects signatures in raw output when emitted text is encoded" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-usage-encoded"),
        .command = @constCast("grep -n"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 2 } },
        .output_delta = @constCast("usage: grep [-abcdDEFGHhIiJLlMmnOopqRSsUVvwXxZz]\npartial \x00 binary\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(
        usage_error_retry_guidance,
        object.get("retry_guidance").?.string,
    );
}

test "incomplete output guidance takes precedence over failure guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-incomplete-usage"),
        .command = @constCast("grep -n"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 2 } },
        .output_delta = @constCast("usage: grep [-abcdDEFGHhIiJLlMmnOopqRSsUVvwXxZz]\n"),
        .output_truncated = false,
        .output_incomplete = true,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.find(
        u8,
        parsed.value.object.get("retry_guidance").?.string,
        "do not blindly rerun",
    ) != null);
}

test "failure guidance detectors match only their signatures" {
    try std.testing.expectEqual(
        zsh_parse_retry_guidance,
        failureRetryGuidance(1, "zsh:1: unmatched '\n", true),
    );

    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(2, "/bin/bash: -c: line 1: syntax error: unexpected end of file\n", true),
    );
    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(2, "bash: -c: line 1: syntax error near unexpected token `)'\n", true),
    );
    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(2, "/bin/dash: 1: Syntax error: Unterminated quoted string\n", true),
    );
    try std.testing.expectEqual(
        zsh_parse_retry_guidance,
        failureRetryGuidance(1, "zsh: parse error near '\\n'\n", true),
    );

    try std.testing.expectEqual(
        zsh_parse_retry_guidance,
        failureRetryGuidance(1, "(eval):1: unmatched \"\n", true),
    );
    try std.testing.expectEqual(
        zsh_parse_retry_guidance,
        failureRetryGuidance(1, "(eval):1: parse error near `)'\r\n", true),
    );
    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(1, "/dev/fd/0: eval: line 2: unexpected EOF while looking for matching `\"'\n/dev/fd/0: eval: line 3: syntax error: unexpected end of file\n", true),
    );

    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(1, "/dev/fd/0: eval: line 40: unexpected EOF while looking for matching `\"'\n", true),
    );
    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(2, "/bin/bash: -c: line 1: unexpected EOF while looking for matching `\"'\n", true),
    );
    try std.testing.expectEqual(
        usage_error_retry_guidance,
        failureRetryGuidance(2, "usage: grep [-abcdDEFGHhIiJLlMmnOopqRSsUVvwXxZz]\n", true),
    );
    try std.testing.expectEqual(
        usage_error_retry_guidance,
        failureRetryGuidance(64, "Usage: ls [-ABCFGHabcdfghiklmnopqrstuvwx1] [file ...]\n", true),
    );
    try std.testing.expectEqual(
        usage_error_retry_guidance,
        failureRetryGuidance(2, "grep: unknown option\nusage: grep [-abcdDEFGHhIiJLlMmnOopqRSsUVvwXxZz]\n", true),
    );

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(0, "usage: grep\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(null, "zsh:1: unmatched '\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "main.c:4:5: error: expected ';' after expression (syntax error)\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "error: bash: syntax error\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "(eval):1: no such file or directory: missing\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "/dev/fd/0: line 3: 1 +  : syntax error: operand expected (error token is \" \")\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "(eval):3: parse error: condition expected: =\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "zsh:2: parse error: condition expected: $a\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "(eval):1: unmatched \"\r\nls: /missing: No such file or directory\r\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "BEFORE\nzsh:1: unmatched '\nAFTER\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "RAN\n(eval):1: unmatched \"\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "zsh:1: unmatched \"\nbye\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "(eval):1: unmatched \"\n", false));
    try std.testing.expectEqual(
        line_shell_parse_retry_guidance,
        failureRetryGuidance(1, "/dev/fd/0: eval: line 2: unexpected EOF while looking for matching `\"'\n", false),
    );

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(3, "./build.sh: eval: line 4: unexpected EOF while looking for matching `\"'\n", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(2, "grep: /nonexistent: No such file or directory\n", true));
    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "", true));

    try std.testing.expectEqual(@as(?[]const u8, null), failureRetryGuidance(1, "line one\nline two\nline three\nline four\nusage: not a banner\n", true));
}

test "shell snapshot keeps bounded head tail and control metadata" {
    const alloc = std.testing.allocator;
    const output = "HEAD_SENTINEL\n" ++ text_utils.repeat("x", 70 * 1024) ++ "\nTAIL_SENTINEL";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-large"),
        .command = @constCast("large-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(output),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-large.bin"),
    }, null);
    defer alloc.free(body);

    try std.testing.expect(body.len <= 16 * 1024);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(
        "fx-command-replay-large.bin",
        object.get("full_output_handle").?.string,
    );
    try std.testing.expect(object.get("output_truncated").?.bool);
    const projected = object.get("output_delta").?.string;
    try std.testing.expect(std.mem.find(u8, projected, "HEAD_SENTINEL") != null);
    try std.testing.expect(std.mem.find(u8, projected, "TAIL_SENTINEL") != null);
    try std.testing.expect(std.mem.find(u8, projected, "[output condensed: kept 3 of 3 lines; dropped 0; ") != null);
    try std.testing.expectEqual(@as(i64, output.len), object.get("original_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 0), object.get("dropped_lines").?.integer);
}

test "shell snapshot projects hostile bytes as readable terminal-safe text" {
    const alloc = std.testing.allocator;
    const raw = "\x1b[31mRED\x1b[0m\rREWRITE\t\x00\xff\nCONTROL_TAIL\n";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-hostile"),
        .command = @constCast("hostile-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(raw),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-hostile.bin"),
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const output_value = parsed.value.object.get("output_delta") orelse
        return error.TestExpectedEqual;
    if (output_value != .string) return error.TestUnexpectedResult;
    const terminal_safe = parsed.value.object.get("output_terminal_safe") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(terminal_safe.bool);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\x1b") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\x00") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\xff") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "CONTROL_TAIL") != null);
    try std.testing.expectEqualStrings(
        "fx-command-replay-hostile.bin",
        parsed.value.object.get("full_output_handle").?.string,
    );
}

test "shell snapshot keeps a hostile output tail within the result limit" {
    const alloc = std.testing.allocator;
    const raw = text_utils.repeat("\xff", 70 * 1024) ++ "\nCONTROL_TAIL";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-hostile-large"),
        .command = @constCast("hostile-large-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(raw),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-hostile-large.bin"),
    }, null);
    defer alloc.free(body);

    try std.testing.expect(body.len <= 16 * 1024);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const output_value = parsed.value.object.get("output_delta") orelse
        return error.TestExpectedEqual;
    if (output_value != .string) return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\xff") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "[output condensed: ") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "CONTROL_TAIL") != null);
    try std.testing.expect(parsed.value.object.get("output_truncated").?.bool);
}

test "shell snapshot condenses a long failing output and keeps the failing line and footer" {
    const alloc = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    for (0..150) |index| try output.print(alloc, "\x1b[32mcompiling unit {d}\x1b[0m\n", .{index});
    try output.appendSlice(alloc, "src/main.zig:12:5: error: expected ';' after statement\n");
    for (0..150) |index| try output.print(alloc, "linking object {d}\n", .{index});
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-noisy"),
        .command = @constCast("noisy-build"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 1 } },
        .output_delta = output.items,
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-noisy.bin"),
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const delta = object.get("output_delta").?.string;
    try std.testing.expect(std.mem.startsWith(u8, delta, "compiling unit 0\ncompiling unit 1\n"));
    try std.testing.expect(std.mem.find(u8, delta, "compiling unit 19\n[...]\nsrc/main.zig:12:5: error: expected ';' after statement\n[...]\nlinking object 130\n") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        delta,
        "linking object 149\n[output condensed: kept 41 of 301 lines; dropped 260; " ++
            "6885 original bytes; page the full output with read_tool_result on full_output_handle]",
    ));
    try std.testing.expect(object.get("output_truncated").?.bool);
    try std.testing.expectEqual(@as(i64, 6885), object.get("original_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 260), object.get("dropped_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 1), object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("fx-command-replay-noisy.bin", object.get("full_output_handle").?.string);
}

test "shell snapshot passes output at the condense thresholds byte for byte" {
    const alloc = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    for (0..command_output_content.condense_min_lines / 2) |index| {
        try output.print(alloc, "\x1b[32mrow {d}\x1b[0m\n\n", .{index});
    }
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-small"),
        .command = @constCast("small-output"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = output.items,
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("original_bytes") == null);
    try std.testing.expect(object.get("dropped_lines") == null);
    try std.testing.expect(object.get("output_truncated") == null);
    try std.testing.expect(std.mem.find(u8, object.get("output_delta").?.string, "output condensed") == null);
    try std.testing.expect(std.mem.find(u8, object.get("output_delta").?.string, "row 99") != null);
}

test "shell snapshot masks secrets in the output sent to the model" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-secret"),
        .command = @constCast("print-secret"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\nplain line\n"),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "abcdefghijklmnopqrstuvwxyz012345") == null);
    try std.testing.expect(std.mem.find(u8, body, "[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, body, "plain line") != null);
}

fn retainedReplayForTest(
    arena: Allocator,
    store: *command_replay_store.EphemeralStore,
    chunks: []const []const u8,
) ![]const u8 {
    const capture = try command_replay_store.Capture.createEphemeral(arena, 0, store);
    for (chunks) |chunk| try capture.appendAcceptedRequired(arena, .stdout, chunk);
    const descriptor = (try capture.retainRequired(arena)) orelse return error.TestExpectedEqual;
    return descriptor.handle;
}

test "shell snapshot takes its last lines from the replay when the in-memory output was cut" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_path);
    var store = command_replay_store.EphemeralStore.initForTesting(alloc, temp_path);
    defer store.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    for (0..6000) |index| try full.print(alloc, "progress line number {d}\n", .{index});
    try full.appendSlice(alloc, "FAILED: test_widget assertion\n");
    for (0..3000) |index| try full.print(alloc, "teardown step {d}\n", .{index});
    try full.appendSlice(alloc, "TRUE_LAST_LINE exit status 3\n");
    const memory_limit = tool_result_limits.default_max_tool_result_bytes;
    try std.testing.expect(full.items.len > 2 * memory_limit);

    const handle = try retainedReplayForTest(arena, &store, &.{
        full.items[0..1000],
        full.items[1000..memory_limit],
        full.items[memory_limit..],
    });
    const body = try formatSnapshotWithLimit(alloc, .{
        .execution_id = @constCast("shell-cut"),
        .command = @constCast("long-run"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 3 } },
        .output_delta = full.items[0..memory_limit],
        .output_truncated = true,
        .output_file = @constCast(handle),
        .stdout_bytes = full.items.len,
    }, null, tool_result_limits.default_max_tool_result_bytes, .{ .ephemeral = &store });
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const delta = object.get("output_delta").?.string;
    try std.testing.expect(std.mem.startsWith(u8, delta, "progress line number 0\n"));
    try std.testing.expect(std.mem.find(u8, delta, "[...]\nFAILED: test_widget assertion\n[...]\n") != null);
    try std.testing.expect(std.mem.find(u8, delta, "teardown step 2999\nTRUE_LAST_LINE exit status 3\n[output condensed: kept 41 of 9002 lines; dropped 8961; ") != null);
    try std.testing.expectEqual(@as(i64, @intCast(full.items.len)), object.get("original_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 8961), object.get("dropped_lines").?.integer);
    try std.testing.expect(body.len <= result_store.large_result_threshold_bytes);
}

test "shell snapshot joins a later delta to the true end of the replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_path);
    var store = command_replay_store.EphemeralStore.initForTesting(alloc, temp_path);
    defer store.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    try full.appendSlice(alloc, "already delivered line\n");
    const delta_start = full.items.len;
    for (0..300) |index| try full.print(alloc, "second read line {d}\n", .{index});
    const delta_end = full.items.len;
    for (0..300) |index| try full.print(alloc, "never buffered line {d}\n", .{index});
    try full.appendSlice(alloc, "TRUE_LAST_LINE\n");

    const handle = try retainedReplayForTest(arena, &store, &.{full.items});
    const body = try formatSnapshotWithLimit(alloc, .{
        .execution_id = @constCast("shell-later"),
        .command = @constCast("long-run"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = full.items[delta_start..delta_end],
        .output_truncated = true,
        .output_file = @constCast(handle),
        .stdout_bytes = full.items.len,
    }, null, tool_result_limits.default_max_tool_result_bytes, .{ .ephemeral = &store });
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const delta = parsed.value.object.get("output_delta").?.string;
    try std.testing.expect(std.mem.startsWith(u8, delta, "second read line 0\n"));
    try std.testing.expect(std.mem.find(u8, delta, "already delivered line") == null);
    try std.testing.expect(std.mem.find(u8, delta, "second read line 19\n[...]\nnever buffered line 281\n") != null);
    try std.testing.expect(std.mem.find(u8, delta, "never buffered line 299\nTRUE_LAST_LINE\n[output condensed: ") != null);
}

test "Bash refuses an unknown argument by name and lists the accepted fields" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "Bash" };
    const decoded = try decodeBash(ctx, "{\"command\":\"printf hi\",\"tty\":true}");
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings(
                "Bash does not take argument \"tty\"; accepted fields: command, cwd, timeout, description, run_in_background, disable_timeout, name",
                message,
            );
        },
    }
}

test "Bash names the accepted fields when a known field has the wrong type" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "Bash" };
    const decoded = try decodeBash(ctx, "{\"command\":7}");
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings(bash_shape_failure, message);
            try std.testing.expect(std.mem.find(u8, message, "run_in_background") != null);
        },
    }
}

test "running shell snapshot leaves continuation intent to the caller" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-running"),
        .command = @constCast("long-command"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .running,
        .output_delta = @constCast(""),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("next_action") == null);
    try std.testing.expectEqualStrings(
        "shell-running",
        parsed.value.object.get("session_id").?.string,
    );
    try std.testing.expectEqualStrings(
        "running",
        parsed.value.object.get("state").?.string,
    );
}

test "registered shell empty observation waits through one managed execution" {
    if (comptime @import("builtin").target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    var streamed_bytes = std.atomic.Value(usize).init(0);
    const StreamCapture = struct {
        fn append(
            raw: *anyopaque,
            _: ?types.ToolLifecycleId,
            _: command_contract.CommandOutputStream,
            chunk: []const u8,
        ) !void {
            const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(raw));
            _ = count.fetchAdd(chunk.len, .seq_cst);
        }
    };
    const spec = tool_dispatch.Tool{
        .name = "shell",
        .description = "shell",
        .model_schema = .{ .name = "shell", .description = "shell" },
        .executor_kind = .terminal,
        .activity_kind = .command,
        .requires_approval = true,
        .decode = decode,
        .validate = validate,
        .call = call,
        .captured_command_action = "run",
        .captured_command_fn = isCapturedCommand,
        .process_local_fn = isProcessLocal,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    };
    const registry = tool_dispatch.Registry{ .tools = &.{spec} };
    var environment_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer environment_arena_state.deinit();
    const environment = try commandEnvironment(
        environment_arena_state.allocator(),
        .{ .allocator = alloc, .workspace_root = "/tmp" },
        .clean,
    );
    const command_ctx = command_admission.CommandContext{
        .command = "sleep 2; printf done",
        .resolved_cwd = "/tmp",
        .target_os = @import("builtin").target.os.tag,
        .environment = environment,
    };
    const authority = command_admission.CommandExecutionAuthority{
        .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .yolo,
        },
    };
    const started = try tool_dispatch.dispatchAuthorizedToolCall(
        .{
            .allocator = alloc,
            .workspace_root = "/tmp",
            .tool_call_id = "shell-integration",
            .managed_executions = &runtime,
            .execution_authority = .{ .run_command = authority },
            .max_command_output_bytes = 4096,
            .output_chunk_lifecycle_id = .{
                .turn_id = 1,
                .call_id = "shell-integration",
            },
            .output_chunk_ctx = &streamed_bytes,
            .on_output_chunk = StreamCapture.append,
        },
        registry,
        .{
            .id = "shell-integration",
            .name = "shell",
            .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 2; printf done\",\"cwd\":\"/tmp\",\"profile\":\"clean\",\"yield_time_ms\":0}",
        },
    );
    defer started.deinit(alloc);
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, started.status);
    try std.testing.expect(std.mem.find(u8, started.body, "\"state\":\"running\"") != null);
    var started_json = try std.json.parseFromSlice(std.json.Value, alloc, started.body, .{});
    defer started_json.deinit();
    const execution_id = started_json.value.object.get("session_id") orelse
        return error.TestExpectedEqual;
    const interact_arguments = try alloc.print(
        "{{\"action\":\"interact\",\"session_id\":\"{s}\",\"yield_time_ms\":1000}}",
        .{execution_id.string},
    );
    defer alloc.free(interact_arguments);

    var command_result_json: ?[]const u8 = null;
    defer if (command_result_json) |json| alloc.free(@constCast(json));
    var tool_result_memory: ?types.ToolResultMemory = null;
    defer if (tool_result_memory) |memory| {
        if (memory.command_output_replay) |replay| switch (replay) {
            .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
            .unavailable => {},
        };
    };
    const waited = try tool_dispatch.dispatchAuthorizedToolCall(
        .{
            .allocator = alloc,
            .workspace_root = "/tmp",
            .tool_call_id = "shell-wait",
            .execution_authority = .ordinary,
            .managed_executions = &runtime,
            .max_command_output_bytes = 4096,
            .command_result_json_sink = &command_result_json,
            .tool_result_memory_sink = &tool_result_memory,
        },
        registry,
        .{
            .id = "shell-wait",
            .name = "shell",
            .arguments_json = interact_arguments,
        },
    );
    defer waited.deinit(alloc);
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, waited.status);
    try std.testing.expect(std.mem.find(u8, waited.body, "\"state\":\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, waited.body, "done") != null);
    try std.testing.expectEqual(@as(usize, "done".len), streamed_bytes.load(.seq_cst));
    try std.testing.expect(std.mem.find(
        u8,
        command_result_json orelse return error.TestExpectedEqual,
        "\"kind\":\"command\"",
    ) != null);
    const replay = tool_result_memory.?.command_output_replay orelse
        return error.TestExpectedEqual;
    try std.testing.expect(replay == .available);
}

test "shell delivery advances only after result commit" {
    if (comptime @import("builtin").target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "printf commit-token",
        .resolved_cwd = "/tmp",
        .target_os = @import("builtin").target.os.tag,
        .environment = .legacy,
    };
    var prepared = try runtime.startCaptured(alloc, .{
        .execution_id = "delivery-commit",
        .command = command_ctx.command,
        .cwd = command_ctx.resolved_cwd,
        .environment = command_ctx.environment,
        .authority = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .yolo,
        } },
        .max_output_bytes = 4096,
        .timeout_ms = 2000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    });
    defer prepared.deinit(alloc);
    var commit_token: ?result_commit.Token = null;
    var result = try finishPrepared(
        .{
            .allocator = alloc,
            .result_commit_sink = &commit_token,
        },
        &runtime,
        &prepared,
        .command,
    );
    defer result.deinit(alloc);
    try std.testing.expect(commit_token != null);
    try std.testing.expectError(
        error.ExecutionBusy,
        runtime.wait(alloc, "delivery-commit", 0, null),
    );
    commit_token.?.cancel();
    var replayed = try runtime.wait(alloc, "delivery-commit", 2000, null);
    defer replayed.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        replayed.snapshot.output_delta,
        "commit-token",
    ) != null);
    try runtime.commitDelivery(
        replayed.snapshot.execution_id,
        replayed.reservation_id,
    );
}

fn timedOutSnapshotCapture(_: shell_snapshot.CaptureRequest) shell_snapshot.CaptureOutcome {
    return .{ .failed = .timed_out };
}

test "shell run result carries a snapshot fallback notice once" {
    const alloc = std.testing.allocator;
    shell_snapshot.resetProcessOwnerForTest(timedOutSnapshotCapture);
    defer shell_snapshot.resetProcessOwnerForTest(shell_snapshot.real_capture_fn);
    try std.testing.expect((try shell_snapshot.processOwner().acquire("/bin/zsh", "/tmp", .{})) == .full_startup);

    const plain = try attachSnapshotNotice(alloc, .{ .failure = try alloc.dupe(u8, "shell result is unavailable") });
    defer plain.deinit(alloc);
    try std.testing.expectEqualStrings("shell result is unavailable", plain.failure);

    const first = try attachSnapshotNotice(alloc, .{ .success = try alloc.dupe(u8, "{\"state\":\"completed\"}") });
    defer first.deinit(alloc);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, first.success, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("completed", parsed.value.object.get("state").?.string);
    const notice = parsed.value.object.get("notice").?.string;
    try std.testing.expect(std.mem.find(u8, notice, "did not finish within 10 s") != null);

    const second = try attachSnapshotNotice(alloc, .{ .success = try alloc.dupe(u8, "{\"state\":\"completed\"}") });
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("{\"state\":\"completed\"}", second.success);
}

fn expectDecodedInput(decoded: tool_dispatch.DecodeResult) !tool_dispatch.ToolInput {
    return switch (decoded) {
        .input => |input| input,
        .failure => |message| {
            defer std.testing.allocator.free(message);
            std.debug.print("unexpected decode failure: {s}\n", .{message});
            return error.TestExpectedEqual;
        },
    };
}

fn expectDecodeRefused(decoded: tool_dispatch.DecodeResult) !void {
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| std.testing.allocator.free(message),
    }
}

test "TaskOutput reads the snapshot of a background task by task_id" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "TaskOutput" };
    const input = try expectDecodedInput(try decodeTaskOutput(ctx, "{\"task_id\":\"shell-1\"}"));
    defer input.deinit(std.testing.allocator);
    const value = input.as(OwnedInput).value;
    try std.testing.expectEqual(Action.interact, value.action);
    try std.testing.expectEqualStrings("shell-1", value.session_id.?);
    try std.testing.expectEqual(@as(u32, 0), value.yield_time_ms);
    try std.testing.expect(value.chars == null);
    try std.testing.expect(readsOnly(input));
}

test "TaskOutput refuses a missing, empty, or extra-field task_id" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "TaskOutput" };
    const refused = [_][]const u8{
        "{}",
        "{\"task_id\":\"\"}",
        "{\"task_id\":\"shell-1\",\"chars\":\"y\"}",
        "[]",
    };
    for (refused) |args| try expectDecodeRefused(try decodeTaskOutput(ctx, args));
}

fn decodedBashValue(args: []const u8) !Input {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "Bash" };
    const input = try expectDecodedInput(try decodeBash(ctx, args));
    defer input.deinit(std.testing.allocator);
    var value = input.as(OwnedInput).value;
    value.command = null;
    value.cwd = null;
    value.task_name = null;
    return value;
}

fn expectBashRefusal(args: []const u8, expected: []const u8) !void {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "Bash" };
    switch (try decodeBash(ctx, args)) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings(expected, message);
        },
    }
}

test "Bash takes a task name only for a background task and uses it as the task id" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "Bash" };
    const named = try expectDecodedInput(try decodeBash(ctx, "{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\",\"name\":\"build_1-a\"}"));
    defer named.deinit(std.testing.allocator);
    const value = named.as(OwnedInput).value;
    try std.testing.expectEqualStrings("build_1-a", value.task_name.?);
    try std.testing.expect(value.background);
    try std.testing.expectEqual(@as(u32, 0), value.yield_time_ms);

    try expectBashRefusal("{\"command\":\"make\",\"name\":\"build\"}", bash_name_background_refusal);
    try expectBashRefusal("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\",\"name\":\"has space\"}", bash_name_shape_refusal);
    try expectBashRefusal("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\",\"name\":\"\"}", bash_name_shape_refusal);

    const unnamed = try decodedBashValue("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\"}");
    try std.testing.expect(unnamed.background);
    const foreground = try decodedBashValue("{\"command\":\"make\"}");
    try std.testing.expect(!foreground.background);
}

test "Bash foreground timeout reaches one hour and an explicit timeout holds the call" {
    const defaulted = try decodedBashValue("{\"command\":\"make\"}");
    try std.testing.expectEqual(managed_contract.default_yield_time_ms, defaulted.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 60_000), defaulted.timeout_ms);

    const short = try decodedBashValue("{\"command\":\"make\",\"timeout\":10}");
    try std.testing.expectEqual(managed_contract.default_yield_time_ms, short.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 10_000), short.timeout_ms);

    const build = try decodedBashValue("{\"command\":\"make\",\"timeout\":600}");
    try std.testing.expectEqual(@as(u32, 600_000), build.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 600_000), build.timeout_ms);

    const longest = try decodedBashValue("{\"command\":\"make\",\"timeout\":3600}");
    try std.testing.expectEqual(managed_contract.max_yield_time_ms, longest.yield_time_ms);

    try expectBashRefusal(
        "{\"command\":\"make\",\"timeout\":3601}",
        "Bash timeout must be at most 3600 seconds for a foreground command; use run_in_background for longer work.",
    );
}

test "Bash auto background on timeout yields at the timeout and keeps the background deadline" {
    const saved = managed_contract.taskSettings();
    defer managed_contract.setTaskSettings(saved);
    var settings = saved;
    settings.auto_background_on_timeout = true;
    settings.background_timeout_s = null;
    managed_contract.setTaskSettings(settings);

    const explicit = try decodedBashValue("{\"command\":\"make\",\"timeout\":10}");
    try std.testing.expectEqual(@as(u32, 10_000), explicit.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 600_000), explicit.timeout_ms);

    const defaulted = try decodedBashValue("{\"command\":\"make\"}");
    try std.testing.expectEqual(managed_contract.default_yield_time_ms, defaulted.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 600_000), defaulted.timeout_ms);

    const long = try decodedBashValue("{\"command\":\"make\",\"timeout\":1200}");
    try std.testing.expectEqual(@as(u32, 1_200_000), long.yield_time_ms);
    try std.testing.expectEqual(@as(?u64, 1_200_000), long.timeout_ms);
}

test "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS refuses a background Bash command and leaves foreground ones alone" {
    const saved = managed_contract.taskSettings();
    defer managed_contract.setTaskSettings(saved);
    var settings = saved;
    settings.background_disabled = true;
    managed_contract.setTaskSettings(settings);
    try std.testing.expectEqualStrings(
        bash_background_disabled_refusal,
        bashProblem(.{ .command = "make", .run_in_background = true, .description = "build" }).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), bashProblem(.{ .command = "make" }));
    settings.background_disabled = false;
    managed_contract.setTaskSettings(settings);
    try std.testing.expectEqual(@as(?[]const u8, null), bashProblem(.{ .command = "make", .run_in_background = true, .description = "build" }));
}

test "Bash background default timeout follows the task timeout setting" {
    const saved = managed_contract.taskSettings();
    defer managed_contract.setTaskSettings(saved);
    var settings = saved;
    settings.auto_background_on_timeout = false;
    settings.background_timeout_s = 1800;
    managed_contract.setTaskSettings(settings);
    const configured = try decodedBashValue("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\"}");
    try std.testing.expectEqual(@as(?u64, 1_800_000), configured.timeout_ms);
    const explicit = try decodedBashValue("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\",\"timeout\":30}");
    try std.testing.expectEqual(@as(?u64, 30_000), explicit.timeout_ms);
    const unbounded = try decodedBashValue("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\",\"disable_timeout\":true}");
    try std.testing.expectEqual(@as(?u64, null), unbounded.timeout_ms);

    settings.background_timeout_s = 0;
    managed_contract.setTaskSettings(settings);
    const built_in = try decodedBashValue("{\"command\":\"make\",\"run_in_background\":true,\"description\":\"build\"}");
    try std.testing.expectEqual(@as(?u64, 600_000), built_in.timeout_ms);
}

test "TaskOutput decodes wait and tail within their bounds" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "TaskOutput" };
    const waited = try expectDecodedInput(try decodeTaskOutput(ctx, "{\"task_id\":\"build\",\"wait\":600,\"tail\":32768}"));
    defer waited.deinit(std.testing.allocator);
    const value = waited.as(OwnedInput).value;
    try std.testing.expectEqual(@as(u32, 600_000), value.yield_time_ms);
    try std.testing.expectEqual(@as(?u32, 32768), value.tail_bytes);
    try std.testing.expect(readsOnly(waited));

    const tail_only = try expectDecodedInput(try decodeTaskOutput(ctx, "{\"task_id\":\"build\",\"tail\":1}"));
    defer tail_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), tail_only.as(OwnedInput).value.yield_time_ms);

    const cases = [_]struct { args: []const u8, expected: []const u8 }{
        .{ .args = "{\"task_id\":\"build\",\"wait\":0}", .expected = task_output_wait_refusal },
        .{ .args = "{\"task_id\":\"build\",\"wait\":601}", .expected = task_output_wait_refusal },
        .{ .args = "{\"task_id\":\"build\",\"tail\":0}", .expected = task_output_tail_refusal },
        .{ .args = "{\"task_id\":\"build\",\"tail\":32769}", .expected = task_output_tail_refusal },
        .{ .args = "{\"task_id\":\"build\",\"wait\":\"long\"}", .expected = task_output_shape_failure },
    };
    for (cases) |case| {
        switch (try decodeTaskOutput(ctx, case.args)) {
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedEqual;
            },
            .failure => |message| {
                defer std.testing.allocator.free(message);
                try std.testing.expectEqualStrings(case.expected, message);
            },
        }
    }
}

test "timed out snapshot names the cause and the fields to change" {
    const alloc = std.testing.allocator;
    const foreground = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-7"),
        .command = @constCast("make"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .stopped = null },
        .output_delta = @constCast("partial\n"),
        .output_truncated = false,
        .error_name = @constCast("TimeoutExpired"),
        .timeout_ms = 60_000,
    }, null);
    defer alloc.free(foreground);
    try std.testing.expect(std.mem.find(u8, foreground, "\"cause\":\"The command was stopped because it ran past its timeout of 60 s.\"") != null);
    try std.testing.expect(std.mem.find(u8, foreground, "\"retry_guidance\":\"" ++ foreground_timeout_retry_guidance ++ "\"") != null);
    try std.testing.expect(std.mem.find(u8, foreground_timeout_retry_guidance, "timeout") != null);
    try std.testing.expect(std.mem.find(u8, foreground_timeout_retry_guidance, "run_in_background") != null);
    try std.testing.expect(std.mem.find(u8, foreground, "partial") != null);

    const background = try formatSnapshot(alloc, .{
        .execution_id = @constCast("build"),
        .command = @constCast("make"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .stopped = null },
        .output_delta = @constCast(""),
        .output_truncated = false,
        .error_name = @constCast("TimeoutExpired"),
    }, null);
    defer alloc.free(background);
    try std.testing.expect(std.mem.find(u8, background, "\"cause\":\"The command was stopped because it ran past its timeout.\"") != null);
    try std.testing.expect(std.mem.find(u8, background, "disable_timeout") != null);
    try std.testing.expect(std.mem.find(u8, background, "86400") != null);

    const incomplete = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-8"),
        .command = @constCast("make"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .stopped = null },
        .output_delta = @constCast(""),
        .output_truncated = false,
        .output_incomplete = true,
        .error_name = @constCast("TimeoutExpired"),
    }, null);
    defer alloc.free(incomplete);
    try std.testing.expect(std.mem.find(u8, incomplete, "Command output is incomplete.") != null);
    try std.testing.expect(std.mem.find(u8, incomplete, foreground_timeout_retry_guidance) == null);
}

test "retained task snapshot carries timing, the stuck and stale marks, the log path and the wait hint" {
    const alloc = std.testing.allocator;
    const running = try formatSnapshot(alloc, .{
        .execution_id = @constCast("build"),
        .command = @constCast("make"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .running,
        .output_delta = @constCast(""),
        .output_truncated = false,
        .running_ms = 4_000,
        .idle_ms = 3_000,
        .stuck = true,
        .tree_changed = true,
        .log_path = @constCast("/tmp/fx/build.log"),
    }, null);
    defer alloc.free(running);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, running, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 4_000), object.get("running_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 3_000), object.get("idle_ms").?.integer);
    try std.testing.expect(object.get("stuck").?.bool);
    try std.testing.expectEqualStrings(stale_tree_mark, object.get("stale").?.string);
    try std.testing.expectEqualStrings("/tmp/fx/build.log", object.get("log_path").?.string);
    try std.testing.expectEqualStrings(
        "Task build is still running. Call WaitFor with task_id \"build\" to block until it ends; do not poll with TaskOutput.",
        object.get("wait_hint").?.string,
    );

    const finished = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-9"),
        .command = @constCast("true"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(""),
        .output_truncated = false,
        .running_ms = 12,
        .tree_changed = true,
    }, null);
    defer alloc.free(finished);
    try std.testing.expect(std.mem.find(u8, finished, "wait_hint") == null);
    try std.testing.expect(std.mem.find(u8, finished, "running_ms") == null);
    try std.testing.expect(std.mem.find(u8, finished, "stale") == null);
}

test "task admission refusals name the task and the running task limit" {
    const alloc = std.testing.allocator;
    const in_use = (try taskAdmissionRefusal(alloc, error.TaskNameInUse, "build", 4)).?;
    defer alloc.free(in_use);
    try std.testing.expectEqualStrings(
        "A background task named build already exists in this session; pick another name.",
        in_use,
    );
    const limited = (try taskAdmissionRefusal(alloc, error.RunningTaskLimitReached, "build", 4)).?;
    defer alloc.free(limited);
    try std.testing.expect(std.mem.find(u8, limited, "limit of 4 running background tasks") != null);
    try std.testing.expect(std.mem.find(u8, limited, "task.max_running_tasks") != null);
    try std.testing.expect((try taskAdmissionRefusal(alloc, error.ExecutionCapacityExceeded, "build", 4)) == null);
}

test "task tail renders the true end of the output with its timing and stale mark" {
    const alloc = std.testing.allocator;
    const body = try formatTaskTail(alloc, "build", .{
        .bytes = @constCast("last line\n"),
        .total_bytes = 90_000,
        .truncated = true,
        .state = .running,
        .running_ms = 5_000,
        .idle_ms = 100,
        .stuck = false,
        .tree_changed = true,
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"session_id\":\"build\",\"state\":\"running\",\"total_bytes\":90000,\"tail_truncated\":true,\"running_ms\":5000,\"idle_ms\":100,\"stale\":\"files changed after this task started\",\"tail\":\"last line\\n\"}",
        body,
    );
}

test "TaskStop records the default reason and accepts a custom one" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "TaskStop" };
    const defaulted = try expectDecodedInput(try decodeTaskStop(ctx, "{\"task_id\":\"shell-1\"}"));
    defer defaulted.deinit(std.testing.allocator);
    const default_value = defaulted.as(OwnedInput).value;
    try std.testing.expectEqual(Action.stop, default_value.action);
    try std.testing.expectEqualStrings("shell-1", default_value.session_id.?);
    try std.testing.expectEqualStrings("Stopped by TaskStop", default_value.stop_reason.?);

    const custom = try expectDecodedInput(try decodeTaskStop(ctx, "{\"task_id\":\"shell-1\",\"reason\":\"superseded\"}"));
    defer custom.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("superseded", custom.as(OwnedInput).value.stop_reason.?);
}

test "TaskStop refuses an empty reason and unknown fields" {
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "TaskStop" };
    try expectDecodeRefused(try decodeTaskStop(ctx, "{\"task_id\":\"shell-1\",\"reason\":\"\"}"));
    try expectDecodeRefused(try decodeTaskStop(ctx, "{\"task_id\":\"shell-1\",\"force\":true}"));
}

test "TaskStop result leads with the reason on success and failure" {
    const alloc = std.testing.allocator;
    const ok = try withStopReason(.{ .allocator = alloc, .tool_call_name = "TaskStop" }, .{ .success = try alloc.dupe(u8, "{\"state\":\"stopped\"}") }, "Stopped by TaskStop");
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("reason: Stopped by TaskStop\n{\"state\":\"stopped\"}", ok.success);

    const failed = try withStopReason(.{ .allocator = alloc, .tool_call_name = "TaskStop" }, .{ .failure = try alloc.dupe(u8, "not found") }, "superseded");
    defer failed.deinit(alloc);
    try std.testing.expectEqualStrings("reason: superseded\nnot found", failed.failure);
}
