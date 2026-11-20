const std = @import("std");
const tw = @import("transcript_window.zig");

const max_steps = 96;
const max_seq = max_steps + 1;

const FuzzDraws = struct {
    smith: *std.testing.Smith,

    fn below(self: FuzzDraws, n: usize, site: u32) usize {
        return self.smith.indexWithHash(n, site);
    }
};

const SeededDraws = struct {
    random: std.Random,

    fn below(self: SeededDraws, n: usize, _: u32) usize {
        return self.random.uintLessThan(usize, n);
    }
};

const World = struct {
    log_saved: tw.Seq = 0,
    cycle_starts: [max_seq]tw.Seq = undefined,
    starts: usize = 0,
    painted: std.StaticBitSet(max_seq) = .empty,

    fn addStart(self: *World, start: tw.Seq) void {
        for (self.cycle_starts[0..self.starts]) |known| if (known == start) return;
        self.cycle_starts[self.starts] = start;
        self.starts += 1;
    }

    fn lastStart(self: *World, saved: tw.Seq) tw.Seq {
        var kept: usize = 0;
        var last: tw.Seq = 0;
        for (self.cycle_starts[0..self.starts]) |start| {
            if (start > saved) continue;
            self.cycle_starts[kept] = start;
            kept += 1;
            last = @max(last, start);
        }
        self.starts = kept;
        return last;
    }
};

const Draw = union(enum) {
    event: tw.Event,
    crash,
    resume_in_place,
};

fn drawEvent(draws: anytype, state: *const tw.State) Draw {
    const live = state.live.items();
    const id: tw.BlockId = if (live.len > 0 and draws.below(4, 11) != 0) live[draws.below(live.len, 12)] else 1 + draws.below(6, 13);
    const token: tw.Token = if (state.ctrlo.pending != 0 and draws.below(3, 14) != 0)
        state.ctrlo.pending
    else
        @intCast(draws.below(state.next_token + 2, 15));
    return .{ .event = switch (draws.below(18, 10)) {
        0 => .turn_started,
        1 => .turn_ended,
        2 => .{ .block_opened = id },
        3 => .{ .block_changed = id },
        4, 5 => .{ .block_finished = id },
        6 => .{ .saved_through = @intCast(draws.below(state.next_seq + 3, 16)) },
        7 => .compacted,
        8 => .resized,
        9, 10 => .reprint_tick,
        11 => .ctrlo_opened,
        12 => .{ .ctrlo_scrolled = if (draws.below(3, 17) == 0) .newer else .older },
        13 => .ctrlo_closed,
        14 => .{ .log_read_done = .{ .token = token, .count = @intCast(draws.below(state.config.read_step + 3, 18)) } },
        15 => .{ .log_read_failed = token },
        16 => return .crash,
        else => return .resume_in_place,
    } };
}

