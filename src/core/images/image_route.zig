const std = @import("std");

pub const Support = enum {
    unknown,
    non_native,
    native,
};

pub const CatalogView = union(enum) {
    down,
    missing,
    listed: Tags,

    pub const Tags = struct {
        vision: bool,
        file_input: bool,
    };
};

pub fn supportFromCatalog(view: CatalogView) Support {
    return switch (view) {
        .down, .missing => .unknown,
        .listed => |tags| if (tags.vision) .native else .non_native,
    };
}

pub const Route = enum {
    native,
    fallback,
    unavailable,
};

pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

pub const ToolImages = enum {
    none,
    attached,
    withheld_fallback,
    withheld_dead_end,
    withheld_unknown,
};

pub const FailReason = enum {
    capability_unknown,
    no_native_image,
};

pub const Request = struct {
    user_images: bool,
    earlier_images: bool,
    pending_images: bool,
    tool_images: bool,
    fallback: bool,
    catalog_down: bool,
};

pub const State = struct {
    support: Support = .unknown,
    resolved: bool = false,
    notified: bool = false,
    pending: ?Request = null,
};

pub const Event = union(enum) {
    turn_started: Support,
    request_ready: Request,
    capabilities_resolved: Support,
};

pub const Decision = struct {
    route: Route,
    mode: VisionMode,
    tool_images: ToolImages,
    earlier_images: ToolImages,
};

pub const Effect = union(enum) {
    resolve_capabilities,
    notify_catalog_down,
    send: Decision,
    fail: FailReason,
};

pub const max_effects = 2;

pub const Output = struct {
    state: State,
    buffer: [max_effects]Effect = undefined,
    len: usize = 0,

    pub fn effects(self: *const Output) []const Effect {
        return self.buffer[0..self.len];
    }
};

pub fn step(state: State, event: Event) Output {
    return switch (event) {
        .turn_started => |support| .{ .state = .{ .support = support } },
        .request_ready => |request| onRequest(state, request),
        .capabilities_resolved => |support| onResolved(state, support),
    };
}

fn onRequest(state: State, request: Request) Output {
    if (state.pending != null) {
        var next = state;
        next.pending = request;
        return .{ .state = next };
    }
    if (state.support == .unknown and !state.resolved and hasImages(request)) {
        var next = state;
        next.resolved = true;
        next.pending = request;
        return withEffects(next, &.{.resolve_capabilities});
    }
    return decide(state, request);
}

fn onResolved(state: State, support: Support) Output {
    const request = state.pending orelse return .{ .state = state };
    var next = state;
    next.support = support;
    next.pending = null;
    return decide(next, request);
}

fn decide(state: State, request: Request) Output {
    const chosen = decision(state.support, request);
    if (request.user_images and chosen.route == .unavailable) {
        const reason: FailReason = if (state.support == .unknown) .capability_unknown else .no_native_image;
        return withEffects(state, &.{.{ .fail = reason }});
    }
    if (withholdsUnknown(chosen) and request.catalog_down and !state.notified) {
        var next = state;
        next.notified = true;
        return withEffects(next, &.{ .notify_catalog_down, .{ .send = chosen } });
    }
    return withEffects(state, &.{.{ .send = chosen }});
}

fn hasImages(request: Request) bool {
    return request.user_images or request.earlier_images or request.tool_images;
}

fn withholdsUnknown(chosen: Decision) bool {
    return chosen.tool_images == .withheld_unknown or chosen.earlier_images == .withheld_unknown;
}

pub fn decision(support: Support, request: Request) Decision {
    const route: Route = switch (support) {
        .native => .native,
        .unknown => .unavailable,
        .non_native => if (request.fallback) .fallback else .unavailable,
    };
    const mode: VisionMode = if (route != .fallback)
        .unavailable
    else if (request.pending_images)
        .required
    else
        .optional;
    return .{
        .route = route,
        .mode = mode,
        .tool_images = held(request.tool_images, support, route),
        .earlier_images = held(request.earlier_images, support, route),
    };
}

fn held(present: bool, support: Support, route: Route) ToolImages {
    if (!present) return .none;
    return switch (support) {
        .native => .attached,
        .unknown => .withheld_unknown,
        .non_native => if (route == .fallback) .withheld_fallback else .withheld_dead_end,
    };
}

