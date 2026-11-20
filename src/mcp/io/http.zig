const std = @import("std");
const Io = std.Io;
const lines = @import("lines.zig");
const Bell = @import("bell.zig").Bell;
const sse = @import("../protocol/sse.zig");
const http_headers = @import("../protocol/http_headers.zig");
const wire = @import("../protocol/wire.zig");
const Budget = @import("budget.zig").Budget;
const Read = @import("budget.zig").Read;

pub const Options = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
    max_message: usize = 16 * 1024 * 1024,
    max_in_flight: usize = 32,
    bell: ?*Bell = null,
    max_idle_ms: u32 = 60_000,
};

pub const Method = enum { post, get, delete };

pub const Ending = enum {
    complete,
    accepted,
    http_failure,
    broken,
    too_large,
    rejected,
    refused,
};

pub const Incoming = union(enum) {
    message: struct { key: u64, status: u16, bytes: []const u8, message: wire.Message, event_id: ?[]const u8, retry_ms: ?u32 },
    mark: struct { key: u64, event_id: ?[]const u8, retry_ms: ?u32 },
    session: struct { key: u64, id: []const u8 },
    endpoint: struct { key: u64, url: []const u8 },
    opened: u64,
    ended: struct { key: u64, status: u16, how: Ending, challenge: ?[]const u8 },
    fetched: struct { key: u64, status: u16, body: []const u8, location: ?[]const u8, media: []const u8, challenge: ?[]const u8 },
    timeout,
};

pub const Error = error{ InvalidUrl, TooManyInFlight, ConcurrencyUnavailable } || std.mem.Allocator.Error || Io.Cancelable;

const Posted = union(enum) {
    event: struct { key: u64, status: u16, data: ?[]u8, event_id: ?[]u8, retry_ms: ?u32 },
    session: struct { key: u64, id: []u8 },
    endpoint: struct { key: u64, url: []u8 },
    opened: u64,
    ended: struct { key: u64, status: u16, how: Ending, challenge: ?[]u8 = null },
    fetched: struct { key: u64, status: u16 = 0, body: ?[]u8 = null, location: ?[]u8 = null, media: ?[]u8 = null, challenge: ?[]u8 = null },

    fn free(p: Posted, gpa: std.mem.Allocator) void {
        switch (p) {
            .event => |e| {
                if (e.data) |d| gpa.free(d);
                if (e.event_id) |i| gpa.free(i);
            },
            .session => |s| gpa.free(s.id),
            .endpoint => |e| gpa.free(e.url),
            .ended => |e| if (e.challenge) |c| gpa.free(c),
            .fetched => |f| {
                if (f.body) |b| gpa.free(b);
                if (f.location) |l| gpa.free(l);
                if (f.media) |m| gpa.free(m);
                if (f.challenge) |c| gpa.free(c);
            },
            .opened => {},
        }
    }
};

const waiting_room = 32;
const exit_read_wait_ms: i64 = 500;

var bounded_streams_open: std.atomic.Value(u32) = .init(0);

pub fn readBoundedStreamsToTheirEndForExit(io: Io) void {
    const started = now(io);
    while (bounded_streams_open.load(.acquire) != 0 and now(io) - started < exit_read_wait_ms) {
        Io.sleep(io, .fromMilliseconds(1), .awake) catch return;
    }
}
const finish_wait_ms: i64 = 2_000;

