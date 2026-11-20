const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_result_display = @import("../tooling/tool_result_display.zig");

const Allocator = std.mem.Allocator;

pub const max_name_len: usize = 64;
pub const max_args_len: usize = 1200;
pub const max_result_len: usize = 2000;
pub const ring_capacity: usize = 64;

pub const ToolCallOutcome = enum(u8) {
    succeeded,
    rejected,
    command_failed,
    tool_failed,
    runtime_failed,
};

pub const ToolCallMetric = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: ToolCallOutcome = .succeeded,
    subagent_id: u64 = 0,
    name_buf: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    args_buf: [max_args_len]u8 = @splat(0),
    args_len: u16 = 0,
    args_total_bytes: u32 = 0,
    result_buf: [max_result_len]u8 = @splat(0),
    result_len: u16 = 0,
    result_total_bytes: u32 = 0,

    pub fn name(self: *const ToolCallMetric) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn args(self: *const ToolCallMetric) []const u8 {
        return self.args_buf[0..self.args_len];
    }

    pub fn result(self: *const ToolCallMetric) []const u8 {
        return self.result_buf[0..self.result_len];
    }

    pub fn setName(self: *ToolCallMetric, value: []const u8) void {
        const n = @min(value.len, max_name_len);
        @memcpy(self.name_buf[0..n], value[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn setArgs(self: *ToolCallMetric, value: []const u8) void {
        self.args_total_bytes = @intCast(@min(value.len, std.math.maxInt(u32)));
        const n = @min(value.len, max_args_len);
        @memcpy(self.args_buf[0..n], value[0..n]);
        self.args_len = @intCast(n);
    }

    pub fn setResult(self: *ToolCallMetric, value: []const u8) void {
        const normalized = tool_result_display.contentForDisplay(value);
        self.result_total_bytes = @intCast(@min(normalized.len, std.math.maxInt(u32)));
        const n = @min(normalized.len, max_result_len);
        @memcpy(self.result_buf[0..n], normalized[0..n]);
        self.result_len = @intCast(n);
    }

    pub fn setPayloadsForName(self: *ToolCallMetric, tool_name: []const u8, arguments_json: []const u8, model_output: []const u8) void {
        if (omitsPayloadsForName(tool_name)) {
            self.clearPayloads();
            return;
        }
        self.setArgs(arguments_json);
        self.setResult(model_output);
    }

    fn clearPayloads(self: *ToolCallMetric) void {
        @memset(&self.args_buf, 0);
        self.args_len = 0;
        self.args_total_bytes = 0;
        @memset(&self.result_buf, 0);
        self.result_len = 0;
        self.result_total_bytes = 0;
    }
};

pub const ToolCallRecord = struct {
    name: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
    outcome: ToolCallOutcome,
    started_at_ms: i64,
    subagent_id: u64 = 0,
    duration_ms: ?u64 = null,
    exit_code: ?i32 = null,
};

pub const max_command_key_len: usize = 120;
pub const max_tracked_commands: usize = 128;
pub const zero_wait_poll_ms: u64 = 1000;

pub const RepeatedCommand = struct {
    command: []const u8,
    count: u32,
    total_ms: u64,
    last_ms: u64,
    last_exit: ?i32,
};

pub const LongestCall = struct {
    tool_name: []const u8,
    label: []const u8,
    duration_ms: u64,
};

pub const CallNote = struct {
    name: []const u8,
    arguments_json: []const u8,
    duration_ms: u64,
    exit_code: ?i32 = null,
    ran: bool = true,
};

const CommandStat = struct {
    key_buf: [max_command_key_len]u8 = undefined,
    key_len: u8 = 0,
    count: u32 = 0,
    total_ms: u64 = 0,
    last_ms: u64 = 0,
    last_exit: ?i32 = null,
    last_seen: u64 = 0,

    fn key(self: *const CommandStat) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

const PollTool = enum { none, task_output, task_list };

fn pollTool(name: []const u8) PollTool {
    if (std.mem.eql(u8, name, "TaskOutput")) return .task_output;
    if (std.mem.eql(u8, name, "TaskList")) return .task_list;
    return .none;
}

pub fn normalizeCommand(out: *[max_command_key_len]u8, command: []const u8) []const u8 {
    var len: usize = 0;
    var pending_space = false;
    for (command) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = len != 0;
            continue;
        }
        if (pending_space) {
            if (len == max_command_key_len) break;
            out[len] = ' ';
            len += 1;
            pending_space = false;
        }
        if (len == max_command_key_len) break;
        out[len] = byte;
        len += 1;
    }
    while (len != 0 and len == max_command_key_len and out[len - 1] & 0xC0 == 0x80) len -= 1;
    if (len != 0 and len < max_command_key_len and out[len - 1] >= 0xC0 and commandCutMidCharacter(command, out[0..len])) len -= 1;
    return out[0..len];
}

fn commandCutMidCharacter(command: []const u8, kept: []const u8) bool {
    return kept.len != 0 and std.unicode.utf8ByteSequenceLength(kept[kept.len - 1]) catch 1 > 1 and
        !std.unicode.utf8ValidateSlice(kept) and command.len > kept.len;
}

const BashArguments = struct {
    command: ?[]const u8 = null,
    action: ?[]const u8 = null,
};

fn isCommandTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Bash") or std.mem.eql(u8, name, "shell");
}

