const std = @import("std");
const era = @import("core/era.zig");
const catalog = @import("core/catalog.zig");
const request = @import("core/request.zig");
const http_modern = @import("core/http_modern.zig");
const http_legacy = @import("core/http_legacy.zig");
const http_sse = @import("core/http_sse.zig");
const mrtr_core = @import("core/mrtr.zig");
const mrtr = @import("protocol/mrtr.zig");
const http = @import("io/http.zig");
const process = @import("io/process.zig");
const stdio_conn = @import("core/stdio_conn.zig");
const http_headers = @import("protocol/http_headers.zig");
const tools = @import("protocol/tools.zig");
const resources = @import("protocol/resources.zig");
const trace = @import("io/trace.zig");
const wire = @import("protocol/wire.zig");
const auth_client = @import("auth/client.zig");
const oauth = @import("auth/oauth.zig");
const elicitation = @import("protocol/elicitation.zig");
const elicit_core = @import("core/elicitation.zig");
const auth_core = @import("core/auth.zig");
const subscription = @import("core/subscription.zig");
const subscriptions = @import("protocol/subscriptions.zig");

const excerpt_max = 80;
const note_max = 160;

fn excerptOf(comptime max: usize, buf: *[max + 3]u8, line: []const u8) []const u8 {
    const n = process.maskedPrefix(buf[0..max], line).len;
    if (n == line.len) return buf[0..n];
    @memcpy(buf[n..][0..3], "...");
    return buf[0 .. n + 3];
}

pub const Link = union(enum) {
    http: http.Options,
    sse: http.Options,
    stdio: process.Options,
};

const sse_legacy = [_][]const u8{"2024-11-05"};

pub const Options = struct {
    link: Link,
    client: era.Client,
    era: era.Config = .{},
    catalog: catalog.Config = .{},
    exchange: http_modern.Config = .{},
    session: http_legacy.Config = .{},
    mrtr: mrtr_core.Config = .{},
    auth: auth_client.Options = .{},
    listen_tools: bool = false,
    subscription: subscription.Config = .{},
    timeouts: request.Timeouts = .{},
    listen_wait_ms: u32 = 1000,
    trace: ?*trace.Writer = null,
};

pub const Handle = u32;

pub const Failure = union(enum) {
    era: era.Failure,
    session,
    initialized_timed_out,
    needs_auth,
    auth_unavailable,
};

pub const CallOutcome = enum { result, failure, lost, http_failure, cancelled, rounds_exceeded, unsupported_input, malformed, needs_auth, auth_unavailable };

pub const Event = union(enum) {
    ready: []const u8,
    failed: Failure,
    tools: struct { ok: bool, fresh: bool, dropped: tools.Added = .{}, needs_auth: bool = false },
    tools_stale,
    called: struct { handle: Handle, outcome: CallOutcome, maybe_ran: bool, timed_out: bool, answer: ?tools.Call, oversized: bool = false },
    resource: struct { handle: Handle, outcome: CallOutcome, answer: ?resources.Answer },
    progress: struct { handle: Handle, progress: f64, total: ?f64, message: ?[]const u8 },
    input: struct { handle: Handle, requests: []const mrtr.Request },
    auth_required: struct { step_up: bool, refused: ?oauth.Refusal = null },
    authorize: []const u8,
    signed_in,
    sign_in_failed: struct { why: auth_client.Failure, message: ?[]const u8 },
    refresh_due,
    refresh_ended,
    listening: subscription.Filter,
    listen_ended: subscription.End,
    elicit: struct { id: elicit_core.Id, params: []const u8, required: bool },
    elicit_withdrawn: u8,
    elicitation_complete: u8,
    down,
    credential,
    timeout,
};

pub const Error = http.Error || process.Error || std.mem.Allocator.Error || wire.EncodeError || std.Io.Writer.Error || auth_client.Error ||
    error{ NotReady, TooManyRequests, UnknownCall, InvalidInputResponses, UnknownElicitation, InvalidAnswer };

const What = union(enum) { discover: u8, initialize, list, call, listen, resource: resources.Op };

const Logical = struct {
    used: bool = false,
    handle: Handle = 0,
    what: What = .list,
    exchange: http_modern.Exchange = undefined,
    id: ?request.Id = null,
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "",
    arguments: ?[]const u8 = null,
    timed_out: bool = false,
    instance: []const u8 = "",
    last_event_id: ?[]const u8 = null,
    chain: mrtr_core.Chain = .init(.{}),
    round: mrtr.Round = .{},
    answers: []const []const u8 = &.{},
    chain_instance: []const u8 = "",
    needs_auth: bool = false,
    unrenewed: bool = false,
    sub: u8 = 0,
    filter: subscription.Filter = 0,
    listen_id: request.Id = 0,
    resend: bool = false,
};

const Kept = struct {
    key: u64,
    method: http.Method,
    body: ?[]const u8,
    headers: []std.http.Header,
    arena: std.heap.ArenaAllocator,
};

const Timer = struct {
    kind: union(enum) { request: request.Timer, probe: u32, expiry: catalog.Generation, resume_stream: request.Id, listen, listen_wait, backoff: Handle, relisten: struct { sub: u8, generation: u32 }, initialized: u64, refresh: u64 },
    due_ms: i64,
};

const Held = struct { id: ?[]u8 = null, eid: ?[]u8 = null, params: []u8 = &.{} };

const aux_base: u64 = 1 << 62;