const Slot = struct {
    state: enum { free, waiting, running, finishing } = .free,
    key: u64 = 0,
    order: u64 = 0,
    arena: std.heap.ArenaAllocator,
    future: Io.Future(void) = undefined,
    ends_by_itself: std.atomic.Value(bool) = .init(false),
    finishing_since_ms: i64 = 0,
    method: Method = .post,
    body: ?[]u8 = null,
    headers: []std.http.Header = &.{},
    fetch: ?struct { uri: std.Uri, content_type: []u8 } = null,
    uri: ?std.Uri = null,
};

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    options: Options,
    uri: std.Uri,
    http: std.http.Client,
    queue: Io.Queue(Posted),
    queue_buffer: [64]Posted = undefined,
    slots: []Slot,
    running: usize = 0,
    sent: u64 = 0,
    own: Bell = undefined,
    held: ?Posted = null,
    budget: Budget,
    last_used_ms: i64 = 0,
    used_lock: Io.Mutex = .init,

    pub fn init(c: *Client, io: Io, gpa: std.mem.Allocator, options: Options) Error!void {
        const slots = try gpa.alloc(Slot, options.max_in_flight + waiting_room);
        for (slots) |*s| s.* = .{ .arena = .init(gpa) };
        c.* = .{
            .io = io,
            .gpa = gpa,
            .options = options,
            .uri = std.Uri.parse(options.url) catch {
                gpa.free(slots);
                return error.InvalidUrl;
            },
            .http = .{ .allocator = gpa, .io = io },
            .queue = undefined,
            .slots = slots,
            .budget = .{ .max = options.max_message },
        };
        c.queue = .init(&c.queue_buffer);
        c.own.init(io);
    }

    fn finishingInTime(c: *Client) bool {
        const at = now(c.io);
        for (c.slots) |*s| {
            if (s.state == .finishing and at - s.finishing_since_ms <= finish_wait_ms) return true;
        }
        return false;
    }

    fn readFinishingToTheirEnd(c: *Client) void {
        while (c.finishingInTime()) {
            var posted: [1]Posted = undefined;
            while ((c.queue.get(c.io, &posted, 0) catch 0) == 1) {
                switch (posted[0]) {
                    .ended => |e| _ = c.settleFinished(e.key),
                    else => {},
                }
                posted[0].free(c.gpa);
            }
            Io.sleep(c.io, .fromMilliseconds(2), .awake) catch return;
        }
    }

    pub fn deinit(c: *Client) void {
        c.readFinishingToTheirEnd();
        for (c.slots) |*s| {
            if (s.state == .running or s.state == .finishing) s.future.cancel(c.io);
            s.arena.deinit();
        }
        c.release();

        var leftover: [1]Posted = undefined;
        while ((c.queue.get(c.io, &leftover, 0) catch 0) == 1) leftover[0].free(c.gpa);
        c.http.deinit();
        c.gpa.free(c.slots);
        c.budget.deinit(c.gpa);
    }

    pub fn send(c: *Client, key: u64, method: Method, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        try c.sendTo(key, method, null, body, headers);
    }

    pub fn sendTo(c: *Client, key: u64, method: Method, url: ?[]const u8, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        const slot = try c.claim(key, method);
        errdefer slot.state = .free;
        const a = slot.arena.allocator();
        const all = try a.alloc(std.http.Header, headers.len + c.options.headers.len);
        for (headers, 0..) |h, i| all[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        @memcpy(all[headers.len..], c.options.headers);
        slot.headers = all;
        slot.body = if (body) |b| try a.dupe(u8, b) else null;
        if (url) |u| slot.uri = std.Uri.parse(try a.dupe(u8, u)) catch return error.InvalidUrl;
        if (c.running < c.options.max_in_flight) try c.start(slot);
    }

    pub fn fetch(c: *Client, key: u64, method: Method, url: []const u8, body: ?[]const u8, content_type: []const u8, headers: []const std.http.Header) Error!void {
        const slot = try c.claim(key, method);
        errdefer slot.state = .free;
        const a = slot.arena.allocator();
        const uri = std.Uri.parse(try a.dupe(u8, url)) catch return error.InvalidUrl;
        const all = try a.alloc(std.http.Header, headers.len);
        for (headers, all) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        slot.headers = all;
        slot.body = if (body) |b| try a.dupe(u8, b) else null;
        slot.fetch = .{ .uri = uri, .content_type = try a.dupe(u8, content_type) };
        if (c.running < c.options.max_in_flight) try c.start(slot);
    }

    fn claim(c: *Client, key: u64, method: Method) Error!*Slot {
        const slot = for (c.slots) |*s| {
            if (s.state == .free) break s;
        } else return error.TooManyInFlight;
        _ = slot.arena.reset(.retain_capacity);
        c.sent += 1;
        slot.* = .{ .state = .waiting, .key = key, .order = c.sent, .method = method, .arena = slot.arena };
        return slot;
    }

    fn start(c: *Client, slot: *Slot) error{ConcurrencyUnavailable}!void {
        slot.future = c.io.concurrent(task, .{ c, slot }) catch return error.ConcurrencyUnavailable;
        slot.state = .running;
        c.running += 1;
    }

    fn task(c: *Client, slot: *Slot) void {
        if (slot.fetch) |f|
            c.fetchTask(slot.key, slot.method, f.uri, slot.body, f.content_type, slot.headers)
        else
            c.exchange(slot.key, slot.method, slot.uri orelse c.uri, slot.body, slot.headers, &slot.ends_by_itself);
    }

    fn startWaiting(c: *Client) void {
        if (c.running >= c.options.max_in_flight) return;
        var oldest: ?*Slot = null;
        for (c.slots) |*s| {
            if (s.state == .waiting and (oldest == null or s.order < oldest.?.order)) oldest = s;
        }
        if (oldest) |s| c.start(s) catch {};
    }

    pub fn cancel(c: *Client, key: u64) void {
        for (c.slots) |*s| if ((s.state == .waiting or s.state == .running) and s.key == key) {
            if (s.state == .running) {
                s.future.cancel(c.io);
                c.running -= 1;
            }
            s.state = .free;
        };
        c.startWaiting();
    }

    pub fn finish(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.state == .running and s.key == key and s.ends_by_itself.load(.acquire)) {
            s.state = .finishing;
            s.finishing_since_ms = now(c.io);
        };
        c.cancel(key);
    }

    fn settleFinished(c: *Client, key: u64) bool {
        var settled = false;
        for (c.slots) |*s| if (s.state == .finishing and s.key == key) {
            s.future.await(c.io);
            s.state = .free;
            c.running -= 1;
            settled = true;
        };
        if (settled) c.startWaiting();
        return settled;
    }

    fn dropOverdueFinishing(c: *Client) void {
        const at = now(c.io);
        var dropped = false;
        for (c.slots) |*s| if (s.state == .finishing and at - s.finishing_since_ms > finish_wait_ms) {
            s.future.cancel(c.io);
            s.state = .free;
            c.running -= 1;
            dropped = true;
        };
        if (dropped) c.startWaiting();
    }

    pub fn next(c: *Client, timeout_ms: ?u32) Error!Incoming {
        const deadline = if (timeout_ms) |ms| now(c.io) + ms else null;
        while (true) {
            if (c.poll()) |incoming| return incoming;
            const left: ?u32 = if (deadline) |d| @intCast(@max(0, d - now(c.io))) else null;
            if (left == 0) return .timeout;
            try c.own.wait(left);
        }
    }

    pub fn poll(c: *Client) ?Incoming {
        c.release();
        c.dropOverdueFinishing();
        var one: [1]Posted = undefined;
        while ((c.queue.get(c.io, &one, 0) catch 0) == 1) {
            c.giveBack(one[0]);
            if (c.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    fn take(c: *Client, posted: Posted) ?Incoming {
        switch (posted) {
            .event => |e| {
                if (!c.inFlight(e.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.held = posted;
                if (e.data) |data| if (wire.decode(data)) |message| return .{ .message = .{
                    .key = e.key,
                    .status = e.status,
                    .bytes = data,
                    .message = message,
                    .event_id = e.event_id,
                    .retry_ms = e.retry_ms,
                } } else |_| {};
                if (e.event_id == null and e.retry_ms == null) {
                    c.release();
                    return null;
                }
                return .{ .mark = .{ .key = e.key, .event_id = e.event_id, .retry_ms = e.retry_ms } };
            },
            .session => |s| {
                if (!c.inFlight(s.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.held = posted;
                return .{ .session = .{ .key = s.key, .id = s.id } };
            },
            .endpoint => |e| {
                if (!c.inFlight(e.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.held = posted;
                return .{ .endpoint = .{ .key = e.key, .url = e.url } };
            },
            .opened => |key| {
                if (!c.inFlight(key)) return null;
                c.held = posted;
                return .{ .opened = key };
            },
            .ended => |e| {
                if (c.settleFinished(e.key) or !c.inFlight(e.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.settle(e.key);
                c.held = posted;
                return .{ .ended = .{ .key = e.key, .status = e.status, .how = e.how, .challenge = e.challenge } };
            },
            .fetched => |f| {
                if (!c.inFlight(f.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.settle(f.key);
                c.held = posted;
                return .{ .fetched = .{ .key = f.key, .status = f.status, .body = f.body orelse "", .location = f.location, .media = f.media orelse "", .challenge = f.challenge } };
            },
        }
    }

    fn settle(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.state == .running and s.key == key) {
            s.future.await(c.io);
            s.state = .free;
            c.running -= 1;
        };
        c.startWaiting();
    }

    fn inFlight(c: *const Client, key: u64) bool {
        for (c.slots) |s| if (s.state == .running and s.key == key) return true;
        return false;
    }

    fn release(c: *Client) void {
        if (c.held) |held| {
            var rest = held;

            switch (rest) {
                .event => |*e| if (e.data) |d| {
                    c.budget.recycle(c.io, c.gpa, d);
                    e.data = null;
                },
                else => {},
            }
            rest.free(c.gpa);
        }
        c.held = null;
    }

    fn giveBack(c: *Client, posted: Posted) void {
        switch (posted) {
            .event => |e| if (e.data) |d| c.budget.give(c.io, d.len),
            else => {},
        }
    }

    fn put(c: *Client, posted: Posted) Io.Cancelable!void {
        c.queue.putOne(c.io, posted) catch |err| {
            c.giveBack(posted);
            posted.free(c.gpa);
            return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => unreachable,
            };
        };
        c.own.ring();
        if (c.options.bell) |b| b.ring();
    }

    fn exchange(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, headers: []const std.http.Header, ends_by_itself: *std.atomic.Value(bool)) void {
        const ending = c.run(key, method, uri, body, headers, ends_by_itself) catch |err| switch (err) {
            error.Canceled => return,
        };
        c.put(.{ .ended = .{ .key = key, .status = ending.status, .how = ending.how, .challenge = ending.challenge } }) catch {};
    }

    const Result = struct { status: u16 = 0, how: Ending, challenge: ?[]u8 = null };

    const identity_only = blk: {
        var accept: @FieldType(std.http.Client.Request, "accept_encoding") = @splat(false);
        accept[@backingInt(std.http.ContentEncoding.identity)] = true;
        break :blk accept;
    };

    fn run(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, headers: []const std.http.Header, ends_by_itself: *std.atomic.Value(bool)) Io.Cancelable!Result {
        if (!http_headers.sendable(headers)) return .{ .how = .http_failure };
        defer _ = c.markUsed();
        var req = (try c.openSent(method, uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = "application/json" } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }, body)) orelse return .{ .how = .broken };
        defer req.deinit();
        var response = req.receiveHead(&.{}) catch |err| {
            if (req.connection) |connection| connection.closing = true;
            return .{ .how = if (err == error.HttpContentEncodingUnsupported) .http_failure else .broken };
        };
        const status: u16 = @backingInt(response.head.status);

        var challenge: std.ArrayList(u8) = .empty;
        defer challenge.deinit(c.gpa);
        var it = response.head.iterateHeaders();
        var session_seen = false;
        while (it.next()) |h| {
            if (!session_seen and std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) {
                session_seen = true;
                const id = c.gpa.dupe(u8, h.value) catch return .{ .status = status, .how = .broken };
                try c.put(.{ .session = .{ .key = key, .id = id } });
            } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                if (challenge.items.len > 0) challenge.appendSlice(c.gpa, ", ") catch return .{ .status = status, .how = .broken };
                challenge.appendSlice(c.gpa, h.value) catch return .{ .status = status, .how = .broken };
            }
        }
        if (status == 401 or (status == 403 and challenge.items.len > 0))
            return .{ .status = status, .how = .rejected, .challenge = challenge.toOwnedSlice(c.gpa) catch return .{ .status = status, .how = .broken } };
        if (status == 202) return .{ .status = status, .how = .accepted };
        const content_type = response.head.content_type orelse "";
        var transfer: [64]u8 = undefined;
        const reader = response.reader(&transfer);
        if (std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")) {
            const bounded = if (response.head.content_length) |declared| declared <= c.options.max_message else false;
            ends_by_itself.store(bounded, .release);
            if (bounded) _ = bounded_streams_open.fetchAdd(1, .acq_rel);
            defer if (bounded) {
                _ = bounded_streams_open.fetchSub(1, .acq_rel);
            };
            if (status / 100 == 2) try c.put(.{ .opened = key });
            return c.readEvents(key, status, reader, response.head.content_encoding != .identity);
        }

        if (!isJson(content_type)) return .{ .status = status, .how = if (status == 404 or status == 405) .refused else .http_failure };

        var read: Read = .{};
        var answer: std.ArrayList(u8) = .empty;
        defer {
            c.budget.drop(c.io, &read);
            answer.deinit(c.gpa);
        }
        c.readBody(reader, &read, &answer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.TooLong => return .{ .status = status, .how = .too_large },
            error.ReadFailed => return .{ .status = status, .how = if (response.head.content_encoding != .identity) .http_failure else .broken },
            error.OutOfMemory => return .{ .status = status, .how = .broken },
        };
        if (wire.decode(answer.items)) |message| {
            if (status / 100 != 2 and message == .response and message.response.body == .result)
                return .{ .status = status, .how = .http_failure };
            const len = answer.items.len;
            try c.budget.post(c.io, &read, len);
            const bytes = answer.toOwnedSlice(c.gpa) catch {
                c.budget.give(c.io, len);
                return .{ .status = status, .how = .broken };
            };
            try c.put(.{ .event = .{ .key = key, .status = status, .data = bytes, .event_id = null, .retry_ms = null } });
            return .{ .status = status, .how = .complete };
        } else |_| {
            return .{ .status = status, .how = .http_failure };
        }
    }

    fn openSent(c: *Client, method: Method, uri: std.Uri, options: std.http.Client.RequestOptions, body: ?[]u8) Io.Cancelable!?std.http.Client.Request {
        var fresh = false;
        while (true) {
            var with = options;
            with.connection = try c.takeKept(uri, fresh);
            var req = c.http.request(switch (method) {
                .post => .POST,
                .get => .GET,
                .delete => .DELETE,
            }, uri, with) catch {
                if (with.connection) |kept| c.http.connection_pool.release(kept, c.io);
                return null;
            };
            req.accept_encoding = identity_only;
            const sending = if (body) |b| send: {
                req.transfer_encoding = .{ .content_length = b.len };
                break :send req.sendBodyComplete(b);
            } else req.sendBodiless();
            sending catch {
                req.connection.?.closing = true;
                req.deinit();
                if (fresh) return null;
                fresh = true;
                continue;
            };
            return req;
        }
    }

    fn takeKept(c: *Client, uri: std.Uri, fresh: bool) Io.Cancelable!?*std.http.Client.Connection {
        if (c.http.http_proxy != null or c.http.https_proxy != null) return null;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        var host: [Io.net.HostName.max_len]u8 = undefined;
        const criteria: std.http.Client.ConnectionPool.Criteria = .{
            .host = Io.net.HostName.fromUri(uri, &host) catch return null,
            .port = uri.port orelse switch (protocol) {
                .plain => 80,
                .tls => 443,
            },
            .protocol = protocol,
        };
        const stale = fresh or c.markUsed() > c.options.max_idle_ms;
        const pool = &c.http.connection_pool;
        while (try pool.findConnection(c.io, criteria)) |kept| {
            if (!stale and !closedByServer(kept)) return kept;
            kept.closing = true;
            pool.release(kept, c.io);
        }
        return null;
    }

    fn markUsed(c: *Client) i64 {
        const at = now(c.io);
        c.used_lock.lockUncancelable(c.io);
        defer c.used_lock.unlock(c.io);
        const idle = at - c.last_used_ms;
        c.last_used_ms = at;
        return idle;
    }

    fn readBody(c: *Client, reader: *Io.Reader, read: *Read, body: *std.ArrayList(u8)) (Io.Cancelable || error{ TooLong, ReadFailed, OutOfMemory })!void {
        var adopted = false;
        while (true) {
            if (body.items.len == c.options.max_message) {
                _ = reader.peekByte() catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return error.ReadFailed,
                };
                return error.TooLong;
            }
            const step = @min(c.budget.allowance, c.options.max_message - body.items.len);
            try c.budget.grow(c.io, read, body.items.len + step);
            if (read.large and !adopted) {
                c.budget.adopt(c.io, c.gpa, body);
                adopted = true;
            }
            try body.ensureUnusedCapacity(c.gpa, step);
            const n = reader.readSliceShort(body.unusedCapacitySlice()[0..step]) catch return error.ReadFailed;
            body.items.len += n;
            if (n < step) return;
        }
    }

    fn fetchTask(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, content_type: []const u8, headers: []const std.http.Header) void {
        const got = c.fetchRun(key, method, uri, body, content_type, headers) catch |err| switch (err) {
            error.Canceled => return,
        };
        c.put(.{ .fetched = got }) catch {};
    }

    fn fetchRun(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, content_type: []const u8, headers: []const std.http.Header) Io.Cancelable!@FieldType(Posted, "fetched") {
        const none: @FieldType(Posted, "fetched") = .{ .key = key };
        if (!http_headers.sendable(headers)) return none;
        defer _ = c.markUsed();
        var req = (try c.openSent(method, uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = content_type } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }, body)) orelse return none;
        defer req.deinit();
        var response = req.receiveHead(&.{}) catch {
            if (req.connection) |connection| connection.closing = true;
            return none;
        };
        var got: @FieldType(Posted, "fetched") = .{ .key = key, .status = @backingInt(response.head.status) };
        var challenge: std.ArrayList(u8) = .empty;
        defer challenge.deinit(c.gpa);
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (got.location == null and std.ascii.eqlIgnoreCase(h.name, "location")) {
                got.location = c.gpa.dupe(u8, h.value) catch null;
            } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                if (challenge.items.len > 0) challenge.appendSlice(c.gpa, ", ") catch {};
                challenge.appendSlice(c.gpa, h.value) catch {};
            }
        }
        if (challenge.items.len > 0) got.challenge = challenge.toOwnedSlice(c.gpa) catch null;

        if (response.head.content_type) |media| got.media = c.gpa.dupe(u8, media) catch null;
        var transfer: [64]u8 = undefined;
        got.body = response.reader(&transfer).allocRemaining(c.gpa, .limited(1 << 20)) catch null;
        return got;
    }

    const Counter = struct {
        c: *Client,
        read: *Read,
        data: *std.ArrayList(u8),
        adopted: bool = false,

        pub fn grow(n: *Counter, held: usize) Io.Cancelable!void {
            if (held <= n.read.held) return;
            const step = n.c.budget.allowance;
            try n.c.budget.grow(n.c.io, n.read, @min(@divCeil(held, step) * step, n.c.options.max_message));
            if (n.read.large and !n.adopted) {
                n.c.budget.adopt(n.c.io, n.c.gpa, n.data);
                n.adopted = true;
            }
        }
    };

    fn readEvents(c: *Client, key: u64, status: u16, reader: *Io.Reader, encoded: bool) Io.Cancelable!Result {
        var parser: sse.Parser = .{};
        defer parser.deinit(c.gpa);

        var data: std.ArrayList(u8) = .empty;
        var read: Read = .{};
        var counter: Counter = .{ .c = c, .read = &read, .data = &data };
        defer {
            c.budget.drop(c.io, &read);
            data.deinit(c.gpa);
        }
        var stream: lines.SseLines = .{};
        while (true) {
            const mark = data.items.len;
            const got = stream.read(reader, c.gpa, &data, c.options.max_message, &counter) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.ReadFailed => return .{ .status = status, .how = if (encoded) .http_failure else .broken },
                error.OutOfMemory => return .{ .status = status, .how = .broken },
            };
            if (got.too_long) return .{ .status = status, .how = .too_large };
            const event = parser.line(c.gpa, &data, mark) catch return .{ .status = status, .how = .broken };
            if (event) |e| {
                if (std.mem.eql(u8, e.name orelse "", "endpoint")) {
                    const url = c.gpa.dupe(u8, e.data orelse "") catch return .{ .status = status, .how = .broken };
                    data.clearRetainingCapacity();
                    try c.put(.{ .endpoint = .{ .key = key, .url = url } });
                } else {
                    const event_id: ?[]u8 = if (e.id) |i| c.gpa.dupe(u8, i) catch return .{ .status = status, .how = .broken } else null;
                    var posted: ?[]u8 = null;
                    if (e.data != null and data.items.len > 0) {
                        const len = data.items.len;
                        c.budget.post(c.io, &read, len) catch |err| {
                            if (event_id) |i| c.gpa.free(i);
                            return err;
                        };
                        counter.adopted = false;
                        posted = data.toOwnedSlice(c.gpa) catch {
                            c.budget.give(c.io, len);
                            if (event_id) |i| c.gpa.free(i);
                            return .{ .status = status, .how = .broken };
                        };
                    } else data.clearRetainingCapacity();
                    if (posted != null or event_id != null or e.retry_ms != null)
                        try c.put(.{ .event = .{ .key = key, .status = status, .data = posted, .event_id = event_id, .retry_ms = e.retry_ms } });
                }
            }

            if (read.large and data.items.len == 0) {
                c.budget.drop(c.io, &read);
                data.clearAndFree(c.gpa);
                counter.adopted = false;
            }
            if (got.at_end) return .{ .status = status, .how = .complete };
        }
    }
};

test {
    std.testing.refAllDecls(Client);
}

fn now(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

fn closedByServer(kept: *std.http.Client.Connection) bool {
    if (kept.reader().bufferedLen() > 0 or kept.stream_reader.interface.bufferedLen() > 0) return true;
    var ready = [_]std.posix.pollfd{.{ .fd = kept.stream_reader.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&ready, 0) catch return true) > 0;
}

pub fn isJson(media: []const u8) bool {
    const end = std.mem.findScalar(u8, media, ';') orelse media.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, media[0..end], " \t"), "application/json");
}

