const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const owner_guard = @import("../shared/owner_guard.zig");
const external = @import("external.zig");

const Allocator = std.mem.Allocator;

pub const output_capture_limit: usize = 256 * 1024;
const kill_grace_ms: i64 = 100;
const poll_interval_ns: u64 = 10 * std.time.ns_per_ms;

pub const Outcome = struct {
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    cancelled: bool = false,

    pub fn execution(self: *const Outcome) external.Execution {
        return .{
            .exit_code = self.exit_code,
            .timed_out = self.timed_out,
            .stdout = self.stdout.items,
            .stderr = self.stderr.items,
        };
    }

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        self.stdout.deinit(alloc);
        self.stderr.deinit(alloc);
        self.* = .{};
    }
};

pub fn run(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    env: []const external.EnvVar,
    timeout_seconds: u32,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) Allocator.Error!Outcome {
    return runWithin(alloc, command, cwd, env, @as(u64, timeout_seconds) * std.time.ms_per_s, payload, cancel_flag);
}

pub fn runWithin(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    env: []const external.EnvVar,
    deadline_ms: u64,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) Allocator.Error!Outcome {
    const timeout_ms: i64 = std.math.cast(i64, deadline_ms) orelse std.math.maxInt(i64);
    var outcome: Outcome = .{};
    if (cancelRequested(cancel_flag)) {
        outcome.cancelled = true;
        return outcome;
    }

    var child = spawnHook(alloc, command, cwd, env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return outcome,
    };
    const guarded_group: ?std.posix.pid_t = if (comptime owner_guard.guards_process_groups) child.id else null;
    if (guarded_group) |group| owner_guard.watch(group);
    defer if (guarded_group) |group| owner_guard.release(group);

    if (comptime builtin.target.os.tag == .wasi) {
        return runUnwatched(alloc, &child, timeout_ms, payload, outcome);
    } else {
        return runWatched(alloc, &child, timeout_ms, payload, cancel_flag, outcome);
    }
}

fn spawnHook(alloc: Allocator, command: []const u8, cwd: []const u8, env: []const external.EnvVar) !std.process.Child {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    if (env.len == 0) return spawnWith(&argv, cwd, null);
    var environment = try io_mod.cloneEnvironMap(alloc);
    defer environment.deinit();
    for (env) |variable| try environment.put(variable.name, variable.value);
    return spawnWith(&argv, cwd, &environment);
}

fn spawnWith(argv: []const []const u8, cwd: []const u8, environment: ?*const std.process.Environ.Map) !std.process.Child {
    return std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
        .pgid = if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) 0 else null,
    });
}

fn runUnwatched(alloc: Allocator, child: *std.process.Child, timeout_ms: i64, payload: []const u8, outcome: Outcome) Allocator.Error!Outcome {
    var result = outcome;
    errdefer result.deinit(alloc);
    const deadline_ms = io_mod.milliTimestamp() +| timeout_ms;
    writePayload(child, payload);
    var timed_out = false;
    drain(alloc, child, &result, deadline_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HookDeadlineExceeded => timed_out = true,
        else => {},
    };
    var term: ?std.process.Child.Term = null;
    if (timed_out) {
        child.kill(io_mod.getIo());
    } else {
        term = child.wait(io_mod.getIo()) catch null;
    }
    result.timed_out = timed_out;
    recordExit(&result, term);
    return result;
}

fn runWatched(
    alloc: Allocator,
    child: *std.process.Child,
    timeout_ms: i64,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    outcome: Outcome,
) Allocator.Error!Outcome {
    var result = outcome;
    errdefer result.deinit(alloc);
    const pid = child.id orelse {
        child.kill(io_mod.getIo());
        return result;
    };
    ignoreBrokenPipe();

    var watchdog = Watchdog{
        .pid = pid,
        .timeout_ms = timeout_ms,
        .cancel_flag = cancel_flag,
        .done = std.atomic.Value(bool).init(false),
        .fired = std.atomic.Value(bool).init(false),
        .cancelled = std.atomic.Value(bool).init(false),
    };
    const thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch {
        child.kill(io_mod.getIo());
        return result;
    };

    writePayload(child, payload);
    const drained = drain(alloc, child, &result, null);
    const term = child.wait(io_mod.getIo()) catch null;
    watchdog.done.store(true, .release);
    thread.join();

    result.timed_out = watchdog.fired.load(.acquire);
    result.cancelled = watchdog.cancelled.load(.acquire);
    recordExit(&result, term);
    drained catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    return result;
}

