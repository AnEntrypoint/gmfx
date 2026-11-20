const std = @import("std");
const command_contract = @import("command_contract.zig");

pub const max_live_entries: usize = 64;
pub const max_tombstones: usize = 32;
pub const default_yield_time_ms: u32 = 30_000;
pub const max_yield_time_ms: u32 = 3_600_000;
pub const default_wait_ceiling_ms: u32 = 5_000;
pub const max_wait_ceiling_ms: u32 = 600_000;
pub const default_stuck_after_ms: u64 = 180_000;
pub const max_task_name_bytes: usize = 64;

pub const default_print_max_turns: usize = 100_000;
pub const default_print_wait_ceiling_s: u64 = 2_147_483;

pub const PrintBackgroundMode = enum {
    exit,
    drain,
    steer,

    pub fn parse(raw: []const u8) ?PrintBackgroundMode {
        return std.meta.stringToEnum(PrintBackgroundMode, raw);
    }
};

pub fn printTurnAllowed(turns_run: usize, settings: TaskSettings) bool {
    return turns_run < settings.print_max_turns;
}

pub fn printWaitDeadlineMs(now_ms: i64, settings: TaskSettings) i64 {
    const ceiling_ms = std.math.cast(i64, settings.print_wait_ceiling_s *| std.time.ms_per_s) orelse std.math.maxInt(i64);
    return now_ms +| ceiling_ms;
}

pub const TaskSettings = struct {
    max_running_tasks: usize = max_live_entries,
    stuck_after_ms: u64 = default_stuck_after_ms,
    keep_alive_on_exit: bool = true,
    auto_background_on_timeout: bool = false,
    background_timeout_s: ?u64 = null,
    kill_grace_ms: u64 = 5_000,
    root_job_wait_ms: ?u64 = null,
    root_min_free_mb: ?u64 = null,
    print_background_mode: PrintBackgroundMode = .steer,
    print_max_turns: usize = default_print_max_turns,
    print_wait_ceiling_s: u64 = default_print_wait_ceiling_s,
    bash_output_max_chars: ?usize = null,
    background_disabled: bool = false,
};

test "print mode runs at most print_max_turns turns and waits at most print_wait_ceiling_s for background work" {
    const defaults: TaskSettings = .{};
    try std.testing.expectEqual(PrintBackgroundMode.steer, defaults.print_background_mode);
    try std.testing.expect(printTurnAllowed(99_999, defaults));
    try std.testing.expect(!printTurnAllowed(100_000, defaults));
    try std.testing.expectEqual(@as(i64, 1_000 + 2_147_483_000), printWaitDeadlineMs(1_000, defaults));
    const short: TaskSettings = .{ .print_max_turns = 1, .print_wait_ceiling_s = 2 };
    try std.testing.expect(!printTurnAllowed(1, short));
    try std.testing.expectEqual(@as(i64, 2_500), printWaitDeadlineMs(500, short));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), printWaitDeadlineMs(5, .{ .print_wait_ceiling_s = std.math.maxInt(u64) }));
    try std.testing.expectEqual(PrintBackgroundMode.drain, PrintBackgroundMode.parse("drain").?);
    try std.testing.expectEqual(@as(?PrintBackgroundMode, null), PrintBackgroundMode.parse("wait"));
}

var process_task_settings: TaskSettings = .{};
var process_task_settings_lock: std.atomic.Mutex = .unlocked;

pub fn taskSettings() TaskSettings {
    while (!process_task_settings_lock.tryLock()) std.atomic.spinLoopHint();
    defer process_task_settings_lock.unlock();
    return process_task_settings;
}

pub fn setTaskSettings(settings: TaskSettings) void {
    while (!process_task_settings_lock.tryLock()) std.atomic.spinLoopHint();
    defer process_task_settings_lock.unlock();
    process_task_settings = settings;
}

pub fn validTaskName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_task_name_bytes) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

pub fn runningTaskLimit(settings: TaskSettings) usize {
    return @max(1, @min(settings.max_running_tasks, max_live_entries));
}

pub const Backend = enum {
    captured,
    tty,
};

