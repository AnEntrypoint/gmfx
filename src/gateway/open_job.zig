const std = @import("std");

pub const State = enum(u8) { running, handed, abandoned };

pub const JobAfterOpen = enum {
    hand_over,
    close_late,
};

pub const WaitMove = enum {
    wait,
    take,
};

pub const StopMove = enum {
    walk_away,
    close_handed,
};

pub const Handoff = struct {
    state: std.atomic.Value(State) = .init(.running),

    pub fn publish(self: *Handoff) JobAfterOpen {
        return if (self.state.cmpxchgStrong(.running, .handed, .acq_rel, .acquire) == null)
            .hand_over
        else
            .close_late;
    }

    pub fn poll(self: *Handoff) WaitMove {
        return if (self.state.load(.acquire) == .handed) .take else .wait;
    }

    pub fn abandoned(self: *const Handoff) bool {
        return self.state.load(.acquire) == .abandoned;
    }

    pub fn stop(self: *Handoff) StopMove {
        return if (self.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null)
            .walk_away
        else
            .close_handed;
    }
};

test "an open that returns first is handed over, and a stop after it closes it" {
    var handoff: Handoff = .{};
    try std.testing.expectEqual(WaitMove.wait, handoff.poll());
    try std.testing.expectEqual(JobAfterOpen.hand_over, handoff.publish());
    try std.testing.expectEqual(WaitMove.take, handoff.poll());
    var stopped: Handoff = .{};
    try std.testing.expectEqual(JobAfterOpen.hand_over, stopped.publish());
    try std.testing.expectEqual(StopMove.close_handed, stopped.stop());
}

test "a request that stops first walks away, and the late open is closed by its job" {
    var handoff: Handoff = .{};
    try std.testing.expect(!handoff.abandoned());
    try std.testing.expectEqual(StopMove.walk_away, handoff.stop());
    try std.testing.expect(handoff.abandoned());
    try std.testing.expectEqual(JobAfterOpen.close_late, handoff.publish());
}

test "the job sees no walk-away once its open was handed over" {
    var handoff: Handoff = .{};
    try std.testing.expectEqual(JobAfterOpen.hand_over, handoff.publish());
    try std.testing.expectEqual(StopMove.close_handed, handoff.stop());
    try std.testing.expect(!handoff.abandoned());
}

test "racing threads leave exactly one owner of every open" {
    const Race = struct {
        handoff: Handoff = .{},
        job: JobAfterOpen = undefined,
        worker: StopMove = undefined,

        fn runJob(self: *@This()) void {
            self.job = self.handoff.publish();
        }

        fn runWorker(self: *@This()) void {
            self.worker = self.handoff.stop();
        }
    };
    var hand_overs: usize = 0;
    var walk_aways: usize = 0;
    for (0..2_000) |_| {
        var race: Race = .{};
        const job = try std.Thread.spawn(.{}, Race.runJob, .{&race});
        const worker = try std.Thread.spawn(.{}, Race.runWorker, .{&race});
        job.join();
        worker.join();

        switch (race.job) {
            .hand_over => {
                try std.testing.expectEqual(StopMove.close_handed, race.worker);
                hand_overs += 1;
            },
            .close_late => {
                try std.testing.expectEqual(StopMove.walk_away, race.worker);
                walk_aways += 1;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 2_000), hand_overs + walk_aways);
}