fn writePayload(child: *std.process.Child, payload: []const u8) void {
    if (child.stdin) |input| {
        input.writeStreamingAll(io_mod.getIo(), payload) catch {};
        input.close(io_mod.getIo());
        child.stdin = null;
    }
}

fn recordExit(outcome: *Outcome, term: ?std.process.Child.Term) void {
    if (term) |value| switch (value) {
        .exited => |code| outcome.exit_code = code,
        else => {},
    };
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

const Watchdog = struct {
    pid: std.posix.pid_t,
    timeout_ms: i64,
    cancel_flag: ?*std.atomic.Value(bool),
    done: std.atomic.Value(bool),
    fired: std.atomic.Value(bool),
    cancelled: std.atomic.Value(bool),

    fn run(self: *Watchdog) void {
        const deadline = io_mod.milliTimestamp() +| self.timeout_ms;
        while (!self.done.load(.acquire) and !cancelRequested(self.cancel_flag) and io_mod.milliTimestamp() < deadline) {
            io_mod.sleep(poll_interval_ns);
        }
        if (self.done.load(.acquire)) return;

        if (cancelRequested(self.cancel_flag)) {
            self.cancelled.store(true, .release);
        } else {
            self.fired.store(true, .release);
        }
        std.posix.kill(-self.pid, std.posix.SIG.TERM) catch {};
        var waited_ms: i64 = 0;
        while (waited_ms < kill_grace_ms and !self.done.load(.acquire)) {
            io_mod.sleep(poll_interval_ns);
            waited_ms += 10;
        }
        if (self.done.load(.acquire)) return;
        std.posix.kill(-self.pid, std.posix.SIG.KILL) catch {};
    }
};

fn ignoreBrokenPipe() void {
    const ignore_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore_action, null);
}

fn drain(alloc: Allocator, child: *std.process.Child, outcome: *Outcome, deadline_ms: ?i64) !void {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io_mod.getIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (true) {
        if (deadline_ms) |limit| {
            if (io_mod.milliTimestamp() >= limit) return error.HookDeadlineExceeded;
        }
        const keep_reading = if (multi_reader.fill(4096, .none))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            else => |e| return e,
        };

        try appendCapped(alloc, &outcome.stdout, stdout_reader);
        try appendCapped(alloc, &outcome.stderr, stderr_reader);

        if (!keep_reading) break;
    }

    try multi_reader.checkAnyError();
}

fn appendCapped(alloc: Allocator, capture: *std.ArrayList(u8), reader: *std.Io.Reader) !void {
    const buffered = reader.buffered();
    if (buffered.len == 0) return;

    if (capture.items.len < output_capture_limit) {
        const remaining = output_capture_limit - capture.items.len;
        try capture.appendSlice(alloc, buffered[0..@min(remaining, buffered.len)]);
    }

    reader.tossBuffered();
}

test "external hook runner feeds the payload on stdin and reports stdout and exit code" {
    var outcome = try run(std.testing.allocator, "cat; exit 2", "/tmp", &.{}, 5, "{\"hook_event_name\":\"Stop\"}", null);
    defer outcome.deinit(std.testing.allocator);
    const execution = outcome.execution();
    try std.testing.expectEqual(@as(?u8, 2), execution.exit_code);
    try std.testing.expect(!execution.timed_out);
    try std.testing.expectEqualStrings("{\"hook_event_name\":\"Stop\"}", execution.stdout);
    try std.testing.expectEqualStrings("", execution.stderr);
}

test "external hook runner captures stderr separately from stdout" {
    var outcome = try run(std.testing.allocator, "printf out; printf err >&2; exit 0", "/tmp", &.{}, 5, "", null);
    defer outcome.deinit(std.testing.allocator);
    const execution = outcome.execution();
    try std.testing.expectEqual(@as(?u8, 0), execution.exit_code);
    try std.testing.expectEqualStrings("out", execution.stdout);
    try std.testing.expectEqualStrings("err", execution.stderr);
}

