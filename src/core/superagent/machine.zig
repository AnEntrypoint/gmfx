const std = @import("std");

pub const State = enum { idle, turn_open, waiting_job, stopped, dead };

pub const Event = enum { prompt_sent, turn_ended, job_wait_began, job_wait_settled, stop_asked, died };

pub fn step(state: State, event: Event) ?State {
    return switch (state) {
        .idle => switch (event) {
            .prompt_sent => .turn_open,
            .turn_ended => .idle,
            .job_wait_began => .waiting_job,
            .job_wait_settled => null,
            .stop_asked => .stopped,
            .died => .dead,
        },
        .turn_open => switch (event) {
            .prompt_sent => .turn_open,
            .turn_ended => .idle,
            .job_wait_began, .job_wait_settled => null,
            .stop_asked => .stopped,
            .died => .dead,
        },
        .waiting_job => switch (event) {
            .prompt_sent, .job_wait_began => null,
            .turn_ended => .waiting_job,
            .job_wait_settled => .idle,
            .stop_asked => .stopped,
            .died => .dead,
        },
        .stopped => switch (event) {
            .stop_asked => .stopped,
            .prompt_sent, .turn_ended, .job_wait_began, .job_wait_settled, .died => null,
        },
        .dead => switch (event) {
            .stop_asked => .stopped,
            .prompt_sent, .turn_ended, .job_wait_began, .job_wait_settled, .died => null,
        },
    };
}

pub fn isLive(state: State) bool {
    return switch (state) {
        .idle, .turn_open, .waiting_job => true,
        .stopped, .dead => false,
    };
}

pub fn ownsOpenTurn(state: State) bool {
    return state == .turn_open;
}

pub const AdmissionFacts = struct {
    state: State,
    worker_running: bool,
    worker_busy: bool,
    queued: usize,
};

pub const Admission = enum { send_now, queue_behind, refuse_not_alive };

pub fn admit(facts: AdmissionFacts) Admission {
    if (!isLive(facts.state) or !facts.worker_running) return .refuse_not_alive;
    if (facts.worker_busy or facts.state == .waiting_job or facts.queued > 0) return .queue_behind;
    return .send_now;
}

pub const Activity = enum { stopped, busy, idle };

pub fn activity(facts: AdmissionFacts) Activity {
    return switch (admit(facts)) {
        .refuse_not_alive => .stopped,
        .queue_behind => .busy,
        .send_now => .idle,
    };
}

test "a root moves from idle through an open turn and a job wait, and every stop is final" {
    try std.testing.expectEqual(@as(?State, .turn_open), step(.idle, .prompt_sent));
    try std.testing.expectEqual(@as(?State, .idle), step(.turn_open, .turn_ended));
    try std.testing.expectEqual(@as(?State, .waiting_job), step(.idle, .job_wait_began));
    try std.testing.expectEqual(@as(?State, .idle), step(.waiting_job, .job_wait_settled));
    try std.testing.expectEqual(@as(?State, .turn_open), step(.turn_open, .prompt_sent));
    try std.testing.expectEqual(@as(?State, .waiting_job), step(.waiting_job, .turn_ended));
    inline for (.{ State.idle, State.turn_open, State.waiting_job, State.stopped, State.dead }) |state| {
        try std.testing.expectEqual(@as(?State, .stopped), step(state, .stop_asked));
    }
    inline for (.{ State.idle, State.turn_open, State.waiting_job }) |state| {
        try std.testing.expectEqual(@as(?State, .dead), step(state, .died));
    }
}

test "no prompt, wait or death is taken by a root that is stopped or dead, and a wait is never doubled" {
    inline for (.{ State.stopped, State.dead }) |state| {
        inline for (.{ Event.prompt_sent, Event.turn_ended, Event.job_wait_began, Event.job_wait_settled, Event.died }) |event| {
            try std.testing.expectEqual(@as(?State, null), step(state, event));
        }
    }
    try std.testing.expectEqual(@as(?State, null), step(.waiting_job, .job_wait_began));
    try std.testing.expectEqual(@as(?State, null), step(.waiting_job, .prompt_sent));
    try std.testing.expectEqual(@as(?State, null), step(.turn_open, .job_wait_began));
    try std.testing.expectEqual(@as(?State, null), step(.idle, .job_wait_settled));
}

test "every state takes every event to a state or a refusal, and only live states are live" {
    for (std.enums.values(State)) |state| {
        for (std.enums.values(Event)) |event| {
            if (step(state, event)) |next| {
                if (!isLive(state)) try std.testing.expect(!isLive(next));
            }
        }
    }
    try std.testing.expect(isLive(.idle) and isLive(.turn_open) and isLive(.waiting_job));
    try std.testing.expect(!isLive(.stopped) and !isLive(.dead));
    try std.testing.expect(ownsOpenTurn(.turn_open) and !ownsOpenTurn(.idle) and !ownsOpenTurn(.waiting_job));
}

test "a prompt is sent to a free root, queued behind running work, and refused by a root that is not alive" {
    try std.testing.expectEqual(Admission.send_now, admit(.{ .state = .idle, .worker_running = true, .worker_busy = false, .queued = 0 }));
    try std.testing.expectEqual(Admission.queue_behind, admit(.{ .state = .turn_open, .worker_running = true, .worker_busy = true, .queued = 0 }));
    try std.testing.expectEqual(Admission.queue_behind, admit(.{ .state = .waiting_job, .worker_running = true, .worker_busy = false, .queued = 0 }));
    try std.testing.expectEqual(Admission.queue_behind, admit(.{ .state = .idle, .worker_running = true, .worker_busy = false, .queued = 2 }));
    try std.testing.expectEqual(Admission.refuse_not_alive, admit(.{ .state = .stopped, .worker_running = true, .worker_busy = false, .queued = 0 }));
    try std.testing.expectEqual(Admission.refuse_not_alive, admit(.{ .state = .dead, .worker_running = false, .worker_busy = false, .queued = 3 }));
    try std.testing.expectEqual(Admission.refuse_not_alive, admit(.{ .state = .idle, .worker_running = false, .worker_busy = false, .queued = 0 }));
}

test "a root's activity follows the same facts as its admission" {
    try std.testing.expectEqual(Activity.idle, activity(.{ .state = .idle, .worker_running = true, .worker_busy = false, .queued = 0 }));
    try std.testing.expectEqual(Activity.busy, activity(.{ .state = .waiting_job, .worker_running = true, .worker_busy = false, .queued = 0 }));
    try std.testing.expectEqual(Activity.stopped, activity(.{ .state = .dead, .worker_running = true, .worker_busy = false, .queued = 0 }));
}
