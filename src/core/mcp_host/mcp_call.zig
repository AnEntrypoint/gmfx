const std = @import("std");

pub const protocol_version: u32 = 1;

pub const max_slots = 16;

pub const default_capacity: u8 = 8;

pub const max_owners = 1 + 256;

pub const Token = [32]u8;

pub const OwnerId = enum(u32) {
    main = 0,
    _,
};

pub const RequestId = enum(u64) {
    _,
};

pub const Stage = enum {
    authorizing,
    calling,
    replying,
    abandoned_auth,
    abandoned_call,
};

pub const Decision = enum { allow, deny };
pub const Delivery = enum { delivered, lost };

pub const Outcome = enum { ok, tool_error, failed };

pub const ReplyOutcome = enum { ok, tool_error, failed, denied };

pub const Refusal = enum { closed, unauthorized, unsupported_version, busy };

pub const Drop = enum {
    stale,
    result_dropped,
    reply_lost,
};

pub const Owner = struct {
    id: OwnerId,
    token: Token,
};

pub const Entry = struct {
    id: RequestId,
    owner: OwnerId,
    stage: Stage,
};

pub const State = struct {
    open: bool = false,
    capacity: u8 = default_capacity,
    owners: [max_owners]?Owner = @splat(null),
    next: u64 = 0,
    slots: [max_slots]?Entry = @splat(null),

    pub fn init(capacity: u8) State {
        std.debug.assert(capacity >= 1 and capacity <= max_slots);
        return .{ .capacity = capacity };
    }
};

pub const Event = union(enum) {
    started: Token,
    stopped,
    owner_added: struct { owner: OwnerId, token: Token },
    owner_removed: OwnerId,
    request: struct { token: Token, version: u32 },
    authorized: struct { id: RequestId, decision: Decision },
    call_finished: struct { id: RequestId, outcome: Outcome },
    reply_done: struct { id: RequestId, delivery: Delivery },
    client_gone: RequestId,
};

pub const Work = struct {
    id: RequestId,
    owner: OwnerId,
};

pub const Effect = union(enum) {
    refuse: Refusal,
    authorize: Work,
    call: Work,
    withdraw: RequestId,
    cancel: RequestId,
    reply: struct { id: RequestId, outcome: ReplyOutcome },
    log: struct { id: RequestId, drop: Drop },
};

pub const max_effects = max_slots;

pub const Output = struct {
    state: State,
    buffer: [max_effects]Effect = undefined,
    len: usize = 0,

    pub fn effects(self: *const Output) []const Effect {
        return self.buffer[0..self.len];
    }

    fn push(self: *Output, effect: Effect) void {
        self.buffer[self.len] = effect;
        self.len += 1;
    }
};

pub fn step(state: State, event: Event) Output {
    return switch (event) {
        .started => |token| onStarted(state, token),
        .stopped => onStopped(state),
        .owner_added => |added| onOwnerAdded(state, added.owner, added.token),
        .owner_removed => |owner| onOwnerRemoved(state, owner),
        .request => |request| onRequest(state, request.token, request.version),
        .authorized => |answer| onAuthorized(state, answer.id, answer.decision),
        .call_finished => |finished| onCallFinished(state, finished.id, finished.outcome),
        .reply_done => |done| onReplyDone(state, done.id, done.delivery),
        .client_gone => |id| onClientGone(state, id),
    };
}

fn quiet(state: State) Output {
    return .{ .state = state };
}

fn logged(state: State, id: RequestId, drop: Drop) Output {
    var out: Output = .{ .state = state };
    out.push(.{ .log = .{ .id = id, .drop = drop } });
    return out;
}

fn onStarted(state: State, token: Token) Output {
    if (state.open) return quiet(state);
    var next = state;
    next.open = true;
    next.owners = @splat(null);
    next.owners[0] = .{ .id = .main, .token = token };
    return quiet(next);
}

fn onStopped(state: State) Output {
    if (!state.open) return quiet(state);
    var out: Output = .{ .state = state };
    out.state.open = false;
    out.state.owners = @splat(null);
    abandonWhere(&out, null);
    return out;
}

fn onOwnerAdded(state: State, owner: OwnerId, token: Token) Output {
    if (!state.open or ownerSlot(state, owner) != null or ownerOf(state, token) != null) return quiet(state);
    var next = state;
    for (&next.owners) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .id = owner, .token = token };
            return quiet(next);
        }
    }

    return quiet(state);
}