test "external hook runner times out a hung hook and fails open" {
    var outcome = try run(std.testing.allocator, "sleep 30", "/tmp", &.{}, 1, "", null);
    defer outcome.deinit(std.testing.allocator);
    const verdict_input = outcome.execution();
    try std.testing.expect(verdict_input.timed_out);
    var verdict = try external.decide(std.testing.allocator, .PreToolUse, verdict_input);
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(!verdict.blocked);
}

test "external hook runner skips the hook when the turn is already cancelled" {
    var cancel = std.atomic.Value(bool).init(true);
    var outcome = try run(std.testing.allocator, "printf out", "/tmp", &.{}, 5, "", &cancel);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.cancelled);
    try std.testing.expect(!outcome.timed_out);
    try std.testing.expectEqualStrings("", outcome.stdout.items);
}

test "external hook runner kills a hung hook when the turn is cancelled" {
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    var cancel = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&cancel});
    defer thread.join();
    const started_ms = io_mod.milliTimestamp();
    var outcome = try run(std.testing.allocator, "sleep 30", "/tmp", &.{}, 30, "", &cancel);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.cancelled);
    try std.testing.expect(!outcome.timed_out);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "external hook runner adds the definition env on top of the inherited environment" {
    const env = [_]external.EnvVar{
        .{ .name = "FX_PLUGIN_ROOT", .value = "/plugins/demo" },
        .{ .name = "FX_HOME", .value = "/home/example/.fx" },
    };
    var outcome = try run(std.testing.allocator, "printf '%s|%s|' \"$FX_PLUGIN_ROOT\" \"$FX_HOME\"; test -n \"$PATH\"", "/tmp", &env, 5, "", null);
    defer outcome.deinit(std.testing.allocator);
    const execution = outcome.execution();
    try std.testing.expectEqual(@as(?u8, 0), execution.exit_code);
    try std.testing.expectEqualStrings("/plugins/demo|/home/example/.fx|", execution.stdout);
}

test "external hook runner kills the whole process group of a hook past its deadline" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const started_ms = io_mod.milliTimestamp();
    var outcome = try run(std.testing.allocator, "sleep 30 & sleep 30 & wait", "/tmp", &.{}, 1, "", null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.timed_out);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 10_000);
}

test "external hook runner unwatched branch feeds the payload and reports the exit code" {
    if (comptime builtin.target.os.tag == .wasi) return;
    var child = try spawnHook(std.testing.allocator, "cat; exit 2", "/tmp", &.{});
    var result = try runUnwatched(std.testing.allocator, &child, 5_000, "{\"hook_event_name\":\"Stop\"}", .{});
    defer result.deinit(std.testing.allocator);
    const execution = result.execution();
    try std.testing.expectEqual(@as(?u8, 2), execution.exit_code);
    try std.testing.expect(!execution.timed_out);
    try std.testing.expectEqualStrings("{\"hook_event_name\":\"Stop\"}", execution.stdout);
}

test "external hook runner unwatched branch reports a hook past its deadline as timed out and fails open" {
    if (comptime builtin.target.os.tag == .wasi) return;
    var child = try spawnHook(std.testing.allocator, "while :; do echo tick; sleep 0.1; done", "/tmp", &.{});
    const started_ms = io_mod.milliTimestamp();
    var result = try runUnwatched(std.testing.allocator, &child, 1_000, "", .{});
    defer result.deinit(std.testing.allocator);
    const execution = result.execution();
    try std.testing.expect(execution.timed_out);
    try std.testing.expectEqual(@as(?u8, null), execution.exit_code);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 10_000);
    var verdict = try external.decide(std.testing.allocator, .PreToolUse, execution);
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(!verdict.blocked);
}

test "external hook runner bounds a hook by a deadline shorter than a second" {
    if (comptime builtin.target.os.tag == .wasi) return;
    const started_ms = io_mod.milliTimestamp();
    var outcome = try runWithin(std.testing.allocator, "sleep 30", "/tmp", &.{}, external.session_end_budget_ms, "", null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.timed_out);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 5_000);
}