pub fn commandKey(out: *[max_command_key_len]u8, name: []const u8, arguments_json: []const u8) ?[]const u8 {
    if (!isCommandTool(name)) return null;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arguments = std.json.parseFromSliceLeaky(BashArguments, arena_state.allocator(), arguments_json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (arguments.action) |action| {
        if (!std.mem.eql(u8, action, "run")) return null;
    }
    const command = arguments.command orelse return null;
    const key = normalizeCommand(out, command);
    return if (key.len == 0) null else key;
}

pub const Metrics = struct {
    lock: std.Io.Mutex = .init,
    commands: [max_tracked_commands]CommandStat = undefined,
    command_count: usize = 0,
    sequence: u64 = 0,
    longest_name_buf: [max_name_len]u8 = undefined,
    longest_name_len: u8 = 0,
    longest_label_buf: [max_command_key_len]u8 = undefined,
    longest_label_len: u8 = 0,
    longest_ms: u64 = 0,
    has_longest: bool = false,
    last_poll: PollTool = .none,
    zero_wait_polls: u32 = 0,

    fn locked(self: *const Metrics) *Metrics {
        const mutable: *Metrics = @constCast(self);
        mutable.lock.lockUncancelable(io_mod.getIo());
        return mutable;
    }

    fn unlock(self: *Metrics) void {
        self.lock.unlock(io_mod.getIo());
    }

    pub fn note(self: *Metrics, call: CallNote) void {
        var key_buf: [max_command_key_len]u8 = undefined;
        const key = if (call.ran) commandKey(&key_buf, call.name, call.arguments_json) else null;
        var label_buf: [max_command_key_len]u8 = undefined;
        const label = key orelse normalizeCommand(&label_buf, call.arguments_json);

        const state = self.locked();
        defer state.unlock();
        state.sequence += 1;
        if (key) |command| state.noteCommandLocked(command, call.duration_ms, call.exit_code);
        if (call.ran and (!state.has_longest or call.duration_ms > state.longest_ms)) {
            state.has_longest = true;
            state.longest_ms = call.duration_ms;
            const name_len = @min(call.name.len, max_name_len);
            @memcpy(state.longest_name_buf[0..name_len], call.name[0..name_len]);
            state.longest_name_len = @intCast(name_len);
            @memcpy(state.longest_label_buf[0..label.len], label);
            state.longest_label_len = @intCast(label.len);
        }
        const poll = pollTool(call.name);
        if (poll != .none and call.duration_ms < zero_wait_poll_ms) {
            if (state.last_poll == poll) state.zero_wait_polls +|= 1;
            state.last_poll = poll;
        } else {
            state.last_poll = .none;
        }
    }

    fn noteCommandLocked(self: *Metrics, key: []const u8, duration_ms: u64, exit_code: ?i32) void {
        const stat = self.findCommandLocked(key) orelse self.claimCommandLocked(key);
        stat.count +|= 1;
        stat.total_ms +|= duration_ms;
        stat.last_ms = duration_ms;
        stat.last_exit = exit_code;
        stat.last_seen = self.sequence;
    }

    fn findCommandLocked(self: *Metrics, key: []const u8) ?*CommandStat {
        for (self.commands[0..self.command_count]) |*stat| {
            if (std.mem.eql(u8, stat.key(), key)) return stat;
        }
        return null;
    }

    fn claimCommandLocked(self: *Metrics, key: []const u8) *CommandStat {
        const slot = if (self.command_count < max_tracked_commands) blk: {
            self.command_count += 1;
            break :blk &self.commands[self.command_count - 1];
        } else self.leastUsefulCommandLocked();
        slot.* = .{};
        @memcpy(slot.key_buf[0..key.len], key);
        slot.key_len = @intCast(key.len);
        return slot;
    }

    fn leastUsefulCommandLocked(self: *Metrics) *CommandStat {
        var chosen = &self.commands[0];
        for (self.commands[1..self.command_count]) |*stat| {
            const fewer_runs = stat.count < chosen.count;
            const same_runs_older = stat.count == chosen.count and stat.last_seen < chosen.last_seen;
            if (fewer_runs or same_runs_older) chosen = stat;
        }
        return chosen;
    }

    pub fn beginTurn(self: *Metrics) void {
        const state = self.locked();
        defer state.unlock();
        state.has_longest = false;
        state.longest_ms = 0;
        state.longest_name_len = 0;
        state.longest_label_len = 0;
    }

    pub fn clear(self: *Metrics) void {
        const state = self.locked();
        defer state.unlock();
        state.command_count = 0;
        state.sequence = 0;
        state.has_longest = false;
        state.longest_ms = 0;
        state.longest_name_len = 0;
        state.longest_label_len = 0;
        state.last_poll = .none;
        state.zero_wait_polls = 0;
    }

    pub fn repeatedCommands(self: *const Metrics, alloc: Allocator, max_rows: usize) ![]RepeatedCommand {
        var picked: [max_tracked_commands]CommandStat = undefined;
        var picked_len: usize = 0;
        {
            const state = self.locked();
            defer state.unlock();
            for (state.commands[0..state.command_count]) |stat| {
                if (stat.count < 2) continue;
                picked[picked_len] = stat;
                picked_len += 1;
            }
        }
        std.mem.sort(CommandStat, picked[0..picked_len], {}, struct {
            fn moreTotalFirst(_: void, left: CommandStat, right: CommandStat) bool {
                if (left.total_ms != right.total_ms) return left.total_ms > right.total_ms;
                if (left.count != right.count) return left.count > right.count;
                return std.mem.order(u8, left.key(), right.key()) == .lt;
            }
        }.moreTotalFirst);
        const shown = @min(picked_len, max_rows);
        const rows = try alloc.alloc(RepeatedCommand, shown);
        var filled: usize = 0;
        errdefer {
            for (rows[0..filled]) |row| alloc.free(row.command);
            alloc.free(rows);
        }
        for (picked[0..shown]) |*stat| {
            rows[filled] = .{
                .command = try alloc.dupe(u8, stat.key()),
                .count = stat.count,
                .total_ms = stat.total_ms,
                .last_ms = stat.last_ms,
                .last_exit = stat.last_exit,
            };
            filled += 1;
        }
        return rows;
    }

    pub fn longestCall(self: *const Metrics) ?LongestCall {
        const state = self.locked();
        defer state.unlock();
        if (!state.has_longest) return null;
        return .{
            .tool_name = self.longest_name_buf[0..state.longest_name_len],
            .label = self.longest_label_buf[0..state.longest_label_len],
            .duration_ms = state.longest_ms,
        };
    }

    pub fn zeroWaitPolls(self: *const Metrics) u32 {
        const state = self.locked();
        defer state.unlock();
        return state.zero_wait_polls;
    }
};

pub fn freeRepeatedCommands(alloc: Allocator, rows: []RepeatedCommand) void {
    for (rows) |row| alloc.free(row.command);
    alloc.free(rows);
}

var session_metrics: Metrics = .{};

pub fn sessionMetrics() *Metrics {
    return &session_metrics;
}

pub fn beginTurn() void {
    session_metrics.beginTurn();
}

pub fn wallMsSince(started_at_ms: i64) u64 {
    const now_ms = io_mod.milliTimestamp();
    return if (now_ms > started_at_ms) @intCast(now_ms - started_at_ms) else 0;
}

const CommandResultExit = struct {
    exit_code: ?i64 = null,
};

pub fn exitCodeFromCommandResultJson(command_result_json: ?[]const u8) ?i32 {
    const encoded = command_result_json orelse return null;
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var arena_state = std.heap.ArenaAllocator.init(if (encoded.len < buffer.len / 4) fixed.allocator() else std.heap.page_allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(CommandResultExit, arena_state.allocator(), encoded, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const code = parsed.exit_code orelse return null;
    return std.math.cast(i32, code);
}

pub fn omitsPayloadsForName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "FetchURL");
}

var mutex: std.Io.Mutex = .init;

var ring: [ring_capacity]ToolCallMetric = std.mem.zeroes([ring_capacity]ToolCallMetric);
var head: usize = 0;
var stored: usize = 0;

pub const LifetimeStats = struct {
    total_calls: u64 = 0,
    outcome_counts: [@typeInfo(ToolCallOutcome).@"enum".field_names.len]u64 = @splat(0),
    total_duration_ms: u64 = 0,

    pub fn countFor(self: *const LifetimeStats, outcome: ToolCallOutcome) u64 {
        return self.outcome_counts[@backingInt(outcome)];
    }
};

var lifetime: LifetimeStats = .{};

pub fn record(call: ToolCallMetric) void {
    var stored_call = call;
    if (omitsPayloadsForName(stored_call.name())) stored_call.clearPayloads();

    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = stored_call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;

    lifetime.total_calls += 1;
    lifetime.outcome_counts[@backingInt(stored_call.outcome)] += 1;
    lifetime.total_duration_ms += stored_call.duration_ms;
}

pub fn lifetimeStats() LifetimeStats {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return lifetime;
}

pub fn recordResult(input: ToolCallRecord) void {
    const elapsed: u64 = input.duration_ms orelse wallMsSince(input.started_at_ms);
    session_metrics.note(.{
        .name = input.name,
        .arguments_json = input.arguments_json,
        .duration_ms = elapsed,
        .exit_code = input.exit_code,
        .ran = input.outcome != .rejected,
    });
    var metric: ToolCallMetric = .{
        .started_at_ms = input.started_at_ms,
        .duration_ms = @intCast(@min(elapsed, std.math.maxInt(u32))),
        .outcome = input.outcome,
        .subagent_id = input.subagent_id,
    };
    metric.setName(input.name);
    metric.setPayloadsForName(input.name, input.arguments_json, input.model_output);
    record(metric);
}

pub fn snapshot(out: []ToolCallMetric) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (head + ring_capacity - n + i) % ring_capacity;
        out[i] = ring[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    lifetime = .{};
    session_metrics.clear();
}

pub fn resetForTest() void {
    reset();
}

test "tool call ring keeps last N records in chronological order" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 3) : (i += 1) {
        var call: ToolCallMetric = .{ .duration_ms = i };
        call.setName("read_file");
        call.setArgs("{}");
        call.setResult("ok");
        record(call);
    }

    var buf: [ring_capacity]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(ring_capacity, n);
    try std.testing.expectEqual(@as(u32, 3), buf[0].duration_ms);
    try std.testing.expectEqual(@as(u32, ring_capacity + 3 - 1), buf[ring_capacity - 1].duration_ms);
}

