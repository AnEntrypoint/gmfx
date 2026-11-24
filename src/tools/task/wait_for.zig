const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const command_admission = @import("../../core/permissions/command_admission.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const process_tree = @import("../../core/execution/process_tree.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const shell = @import("../shell/shell.zig");

const Allocator = std.mem.Allocator;

pub const description =
    "Wait up to timeout seconds (1 to 600) in one call instead of polling. Pass task_id to wait for one background task and get its output, pid to wait for a process fx did not start, or neither to wait while any background task of this agent runs: the call wakes when one finishes, stalls or is killed by its timeout, and returns at once when none is running. It may also wake when a message for this agent arrives. The result carries the task notice when there is one. A timeout is not an error: without pid, the result lists each task still running with how long it has run and how long it has been silent.";

const polls_per_second: u32 = 10;
const poll_interval_ns: u64 = std.time.ns_per_s / polls_per_second;
const min_timeout_s: i64 = 1;
const max_timeout_s: i64 = 600;
const notice_grace_polls: u32 = 5;
const max_listed_command_bytes: usize = 120;
const pid_wait_supported = builtin.target.os.tag != .wasi and builtin.target.os.tag != .windows;
const timeout_refusal = "WaitFor timeout must be an integer from 1 to 600 seconds.";
const task_id_refusal = "WaitFor task_id cannot be empty.";
const pid_and_task_refusal = "WaitFor takes task_id or pid, not both.";
const pid_range_refusal = "WaitFor pid must be a process ID greater than 1.";
const own_pid_refusal = "WaitFor cannot wait for the fx process itself.";
const pid_unsupported_refusal = "WaitFor pid is not supported on this platform.";
const shape_refusal = "WaitFor arguments must be a JSON object with timeout and optional task_id or pid.";
const unavailable_message = "WaitFor is not available in this session.";
const no_tasks_message = "No background tasks exist.";
const finished_message = "Background task finished.";
const none_running_message = "No running background task.";
const message_arrived_message = "A message for this agent arrived; it is delivered right after this result.";
const Waited = struct { started: usize, waiting: usize, timed_out: bool };
const ProcessProbe = *const fn (Allocator, i64) bool;

const Arguments = struct {
    timeout: ?i64 = null,
    task_id: ?[]const u8 = null,
    pid: ?i64 = null,
};

pub const Input = struct {
    timeout_s: u32,
    task_id: ?[]u8,
    pid: ?i64 = null,

    fn deinit(self: Input, alloc: Allocator) void {
        if (self.task_id) |task_id| alloc.free(task_id);
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arguments = std.json.parseFromSliceLeaky(Arguments, arena_state.allocator(), args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, shape_refusal) };
    };
    const timeout = arguments.timeout orelse return .{ .failure = try ctx.allocator.dupe(u8, timeout_refusal) };
    if (timeout < min_timeout_s or timeout > max_timeout_s) {
        return .{ .failure = try ctx.allocator.dupe(u8, timeout_refusal) };
    }
    if (arguments.task_id) |task_id| {
        if (task_id.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, task_id_refusal) };
    }
    if (arguments.pid) |pid| {
        if (pidProblem(pid, arguments.task_id != null)) |problem| {
            return .{ .failure = try ctx.allocator.dupe(u8, problem) };
        }
    }
    const owned_task_id: ?[]u8 = if (arguments.task_id) |task_id| try ctx.allocator.dupe(u8, task_id) else null;
    errdefer if (owned_task_id) |task_id| ctx.allocator.free(task_id);
    return .{ .input = try wrap(ctx.allocator, .{
        .timeout_s = @intCast(timeout),
        .task_id = owned_task_id,
        .pid = arguments.pid,
    }) };
}

fn pidProblem(pid: i64, has_task_id: bool) ?[]const u8 {
    if (has_task_id) return pid_and_task_refusal;
    if (comptime !pid_wait_supported) return pid_unsupported_refusal;
    if (pid <= 1 or pid > std.math.maxInt(i32)) return pid_range_refusal;
    if (pid == ownPid()) return own_pid_refusal;
    return null;
}

fn ownPid() i64 {
    if (comptime !pid_wait_supported) return 0;
    return @intCast(std.c.getpid());
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.pid) |pid| return waitForProcess(ctx.allocator, pid, input.timeout_s, ctx.cancel_flag, processAlive);
    const runtime = ctx.managed_executions orelse return .{
        .failure = try ctx.allocator.dupe(u8, unavailable_message),
    };
    if (input.task_id) |task_id| return waitForTask(ctx, runtime, input.timeout_s, task_id);
    return waitForAnyEvent(ctx, runtime, input.timeout_s);
}

