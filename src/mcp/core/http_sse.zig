const std = @import("std");
const request = @import("request.zig");

pub const Id = request.Id;

pub const Phase = enum { start, awaiting, ready, failed, closed };

pub const max_pending = 64;

pub const Event = union(enum) {
    start,
    endpoint,
    bad_endpoint,
    send: Id,
    refused: Id,
    done: Id,
    message: ?Id,
    stream_ended,
    close,
};

pub const Effect = union(enum) {
    open_stream,
    ready,
    close_stream,
    failed,
    lost: Id,
    answer: Id,
    forward,
};

pub const StepError = error{ NotReady, TooManyRequests };

pub const max_effects = max_pending + 2;

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn push(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Session = struct {
    phase: Phase = .start,
    pending: [max_pending]Id = undefined,
    count: usize = 0,

    pub fn step(s: *Session, event: Event, out: *Output) StepError!void {
        out.* = .{};
        switch (event) {
            .start => switch (s.phase) {
                .start, .failed, .closed => {
                    s.phase = .awaiting;
                    out.push(.open_stream);
                },
                .awaiting, .ready => {},
            },
            .endpoint => if (s.phase == .awaiting) {
                s.phase = .ready;
                out.push(.ready);
            },
            .bad_endpoint => if (s.phase == .awaiting) s.fail(true, out),
            .send => |id| {
                if (s.phase != .ready) return error.NotReady;
                if (s.indexOf(id) != null) return;
                if (s.count == max_pending) return error.TooManyRequests;
                s.pending[s.count] = id;
                s.count += 1;
            },
            .refused => |id| if (s.take(id)) out.push(.{ .lost = id }),
            .done => |id| _ = s.take(id),
            .message => |id| switch (s.phase) {
                .awaiting => s.fail(true, out),
                .ready => if (id) |answered| {
                    if (s.take(answered)) out.push(.{ .answer = answered });
                } else out.push(.forward),
                .start, .failed, .closed => {},
            },
            .stream_ended => switch (s.phase) {
                .awaiting, .ready => s.fail(false, out),
                .start, .failed, .closed => {},
            },
            .close => switch (s.phase) {
                .awaiting, .ready => {
                    s.phase = .closed;
                    out.push(.close_stream);
                    s.loseAll(out);
                },
                .start, .failed, .closed => s.phase = .closed,
            },
        }
    }

    fn fail(s: *Session, close_stream: bool, out: *Output) void {
        s.phase = .failed;
        if (close_stream) out.push(.close_stream);
        s.loseAll(out);
        out.push(.failed);
    }

    fn loseAll(s: *Session, out: *Output) void {
        for (s.pending[0..s.count]) |id| out.push(.{ .lost = id });
        s.count = 0;
    }

    fn indexOf(s: *const Session, id: Id) ?usize {
        for (s.pending[0..s.count], 0..) |p, i| if (p == id) return i;
        return null;
    }

    fn take(s: *Session, id: Id) bool {
        const i = s.indexOf(id) orelse return false;
        s.count -= 1;
        s.pending[i] = s.pending[s.count];
        return true;
    }
};

pub const ResolveError = error{ InvalidEndpoint, CrossOrigin, OutOfMemory };

pub fn resolve(gpa: std.mem.Allocator, base: []const u8, endpoint: []const u8) ResolveError![]u8 {
    const url = try resolveAny(gpa, base, endpoint);
    errdefer gpa.free(url);
    const base_origin = originOf(base) orelse return error.InvalidEndpoint;
    const url_origin = originOf(url) orelse return error.InvalidEndpoint;
    if (!std.ascii.eqlIgnoreCase(base_origin, url_origin)) return error.CrossOrigin;
    return url;
}

fn originOf(url: []const u8) ?[]const u8 {
    const scheme = std.mem.find(u8, url, "://") orelse return null;
    const authority = url[scheme + 3 ..];
    return url[0 .. scheme + 3 + (std.mem.findAny(u8, authority, "/?#") orelse authority.len)];
}

fn resolveAny(gpa: std.mem.Allocator, base: []const u8, endpoint: []const u8) ResolveError![]u8 {
    if (endpoint.len == 0) return error.InvalidEndpoint;
    if (absolute(endpoint)) return gpa.dupe(u8, endpoint);

    const scheme = std.mem.find(u8, base, "://") orelse return error.InvalidEndpoint;
    const authority = base[scheme + 3 ..];
    const origin_len = scheme + 3 + (std.mem.findAny(u8, authority, "/?#") orelse authority.len);
    const origin = base[0..origin_len];
    const after_origin = base[origin_len..];
    const path = after_origin[0 .. std.mem.findAny(u8, after_origin, "?#") orelse after_origin.len];

    if (std.mem.startsWith(u8, endpoint, "//")) return joined(gpa, &.{ base[0 .. scheme + 1], endpoint });
    if (endpoint[0] == '/') return joined(gpa, &.{ origin, endpoint });
    if (endpoint[0] == '?') return joined(gpa, &.{ origin, path, endpoint });

    var dir_len: usize = 0;
    for (path, 0..) |c, i| if (c == '/') {
        dir_len = i + 1;
    };
    const dir = if (path.len == 0) "/" else path[0..dir_len];
    return joined(gpa, &.{ origin, dir, endpoint });
}

fn absolute(endpoint: []const u8) bool {
    const colon = std.mem.find(u8, endpoint, "://") orelse return false;
    return colon > 0 and std.mem.findAny(u8, endpoint[0..colon], "/?#") == null;
}

fn joined(gpa: std.mem.Allocator, parts: []const []const u8) std.mem.Allocator.Error![]u8 {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    const out = try gpa.alloc(u8, len);
    var at: usize = 0;
    for (parts) |p| {
        @memcpy(out[at .. at + p.len], p);
        at += p.len;
    }
    return out;
}

const testing = std.testing;

test "a relative endpoint resolves against the server URL and a same-origin absolute one is kept" {
    const base = "https://mcp.example/a/sse?x=1";
    const Case = struct { endpoint: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .endpoint = "/messages?session=1", .want = "https://mcp.example/messages?session=1" },
        .{ .endpoint = "messages?session=1", .want = "https://mcp.example/a/messages?session=1" },
        .{ .endpoint = "?session=2", .want = "https://mcp.example/a/sse?session=2" },
        .{ .endpoint = "https://mcp.example/m", .want = "https://mcp.example/m" },
    }) |c| {
        const got = try resolve(testing.allocator, base, c.endpoint);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    try testing.expectError(error.CrossOrigin, resolve(testing.allocator, base, "//cdn.example/post"));
    try testing.expectError(error.CrossOrigin, resolve(testing.allocator, base, "https://other.example/m"));
    try testing.expectError(error.CrossOrigin, resolve(testing.allocator, base, "http://mcp.example/m"));
    try testing.expectError(error.InvalidEndpoint, resolve(testing.allocator, "mcp.example/sse", "/m"));
    try testing.expectError(error.InvalidEndpoint, resolve(testing.allocator, base, ""));
}