const testing = std.testing;

test "only application/json, with or without parameters, is JSON" {
    for ([_][]const u8{ "application/json", "Application/JSON", "application/json; charset=utf-8", "application/json;charset=UTF-8" }) |m| try testing.expect(isJson(m));
    for ([_][]const u8{ "", "text/plain", "text/json", "application/json-rpc", "application/jsonx", "text/event-stream" }) |m| try testing.expect(!isJson(m));
}

test "a header that can't go out as it is never does, and the request ends refused" {
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp" });
    defer c.deinit();
    for ([_][]const u8{ "a\r\nb", "a\nInjected: yes" }, 1..) |value, key| {
        try c.send(key, .post, "{}", &.{.{ .name = "X-Team", .value = value }});
        try testing.expectEqual(Ending.http_failure, (try c.next(10_000)).ended.how);
    }
    try c.send(3, .post, "{}", &.{.{ .name = "X-Team", .value = "a b\tc" }});
    try testing.expectEqual(Ending.broken, (try c.next(10_000)).ended.how);

    try c.fetch(4, .post, "http://127.0.0.1:1/token", "x", "text/plain", &.{.{ .name = "X-Team", .value = "a\r\nb" }});
    try testing.expectEqual(@as(u16, 0), (try c.next(10_000)).fetched.status);
}

