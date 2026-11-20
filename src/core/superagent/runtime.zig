const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Status = enum { ready, busy, idle, stopped, failed, blocked };

pub const TurnEnd = enum { failed, interrupted, paused, blocked };

pub const Request = struct {
    agent: []const u8,
    prompt: []const u8,
    cwd: []const u8,
    session: ?[]const u8 = null,
    queue: []const []const u8 = &.{},
};

pub const Result = struct {
    agent: []const u8,
    cwd: []const u8,
    prompt_id: []const u8,
    session: []const u8,
    text: []const u8,
    status: []const u8,
};

pub const Snapshot = struct {
    agent: []const u8,
    cwd: []const u8,
    status: Status,
    busy: bool,
    alive: bool,
    prompt_id: []const u8,
    session: []const u8,
};

pub const Journal = struct {
    text: []const u8,
    total: usize,
    offset: usize,
};

pub const StartFn = *const fn (?*anyopaque, Allocator, Request) anyerror!void;
pub const PromptFn = *const fn (?*anyopaque, Allocator, Request) anyerror!Result;
pub const StatusFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!Snapshot;
pub const ListFn = *const fn (?*anyopaque, Allocator) anyerror![]Snapshot;
pub const StopFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!void;
pub const ProjectsFn = *const fn (?*anyopaque, Allocator) anyerror![][]const u8;
pub const JournalFn = *const fn (?*anyopaque, Allocator, []const u8, usize, usize) anyerror!Journal;
pub const TurnFinishedFn = *const fn (?*anyopaque, *anyopaque, []const u8) void;
pub const TurnEndedFn = *const fn (?*anyopaque, *anyopaque, TurnEnd, []const u8) void;
pub const DrainFn = *const fn (?*anyopaque) void;
pub const CloseFn = *const fn (?*anyopaque, HostExit) void;

pub const HostExit = enum { asked, cut };

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    start: ?StartFn = null,
    prompt: ?PromptFn = null,
    status: ?StatusFn = null,
    list: ?ListFn = null,
    stop: ?StopFn = null,
    projects: ?ProjectsFn = null,
    journal: ?JournalFn = null,
    turn_finished: ?TurnFinishedFn = null,
    turn_ended: ?TurnEndedFn = null,
    drain: ?DrainFn = null,
    close: ?CloseFn = null,
};

var callbacks: Callbacks = .{};
var lock: std.Io.Mutex = .init;
var host_cut: std.atomic.Value(bool) = .init(false);

pub fn noteHostCut() void {
    host_cut.store(true, .release);
}

pub fn bind(value: Callbacks) void {
    lock.lockUncancelable(@import("../shared/io.zig").getIo());
    defer lock.unlock(@import("../shared/io.zig").getIo());
    callbacks = value;
}

pub fn unbind() void {
    const bound = snapshot();
    if (bound.close) |close| close(bound.context, if (host_cut.load(.acquire)) .cut else .asked);
    bind(.{});
}

pub fn listProjects(alloc: Allocator) ![][]const u8 {
    const fn_value = snapshot().projects orelse return fallbackProjects(alloc);
    return fn_value(snapshot().context, alloc);
}

pub fn start(alloc: Allocator, request: Request) !void {
    const fn_value = snapshot().start orelse return error.SuperagentUnavailable;
    return fn_value(snapshot().context, alloc, request);
}

pub fn instruct(alloc: Allocator, request: Request) !Result {
    const fn_value = snapshot().prompt orelse return error.SuperagentUnavailable;
    return fn_value(snapshot().context, alloc, request);
}

pub fn status(alloc: Allocator, agent: []const u8) !Snapshot {
    const fn_value = snapshot().status orelse return error.SuperagentUnavailable;
    return fn_value(snapshot().context, alloc, agent);
}

pub fn statuses(alloc: Allocator) ![]Snapshot {
    const fn_value = snapshot().list orelse return alloc.alloc(Snapshot, 0);
    return fn_value(snapshot().context, alloc);
}

pub fn stop(alloc: Allocator, agent: []const u8) !void {
    const fn_value = snapshot().stop orelse return error.SuperagentUnavailable;
    return fn_value(snapshot().context, alloc, agent);
}

pub fn journal(alloc: Allocator, agent: []const u8, offset: usize, limit: usize) !Journal {
    const fn_value = snapshot().journal orelse return error.SuperagentUnavailable;
    return fn_value(snapshot().context, alloc, agent, offset, limit);
}