test "a request cannot be posted before the endpoint event arrives" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try testing.expectEqualSlices(Effect, &.{.open_stream}, out.effects());
    try testing.expectError(error.NotReady, s.step(.{ .send = 1 }, &out));
    try s.step(.endpoint, &out);
    try testing.expectEqualSlices(Effect, &.{.ready}, out.effects());
    try s.step(.{ .send = 1 }, &out);
    try testing.expectEqual(@as(usize, 1), s.count);
}

test "a message before the endpoint event fails the link and closes the stream" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try s.step(.{ .message = null }, &out);
    try testing.expectEqualSlices(Effect, &.{ .close_stream, .failed }, out.effects());
    try testing.expectEqual(Phase.failed, s.phase);
}

test "an answer ends the pending request with the matching id; an unmatched id is ignored" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try s.step(.endpoint, &out);
    try s.step(.{ .send = 1 }, &out);
    try s.step(.{ .send = 2 }, &out);
    try s.step(.{ .message = 7 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    try s.step(.{ .message = 2 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .answer = 2 }}, out.effects());
    try s.step(.{ .message = 2 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    try s.step(.{ .message = null }, &out);
    try testing.expectEqualSlices(Effect, &.{.forward}, out.effects());
    try testing.expectEqual(@as(usize, 1), s.count);
}

test "a stream that ends before an answer loses the pending requests by id and fails the link" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try s.step(.endpoint, &out);
    try s.step(.{ .send = 1 }, &out);
    try s.step(.{ .send = 2 }, &out);
    try s.step(.{ .message = 1 }, &out);
    try s.step(.stream_ended, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .lost = 2 }, .failed }, out.effects());
    try testing.expectEqual(Phase.failed, s.phase);
    try testing.expectEqual(@as(usize, 0), s.count);
}

test "a refused POST loses only its own request" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try s.step(.endpoint, &out);
    try s.step(.{ .send = 1 }, &out);
    try s.step(.{ .send = 2 }, &out);
    try s.step(.{ .refused = 1 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .lost = 1 }}, out.effects());
    try testing.expectEqual(@as(usize, 1), s.count);
    try s.step(.{ .refused = 9 }, &out);
    try testing.expectEqual(@as(usize, 0), out.effects().len);
}

test "closing the link loses what is pending, and a later start opens a new stream" {
    var s: Session = .{};
    var out: Output = .{};
    try s.step(.start, &out);
    try s.step(.endpoint, &out);
    try s.step(.{ .send = 5 }, &out);
    try s.step(.close, &out);
    try testing.expectEqualSlices(Effect, &.{ .close_stream, .{ .lost = 5 } }, out.effects());
    try testing.expectEqual(Phase.closed, s.phase);
    try s.step(.start, &out);
    try testing.expectEqualSlices(Effect, &.{.open_stream}, out.effects());
    try testing.expectEqual(Phase.awaiting, s.phase);
}