const url_elicitation_required: i64 = -32042;

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    client: http.Client,
    proc: process.Process,
    stdio: bool,
    era_generation: stdio_conn.Generation = 0,
    start_due_ms: i64 = 0,
    refresh_timed: u64 = 0,
    catalog_generation: stdio_conn.Generation = 0,
    start_pending: bool = false,
    table: request.Table,
    table_slots: [64]request.Slot = undefined,
    detector: era.Detector,
    catalog: catalog.Catalog,
    store: tools.Store = .{},
    logicals: [32]Logical = undefined,
    next_handle: Handle = 1,
    timers: std.ArrayList(Timer) = .empty,
    events: [16 + 2 * elicit_core.max_pending]Event = undefined,
    event_count: usize = 0,
    held_answer: ?tools.Call = null,
    held_resource: ?resources.Answer = null,
    losing_oversized: bool = false,
    refused_reply: [512]u8 = undefined,
    stray: [excerpt_max + 3]u8 = undefined,
    stray_len: u8 = 0,
    note: [note_max + 3]u8 = undefined,
    last_added: tools.Added = .{},

    legacy: ?http_legacy.Session = null,
    legacy_slots: [32]http_legacy.Request = undefined,
    session_id: ?[]u8 = null,
    incoming_session: ?[]u8 = null,
    bad_session: bool = false,
    legacy_version: u8 = 0,
    instructions: ?[]const u8 = null,
    listen_key: ?u64 = null,
    listen_last_event_id: ?[]u8 = null,
    delete_key: ?u64 = null,
    next_aux: u64 = aux_base,
    initialized_key: ?u64 = null,
    held_sends: std.ArrayList(http_legacy.Effect) = .empty,
    first_listen: bool = true,
    listen_pending: bool = false,
    sse_link: bool = false,
    sse: http_sse.Session = .{},
    sse_stream: ?u64 = null,
    sse_endpoint: ?[]u8 = null,

    auth: auth_client.Auth = undefined,
    outbox: std.ArrayList(Kept) = .empty,
    page_needs_auth: bool = false,
    era_instance: []const u8 = "remote",
    era_run: u32 = 1,
    era_instance_buf: [24]u8 = undefined,

    subs: subscription.Table = undefined,

    elicit: elicit_core.Table = undefined,
    elicit_held: [elicit_core.max_pending]Held = @splat(.{}),

    pub fn init(r: *Server, io: std.Io, gpa: std.mem.Allocator, given: Options) Error!void {
        var options = given;
        if (options.link == .sse) options.era.legacy = &sse_legacy;
        r.* = .{
            .io = io,
            .gpa = gpa,
            .options = options,
            .client = undefined,
            .proc = undefined,
            .stdio = options.link == .stdio,
            .sse_link = options.link == .sse,
            .table = undefined,
            .detector = .init(options.era),
            .catalog = .init(options.catalog),
            .subs = undefined,
            .elicit = .init(elicitation.declared(options.client.capabilities)),
        };
        var subs = options.subscription;
        subs.stdio = r.stdio;
        r.subs = .init(subs);
        r.table = .init(&r.table_slots, options.timeouts);
        for (&r.logicals) |*l| l.* = .{ .arena = .init(gpa) };
        switch (options.link) {
            .http, .sse => |h| {
                try r.client.init(io, gpa, h);
                r.auth = .init(io, gpa, &r.client, h.url, options.auth, trace.on(options.trace));
                if (options.auth.saved) |saved| _ = try r.auth.restore(saved);
            },
            .stdio => |o| {
                var po = o;
                po.config.max_attempts = std.math.maxInt(u8);
                po.config.backoff_ms = 0;
                r.proc.init(io, gpa, po);
            },
        }
    }

    pub fn deinit(r: *Server) void {
        if (r.instructions) |text| r.gpa.free(text);
        if (r.stdio) r.proc.deinit() else {
            r.client.deinit();
            r.auth.deinit();
        }
        for (r.outbox.items) |*k| k.arena.deinit();
        r.outbox.deinit(r.gpa);
        for (&r.logicals) |*l| l.arena.deinit();
        r.timers.deinit(r.gpa);
        r.held_sends.deinit(r.gpa);
        r.store.deinit(r.gpa);
        for ([_]?[]u8{ r.session_id, r.incoming_session, r.listen_last_event_id, r.sse_endpoint }) |s| if (s) |v| r.gpa.free(v);
        for (&r.elicit_held) |*h| {
            r.forget(h);
            r.gpa.free(h.params);
        }
    }

    pub fn toolList(r: *const Server) *const tools.List {
        return &r.store.current;
    }

    pub fn detect(r: *Server) Error!void {
        try r.stepEra(.process_started);
        try r.stepEra(.detect_requested);
    }

    pub fn connect(r: *Server) Error!void {
        if (r.sse_link) {
            if (r.detector.state != .unknown) try r.reset();
            return r.stepSse(.start);
        }
        if (!r.stdio) {
            if (r.detector.state != .unknown) try r.reset();
            return r.detect();
        }
        switch (r.proc.conn.state) {
            .idle, .stopped => try r.proc.start(),
            .failed => {
                try r.proc.reconnect();
                try r.proc.start();
            },
            else => {
                r.start_pending = true;
                return r.processUp();
            },
        }
        try r.started();
    }

    pub fn exitStatus(r: *Server) ?process.Exit {
        return if (r.stdio) r.proc.exitStatus() else null;
    }

    pub fn strayLine(r: *const Server) ?[]const u8 {
        return if (r.stray_len == 0) null else r.stray[0..r.stray_len];
    }

    pub fn stderrTail(r: *Server, out: *[process.tail_max]u8) ?[]const u8 {
        if (!r.stdio) return null;
        const tail = r.proc.stderrTail(out);
        return if (tail.len == 0) null else tail;
    }

    fn keepStray(r: *Server, line: []const u8) void {
        r.stray_len = @intCast(excerptOf(excerpt_max, &r.stray, line).len);
    }

    pub fn spawnError(r: *const Server) ?anyerror {
        return if (r.stdio) r.proc.spawn_error else null;
    }

    pub fn reset(r: *Server) Error!void {
        r.start_pending = false;
        if (r.stdio) return r.proc.stop();

        try r.stepSubs(.{ .cancel = 0 });
        if (r.sse_link) try r.stepSse(.close);
        if (r.legacy != null) try r.stepLegacy(.close);
        for (&r.logicals) |*l| if (l.used) {
            if (l.id) |id| {
                try r.stepRequest(.{ .transport_lost = id });
                try r.closeKey(id, .forgotten);
            }
            l.used = false;
        };
        if (r.listen_key) |key| try r.closeKey(key, .forgotten);
        r.listen_key = null;
        r.timers.clearRetainingCapacity();
        r.held_sends.clearRetainingCapacity();

        if (r.initialized_key) |key| try r.closeKey(key, .forgotten);
        r.initialized_key = null;
        r.listen_pending = false;
        r.legacy = null;
        r.dropEndpoint();
        try r.endElicitations();
        r.newEraRun();
    }

    pub fn protocolVersion(r: *const Server) ?[]const u8 {
        if (!r.detector.ready()) return null;
        return era.versionName(r.detector.config, r.detector.version);
    }

    pub fn revoking(r: *const Server) bool {
        return !r.stdio and r.auth.revoking() != null;
    }

    pub fn saveCredential(r: *const Server, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        if (r.stdio) return false;
        return r.auth.save(w);
    }

    pub fn stopping(r: *const Server) bool {
        if (!r.stdio) return false;
        return switch (r.proc.conn.state) {
            .closing, .terminating, .killing => true,
            else => false,
        };
    }

    pub fn waiting(r: *const Server) bool {
        return r.subs.waiting();
    }

    pub fn dueMs(r: *const Server) ?i64 {
        var due: ?i64 = null;
        for (r.timers.items) |t| due = @min(due orelse t.due_ms, t.due_ms);
        return due;
    }

    pub fn needTools(r: *Server) Error!void {
        try r.stepCatalog(.need);
    }

    pub fn call(r: *Server, name: []const u8, arguments: ?[]const u8) Error!Handle {
        if (!r.detector.ready()) return error.NotReady;
        const l = try r.newLogical(.call, .call);
        const a = l.arena.allocator();
        l.name = try a.dupe(u8, name);
        l.arguments = if (arguments) |args| try a.dupe(u8, args) else null;
        try r.start(l);
        return l.handle;
    }

    pub fn resource(r: *Server, op: resources.Op) Error!Handle {
        if (!r.detector.ready()) return error.NotReady;
        const l = try r.newLogical(.list, .idempotent);
        l.what = .{ .resource = try op.dupe(l.arena.allocator()) };
        try r.start(l);
        return l.handle;
    }

    pub fn cancel(r: *Server, handle: Handle) Error!void {
        const l = r.logicalByHandle(handle) orelse return;

        if (l.chain.phase == .asking or l.chain.phase == .backoff) return r.stepChain(l, .cancel);
        if (l.id) |id| try r.stepRequest(.{ .cancel_requested = id });
        if (!r.pipe() and r.legacy == null and l.used) try r.stepExchange(l, .cancel);
    }

    pub fn stopListening(r: *Server) Error!void {
        try r.stepSubs(.{ .cancel = 0 });
    }

    pub fn respond(r: *Server, handle: Handle, values: []const []const u8) Error!void {
        const l = r.logicalByHandle(handle) orelse return error.UnknownCall;
        if (l.chain.phase != .asking or values.len != l.round.count) return error.InvalidInputResponses;

        for (l.round.slice(), values) |q, v| if (q.kind == .elicitation) {
            var form: elicitation.Form = .{};
            const read = elicitation.parse(q.params.?, &form) catch return error.InvalidInputResponses;
            _ = elicitation.readAnswer(read.mode, &form, v) catch return error.InvalidInputResponses;
        };
        const a = l.arena.allocator();
        const copies = try a.alloc([]const u8, values.len);
        for (values, copies) |v, *c| c.* = try a.dupe(u8, v);
        l.answers = copies;
        try r.stepChain(l, .provided);
    }

    pub fn answerElicitation(r: *Server, id: elicit_core.Id, answer: elicitation.Answer) Error!void {
        const s = r.elicit.find(id) orelse return error.UnknownElicitation;
        var form: elicitation.Form = .{};
        _ = elicitation.parse(r.elicit_held[id.slot].params, &form) catch return error.InvalidAnswer;
        const valid = if (elicitation.check(s.mode, &form, answer)) true else |err| switch (err) {
            error.InvalidAnswer => return error.InvalidAnswer,
            error.InvalidContent => false,
        };
        try r.stepElicit(.{ .answered = .{ .id = id, .action = answer.action, .valid = valid } }, .{ .content = answer.content });
        if (!valid) return error.InvalidAnswer;
    }

    pub fn signIn(r: *Server, redirect_uri: []const u8) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.signIn(redirect_uri);
        try r.runAuth(null);
    }

    pub fn finishSignIn(r: *Server, callback_url: []const u8) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.finishSignIn(callback_url);
        try r.runAuth(null);
    }

    pub fn cancelSignIn(r: *Server) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.cancelSignIn();
        try r.runAuth(null);
    }

    pub fn useCredential(r: *Server, saved: []const u8) Error!bool {
        if (r.stdio) return error.NotReady;
        if (!try r.auth.restore(saved)) return false;
        try r.runAuth(null);
        return true;
    }

    pub fn refresh(r: *Server) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.refreshNow();
        try r.runAuth(null);
    }

    pub fn signOut(r: *Server) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.signOut();
        try r.runAuth(null);
    }

    pub fn close(r: *Server) Error!void {
        if (r.stdio) return r.proc.stop();
        if (r.sse_link) try r.stepSse(.close);
        var delete: ?u64 = null;
        if (r.legacy != null) {
            try r.stepLegacy(.close);
            delete = r.delete_key;
        }

        var revoke = r.auth.revoking();
        const deadline = r.now() + 2000;
        while ((delete != null or revoke != null) and r.now() < deadline) switch (try r.client.next(@intCast(@max(0, deadline - r.now())))) {
            .ended => |e| if (delete) |k| if (k == e.key) {
                delete = null;
            },
            .fetched => |f| if (revoke) |k| if (k == f.key) {
                revoke = null;
            },
            .timeout => return,
            else => {},
        };
    }

    pub fn next(r: *Server, timeout_ms: u32) Error!Event {
        r.held_answer = null;
        const deadline = r.now() + timeout_ms;
        while (true) {
            if (r.take()) |event| return event;
            const wait: u32 = @intCast(@max(0, @min(deadline, r.dueMs() orelse deadline) - r.now()));
            const timed_out = if (r.stdio) blk: {
                const incoming = try r.proc.next(wait);
                if (incoming == .timeout) break :blk true;
                try r.onProcess(incoming);
                break :blk false;
            } else blk: {
                const incoming = try r.client.next(wait);
                if (incoming == .timeout) break :blk true;
                try r.onHttp(incoming);
                break :blk false;
            };
            if (timed_out) {
                try r.fireTimers();
                if (r.event_count == 0 and r.now() >= deadline) return .timeout;
            }
        }
    }

    pub fn poll(r: *Server) Error!?Event {
        r.held_answer = null;
        var read: u32 = 0;
        while (true) {
            if (r.take()) |event| return event;
            if (r.dueMs()) |due| if (due <= r.now()) {
                try r.fireTimers();
                continue;
            };
            if (read == burst) {
                if (if (r.stdio) r.proc.options.bell else r.client.options.bell) |b| b.ring();
                return null;
            }
            read += 1;
            if (r.stdio) {
                if (try r.proc.poll()) |incoming| {
                    try r.onProcess(incoming);
                    continue;
                }
            } else if (r.client.poll()) |incoming| {
                try r.onHttp(incoming);
                continue;
            }
            return null;
        }
    }

    const burst = 64;

    pub fn pending(r: *Server) ?Event {
        return r.take();
    }

    fn take(r: *Server) ?Event {
        if (r.event_count == 0) return null;
        const event = r.events[0];
        @memmove(r.events[0 .. r.event_count - 1], r.events[1..r.event_count]);
        r.event_count -= 1;
        return event;
    }

    fn onHttp(r: *Server, incoming: http.Incoming) Error!void {
        switch (incoming) {
            .message => |m| {
                if (r.sse_link) return r.onSseMessage(m.key, m.message);
                try r.onEventId(m.key, m.event_id, m.retry_ms);
                try r.onMessage(m.key, m.status, m.message);
            },
            .mark => |m| try r.onEventId(m.key, m.event_id, m.retry_ms),
            .session => |s| try r.onSession(s.key, s.id),
            .endpoint => |e| try r.onEndpoint(e.key, e.url),
            .opened => |key| if (r.legacy != null and key == r.listen_key) try r.listenSettled(),
            .ended => |e| try r.onEnded(e.key, e.status, e.how, e.challenge),
            .fetched => |f| {
                _ = try r.auth.fetched(f.key, f.status, f.media, f.challenge, f.body);
                try r.runAuth(null);
            },
            .timeout => unreachable,
        }
    }

    fn onProcess(r: *Server, incoming: process.Incoming) Error!void {
        switch (incoming) {
            .message => |m| try r.onMessage(if (m.message == .response) m.message.response.id orelse 0 else 0, 200, m.message),

            .stderr => {},
            .dropped => |d| try r.onRefusedLine(d.err, d.line),
            .changed => |c| try r.onProcessChanged(c.state, c.lost, c.oversized),
            .timeout => unreachable,
        }
    }

    fn onRefusedLine(r: *Server, err: wire.DecodeError, line: []const u8) Error!void {
        if (line.len == 0) return;
        const id = wire.responseId(line) orelse return r.keepStray(line);
        if (r.logicalFor(id) == null) return r.keepStray(line);
        const why = switch (err) {
            error.NotJsonRpc2 => "its jsonrpc isn't \"2.0\"",
            error.Ambiguous => "it has both a result and an error, or neither",
            error.InvalidResult => "its result isn't an object",
            error.InvalidErrorObject => "its error isn't an error object",
            else => "it isn't valid JSON-RPC",
        };
        var buf: [excerpt_max + 3]u8 = undefined;
        var text: [192]u8 = undefined;
        const plain = std.mem.print(&text, "invalid reply ({s}): {s}", .{ why, excerptOf(excerpt_max, &buf, line) }) catch unreachable;
        var w: std.Io.Writer = .fixed(&r.refused_reply);
        std.json.Stringify.value(plain, .{}, &w) catch unreachable;
        try r.onMessage(id, 200, .{ .response = .{ .id = id, .body = .{ .failure = .{ .code = wire.code.invalid_request, .message = w.buffered(), .data = null } } } });
    }

    fn onProcessChanged(r: *Server, state: stdio_conn.State, lost: bool, oversized: bool) Error!void {
        if (lost) {
            r.losing_oversized = oversized;
            defer r.losing_oversized = false;
            for (r.table_slots) |slot| if (slot.used) try r.stepRequest(.{ .transport_lost = slot.id });
            if (r.subs.up) try r.stepSubs(.transport_down);
            try r.endElicitations();
            var i: usize = 0;
            while (i < r.timers.items.len) {
                if (r.timers.items[i].kind == .probe) _ = r.timers.swapRemove(i) else i += 1;
            }
        }

        if (state == .backoff or state == .failed) r.emit(.down);
        if (r.start_pending and (state == .idle or state == .stopped)) {
            r.start_pending = false;
            try r.proc.start();
            return r.started();
        }
        try r.processUp();
    }

    fn started(r: *Server) Error!void {
        if (r.proc.conn.state == .backoff or r.proc.conn.state == .failed) return r.emit(.down);
        try r.processUp();
    }

    fn processUp(r: *Server) Error!void {
        const generation = r.proc.conn.generation;
        if (r.proc.conn.state != .running or generation == r.era_generation) return;
        r.era_generation = generation;
        try r.stepEra(.process_started);
        try r.stepEra(.detect_requested);
    }

    fn onStdioAnswer(r: *Server, l: *Logical, id: request.Id, body: @FieldType(wire.Response, "body")) Error!void {
        switch (l.what) {
            .discover => {
                try r.keepInstructions(body);
                try r.stepEra(era.classifyDiscover(r.detector.config, body));
            },
            .initialize => {
                try r.keepInstructions(body);
                try r.stepEra(era.classifyInitialize(r.detector.config, body));
            },
            .list => try r.stepCatalog(try r.pageEvent(body)),
            .call => _ = try r.callAnswer(body),
            .resource => r.held_resource = resources.classify(body),
            .listen => try r.stepSubs(.{ .final = .{ .id = id, .end = listenEnd(body) } }),
        }
        try r.stepRequest(.{ .response_received = .{ .id = id, .response = if (body == .result) .result else .peer_error } });
    }

    fn listenEnd(body: @FieldType(wire.Response, "body")) subscription.End {
        return if (body == .result and body.result.kind == .complete) .result else .refused;
    }

    fn stdioDelivered(r: *Server, id: request.Id, outcome: request.Outcome) Error!void {
        const l = r.logicalFor(id) orelse return;
        const answered = outcome == .result or outcome == .peer_error;
        if (r.legacyEra() and (l.what == .call or l.what == .list or l.what == .resource)) return r.legacyDelivered(id, switch (outcome) {
            .result, .peer_error => .result,
            .none, .lost, .ended => .lost,
            .timed_out, .cancelled => .cancelled,
        });
        l.id = null;
        switch (l.what) {
            .discover => {},
            .initialize => if (outcome == .timed_out) try r.stepEra(.initialize_timed_out),
            .list => if (!answered) try r.stepCatalog(.page_failed),
            .resource => return r.resourceDelivered(l, switch (outcome) {
                .result, .peer_error => .result,
                .none, .lost, .ended => .lost,
                .timed_out, .cancelled => .cancelled,
            }),

            .listen => if (outcome == .ended) try r.stepSubs(.{ .final = .{ .id = id, .end = .server_cancelled } }),
            .call => return r.roundEnded(l, switch (outcome) {
                .result => .result,
                .peer_error => .failure,
                .none, .lost, .ended => .lost,
                .timed_out, .cancelled => .cancelled,
            }),
        }
        l.used = false;
    }

    fn pipe(r: *const Server) bool {
        return r.stdio or r.sse_link;
    }

    fn legacyEra(r: *const Server) bool {
        if (!r.pipe()) return r.legacy != null;
        return r.detector.state == .legacy or r.detector.state == .initializing;
    }

    fn reply(r: *Server, body: []const u8) Error!void {
        if (r.stdio) return r.proc.send(.response, body) catch {};
        try r.sendAux(.post, body, null);
    }

    fn notify(r: *Server, body: []const u8) Error!void {
        if (r.stdio) return r.proc.send(.notification, body) catch {};
        try r.sendAux(.post, body, null);
    }

    inline fn tracer(r: *const Server) ?*trace.Writer {
        return trace.on(r.options.trace);
    }

    fn now(r: *const Server) i64 {
        return std.Io.Clock.awake.now(r.io).toMilliseconds();
    }

    fn emit(r: *Server, event: Event) void {
        if (r.event_count == r.events.len) return;
        r.events[r.event_count] = event;
        r.event_count += 1;
    }

    fn auxKey(r: *Server) u64 {
        r.next_aux += 1;
        return r.next_aux;
    }

    fn newLogical(r: *Server, what: What, kind: http_modern.Kind) Error!*Logical {
        const l = for (&r.logicals) |*l| {
            if (!l.used) break l;
        } else return error.TooManyRequests;
        _ = l.arena.reset(.retain_capacity);
        l.* = .{ .used = true, .handle = r.next_handle, .what = what, .exchange = .init(r.options.exchange, kind), .arena = l.arena, .chain = .init(r.options.mrtr) };
        r.next_handle +%= 1;
        l.instance = try l.arena.allocator().print("x{d}", .{l.handle});
        l.chain_instance = l.instance;
        return l;
    }

    fn logicalByHandle(r: *Server, handle: Handle) ?*Logical {
        for (&r.logicals) |*l| if (l.used and l.handle == handle) return l;
        return null;
    }

    fn logicalFor(r: *Server, id: request.Id) ?*Logical {
        for (&r.logicals) |*l| if (l.used and l.id == id) return l;
        return null;
    }

    fn start(r: *Server, l: *Logical) Error!void {
        if (r.pipe()) return if (l.what == .call and !r.legacyEra()) r.stepChain(l, .start) else r.sendAttempt(l);
        if (r.legacy == null) return if (l.what == .call) r.stepChain(l, .start) else r.stepExchange(l, .send);
        var out: era.Output = .{};
        r.detector.step(.operation_sent, &out) catch return error.NotReady;
        if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
        l.id = try r.newRequest(.normal);
        try r.stepLegacy(.{ .send = l.id.? });
    }

    fn newRequest(r: *Server, kind: request.Kind) Error!request.Id {
        var out: request.Output = .{};
        r.table.step(.{ .send = kind }, &out) catch return error.TooManyRequests;
        if (r.tracer()) |t| try request.writeTrace(t, "remote", &out);
        var id: request.Id = 0;
        for (out.effects()) |effect| switch (effect) {
            .write_request => |w| id = w.id,
            .arm_timer => |a| try r.armRequestTimer(a.timer, if (kind == .initialize and a.timer.kind == .hard) r.startLeft(a.after_ms) else a.after_ms),
            else => {},
        };
        if (r.questionsHeld() > 0) try r.stepRequest(.{ .idle_paused = id });
        return id;
    }

    fn startLeft(r: *const Server, after_ms: u32) u32 {
        if (r.detector.ready()) return after_ms;
        return @intCast(std.math.clamp(r.start_due_ms - r.now(), 0, after_ms));
    }

    fn questionsHeld(r: *const Server) usize {
        var n: usize = 0;
        for (r.elicit.slots) |slot| n += @intFromBool(slot.used);
        return n;
    }

    fn idleWhileAsking(r: *Server, held_before: usize) Error!void {
        const held = r.questionsHeld();
        if ((held_before == 0) == (held == 0)) return;
        for (r.table.slots) |slot| if (slot.used) {
            try r.stepRequest(if (held > 0) .{ .idle_paused = slot.id } else .{ .idle_resumed = slot.id });
        };
    }

    fn stepExchange(r: *Server, l: *Logical, event: http_modern.Event) Error!void {
        var out: http_modern.Output = .{};
        l.exchange.step(event, &out);
        if (r.tracer()) |t| try http_modern.writeTrace(t, l.instance, &out);
        for (out.effects()) |effect| switch (effect) {
            .post => try r.sendAttempt(l),
            .relist => {
                try r.stepCatalog(.invalidated);
                try r.stepCatalog(.need);
            },

            .close => if (l.id) |id| {
                l.id = null;
                try r.closeKey(id, if (l.exchange.phase == .cancelled) .forgotten else .answered);
            },
            .deliver => |d| {
                if (l.what == .call) return r.roundEnded(l, d.outcome);
                if (l.what == .resource) return r.resourceDelivered(l, switch (d.outcome) {
                    .result, .failure => .result,
                    .lost => .lost,
                    .http_failure => .http_failure,
                    .cancelled => .cancelled,
                });

                if (l.what == .listen) {
                    l.used = false;
                    return r.stepSubs(switch (d.outcome) {
                        .lost => .{ .lost = l.listen_id },
                        .http_failure => .{ .final = .{ .id = l.listen_id, .end = .refused } },
                        else => return,
                    });
                }

                if (d.outcome != .result and d.outcome != .failure and l.what == .list) {
                    r.page_needs_auth = l.needs_auth;
                    try r.stepCatalog(.page_failed);
                }
                l.used = false;
            },
        };
    }

    fn sendAttempt(r: *Server, l: *Logical) Error!void {
        var version: era.Version = .none;
        if (l.what == .discover) {
            version = .{ .preferred = l.what.discover };
        } else if (l.what != .initialize) {
            var out: era.Output = .{};
            r.detector.step(.operation_sent, &out) catch return error.NotReady;
            if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
            version = out.meta.?;
        }
        const id = try r.newRequest(switch (l.what) {
            .listen => .listen,
            .initialize => .initialize,
            else => .normal,
        });
        l.id = id;
        if (l.what == .listen) {
            l.listen_id = id;
            try r.stepSubs(if (l.resend) .{ .resent = .{ .sub = l.sub, .id = id } } else .{ .opened = .{ .sub = l.sub, .id = id, .filter = l.filter } });
        }
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.Io.Writer.Allocating = .init(a);
        const config = r.detector.config;
        const meta = era.meta(config, r.options.client, version, id);
        switch (l.what) {
            .discover => |i| try era.writeDiscover(&body.writer, config, r.options.client, i, id),
            .initialize => try era.writeInitialize(&body.writer, config, r.options.client, id),
            .list, .call, .resource => try r.writeOperation(&body.writer, l, meta),
            .listen => try subscriptions.writeListen(&body.writer, id, meta, l.filter),
        }

        if (r.stdio) return r.proc.send(.request, body.written()) catch r.stepRequest(.{ .transport_lost = id });
        var headers: std.ArrayList(http_headers.Header) = .empty;
        const version_name = era.versionName(config, version) orelse config.legacy[0];
        try http_headers.requestHeaders(a, version_name, switch (l.what) {
            .discover => "server/discover",
            .list => "tools/list",
            .call => "tools/call",
            .resource => |op| op.method(),
            .listen => "subscriptions/listen",
            .initialize => "initialize",
        }, if (l.what == .call) l.name else null, &.{}, &headers);
        if (l.what == .call) if (r.store.current.find(l.name)) |tool| try r.paramHeaders(a, tool.raw, l.arguments orelse "{}", &headers);
        r.send(id, .post, body.written(), headers.items) catch |err| switch (err) {
            error.TooManyInFlight, error.ConcurrencyUnavailable => if (r.sse_link) try r.stepRequest(.{ .transport_lost = id }) else try r.endAttempt(l, id, .broken, 0),
            else => return err,
        };
    }

    fn writeOperation(r: *Server, out: *std.Io.Writer, l: *const Logical, meta: wire.Meta) Error!void {
        const id = l.id.?;
        switch (l.what) {
            .list => try tools.writeList(out, id, meta, if (r.catalog.pending == .next) r.store.nextCursor() else null),
            .call => try tools.writeCall(out, id, meta, l.name, l.arguments, if (!r.legacyEra()) retryOf(l) else .{}),
            .resource => |op| try resources.write(out, id, meta, op),
            else => unreachable,
        }
    }

    fn paramHeaders(_: *Server, a: std.mem.Allocator, tool_raw: []const u8, arguments: []const u8, headers: *std.ArrayList(http_headers.Header)) Error!void {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(tool_raw, &.{"inputSchema"}, &found) catch return;
        var annotations: [http_headers.max_annotations]http_headers.Annotation = undefined;
        const n = http_headers.annotations(found[0] orelse return, &annotations) catch return;
        http_headers.paramHeaders(a, annotations[0..n], arguments, headers) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    fn onMessage(r: *Server, key: u64, status: u16, message: wire.Message) Error!void {
        switch (message) {
            .notification => |n| {
                if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
                    if (r.legacyEra()) if (r.heldSlot(n.params, "requestId", .id)) |slot| {
                        return r.stepElicit(.{ .server_cancelled = slot }, .{});
                    };
                    const id = subscriptions.cancelledId(n.params) orelse return;
                    return r.stepRequest(.{ .server_cancel_received = id });
                }

                if (subscriptions.subscriptionId(n.params)) |sid| return switch (subscriptions.notice(n.method, n.params)) {
                    .acknowledged => |f| r.stepSubs(.{ .acknowledged = .{ .id = sid, .filter = f } }),
                    .changed => |kind| r.stepSubs(.{ .notified = .{ .id = sid, .kind = kind } }),
                    .other => {},
                };

                if (r.legacyEra() and std.mem.eql(u8, n.method, "notifications/elicitation/complete")) {
                    return r.stepElicit(.{ .completed = r.heldSlot(n.params, "elicitationId", .eid) }, .{});
                }

                if (std.mem.eql(u8, n.method, "notifications/tools/list_changed")) return r.stepCatalog(.invalidated);
                if (std.mem.eql(u8, n.method, "notifications/progress")) {
                    var found: [4]?[]const u8 = undefined;
                    wire.objectFields(n.params orelse "{}", &.{ "progressToken", "progress", "total", "message" }, &found) catch return;
                    const token = wire.decimal(found[0] orelse return) orelse return;
                    const value = std.fmt.parseFloat(f64, found[1] orelse return) catch return;
                    const before = r.table.progressCount(token);
                    try r.stepRequest(.{ .progress_received = .{ .token = token, .value = value } });

                    if (r.table.progressCount(token) == before) return;
                    const l = r.logicalFor(token) orelse return;
                    if (l.what != .call) return;
                    var text: [1024]u8 = undefined;
                    var fixed: std.heap.FixedBufferAllocator = .init(&text);
                    const said = if (found[3]) |raw| wire.decodeString(fixed.allocator(), raw) catch null else null;
                    r.emit(.{ .progress = .{
                        .handle = l.handle,
                        .progress = value,
                        .total = if (found[2]) |t| std.fmt.parseFloat(f64, t) catch null else null,
                        .message = if (said) |m| excerptOf(note_max, &r.note, m) else null,
                    } });
                    return;
                }
            },

            .request => |q| if (r.legacyEra()) try r.answerServerRequest(q),
            .response => |resp| {
                if (resp.id) |id| if (id != key) return;

                if (r.stdio and resp.id == null) return if (resp.body == .failure and r.detector.pending == .discover) r.stepEra(.legacy_answer);
                const l = r.logicalFor(key) orelse return;
                if (r.pipe()) return r.onStdioAnswer(l, key, resp.body);
                if (l.what == .initialize) return r.onInitializeAnswer(l, resp.body);
                if (r.legacy != null and l.what != .discover) return r.onLegacyAnswer(l, key, status, resp.body);
                if (l.exchange.phase != .posted) return;
                try r.stepRequest(.{ .response_received = .{ .id = key, .response = if (resp.body == .result) .result else .peer_error } });
                const answer: http_modern.Answer = switch (l.what) {
                    .discover => blk: {
                        try r.keepInstructions(resp.body);
                        try r.stepEra(era.classifyDiscoverHttp(r.detector.config, status, resp.body));
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .list => blk: {
                        try r.stepCatalog(try r.pageEvent(resp.body));
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .resource => blk: {
                        r.held_resource = resources.classify(resp.body);
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .call => blk: {
                        const c = try r.callAnswer(resp.body) orelse break :blk .mismatch;

                        break :blk switch (c) {
                            .result, .input_required => .result,
                            .failure, .invalid => .failure,
                        };
                    },
                    .listen => blk: {
                        try r.stepSubs(.{ .final = .{ .id = key, .end = listenEnd(resp.body) } });
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .initialize => unreachable,
                };

                try r.stepExchange(l, .{ .answer = answer });
            },
        }
    }

    fn callAnswer(r: *Server, body: @FieldType(wire.Response, "body")) Error!?tools.Call {
        const c = tools.classifyCall(body);
        r.held_answer = c;
        if (c == .failure) {
            if (!r.pipe() and r.legacy == null and c.failure.code == wire.code.header_mismatch) return null;
            if (era.classifyOperationRejection(r.detector.config, c.failure)) |e| try r.stepEra(e);
        }
        if (tools.suggestsChangedList(c)) try r.stepCatalog(.invalidated);
        return c;
    }

    fn onEnded(r: *Server, key: u64, status: u16, how: http.Ending, challenge: ?[]const u8) Error!void {
        if (r.kept(key) != null) {
            if (how == .rejected) {
                if (try r.auth.ended(key, .{ .rejected = .{ .status = status, .challenge = challenge orelse "" } })) return r.runAuth(null);
                r.unkeep(key);
                try r.runAuth(null);
            } else {
                r.unkeep(key);

                _ = try r.auth.ended(key, if (how == .broken) .forgotten else .answered);
                try r.runAuth(null);
            }
        }
        try r.onEndedDomain(key, status, if (how == .rejected) .http_failure else how);
    }

    fn onEndedDomain(r: *Server, key: u64, status: u16, how: http.Ending) Error!void {
        if (how == .refused and !r.refusable(key)) return r.onEndedDomain(key, status, .http_failure);
        if (r.sse_link) return r.onSseEnded(key, status, how);
        if (r.legacy != null) {
            if (key == r.initialized_key) return r.releaseHeldSends();
            if (key == r.listen_key) return r.onListenEnded(status, how);
            const l = r.logicalFor(key) orelse return;
            if (l.what == .initialize) return r.onInitializeEnded(l, key, how);
            if (l.what != .discover) return r.onLegacyEnded(l, key, status, how);
        }
        const l = r.logicalFor(key) orelse return;
        if (l.exchange.phase != .posted) return;
        try r.endAttempt(l, key, how, status);
    }

    fn refusable(r: *Server, key: u64) bool {
        if (r.sse_link) return false;
        const l = r.logicalFor(key) orelse return false;
        return l.what == .initialize or (l.what == .discover and r.legacy == null);
    }

    fn onSseMessage(r: *Server, key: u64, message: wire.Message) Error!void {
        if (r.sse_stream != key) return;
        var out: http_sse.Output = .{};
        try r.sse.step(.{ .message = if (message == .response) message.response.id else null }, &out);
        for (out.effects()) |effect| switch (effect) {
            .answer => |id| try r.onMessage(id, 200, message),
            .forward => try r.onMessage(0, 200, message),
            else => try r.applySse(effect),
        };
    }

    fn onEndpoint(r: *Server, key: u64, url: []const u8) Error!void {
        if (r.sse_stream != key or r.sse.phase != .awaiting) return;
        const endpoint = http_sse.resolve(r.gpa, r.sseBase(), url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEndpoint, error.CrossOrigin => return r.stepSse(.bad_endpoint),
        };
        r.dropEndpoint();
        r.sse_endpoint = endpoint;
        try r.stepSse(.endpoint);
    }

    fn onSseEnded(r: *Server, key: u64, status: u16, how: http.Ending) Error!void {
        if (r.sse_stream == key) {
            r.sse_stream = null;
            return r.stepSse(.stream_ended);
        }
        if (status / 100 != 2 or how == .broken or how == .http_failure or how == .too_large) try r.stepSse(.{ .refused = key });
    }

    fn stepSse(r: *Server, event: http_sse.Event) Error!void {
        var out: http_sse.Output = .{};
        try r.sse.step(event, &out);
        for (out.effects()) |effect| try r.applySse(effect);
    }

    fn applySse(r: *Server, effect: http_sse.Effect) Error!void {
        switch (effect) {
            .open_stream => {
                const key = r.auxKey();
                r.sse_stream = key;
                try r.sendLegacy(key, .get, null, null);
            },
            .ready => try r.detect(),
            .close_stream => if (r.sse_stream) |key| {
                r.sse_stream = null;
                try r.closeKey(key, .forgotten);
            },
            .failed => try r.onSseDown(),
            .lost => |id| try r.stepRequest(.{ .transport_lost = id }),
            .answer, .forward => {},
        }
    }

    fn onSseDown(r: *Server) Error!void {
        if (r.subs.up) try r.stepSubs(.transport_down);
        try r.endElicitations();
        var i: usize = 0;
        while (i < r.timers.items.len) {
            if (r.timers.items[i].kind == .probe) _ = r.timers.swapRemove(i) else i += 1;
        }
        r.emit(.{ .failed = .session });
    }

    fn sseBase(r: *const Server) []const u8 {
        return switch (r.options.link) {
            .sse => |h| h.url,
            else => "",
        };
    }

    fn dropEndpoint(r: *Server) void {
        if (r.sse_endpoint) |url| r.gpa.free(url);
        r.sse_endpoint = null;
    }

    fn endAttempt(r: *Server, l: *Logical, id: request.Id, how: http.Ending, status: u16) Error!void {
        l.id = null;
        try r.stepRequest(.{ .transport_lost = id });
        if (how == .http_failure or how == .refused) {
            if (l.what == .discover) try r.stepEra(if (how == .refused) era.Event.http_refused else era.classifyDiscoverHttp(r.detector.config, status, null));
            return r.stepExchange(l, .http_failure);
        }

        if (how == .too_large) {
            r.losing_oversized = true;
            defer r.losing_oversized = false;
            return r.stepExchange(l, .too_large);
        }
        try r.stepExchange(l, .stream_broken);
    }

    fn pageEvent(r: *Server, body: @FieldType(wire.Response, "body")) Error!catalog.Event {
        switch (body) {
            .failure => |f| return if (f.code == wire.code.invalid_params and r.catalog.pending == .next) .invalid_cursor else .page_failed,
            .result => |res| {
                if (res.kind != .complete) return .page_failed;
                const page = tools.parsePage(res.raw) catch return .page_failed;

                r.store.check_headers = !r.legacyEra();
                const added = r.store.addPage(r.gpa, page) catch return .page_failed;
                r.last_added = added;
                return .{ .page_received = .{ .more = page.next_cursor != null, .ttl_ms = page.ttl_ms, .now_ms = r.now() } };
            },
        }
    }

    fn retryOf(l: *const Logical) mrtr.Retry {
        const answering = l.chain.responded > 0;
        return .{
            .requests = if (answering) l.round.slice() else &.{},
            .values = if (answering) l.answers else &.{},
            .state = if (l.chain.sent_state != 0) l.round.state else null,
        };
    }

    fn roundEnded(r: *Server, l: *Logical, outcome: http_modern.Outcome) Error!void {
        const answer: mrtr_core.Answer = switch (outcome) {
            .result => if (r.held_answer) |a| switch (a) {
                .input_required => |raw| try r.readRound(l, raw),
                else => .{ .ended = .result },
            } else .{ .ended = .result },
            .failure => .{ .ended = .failure },
            .lost => .{ .ended = .lost },
            .http_failure => .{ .ended = .http_failure },
            .cancelled => return r.stepChain(l, .cancel),
        };
        try r.stepChain(l, .{ .answered = answer });
    }

    fn readRound(r: *Server, l: *Logical, raw: []const u8) Error!mrtr_core.Answer {
        const bytes = try l.arena.allocator().dupe(u8, raw);
        mrtr.parse(bytes, &l.round) catch return .malformed;

        for (l.round.slice()) |q| if (q.kind == .elicitation and mrtr.supported(r.options.client.capabilities, q)) {
            var form: elicitation.Form = .{};
            _ = elicitation.parse(q.params orelse return .malformed, &form) catch return .malformed;
        };
        return .{ .input_required = .{
            .requests = l.round.count,
            .state = l.round.state != null,
            .supported = mrtr.allSupported(r.options.client.capabilities, &l.round),
        } };
    }

    fn stepChain(r: *Server, l: *Logical, event: mrtr_core.Event) Error!void {
        var out: mrtr_core.Output = .{};
        l.chain.step(event, &out);
        if (r.tracer()) |t| try mrtr_core.writeTrace(t, l.chain_instance, &l.chain, &out);
        for (out.effects()) |effect| switch (effect) {
            .send => |s| {
                l.exchange = .init(r.options.exchange, .call);
                l.id = null;
                if (s.round > 1) l.instance = try l.arena.allocator().print("x{d}.{d}", .{ l.handle, s.round });
                if (r.pipe()) try r.sendAttempt(l) else try r.stepExchange(l, .send);
            },
            .ask_host => r.emit(.{ .input = .{ .handle = l.handle, .requests = l.round.slice() } }),
            .arm_backoff => |ms| try r.timers.append(r.gpa, .{ .kind = .{ .backoff = l.handle }, .due_ms = r.now() + ms }),
            .deliver => |o| {
                r.emit(.{
                    .called = .{
                        .handle = l.handle,
                        .outcome = if (l.needs_auth and o == .http_failure) .needs_auth else if (l.unrenewed and o == .http_failure) .auth_unavailable else switch (o) {
                            .none => .failure,
                            inline else => |tag| @field(CallOutcome, @tagName(tag)),
                        },

                        .maybe_ran = o == .lost,
                        .timed_out = l.timed_out,
                        .answer = if (o == .result or o == .failure) r.held_answer else null,
                        .oversized = o == .lost and r.losing_oversized,
                    },
                });
                l.used = false;
            },
        };
    }

    fn startSession(r: *Server) Error!void {
        if (r.legacy == null) r.legacy = .init(&r.legacy_slots, r.options.session);
        try r.stepLegacy(.start);
    }

    fn stepLegacy(r: *Server, event: http_legacy.Event) Error!void {
        const s = &(r.legacy orelse return);
        var out: http_legacy.Output = .{};
        s.step(event, &out) catch return;
        if (r.tracer()) |t| try http_legacy.writeTrace(t, r.era_instance, &out);
        for (out.effects()) |effect| try r.legacyEffect(effect);
        s.sweep();
    }

    fn legacyEffect(r: *Server, effect: http_legacy.Effect) Error!void {
        switch (effect) {
            .post, .get_resume => if (r.initialized_key != null or r.listen_pending) return r.held_sends.append(r.gpa, effect),
            .open_listen => if (r.initialized_key != null) return r.held_sends.append(r.gpa, effect),
            else => {},
        }
        switch (effect) {
            .post_initialize => {
                try r.endElicitations();
                r.first_listen = true;
                r.listen_pending = false;
                try r.sendInitialize();
            },
            .post_initialized => {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try era.writeInitialized(&body.writer);
                const key = r.auxKey();
                r.initialized_key = key;

                try r.timers.append(r.gpa, .{ .kind = .{ .initialized = key }, .due_ms = r.now() + r.options.timeouts.idle_ms });
                try r.sendLegacy(key, .post, body.written(), null);
            },
            .post => |id| {
                const req = r.legacy.?.find(id) orelse return;
                if (req.state == .posted) try r.postLegacy(id);
            },
            .post_cancel => |id| {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .notification(&body.writer, "notifications/cancelled", .{});
                try w.field("requestId");
                try w.int(@intCast(id));
                try w.end();
                try r.sendAux(.post, body.written(), null);
            },
            .get_resume => |id| {
                const req = r.legacy.?.find(id) orelse return;
                const l = r.logicalFor(id) orelse return;
                if (req.state == .resuming) try r.sendLegacy(id, .get, null, l.last_event_id);
            },
            .arm_resume => |a| try r.timers.append(r.gpa, .{ .kind = .{ .resume_stream = a.id }, .due_ms = r.now() + a.after_ms }),
            .open_listen => {
                if (r.legacy.?.listen != .open or r.legacy.?.phase != .ready) return;
                const key = r.auxKey();
                r.listen_key = key;
                if (r.first_listen) {
                    r.first_listen = false;
                    r.listen_pending = true;
                    try r.timers.append(r.gpa, .{ .kind = .listen_wait, .due_ms = r.now() + r.options.listen_wait_ms });
                }
                try r.sendLegacy(key, .get, null, r.listen_last_event_id);
            },
            .close_listen => if (r.listen_key) |key| {
                try r.closeKey(key, .forgotten);
                r.listen_key = null;
            },
            .arm_listen => |ms| try r.timers.append(r.gpa, .{ .kind = .listen, .due_ms = r.now() + ms }),
            .delete => {
                try r.endElicitations();
                const key = r.auxKey();
                r.delete_key = key;
                try r.sendLegacy(key, .delete, null, null);
            },
            .deliver => |d| {
                if (d.outcome == .result) try r.closeKey(d.id, .answered) else {
                    try r.stepRequest(.{ .transport_lost = d.id });
                    try r.closeKey(d.id, .forgotten);
                }
                try r.legacyDelivered(d.id, d.outcome);
            },
        }
    }

    fn listenSettled(r: *Server) Error!void {
        if (!r.listen_pending) return;
        r.listen_pending = false;
        try r.releaseHeldSends();
    }

    fn releaseHeldSends(r: *Server) Error!void {
        r.initialized_key = null;
        var held = r.held_sends;
        r.held_sends = .empty;
        defer held.deinit(r.gpa);
        for (held.items) |effect| try r.legacyEffect(effect);
    }

    fn sendInitialize(r: *Server) Error!void {
        const l = try r.newLogical(.initialize, .idempotent);
        const id = try r.newRequest(.initialize);
        l.id = id;
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        try era.writeInitialize(&body.writer, r.detector.config, r.options.client, id);
        if (r.incoming_session) |v| r.gpa.free(v);
        r.incoming_session = null;
        r.bad_session = false;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        var headers: std.ArrayList(http_headers.Header) = .empty;
        try http_headers.sessionHeaders(arena.allocator(), false, null, null, null, &headers);
        try r.send(id, .post, body.written(), headers.items);
    }

    fn postLegacy(r: *Server, id: request.Id) Error!void {
        const l = r.logicalFor(id) orelse return;
        l.last_event_id = null;
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        try r.writeOperation(&body.writer, l, era.meta(r.detector.config, r.options.client, .none, id));
        try r.sendLegacy(id, .post, body.written(), null);
    }

    fn sendLegacy(r: *Server, key: u64, method: http.Method, body: ?[]const u8, last_event_id: ?[]const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        var headers: std.ArrayList(http_headers.Header) = .empty;
        const version = r.detector.config.legacy[r.legacy_version];
        try http_headers.sessionHeaders(arena.allocator(), method == .get, version, r.session_id, last_event_id, &headers);
        r.send(key, method, body, headers.items) catch |err| switch (err) {
            error.TooManyInFlight, error.ConcurrencyUnavailable => if (key < aux_base) try r.stepLegacy(.{ .broke = key }),
            else => return err,
        };
    }

    fn sendAux(r: *Server, method: http.Method, body: ?[]const u8, last_event_id: ?[]const u8) Error!void {
        try r.sendLegacy(r.auxKey(), method, body, last_event_id);
    }

    fn answerServerRequest(r: *Server, q: wire.ServerRequest) Error!void {
        if (std.mem.eql(u8, q.method, "elicitation/create")) return r.askElicitation(.request, q.id, q.params orelse "{}");
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        if (std.mem.eql(u8, q.method, "ping")) {
            var w: wire.Writer = try .result(&body.writer, q.id);
            try w.end();
        } else if (std.mem.eql(u8, q.method, "roots/list") and r.options.client.workspace.len > 0) {
            const uri = try fileUri(r.gpa, r.options.client.workspace);
            defer r.gpa.free(uri);
            var w: wire.Writer = try .result(&body.writer, q.id);
            try w.field("roots");
            try w.json.beginArray();
            try w.json.beginObject();
            try w.field("uri");
            try w.string(uri);
            try w.field("name");
            try w.string(std.fs.path.basename(r.options.client.workspace));
            try w.json.endObject();
            try w.json.endArray();
            try w.end();
        } else try wire.writeFailure(&body.writer, q.id, wire.code.method_not_found, "Method not found");
        try r.reply(body.written());
    }

    fn fileUri(gpa: std.mem.Allocator, path: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("file://");
        for (path) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.writer.writeByte(c),
            else => try out.writer.print("%{X:0>2}", .{c}),
        };
        return out.toOwnedSlice();
    }

    fn onSession(r: *Server, key: u64, id: []const u8) Error!void {
        const l = r.logicalFor(key) orelse return;
        if (l.what != .initialize) return;

        if (!http_headers.validSessionId(id)) {
            r.bad_session = true;
            return;
        }
        if (r.incoming_session) |v| r.gpa.free(v);
        r.incoming_session = try r.gpa.dupe(u8, id);
    }

    fn onEventId(r: *Server, key: u64, event_id: ?[]const u8, retry_ms: ?u32) Error!void {
        if (r.legacy == null) return;

        const id = if (event_id) |e| if (http_headers.validEventId(e)) e else null else null;
        if (key == r.listen_key) {
            if (id) |e| {
                if (r.listen_last_event_id) |v| r.gpa.free(v);
                r.listen_last_event_id = try r.gpa.dupe(u8, e);
            }
            return r.stepLegacy(.listen_event);
        }
        const l = r.logicalFor(key) orelse return;
        if (l.what == .initialize or l.what == .discover) return;
        if (id) |e| l.last_event_id = try l.arena.allocator().dupe(u8, e);
        if (id != null or retry_ms != null) try r.stepLegacy(.{ .event_seen = .{ .id = key, .has_id = id != null, .retry_ms = retry_ms } });
    }

    fn keepInstructions(r: *Server, body: @FieldType(wire.Response, "body")) Error!void {
        if (body != .result) return;
        var found: [1]?[]const u8 = .{null};
        wire.objectFields(body.result.raw, &.{"instructions"}, &found) catch {};
        if (r.instructions) |old| r.gpa.free(old);
        r.instructions = null;
        const raw = found[0] orelse return;
        const text = (try wire.decodeString(r.gpa, raw)) orelse return;

        r.instructions = if (wire.plainString(raw) != null) try r.gpa.dupe(u8, text) else text;
    }

    fn onInitializeAnswer(r: *Server, l: *Logical, body: @FieldType(wire.Response, "body")) Error!void {
        const id = l.id.?;
        try r.stepRequest(.{ .response_received = .{ .id = id, .response = if (body == .result) .result else .peer_error } });
        l.used = false;
        try r.keepInstructions(body);
        const event = era.classifyInitialize(r.detector.config, body);
        const first = r.detector.state == .initializing;
        if (event == .initialize_result and event.initialize_result == .legacy and !r.bad_session) {
            r.legacy_version = event.initialize_result.legacy;
            if (r.session_id) |v| r.gpa.free(v);
            r.session_id = r.incoming_session;
            r.incoming_session = null;
            if (r.listen_last_event_id) |v| r.gpa.free(v);
            r.listen_last_event_id = null;
            try r.stepLegacy(.{ .initialize_answered = .{ .session = r.session_id != null } });

            if (!first) try r.stepCatalog(.{ .process_started = .legacy });
        } else {
            try r.stepLegacy(.initialize_failed);
            if (!first) r.emit(.{ .failed = if (l.needs_auth) .needs_auth else .session });
        }
        if (first) try r.stepEra(if (r.bad_session) .{ .initialize_error = false } else event);
    }

    fn onInitializeEnded(r: *Server, l: *Logical, key: u64, how: http.Ending) Error!void {
        l.used = false;
        try r.stepRequest(.{ .transport_lost = key });
        try r.initializeFailed(l, if (how == .refused) .http_refused else .{ .initialize_error = false });
    }

    fn onInitializeTimedOut(r: *Server, l: *Logical, id: request.Id) Error!void {
        l.used = false;
        try r.closeKey(id, .forgotten);
        try r.initializeFailed(l, .initialize_timed_out);
    }

    fn onInitializedTimedOut(r: *Server) Error!void {
        if (r.initialized_key) |key| try r.closeKey(key, .forgotten);
        r.initialized_key = null;
        r.emit(.{ .failed = .initialized_timed_out });
    }

    fn initializeFailed(r: *Server, l: *const Logical, event: era.Event) Error!void {
        const first = r.detector.state == .initializing;
        try r.stepLegacy(.initialize_failed);
        if (first) try r.stepEra(event) else r.emit(.{ .failed = if (l.needs_auth) .needs_auth else .session });
    }

    fn onLegacyAnswer(r: *Server, l: *Logical, key: u64, status: u16, body: @FieldType(wire.Response, "body")) Error!void {
        const s = &r.legacy.?;
        const req = s.find(key) orelse return;
        if (req.state != .posted and req.state != .resuming) return;

        if (status == 404 or (req.state == .resuming and status >= 300)) return;
        try r.stepRequest(.{ .response_received = .{ .id = key, .response = if (body == .result) .result else .peer_error } });
        switch (l.what) {
            .list => try r.stepCatalog(try r.pageEvent(body)),
            .call => _ = try r.callAnswer(body),
            .resource => r.held_resource = resources.classify(body),
            else => {},
        }
        try r.stepLegacy(.{ .answered = key });
    }

    fn onLegacyEnded(r: *Server, l: *Logical, key: u64, status: u16, how: http.Ending) Error!void {
        _ = l;
        const s = &r.legacy.?;
        const req = s.find(key) orelse return;
        if (req.state != .posted and req.state != .resuming) return;
        const event: http_legacy.Event = if (status == 404)
            .{ .expired = key }
        else if (status >= 300)
            .{ .refused = key }
        else switch (how) {
            .complete, .accepted, .broken => .{ .broke = key },

            .too_large => .{ .too_large = key },
            .http_failure, .rejected, .refused => .{ .refused = key },
        };
        r.losing_oversized = event == .too_large;
        defer r.losing_oversized = false;
        try r.stepLegacy(event);
    }

    fn onListenEnded(r: *Server, status: u16, how: http.Ending) Error!void {
        r.listen_key = null;
        try r.stepLegacy(if (status == 404 and r.session_id != null)
            .listen_expired
        else if (status >= 300 or how == .http_failure)
            .listen_refused
        else
            .{ .listen_broke = null });
        try r.listenSettled();
    }

    fn legacyDelivered(r: *Server, id: request.Id, outcome: http_legacy.Outcome) Error!void {
        const l = r.logicalFor(id) orelse return;
        if (l.what == .resource) return r.resourceDelivered(l, switch (outcome) {
            .result => .result,
            .lost => .lost,
            .failed, .none => .http_failure,
            .cancelled => .cancelled,
        });

        if (l.what == .call and outcome == .result) if (r.held_answer) |a| if (a == .failure and a.failure.code == url_elicitation_required) {
            try r.requiredElicitations(a.failure.data);
        };
        if (l.what == .call) r.emit(.{
            .called = .{
                .handle = l.handle,
                .outcome = switch (outcome) {
                    .result => if (r.held_answer) |a| switch (a) {
                        .failure => .failure,
                        .input_required => .malformed,
                        else => .result,
                    } else .result,
                    .lost => .lost,
                    .failed, .none => if (l.needs_auth) .needs_auth else if (l.unrenewed) .auth_unavailable else .http_failure,
                    .cancelled => .cancelled,
                },

                .maybe_ran = outcome == .lost,
                .timed_out = l.timed_out,
                .answer = if (outcome == .result) r.held_answer else null,
                .oversized = outcome == .lost and r.losing_oversized,
            },
        });
        if (l.what == .list and outcome != .result) {
            r.page_needs_auth = l.needs_auth;
            try r.stepCatalog(.page_failed);
        }
        l.used = false;
    }

    fn resourceDelivered(r: *Server, l: *Logical, outcome: CallOutcome) Error!void {
        r.emit(.{ .resource = .{
            .handle = l.handle,
            .outcome = outcome,
            .answer = if (outcome == .result) r.held_resource orelse .invalid else null,
        } });
        r.held_resource = null;
        l.used = false;
    }

    fn askElicitation(r: *Server, origin: elicit_core.Origin, id: ?[]const u8, params: []const u8) Error!void {
        var form: elicitation.Form = .{};
        const read: ?elicitation.Request = elicitation.parse(params, &form) catch null;
        const mode: elicit_core.Mode = if (read) |q| q.mode else .form;
        const eid = if (read) |q| if (mode == .url) q.elicitation_id else null else null;

        if (origin == .required and eid == null) return;
        try r.stepElicit(.{ .asked = .{ .origin = origin, .mode = mode, .eid = eid != null, .readable = read != null } }, .{ .id = id, .eid = eid, .params = params });
    }

    fn requiredElicitations(r: *Server, data: ?[]const u8) Error!void {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(data orelse return, &.{"elicitations"}, &found) catch return;
        var list: wire.Elements = undefined;
        list.init(found[0] orelse return) catch return;
        while (list.next() catch return) |entry| try r.askElicitation(.required, null, entry);
    }

    fn endElicitations(r: *Server) Error!void {
        try r.stepElicit(.session_ended, .{});
    }

    fn heldSlot(r: *const Server, params: ?[]const u8, field: []const u8, comptime which: enum { id, eid }) ?u8 {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(params orelse return null, &.{field}, &found) catch return null;
        const token = found[0] orelse return null;
        for (r.elicit_held, 0..) |h, i| {
            const held = (if (which == .id) h.id else h.eid) orelse continue;
            if (r.elicit.slots[i].used and std.mem.eql(u8, held, token)) return @intCast(i);
        }
        return null;
    }

    fn forget(r: *Server, h: *Held) void {
        if (h.id) |v| r.gpa.free(v);
        if (h.eid) |v| r.gpa.free(v);
        h.id = null;
        h.eid = null;
    }

    fn stepElicit(r: *Server, event: elicit_core.Event, with: struct { id: ?[]const u8 = null, eid: ?[]const u8 = null, params: []const u8 = "", content: ?[]const u8 = null }) Error!void {
        var out: elicit_core.Output = .{};
        const held_before = r.questionsHeld();
        r.elicit.step(event, &out);
        try r.idleWhileAsking(held_before);
        if (r.tracer()) |t| try elicit_core.writeTrace(t, "remote", &r.elicit, event, &out);
        for (out.effects()) |effect| switch (effect) {
            .show => |slot| {
                const h = &r.elicit_held[slot];
                const params = try r.gpa.dupe(u8, with.params);
                r.gpa.free(h.params);
                h.* = .{ .params = params };
                if (with.id) |id| h.id = try r.gpa.dupe(u8, id);
                if (with.eid) |eid| h.eid = try r.gpa.dupe(u8, eid);
                r.emit(.{ .elicit = .{ .id = .{ .slot = slot, .n = out.n }, .params = h.params, .required = event.asked.origin == .required } });
            },
            .reject => |why| {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try switch (why) {
                    .invalid_params => wire.writeFailure(&body.writer, with.id.?, wire.code.invalid_params, "Unsupported elicitation"),
                    .too_many => wire.writeFailure(&body.writer, with.id.?, wire.code.internal_error, "Too many elicitations"),
                };
                try r.reply(body.written());
            },
            .send => |s| {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .result(&body.writer, r.elicit_held[s.slot].id.?);
                try w.field("action");
                try w.string(@tagName(s.action));
                if (s.content) {
                    try w.field("content");
                    try w.raw(with.content.?);
                }
                try w.end();
                try r.reply(body.written());
            },
            .withdraw => |slot| r.emit(.{ .elicit_withdrawn = slot }),
            .complete => |slot| r.emit(.{ .elicitation_complete = slot }),
            .release => |slot| r.forget(&r.elicit_held[slot]),
        };
    }

    fn send(r: *Server, key: u64, method: http.Method, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            errdefer arena.deinit();
            const a = arena.allocator();
            const copies = try a.alloc(std.http.Header, headers.len + 1);
            for (headers, copies[0..headers.len]) |h, *c| c.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
            try r.outbox.append(r.gpa, .{ .key = key, .method = method, .body = if (body) |b| try a.dupe(u8, b) else null, .headers = copies, .arena = arena });
        }

        const sent: Error!void = blk: {
            r.auth.beforeSend(key) catch |err| break :blk err;
            break :blk r.runAuth(key);
        };
        sent catch |err| {
            if (r.kept(key) != null) {
                r.unkeep(key);
                _ = r.auth.ended(key, .forgotten) catch {};
            }
            return err;
        };
    }

    fn kept(r: *Server, key: u64) ?*Kept {
        for (r.outbox.items) |*k| if (k.key == key) return k;
        return null;
    }

    fn unkeep(r: *Server, key: u64) void {
        for (r.outbox.items, 0..) |*k, i| if (k.key == key) {
            k.arena.deinit();
            _ = r.outbox.swapRemove(i);
            return;
        };
    }

    fn closeKey(r: *Server, key: u64, how: auth_client.Ending) Error!void {
        if (how == .answered) r.client.finish(key) else r.client.cancel(key);
        if (r.kept(key) == null) return;
        r.unkeep(key);
        _ = try r.auth.ended(key, how);
        try r.runAuth(null);
    }

    fn runAuth(r: *Server, now_key: ?u64) Error!void {
        while (r.auth.actions.items.len > 0) {
            const action = r.auth.actions.orderedRemove(0);
            switch (action) {
                .post => |p| if (now_key != null and p.key == now_key.?) {
                    try r.dispatch(p.key, p.token);
                } else r.dispatch(p.key, p.token) catch |err| switch (err) {
                    error.TooManyInFlight, error.ConcurrencyUnavailable => try r.onEnded(p.key, 0, .broken, null),
                    else => return err,
                },
                .give_up => |g| try r.authGaveUp(g.key, g.why),
                .needs_sign_in => |n| r.emit(.{ .auth_required = .{ .step_up = n.step_up, .refused = n.refused } }),
                .authorize => |url| r.emit(.{ .authorize = url }),
                .signed_in => r.emit(.signed_in),
                .sign_in_failed => |f| r.emit(.{ .sign_in_failed = .{ .why = f.why, .message = f.message } }),
                .save => r.emit(.credential),
                .refresh_due => r.emit(.refresh_due),
                .refresh_ended => r.emit(.refresh_ended),
            }
        }

        const key = r.auth.refresh_key;
        if (key != 0 and key != r.refresh_timed) {
            r.refresh_timed = key;
            try r.timers.append(r.gpa, .{ .kind = .{ .refresh = key }, .due_ms = r.now() + r.options.timeouts.refresh_ms });
        }
    }

    fn dispatch(r: *Server, key: u64, token: u32) Error!void {
        const k = r.kept(key) orelse return;
        var count = k.headers.len - 1;
        if (r.auth.authorization(token)) |value| {
            k.headers[count] = .{ .name = "authorization", .value = value };
            count += 1;
        }
        if (r.sse_link and k.method == .post) {
            const endpoint = r.sse_endpoint orelse return error.NotReady;
            if (key < aux_base) try r.stepSse(.{ .send = key });
            return r.client.sendTo(key, .post, endpoint, k.body, k.headers[0..count]);
        }
        try r.client.send(key, k.method, k.body, k.headers[0..count]);
    }

    fn authGaveUp(r: *Server, key: u64, why: auth_core.GiveUp) Error!void {
        r.unkeep(key);
        if (key < aux_base) if (r.logicalFor(key)) |l| {
            l.needs_auth = why == .needs_sign_in;
            l.unrenewed = why == .failed;
            if ((l.what == .discover or l.what == .initialize) and !r.detector.ready()) return r.abortDetection(why);
            if (why == .failed and l.what == .listen) return r.onEndedDomain(key, 0, .broken);
            return r.onEndedDomain(key, 401, .http_failure);
        };
        try r.onEndedDomain(key, if (why == .needs_sign_in) 401 else 0, if (why == .needs_sign_in) .http_failure else .broken);
    }

    fn abortDetection(r: *Server, why: auth_core.GiveUp) Error!void {
        for (&r.logicals) |*l| if (l.used and (l.what == .discover or l.what == .initialize)) {
            if (l.id) |id| {
                try r.stepRequest(.{ .transport_lost = id });
                try r.closeKey(id, .forgotten);
            }
            l.used = false;
        };
        var i: usize = 0;
        while (i < r.timers.items.len) {
            if (r.timers.items[i].kind == .probe) _ = r.timers.swapRemove(i) else i += 1;
        }
        r.legacy = null;
        try r.endElicitations();
        r.newEraRun();
        r.emit(.{ .failed = if (why == .needs_sign_in) .needs_auth else .auth_unavailable });
    }

    fn newEraRun(r: *Server) void {
        r.detector = .init(r.options.era);
        r.era_run += 1;
        r.era_instance = std.mem.print(&r.era_instance_buf, "remote.{d}", .{r.era_run}) catch "remote.n";
    }

    fn armRequestTimer(r: *Server, timer: request.Timer, after_ms: u32) Error!void {
        const due_ms = r.now() + after_ms;
        if (timer.kind == .idle) for (r.timers.items) |*t| {
            if (t.kind == .request and t.kind.request.id == timer.id and t.kind.request.kind == .idle) {
                t.* = .{ .kind = .{ .request = timer }, .due_ms = due_ms };
                return;
            }
        };
        try r.timers.append(r.gpa, .{ .kind = .{ .request = timer }, .due_ms = due_ms });
    }

    fn stepRequest(r: *Server, event: request.Event) Error!void {
        var out: request.Output = .{};
        r.table.step(event, &out) catch return;
        if (r.tracer()) |t| try request.writeTrace(t, "remote", &out);

        for (out.effects()) |effect| if (effect == .deliver and effect.deliver.outcome == .timed_out) {
            if (r.logicalFor(effect.deliver.id)) |l| l.timed_out = true;
        };
        for (out.effects()) |effect| switch (effect) {
            .write_request => {},

            .send_cancel => |id| if (r.pipe()) {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .notification(&body.writer, "notifications/cancelled", .{});
                try w.field("requestId");
                try w.int(@intCast(id));
                try w.end();
                try r.notify(body.written());
            } else try r.stepLegacy(.{ .cancel = id }),
            .deliver => |d| if (r.pipe()) {
                if (r.sse_link) try r.stepSse(.{ .done = d.id });
                try r.stdioDelivered(d.id, d.outcome);
            } else switch (d.outcome) {
                .timed_out => if (r.logicalFor(d.id)) |l| {
                    if (r.legacy == null) try r.stepExchange(l, .cancel) else if (l.what == .initialize) try r.onInitializeTimedOut(l, d.id);
                },

                .ended => if (r.logicalFor(d.id)) |l| {
                    try r.stepSubs(.{ .final = .{ .id = d.id, .end = .server_cancelled } });
                    try r.stepExchange(l, .cancel);
                },
                else => {},
            },
            .arm_timer => |a| try r.armRequestTimer(a.timer, a.after_ms),
            .disarm_timers => |id| {
                var i: usize = 0;
                while (i < r.timers.items.len) {
                    const t = r.timers.items[i];
                    if (t.kind == .request and t.kind.request.id == id) _ = r.timers.swapRemove(i) else i += 1;
                }
            },
        };
    }

    fn stepEra(r: *Server, event: era.Event) Error!void {
        const was = r.detector.state;
        var out: era.Output = .{};
        r.detector.step(event, &out) catch return;
        if (was == .unknown and r.detector.state != .unknown) r.start_due_ms = r.now() + r.options.timeouts.start_ms;
        if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
        for (out.effects()) |effect| switch (effect) {
            .send_discover => |i| {
                r.legacy = null;
                try r.endElicitations();
                const l = try r.newLogical(.{ .discover = i }, .idempotent);
                if (r.pipe()) try r.sendAttempt(l) else try r.stepExchange(l, .send);
            },
            .send_initialize => if (r.pipe()) try r.sendAttempt(try r.newLogical(.initialize, .idempotent)) else try r.startSession(),

            .send_initialized => if (r.pipe()) {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try era.writeInitialized(&body.writer);
                try r.notify(body.written());
            },
            .arm_probe_timer => |a| try r.timers.append(r.gpa, .{ .kind = .{ .probe = a.probe }, .due_ms = r.now() + r.startLeft(a.after_ms) }),
            .ready => |v| {
                const run = if (r.stdio) r.era_generation else r.era_run;
                const first = r.catalog_generation != run;
                r.catalog_generation = run;
                if (r.stdio) r.proc.setEra(if (v == .legacy) .legacy else .modern) catch {};
                r.stray_len = 0;
                r.emit(.{ .ready = era.versionName(r.detector.config, v).? });
                if (first) try r.stepCatalog(.{ .process_started = if (v == .legacy) .legacy else .modern });

                if (r.stdio and v != .legacy and !r.subs.up) try r.stepSubs(.transport_up);
                if (first and v != .legacy and r.options.listen_tools) try r.listen(0, subscription.bit(.tools), false);
            },
            .failed => |f| {
                if (r.stdio) r.proc.stop() catch {};
                r.emit(.{ .failed = .{ .era = f } });
            },
        };
    }

    fn stepCatalog(r: *Server, event: catalog.Event) Error!void {
        var out: catalog.Output = .{};
        const generation = r.catalog.generation;
        const was_fresh = r.catalog.cache == .fresh;
        r.catalog.step(event, &out) catch return;
        if (r.tracer()) |t| try catalog.writeTrace(t, "remote", &out);

        const changed = r.catalog.generation != generation and (r.catalog.cache != .none or r.catalog.listing);
        if (changed or (was_fresh and r.catalog.cache != .fresh)) r.emit(.tools_stale);
        for (out.effects()) |effect| switch (effect) {
            .send_page => {
                const l = try r.newLogical(.list, .idempotent);
                try r.start(l);
            },
            .discard_pages => r.store.discard(),
            .publish => |fresh| {
                r.store.publish();
                r.emit(.{ .tools = .{ .ok = true, .fresh = fresh, .dropped = r.last_added } });
                try r.relisted(true);
            },
            .fail => {
                r.store.discard();
                r.emit(.{ .tools = .{ .ok = false, .fresh = false, .needs_auth = r.page_needs_auth } });
                r.page_needs_auth = false;
                try r.relisted(false);
            },

            .serve_last => {
                r.store.discard();
                r.emit(.{ .tools = .{ .ok = !r.page_needs_auth, .fresh = false, .needs_auth = r.page_needs_auth } });
                r.page_needs_auth = false;
                try r.relisted(false);

                r.emit(.tools_stale);
            },
            .serve => r.emit(.{ .tools = .{ .ok = true, .fresh = true } }),
            .arm_expiry => |a| try r.timers.append(r.gpa, .{ .kind = .{ .expiry = a.generation }, .due_ms = r.now() + a.after_ms }),
        };
    }

    fn relisted(r: *Server, ok: bool) Error!void {
        if (r.pipe() or r.legacy != null) return;
        for (&r.logicals) |*l| if (l.used and l.exchange.phase == .relisting) try r.stepExchange(l, .{ .relisted = ok });
    }

    fn listen(r: *Server, sub: u8, filter: subscription.Filter, resend: bool) Error!void {
        if (!resend and !r.subs.canOpen(sub)) return;
        const l = try r.newLogical(.listen, .call);
        l.sub = sub;
        l.filter = filter;
        l.resend = resend;
        if (r.pipe()) try r.sendAttempt(l) else try r.stepExchange(l, .send);
    }

    fn stepSubs(r: *Server, event: subscription.Event) Error!void {
        var out: subscription.Output = .{};
        r.subs.step(event, &out);
        if (r.tracer()) |t| try subscription.writeTrace(t, "remote", &r.subs, event, &out);
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| if (d.kind == .tools) try r.stepCatalog(.invalidated),
            .acknowledged => |a| r.emit(.{ .listening = a.filter }),
            .ended => |e| r.emit(.{ .listen_ended = e.end }),

            .cancel_listen => |id| if (r.logicalFor(id)) |l| {
                try r.stepRequest(.{ .cancel_requested = id });
                if (!r.pipe()) try r.stepExchange(l, .cancel);
            },

            .arm_retry => |a| if (!r.pipe()) try r.timers.append(r.gpa, .{ .kind = .{ .relisten = .{ .sub = a.sub, .generation = a.generation } }, .due_ms = r.now() + a.after_ms }),
            .relisten => |sub| try r.listen(sub, r.subs.subs[sub].asked, true),
        };
    }

    fn fireTimers(r: *Server) Error!void {
        var i: usize = 0;
        while (i < r.timers.items.len) {
            const t = r.timers.items[i];
            if (t.due_ms > r.now()) {
                i += 1;
                continue;
            }
            _ = r.timers.swapRemove(i);
            switch (t.kind) {
                .request => |timer| try r.stepRequest(.{ .timer_fired = timer }),
                .probe => |probe| try r.stepEra(.{ .probe_timer_fired = probe }),
                .expiry => |generation| try r.stepCatalog(.{ .expired = generation }),
                .resume_stream => |id| try r.stepLegacy(.{ .resume_due = id }),
                .listen => try r.stepLegacy(.listen_due),
                .listen_wait => try r.listenSettled(),
                .backoff => |handle| if (r.logicalByHandle(handle)) |l| try r.stepChain(l, .backoff_elapsed),
                .relisten => |x| try r.stepSubs(.{ .retry_due = .{ .sub = x.sub, .generation = x.generation } }),
                .initialized => |key| if (r.initialized_key == key) try r.onInitializedTimedOut(),

                .refresh => |key| if (r.auth.refresh_key == key) {
                    r.client.cancel(key);
                    _ = try r.auth.fetched(key, 0, "", null, "");
                    try r.runAuth(null);
                },
            }
            i = 0;
        }
    }
};

test {
    std.testing.refAllDecls(Server);
    _ = http_sse;
}

test "a send that fails after the outbox took its copy frees the copy once" {
    var r: Server = undefined;

    try r.init(std.testing.io, std.testing.allocator, .{
        .link = .{ .http = .{ .url = "http://127.0.0.1:1/mcp", .max_in_flight = 0 } },
        .client = .{ .info = .{ .name = "test", .version = "0" } },
    });
    defer r.deinit();
    const headers = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};

    var key: u64 = 1;
    const failed = while (key < 100) : (key += 1) {
        r.send(key, .post, "{}", &headers) catch |err| break err;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(error.TooManyInFlight, failed);
    try std.testing.expectEqual(@as(u64, 33), key);

    try std.testing.expect(r.kept(key) == null);
    try std.testing.expect(r.kept(key - 1) != null);
}