fn onOwnerRemoved(state: State, owner: OwnerId) Output {
    if (owner == .main) return quiet(state);
    const index = ownerSlot(state, owner) orelse return quiet(state);
    var out: Output = .{ .state = state };
    out.state.owners[index] = null;
    abandonWhere(&out, owner);
    return out;
}

fn refusal(state: State, owner: ?OwnerId, version: u32) ?Refusal {
    if (!state.open) return .closed;
    if (owner == null) return .unauthorized;
    if (version != protocol_version) return .unsupported_version;
    if (held(state) >= state.capacity) return .busy;
    return null;
}

fn onRequest(state: State, token: Token, version: u32) Output {
    const owner = ownerOf(state, token);
    var out: Output = .{ .state = state };
    if (refusal(state, owner, version)) |reason| {
        out.push(.{ .refuse = reason });
        return out;
    }
    const id: RequestId = @fromBackingInt(state.next);
    out.state.next = state.next + 1;
    out.state.slots[freeSlot(state)] = .{ .id = id, .owner = owner.?, .stage = .authorizing };
    out.push(.{ .authorize = .{ .id = id, .owner = owner.? } });
    return out;
}

fn onAuthorized(state: State, id: RequestId, decision: Decision) Output {
    const index = slotOf(state, id) orelse return logged(state, id, .stale);
    const entry = state.slots[index].?;
    var out: Output = .{ .state = state };
    switch (entry.stage) {
        .authorizing => switch (decision) {
            .allow => {
                out.state.slots[index].?.stage = .calling;
                out.push(.{ .call = .{ .id = id, .owner = entry.owner } });
            },
            .deny => {
                out.state.slots[index].?.stage = .replying;
                out.push(.{ .reply = .{ .id = id, .outcome = .denied } });
            },
        },
        .abandoned_auth => out.state.slots[index] = null,
        .calling, .replying, .abandoned_call => return logged(state, id, .stale),
    }
    return out;
}

fn onCallFinished(state: State, id: RequestId, outcome: Outcome) Output {
    const index = slotOf(state, id) orelse return logged(state, id, .stale);
    var out: Output = .{ .state = state };
    switch (state.slots[index].?.stage) {
        .calling => {
            out.state.slots[index].?.stage = .replying;
            out.push(.{ .reply = .{ .id = id, .outcome = replyOutcome(outcome) } });
        },
        .abandoned_call => {
            out.state.slots[index] = null;
            if (outcome != .failed) out.push(.{ .log = .{ .id = id, .drop = .result_dropped } });
        },
        .authorizing, .replying, .abandoned_auth => return logged(state, id, .stale),
    }
    return out;
}

fn onReplyDone(state: State, id: RequestId, delivery: Delivery) Output {
    const index = slotOf(state, id) orelse return logged(state, id, .stale);
    if (state.slots[index].?.stage != .replying) return logged(state, id, .stale);
    var out: Output = .{ .state = state };
    out.state.slots[index] = null;
    if (delivery == .lost) out.push(.{ .log = .{ .id = id, .drop = .reply_lost } });
    return out;
}

fn onClientGone(state: State, id: RequestId) Output {
    const index = slotOf(state, id) orelse return quiet(state);
    var out: Output = .{ .state = state };
    letGo(&out, index);
    return out;
}

fn abandonWhere(out: *Output, owner: ?OwnerId) void {
    for (out.state.slots, 0..) |slot, index| {
        const entry = slot orelse continue;
        if (owner) |only| if (entry.owner != only) continue;
        letGo(out, index);
    }
}

fn letGo(out: *Output, index: usize) void {
    const entry = &out.state.slots[index].?;
    switch (entry.stage) {
        .authorizing => {
            entry.stage = .abandoned_auth;
            out.push(.{ .withdraw = entry.id });
        },
        .calling => {
            entry.stage = .abandoned_call;
            out.push(.{ .cancel = entry.id });
        },
        .replying, .abandoned_auth, .abandoned_call => {},
    }
}

fn replyOutcome(outcome: Outcome) ReplyOutcome {
    return switch (outcome) {
        .ok => .ok,
        .tool_error => .tool_error,
        .failed => .failed,
    };
}