fn waitForTask(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    timeout_s: u32,
    task_id: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const state = runtime.stateFor(task_id) orelse return .{
        .success = try unknownTaskMessage(ctx.allocator, runtime, task_id),
    };
    if (std.meta.activeTag(state) == .running) {
        const waited = try waitWhileRunning(ctx.allocator, runtime, timeout_s, task_id, ctx.cancel_flag);
        if (waited.timed_out) return .{ .success = try timeoutResult(ctx.allocator, runtime, timeout_s, waited.waiting) };
    }
    return shell.readTaskOutput(ctx, task_id);
}

fn waitForAnyEvent(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    timeout_s: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const alloc = ctx.allocator;
    runtime.beginEventWait();
    defer runtime.endEventWait();
    const poll_limit = timeout_s * polls_per_second;
    var polls: u32 = 0;
    var started: usize = 0;
    var quiet_polls: u32 = 0;
    while (true) {
        if (cancelled(ctx.cancel_flag)) return error.Cancelled;
        if (try takeNoticeText(alloc, runtime)) |text| return .{ .success = text };
        if (runtime.externalEventsPending() > 0) return .{ .success = try alloc.dupe(u8, message_arrived_message) };
        const waiting = try runningCount(alloc, runtime, null);
        if (polls == 0) started = waiting;
        if (waiting == 0) {
            if (started == 0) {
                const message = if (runtime.hasExecutions()) none_running_message else no_tasks_message;
                return .{ .success = try alloc.dupe(u8, message) };
            }
            if (quiet_polls >= notice_grace_polls) return .{ .success = try alloc.dupe(u8, finished_message) };
            quiet_polls += 1;
        } else if (polls >= poll_limit) {
            return .{ .success = try timeoutResult(alloc, runtime, timeout_s, waiting) };
        }
        io_mod.sleep(poll_interval_ns);
        polls += 1;
    }
}

fn takeNoticeText(alloc: Allocator, runtime: *managed_execution.Runtime) !?[]u8 {
    const notices = try runtime.takeNotices(alloc);
    defer managed_execution.freeNotices(alloc, notices);
    if (notices.len == 0) return null;
    return try joinNotices(alloc, notices);
}

fn joinNotices(alloc: Allocator, notices: []const []u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (notices, 0..) |notice, index| {
        if (index != 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, std.mem.trimEnd(u8, notice, "\n"));
    }
    return out.toOwnedSlice(alloc);
}

fn cancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    const flag = cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

fn waitForProcess(
    alloc: Allocator,
    pid: i64,
    timeout_s: u32,
    cancel_flag: ?*std.atomic.Value(bool),
    probe: ProcessProbe,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (comptime !pid_wait_supported) return .{ .failure = try alloc.dupe(u8, pid_unsupported_refusal) };
    if (!probe(alloc, pid)) return .{ .success = try std.fmt.allocPrint(alloc, "No process with pid {d}.", .{pid}) };
    const poll_limit = timeout_s * polls_per_second;
    var polls: u32 = 0;
    while (true) {
        if (cancelled(cancel_flag)) return error.Cancelled;
        if (polls >= poll_limit) return .{ .success = try std.fmt.allocPrint(
            alloc,
            "Timed out after {d} seconds; process {d} is still running.",
            .{ timeout_s, pid },
        ) };
        io_mod.sleep(poll_interval_ns);
        polls += 1;
        if (!probe(alloc, pid)) return .{ .success = try std.fmt.allocPrint(
            alloc,
            "Process {d} exited after {d} s of waiting.",
            .{ pid, polls / polls_per_second },
        ) };
    }
}