test "a request past the slots waits for one, oldest first, and one cancelled while it waits never goes out" {
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp", .max_in_flight = 1 });
    defer c.deinit();
    for (1..5) |key| try c.send(key, .post, "{}", &.{});
    c.cancel(3);
    for ([_]u64{ 1, 2, 4 }) |key| try testing.expectEqual(key, (try c.next(10_000)).ended.key);
    try testing.expect((try c.next(200)) == .timeout);

    try c.send(5, .post, "{}", &.{});
    try c.send(6, .post, "{}", &.{});
    c.cancel(5);
    try testing.expectEqual(@as(u64, 6), (try c.next(10_000)).ended.key);
}

test "a request's end wakes a timed wait at once, with or without a shared bell" {
    var shared: Bell = undefined;
    shared.init(testing.io);
    for ([_]?*Bell{ null, &shared }) |bell| {
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp", .bell = bell });
        defer c.deinit();
        const started = now(testing.io);
        try c.send(1, .post, "{}", &.{});
        try testing.expectEqual(Ending.broken, (try c.next(10_000)).ended.how);
        try testing.expect(now(testing.io) - started < 3_000);
    }
    try testing.expect(shared.rung);
}

fn serveEvents(server: *Io.net.Server, count: usize) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n");
    for (0..count) |_| try w.interface.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/n\"}\n\n");
    try w.interface.writeAll("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n");
    try w.interface.flush();
}