fn checkStep(before: tw.State, event: tw.Event, out: tw.Output, world: *World) !void {
    const after = out.state;
    const config = before.config;
    if (out.rejected != null) {
        try std.testing.expectEqual(tw.abstract(&before), tw.abstract(&after));
        try std.testing.expect(out.effect == null);
        return;
    }
    switch (event) {
        .block_changed => |id| {
            try std.testing.expectEqual(tw.abstract(&before), tw.abstract(&after));
            try std.testing.expectEqual(tw.Effect{ .repaint_block = id }, out.effect.?);
        },

        .log_read_done => |reply| {
            try std.testing.expectEqual(before.ctrlo.pending, reply.token);
            try std.testing.expect(before.ctrlo.lo -| after.ctrlo.lo <= config.read_step);
            try std.testing.expect(after.ctrlo.hi -| before.ctrlo.hi <= config.read_step);
        },

        .ctrlo_opened => {
            try std.testing.expectEqual(before.next_seq, after.ctrlo.hi);
            try std.testing.expect(after.ctrlo.lo >= before.heldFirst());
        },
        .log_read_failed => |token| try std.testing.expectEqual(before.ctrlo.pending, token),
        .resized, .resumed => world.painted = .empty,
        else => {},
    }
    if (out.effect) |effect| switch (effect) {
        .drop => |range| {
            try std.testing.expect(range.from < range.to);
            try std.testing.expect(range.to <= after.cycle_first);
            if (config.saved) try std.testing.expect(range.to <= world.log_saved);
            try std.testing.expect(!after.turn_open);
        },
        .paint_final => |seq| {
            try std.testing.expectEqual(after.next_seq - 1, seq);
            try std.testing.expect(!world.painted.isSet(seq));
            world.painted.set(seq);
        },
        .reprint_slice => |range| {
            try std.testing.expect(range.from < range.to and range.to - range.from <= config.slice);
            for (range.from..range.to) |seq| {
                try std.testing.expect(!world.painted.isSet(seq));
                world.painted.set(seq);
            }
        },
        .read_log => {
            try std.testing.expect(config.saved);
            try std.testing.expect(event != .ctrlo_opened);
        },
        else => {},
    };

    if (!after.turn_open and (!config.saved or after.saved_through >= after.cycle_first)) try std.testing.expect(after.prev_first == null);
    if (after.reprinting) {
        try std.testing.expect(after.heldFirst() <= after.painted_through and after.painted_through <= after.next_seq);
    } else {
        try std.testing.expectEqual(after.next_seq, after.painted_through);
        for (after.heldFirst()..after.next_seq) |seq| try std.testing.expect(world.painted.isSet(seq));
    }
    const co = after.ctrlo;
    if (co.open) try std.testing.expect(co.lo <= co.hi and co.hi <= after.next_seq and co.hi - co.lo <= config.window);
    if (co.pending != 0) try std.testing.expect(co.open);
}

fn driveCore(draws: anytype) !void {
    const config: tw.Config = .{
        .window = @intCast(1 + draws.below(4, 1)),
        .read_step = @intCast(1 + draws.below(3, 2)),
        .slice = @intCast(1 + draws.below(3, 3)),
        .saved = draws.below(4, 4) != 0,
    };
    var state = tw.State.init(config);
    var world: World = .{};
    world.addStart(0);
    const steps = 1 + draws.below(max_steps, 5);
    for (0..steps) |_| {
        const drawn = drawEvent(draws, &state);
        var before = state;
        const event: tw.Event = switch (drawn) {
            .event => |event| event,
            .crash, .resume_in_place => restart: {
                if (!config.saved) continue;

                if (drawn == .crash) before = tw.State.init(config);
                const saved = world.log_saved;
                break :restart .{ .resumed = .{ .cycle = state.cycle, .cycle_first = world.lastStart(saved), .next_seq = saved } };
            },
        };
        if (event == .saved_through and config.saved) world.log_saved = @max(world.log_saved, @min(event.saved_through, before.next_seq));
        const out = tw.step(before, event);
        try checkStep(before, event, out, &world);
        if (event == .resumed) {
            const after = out.state;
            try std.testing.expectEqual(world.log_saved, after.next_seq);
            try std.testing.expectEqual(world.log_saved, after.saved_through);
            try std.testing.expect(after.prev_first == null and after.live.len == 0 and !after.turn_open);
            try std.testing.expect(!after.ctrlo.open and after.ctrlo.pending == 0);
        }
        if (event == .compacted) world.addStart(before.next_seq);
        state = out.state;
    }
}

fn fuzzCore(_: void, smith: *std.testing.Smith) !void {
    try driveCore(FuzzDraws{ .smith = smith });
}

fn corpusOf(comptime values: []const u64) []const u8 {
    comptime {
        var bytes: [values.len * 8]u8 = undefined;
        for (values, 0..) |value, index| std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
        const final = bytes;
        return &final;
    }
}

test "the transcript window keeps the model's laws on arbitrary event sequences" {
    try std.testing.fuzz({}, fuzzCore, .{
        .corpus = &(.{
            comptime corpusOf(&.{ 1, 0, 0, 1, 12, 0, 4, 0, 4, 1, 6, 2, 7, 1, 11, 12, 1, 14, 1, 1 }),
        } ++ @import("fuzz_corpus").transcript_window.*),
    });
}

test "the transcript window keeps the model's laws on seeded random event sequences" {
    var prng: std.Random.DefaultPrng = .init(20261030);
    for (0..4000) |_| try driveCore(SeededDraws{ .random = prng.random() });
}

test {
    _ = tw;
}