pub fn noteTurnFinished(agent: *anyopaque, final_response: []const u8) void {
    const fn_value = snapshot().turn_finished orelse return;
    fn_value(snapshot().context, agent, final_response);
}

pub fn noteTurnEnded(agent: *anyopaque, end: TurnEnd, text: []const u8) void {
    const fn_value = snapshot().turn_ended orelse return;
    fn_value(snapshot().context, agent, end, text);
}

pub fn drainTurnEvents() void {
    const fn_value = snapshot().drain orelse return;
    fn_value(snapshot().context);
}

pub fn hostLine(alloc: Allocator, configured_min_free_mb: ?u64) ![]u8 {
    const host_checks = @import("host_checks.zig");
    return host_checks.renderHostLine(alloc, host_checks.minFreeMb(configured_min_free_mb));
}

pub const ReportState = enum { finished, open, blocked, none };

pub const Report = struct {
    state: ReportState = .none,
    line: []const u8 = "",
};

const report_marker = "REPORT:";

pub fn reportOf(final_response: []const u8) Report {
    var lines = std.mem.splitBackwardsScalar(u8, final_response, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r*`_");
        if (!std.ascii.startsWithIgnoreCase(line, report_marker)) continue;
        const rest = std.mem.trimStart(u8, line[report_marker.len..], " \t*`_");
        inline for (.{ ReportState.finished, ReportState.open, ReportState.blocked }) |state| {
            if (std.ascii.startsWithIgnoreCase(rest, @tagName(state))) return .{ .state = state, .line = line };
        }
        return .{ .line = line };
    }
    return .{};
}

pub fn jobPidIn(text: []const u8) ?i32 {
    var index: usize = 0;
    while (index + 3 <= text.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(text[index .. index + 3], "pid")) continue;
        if (index > 0 and std.ascii.isAlphanumeric(text[index - 1])) continue;
        var at = index + 3;
        while (at < text.len and (text[at] == ' ' or text[at] == '=' or text[at] == ':')) at += 1;
        const digits_from = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == digits_from) continue;
        const pid = std.fmt.parseInt(i32, text[digits_from..at], 10) catch continue;
        if (pid > 1) return pid;
    }
    return null;
}

pub const max_open_steps: u32 = 3;
pub const max_blocked_steps: u32 = 1;
pub const default_job_wait_ms: u64 = 30 * std.time.ms_per_min;

pub const Facts = struct {
    report: ReportState,
    queued: usize,
    running_jobs: usize = 0,
    finished_job_notes: usize = 0,
    waited_already: bool = false,
    open_steps: u32 = 0,
    blocked_steps: u32 = 0,
};

pub const Decision = enum {
    send_queued_item,
    wait_for_job,
    send_job_result,
    send_next_step,
    stop_root,
    leave_idle,
    hand_to_owner,
};

pub fn decide(facts: Facts) Decision {
    if (facts.running_jobs > 0 and !facts.waited_already) return .wait_for_job;
    if (facts.finished_job_notes > 0 or (facts.running_jobs > 0 and facts.waited_already)) return .send_job_result;
    return switch (facts.report) {
        .finished => if (facts.queued > 0) .send_queued_item else .stop_root,
        .none => if (facts.queued > 0) .send_queued_item else .leave_idle,
        .open => if (facts.open_steps < max_open_steps) .send_next_step else .hand_to_owner,
        .blocked => if (facts.blocked_steps < max_blocked_steps) .send_next_step else .hand_to_owner,
    };
}

pub fn jobWaitMs(configured: ?u64) u64 {
    return configured orelse default_job_wait_ms;
}

pub const Death = enum { instance_closed, worker_ended };

pub fn deathPhrase(death: Death) []const u8 {
    return switch (death) {
        .instance_closed => "its instance was closed",
        .worker_ended => "its worker ended",
    };
}

pub const DeathFacts = struct {
    turn_open: bool,
    queued: usize,
    waiting_on_job: bool,
    revived_already: bool,
};

pub const DeathDecision = enum { revive_and_send_again, revive_and_send_queued, stay_stopped };

pub fn decideDeath(facts: DeathFacts) DeathDecision {
    if (facts.revived_already) return .stay_stopped;
    if (facts.turn_open or facts.waiting_on_job) return .revive_and_send_again;
    if (facts.queued > 0) return .revive_and_send_queued;
    return .stay_stopped;
}