pub const Persistence = enum {
    process,
    session,
};

pub const TerminalState = enum {
    completed,
    stopped,
    lost,
};

pub const State = union(enum) {
    starting,
    running,
    stopping,
    completed: command_contract.CommandStatus,
    stopped: ?command_contract.CommandStatus,
    lost,

    pub fn isTerminal(self: State) bool {
        return switch (self) {
            .completed, .stopped, .lost => true,
            .starting, .running, .stopping => false,
        };
    }
};

pub const Event = union(enum) {
    child_started,
    stop_requested,
    process_terminated: command_contract.CommandStatus,
    output_drained,
    backend_lost,
};

pub const CompletionBarrier = struct {
    status: ?command_contract.CommandStatus = null,
    output_drained: bool = false,

    pub fn observe(self: CompletionBarrier, event: Event) CompletionBarrier {
        var next = self;
        switch (event) {
            .process_terminated => |status| next.status = status,
            .output_drained => next.output_drained = true,
            .child_started, .stop_requested, .backend_lost => {},
        }
        return next;
    }

    pub fn completedStatus(self: CompletionBarrier) ?command_contract.CommandStatus {
        if (!self.output_drained) return null;
        return self.status;
    }
};

pub const Transition = struct {
    state: State,
    barrier: CompletionBarrier,
};

pub fn transition(
    state: State,
    barrier: CompletionBarrier,
    event: Event,
) Transition {
    if (state.isTerminal()) return .{ .state = state, .barrier = barrier };

    const next_barrier = barrier.observe(event);
    if (next_barrier.completedStatus()) |status| {
        return .{
            .state = switch (state) {
                .stopping => .{ .stopped = status },
                .starting, .running => .{ .completed = status },
                .completed, .stopped, .lost => unreachable,
            },
            .barrier = next_barrier,
        };
    }

    return .{
        .state = switch (event) {
            .child_started => switch (state) {
                .starting => .running,
                .running, .stopping => state,
                .completed, .stopped, .lost => unreachable,
            },
            .stop_requested => switch (state) {
                .starting, .running => .stopping,
                .stopping => .stopping,
                .completed, .stopped, .lost => unreachable,
            },
            .backend_lost => .lost,
            .process_terminated, .output_drained => state,
        },
        .barrier = next_barrier,
    };
}

pub const Admission = enum {
    admit,
    capacity_exhausted,
};

pub fn decideAdmission(live_count: usize) Admission {
    return if (live_count < max_live_entries) .admit else .capacity_exhausted;
}

pub fn decideRunningAdmission(running_count: usize, settings: TaskSettings) Admission {
    return if (running_count < runningTaskLimit(settings)) .admit else .capacity_exhausted;
}

pub const StuckChange = enum {
    unchanged,
    became_stuck,
    resumed,
};

pub fn stuckChange(was_stuck: bool, idle_ms: u64, stuck_after_ms: u64) StuckChange {
    const idle = stuck_after_ms != 0 and idle_ms >= stuck_after_ms;
    if (idle and !was_stuck) return .became_stuck;
    if (!idle and was_stuck) return .resumed;
    return .unchanged;
}

pub const Presentation = enum {
    observe_initially,
    return_running,
};

pub fn initialPresentation(yield_time_ms: u32) Presentation {
    return if (yield_time_ms == 0) .return_running else .observe_initially;
}

pub const CancellationPoint = enum {
    before_spawn,
    after_spawn_before_publication,
    published_wait,
};

pub const CancellationDecision = enum {
    no_process_effect,
    stop_and_join_unpublished,
    detach_waiter,
};

pub fn cancellationDecision(point: CancellationPoint) CancellationDecision {
    return switch (point) {
        .before_spawn => .no_process_effect,
        .after_spawn_before_publication => .stop_and_join_unpublished,
        .published_wait => .detach_waiter,
    };
}

pub const OutputRange = struct {
    start: u64,
    end: u64,
};

pub const Reservation = struct {
    waiter_id: u64,
    range: OutputRange,
};