test "args and result are truncated and total length tracked" {
    resetForTest();
    defer resetForTest();

    const huge_len: usize = @as(usize, @max(max_args_len, max_result_len)) + 200;
    var huge: [huge_len]u8 = undefined;
    @memset(&huge, 'a');
    var call: ToolCallMetric = .{};
    call.setName("read_file");
    call.setArgs(&huge);
    call.setResult(&huge);
    record(call);

    var buf: [1]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, max_args_len), buf[0].args_len);
    try std.testing.expectEqual(@as(u32, huge_len), buf[0].args_total_bytes);
    try std.testing.expectEqual(@as(u16, max_result_len), buf[0].result_len);
    try std.testing.expectEqual(@as(u32, huge_len), buf[0].result_total_bytes);
}

test "lifetime stats count every outcome and survive ring eviction" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 3) : (i += 1) {
        var call: ToolCallMetric = .{
            .duration_ms = 5,
            .started_at_ms = 10_000 + @as(i64, i) * 100,
            .outcome = if (i % 4 == 0) .rejected else .succeeded,
        };
        call.setName("Bash");
        record(call);
    }

    const stats = lifetimeStats();
    const total = ring_capacity + 3;
    try std.testing.expectEqual(@as(u64, total), stats.total_calls);
    try std.testing.expectEqual(@as(u64, total), stats.countFor(.succeeded) + stats.countFor(.rejected));
    try std.testing.expect(stats.countFor(.rejected) > 0);
    try std.testing.expectEqual(@as(u64, total * 5), stats.total_duration_ms);

    var buf: [ring_capacity]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expect(stats.total_calls > n);

    resetForTest();
    try std.testing.expectEqual(@as(u64, 0), lifetimeStats().total_calls);
}