pub fn wakesOwner(decision: Decision) bool {
    return switch (decision) {
        .stop_root, .leave_idle, .hand_to_owner => true,
        .send_queued_item, .wait_for_job, .send_job_result, .send_next_step => false,
    };
}

pub fn nextStepPrompt(alloc: Allocator, report: Report) ![]u8 {
    return switch (report.state) {
        .blocked => std.fmt.allocPrint(
            alloc,
            "Your last turn ended blocked:\n{s}\n\nIf the blocker is a choice that can be undone, make it now, write down what you chose and why, and carry on with the work on this session. " ++
                "If it needs the owner (a credential, a payment, or an action that cannot be undone or reaches outside this machine), end again with REPORT: blocked and name exactly what the owner must do.",
            .{report.line},
        ),
        else => std.fmt.allocPrint(
            alloc,
            "Your last turn ended open:\n{s}\n\nCarry on with the open items on this session, in order. Decide any choice that can be undone yourself and write it down. " ++
                "End with REPORT: finished, open or blocked, the one-line result and the witness.",
            .{report.line},
        ),
    };
}

pub fn jobResultPrompt(alloc: Allocator, result: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "The job your last turn left running has this result:\n{s}\n\nCarry on from it on this session and end with REPORT: finished, open or blocked, the one-line result and the witness.",
        .{result},
    );
}

pub const PidWait = enum { exited, still_running, not_found, unsupported };

pub fn waitForPid(pid: i32, timeout_ms: u64) PidWait {
    const builtin = @import("builtin");
    if (comptime builtin.target.os.tag != .linux) return .unsupported;
    const linux = std.os.linux;
    const opened = linux.pidfd_open(pid, 0);
    if (linux.errno(opened) != .SUCCESS) return .not_found;
    const fd: std.posix.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const bounded: i32 = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i32))));
    const ready = std.posix.poll(&fds, bounded) catch return .still_running;
    return if (ready > 0) .exited else .still_running;
}

pub fn pidWaitPhrase(outcome: PidWait) []const u8 {
    return switch (outcome) {
        .exited => "has exited",
        .still_running => "was still running when the wait timed out",
        .not_found => "is not running any more",
        .unsupported => "could not be waited on by this platform",
    };
}

fn snapshot() Callbacks {
    lock.lockUncancelable(@import("../shared/io.zig").getIo());
    defer lock.unlock(@import("../shared/io.zig").getIo());
    return callbacks;
}

fn fallbackProjects(alloc: Allocator) ![][]const u8 {
    return alloc.alloc([]const u8, 0);
}

pub fn freeResult(alloc: Allocator, result: Result) void {
    alloc.free(result.agent);
    alloc.free(result.cwd);
    alloc.free(result.prompt_id);
    alloc.free(result.session);
    alloc.free(result.text);
    alloc.free(result.status);
}

pub fn freeSnapshot(alloc: Allocator, item: Snapshot) void {
    alloc.free(item.agent);
    alloc.free(item.cwd);
    alloc.free(item.prompt_id);
    alloc.free(item.session);
}

pub fn freeJournal(alloc: Allocator, value: Journal) void {
    alloc.free(value.text);
}

pub fn freeStatuses(alloc: Allocator, items: []Snapshot) void {
    for (items) |item| freeSnapshot(alloc, item);
    alloc.free(items);
}