fn withEffects(state: State, list: []const Effect) Output {
    var out: Output = .{ .state = state, .len = list.len };
    @memcpy(out.buffer[0..list.len], list);
    return out;
}

pub const Abstract = struct {
    support: Support,
    resolved: bool,
    notified: bool,
    pending: []const Request,
};

pub fn abstract(state: *const State) Abstract {
    return .{
        .support = state.support,
        .resolved = state.resolved,
        .notified = state.notified,
        .pending = if (state.pending) |*request| request[0..1] else &.{},
    };
}

fn eachRequest(comptime body: anytype) !void {
    for (0..64) |bits| {
        const request: Request = .{
            .user_images = bits & 1 != 0,
            .pending_images = bits & 2 != 0,
            .tool_images = bits & 4 != 0,
            .fallback = bits & 8 != 0,
            .catalog_down = bits & 16 != 0,
            .earlier_images = bits & 32 != 0,
        };
        if (request.pending_images and !request.user_images) continue;
        try body(request);
    }
}

const all_support = [_]Support{ .unknown, .non_native, .native };

test "a catalog that lists vision makes image input native with or without file input" {
    for ([_]bool{ false, true }) |file_input| {
        try std.testing.expectEqual(Support.native, supportFromCatalog(.{ .listed = .{ .vision = true, .file_input = file_input } }));
        try std.testing.expectEqual(Support.non_native, supportFromCatalog(.{ .listed = .{ .vision = false, .file_input = file_input } }));
    }
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.down));
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.missing));
}

test "every decision reads one support value" {
    try eachRequest(struct {
        fn check(request: Request) !void {
            for (all_support) |support| {
                const chosen = decision(support, request);
                try std.testing.expectEqual(chosen.route == .native, support == .native);
                try std.testing.expectEqual(chosen.route == .fallback, chosen.mode != .unavailable);
                try std.testing.expectEqual(chosen.tool_images == .none, !request.tool_images);
                try std.testing.expectEqual(chosen.earlier_images == .none, !request.earlier_images);
                for ([_]ToolImages{ chosen.tool_images, chosen.earlier_images }) |images| {
                    if (images == .attached) try std.testing.expectEqual(Support.native, support);
                    if (images == .withheld_unknown) try std.testing.expectEqual(Support.unknown, support);
                    if (images == .withheld_fallback) try std.testing.expectEqual(Route.fallback, chosen.route);
                    if (images == .withheld_dead_end) try std.testing.expect(support == .non_native and chosen.route == .unavailable);
                }
                if (chosen.route == .fallback) try std.testing.expectEqual(request.pending_images, chosen.mode == .required);
            }
        }
    }.check);
}

test "a turn asks for capabilities at most once and answers the request it held" {
    try eachRequest(struct {
        fn check(request: Request) !void {
            const started = step(.{}, .{ .turn_started = .unknown });
            const first = step(started.state, .{ .request_ready = request });
            if (!hasImages(request)) {
                try std.testing.expectEqual(@as(usize, 1), first.len);
                try std.testing.expect(first.effects()[0] == .send);
                return;
            }
            try std.testing.expectEqual(@as(usize, 1), first.len);
            try std.testing.expect(first.effects()[0] == .resolve_capabilities);

            const duplicate = step(first.state, .{ .request_ready = request });
            try std.testing.expectEqual(@as(usize, 0), duplicate.len);
            const answered = step(duplicate.state, .{ .capabilities_resolved = .unknown });
            try std.testing.expect(answered.state.pending == null);
            for (answered.effects()) |effect| try std.testing.expect(effect != .resolve_capabilities);

            const stale = step(answered.state, .{ .capabilities_resolved = .native });
            try std.testing.expectEqual(@as(usize, 0), stale.len);
            try std.testing.expectEqualDeep(answered.state, stale.state);

            const again = step(stale.state, .{ .request_ready = request });
            for (again.effects()) |effect| try std.testing.expect(effect != .resolve_capabilities);
        }
    }.check);
}