fn ownerOf(state: State, token: Token) ?OwnerId {
    var found: ?OwnerId = null;
    for (state.owners) |slot| {
        const owner = slot orelse continue;
        if (std.crypto.timing_safe.eql(Token, owner.token, token)) found = owner.id;
    }
    return found;
}

fn ownerSlot(state: State, owner: OwnerId) ?usize {
    for (state.owners, 0..) |slot, index| {
        if (slot) |registered| if (registered.id == owner) return index;
    }
    return null;
}

fn slotOf(state: State, id: RequestId) ?usize {
    for (state.slots, 0..) |slot, index| {
        if (slot) |entry| if (entry.id == id) return index;
    }
    return null;
}

fn held(state: State) usize {
    var count: usize = 0;
    for (state.slots) |slot| {
        if (slot != null) count += 1;
    }
    return count;
}

fn freeSlot(state: State) usize {
    for (state.slots, 0..) |slot, index| {
        if (slot == null) return index;
    }
    unreachable;
}

pub const Abstract = struct {
    open: bool,
    next: u64,
    owners_buffer: [max_owners]Owner = undefined,
    owners_len: usize = 0,
    entries_buffer: [max_slots]Entry = undefined,
    entries_len: usize = 0,

    pub fn owners(self: *const Abstract) []const Owner {
        return self.owners_buffer[0..self.owners_len];
    }

    pub fn entries(self: *const Abstract) []const Entry {
        return self.entries_buffer[0..self.entries_len];
    }
};

pub fn abstract(state: *const State) Abstract {
    var result: Abstract = .{ .open = state.open, .next = state.next };
    for (state.owners) |slot| {
        const owner = slot orelse continue;
        result.owners_buffer[result.owners_len] = owner;
        result.owners_len += 1;
    }
    for (state.slots) |slot| {
        const entry = slot orelse continue;
        result.entries_buffer[result.entries_len] = entry;
        result.entries_len += 1;
    }
    std.mem.sort(Owner, result.owners_buffer[0..result.owners_len], {}, ownerBefore);
    std.mem.sort(Entry, result.entries_buffer[0..result.entries_len], {}, entryBefore);
    return result;
}

fn ownerBefore(_: void, a: Owner, b: Owner) bool {
    return @backingInt(a.id) < @backingInt(b.id);
}

fn entryBefore(_: void, a: Entry, b: Entry) bool {
    return @backingInt(a.id) < @backingInt(b.id);
}

const testing = std.testing;
const main_token: Token = @splat(0x11);
const child_token: Token = @splat(0x22);
const forged_token: Token = @splat(0xff);
const child: OwnerId = @fromBackingInt(1);

fn rid(n: u64) RequestId {
    return @fromBackingInt(n);
}

fn run(state: State, events: []const Event) State {
    var current = state;
    for (events) |event| current = step(current, event).state;
    return current;
}

fn single(out: Output) Effect {
    std.debug.assert(out.len == 1);
    return out.buffer[0];
}

test "a request is admitted only with a token in force and the supported version" {
    const closed = State.init(2);
    try testing.expectEqual(Effect{ .refuse = .closed }, single(step(closed, .{ .request = .{ .token = main_token, .version = 1 } })));

    const open = run(closed, &.{.{ .started = main_token }});
    try testing.expectEqual(Effect{ .refuse = .unauthorized }, single(step(open, .{ .request = .{ .token = forged_token, .version = 1 } })));

    try testing.expectEqual(Effect{ .refuse = .unauthorized }, single(step(open, .{ .request = .{ .token = forged_token, .version = 2 } })));
    try testing.expectEqual(Effect{ .refuse = .unsupported_version }, single(step(open, .{ .request = .{ .token = main_token, .version = 2 } })));

    const admitted = step(open, .{ .request = .{ .token = main_token, .version = 1 } });
    try testing.expectEqual(Effect{ .authorize = .{ .id = rid(0), .owner = .main } }, single(admitted));
    try testing.expectEqual(@as(u64, 1), admitted.state.next);

    const restarted = run(admitted.state, &.{ .stopped, .{ .started = child_token } });
    try testing.expectEqual(Effect{ .refuse = .unauthorized }, single(step(restarted, .{ .request = .{ .token = main_token, .version = 1 } })));
}