test "tool call outcome labels remain exact" {
    const cases = [_]struct {
        outcome: ToolCallOutcome,
        label: []const u8,
        success: bool,
    }{
        .{ .outcome = .succeeded, .label = "succeeded", .success = true },
        .{ .outcome = .rejected, .label = "rejected", .success = false },
        .{ .outcome = .command_failed, .label = "command_failed", .success = false },
        .{ .outcome = .tool_failed, .label = "tool_failed", .success = false },
        .{ .outcome = .runtime_failed, .label = "runtime_failed", .success = false },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.label, @tagName(case.outcome));
        try std.testing.expectEqual(case.success, case.outcome == .succeeded);
    }
    try std.testing.expectEqual(@as(u8, 0), @backingInt(ToolCallOutcome.succeeded));
}

test "a command key collapses whitespace runs, trims, and stops at 120 bytes" {
    var buf: [max_command_key_len]u8 = undefined;
    try std.testing.expectEqualStrings("zig build test", normalizeCommand(&buf, "  zig \t build\n\n  test  "));
    try std.testing.expectEqualStrings("", normalizeCommand(&buf, " \n\t "));
    const long: [300]u8 = @splat('x');
    try std.testing.expectEqual(max_command_key_len, normalizeCommand(&buf, &long).len);
    var spaced: [200]u8 = undefined;
    for (&spaced, 0..) |*byte, index| byte.* = if (index % 2 == 0) 'a' else ' ';
    const cut = normalizeCommand(&buf, &spaced);
    try std.testing.expectEqual(max_command_key_len, cut.len);
    try std.testing.expect(std.mem.startsWith(u8, cut, "a a a"));
}