fn processAlive(alloc: Allocator, pid: i64) bool {
    if (comptime !pid_wait_supported) return false;
    const native: std.posix.pid_t = @intCast(pid);
    if (process_tree.processIsAlive(alloc, native)) |alive| return alive else |_| {}
    std.posix.kill(native, @fromBackingInt(@intCast(0))) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

fn unknownTaskMessage(alloc: Allocator, runtime: *managed_execution.Runtime, task_id: []const u8) Allocator.Error![]u8 {
    if (!runtime.hasExecutions()) return alloc.dupe(u8, no_tasks_message);
    return std.fmt.allocPrint(alloc, "No background task with id {s}.", .{task_id});
}

fn waitWhileRunning(
    alloc: Allocator,
    runtime: *managed_execution.Runtime,
    timeout_s: u32,
    task_id: ?[]const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) !Waited {
    var polls: u32 = 0;
    var started: usize = 0;
    const poll_limit = timeout_s * polls_per_second;
    while (true) {
        if (cancelled(cancel_flag)) return error.Cancelled;
        const waiting = try runningCount(alloc, runtime, task_id);
        if (polls == 0) started = waiting;
        if (waiting == 0) return .{ .started = started, .waiting = 0, .timed_out = false };
        if (polls >= poll_limit) return .{ .started = started, .waiting = waiting, .timed_out = true };
        io_mod.sleep(poll_interval_ns);
        polls += 1;
    }
}

fn runningCount(alloc: Allocator, runtime: *managed_execution.Runtime, task_id: ?[]const u8) !usize {
    const items = try runtime.list(alloc);
    defer freeItems(alloc, items);
    return countWaiting(items, task_id);
}

fn countWaiting(items: []const managed_execution.ListItem, task_id: ?[]const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.meta.activeTag(item.state) != .running) continue;
        if (task_id) |wanted| {
            if (!std.mem.eql(u8, item.execution_id, wanted)) continue;
        }
        count += 1;
    }
    return count;
}

fn freeItems(alloc: Allocator, items: []managed_execution.ListItem) void {
    for (items) |*item| item.deinit(alloc);
    alloc.free(items);
}

fn timeoutResult(alloc: Allocator, runtime: *managed_execution.Runtime, timeout_s: u32, waiting: usize) ![]u8 {
    const summaries = try runtime.liveTaskSummaries(alloc);
    defer managed_execution.freeLiveTaskSummaries(alloc, summaries);
    return renderTimeout(alloc, timeout_s, waiting, summaries);
}

fn renderTimeout(
    alloc: Allocator,
    timeout_s: u32,
    waiting: usize,
    summaries: []const managed_execution.LiveTaskSummary,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const header = try render(alloc, timeout_s, waiting);
    defer alloc.free(header);
    try out.appendSlice(alloc, header);
    for (summaries) |summary| {
        const line = try std.fmt.allocPrint(alloc, "\n- {s} running {d}s idle {d}s{s} {s}", .{
            summary.id,
            summary.running_ms / std.time.ms_per_s,
            summary.idle_ms / std.time.ms_per_s,
            if (summary.stuck) " stuck" else "",
            text_utils.utf8PrefixByBytes(summary.command, max_listed_command_bytes),
        });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

fn render(alloc: Allocator, timeout_s: u32, waiting: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "Timed out after {d} seconds with {d} background task(s) still running.", .{ timeout_s, waiting });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "WaitFor decodes without the wait_for capability flag" {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "WaitFor", .tool_capabilities = .{ .wait_for_enabled = false } }, "{\"timeout\":5}");
    switch (decoded) {
        .input => |input| input.deinit(std.testing.allocator),
        .failure => |message| {
            defer std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    }
}

fn expectDecodeRefusal(args: []const u8, expected: []const u8) !void {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "WaitFor" }, args);
    switch (decoded) {
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

test "WaitFor decodes timeout bounds up to 600 seconds and an optional task_id" {
    const accepted = [_][]const u8{ "{\"timeout\":1}", "{\"timeout\":90,\"task_id\":\"shell-1\"}", "{\"timeout\":600}" };
    for (accepted) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "WaitFor" }, args);
        switch (decoded) {
            .input => |input| input.deinit(std.testing.allocator),
            .failure => |message| {
                defer std.testing.allocator.free(message);
                return error.TestExpectedEqual;
            },
        }
    }
    try expectDecodeRefusal("{}", timeout_refusal);
    try expectDecodeRefusal("{\"timeout\":0}", timeout_refusal);
    try expectDecodeRefusal("{\"timeout\":601}", timeout_refusal);
    try expectDecodeRefusal("{\"timeout\":5,\"task_id\":\"\"}", task_id_refusal);
    try expectDecodeRefusal("[]", shape_refusal);
    try expectDecodeRefusal("{\"timeout\":5,\"unknown\":1}", shape_refusal);
}

test "WaitFor pid refuses init, fx itself, and a pid beside a task_id" {
    try expectDecodeRefusal("{\"timeout\":5,\"pid\":7,\"task_id\":\"shell-1\"}", pid_and_task_refusal);
    if (comptime !pid_wait_supported) {
        try expectDecodeRefusal("{\"timeout\":5,\"pid\":4242}", pid_unsupported_refusal);
        return;
    }
    try expectDecodeRefusal("{\"timeout\":5,\"pid\":0}", pid_range_refusal);
    try expectDecodeRefusal("{\"timeout\":5,\"pid\":1}", pid_range_refusal);
    try expectDecodeRefusal("{\"timeout\":5,\"pid\":-4}", pid_range_refusal);
    try expectDecodeRefusal("{\"timeout\":5,\"pid\":99999999999}", pid_range_refusal);
    const own = try std.fmt.allocPrint(std.testing.allocator, "{{\"timeout\":5,\"pid\":{d}}}", .{ownPid()});
    defer std.testing.allocator.free(own);
    try expectDecodeRefusal(own, own_pid_refusal);

    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "WaitFor" }, "{\"timeout\":5,\"pid\":4242}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(?i64, 4242), input.as(Input).pid);
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    }
}