test "a full owner table leaves a new owner out, and its requests are refused" {
    var state = run(State.init(2), &.{.{ .started = main_token }});
    var n: u32 = 1;
    while (n < max_owners) : (n += 1) {
        var token: Token = @splat(0);
        std.mem.writeInt(u32, token[0..4], n, .little);
        token[31] = 0xee;
        state = step(state, .{ .owner_added = .{ .owner = @fromBackingInt(n), .token = token } }).state;
    }
    const late_token: Token = @splat(0xab);
    const full = step(state, .{ .owner_added = .{ .owner = @fromBackingInt(max_owners), .token = late_token } });
    try testing.expectEqual(@as(usize, 0), full.effects().len);
    try testing.expectEqualDeep(state, full.state);
    try testing.expectEqual(Effect{ .refuse = .unauthorized }, single(step(full.state, .{ .request = .{ .token = late_token, .version = 1 } })));
}

test "a call starts only after the permission check allows it, once per request" {
    const waiting = run(State.init(2), &.{ .{ .started = main_token }, .{ .request = .{ .token = main_token, .version = 1 } } });
    const allowed = step(waiting, .{ .authorized = .{ .id = rid(0), .decision = .allow } });
    try testing.expectEqual(Effect{ .call = .{ .id = rid(0), .owner = .main } }, single(allowed));

    const again = step(allowed.state, .{ .authorized = .{ .id = rid(0), .decision = .allow } });
    try testing.expectEqual(Effect{ .log = .{ .id = rid(0), .drop = .stale } }, single(again));
    try testing.expectEqualDeep(allowed.state, again.state);

    const denied = step(waiting, .{ .authorized = .{ .id = rid(0), .decision = .deny } });
    try testing.expectEqual(Effect{ .reply = .{ .id = rid(0), .outcome = .denied } }, single(denied));
}

test "a subagent's requests act for it, and its end lets them go" {
    const two = run(State.init(2), &.{
        .{ .started = main_token },
        .{ .owner_added = .{ .owner = child, .token = child_token } },
        .{ .request = .{ .token = child_token, .version = 1 } },
        .{ .request = .{ .token = child_token, .version = 1 } },
    });
    const calling = step(two, .{ .authorized = .{ .id = rid(0), .decision = .allow } });
    try testing.expectEqual(Effect{ .call = .{ .id = rid(0), .owner = child } }, single(calling));
    const ended = step(calling.state, .{ .owner_removed = child });
    try testing.expectEqual(@as(usize, 2), ended.len);
    try testing.expectEqual(Effect{ .cancel = rid(0) }, ended.buffer[0]);
    try testing.expectEqual(Effect{ .withdraw = rid(1) }, ended.buffer[1]);
    try testing.expectEqual(Effect{ .refuse = .unauthorized }, single(step(ended.state, .{ .request = .{ .token = child_token, .version = 1 } })));
}

test "stopping lets work go, but each request keeps its slot until its work ends" {
    const busy = run(State.init(2), &.{
        .{ .started = main_token },
        .{ .request = .{ .token = main_token, .version = 1 } },
        .{ .request = .{ .token = main_token, .version = 1 } },
        .{ .authorized = .{ .id = rid(0), .decision = .allow } },
    });
    try testing.expectEqual(Effect{ .refuse = .busy }, single(step(busy, .{ .request = .{ .token = main_token, .version = 1 } })));
    const stopped = step(busy, .stopped);
    try testing.expectEqual(@as(usize, 2), stopped.len);

    const reopened = run(stopped.state, &.{.{ .started = child_token }});
    try testing.expectEqual(Effect{ .refuse = .busy }, single(step(reopened, .{ .request = .{ .token = child_token, .version = 1 } })));

    const freed = step(reopened, .{ .authorized = .{ .id = rid(1), .decision = .allow } });
    try testing.expectEqual(@as(usize, 0), freed.len);
    try testing.expectEqual(Effect{ .authorize = .{ .id = rid(2), .owner = .main } }, single(step(freed.state, .{ .request = .{ .token = child_token, .version = 1 } })));
}