test "only a Bash command or a shell run action has a command key" {
    var buf: [max_command_key_len]u8 = undefined;
    try std.testing.expectEqualStrings("make  check"[0..4] ++ " check", commandKey(&buf, "Bash", "{\"command\":\"make   check\",\"timeout\":5}").?);
    try std.testing.expectEqualStrings("ls", commandKey(&buf, "shell", "{\"action\":\"run\",\"command\":\"ls\"}").?);
    try std.testing.expect(commandKey(&buf, "shell", "{\"action\":\"stop\",\"session_id\":\"shell-1\"}") == null);
    try std.testing.expect(commandKey(&buf, "read_file", "{\"command\":\"ls\"}") == null);
    try std.testing.expect(commandKey(&buf, "Bash", "not json") == null);
    try std.testing.expect(commandKey(&buf, "Bash", "{\"command\":\"   \"}") == null);
}

test "repeated commands list only commands run twice or more, most total time first" {
    var metrics: Metrics = .{};
    const runs = [_]struct { command: []const u8, ms: u64, exit: ?i32 }{
        .{ .command = "{\"command\":\"zig build\"}", .ms = 400, .exit = 0 },
        .{ .command = "{\"command\":\"zig  build\"}", .ms = 600, .exit = 1 },
        .{ .command = "{\"command\":\"bun test\"}", .ms = 5000, .exit = 0 },
        .{ .command = "{\"command\":\"git status\"}", .ms = 10, .exit = 0 },
        .{ .command = "{\"command\":\"git status\"}", .ms = 20, .exit = 0 },
        .{ .command = "{\"command\":\"git status\"}", .ms = 30, .exit = null },
    };
    for (runs) |run| metrics.note(.{ .name = "Bash", .arguments_json = run.command, .duration_ms = run.ms, .exit_code = run.exit });
    metrics.note(.{ .name = "Bash", .arguments_json = "{\"command\":\"zig build\"}", .duration_ms = 9000, .ran = false });

    const rows = try metrics.repeatedCommands(std.testing.allocator, 8);
    defer freeRepeatedCommands(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("zig build", rows[0].command);
    try std.testing.expectEqual(@as(u32, 2), rows[0].count);
    try std.testing.expectEqual(@as(u64, 1000), rows[0].total_ms);
    try std.testing.expectEqual(@as(u64, 600), rows[0].last_ms);
    try std.testing.expectEqual(@as(?i32, 1), rows[0].last_exit);
    try std.testing.expectEqualStrings("git status", rows[1].command);
    try std.testing.expectEqual(@as(u32, 3), rows[1].count);
    try std.testing.expectEqual(@as(?i32, null), rows[1].last_exit);

    const capped = try metrics.repeatedCommands(std.testing.allocator, 1);
    defer freeRepeatedCommands(std.testing.allocator, capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqualStrings("zig build", capped[0].command);
}

test "a full command table gives its slot to the least repeated oldest command" {
    var metrics: Metrics = .{};
    metrics.note(.{ .name = "Bash", .arguments_json = "{\"command\":\"kept\"}", .duration_ms = 1 });
    metrics.note(.{ .name = "Bash", .arguments_json = "{\"command\":\"kept\"}", .duration_ms = 1 });
    var index: usize = 0;
    while (index < max_tracked_commands + 5) : (index += 1) {
        var args_buf: [64]u8 = undefined;
        const args = try std.fmt.bufPrint(&args_buf, "{{\"command\":\"once-{d}\"}}", .{index});
        metrics.note(.{ .name = "Bash", .arguments_json = args, .duration_ms = 1 });
    }
    const rows = try metrics.repeatedCommands(std.testing.allocator, 8);
    defer freeRepeatedCommands(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("kept", rows[0].command);
}

test "the longest call belongs to the current turn and is forgotten at the next" {
    var metrics: Metrics = .{};
    try std.testing.expect(metrics.longestCall() == null);
    metrics.note(.{ .name = "read_file", .arguments_json = "{\"path\":\"a.zig\"}", .duration_ms = 40 });
    metrics.note(.{ .name = "Bash", .arguments_json = "{\"command\":\"zig   build test\"}", .duration_ms = 9000, .exit_code = 0 });
    metrics.note(.{ .name = "grep_files", .arguments_json = "{}", .duration_ms = 12 });
    const longest = metrics.longestCall().?;
    try std.testing.expectEqualStrings("Bash", longest.tool_name);
    try std.testing.expectEqualStrings("zig build test", longest.label);
    try std.testing.expectEqual(@as(u64, 9000), longest.duration_ms);

    metrics.beginTurn();
    try std.testing.expect(metrics.longestCall() == null);
    metrics.note(.{ .name = "read_file", .arguments_json = "{\"path\":\"a.zig\"}", .duration_ms = 3 });
    try std.testing.expectEqualStrings("read_file", metrics.longestCall().?.tool_name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", metrics.longestCall().?.label);
    const rows = try metrics.repeatedCommands(std.testing.allocator, 8);
    defer freeRepeatedCommands(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "zero wait polls count back to back quick TaskOutput or TaskList calls" {
    var metrics: Metrics = .{};
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 0), metrics.zeroWaitPolls());
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{}", .duration_ms = 5 });
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 2), metrics.zeroWaitPolls());
    metrics.note(.{ .name = "TaskList", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 2), metrics.zeroWaitPolls());
    metrics.note(.{ .name = "TaskList", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 3), metrics.zeroWaitPolls());
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{\"wait\":30}", .duration_ms = 30_000 });
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 3), metrics.zeroWaitPolls());
    metrics.note(.{ .name = "read_file", .arguments_json = "{}", .duration_ms = 5 });
    metrics.note(.{ .name = "TaskOutput", .arguments_json = "{}", .duration_ms = 5 });
    try std.testing.expectEqual(@as(u32, 3), metrics.zeroWaitPolls());
}