fn serveFixedLengthEvents(server: *Io.net.Server, answer: []const u8, rest: []const u8) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n", .{answer.len + rest.len});
    try w.interface.writeAll(answer);
    try w.interface.flush();
    try Io.sleep(testing.io, .fromMilliseconds(100), .awake);
    try w.interface.writeAll(rest);
    try w.interface.flush();
    try Io.sleep(testing.io, .fromMilliseconds(100), .awake);
    try w.interface.writeAll("HTTP/1.1 204 No Content\r\n\r\n");
    try w.interface.flush();
}

test "a fixed-length event stream finished after its answer is read to its declared end, not reset" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var rest: [1024]u8 = @splat(':');
    rest[rest.len - 1] = '\n';
    var serving = try testing.io.concurrent(serveFixedLengthEvents, .{ &server, "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n", &rest });
    var served = false;
    defer if (!served) {
        serving.cancel(testing.io) catch {};
    };
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}) });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    while (true) switch (try c.next(5_000)) {
        .message => break,
        .timeout => return error.TestTimeout,
        else => {},
    };
    c.finish(1);
    try testing.expectEqual(@as(usize, 1), c.running);
    const deadline = now(testing.io) + 5_000;
    while (c.running > 0) {
        if (now(testing.io) > deadline) return error.TestTimeout;
        try testing.expect((try c.next(50)) == .timeout);
    }
    served = true;
    try serving.await(testing.io);
}