pub const DeliveryState = struct {
    committed: u64 = 0,
    reservation: ?Reservation = null,

    pub fn prepare(
        self: DeliveryState,
        waiter_id: u64,
        observed_end: u64,
    ) error{ ExecutionBusy, InvalidOutputRange }!DeliveryState {
        if (self.reservation != null) return error.ExecutionBusy;
        if (observed_end < self.committed) return error.InvalidOutputRange;
        var next = self;
        next.reservation = .{
            .waiter_id = waiter_id,
            .range = .{ .start = self.committed, .end = observed_end },
        };
        return next;
    }

    pub fn commit(
        self: DeliveryState,
        waiter_id: u64,
    ) error{UnknownReservation}!DeliveryState {
        const reservation = self.reservation orelse return error.UnknownReservation;
        if (reservation.waiter_id != waiter_id) return error.UnknownReservation;
        return .{ .committed = reservation.range.end };
    }

    pub fn cancel(
        self: DeliveryState,
        waiter_id: u64,
    ) error{UnknownReservation}!DeliveryState {
        const reservation = self.reservation orelse return error.UnknownReservation;
        if (reservation.waiter_id != waiter_id) return error.UnknownReservation;
        return .{ .committed = self.committed };
    }
};

pub const Tombstone = struct {
    terminal_state: TerminalState,
    status: ?command_contract.CommandStatus,
    delivered_output_end: u64,
};

pub fn toTombstone(
    state: State,
    delivery: DeliveryState,
) error{ NotTerminal, DeliveryPending }!Tombstone {
    if (delivery.reservation != null) return error.DeliveryPending;
    return switch (state) {
        .completed => |status| .{
            .terminal_state = .completed,
            .status = status,
            .delivered_output_end = delivery.committed,
        },
        .stopped => |status| .{
            .terminal_state = .stopped,
            .status = status,
            .delivered_output_end = delivery.committed,
        },
        .lost => .{
            .terminal_state = .lost,
            .status = null,
            .delivered_output_end = delivery.committed,
        },
        .starting, .running, .stopping => error.NotTerminal,
    };
}

test "completion requires process status and output drain in either order" {
    const status = command_contract.CommandStatus{ .exit_code = 0 };
    var first = transition(.running, .{}, .{ .process_terminated = status });
    try std.testing.expect(!first.state.isTerminal());
    first = transition(first.state, first.barrier, .output_drained);
    try std.testing.expect(first.state.isTerminal());

    var second = transition(.running, .{}, .output_drained);
    try std.testing.expect(!second.state.isTerminal());
    second = transition(second.state, second.barrier, .{ .process_terminated = status });
    try std.testing.expect(second.state.isTerminal());
}

test "stop is idempotent and terminal states absorb later effects" {
    var current = transition(.running, .{}, .stop_requested);
    try std.testing.expectEqual(State.stopping, current.state);
    current = transition(current.state, current.barrier, .stop_requested);
    try std.testing.expectEqual(State.stopping, current.state);
    current = transition(
        current.state,
        current.barrier,
        .{ .process_terminated = .{ .signal = 15 } },
    );
    try std.testing.expect(!current.state.isTerminal());
    current = transition(current.state, current.barrier, .output_drained);
    try std.testing.expect(current.state.isTerminal());
    const absorbed = transition(current.state, current.barrier, .backend_lost);
    try std.testing.expectEqual(current.state, absorbed.state);
}

test "capacity and zero yield decisions happen before effects" {
    try std.testing.expectEqual(@as(usize, 64), max_live_entries);
    try std.testing.expectEqual(Admission.admit, decideAdmission(max_live_entries - 1));
    try std.testing.expectEqual(Admission.capacity_exhausted, decideAdmission(max_live_entries));
    try std.testing.expectEqual(Presentation.return_running, initialPresentation(0));
    try std.testing.expectEqual(Presentation.observe_initially, initialPresentation(1));
}

test "task names are short and made of letters, digits, underscore and dash" {
    try std.testing.expect(validTaskName("build-1"));
    try std.testing.expect(validTaskName("A_b-9"));
    try std.testing.expect(!validTaskName(""));
    try std.testing.expect(!validTaskName("has space"));
    try std.testing.expect(!validTaskName("dot.name"));
    const long: [max_task_name_bytes + 1]u8 = @splat('a');
    try std.testing.expect(validTaskName(long[0..max_task_name_bytes]));
    try std.testing.expect(!validTaskName(&long));
}