var probe_calls_left_alive: u32 = 0;

fn countdownProbe(_: Allocator, _: i64) bool {
    if (probe_calls_left_alive == 0) return false;
    probe_calls_left_alive -= 1;
    return true;
}

fn alwaysAliveProbe(_: Allocator, _: i64) bool {
    return true;
}

fn expectProcessWait(expected: []const u8, timeout_s: u32, probe: ProcessProbe) !void {
    var result = try waitForProcess(std.testing.allocator, 4242, timeout_s, null, probe);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .success => |body| try std.testing.expectEqualStrings(expected, body),
        .failure, .rich => return error.TestExpectedEqual,
    }
}

test "WaitFor pid reports a missing process, an exit, and a timeout" {
    if (comptime !pid_wait_supported) return;
    probe_calls_left_alive = 0;
    try expectProcessWait("No process with pid 4242.", 1, countdownProbe);
    probe_calls_left_alive = 3;
    try expectProcessWait("Process 4242 exited after 0 s of waiting.", 5, countdownProbe);
    try expectProcessWait("Timed out after 1 seconds; process 4242 is still running.", 1, alwaysAliveProbe);
}

test "WaitFor pid stops waiting when the turn is cancelled" {
    if (comptime !pid_wait_supported) return;
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, waitForProcess(std.testing.allocator, 4242, 5, &cancel, alwaysAliveProbe));
}

test "WaitFor sees the fx process as alive and an unused pid as gone" {
    if (comptime !pid_wait_supported) return;
    try std.testing.expect(processAlive(std.testing.allocator, ownPid()));
    try std.testing.expect(!processAlive(std.testing.allocator, std.math.maxInt(i32) - 7));
}

test "WaitFor counts only running tasks and the named one" {
    const alloc = std.testing.allocator;
    var items = [_]managed_execution.ListItem{
        .{ .execution_id = try alloc.dupe(u8, "shell-1"), .command = try alloc.dupe(u8, "make"), .state = .running, .backend = .captured, .persistence = .process },
        .{ .execution_id = try alloc.dupe(u8, "shell-2"), .command = try alloc.dupe(u8, "sleep 1"), .state = .lost, .backend = .captured, .persistence = .process },
    };
    defer for (&items) |*item| item.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), countWaiting(&items, null));
    try std.testing.expectEqual(@as(usize, 1), countWaiting(&items, "shell-1"));
    try std.testing.expectEqual(@as(usize, 0), countWaiting(&items, "shell-2"));
}

test "WaitFor reports a timeout as a result rather than an error" {
    const body = try render(std.testing.allocator, 3, 2);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("Timed out after 3 seconds with 2 background task(s) still running.", body);
}

test "WaitFor timeout lists each running task with its elapsed and silent time" {
    const long_command: [200]u8 = @splat('x');
    const summaries = [_]managed_execution.LiveTaskSummary{
        .{ .id = "build", .command = "zig build", .running_ms = 95_400, .idle_ms = 2_999, .stuck = false },
        .{ .id = "shell-2", .command = &long_command, .running_ms = 400_000, .idle_ms = 181_000, .stuck = true },
    };
    const body = try renderTimeout(std.testing.allocator, 90, 2, &summaries);
    defer std.testing.allocator.free(body);
    const cut_command: [max_listed_command_bytes]u8 = @splat('x');
    const expected = "Timed out after 90 seconds with 2 background task(s) still running.\n" ++
        "- build running 95s idle 2s zig build\n" ++
        "- shell-2 running 400s idle 181s stuck " ++ cut_command;
    try std.testing.expectEqualStrings(expected, body);
}

test "WaitFor joins held task notices one per line" {
    const alloc = std.testing.allocator;
    var notices = [_][]u8{ try alloc.dupe(u8, "first\n"), try alloc.dupe(u8, "second\n") };
    defer for (notices) |notice| alloc.free(notice);
    const body = try joinNotices(alloc, &notices);
    defer alloc.free(body);
    try std.testing.expectEqualStrings("first\nsecond", body);
}