pub fn freeProjects(alloc: Allocator, items: [][]const u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

test "a report line is read from the end of a reply, whatever decorates it" {
    try std.testing.expectEqual(ReportState.finished, reportOf("did it\nREPORT: finished — all rows pass — witness: 12 pass").state);
    try std.testing.expectEqual(ReportState.open, reportOf("**REPORT: open** — two rows left\n").state);
    try std.testing.expectEqual(ReportState.blocked, reportOf("text\n`report: BLOCKED — needs a key`\n\n").state);
    try std.testing.expectEqual(ReportState.none, reportOf("just a reply with no report").state);
    try std.testing.expectEqual(ReportState.none, reportOf("REPORT: done").state);
    try std.testing.expectEqual(ReportState.open, reportOf("REPORT: finished\nlater\nREPORT: open — more").state);
    try std.testing.expectEqualStrings("REPORT: open — more", reportOf("REPORT: finished\nlater\nREPORT: open — more").line);
}

test "a job's process id is read from a report line and nothing else counts as one" {
    try std.testing.expectEqual(@as(?i32, 4242), jobPidIn("REPORT: open — validation still running, PID 4242"));
    try std.testing.expectEqual(@as(?i32, 77), jobPidIn("job pid=77 runs"));
    try std.testing.expectEqual(@as(?i32, 9001), jobPidIn("wait on pid: 9001"));
    try std.testing.expectEqual(@as(?i32, null), jobPidIn("the rapid 55 fox"));
    try std.testing.expectEqual(@as(?i32, null), jobPidIn("pid 1"));
    try std.testing.expectEqual(@as(?i32, null), jobPidIn("no process named"));
}

test "a turn end is decided from the report, the queue and the root's jobs" {
    try std.testing.expectEqual(Decision.send_queued_item, decide(.{ .report = .finished, .queued = 2 }));
    try std.testing.expectEqual(Decision.stop_root, decide(.{ .report = .finished, .queued = 0 }));
    try std.testing.expectEqual(Decision.send_queued_item, decide(.{ .report = .none, .queued = 1 }));
    try std.testing.expectEqual(Decision.leave_idle, decide(.{ .report = .none, .queued = 0 }));
    try std.testing.expectEqual(Decision.wait_for_job, decide(.{ .report = .finished, .queued = 3, .running_jobs = 1 }));
    try std.testing.expectEqual(Decision.send_job_result, decide(.{ .report = .open, .queued = 0, .running_jobs = 1, .waited_already = true }));
    try std.testing.expectEqual(Decision.send_job_result, decide(.{ .report = .finished, .queued = 1, .finished_job_notes = 1 }));
    try std.testing.expectEqual(Decision.send_next_step, decide(.{ .report = .open, .queued = 0 }));
    try std.testing.expectEqual(Decision.send_next_step, decide(.{ .report = .open, .queued = 4, .open_steps = max_open_steps - 1 }));
    try std.testing.expectEqual(Decision.hand_to_owner, decide(.{ .report = .open, .queued = 0, .open_steps = max_open_steps }));
    try std.testing.expectEqual(Decision.send_next_step, decide(.{ .report = .blocked, .queued = 0 }));
    try std.testing.expectEqual(Decision.hand_to_owner, decide(.{ .report = .blocked, .queued = 0, .blocked_steps = max_blocked_steps }));
}

test "the job wait keeps its default of thirty minutes unless a time is set" {
    try std.testing.expectEqual(@as(u64, 30 * 60 * 1000), jobWaitMs(null));
    try std.testing.expectEqual(@as(u64, 90_000), jobWaitMs(90_000));
}

test "a root that died with work is brought back once, and one that had none or died again stays stopped" {
    try std.testing.expectEqual(DeathDecision.revive_and_send_again, decideDeath(.{ .turn_open = true, .queued = 2, .waiting_on_job = false, .revived_already = false }));
    try std.testing.expectEqual(DeathDecision.revive_and_send_again, decideDeath(.{ .turn_open = false, .queued = 0, .waiting_on_job = true, .revived_already = false }));
    try std.testing.expectEqual(DeathDecision.revive_and_send_queued, decideDeath(.{ .turn_open = false, .queued = 1, .waiting_on_job = false, .revived_already = false }));
    try std.testing.expectEqual(DeathDecision.stay_stopped, decideDeath(.{ .turn_open = false, .queued = 0, .waiting_on_job = false, .revived_already = false }));
    try std.testing.expectEqual(DeathDecision.stay_stopped, decideDeath(.{ .turn_open = true, .queued = 3, .waiting_on_job = false, .revived_already = true }));
}

test "only a decision that ends the runtime's own work wakes the owner's model" {
    try std.testing.expect(wakesOwner(.stop_root));
    try std.testing.expect(wakesOwner(.leave_idle));
    try std.testing.expect(wakesOwner(.hand_to_owner));
    try std.testing.expect(!wakesOwner(.send_queued_item));
    try std.testing.expect(!wakesOwner(.wait_for_job));
    try std.testing.expect(!wakesOwner(.send_job_result));
    try std.testing.expect(!wakesOwner(.send_next_step));
}

test "the next step names the report it answers and the job result is carried whole" {
    const alloc = std.testing.allocator;
    const open = try nextStepPrompt(alloc, reportOf("REPORT: open — two rows left"));
    defer alloc.free(open);
    try std.testing.expect(std.mem.find(u8, open, "REPORT: open — two rows left") != null);
    try std.testing.expect(std.mem.find(u8, open, "Carry on with the open items") != null);
    const blocked = try nextStepPrompt(alloc, reportOf("REPORT: blocked — port taken"));
    defer alloc.free(blocked);
    try std.testing.expect(std.mem.find(u8, blocked, "can be undone, make it now") != null);
    const job = try jobResultPrompt(alloc, "task t1 exited 0");
    defer alloc.free(job);
    try std.testing.expect(std.mem.find(u8, job, "task t1 exited 0") != null);
}

test "one wait on a process id returns when it exits and times out while it runs" {
    const builtin = @import("builtin");
    if (comptime builtin.target.os.tag != .linux) return;
    const own: i32 = @intCast(std.c.getpid());
    try std.testing.expectEqual(PidWait.still_running, waitForPid(own, 20));
    try std.testing.expectEqual(PidWait.not_found, waitForPid(std.math.maxInt(i32) - 7, 20));
}

test "unbound superagent reports unavailable for root actions" {
    unbind();
    try std.testing.expectError(error.SuperagentUnavailable, start(std.testing.allocator, .{
        .agent = "peer",
        .prompt = "",
        .cwd = "",
    }));
    try std.testing.expectError(error.SuperagentUnavailable, instruct(std.testing.allocator, .{
        .agent = "peer",
        .prompt = "hello",
        .cwd = "",
    }));
}

test "bound callbacks dispatch without spawning a process" {
    const Fixture = struct {
        var started: usize = 0;
        var prompted: usize = 0;

        fn start(_: ?*anyopaque, _: Allocator, _: Request) anyerror!void {
            started += 1;
        }

        fn prompt(_: ?*anyopaque, alloc: Allocator, request: Request) anyerror!Result {
            prompted += 1;
            return .{
                .agent = try alloc.dupe(u8, request.agent),
                .cwd = try alloc.dupe(u8, request.cwd),
                .prompt_id = try alloc.dupe(u8, "p1"),
                .session = try alloc.dupe(u8, ""),
                .text = try alloc.dupe(u8, "peer result"),
                .status = try alloc.dupe(u8, "turn_end"),
            };
        }
    };
    bind(.{ .start = Fixture.start, .prompt = Fixture.prompt });
    defer unbind();
    try start(std.testing.allocator, .{ .agent = "peer", .prompt = "", .cwd = "/work/peer" });
    const result = try instruct(std.testing.allocator, .{ .agent = "peer", .prompt = "hello", .cwd = "/work/peer" });
    defer freeResult(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 1), Fixture.started);
    try std.testing.expectEqual(@as(usize, 1), Fixture.prompted);
    try std.testing.expectEqualStrings("peer result", result.text);
}