test "the running task limit is the setting, kept between one and the live entry cap" {
    try std.testing.expectEqual(max_live_entries, runningTaskLimit(.{}));
    try std.testing.expectEqual(@as(usize, 3), runningTaskLimit(.{ .max_running_tasks = 3 }));
    try std.testing.expectEqual(@as(usize, 1), runningTaskLimit(.{ .max_running_tasks = 0 }));
    try std.testing.expectEqual(max_live_entries, runningTaskLimit(.{ .max_running_tasks = 10_000 }));
    try std.testing.expectEqual(Admission.admit, decideRunningAdmission(2, .{ .max_running_tasks = 3 }));
    try std.testing.expectEqual(Admission.capacity_exhausted, decideRunningAdmission(3, .{ .max_running_tasks = 3 }));
}

test "a task becomes stuck once at the threshold and resumes once when output grows" {
    try std.testing.expectEqual(StuckChange.unchanged, stuckChange(false, 179_999, 180_000));
    try std.testing.expectEqual(StuckChange.became_stuck, stuckChange(false, 180_000, 180_000));
    try std.testing.expectEqual(StuckChange.unchanged, stuckChange(true, 500_000, 180_000));
    try std.testing.expectEqual(StuckChange.resumed, stuckChange(true, 10, 180_000));
    try std.testing.expectEqual(StuckChange.unchanged, stuckChange(false, 500_000, 0));
}

test "process task settings are replaced as a whole" {
    const before = taskSettings();
    defer setTaskSettings(before);
    setTaskSettings(.{ .max_running_tasks = 2, .stuck_after_ms = 1_500 });
    try std.testing.expectEqual(@as(usize, 2), taskSettings().max_running_tasks);
    try std.testing.expectEqual(@as(u64, 1_500), taskSettings().stuck_after_ms);
}

test "managed execution defaults preserve ordinary and interactive observation windows" {
    try std.testing.expectEqual(@as(u32, 30_000), default_yield_time_ms);
    try std.testing.expectEqual(@as(u32, 5_000), default_wait_ceiling_ms);
}

test "delivery reservation prevents duplicate output and cancellation does not commit" {
    const initial = DeliveryState{ .committed = 3 };
    const reserved = try initial.prepare(11, 9);
    try std.testing.expectError(error.ExecutionBusy, reserved.prepare(12, 9));
    const cancelled = try reserved.cancel(11);
    try std.testing.expectEqual(@as(u64, 3), cancelled.committed);
    const replayed = try cancelled.prepare(12, 9);
    try std.testing.expectEqual(OutputRange{ .start = 3, .end = 9 }, replayed.reservation.?.range);
    const committed = try replayed.commit(12);
    try std.testing.expectEqual(@as(u64, 9), committed.committed);
}

test "cancellation distinguishes unpublished work from observation" {
    try std.testing.expectEqual(
        CancellationDecision.no_process_effect,
        cancellationDecision(.before_spawn),
    );
    try std.testing.expectEqual(
        CancellationDecision.stop_and_join_unpublished,
        cancellationDecision(.after_spawn_before_publication),
    );
    try std.testing.expectEqual(
        CancellationDecision.detach_waiter,
        cancellationDecision(.published_wait),
    );
}

test "tombstones contain terminal facts without authority" {
    const tombstone = try toTombstone(
        .{ .completed = .{ .exit_code = 0 } },
        .{ .committed = 17 },
    );
    try std.testing.expectEqual(TerminalState.completed, tombstone.terminal_state);
    try std.testing.expectEqual(@as(u64, 17), tombstone.delivered_output_end);
    try std.testing.expectError(
        error.DeliveryPending,
        toTombstone(
            .{ .completed = .{ .exit_code = 0 } },
            .{ .reservation = .{
                .waiter_id = 1,
                .range = .{ .start = 0, .end = 1 },
            } },
        ),
    );
}