fn serveUnsupportedEncoding(server: *Io.net.Server, body: []const u8) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-encoding: gzip\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n", .{body.len});
    try w.interface.writeAll(body);
    try w.interface.flush();
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

test "an answer in an encoding fx did not ask for ends as an HTTP failure at once, on a connection the server keeps open" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveUnsupportedEncoding, .{ &server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}" });
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}) });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    while (true) switch (try c.next(5_000)) {
        .ended => |e| {
            try testing.expectEqual(Ending.http_failure, e.how);
            break;
        },
        .timeout => return error.TestTimeout,
        else => {},
    };
}

fn serveRaw(server: *Io.net.Server, response: []const u8) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.writeAll(response);
    try w.interface.flush();
}

fn endedBy(response: []const u8) !struct { status: u16, how: Ending } {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveRaw, .{ &server, response });
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}) });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    while (true) switch (try c.next(5_000)) {
        .ended => |e| return .{ .status = e.status, .how = e.how },
        .timeout => return error.TestTimeout,
        else => {},
    };
}

test "a redirect answer is not followed and ends as an HTTP failure" {
    const got = try endedBy("HTTP/1.1 307 Temporary Redirect\r\nlocation: http://127.0.0.1:9/redirected\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
    try testing.expectEqual(@as(u16, 307), got.status);
    try testing.expectEqual(Ending.http_failure, got.how);
}

test "an error status answer with a JSON-RPC result ends as an HTTP failure, not complete" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const got = try endedBy("HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: " ++ std.fmt.comptimePrint("{d}", .{json.len}) ++ "\r\nconnection: close\r\n\r\n" ++ json);
    try testing.expectEqual(@as(u16, 503), got.status);
    try testing.expectEqual(Ending.http_failure, got.how);
}

test "a 404 or 405 answer that is not JSON-RPC ends as a refusal of the endpoint" {
    const not_found = try endedBy("HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\ncontent-length: 9\r\nconnection: close\r\n\r\nNot Found");
    try testing.expectEqual(@as(u16, 404), not_found.status);
    try testing.expectEqual(Ending.refused, not_found.how);
    const not_allowed = try endedBy("HTTP/1.1 405 Method Not Allowed\r\ncontent-type: text/plain\r\ncontent-length: 9\r\nconnection: close\r\n\r\nNot Found");
    try testing.expectEqual(@as(u16, 405), not_allowed.status);
    try testing.expectEqual(Ending.refused, not_allowed.how);
}

test "an answer whose media type is not application/json ends as an HTTP failure, even with a valid JSON-RPC body" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const got = try endedBy("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: " ++ std.fmt.comptimePrint("{d}", .{json.len}) ++ "\r\nconnection: close\r\n\r\n" ++ json);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqual(Ending.http_failure, got.how);
}