test "a result whose client is gone is dropped and logged, and so is a reply that was lost" {
    const calling = run(State.init(2), &.{
        .{ .started = main_token },
        .{ .request = .{ .token = main_token, .version = 1 } },
        .{ .authorized = .{ .id = rid(0), .decision = .allow } },
    });
    const gone = step(calling, .{ .client_gone = rid(0) });
    try testing.expectEqual(Effect{ .cancel = rid(0) }, single(gone));
    try testing.expectEqual(Effect{ .log = .{ .id = rid(0), .drop = .result_dropped } }, single(step(gone.state, .{ .call_finished = .{ .id = rid(0), .outcome = .ok } })));
    try testing.expectEqual(@as(usize, 0), step(gone.state, .{ .call_finished = .{ .id = rid(0), .outcome = .failed } }).len);

    const replying = step(calling, .{ .call_finished = .{ .id = rid(0), .outcome = .tool_error } });
    try testing.expectEqual(Effect{ .reply = .{ .id = rid(0), .outcome = .tool_error } }, single(replying));
    try testing.expectEqual(Effect{ .log = .{ .id = rid(0), .drop = .reply_lost } }, single(step(replying.state, .{ .reply_done = .{ .id = rid(0), .delivery = .lost } })));
}

test "abstract lists registrations by owner and entries by id" {
    const state = run(State.init(3), &.{
        .{ .started = main_token },
        .{ .request = .{ .token = main_token, .version = 1 } },
        .{ .request = .{ .token = main_token, .version = 1 } },
        .{ .authorized = .{ .id = rid(0), .decision = .deny } },
        .{ .reply_done = .{ .id = rid(0), .delivery = .delivered } },
        .{ .request = .{ .token = main_token, .version = 1 } },
    });

    try testing.expectEqual(rid(2), state.slots[0].?.id);
    const view = abstract(&state);
    try testing.expectEqual(@as(usize, 2), view.entries().len);
    try testing.expectEqual(rid(1), view.entries()[0].id);
    try testing.expectEqual(rid(2), view.entries()[1].id);
    try testing.expectEqual(@as(usize, 1), view.owners().len);
}

fn randomEvent(random: std.Random) Event {
    const pick = random.uintLessThan(u8, 10);
    const any_id = rid(random.uintLessThan(u64, 6));
    const tokens = [_]Token{ main_token, child_token, forged_token };
    return switch (pick) {
        0 => .{ .started = tokens[random.uintLessThan(usize, 2)] },
        1 => if (random.boolean()) .stopped else .{ .owner_removed = child },
        2 => .{ .owner_added = .{ .owner = child, .token = tokens[random.uintLessThan(usize, 2)] } },
        3, 4 => .{ .request = .{ .token = tokens[random.uintLessThan(usize, 3)], .version = if (random.uintLessThan(u8, 5) == 0) 2 else 1 } },
        5 => .{ .authorized = .{ .id = any_id, .decision = if (random.boolean()) .allow else .deny } },
        6 => .{ .call_finished = .{ .id = any_id, .outcome = random.enumValue(Outcome) } },
        7 => .{ .reply_done = .{ .id = any_id, .delivery = if (random.boolean()) .delivered else .lost } },
        else => .{ .client_gone = any_id },
    };
}

test "seeded random event sequences keep the bounds and run at most one call per request" {
    var prng = std.Random.DefaultPrng.init(20261029);
    const random = prng.random();
    for (0..200) |_| {
        var state = State.init(2);
        var called: [64]bool = @splat(false);
        for (0..60) |_| {
            const before = state;
            const event = randomEvent(random);
            const out = step(state, event);
            state = out.state;
            try testing.expect(held(state) <= state.capacity);
            try testing.expect(out.len <= state.capacity);
            for (out.effects()) |effect| switch (effect) {
                .call => |work| {
                    try testing.expect(event == .authorized and event.authorized.decision == .allow);
                    try testing.expectEqual(Stage.authorizing, before.slots[slotOf(before, work.id).?].?.stage);
                    const n: usize = @intCast(@backingInt(work.id));
                    try testing.expect(!called[n]);
                    called[n] = true;
                },
                .authorize => |work| try testing.expectEqual(before.next, @backingInt(work.id)),
                else => {},
            };
            for (state.slots) |slot| {
                const entry = slot orelse continue;
                try testing.expect(@backingInt(entry.id) < state.next);
                if (entry.stage == .authorizing or entry.stage == .calling) try testing.expect(ownerSlot(state, entry.owner) != null);
            }
        }
    }
}