test "the catalog-down notice reaches the user once per turn" {
    const request: Request = .{ .user_images = false, .earlier_images = false, .pending_images = false, .tool_images = true, .fallback = true, .catalog_down = true };
    var state = step(.{}, .{ .turn_started = .unknown }).state;
    var notices: usize = 0;
    for (0..3) |_| {
        var out = step(state, .{ .request_ready = request });
        if (out.len == 1 and out.effects()[0] == .resolve_capabilities) out = step(out.state, .{ .capabilities_resolved = .unknown });
        for (out.effects()) |effect| {
            if (effect == .notify_catalog_down) notices += 1;
        }
        state = out.state;
    }
    try std.testing.expectEqual(@as(usize, 1), notices);
    const next_turn = step(state, .{ .turn_started = .unknown });
    try std.testing.expect(!next_turn.state.notified and !next_turn.state.resolved);
}

test "user images without a route fail the request and never send" {
    for (all_support) |support| {
        const request: Request = .{ .user_images = true, .earlier_images = true, .pending_images = true, .tool_images = true, .fallback = false, .catalog_down = false };
        const out = step(.{ .support = support, .resolved = true }, .{ .request_ready = request });
        try std.testing.expectEqual(@as(usize, 1), out.len);
        switch (support) {
            .native => try std.testing.expect(out.effects()[0] == .send),
            .unknown => try std.testing.expectEqual(Effect{ .fail = .capability_unknown }, out.effects()[0]),
            .non_native => try std.testing.expectEqual(Effect{ .fail = .no_native_image }, out.effects()[0]),
        }
    }
}

test "abstract maps the pending request onto a sequence of at most one" {
    const request: Request = .{ .user_images = true, .earlier_images = false, .pending_images = false, .tool_images = false, .fallback = true, .catalog_down = false };
    const idle: State = .{};
    try std.testing.expectEqual(@as(usize, 0), abstract(&idle).pending.len);
    const waiting: State = .{ .resolved = true, .pending = request };
    const view = abstract(&waiting);
    try std.testing.expectEqual(@as(usize, 1), view.pending.len);
    try std.testing.expectEqualDeep(request, view.pending[0]);
}

test "requests carry flags, not image bytes" {
    inline for (@typeInfo(Request).@"struct".field_types) |field_type| {
        try std.testing.expect(field_type == bool);
    }
}

test "an earlier image never blocks a turn" {
    for (all_support) |support| {
        for ([_]bool{ false, true }) |fallback| {
            for ([_]bool{ false, true }) |catalog_down| {
                const request: Request = .{ .user_images = false, .earlier_images = true, .pending_images = false, .tool_images = false, .fallback = fallback, .catalog_down = catalog_down };
                const asked = step(step(.{}, .{ .turn_started = .unknown }).state, .{ .request_ready = request });
                try std.testing.expectEqual(Effect.resolve_capabilities, asked.effects()[0]);
                const out = step(asked.state, .{ .capabilities_resolved = support });
                const answer = out.effects()[out.len - 1];
                try std.testing.expect(answer == .send);
                const expected: ToolImages = switch (support) {
                    .native => .attached,
                    .non_native => if (fallback) .withheld_fallback else .withheld_dead_end,
                    .unknown => ToolImages.withheld_unknown,
                };
                try std.testing.expectEqual(expected, answer.send.earlier_images);

                try std.testing.expectEqual(support == .unknown and catalog_down, out.len == 2);
            }
        }
    }
}

fn decidedRequest(before: State, event: Event) ?Request {
    return switch (event) {
        .turn_started => null,
        .request_ready => |request| if (before.pending == null) request else null,
        .capabilities_resolved => before.pending,
    };
}