fn serveBody(server: *Io.net.Server, content_type: []const u8, body: []const u8) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: {s}\r\nconnection: close\r\n\r\n", .{content_type});
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "an answer over max_message ends too_large, not broken, in a JSON body and in an SSE event" {
    const pad: [200]u8 = @splat('x');
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"t\":\"" ++ pad ++ "\"}}";
    const Case = struct { content_type: []const u8, body: []const u8 };
    for ([_]Case{
        .{ .content_type = "application/json", .body = json },
        .{ .content_type = "text/event-stream", .body = "id: e1\ndata: " ++ json ++ "\n\n" },
    }) |case| {
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(testing.io, .{ .reuse_address = true });
        defer server.deinit(testing.io);
        var serving = try testing.io.concurrent(serveBody, .{ &server, case.content_type, case.body });
        defer serving.cancel(testing.io) catch {};
        var url: [64]u8 = undefined;
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 64 });
        defer c.deinit();
        try c.send(1, .post, "{}", &.{});
        while (true) switch (try c.next(5_000)) {
            .ended => |e| {
                try testing.expectEqual(Ending.too_large, e.how);
                break;
            },
            .timeout => return error.TestTimeout,
            else => {},
        };
    }
}

test "events past the budget all arrive, each once the one before it is taken" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveEvents, .{ &server, 6 });
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;

    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 64 });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    var notes: usize = 0;
    while (true) switch (try c.next(5_000)) {
        .message => |m| if (m.message == .notification) {
            notes += 1;
        },
        .ended => |e| {
            try testing.expectEqual(Ending.complete, e.how);
            break;
        },
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expectEqual(@as(usize, 6), notes);
    try testing.expect(c.budget.used <= 64);
}

const Peak = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(p: *Peak) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(p: *Peak, old: usize, new: usize) void {
        if (new >= old) {
            const total = p.live.fetchAdd(new - old, .monotonic) + new - old;
            _ = p.peak.fetchMax(total, .monotonic);
        } else _ = p.live.fetchSub(old - new, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const out = p.child.rawAlloc(len, a, ra) orelse return null;
        p.grew(0, len);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        if (!p.child.rawResize(memory, a, new_len, ra)) return false;
        p.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const out = p.child.rawRemap(memory, a, new_len, ra) orelse return null;
        p.grew(memory.len, new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, ra: usize) void {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        p.child.rawFree(memory, a, ra);
        p.grew(memory.len, 0);
    }
};

fn answerOne(stream: Io.net.Stream, size: usize, events: bool) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [4096]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    const head = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":\"";
    const tail = "\"}}";
    if (events) {
        try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n: one large event\ndata: ");
    } else {
        try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{size});
    }
    try w.interface.writeAll(head);
    try w.interface.splatByteAll('a', size - head.len - tail.len);
    try w.interface.writeAll(tail);
    if (events) try w.interface.writeAll("\n\n");
    try w.interface.flush();
}

fn serveAnswers(server: *Io.net.Server, count: usize, size: usize, events: bool) !void {
    var answering: [16]?Io.Future(@typeInfo(@TypeOf(answerOne)).@"fn".return_type.?) = @splat(null);
    defer for (&answering) |*a| if (a.*) |*f| f.cancel(testing.io) catch {};
    for (answering[0..count]) |*a| a.* = try testing.io.concurrent(answerOne, .{ try server.accept(testing.io), size, events });
    for (answering[0..count]) |*a| {
        try a.*.?.await(testing.io);
        a.* = null;
    }
}

fn manyLargeAnswers(events: bool) !void {
    const count = 16;
    const size = 200 * 1024;
    const max = 256 * 1024;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveAnswers, .{ &server, count, size, events });
    defer serving.cancel(testing.io) catch {};
    var peak: Peak = .{ .child = testing.allocator };
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, peak.allocator(), .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = max });
    defer c.deinit();
    c.budget.allowance = 4 * 1024;
    for (1..count + 1) |key| try c.send(key, .post, "{}", &.{});

    try Io.sleep(testing.io, .fromMilliseconds(500), .awake);
    var answers: usize = 0;
    var ended: usize = 0;
    while (ended < count) switch (try c.next(10_000)) {
        .message => |m| if (m.message == .response) {
            answers += 1;
        },
        .ended => |e| {
            try testing.expectEqual(Ending.complete, e.how);
            ended += 1;
        },
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expectEqual(@as(usize, count), answers);

    try testing.expect(peak.peak.load(.monotonic) < count * size / 2);
}

test "many large answers at once are read within the budget, one large read at a time" {
    try manyLargeAnswers(false);
}

test "many large events at once are read into one buffer each, within the budget" {
    try manyLargeAnswers(true);
}

fn hangAfterComment(stream: Io.net.Stream) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [4096]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n: ");
    try w.interface.splatByteAll('c', 20 * 1024);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

fn serveCommentThenEvent(server: *Io.net.Server) !void {
    var hanging = try testing.io.concurrent(hangAfterComment, .{try server.accept(testing.io)});
    defer hanging.cancel(testing.io) catch {};
    try answerOne(try server.accept(testing.io), 200 * 1024, true);

    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

test "a large comment doesn't keep the large read from the next large event" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveCommentThenEvent, .{&server});
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 256 * 1024 });
    defer c.deinit();
    c.budget.allowance = 4 * 1024;
    try c.send(1, .post, "{}", &.{});

    try Io.sleep(testing.io, .fromMilliseconds(200), .awake);
    try c.send(2, .post, "{}", &.{});
    while (true) switch (try c.next(5_000)) {
        .message => |m| if (m.message == .response) break,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

test "a timed wait starts no task, so it works where none can run" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var c: Client = undefined;
    try c.init(threaded.io(), testing.allocator, .{ .url = "http://127.0.0.1:1/mcp" });
    defer c.deinit();
    try testing.expect((try c.next(20)) == .timeout);
}