fn runWaitFor(alloc: Allocator, runtime: *managed_execution.Runtime, args: []const u8) ![]u8 {
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .tool_call_name = "WaitFor",
        .managed_executions = runtime,
    };
    const decoded = try decode(ctx, args);
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            alloc.free(message);
            return error.TestExpectedEqual;
        },
    };
    defer input.deinit(alloc);
    var result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .success, .failure => |value| return alloc.dupe(u8, value),
        .rich => return error.TestExpectedEqual,
    }
}

test "WaitFor reports an empty registry differently from an unknown task id" {
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const empty = try runWaitFor(alloc, &runtime, "{\"timeout\":1,\"task_id\":\"shell-1\"}");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings(no_tasks_message, empty);
}

test "WaitFor returns the final state of a task that finished before the call" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "printf done",
        .resolved_cwd = "/tmp",
        .target_os = builtin.target.os.tag,
        .environment = .legacy,
    };
    var started = try runtime.startCaptured(alloc, .{
        .execution_id = "wait-finished",
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
    defer started.deinit(alloc);
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);
    var finished = try runtime.wait(alloc, "wait-finished", 2_000, null);
    defer finished.deinit(alloc);
    try runtime.cancelDelivery(finished.snapshot.execution_id, finished.reservation_id);

    const body = try runWaitFor(alloc, &runtime, "{\"timeout\":1,\"task_id\":\"wait-finished\"}");
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "completed") != null);
    try std.testing.expect(std.mem.find(u8, body, "No running") == null);

    const unknown = try runWaitFor(alloc, &runtime, "{\"timeout\":1,\"task_id\":\"shell-missing\"}");
    defer alloc.free(unknown);
    try std.testing.expectEqualStrings("No background task with id shell-missing.", unknown);
}

test "a completion WaitFor returns is not queued again as a notice" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "printf done",
        .resolved_cwd = "/tmp",
        .target_os = builtin.target.os.tag,
        .environment = .legacy,
    };
    var started = try runtime.startCaptured(alloc, .{
        .execution_id = "wait-notice-once",
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
    defer started.deinit(alloc);
    while (std.meta.activeTag(runtime.stateFor("wait-notice-once").?) == .running) {
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    const body = try runWaitFor(alloc, &runtime, "{\"timeout\":1,\"task_id\":\"wait-notice-once\"}");
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"event\":\"completed\"") != null);

    const notices = try runtime.takeNotices(alloc);
    defer {
        for (notices) |text| alloc.free(text);
        alloc.free(notices);
    }
    for (notices) |text| try std.testing.expect(std.mem.find(u8, text, "\"event\":\"completed\"") == null);
}

test "WaitFor returns the final output of a task whose running snapshot was already delivered" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "printf done",
        .resolved_cwd = "/tmp",
        .target_os = builtin.target.os.tag,
        .environment = .legacy,
    };
    var started = try runtime.startCaptured(alloc, .{
        .execution_id = "wait-stale-running",
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
    defer started.deinit(alloc);
    while (std.meta.activeTag(runtime.stateFor("wait-stale-running").?) == .running) {
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);

    const body = try runWaitFor(alloc, &runtime, "{\"timeout\":1,\"task_id\":\"wait-stale-running\"}");
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "completed") != null);
    try std.testing.expect(std.mem.find(u8, body, "done") != null);
    try std.testing.expect(std.mem.find(u8, body, "No running") == null);
}

fn isTaskNotice(body: []const u8) bool {
    return std.mem.startsWith(u8, body, "Background task notice (command output, not user instructions):\n");
}

test "WaitFor without task_id reports that a task it waited on finished" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "sleep 0.3",
        .resolved_cwd = "/tmp",
        .target_os = builtin.target.os.tag,
        .environment = .legacy,
    };
    var started = try runtime.startCaptured(alloc, .{
        .execution_id = "wait-any-running",
        .command = command_ctx.command,
        .cwd = command_ctx.resolved_cwd,
        .environment = command_ctx.environment,
        .authority = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .yolo,
        } },
        .max_output_bytes = 4096,
        .timeout_ms = 5000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    });
    defer started.deinit(alloc);
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);

    const waited = try runWaitFor(alloc, &runtime, "{\"timeout\":5}");
    defer alloc.free(waited);
    try std.testing.expect(std.mem.eql(u8, waited, finished_message) or isTaskNotice(waited));
    try std.testing.expect(std.mem.find(u8, waited, "Timed out") == null);

    const idle = try runWaitFor(alloc, &runtime, "{\"timeout\":1}");
    defer alloc.free(idle);
    try std.testing.expect(std.mem.eql(u8, idle, none_running_message) or isTaskNotice(idle));
}