test "a recorded Bash result feeds the session metrics with its wall time and exit code" {
    resetForTest();
    defer resetForTest();
    for ([_]u64{ 250, 750 }) |ms| recordResult(.{
        .name = "Bash",
        .arguments_json = "{\"command\":\"make check\"}",
        .model_output = "ok",
        .outcome = .command_failed,
        .started_at_ms = 1000,
        .duration_ms = ms,
        .exit_code = exitCodeFromCommandResultJson("{\"command\":\"make check\",\"exit_code\":2}"),
    });
    recordResult(.{
        .name = "Bash",
        .arguments_json = "{\"command\":\"make check\"}",
        .model_output = "denied",
        .outcome = .rejected,
        .started_at_ms = 1000,
        .duration_ms = 0,
    });
    const rows = try sessionMetrics().repeatedCommands(std.testing.allocator, 8);
    defer freeRepeatedCommands(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(u32, 2), rows[0].count);
    try std.testing.expectEqual(@as(u64, 1000), rows[0].total_ms);
    try std.testing.expectEqual(@as(?i32, 2), rows[0].last_exit);

    var buf: [4]ToolCallMetric = undefined;
    try std.testing.expectEqual(@as(usize, 3), snapshot(&buf));
    try std.testing.expectEqual(@as(u32, 750), buf[1].duration_ms);

    resetForTest();
    const cleared = try sessionMetrics().repeatedCommands(std.testing.allocator, 8);
    defer freeRepeatedCommands(std.testing.allocator, cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}

test "the exit code is read from a command result and absent otherwise" {
    try std.testing.expectEqual(@as(?i32, 0), exitCodeFromCommandResultJson("{\"exit_code\":0,\"signal\":null}"));
    try std.testing.expectEqual(@as(?i32, null), exitCodeFromCommandResultJson("{\"signal\":9}"));
    try std.testing.expectEqual(@as(?i32, null), exitCodeFromCommandResultJson(null));
    try std.testing.expectEqual(@as(?i32, null), exitCodeFromCommandResultJson("nope"));
}