const Drop = enum { keep, reset, close };

fn readRequest(r: *Io.Reader) !void {
    const name = "content-length:";
    var length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (line.len <= 2) break;
        if (std.ascii.startsWithIgnoreCase(line, name)) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \r\n"), 10);
    }
    try r.discardAll(length);
}

fn answerKept(stream: Io.net.Stream, drop: Drop, requests: *std.atomic.Value(u32)) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    const answer = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    while (true) {
        readRequest(&r.interface) catch return Io.sleep(testing.io, .fromSeconds(30), .awake);
        _ = requests.fetchAdd(1, .monotonic);
        try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n", .{answer.len});
        try w.interface.writeAll(answer);
        try w.interface.flush();
        switch (drop) {
            .keep => {},
            .close => return,
            .reset => {
                try Io.sleep(testing.io, .fromMilliseconds(50), .awake);
                try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&std.posix.linger{ .onoff = 1, .linger = 0 }));
                return;
            },
        }
    }
}

fn serveKept(server: *Io.net.Server, drop: Drop, connections: *std.atomic.Value(u32), requests: *std.atomic.Value(u32)) !void {
    var answering: [4]?Io.Future(@typeInfo(@TypeOf(answerKept)).@"fn".return_type.?) = @splat(null);
    defer for (&answering) |*a| if (a.*) |*f| f.cancel(testing.io) catch {};
    for (&answering) |*a| {
        const stream = try server.accept(testing.io);
        _ = connections.fetchAdd(1, .monotonic);
        a.* = try testing.io.concurrent(answerKept, .{ stream, drop, requests });
    }
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

const Kept = struct {
    server: Io.net.Server,
    connections: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    serving: ?Io.Future(@typeInfo(@TypeOf(serveKept)).@"fn".return_type.?) = null,
    url_buffer: [64]u8 = undefined,
    url: []const u8 = "",

    fn start(k: *Kept, drop: Drop) !void {
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        k.* = .{ .server = try address.listen(testing.io, .{ .reuse_address = true }) };
        k.url = try std.mem.print(&k.url_buffer, "http://127.0.0.1:{d}/mcp", .{k.server.socket.address.getPort()});
        k.serving = try testing.io.concurrent(serveKept, .{ &k.server, drop, &k.connections, &k.requests });
    }

    fn stop(k: *Kept) void {
        if (k.serving) |*f| f.cancel(testing.io) catch {};
        k.server.deinit(testing.io);
    }
};

fn endingOf(c: *Client) !Ending {
    while (true) switch (try c.next(5_000)) {
        .ended => |e| return e.how,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

fn fetchedStatus(c: *Client) !u16 {
    while (true) switch (try c.next(5_000)) {
        .fetched => |f| return f.status,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

test "a kept connection the server reset or closed while idle isn't sent on again: each request goes out once, on a new one" {
    for ([_]Drop{ .reset, .close }) |drop| {
        var kept: Kept = undefined;
        try kept.start(drop);
        defer kept.stop();
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = kept.url });
        defer c.deinit();
        try c.send(1, .post, "{}", &.{});
        try testing.expectEqual(Ending.complete, try endingOf(&c));

        try Io.sleep(testing.io, .fromMilliseconds(300), .awake);
        try c.send(2, .post, "{}", &.{});
        try testing.expectEqual(Ending.complete, try endingOf(&c));
        try Io.sleep(testing.io, .fromMilliseconds(300), .awake);
        try c.fetch(3, .post, kept.url, "{}", "application/json", &.{});
        try testing.expectEqual(@as(u16, 200), try fetchedStatus(&c));
        try testing.expectEqual(@as(u32, 3), kept.connections.load(.monotonic));
        try testing.expectEqual(@as(u32, 3), kept.requests.load(.monotonic));
    }
}

test "a request whose send fails goes out once more, on a new connection, and reaches the server once" {
    var kept: Kept = undefined;
    try kept.start(.keep);
    defer kept.stop();
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = kept.url });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    try testing.expectEqual(Ending.complete, try endingOf(&c));

    const node = c.http.connection_pool.free.last orelse return error.TestUnexpectedResult;
    const connection: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
    try connection.stream_reader.stream.shutdown(testing.io, .send);
    try c.send(2, .post, "{}", &.{});
    try testing.expectEqual(Ending.complete, try endingOf(&c));
    try testing.expectEqual(@as(u32, 2), kept.connections.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), kept.requests.load(.monotonic));
}

test "a kept connection is used again, unless the client sat idle past max_idle_ms" {
    for ([_]u32{ 60_000, 0 }, [_]u32{ 1, 2 }) |max_idle_ms, connections| {
        var kept: Kept = undefined;
        try kept.start(.keep);
        defer kept.stop();
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = kept.url, .max_idle_ms = max_idle_ms });
        defer c.deinit();
        for (1..3) |key| {
            try c.send(key, .post, "{}", &.{});
            try testing.expectEqual(Ending.complete, try endingOf(&c));
            try Io.sleep(testing.io, .fromMilliseconds(20), .awake);
        }
        try testing.expectEqual(connections, kept.connections.load(.monotonic));
        try testing.expectEqual(@as(u32, 2), kept.requests.load(.monotonic));
    }
}