fn expectLaws(before: State, event: Event, out: Output) !void {
    const after = out.state;
    const effects = out.effects();
    const decided = decidedRequest(before, event);

    try std.testing.expect(effects.len <= max_effects);
    if (effects.len == 2) try std.testing.expect(effects[0] == .notify_catalog_down and effects[1] == .send);
    for (effects) |effect| switch (effect) {
        .resolve_capabilities => {
            try std.testing.expect(event == .request_ready and before.pending == null);
            try std.testing.expect(before.support == .unknown and !before.resolved and hasImages(event.request_ready));
            try std.testing.expect(after.resolved and after.pending != null);
        },

        .notify_catalog_down => {
            const request = decided orelse return error.TestUnexpectedResult;
            try std.testing.expect(effects.len == 2 and withholdsUnknown(effects[1].send));
            try std.testing.expect(request.catalog_down and !before.notified and after.notified);
        },
        .send => |chosen| {
            const request = decided orelse return error.TestUnexpectedResult;

            try std.testing.expect(after.pending == null);

            try std.testing.expectEqual(after.support == .native, chosen.route == .native);
            const kinds = [_]struct { bool, ToolImages }{
                .{ request.tool_images, chosen.tool_images },
                .{ request.earlier_images, chosen.earlier_images },
            };
            for (kinds) |kind| {
                const present, const images = kind;

                try std.testing.expectEqual(present, images != .none);

                switch (images) {
                    .none => {},
                    .attached => try std.testing.expectEqual(Support.native, after.support),
                    .withheld_unknown => try std.testing.expect(after.support == .unknown and after.resolved),
                    .withheld_fallback => try std.testing.expect(after.support == .non_native and chosen.route == .fallback),
                    .withheld_dead_end => try std.testing.expect(after.support == .non_native and chosen.route == .unavailable),
                }
            }

            try std.testing.expectEqual(chosen.route == .fallback, chosen.mode != .unavailable);
            if (chosen.route == .fallback) try std.testing.expectEqual(request.pending_images, chosen.mode == .required);

            if (request.user_images) try std.testing.expect(chosen.route != .unavailable);
        },
        .fail => |reason| {
            const request = decided orelse return error.TestUnexpectedResult;
            try std.testing.expect(after.pending == null);

            try std.testing.expect(request.user_images);
            switch (reason) {
                .capability_unknown => try std.testing.expect(after.support == .unknown and after.resolved),
                .no_native_image => try std.testing.expect(after.support == .non_native and !request.fallback),
            }
        },
    };
    switch (event) {
        .turn_started => try std.testing.expect(effects.len == 0 and !after.resolved and !after.notified and after.pending == null),

        .request_ready => try std.testing.expectEqual(before.pending != null, effects.len == 0),

        .capabilities_resolved => if (before.pending == null) {
            try std.testing.expectEqual(@as(usize, 0), effects.len);
            try std.testing.expectEqualDeep(before, after);
        },
    }
}

const FuzzDraws = struct {
    smith: *std.testing.Smith,

    fn below(self: FuzzDraws, n: usize, site: u32) usize {
        return self.smith.indexWithHash(n, site);
    }

    fn flag(self: FuzzDraws, site: u32) bool {
        return self.smith.valueWithHash(bool, site);
    }
};

const SeededDraws = struct {
    random: std.Random,

    fn below(self: SeededDraws, n: usize, _: u32) usize {
        return self.random.uintLessThan(usize, n);
    }

    fn flag(self: SeededDraws, _: u32) bool {
        return self.random.boolean();
    }
};

fn driveCore(draws: anytype) !void {
    var state: State = .{};
    const steps = 1 + draws.below(64, 1);
    for (0..steps) |_| {
        const event: Event = switch (draws.below(4, 2)) {
            0 => .{ .turn_started = all_support[draws.below(all_support.len, 3)] },
            1 => ready: {
                const user_images = draws.flag(4);
                const earlier_images = draws.flag(5);

                const pending_images = user_images and draws.flag(6);
                break :ready .{ .request_ready = .{
                    .user_images = user_images,
                    .earlier_images = earlier_images,
                    .pending_images = pending_images,
                    .tool_images = draws.flag(7),
                    .fallback = draws.flag(8),
                    .catalog_down = draws.flag(9),
                } };
            },
            2 => .{ .capabilities_resolved = all_support[draws.below(all_support.len, 10)] },
            else => {
                state = .{};
                continue;
            },
        };
        const out = step(state, event);
        try expectLaws(state, event, out);
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

test "the core keeps the model's laws on arbitrary event sequences" {
    try std.testing.fuzz({}, fuzzCore, .{
        .corpus = &(.{
            comptime corpusOf(&.{ 2, 0, 0, 1, 0, 1, 0, 1, 1, 2, 0 }),

            comptime corpusOf(&.{ 2, 0, 0, 1, 1, 1, 1, 0, 1, 1, 2, 0 }),
        } ++ @import("fuzz_corpus").image_route.*),
    });
}

test "the core keeps the model's laws on seeded random event sequences" {
    var prng: std.Random.DefaultPrng = .init(20261022);
    for (0..4000) |_| try driveCore(SeededDraws{ .random = prng.random() });
}