test "statuses and list_projects are empty until an interactive app binds roots" {
    unbind();
    const alloc = std.testing.allocator;
    const projects = try listProjects(alloc);
    defer freeProjects(alloc, projects);
    try std.testing.expectEqual(@as(usize, 0), projects.len);
    const items = try statuses(alloc);
    defer freeStatuses(alloc, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "turn-finished and journal callbacks dispatch through the bound host" {
    const Fixture = struct {
        var finished: usize = 0;
        var last_final_len: usize = 0;
        var last_offset: usize = 0;
        var last_limit: usize = 0;

        fn turnFinished(_: ?*anyopaque, _: *anyopaque, final_response: []const u8) void {
            finished += 1;
            last_final_len = final_response.len;
        }

        fn journal(_: ?*anyopaque, alloc: Allocator, agent: []const u8, offset: usize, limit: usize) anyerror!Journal {
            last_offset = offset;
            last_limit = limit;
            return .{
                .text = try alloc.dupe(u8, agent),
                .total = agent.len,
                .offset = offset,
            };
        }
    };
    bind(.{ .turn_finished = Fixture.turnFinished, .journal = Fixture.journal });
    defer unbind();
    var agent_marker: u8 = 0;
    noteTurnFinished(&agent_marker, "peer-pong");
    try std.testing.expectEqual(@as(usize, 1), Fixture.finished);
    try std.testing.expectEqual(@as(usize, "peer-pong".len), Fixture.last_final_len);
    const slice = try journal(std.testing.allocator, "peer", 2, 8);
    defer freeJournal(std.testing.allocator, slice);
    try std.testing.expectEqual(@as(usize, 2), Fixture.last_offset);
    try std.testing.expectEqual(@as(usize, 8), Fixture.last_limit);
    try std.testing.expectEqualStrings("peer", slice.text);
}

test {
    _ = @import("roots_ledger.zig");
    _ = @import("machine.zig");
    _ = @import("host_checks.zig");
}
