const std = @import("std");
const observation = @import("../agent/runtime/observation.zig");
const mcp = @import("../../mcp/mcp.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const io_mod = @import("../shared/io.zig");
const host_target = @import("../hosts/target.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const url_opener = @import("../hosts/url_opener.zig");
const secret = @import("../auth/secret.zig");
const config = @import("config.zig");
const ignore_lines = @import("../mcp/ignore_lines.zig");
const credentials = @import("credentials.zig");
const loopback = @import("login.zig");
const elicitation = @import("../mcp/elicitation.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const engine = mcp.engine;

const login_timeout_ms: i64 = 15 * 60 * 1000;
const max_idle_wait_ms: u32 = 1000;
const revoke_wait_ms: i64 = 2000;
const refresh_answer_ms: i64 = (@FieldType(mcp.engine.Options, "timeouts"){}).refresh_ms;
const refresh_retry_ms: u32 = 20;
const client_name = "kimi-code";
const client_capabilities = "{}";
const form_client_capabilities = "{\"elicitation\":{\"form\":{}}}";
const url_client_capabilities = "{\"elicitation\":{\"url\":{}}}";
const form_url_client_capabilities = "{\"elicitation\":{\"form\":{},\"url\":{}}}";

fn writeIgnoreLines(gpa: Allocator, scratch: Allocator, configs: []const mcp_contract.McpServerConfig, servers: []const config.Server, workspace_root: []const u8) void {
    const lines = config.ignoreLines(scratch, configs, servers) catch return;
    if (lines.len == 0) return;
    const outcome = ignore_lines.apply(gpa, workspace_root, lines) catch |err| {
        debug_trace.logf("mcp", "MCP ignore lines not written lines={d} err={s}", .{ lines.len, @errorName(err) });
        return;
    };
    debug_trace.logf("mcp", "MCP ignore lines outcome={s} lines={d}", .{ @tagName(outcome), lines.len });
}

fn clientCapabilities(questions: elicitation.Capabilities) []const u8 {
    if (questions.form and questions.url) return form_url_client_capabilities;
    if (questions.form) return form_client_capabilities;
    if (questions.url) return url_client_capabilities;
    return client_capabilities;
}

test "MCP client identifies itself with the Kimi client name" {
    try std.testing.expectEqualStrings("kimi-code", client_name);
}

test "MCP sign-in waits fifteen minutes for the browser callback" {
    try std.testing.expectEqual(@as(i64, 15 * 60 * 1000), login_timeout_ms);
}

test "MCP client declares no elicitation, sampling, or roots capability" {
    try std.testing.expectEqualStrings("{}", client_capabilities);
}

pub fn signalServersForExit() void {
    if (comptime host_target.is_wasm) return;
    mcp.stdio.signalAllForExit(io_mod.getIo());
    mcp.http.readBoundedStreamsToTheirEndForExit(io_mod.getIo());
}

var retiring: std.atomic.Value(u32) = .init(0);
const held_recheck_ms: u32 = 50;

fn retireStarted() void {
    _ = retiring.fetchAdd(1, .acq_rel);
}

fn retireEnded() void {
    _ = retiring.fetchSub(1, .acq_rel);
}

pub fn waitRetired() void {
    while (retiring.load(.acquire) != 0) io_mod.sleep(5 * std.time.ns_per_ms);
}

pub const State = enum {
    idle,
    connecting,
    ready,
    retrying,
    failed,
    disabled,
    waiting_for_approval,
    rejected,
    unsupported,
    missing_env,
    invalid_env,
    removed,
};

pub const Status = struct {
    name: []const u8,
    source: mcp_contract.ConfigSource,
    transport: mcp_contract.McpTransport,
    state: State,
    version: ?[]const u8 = null,
    tools: usize = 0,
    last_error: ?[]const u8 = null,
    needs_login: bool = false,
    signed_in: bool = false,
    signing_in: bool = false,
    missing: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    next_retry_at_ms: ?i64 = null,
};

pub const Tool = struct { name: []const u8, raw: []const u8 };

pub const ToolsResult = union(enum) {
    tools: []Tool,
    needs_login,
    failed: []const u8,
    unknown_server,
};

pub const CallResult = union(enum) {
    result: struct { content: []const u8, structured: ?[]const u8, is_error: bool },
    failure: struct { code: i64, message: []const u8 },
    ended: struct { outcome: engine.Outcome, maybe_ran: bool, timed_out: bool, why: ?[]const u8 = null },
    unknown_server,
};

pub const ResourceResult = union(enum) {
    result: []const u8,
    failure: struct { code: i64, message: []const u8 },
    ended: struct { outcome: engine.Outcome },
    unknown_server,
};

pub const SignInResult = union(enum) {
    signed_in,
    already_signed_in,
    failed: struct { reason: []const u8, url: ?[]const u8 },
    unknown_server,
};

pub const Question = struct {
    server: []const u8,
    input_requests_json: []const u8,
    version: ?[]const u8,
    url_wait: ?*const tool_mcp_runtime.LegacyUrlCompletionSignal = null,
};

pub const Asker = struct {
    context: *anyopaque,
    ask: *const fn (context: *anyopaque, alloc: Allocator, question: Question) anyerror!?[]u8,
};

pub const Notice = union(enum) {
    authorize: struct { server: []const u8, url: []const u8 },
    signed_in: []const u8,
    sign_in_failed: struct { server: []const u8, reason: []const u8 },
    needs_login: []const u8,
    not_saved: struct { server: []const u8, reason: []const u8 },
};

pub const Notify = struct {
    context: *anyopaque,
    notice: *const fn (context: *anyopaque, notice: Notice) void,
};

pub const Options = struct {
    client_version: []const u8,
    credentials: union(enum) { detect: []const u8, store: credentials.Store },
    workspace_root: []const u8 = "",
    notify: ?Notify = null,
    questions: elicitation.Capabilities = .{},
    url_completions: ?tool_mcp_runtime.LegacyUrlCompletionSink = null,
    slash_commands: bool = false,
    reconnect_initial_delay_ms: ?u32 = null,
    reconnect_max_delay_ms: ?u32 = null,
    reconnect_jitter: bool = true,
};

fn reconnectGate(options: Options) @FieldType(mcp.engine.Options, "gate") {
    var gate: @FieldType(mcp.engine.Options, "gate") = .{};
    if (options.reconnect_initial_delay_ms) |initial_ms| gate.reconnect_initial_ms = initial_ms;
    if (options.reconnect_max_delay_ms) |cap_ms| gate.reconnect_cap_ms = cap_ms;
    return gate;
}

test "the configured reconnect delays reach the engine, and Kimi's defaults stand without them" {
    const defaults = reconnectGate(.{ .client_version = "0", .credentials = .{ .detect = "" } });
    try std.testing.expectEqual(@as(u32, 5_000), defaults.reconnect_initial_ms);
    try std.testing.expectEqual(@as(u32, 300_000), defaults.reconnect_cap_ms);
    try std.testing.expectEqual(@as(?u8, null), defaults.max_attempts);

    const tuned = reconnectGate(.{ .client_version = "0", .credentials = .{ .detect = "" }, .reconnect_initial_delay_ms = 250, .reconnect_max_delay_ms = 4_000 });
    try std.testing.expectEqual(@as(u32, 250), tuned.reconnect_initial_ms);
    try std.testing.expectEqual(@as(u32, 4_000), tuned.reconnect_cap_ms);
}

pub const Error = Allocator.Error || error{
    UnknownServer,
    NotHttp,
    Held,
    NotSigningIn,
    Stopped,
    Cancelled,
    Failed,
    CredentialStoreUnreadable,
    CallbackPortInUse,
};

const Request = struct {
    observation: ?observation.McpCall = null,
    kind: Kind,
    alloc: Allocator,
    done: std.Io.Event = .unset,
    result: Outcome = .none,
    owned: bool = false,
    owned_url: ?[]u8 = null,
    asker: ?Asker = null,
    progress: ?mcp_contract.ProgressSink = null,
    note: ?mcp_contract.Progress = null,
    question: ?Pending = null,
    logout_kept: ?anyerror = null,
    declined_by_fx: bool = false,
    urls: std.ArrayList(UrlNeed) = .empty,
    url_phase: enum { none, consent, waiting } = .none,
    url_server: usize = 0,
    url_failure: ?CallResult = null,
    url_signal: tool_mcp_runtime.LegacyUrlCompletionSignal = .{},

    const Kind = union(enum) {
        tools: []const u8,
        need: []const u8,
        call: struct { server: []const u8, tool: []const u8, arguments: ?[]const u8 },
        resource: struct { server: []const u8, op: mcp.resources.Op },
        cancel: *Request,
        login: struct { server: []const u8, open_browser: bool },
        finish_login: struct { server: []const u8, url: []const u8 },
        logout: []const u8,
        pick_up,
        authenticate: struct { server: []const u8, open_browser: bool },
        answer: struct { pending: Pending, json: ?[]u8 },
        reload: struct { configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map },
        refresh: []const u8,

        fn mayStart(k: Kind) bool {
            return switch (k) {
                .tools, .need, .call, .resource, .login, .finish_login, .pick_up, .authenticate => true,
                .cancel, .logout, .answer, .reload, .refresh => false,
            };
        }

        fn starts(k: Kind) ?[]const u8 {
            return switch (k) {
                .tools => |name| name,
                .need => |name| name,
                .call => |c| c.server,
                .resource => |c| c.server,
                .login => |l| l.server,
                .finish_login => |f| f.server,
                .authenticate => |a| a.server,
                .pick_up, .cancel, .logout, .answer, .reload, .refresh => null,
            };
        }
    };

    const Outcome = union(enum) {
        none,
        ok,
        failed: Error,
        tools: ToolsResult,
        call: CallResult,
        resource: ResourceResult,
        reloaded: Reloaded,
        authenticated: SignInResult,
    };
};

const Pending = struct {
    name: []const u8,
    server: u64,
    json: []u8,
    version: ?[]u8,
    reply: union(enum) {
        input: struct { call: engine.Handle, keys: [][]u8 },
        elicit: mcp.core.elicitation.Id,
        url_consent: *Request,
        url_wait: *Request,
    },

    fn deinit(p: *Pending, gpa: Allocator) void {
        gpa.free(p.json);
        if (p.version) |v| gpa.free(v);
        switch (p.reply) {
            .input => |input| {
                for (input.keys) |k| gpa.free(k);
                gpa.free(input.keys);
            },
            .elicit, .url_consent, .url_wait => {},
        }
        p.* = undefined;
    }
};

const UrlNeed = struct {
    id: mcp.core.elicitation.Id,
    params: []u8,
    seen: bool = false,
    dropped: bool = false,
};

const url_elicitation_required: i64 = -32042;
const static_credentials_rejected = "the server rejected the configured credentials with 401 Unauthorized; correct the bearer token or headers in its MCP config";
const sign_in_timed_out = "the browser didn't come back within 15 minutes";
const sign_in_url_status =
    "Open this URL in your browser to authorize \"{s}\":\n\n{s}\n\n" ++
    "Waiting for the OAuth callback (timeout 15 min). " ++
    "If you cancel, call this tool again to restart the flow.";

fn signInFailed(alloc: Allocator, reason: []const u8, url: ?[]const u8) Allocator.Error!SignInResult {
    const owned_reason = try alloc.dupe(u8, reason);
    errdefer alloc.free(owned_reason);
    return .{ .failed = .{ .reason = owned_reason, .url = if (url) |address| try alloc.dupe(u8, address) else null } };
}
const removed_server_call_reason = "the server was removed from the MCP config (plugin uninstalled or config deleted). Do not call this tool again";

const Login = struct {
    runtime: *Runtime,
    server: usize,
    name: []const u8,
    listener: loopback.Listener,
    group: std.Io.Group = .init,
    deadline_ms: i64,
    open_browser: bool,
    callback: ?[]u8 = null,
    url: ?[]u8 = null,
};

pub const Reloaded = struct {
    kept: []const bool,
    dropped: bool,
};

pub const Runtime = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    arena: std.heap.ArenaAllocator,
    resolved: config.Resolved,
    engine: engine.Engine,
    flags: []Flags,
    ids: []u64,
    next_id: u64 = 1,
    tools_epochs: []std.atomic.Value(u64),
    awaiting_dropped_stop: bool = false,
    session_servers: []const []const u8 = &.{},
    thread: ?std.Thread = null,
    retired: std.atomic.Value(bool) = .init(false),

    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(*Request) = .empty,
    stopping: bool = false,
    callers_inside: std.atomic.Value(u32) = .init(0),
    snapshot: []Status = &.{},
    snapshot_arena: std.heap.ArenaAllocator,
    credentials_restored: std.Io.Event = .unset,

    calls: std.AutoHashMapUnmanaged(engine.Handle, *Request) = .empty,
    tool_waiters: std.ArrayList(struct { server: usize, request: *Request }) = .empty,
    logins: std.ArrayList(*Login) = .empty,
    sign_in_waiters: std.ArrayList(struct { server: usize, request: *Request }) = .empty,
    url_questions: std.ArrayList(struct { server: usize, slot: u8, id: []u8 }) = .empty,
    required: std.ArrayList(struct { server: usize, need: UrlNeed }) = .empty,
    held: std.ArrayList(*Request) = .empty,
    logouts: std.ArrayList(struct { server: usize, request: *Request, deadline_ms: i64 }) = .empty,
    refreshes: std.ArrayList(Refresh) = .empty,
    finished: std.ArrayList(*Request) = .empty,

    const Flags = struct {
        needs_login: bool = false,
        signed_in: bool = false,
        last_saved_digest: ?[32]u8 = null,
        not_saved: bool = false,
        tools_when_removed: usize = 0,
        credentials_rejected: bool = false,
        static_retry: enum { none, pending, used } = .none,
        awaiting_auth: bool = false,
        awaiting_tools: bool = false,
    };

    const Refresh = struct {
        server: usize,
        lock: ?credentials.Store.Locked = null,
        sent: bool = false,
        awake_started_ms: i64,
    };

    pub fn start(
        r: *Runtime,
        gpa: Allocator,
        io: std.Io,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        options: Options,
    ) !void {
        r.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .arena = .init(gpa),
            .resolved = undefined,
            .engine = undefined,
            .flags = &.{},
            .ids = &.{},
            .tools_epochs = &.{},
            .snapshot_arena = .init(gpa),
        };
        errdefer r.arena.deinit();
        errdefer r.snapshot_arena.deinit();
        const arena = r.arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const resolved = try config.resolve(scratch.allocator(), configs, inherited, r.options.workspace_root);
        writeIgnoreLines(gpa, scratch.allocator(), configs, resolved.servers, r.options.workspace_root);
        const n = resolved.servers.len;
        r.resolved = .{ .servers = try config.keepServers(arena, resolved.servers, &.{}), .engine = &.{}, .engine_server = try arena.dupe(usize, resolved.engine_server) };
        const session_servers = try arena.alloc([]const u8, n);
        for (r.resolved.servers, session_servers) |server, *name| name.* = server.name;
        r.session_servers = session_servers;
        r.flags = try gpa.alloc(Flags, n);
        errdefer gpa.free(r.flags);
        for (r.flags) |*f| f.* = .{};
        r.ids = try gpa.alloc(u64, n);
        errdefer gpa.free(r.ids);
        for (r.ids) |*id| id.* = r.newId();
        r.tools_epochs = try gpa.alloc(std.atomic.Value(u64), n);
        errdefer gpa.free(r.tools_epochs);
        for (r.tools_epochs) |*e| e.* = .init(0);

        try r.engine.init(io, gpa, .{ .context = r, .allow = allow, .log = log }, .{
            .client = .{ .info = .{ .name = client_name, .version = options.client_version }, .capabilities = clientCapabilities(options.questions), .workspace = options.workspace_root },
            .gate = reconnectGate(options),
            .reconnect_jitter = options.reconnect_jitter,
        }, resolved.engine);
        errdefer r.engine.deinit();
        try r.publish();
        r.thread = try std.Thread.spawn(.{}, run, .{r});
    }

    pub fn retire(r: *Runtime) void {
        if (!r.retired.swap(true, .acq_rel)) retireStarted();
    }

    fn waitsForRetired(r: *const Runtime) bool {
        return !r.retired.load(.acquire) and retiring.load(.acquire) != 0;
    }

    pub fn deinit(r: *Runtime) void {
        r.mutex.lockUncancelable(r.io);
        r.stopping = true;
        r.mutex.unlock(r.io);
        r.engine.wake();
        if (r.thread) |t| t.join();

        while (r.callers_inside.load(.acquire) != 0) std.Io.sleep(r.io, .fromMilliseconds(1), .awake) catch {};
        r.queue.deinit(r.gpa);
        r.calls.deinit(r.gpa);
        r.tool_waiters.deinit(r.gpa);
        r.logins.deinit(r.gpa);
        r.sign_in_waiters.deinit(r.gpa);
        r.logouts.deinit(r.gpa);
        r.refreshes.deinit(r.gpa);
        for (r.url_questions.items) |q| r.gpa.free(q.id);
        r.url_questions.deinit(r.gpa);
        for (r.required.items) |q| r.gpa.free(q.need.params);
        r.required.deinit(r.gpa);
        r.held.deinit(r.gpa);
        r.finished.deinit(r.gpa);
        r.gpa.free(r.flags);
        r.gpa.free(r.ids);
        r.gpa.free(r.tools_epochs);
        r.snapshot_arena.deinit();
        r.arena.deinit();
        const was_retired = r.retired.load(.acquire);
        r.* = undefined;

        if (was_retired) retireEnded();
    }

    pub fn statuses(r: *Runtime, alloc: Allocator) Allocator.Error![]Status {
        _ = r.callers_inside.fetchAdd(1, .acq_rel);
        defer _ = r.callers_inside.fetchSub(1, .acq_rel);
        r.credentials_restored.waitUncancelable(r.io);
        return r.statusesNow(alloc);
    }

    pub fn statusesNow(r: *Runtime, alloc: Allocator) Allocator.Error![]Status {
        _ = r.callers_inside.fetchAdd(1, .acq_rel);
        defer _ = r.callers_inside.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const out = try alloc.alloc(Status, r.snapshot.len);
        for (r.snapshot, out) |s, *o| {
            o.* = s;
            o.name = try alloc.dupe(u8, s.name);
            if (s.version) |v| o.version = try alloc.dupe(u8, v);
            if (s.last_error) |e| o.last_error = try alloc.dupe(u8, e);
            if (s.missing) |m| o.missing = try alloc.dupe(u8, m);
            if (s.instructions) |t| o.instructions = try alloc.dupe(u8, t);
        }
        return out;
    }

    pub fn instructions(r: *Runtime, alloc: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        _ = r.callers_inside.fetchAdd(1, .acq_rel);
        defer _ = r.callers_inside.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.snapshot) |s| if (std.mem.eql(u8, s.name, name)) {
            const text = s.instructions orelse return null;
            return try alloc.dupe(u8, text);
        };
        return null;
    }

    pub fn toolsEpoch(r: *Runtime, name: []const u8) u64 {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const i = r.serverIndex(name) orelse return 0;
        return r.tools_epochs[i].load(.acquire);
    }

    pub fn servers(r: *Runtime) []const config.Server {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return r.resolved.servers;
    }

    pub fn tools(r: *Runtime, alloc: Allocator, server: []const u8, cancel: ?*const std.atomic.Value(bool)) Error!ToolsResult {
        var req: Request = .{ .kind = .{ .tools = server }, .alloc = alloc };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .tools => |t| t,
            .failed => |err| err,
            else => unreachable,
        };
    }

    pub fn prepare(r: *Runtime, name: []const u8) Error!void {
        const req = try r.gpa.create(Request);
        req.* = .{ .kind = .{ .need = name }, .alloc = r.gpa, .owned = true };
        r.post(req) catch |err| {
            r.gpa.destroy(req);
            return err;
        };
    }

    pub fn reload(r: *Runtime, configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map) Error!Reloaded {
        var req: Request = .{ .kind = .{ .reload = .{ .configs = configs, .inherited = inherited } }, .alloc = r.gpa };
        try r.submit(&req, null);
        return switch (req.result) {
            .reloaded => |done| done,
            .failed => |err| err,
            else => unreachable,
        };
    }

    pub fn call(
        r: *Runtime,
        alloc: Allocator,
        server: []const u8,
        tool: []const u8,
        arguments: ?[]const u8,
        cancel: ?*const std.atomic.Value(bool),
        asker: ?Asker,
    ) Error!CallResult {
        return r.callObserved(alloc, server, tool, arguments, cancel, asker, null, null);
    }

    pub fn callObserved(r: *Runtime, alloc: Allocator, server: []const u8, tool: []const u8, arguments: ?[]const u8, cancel: ?*const std.atomic.Value(bool), asker: ?Asker, progress: ?mcp_contract.ProgressSink, observed: ?observation.McpCall) Error!CallResult {
        var req: Request = .{ .kind = .{ .call = .{ .server = server, .tool = tool, .arguments = arguments } }, .alloc = alloc, .asker = asker, .progress = progress, .observation = observed };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .call => |c| c,
            .failed => |err| err,
            else => unreachable,
        };
    }

    pub fn resource(r: *Runtime, alloc: Allocator, server: []const u8, op: mcp.resources.Op, cancel: ?*const std.atomic.Value(bool)) Error!ResourceResult {
        var req: Request = .{ .kind = .{ .resource = .{ .server = server, .op = op } }, .alloc = alloc };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .resource => |c| c,
            .failed => |err| err,
            else => unreachable,
        };
    }

    pub fn login(r: *Runtime, server: []const u8, open_browser: bool) Error!void {
        var req: Request = .{ .kind = .{ .login = .{ .server = server, .open_browser = open_browser } }, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    pub fn authenticate(
        r: *Runtime,
        alloc: Allocator,
        server: []const u8,
        open_browser: bool,
        cancel: ?*const std.atomic.Value(bool),
        progress: ?mcp_contract.ProgressSink,
    ) Error!SignInResult {
        var req: Request = .{ .kind = .{ .authenticate = .{ .server = server, .open_browser = open_browser } }, .alloc = alloc, .progress = progress };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .authenticated => |outcome| outcome,
            .failed => |err| err,
            else => unreachable,
        };
    }

    pub fn finishLogin(r: *Runtime, server: []const u8, url: []const u8) Error!void {
        var req: Request = .{ .kind = .{ .finish_login = .{ .server = server, .url = url } }, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    pub fn logout(r: *Runtime, server: []const u8) Error!?anyerror {
        var req: Request = .{ .kind = .{ .logout = server }, .alloc = r.gpa };
        try r.submitOk(&req);
        return req.logout_kept;
    }

    pub fn pickUpLogins(r: *Runtime) Error!void {
        var req: Request = .{ .kind = .pick_up, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    fn submitOk(r: *Runtime, req: *Request) Error!void {
        try r.submit(req, null);
        switch (req.result) {
            .ok => {},
            .failed => |err| return err,
            else => unreachable,
        }
    }

    fn submit(r: *Runtime, req: *Request, cancel: ?*const std.atomic.Value(bool)) Error!void {
        _ = r.callers_inside.fetchAdd(1, .acq_rel);
        defer _ = r.callers_inside.fetchSub(1, .acq_rel);
        const io = r.io;
        try r.post(req);
        var cancel_req: Request = .{ .kind = .{ .cancel = req }, .alloc = r.gpa };
        var cancel_tried = false;
        var cancel_sent = false;
        while (!req.done.isSet()) {
            req.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
            if (req.asker) |asker| r.askWaiting(req, asker);
            if (req.progress) |sink| r.reportProgress(req, sink);
            if (!cancel_tried) if (cancel) |flag| if (flag.load(.acquire)) {
                cancel_tried = true;

                cancel_sent = if (r.post(&cancel_req)) |_| true else |_| false;
            };
        }
        if (cancel_sent) cancel_req.done.waitUncancelable(io);

        if (req.progress) |sink| r.reportProgress(req, sink);
    }

    fn reportProgress(r: *Runtime, req: *Request, sink: mcp_contract.ProgressSink) void {
        r.mutex.lockUncancelable(r.io);
        const note = req.note orelse {
            r.mutex.unlock(r.io);
            return;
        };
        req.note = null;
        r.mutex.unlock(r.io);
        defer if (note.message) |m| r.gpa.free(m);
        sink.callback(sink.context, note);
    }

    fn askWaiting(r: *Runtime, req: *Request, asker: Asker) void {
        r.mutex.lockUncancelable(r.io);
        var pending = req.question orelse {
            r.mutex.unlock(r.io);
            return;
        };
        req.question = null;
        r.mutex.unlock(r.io);
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const answer = asker.ask(asker.context, scratch.allocator(), .{
            .server = pending.name,
            .input_requests_json = pending.json,
            .version = pending.version,
            .url_wait = if (pending.reply == .url_wait) &req.url_signal else null,
        }) catch |err| answer: {
            debug_trace.logf("mcp", "MCP question not answered server={s} err={s}", .{ pending.name, @errorName(err) });
            break :answer null;
        };
        const reply = r.gpa.create(Request) catch return pending.deinit(r.gpa);
        reply.* = .{ .kind = .{ .answer = .{ .pending = pending, .json = null } }, .alloc = r.gpa, .owned = true };
        if (answer) |text| reply.kind.answer.json = r.gpa.dupe(u8, text) catch null;
        r.post(reply) catch r.finish(reply, .ok);
    }

    fn post(r: *Runtime, req: *Request) Error!void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.stopping) return error.Stopped;
        try r.queue.append(r.gpa, req);
        r.engine.wake();
    }

    fn run(r: *Runtime) void {
        r.restoreCredentials();
        while (true) {
            const stopping = r.drain();
            r.flush();
            if (stopping) break;
            const event = r.engine.next(r.waitMs()) catch |err| {
                debug_trace.logf("mcp", "MCP engine step failed err={s}", .{@errorName(err)});
                std.Io.sleep(r.io, .fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (event) |e| r.onEvent(e) catch |err| {
                debug_trace.logf("mcp", "MCP event handling failed server={s} err={s}", .{ e.server, @errorName(err) });
            };
            r.expireLogins();
            r.endLogouts();
            r.retryRefreshes();
            r.flush();
        }
        r.shutdown();
    }

    fn flush(r: *Runtime) void {
        r.publish() catch |err| debug_trace.logf("mcp", "MCP status not published err={s}", .{@errorName(err)});
        for (r.finished.items) |req| req.done.set(r.io);
        r.finished.clearRetainingCapacity();
    }

    fn drain(r: *Runtime) bool {
        r.awaiting_dropped_stop = false;
        while (true) {
            r.mutex.lockUncancelable(r.io);
            const stopping = r.stopping;
            var taken = r.queue;
            r.queue = .empty;
            var after_reload = false;
            if (!stopping) {
                var batch = taken.items.len;
                for (taken.items, 0..) |req, k| if (req.kind == .reload) {
                    batch = k + 1;
                    break;
                };
                const retiring_now = r.waitsForRetired();
                var kept: usize = 0;
                for (taken.items[0..batch]) |req| {
                    const dropped_stopping = if (req.kind.starts()) |name| r.engine.stopping(name) else false;
                    if ((retiring_now and req.kind.mayStart()) or dropped_stopping) held: {
                        r.queue.append(r.gpa, req) catch break :held;
                        if (dropped_stopping) r.awaiting_dropped_stop = true;
                        continue;
                    }
                    taken.items[kept] = req;
                    kept += 1;
                }
                const rest = taken.items[batch..];
                if (rest.len > 0) {
                    if (r.queue.appendSlice(r.gpa, rest)) |_| {
                        after_reload = true;
                    } else |_| {
                        @memmove(taken.items[kept..][0..rest.len], rest);
                        kept += rest.len;
                    }
                }
                taken.shrinkRetainingCapacity(kept);
            }
            r.mutex.unlock(r.io);
            defer taken.deinit(r.gpa);
            for (taken.items) |req| {
                if (stopping) {
                    r.finish(req, .{ .failed = error.Stopped });
                    continue;
                }
                r.handle(req) catch |err| {
                    debug_trace.logf("mcp", "MCP request failed kind={s} err={s}", .{ @tagName(req.kind), @errorName(err) });
                    r.finish(req, .{ .failed = if (err == error.OutOfMemory) error.OutOfMemory else error.Failed });
                };
            }
            if (stopping or !after_reload) return stopping;
        }
    }

    fn unqueue(r: *Runtime, req: *Request) bool {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.queue.items, 0..) |queued, k| if (queued == req) {
            _ = r.queue.orderedRemove(k);
            return true;
        };
        return false;
    }

    fn handle(r: *Runtime, req: *Request) !void {
        switch (req.kind) {
            .tools => |name| {
                const i = r.serverIndex(name) orelse return r.finish(req, .{ .tools = .unknown_server });
                if (r.heldReason(req.alloc, i)) |why| return r.finish(req, .{ .tools = .{ .failed = try why } });
                if (r.flags[i].needs_login and r.loginFor(i) == null and !try r.pickUpLogin(i)) return r.finish(req, .{ .tools = .needs_login });

                try r.tool_waiters.ensureUnusedCapacity(r.gpa, 1);
                try r.engine.needTools(r.resolved.servers[i].name);
                if (r.keepsFailingToStart(i) and !r.startStaticRetry(i)) return r.finish(req, .{ .tools = .{ .failed = try r.lastError(req.alloc, i) } });
                r.tool_waiters.appendAssumeCapacity(.{ .server = i, .request = req });
            },
            .pick_up => {
                for (r.flags, 0..) |f, i| if (f.needs_login) {
                    _ = try r.pickUpLogin(i);
                };
                r.finish(req, .ok);
            },
            .need => |name| {
                if (r.engineServer(name) != null) r.engine.needTools(name) catch |err| {
                    debug_trace.logf("mcp", "MCP tool list not started server={s} err={s}", .{ name, @errorName(err) });
                };
                r.finish(req, .ok);
            },
            .reload => |c| r.finish(req, .{ .reloaded = try r.applyReload(c.configs, c.inherited) }),
            .refresh => |name| {
                if (r.serverIndex(name)) |i| {
                    r.refreshHeaders(i) catch |err| {
                        debug_trace.logf("mcp", "MCP headers helper not rerun server={s} err={s}", .{ name, @errorName(err) });
                        r.flags[i].credentials_rejected = true;
                        r.endToolWaiters(i, .failed);
                    };
                    r.flags[i].static_retry = .used;
                }
                r.finish(req, .ok);
            },
            .resource => |c| {
                const i = r.serverIndex(c.server) orelse return r.finish(req, .{ .resource = .unknown_server });
                if (r.resolved.servers[i].held != null) return r.finish(req, .{ .failed = error.Held });
                if (r.flags[i].needs_login) _ = try r.pickUpLogin(i);
                try r.sendResource(req, i, c.op);
            },
            .call => |c| {
                const i = r.serverIndex(c.server) orelse return r.finish(req, .{ .call = .unknown_server });
                if (r.resolved.servers[i].held == .removed) return r.finish(req, .{ .call = .{ .ended = .{
                    .outcome = .lost,
                    .maybe_ran = false,
                    .timed_out = false,
                    .why = removed_server_call_reason,
                } } });
                if (r.resolved.servers[i].held != null) return r.finish(req, .{ .failed = error.Held });
                if (r.flags[i].needs_login) _ = try r.pickUpLogin(i);
                try r.send(req, i);
            },
            .cancel => |target| {
                if (r.unqueue(target)) {
                    r.finish(target, switch (target.kind) {
                        .call => .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } } },
                        else => .{ .failed = error.Cancelled },
                    });
                    return r.finish(req, .ok);
                }
                var it = r.calls.iterator();
                while (it.next()) |entry| if (entry.value_ptr.* == target) {
                    try r.engine.cancel(entry.key_ptr.*);
                    break;
                };

                if (r.isHeld(target)) r.endHeld(target, .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } } });

                for (r.tool_waiters.items, 0..) |w, k| if (w.request == target) {
                    _ = r.tool_waiters.swapRemove(k);
                    r.finish(target, .{ .failed = error.Cancelled });
                    break;
                };

                for (r.logouts.items, 0..) |l, k| if (l.request == target) {
                    _ = r.logouts.swapRemove(k);
                    r.finish(target, .ok);
                    break;
                };

                for (r.sign_in_waiters.items, 0..) |w, k| if (w.request == target) {
                    _ = r.sign_in_waiters.swapRemove(k);
                    r.finish(target, .{ .failed = error.Cancelled });
                    r.abandonLogin(w.server);
                    break;
                };
                r.finish(req, .ok);
            },
            .login => |l| try r.startLogin(req, l.server, l.open_browser),
            .authenticate => |a| {
                const i = r.serverIndex(a.server) orelse return r.finish(req, .{ .authenticated = .unknown_server });
                const s = r.resolved.servers[i];
                if (s.held == .removed) return r.finish(req, .{ .authenticated = .unknown_server });
                if (s.held != null) return r.finish(req, .{ .failed = error.Held });
                if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
                if (r.loginFor(i) == null and (!r.flags[i].needs_login or try r.pickUpLogin(i))) {
                    return r.finish(req, .{ .authenticated = .already_signed_in });
                }
                try r.sign_in_waiters.ensureUnusedCapacity(r.gpa, 1);
                if (try r.openLogin(i, a.open_browser)) |refused| return r.finish(req, .{ .failed = refused.failure() });
                r.sign_in_waiters.appendAssumeCapacity(.{ .server = i, .request = req });
                if (r.loginFor(i)) |l| if (l.url) |url| r.noteSignInUrl(req, s.name, url);
            },
            .finish_login => |f| {
                const i = r.engineServer(f.server) orelse return r.finish(req, .{ .failed = error.UnknownServer });
                const l = r.loginFor(i) orelse return r.finish(req, .{ .failed = error.NotSigningIn });
                const url = req.owned_url orelse try r.gpa.dupe(u8, f.url);
                req.owned_url = null;
                if (l.callback) |old| r.gpa.free(old);
                l.callback = url;
                try r.engine.finishSignIn(r.resolved.servers[i].name, url);
                r.finish(req, .ok);
            },
            .answer => |a| {
                defer r.finish(req, .ok);
                const name = a.pending.name;
                var scratch: std.heap.ArenaAllocator = .init(r.gpa);
                defer scratch.deinit();
                switch (a.pending.reply) {
                    .input => |input| {
                        const values = if (a.json) |json| inputValues(scratch.allocator(), json, input.keys) else null;
                        if (values) |v| r.engine.respond(input.call, v) catch |err| {
                            debug_trace.logf("mcp", "MCP answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        } else {
                            if (r.calls.get(input.call)) |asking| asking.declined_by_fx = true;
                            r.engine.cancel(input.call) catch {};
                        }
                    },
                    .elicit => |id| {
                        if (r.serverById(a.pending.server) == null) {
                            debug_trace.logf("mcp", "MCP elicitation answer dropped server={s} reason=the server was reloaded", .{name});
                            return;
                        }
                        const answer = elicitAnswer(scratch.allocator(), a.json) orelse mcp.elicitation.Answer{ .action = .decline };
                        r.engine.answerElicitation(name, id, answer) catch |err| {
                            debug_trace.logf("mcp", "MCP elicitation answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        };
                    },

                    .url_consent => |held| if (r.isHeld(held) and held.url_phase == .consent) {
                        const choice = urlChoice(scratch.allocator(), a.json, held.urls.items.len);
                        const action: @FieldType(mcp.elicitation.Answer, "action") = switch (choice) {
                            .accepted => .accept,
                            .declined => .decline,
                            .cancelled => .cancel,
                        };

                        for (held.urls.items) |need| if (!need.dropped) r.engine.answerElicitation(name, need.id, .{ .action = action }) catch |err| {
                            debug_trace.logf("mcp", "MCP elicitation answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        };
                        held.url_phase = .none;
                        if (choice != .accepted) return r.endHeld(held, null);
                        held.url_signal.status.store(.pending, .release);
                        held.url_signal.wake.store(false, .release);
                        r.askUrls(held, .waiting) catch |err| {
                            logUrlCallEnded(name, "wait", err);
                            r.endHeld(held, null);
                        };
                    },

                    .url_wait => |held| if (r.isHeld(held) and held.url_phase == .waiting) {
                        const completed = held.url_signal.status.load(.acquire) == .completed;
                        if (!completed and urlChoice(scratch.allocator(), a.json, held.urls.items.len) != .accepted) return r.endHeld(held, null);
                        r.callAgain(held);
                    },
                }
            },
            .logout => |name| {
                const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = error.UnknownServer });
                const s = r.resolved.servers[i];
                if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });

                const saved = r.options.credentials.store.lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => blk: {
                        debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                        break :blk null;
                    },
                };
                defer if (saved) |c| secret.zeroAndFree(r.gpa, c);

                if (r.options.credentials.store.remove(r.gpa, s.credentialKey())) |_| {} else |err| switch (err) {
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => {
                        debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) });
                        req.logout_kept = err;
                    },
                }
                try r.engine.signOut(s.name);
                if (saved) |c| if (!r.holds(i, c) and try r.engine.adoptCredential(s.name, c)) {
                    debug_trace.logf("mcp", "MCP logout also revokes server={s} reason=another fx saved a newer login", .{s.name});
                    try r.engine.signOut(s.name);
                };
                r.flags[i] = .{};

                if (!r.engine.revoking(s.name)) return r.finish(req, .ok);
                try r.logouts.append(r.gpa, .{ .server = i, .request = req, .deadline_ms = r.nowMs() + revoke_wait_ms });
            },
        }
    }

    fn startLogin(r: *Runtime, req: *Request, name: []const u8, open_browser: bool) !void {
        const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = if (r.joinedSession(name)) error.Held else error.UnknownServer });
        if (r.resolved.servers[i].transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
        if (try r.openLogin(i, open_browser)) |refused| return r.finish(req, .{ .failed = refused.failure() });
        r.finish(req, .ok);
    }

    const LoginRefusal = enum {
        credential_store_unreadable,
        callback_port_in_use,

        fn failure(refusal: LoginRefusal) Error {
            return switch (refusal) {
                .credential_store_unreadable => error.CredentialStoreUnreadable,
                .callback_port_in_use => error.CallbackPortInUse,
            };
        }
    };

    fn openLogin(r: *Runtime, i: usize, open_browser: bool) !?LoginRefusal {
        const s = r.resolved.servers[i];
        if (r.loginFor(i)) |l| {
            l.open_browser = l.open_browser or open_browser;
            if (l.url) |url| {
                r.notify(.{ .authorize = .{ .server = s.name, .url = url } });
                if (open_browser) r.openBrowser(s.name, url);
            }
            return null;
        }

        r.options.credentials.store.check(r.gpa) catch |err| switch (err) {
            error.CredentialStoreUnreadable => return .credential_store_unreadable,
            else => debug_trace.logf("mcp", "MCP credential store not checked server={s} err={s}", .{ s.name, @errorName(err) }),
        };
        var listener = loopback.Listener.open(r.io, s.callback_port) catch |err| switch (err) {
            error.AddressInUse => if (s.callback_port != null) return .callback_port_in_use else return err,
            else => return err,
        };
        const l = r.gpa.create(Login) catch |err| {
            listener.close(r.io);
            return err;
        };
        l.* = .{
            .runtime = r,
            .server = i,
            .name = s.name,
            .listener = listener,
            .deadline_ms = r.nowMs() + login_timeout_ms,
            .open_browser = open_browser,
        };
        l.listener.localhost = s.slack_app;
        r.logins.append(r.gpa, l) catch |err| {
            l.listener.close(r.io);
            r.gpa.destroy(l);
            return err;
        };
        l.group.concurrent(r.io, awaitBrowser, .{l}) catch |err| {
            _ = r.logins.pop();
            l.listener.close(r.io);
            r.gpa.destroy(l);
            return err;
        };
        var buffer: [64]u8 = undefined;
        r.engine.signIn(s.name, l.listener.redirectUri(&buffer)) catch |err| {
            r.endLogin(i);
            return err;
        };
        return null;
    }

    fn noteSignInUrl(r: *Runtime, req: *Request, server: []const u8, url: []const u8) void {
        if (req.progress == null) return;
        const message = r.gpa.print(sign_in_url_status, .{ server, url }) catch return;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (req.note) |old| if (old.message) |m| r.gpa.free(m);
        req.note = .{ .progress = 0, .message = message };
    }

    fn endSignInWaiters(r: *Runtime, i: usize, failure: ?[]const u8) void {
        const url: ?[]const u8 = if (r.loginFor(i)) |l| l.url else null;
        var k: usize = 0;
        while (k < r.sign_in_waiters.items.len) {
            const w = r.sign_in_waiters.items[k];
            if (w.server != i) {
                k += 1;
                continue;
            }
            _ = r.sign_in_waiters.swapRemove(k);
            const reason = failure orelse {
                r.finish(w.request, .{ .authenticated = .signed_in });
                continue;
            };
            r.finish(w.request, if (signInFailed(w.request.alloc, reason, url)) |failed| .{ .authenticated = failed } else |err| .{ .failed = err });
        }
    }

    fn abandonLogin(r: *Runtime, i: usize) void {
        if (r.loginFor(i) == null) return;
        for (r.sign_in_waiters.items) |w| if (w.server == i) return;
        const name = r.resolved.servers[i].name;
        r.engine.cancelSignIn(name) catch {};
        r.notify(.{ .sign_in_failed = .{ .server = name, .reason = "the sign-in was cancelled" } });
        r.endLogin(i);
    }

    fn awaitBrowser(l: *Login) std.Io.Cancelable!void {
        const r = l.runtime;
        const url = l.listener.accept(r.io, r.gpa) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                debug_trace.logf("mcp", "MCP login listener failed server={s} err={s}", .{ l.name, @errorName(err) });
                return;
            },
        };
        const req = r.gpa.create(Request) catch {
            r.gpa.free(url);
            return;
        };
        req.* = .{
            .kind = .{ .finish_login = .{ .server = l.name, .url = url } },
            .alloc = r.gpa,
            .owned = true,
            .owned_url = url,
        };
        r.post(req) catch {
            r.gpa.free(url);
            r.gpa.destroy(req);
        };
    }

    fn openBrowser(r: *Runtime, name: []const u8, url: []const u8) void {
        const opened = url_opener.native_opener.open(r.gpa, url) catch false;
        if (!opened) debug_trace.logf("mcp", "browser not opened for MCP login server={s}", .{name});
    }

    fn loginFor(r: *const Runtime, server: usize) ?*Login {
        for (r.logins.items) |l| if (l.server == server) return l;
        return null;
    }

    fn endLogin(r: *Runtime, server: usize) void {
        for (r.logins.items, 0..) |l, k| if (l.server == server) {
            l.group.cancel(r.io);
            l.listener.close(r.io);
            if (l.callback) |url| r.gpa.free(url);
            if (l.url) |url| r.gpa.free(url);
            r.gpa.destroy(l);
            _ = r.logins.swapRemove(k);
            return;
        };
    }

    fn expireLogins(r: *Runtime) void {
        const now = r.nowMs();
        var k: usize = 0;
        while (k < r.logins.items.len) {
            const l = r.logins.items[k];
            if (l.deadline_ms > now) {
                k += 1;
                continue;
            }
            const name = r.resolved.servers[l.server].name;
            r.engine.cancelSignIn(name) catch {};
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = sign_in_timed_out } });
            r.endSignInWaiters(l.server, sign_in_timed_out);
            r.endLogin(l.server);
        }
    }

    fn endLogouts(r: *Runtime) void {
        const now = r.nowMs();
        var k: usize = 0;
        while (k < r.logouts.items.len) {
            const l = r.logouts.items[k];
            if (l.deadline_ms > now and r.engine.revoking(r.resolved.servers[l.server].name)) {
                k += 1;
                continue;
            }
            _ = r.logouts.swapRemove(k);
            r.finish(l.request, .ok);
        }
    }

    fn onEvent(r: *Runtime, event: engine.Event) !void {
        const i = r.engineServer(event.server) orelse return;
        switch (event.kind) {
            .phase => |phase| if (phase == .backoff or phase == .failed) r.endToolWaiters(i, .failed),
            .called => |c| {
                const entry = r.calls.fetchRemove(c.call) orelse return r.releaseRequired(i);
                const req = entry.value;
                var result = copyCall(req.alloc, c) catch |err| {
                    r.releaseRequired(i);
                    return r.finish(req, .{ .failed = err });
                };
                if (req.declined_by_fx and result == .ended and result.ended.outcome == .cancelled) result.ended.outcome = .unsupported_input;
                if (result == .ended and result.ended.outcome == .needs_auth and r.resolved.servers[i].static_credentials) {
                    r.flags[i].credentials_rejected = true;
                    result.ended.outcome = .http_failure;
                    result.ended.why = static_credentials_rejected;
                }

                if (c.oversized and result == .ended) {
                    const s = r.resolved.servers[i];
                    debug_trace.logf("mcp", "MCP call reply dropped server={s} transport={s} reason=too_large", .{ s.name, @tagName(s.transport) });
                    result.ended.why = if (s.transport == .stdio)
                        "its reply was larger than fx reads in one message, so fx restarted the server"
                    else
                        "its reply was larger than fx reads in one message, so fx dropped it";
                }
                if (result == .ended and result.ended.outcome == .transport_failed) {
                    const down = if (r.enginePhase(i)) |p| p == .backoff or p == .failed else false;
                    if (down) result.ended.why = r.failureText(req.alloc, i) catch null;
                }
                if (r.holdForUrls(i, req, result)) return;
                r.finish(req, .{ .call = result });
            },
            .resource => |c| {
                const entry = r.calls.fetchRemove(c.call) orelse return r.releaseRequired(i);
                const result = copyResource(entry.value.alloc, c.outcome, c.answer) catch |err| return r.finish(entry.value, .{ .failed = err });
                r.finish(entry.value, .{ .resource = result });
            },
            .progress => |p| {
                const req = r.calls.get(p.call) orelse return;
                if (req.progress == null) return;
                const message = if (p.message) |m| try r.gpa.dupe(u8, m) else null;
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);

                if (req.note) |old| if (old.message) |m| r.gpa.free(m);
                req.note = .{ .progress = p.progress, .total = p.total, .message = message };
            },
            .input => |q| {
                const req = r.calls.get(q.call) orelse return r.engine.cancel(q.call);
                if (req.asker == null) {
                    const elicitations = for (q.requests) |request| {
                        if (request.kind != .elicitation) break false;
                    } else true;
                    if (elicitations) {
                        debug_trace.logf("mcp", "MCP input request answered cancel server={s} reason=no question UI", .{event.server});
                        const values = try r.gpa.alloc([]const u8, q.requests.len);
                        defer r.gpa.free(values);
                        @memset(values, cancel_answer);
                        return r.engine.respond(q.call, values);
                    }
                    debug_trace.logf("mcp", "MCP input request declined server={s} reason=no question UI", .{event.server});
                    req.declined_by_fx = true;
                    return r.engine.cancel(q.call);
                }
                var pending = r.inputQuestion(i, q.call, q.requests) catch |err| {
                    try r.engine.cancel(q.call);
                    return err;
                };
                if (!r.offer(req, pending)) {
                    pending.deinit(r.gpa);
                    req.declined_by_fx = true;
                    try r.engine.cancel(q.call);
                }
            },
            .server => |s| try r.onServer(i, event.server, s),
        }
    }

    fn startStaticRetry(r: *Runtime, i: usize) bool {
        switch (r.flags[i].static_retry) {
            .pending => return true,
            .used => return false,
            .none => {},
        }
        if (!r.resolved.servers[i].static_credentials or r.resolved.servers[i].headers_helper == null) return false;
        const req = r.gpa.create(Request) catch return false;
        req.* = .{ .kind = .{ .refresh = r.resolved.servers[i].name }, .alloc = r.gpa, .owned = true };
        r.flags[i].static_retry = .pending;
        r.post(req) catch {
            r.gpa.destroy(req);
            r.flags[i].static_retry = .used;
            return false;
        };
        return true;
    }

    fn refreshHeaders(r: *Runtime, i: usize) !void {
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const server = r.resolved.servers[i];
        const helper = server.headers_helper orelse return error.InvalidHeadersHelper;
        const url = server.url orelse return error.InvalidHeadersHelper;
        const printed = try config.runHeadersHelper(s, helper, server.name, url, r.options.workspace_root);
        const produced = (try config.helperHeaders(s, printed orelse "")) orelse return error.InvalidHeadersHelper;
        if (!mcp.http_headers.sendable(produced)) return error.InvalidHeadersHelper;
        const configs = try r.engine.configs(s);
        const k = for (configs, 0..) |c, j| {
            if (std.mem.eql(u8, c.name, server.name)) break j;
        } else return error.UnknownServer;
        const link = switch (configs[k].transport) {
            .http, .sse => |*t| t,
            .stdio => return error.UnknownServer,
        };
        var merged: std.ArrayList(std.http.Header) = .empty;
        for (link.headers) |h| if (!hasHeader(produced, h.name)) try merged.append(s, h);
        try merged.appendSlice(s, produced);
        link.headers = merged.items;
        try r.engine.reload(configs);
        try r.engine.needTools(server.name);
    }

    fn hasHeader(headers: []const std.http.Header, name: []const u8) bool {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        return false;
    }

    fn onServer(r: *Runtime, i: usize, name: []const u8, event: mcp.server.Event) !void {
        switch (event) {
            .tools => |t| {
                const static_rejected = !t.ok and t.needs_auth and r.resolved.servers[i].static_credentials;
                if (static_rejected and r.flags[i].awaiting_tools) {
                    r.flags[i].awaiting_tools = false;
                    return;
                }
                if (static_rejected and r.startStaticRetry(i)) {
                    r.flags[i].awaiting_auth = true;
                    return;
                }
                r.flags[i].credentials_rejected = static_rejected;
                var k: usize = 0;
                while (k < r.tool_waiters.items.len) {
                    const w = r.tool_waiters.items[k];
                    if (w.server != i) {
                        k += 1;
                        continue;
                    }
                    _ = r.tool_waiters.swapRemove(k);
                    const result: Allocator.Error!ToolsResult = if (t.ok)
                        if (r.copyTools(w.request.alloc, name)) |list| .{ .tools = list } else |err| err
                    else if (t.needs_auth and !static_rejected)
                        .needs_login
                    else if (r.lastError(w.request.alloc, i)) |why| .{ .failed = why } else |err| err;
                    r.finish(w.request, if (result) |ok| .{ .tools = ok } else |err| .{ .failed = err });
                }
            },
            .auth_required => |required| if (r.resolved.servers[i].static_credentials) {
                if (r.flags[i].awaiting_auth) {
                    r.flags[i].awaiting_auth = false;
                    return;
                }
                if (r.startStaticRetry(i)) {
                    r.flags[i].awaiting_tools = true;
                    return;
                }
                r.flags[i].credentials_rejected = true;
                debug_trace.logf("mcp", "MCP static credentials rejected server={s} status=401", .{name});
                r.endToolWaiters(i, .failed);
            } else {
                r.flags[i].needs_login = true;

                if (!required.step_up) r.flags[i].signed_in = false;
                if (required.refused) |refused| {
                    debug_trace.logf("mcp", "MCP login dropped server={s} reason=refresh refused status={d} error={s}", .{ name, refused.status, refused.code });
                } else {
                    debug_trace.logf("mcp", "MCP login needed server={s} reason={s}", .{ name, if (required.step_up) "more scopes" else "sign-in required" });
                }
                r.notify(.{ .needs_login = name });

                r.endToolWaiters(i, .needs_login);
            },
            .authorize => |authorize| {
                r.notify(.{ .authorize = .{ .server = name, .url = authorize } });
                for (r.logins.items) |l| if (l.server == i) {
                    l.listener.expect(r.io, authorize);

                    if (r.gpa.dupe(u8, authorize)) |url| {
                        if (l.url) |old| r.gpa.free(old);
                        l.url = url;
                    } else |_| {}
                    if (l.open_browser) r.openBrowser(name, authorize);
                };
                for (r.sign_in_waiters.items) |w| if (w.server == i) r.noteSignInUrl(w.request, name, authorize);
            },
            .signed_in => {
                r.flags[i] = .{ .signed_in = true };
                r.endSignInWaiters(i, null);
                r.endLogin(i);
                r.notify(.{ .signed_in = name });
            },
            .sign_in_failed => |f| {
                var buffer: [512]u8 = undefined;
                const reason = signInFailure(&buffer, f.why, f.message);
                r.endSignInWaiters(i, reason);
                r.endLogin(i);
                r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            },
            .tools_stale => _ = r.tools_epochs[i].fetchAdd(1, .release),
            .credential => try r.saveCredential(i),
            .refresh_due => try r.refreshDue(i),
            .refresh_ended => r.endRefresh(i),
            .elicit => |x| {
                r.dropUrlSlot(i, x.id.slot);
                if (x.required) {
                    const params = try r.gpa.dupe(u8, x.params);
                    r.required.append(r.gpa, .{ .server = i, .need = .{ .id = x.id, .params = params } }) catch |err| {
                        r.gpa.free(params);
                        return err;
                    };
                } else {
                    const cancel: mcp.elicitation.Answer = .{ .action = .cancel };
                    const req = r.callAsking(name) orelse {
                        debug_trace.logf("mcp", "MCP elicitation answered cancel server={s} reason=no call can ask", .{name});
                        return r.engine.answerElicitation(name, x.id, cancel);
                    };
                    const json = try r.gpa.print("{{\"elicitation\":{{\"method\":\"elicitation/create\",\"params\":{s}}}}}", .{x.params});
                    var pending: Pending = .{ .name = r.resolved.servers[i].name, .server = r.ids[i], .json = json, .version = r.versionCopy(i), .reply = .{ .elicit = x.id } };
                    if (!r.offer(req, pending)) {
                        pending.deinit(r.gpa);
                        return r.engine.answerElicitation(name, x.id, cancel);
                    }
                }
                try r.holdUrl(i, x.id.slot, x.params);
            },
            .elicitation_complete => |slot| {
                r.urlCompleted(i, slot);
                r.endUrl(i, slot, true);
            },
            .elicit_withdrawn => |slot| {
                r.dropWithdrawn(i, slot);
                r.dropUrlSlot(i, slot);
                r.endUrl(i, slot, false);
            },
            else => {},
        }
    }

    fn dropWithdrawn(r: *Runtime, i: usize, slot: u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        var it = r.calls.valueIterator();
        while (it.next()) |req| if (req.*.question) |*q| {
            if (q.server != r.ids[i] or q.reply != .elicit or q.reply.elicit.slot != slot) continue;
            debug_trace.logf("mcp", "MCP question dropped server={s} reason=withdrawn before it was shown", .{r.resolved.servers[i].name});
            q.deinit(r.gpa);
            req.*.question = null;
            return;
        };
    }

    fn holdUrl(r: *Runtime, i: usize, slot: u8, params: []const u8) !void {
        if (r.options.url_completions == null) return;
        var form: mcp.elicitation.Form = .{};
        const request = mcp.elicitation.parse(params, &form) catch return;
        const raw = request.elicitation_id orelse return;
        const parsed = json_decode.parseFromSlice([]const u8, r.gpa, raw, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer parsed.deinit();
        const id = try r.gpa.dupe(u8, parsed.value);
        errdefer r.gpa.free(id);

        r.endUrl(i, slot, false);
        try r.url_questions.append(r.gpa, .{ .server = i, .slot = slot, .id = id });
    }

    fn endUrl(r: *Runtime, i: usize, slot: u8, completed: bool) void {
        for (r.url_questions.items, 0..) |q, k| if (q.server == i and q.slot == slot) {
            _ = r.url_questions.swapRemove(k);
            defer r.gpa.free(q.id);
            if (completed) if (r.options.url_completions) |sink| sink.complete(.{
                .server_name = r.resolved.servers[i].name,
                .elicitation_id = q.id,
                .connection_generation = 0,
                .client_generation = 0,
                .auth_generation = 0,
            });
            return;
        };
    }

    fn holdForUrls(r: *Runtime, i: usize, req: *Request, result: CallResult) bool {
        const listed = for (r.required.items) |q| {
            if (q.server == i) break true;
        } else false;
        if (!listed) return false;
        const name = r.resolved.servers[i].name;
        if (req.asker == null or result != .failure or result.failure.code != url_elicitation_required) {
            debug_trace.logf("mcp", "MCP elicitation answered cancel server={s} reason=no call can ask", .{name});
            r.releaseRequired(i);
            return false;
        }
        r.holdUrls(i, req, result) catch |err| {
            logUrlCallEnded(name, "hold", err);
            r.unhold(req);
            r.releaseRequired(i);
            return false;
        };
        return true;
    }

    fn holdUrls(r: *Runtime, i: usize, req: *Request, result: CallResult) Allocator.Error!void {
        try r.held.ensureUnusedCapacity(r.gpa, 1);
        req.url_server = i;
        r.held.appendAssumeCapacity(req);
        var k: usize = 0;
        while (k < r.required.items.len) {
            if (r.required.items[k].server != i) {
                k += 1;
                continue;
            }
            try req.urls.append(r.gpa, r.required.items[k].need);
            _ = r.required.orderedRemove(k);
        }
        req.url_failure = result;
        try r.askUrls(req, .consent);
    }

    fn askUrls(r: *Runtime, req: *Request, phase: @FieldType(Request, "url_phase")) Allocator.Error!void {
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();

        out.writer.writeByte('{') catch return error.OutOfMemory;

        for (req.urls.items, 0..) |need, n| {
            if (n > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            const key = [_]u8{ '"', 'a' + @as(u8, @intCast(n)), '"' };
            out.writer.writeAll(&key) catch return error.OutOfMemory;
            out.writer.writeAll(":{\"method\":\"elicitation/create\",\"params\":") catch return error.OutOfMemory;
            out.writer.writeAll(need.params) catch return error.OutOfMemory;
            out.writer.writeByte('}') catch return error.OutOfMemory;
        }
        out.writer.writeByte('}') catch return error.OutOfMemory;
        const pending: Pending = .{
            .name = r.resolved.servers[req.url_server].name,
            .server = r.ids[req.url_server],
            .json = try out.toOwnedSlice(),
            .version = r.versionCopy(req.url_server),
            .reply = if (phase == .consent) .{ .url_consent = req } else .{ .url_wait = req },
        };
        r.mutex.lockUncancelable(r.io);

        var stale = req.question;
        req.question = pending;
        r.mutex.unlock(r.io);
        if (stale) |*p| p.deinit(r.gpa);
        req.url_phase = phase;
    }

    fn isHeld(r: *const Runtime, req: *Request) bool {
        return std.mem.findScalar(*Request, r.held.items, req) != null;
    }

    fn endHeld(r: *Runtime, req: *Request, result: ?Request.Outcome) void {
        const failure: Request.Outcome = if (req.url_failure) |f| .{ .call = f } else .{ .failed = error.Cancelled };
        r.unhold(req);
        r.finish(req, result orelse failure);
    }

    fn unhold(r: *Runtime, req: *Request) void {
        if (std.mem.findScalar(*Request, r.held.items, req)) |k| _ = r.held.orderedRemove(k);
        const name = r.resolved.servers[req.url_server].name;
        for (req.urls.items) |need| {
            if (!need.dropped and !need.seen) r.engine.answerElicitation(name, need.id, .{ .action = .cancel }) catch {};
            r.gpa.free(need.params);
        }
        req.urls.clearAndFree(r.gpa);
        if (req.url_phase == .waiting) {
            req.url_signal.status.store(.cancelled, .release);
            req.url_signal.wake.store(true, .release);
        }
        req.url_phase = .none;
    }

    fn callAgain(r: *Runtime, req: *Request) void {
        const failure = req.url_failure orelse CallResult{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } };
        req.url_failure = null;
        r.unhold(req);
        r.send(req, req.url_server) catch |err| {
            logUrlCallEnded(r.resolved.servers[req.url_server].name, "again", err);
            r.finish(req, .{ .call = failure });
        };
    }

    fn sendResource(r: *Runtime, req: *Request, i: usize, op: mcp.resources.Op) !void {
        try r.calls.ensureUnusedCapacity(r.gpa, 1);
        const handle_ = try r.engine.resource(r.resolved.servers[i].name, op);
        r.calls.putAssumeCapacity(handle_, req);
    }

    fn send(r: *Runtime, req: *Request, i: usize) !void {
        const c = req.kind.call;

        try r.calls.ensureUnusedCapacity(r.gpa, 1);
        const handle_ = try r.engine.call(r.resolved.servers[i].name, c.tool, c.arguments);
        if (req.observation) |call_| call_.engineRequest(handle_);
        r.calls.putAssumeCapacity(handle_, req);
    }

    fn releaseRequired(r: *Runtime, i: usize) void {
        var k: usize = 0;
        while (k < r.required.items.len) {
            const q = r.required.items[k];
            if (q.server != i) {
                k += 1;
                continue;
            }
            _ = r.required.orderedRemove(k);
            r.engine.answerElicitation(r.resolved.servers[i].name, q.need.id, .{ .action = .cancel }) catch {};
            r.gpa.free(q.need.params);
        }
    }

    fn dropUrlSlot(r: *Runtime, i: usize, slot: u8) void {
        for (r.held.items) |req| if (req.url_server == i) {
            for (req.urls.items) |*need| if (need.id.slot == slot and !need.seen) {
                need.dropped = true;
            };
        };
    }

    fn urlCompleted(r: *Runtime, i: usize, slot: u8) void {
        for (r.held.items) |req| if (req.url_server == i) {
            var all = true;
            for (req.urls.items) |*need| {
                if (need.id.slot == slot and !need.dropped) need.seen = true;
                all = all and need.seen;
            }
            if (all and req.url_phase == .waiting) {
                req.url_signal.status.store(.completed, .release);
                req.url_signal.wake.store(true, .release);
            }
        };
    }

    fn saveCredential(r: *Runtime, i: usize) !void {
        const s = r.resolved.servers[i];
        if (s.url == null) return;
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        if (try r.engine.saveCredential(s.name, &out.writer)) {
            for (r.refreshes.items) |*f| if (f.server == i) if (f.lock) |*l| l.restamp();
            if (r.options.credentials.store.put(r.gpa, s.credentialKey(), out.written())) {
                r.flags[i].last_saved_digest = credentials.digest(out.written());
                r.flags[i].not_saved = false;
            } else |err| {
                debug_trace.logf("mcp", "MCP credential not saved server={s} err={s}", .{ s.name, @errorName(err) });
                if (r.flags[i].not_saved) return;
                r.flags[i].not_saved = true;
                var buf: [320]u8 = undefined;
                r.notify(.{ .not_saved = .{ .server = s.name, .reason = r.options.credentials.store.writeFailure(&buf, err) } });
            }
        } else {
            r.flags[i].signed_in = false;
            const own = r.flags[i].last_saved_digest orelse return debug_trace.logf("mcp", "MCP login dropped server={s} saved=none", .{s.name});

            const removed = r.options.credentials.store.removeIfSame(r.gpa, s.credentialKey(), own) catch |err| {
                return debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) });
            };
            debug_trace.logf("mcp", "MCP login dropped server={s} saved={s}", .{ s.name, if (removed) "removed" else "kept, another fx saved a newer one" });
        }
    }

    fn applyReload(r: *Runtime, configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map) !Reloaded {
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const session_configs = try r.sessionConfigs(s, configs);
        const next = try config.resolve(s, session_configs, inherited, r.options.workspace_root);
        writeIgnoreLines(r.gpa, s, session_configs, next.servers, r.options.workspace_root);
        const live = next.servers.len;
        const gone = try r.serversMissingFrom(s, next.servers);
        const n = live + gone.len;

        const arena = r.arena.allocator();
        const kept_servers = try arena.alloc(config.Server, n);
        @memcpy(kept_servers[0..live], try config.keepServers(arena, next.servers, r.resolved.servers));
        for (gone, kept_servers[live..]) |i, *removed| {
            removed.* = r.resolved.servers[i];
            removed.held = .removed;
            removed.missing = null;
        }
        const engine_server = try arena.dupe(usize, next.engine_server);
        const kept = try arena.alloc(bool, n);
        @memset(kept[0..live], false);
        @memset(kept[live..], true);
        for (next.engine, next.engine_server) |c, j| kept[j] = r.engine.keeps(c);

        const from = try s.alloc(?usize, n);
        for (next.servers, kept[0..live], from[0..live]) |server, k, *f| f.* = if (k) r.serverIndex(server.name) else null;
        for (gone, from[live..]) |i, *f| f.* = i;
        const to = try s.alloc(?usize, r.resolved.servers.len);
        @memset(to, null);
        for (from, 0..) |f, j| if (f) |i| {
            to[i] = j;
        };
        const flags = try r.gpa.alloc(Flags, n);
        errdefer r.gpa.free(flags);
        const ids = try r.gpa.alloc(u64, n);
        errdefer r.gpa.free(ids);
        const epochs = try r.gpa.alloc(std.atomic.Value(u64), n);
        errdefer r.gpa.free(epochs);
        for (from, flags, ids, epochs) |f, *flag, *id, *epoch| {
            flag.* = if (f) |i| r.flags[i] else .{};
            id.* = if (f) |i| r.ids[i] else r.newId();
            epoch.* = .init(if (f) |i| r.tools_epochs[i].load(.acquire) else 0);
        }
        for (gone, flags[live..]) |i, *flag| {
            if (r.resolved.servers[i].held == .removed) continue;
            const engine_index = std.mem.findScalar(usize, r.resolved.engine_server, i);
            flag.* = .{ .tools_when_removed = if (engine_index) |k| r.engine.status(k).tools else 0 };
        }

        var dropped = false;
        var removed_now: usize = 0;
        for (r.resolved.engine_server) |i| {
            const removed = if (to[i]) |j| j >= live else false;
            if (to[i] != null and !removed) continue;
            if (removed) removed_now += 1 else dropped = true;
            r.dropServer(i, next.servers);
        }

        try r.engine.reload(next.engine);
        r.moveServers(to);
        r.mutex.lockUncancelable(r.io);
        const old_flags = r.flags;
        const old_ids = r.ids;
        const old_epochs = r.tools_epochs;
        r.resolved = .{ .servers = kept_servers, .engine = &.{}, .engine_server = engine_server };
        r.flags = flags;
        r.ids = ids;
        r.tools_epochs = epochs;
        r.mutex.unlock(r.io);

        r.gpa.free(old_flags);
        r.gpa.free(old_ids);
        r.gpa.free(old_epochs);
        var added: usize = 0;
        for (engine_server) |j| if (from[j] == null) {
            added += 1;
            r.adoptSaved(j);
        };
        var same: usize = 0;
        for (kept[0..live]) |k| same += @intFromBool(k);
        debug_trace.logf("mcp", "MCP config reloaded servers={d} kept={d} fresh={d} removed={d} removed_now={d} dropped={s}", .{ live, same, added, gone.len, removed_now, if (dropped) "yes" else "no" });
        return .{ .kept = kept, .dropped = dropped };
    }

    fn joinedSession(r: *const Runtime, name: []const u8) bool {
        const i = r.serverIndex(name) orelse return false;
        return r.resolved.servers[i].held != .removed;
    }

    fn startedWith(r: *const Runtime, name: []const u8) bool {
        for (r.session_servers) |started| if (std.mem.eql(u8, started, name)) return true;
        return false;
    }

    fn sessionConfigs(r: *const Runtime, scratch: Allocator, configs: []const mcp_contract.McpServerConfig) Allocator.Error![]const mcp_contract.McpServerConfig {
        var joined: std.ArrayList(mcp_contract.McpServerConfig) = .empty;
        for (configs) |c| {
            if (r.startedWith(c.name)) {
                try joined.append(scratch, c);
                continue;
            }
            debug_trace.logf("mcp", "MCP server left for the next session server={s} reason=added after this session started", .{c.name});
        }
        return joined.items;
    }

    fn serversMissingFrom(r: *const Runtime, scratch: Allocator, next: []const config.Server) Allocator.Error![]const usize {
        var gone: std.ArrayList(usize) = .empty;
        for (r.resolved.servers, 0..) |old, i| {
            const still_configured = for (next) |server| {
                if (std.mem.eql(u8, server.name, old.name)) break true;
            } else false;
            if (!still_configured) try gone.append(scratch, i);
        }
        return gone.items;
    }

    fn dropServer(r: *Runtime, i: usize, next: []const config.Server) void {
        const name = r.resolved.servers[i].name;
        const successor: ?config.Server = for (next) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else null;
        const why = if (successor == null) "removed" else if (successor.?.held != null) "held back" else "changed";
        debug_trace.logf("mcp", "MCP server stops for a reload server={s} reason={s}", .{ name, why });
        while (r.callOn(name)) |waiting| {
            _ = r.calls.remove(waiting.handle);
            r.finish(waiting.request, .{ .call = .{ .ended = .{
                .outcome = .cancelled,
                .maybe_ran = r.engine.callSent(waiting.handle),
                .timed_out = false,
                .why = "the MCP config changed, and fx stopped the server",
            } } });
        }
        var k: usize = 0;
        while (k < r.tool_waiters.items.len) {
            const w = r.tool_waiters.items[k];
            if (w.server != i) {
                k += 1;
                continue;
            }
            _ = r.tool_waiters.swapRemove(k);
            r.mutex.lockUncancelable(r.io);
            const queued = if (r.queue.append(r.gpa, w.request)) |_| true else |_| false;
            r.mutex.unlock(r.io);
            if (queued) r.engine.wake() else r.finish(w.request, .{ .failed = error.OutOfMemory });
        }
        if (r.loginFor(i) != null) {
            var buf: [320]u8 = undefined;
            const reason = if (successor != null and successor.?.held == null)
                std.mem.print(&buf, "the MCP config changed before the browser came back; run /mcp login {s} again", .{name}) catch "the MCP config changed before the browser came back"
            else
                "the MCP config changed before the browser came back";
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            r.endSignInWaiters(i, reason);
            r.endLogin(i);
        }
        r.endSignInWaiters(i, "the MCP config changed, and fx stopped the server");
        k = 0;
        while (k < r.logouts.items.len) {
            const l = r.logouts.items[k];
            if (l.server != i) {
                k += 1;
                continue;
            }
            _ = r.logouts.swapRemove(k);
            r.finish(l.request, .ok);
        }
        r.endRefresh(i);
        k = 0;
        while (k < r.held.items.len) {
            const req = r.held.items[k];
            if (req.url_server != i) {
                k += 1;
                continue;
            }
            r.endHeld(req, .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false, .why = "the MCP config changed, and fx stopped the server" } } });
        }
        k = 0;
        while (k < r.required.items.len) {
            if (r.required.items[k].server != i) {
                k += 1;
                continue;
            }
            r.gpa.free(r.required.orderedRemove(k).need.params);
        }
        k = 0;
        while (k < r.url_questions.items.len) {
            if (r.url_questions.items[k].server != i) {
                k += 1;
                continue;
            }
            r.gpa.free(r.url_questions.swapRemove(k).id);
        }
    }

    fn moveServers(r: *Runtime, to: []const ?usize) void {
        for (r.tool_waiters.items) |*w| w.server = to[w.server].?;
        for (r.logins.items) |l| l.server = to[l.server].?;
        for (r.sign_in_waiters.items) |*w| w.server = to[w.server].?;
        for (r.logouts.items) |*l| l.server = to[l.server].?;
        for (r.refreshes.items) |*f| f.server = to[f.server].?;
        for (r.held.items) |req| req.url_server = to[req.url_server].?;
        for (r.required.items) |*q| q.server = to[q.server].?;
        for (r.url_questions.items) |*q| q.server = to[q.server].?;
    }

    fn adoptSaved(r: *Runtime, i: usize) void {
        const s = r.resolved.servers[i];
        if (s.url == null) return;
        const saved = r.options.credentials.store.get(r.gpa, s.credentialKey()) catch |err| {
            return debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
        } orelse return;
        defer secret.zeroAndFree(r.gpa, saved);
        r.engine.restoreCredential(s.name, saved) catch |err| {
            return debug_trace.logf("mcp", "MCP credential not loaded server={s} err={s}", .{ s.name, @errorName(err) });
        };
        r.flags[i].signed_in = true;
        r.flags[i].last_saved_digest = credentials.digest(saved);
    }

    fn callOn(r: *Runtime, name: []const u8) ?struct { handle: engine.Handle, request: *Request } {
        var it = r.calls.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.kind.call.server, name)) return .{ .handle = entry.key_ptr.*, .request = entry.value_ptr.* };
        }
        return null;
    }

    fn serverById(r: *const Runtime, id: u64) ?usize {
        return std.mem.findScalar(u64, r.ids, id);
    }

    fn newId(r: *Runtime) u64 {
        defer r.next_id += 1;
        return r.next_id;
    }

    fn shutdown(r: *Runtime) void {
        while (r.logins.items.len > 0) {
            const server = r.logins.items[0].server;
            const name = r.resolved.servers[server].name;
            var buf: [320]u8 = undefined;
            const reason = std.mem.print(&buf, "the MCP config changed before the browser came back; run /mcp login {s} again", .{name}) catch
                "the MCP config changed before the browser came back; sign in again";
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            r.endLogin(server);
        }
        var it = r.calls.valueIterator();
        while (it.next()) |req| r.finish(req.*, .{ .failed = error.Stopped });
        r.calls.clearRetainingCapacity();
        while (r.held.items.len > 0) r.endHeld(r.held.items[0], .{ .failed = error.Stopped });
        for (r.required.items) |q| r.gpa.free(q.need.params);
        r.required.clearRetainingCapacity();
        for (r.tool_waiters.items) |w| r.finish(w.request, .{ .failed = error.Stopped });
        r.tool_waiters.clearRetainingCapacity();
        for (r.sign_in_waiters.items) |w| r.finish(w.request, .{ .failed = error.Stopped });
        r.sign_in_waiters.clearRetainingCapacity();
        for (r.logouts.items) |l| r.finish(l.request, .ok);
        r.logouts.clearRetainingCapacity();
        for (r.refreshes.items) |*f| if (f.lock) |*l| l.release();
        r.refreshes.clearRetainingCapacity();

        _ = r.drain();
        r.flush();
        r.engine.deinit();
    }

    fn publish(r: *Runtime) Allocator.Error!void {
        var next_arena: std.heap.ArenaAllocator = .init(r.gpa);
        errdefer next_arena.deinit();
        const a = next_arena.allocator();
        const out = try a.alloc(Status, r.resolved.servers.len);
        for (r.resolved.servers, out, 0..) |s, *o, i| {
            o.* = .{ .name = s.name, .source = s.source, .transport = s.transport, .state = .idle, .missing = s.missing };
            if (s.held) |h| {
                o.state = switch (h) {
                    .disabled => .disabled,
                    .waiting_for_approval => .waiting_for_approval,
                    .rejected => .rejected,
                    .unsupported => .unsupported,
                    .missing_env => .missing_env,
                    .invalid_env => .invalid_env,
                    .removed => .removed,
                    .nested => .disabled,
                };
                if (h == .removed) o.tools = r.flags[i].tools_when_removed;
                continue;
            }
            const k = std.mem.findScalar(usize, r.resolved.engine_server, i).?;
            const st = r.engine.status(k);
            o.state = switch (st.phase) {
                .idle => .idle,
                .connecting => .connecting,
                .ready => .ready,
                .backoff => .retrying,
                .failed => .failed,
            };
            o.version = if (st.version) |v| try a.dupe(u8, v) else null;
            o.tools = st.tools;
            if (st.retry_in_ms) |wait_ms| o.next_retry_at_ms = io_mod.milliTimestamp() + wait_ms;

            o.last_error = switch (o.state) {
                .failed, .retrying => try r.failureText(a, i),
                else => null,
            };
            if (r.flags[i].credentials_rejected) {
                o.state = .failed;
                o.last_error = try a.dupe(u8, static_credentials_rejected);
            }
            o.needs_login = r.flags[i].needs_login;
            o.signed_in = r.flags[i].signed_in;
            o.signing_in = r.loginFor(i) != null;
            if (r.engine.instructions(s.name)) |t| o.instructions = try a.dupe(u8, t);
        }
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.snapshot_arena.deinit();
        r.snapshot_arena = next_arena;
        r.snapshot = out;
    }

    fn waitMs(r: *const Runtime) u32 {
        var wait: i64 = max_idle_wait_ms;
        const now = r.nowMs();
        for (r.logins.items) |l| wait = @min(wait, @max(0, l.deadline_ms - now));
        for (r.logouts.items) |l| wait = @min(wait, @max(0, l.deadline_ms - now));
        for (r.refreshes.items) |f| if (!f.sent) {
            wait = @min(wait, refresh_retry_ms);
        };
        if (r.waitsForRetired() or r.awaiting_dropped_stop) wait = @min(wait, held_recheck_ms);
        return @intCast(wait);
    }

    fn nowMs(r: *const Runtime) i64 {
        return std.Io.Clock.awake.now(r.io).toMilliseconds();
    }

    fn finish(r: *Runtime, req: *Request, result: Request.Outcome) void {
        if (req.owned) {
            if (req.owned_url) |url| r.gpa.free(url);
            switch (req.kind) {
                .answer => |*a| {
                    a.pending.deinit(r.gpa);
                    if (a.json) |json| r.gpa.free(json);
                },
                else => {},
            }
            return r.gpa.destroy(req);
        }

        r.mutex.lockUncancelable(r.io);
        var question = req.question;
        req.question = null;
        r.mutex.unlock(r.io);
        if (question) |*p| p.deinit(r.gpa);
        req.result = result;
        r.finished.append(r.gpa, req) catch req.done.set(r.io);
    }

    fn offer(r: *Runtime, req: *Request, pending: Pending) bool {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (req.question != null) return false;
        req.question = pending;
        return true;
    }

    fn callAsking(r: *Runtime, name: []const u8) ?*Request {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        var it = r.calls.valueIterator();
        while (it.next()) |req| {
            if (req.*.asker == null or req.*.question != null) continue;
            if (std.mem.eql(u8, req.*.kind.call.server, name)) return req.*;
        }
        return null;
    }

    fn inputQuestion(r: *Runtime, i: usize, call_handle: engine.Handle, requests: []const mcp.mrtr.Request) Allocator.Error!Pending {
        const keys = try r.gpa.alloc([]u8, requests.len);
        var made: usize = 0;
        errdefer {
            for (keys[0..made]) |k| r.gpa.free(k);
            r.gpa.free(keys);
        }
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();

        out.writer.writeByte('{') catch return error.OutOfMemory;
        for (requests, keys, 0..) |request, *key, n| {
            key.* = try r.gpa.dupe(u8, request.key);
            made += 1;
            if (n > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            out.writer.print("{s}:{s}", .{ request.key, request.raw }) catch return error.OutOfMemory;
        }
        out.writer.writeByte('}') catch return error.OutOfMemory;
        const json = try out.toOwnedSlice();
        return .{ .name = r.resolved.servers[i].name, .server = r.ids[i], .json = json, .version = r.versionCopy(i), .reply = .{ .input = .{ .call = call_handle, .keys = keys } } };
    }

    fn versionCopy(r: *Runtime, i: usize) ?[]u8 {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        const version = r.engine.status(k).version orelse return null;
        return r.gpa.dupe(u8, version) catch null;
    }

    fn notify(r: *Runtime, notice: Notice) void {
        if (r.options.notify) |n| n.notice(n.context, notice);
    }

    fn serverIndex(r: *const Runtime, name: []const u8) ?usize {
        for (r.resolved.servers, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }

    fn engineServer(r: *const Runtime, name: []const u8) ?usize {
        const i = r.serverIndex(name) orelse return null;
        return if (r.resolved.servers[i].held == null) i else null;
    }

    fn endToolWaiters(r: *Runtime, i: usize, how: enum { failed, needs_login }) void {
        var k: usize = 0;
        while (k < r.tool_waiters.items.len) {
            const w = r.tool_waiters.items[k];
            if (w.server != i) {
                k += 1;
                continue;
            }
            _ = r.tool_waiters.swapRemove(k);
            if (how == .needs_login) {
                r.finish(w.request, .{ .tools = .needs_login });
                continue;
            }
            const why = r.lastError(w.request.alloc, i);
            r.finish(w.request, if (why) |text| .{ .tools = .{ .failed = text } } else |err| .{ .failed = err });
        }
    }

    fn keepsFailingToStart(r: *const Runtime, i: usize) bool {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return false;
        return r.engine.status(k).failed_attempts > 0;
    }

    fn enginePhase(r: *const Runtime, i: usize) ?engine.Phase {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return r.engine.status(k).phase;
    }

    fn lastError(r: *const Runtime, alloc: Allocator, i: usize) Allocator.Error![]u8 {
        if (r.flags[i].credentials_rejected) return alloc.dupe(u8, static_credentials_rejected);
        return (try r.failureText(alloc, i)) orelse try alloc.dupe(u8, "the server is unavailable");
    }

    fn failureText(r: *const Runtime, alloc: Allocator, i: usize) Allocator.Error!?[]u8 {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        const st = r.engine.status(k);
        const why = st.last_error orelse return null;
        var tail_buf: [mcp.stdio.tail_max]u8 = undefined;
        const tail = r.engine.stderrTail(k, &tail_buf);
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        writeFailure(&out.writer, why, st.exit, st.stray_line, tail) catch return error.OutOfMemory;
        return try out.toOwnedSlice();
    }

    fn heldReason(r: *const Runtime, alloc: Allocator, i: usize) ?Allocator.Error![]u8 {
        const s = r.resolved.servers[i];
        const held = s.held orelse return null;
        return switch (held) {
            .disabled => alloc.dupe(u8, "the server is disabled"),
            .waiting_for_approval => alloc.dupe(u8, "the project server is waiting for approval"),
            .rejected => alloc.dupe(u8, "the project server was rejected"),
            .unsupported => alloc.dupe(u8, "servers of \"type\": \"acp\" are not supported: ACP v1 defines stdio, HTTP, and SSE"),
            .missing_env => alloc.print("{s} is not set", .{s.missing orelse "a variable"}),
            .invalid_env => alloc.print("{s} holds a line break or another character a header can't carry", .{s.missing orelse "a variable"}),
            .removed => alloc.dupe(u8, "the server was removed from the MCP config"),
            .nested => alloc.print("this fx was itself started as an MCP server {d} levels deep ({s}), so it starts no MCP servers of its own", .{ config.max_depth, config.depth_variable }),
        };
    }

    fn copyTools(r: *Runtime, alloc: Allocator, name: []const u8) Allocator.Error![]Tool {
        const list = r.engine.toolList(name) catch return &.{};
        const server: ?config.Server = if (r.serverIndex(name)) |i| r.resolved.servers[i] else null;
        var out: std.ArrayList(Tool) = .empty;
        for (0..list.len()) |k| {
            const tool = list.get(k);
            if (server) |s| if (!config.toolAllowed(s, tool.name)) continue;
            try out.append(alloc, .{ .name = try alloc.dupe(u8, tool.name), .raw = try alloc.dupe(u8, tool.raw) });
        }
        return out.toOwnedSlice(alloc);
    }

    fn pickUpLogin(r: *Runtime, i: usize) !bool {
        const s = r.resolved.servers[i];
        if (s.transport != .http or s.held != null or r.loginFor(i) != null) return false;
        if (!try r.takeSaved(i)) return false;
        r.flags[i].needs_login = false;
        r.flags[i].signed_in = true;
        debug_trace.logf("mcp", "MCP login saved by another fx taken server={s}", .{s.name});
        r.notify(.{ .signed_in = s.name });
        return true;
    }

    fn refreshDue(r: *Runtime, i: usize) !void {
        r.endRefresh(i);
        try r.refreshes.append(r.gpa, .{ .server = i, .awake_started_ms = r.nowMs() });
        try r.tryRefresh(&r.refreshes.items[r.refreshes.items.len - 1]);
    }

    fn tryRefresh(r: *Runtime, f: *Refresh) !void {
        const s = r.resolved.servers[f.server];
        if (r.options.credentials.store.tryRefreshLock(s.credentialKey())) |maybe| {
            if (maybe) |lock| {
                f.lock = lock;
            } else if (!r.options.credentials.store.refreshHolderStopped(s.credentialKey(), f.awake_started_ms, refresh_answer_ms)) {
                return;
            } else debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=another fx stopped refreshing started={d} at={d}", .{ s.name, f.awake_started_ms, r.nowMs() });
        } else |err| debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=no refresh lock err={s}", .{ s.name, @errorName(err) });
        f.sent = true;
        const saved = r.options.credentials.store.lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,

            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return r.sendRefresh(f);
            },
        };
        if (saved) |c| {
            defer secret.zeroAndFree(r.gpa, c);
            if (try r.take(f.server, c)) debug_trace.logf("mcp", "MCP refresh replaced server={s} reason=another fx refreshed", .{s.name});
        } else if (r.flags[f.server].last_saved_digest != null) {
            debug_trace.logf("mcp", "MCP login ended server={s} reason=signed out in another fx", .{s.name});
            if (f.lock) |*l| l.release();
            f.lock = null;
            try r.engine.signOut(s.name);
            r.flags[f.server] = .{};
            return;
        }

        try r.sendRefresh(f);
    }

    fn sendRefresh(r: *Runtime, f: *Refresh) !void {
        if (f.lock) |*l| l.restamp();
        try r.engine.refresh(r.resolved.servers[f.server].name);
    }

    fn holds(r: *const Runtime, i: usize, saved: []const u8) bool {
        const tried = r.flags[i].last_saved_digest orelse return false;
        return std.mem.eql(u8, &tried, &credentials.digest(saved));
    }

    fn retryRefreshes(r: *Runtime) void {
        for (r.refreshes.items) |*f| if (!f.sent) r.tryRefresh(f) catch |err| {
            debug_trace.logf("mcp", "MCP refresh not started server={s} err={s}", .{ r.resolved.servers[f.server].name, @errorName(err) });
        };
    }

    fn endRefresh(r: *Runtime, i: usize) void {
        for (r.refreshes.items, 0..) |*f, k| if (f.server == i) {
            if (f.lock) |*l| l.release();
            _ = r.refreshes.swapRemove(k);
            return;
        };
    }

    fn takeSaved(r: *Runtime, i: usize) !bool {
        const s = r.resolved.servers[i];
        const saved = r.options.credentials.store.get(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return false;
            },
        } orelse return false;
        defer secret.zeroAndFree(r.gpa, saved);
        return r.take(i, saved);
    }

    fn take(r: *Runtime, i: usize, saved: []const u8) !bool {
        const s = r.resolved.servers[i];
        if (r.holds(i, saved)) return false;
        r.flags[i].last_saved_digest = credentials.digest(saved);

        if (!try r.engine.useCredential(s.name, saved)) {
            debug_trace.logf("mcp", "MCP saved login not usable, ignored server={s}", .{s.name});
            return false;
        }
        return true;
    }

    fn restoreCredentials(r: *Runtime) void {
        defer r.credentials_restored.set(r.io);
        const store: credentials.Store = switch (r.options.credentials) {
            .store => |s| s,
            .detect => |home| .detect(r.gpa, home),
        };
        r.options.credentials = .{ .store = store };
        var saved = store.snapshot(r.gpa) catch |err| {
            debug_trace.logf("mcp", "MCP credentials not loaded err={s}", .{@errorName(err)});
            return;
        };
        defer saved.deinit(r.gpa);
        for (r.resolved.engine_server) |i| {
            const s = r.resolved.servers[i];
            if (s.url == null) continue;
            const credential = saved.get(s.credentialKey()) orelse continue;
            r.engine.restoreCredential(s.name, credential) catch |err| {
                debug_trace.logf("mcp", "MCP credential not loaded server={s} err={s}", .{ s.name, @errorName(err) });
                continue;
            };
            r.flags[i].signed_in = true;

            r.flags[i].last_saved_digest = credentials.digest(credential);
        }
        r.publish() catch |err| debug_trace.logf("mcp", "MCP status not published err={s}", .{@errorName(err)});
    }

    fn allow(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) bool {
        return true;
    }

    fn log(_: *anyopaque, server: []const u8, line: []const u8) void {
        debug_trace.logf("mcp", "MCP server stderr server={s} line={s}", .{ server, line[0..@min(line.len, 512)] });
    }
};

fn signInFailure(buffer: []u8, why: mcp.auth.client.Failure, message: ?[]const u8) []const u8 {
    const what = switch (why) {
        .discovery => "fx couldn't find how to sign in to it",
        .registration => "it didn't register fx as a client; set oauth.client_id for it in mcp.json",
        .response => "the sign-in page returned an error",
        .mismatch => "the answer that came back wasn't for this sign-in",
        .redemption => "it didn't accept the sign-in",
        .cancelled => "the sign-in was cancelled",
        .refused => "fx has tried to sign in to it too many times; restart fx to try again",
        .insecure_endpoint => "its sign-in server uses plain HTTP, not HTTPS",
        .internal_endpoint => "its sign-in server points at an internal address fx won't contact",
        .metadata_not_json => "its sign-in metadata isn't JSON",
    };
    var said = std.mem.trimEnd(u8, message orelse return what, ". \t\r\n");
    if (said.len == 0) return what;

    if (said.len > 300) {
        var end: usize = 300;
        while (end > 0 and said[end] & 0xC0 == 0x80) end -= 1;
        said = said[0..end];
    }
    return std.mem.print(buffer, "{s} ({s})", .{ what, said }) catch what;
}

test "a failed sign-in says why in words, with the server's own" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("it didn't accept the sign-in (invalid_grant: The code expired)", signInFailure(&buffer, .redemption, "invalid_grant: The code expired."));
    try std.testing.expectEqualStrings("the sign-in was cancelled", signInFailure(&buffer, .cancelled, null));
    try std.testing.expectEqualStrings("it didn't register fx as a client; set oauth.client_id for it in mcp.json", signInFailure(&buffer, .registration, null));
    try std.testing.expectEqualStrings("the sign-in page returned an error", signInFailure(&buffer, .response, " . "));
    try std.testing.expectEqualStrings("the answer that came back wasn't for this sign-in", signInFailure(&buffer, .mismatch, null));
    const long = text_utils.repeat("\xc3\xa9", 200);
    const said = signInFailure(&buffer, .redemption, long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(said));
    try std.testing.expect(said.len < 340);
}

fn writeFailure(w: *std.Io.Writer, why: []const u8, exit: ?mcp.stdio.Exit, stray: ?[]const u8, tail: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll(describeFailure(why));

    const own = std.mem.eql(u8, why, "process");
    if (exit) |e| switch (e) {
        .code => |c| try w.print("{s} with code {d}", .{ if (own) "" else "; its process exited", c }),
        .signal => |n| try w.print("{s} on signal {d}", .{ if (own) "" else "; its process exited", n }),
    };
    if (stray) |line| try w.print("; it wrote \"{s}\" instead of MCP", .{line});
    if (tail) |t| try w.print("; its last stderr lines: \"{s}\"", .{t});
}

fn describeFailure(why: []const u8) []const u8 {
    const known = [_]struct { []const u8, []const u8 }{
        .{ "no_shared_version", "it supports no MCP version fx speaks" },
        .{ "rejected", "it refused fx's MCP version" },
        .{ "went_quiet", "it stopped answering while starting" },
        .{ "unsupported_version", "it answered with an MCP version fx doesn't support (fx speaks 2025-03-26 and newer)" },
        .{ "initialize_failed", "it refused or never answered fx's initialize request" },
        .{ "refused", "it refused the request fx sent to its endpoint" },
        .{ "session", "its session ended" },
        .{ "initialized_timed_out", "it never answered fx's initialized notification" },
        .{ "needs_auth", "it needs a login" },
        .{ "auth_unavailable", "its login couldn't be renewed: the sign-in server didn't answer; fx tries again" },
        .{ "process", "its process exited" },
        .{ "FileNotFound", "its command was not found" },
        .{ "AccessDenied", "its command could not be run (permission denied)" },
    };
    for (known) |entry| if (std.mem.eql(u8, entry[0], why)) return entry[1];
    return why;
}

const cancel_answer = "{\"action\":\"cancel\"}";

fn inputValues(a: Allocator, json: []const u8, keys: []const []const u8) ?[]const []const u8 {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .parse_numbers = false }) catch return null;
    if (answers != .object) return null;
    const values = a.alloc([]const u8, keys.len) catch return null;
    for (keys, values) |token, *value| {
        const key = json_decode.parseFromSliceLeaky([]const u8, a, token, .{}) catch return null;
        const answer = answers.object.get(key) orelse return null;
        value.* = std.json.Stringify.valueAlloc(a, answer, .{}) catch return null;
    }
    return values;
}

fn logUrlCallEnded(server: []const u8, step: []const u8, err: anyerror) void {
    debug_trace.logf("mcp", "MCP URL call ended server={s} step={s} err={s}", .{ server, step, @errorName(err) });
}

fn urlChoice(a: Allocator, json: ?[]const u8, n: usize) enum { accepted, declined, cancelled } {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json orelse return .cancelled, .{ .parse_numbers = false }) catch return .cancelled;
    if (answers != .object or answers.object.count() != n) return .cancelled;
    var declined = false;
    for (answers.object.values()) |reply| {
        if (reply != .object) return .cancelled;
        const action = reply.object.get("action") orelse return .cancelled;
        if (action != .string) return .cancelled;
        if (std.mem.eql(u8, action.string, "decline")) {
            declined = true;
        } else if (!std.mem.eql(u8, action.string, "accept")) return .cancelled;
    }
    return if (declined) .declined else .accepted;
}

fn elicitAnswer(a: Allocator, json: ?[]const u8) ?mcp.elicitation.Answer {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json orelse return null, .{ .parse_numbers = false }) catch return null;
    if (answers != .object) return null;
    const reply = answers.object.get("elicitation") orelse return null;
    if (reply != .object) return null;
    const action_value = reply.object.get("action") orelse return null;
    if (action_value != .string) return null;
    const action = std.meta.stringToEnum(@FieldType(mcp.elicitation.Answer, "action"), action_value.string) orelse return null;
    const content = if (reply.object.get("content")) |c| std.json.Stringify.valueAlloc(a, c, .{}) catch return null else null;
    return .{ .action = action, .content = content };
}

fn copyResource(alloc: Allocator, outcome: engine.Outcome, answer: ?mcp.resources.Answer) Allocator.Error!ResourceResult {
    const a = answer orelse return .{ .ended = .{ .outcome = outcome } };
    return switch (a) {
        .result => |raw| if (outcome == .result) .{ .result = try alloc.dupe(u8, raw) } else .{ .ended = .{ .outcome = outcome } },
        .failure => |f| .{ .failure = .{ .code = f.code, .message = try alloc.dupe(u8, f.message) } },
        .invalid => .{ .ended = .{ .outcome = if (outcome == .result) .malformed else outcome } },
    };
}

fn copyCall(alloc: Allocator, c: anytype) Allocator.Error!CallResult {
    const answer = c.answer orelse return .{ .ended = .{ .outcome = c.outcome, .maybe_ran = c.maybe_ran, .timed_out = c.timed_out } };
    return switch (answer) {
        .result => |res| .{ .result = .{
            .content = try alloc.dupe(u8, res.content),
            .structured = if (res.structured) |s| try alloc.dupe(u8, s) else null,
            .is_error = res.is_error,
        } },
        .failure => |f| .{ .failure = .{ .code = f.code, .message = try alloc.dupe(u8, f.message) } },

        .input_required, .invalid => .{ .ended = .{
            .outcome = if (c.outcome == .result) .malformed else c.outcome,
            .maybe_ran = true,
            .timed_out = false,
        } },
    };
}

test {
    _ = config;
    _ = credentials;
    _ = loopback;
}

const testing = std.testing;

const Fixture = @import("fake_server.zig").Fixture;
const HttpFixture = @import("fake_server.zig").HttpFixture;
const SseFixture = @import("fake_server.zig").SseFixture;

test "a static headers helper is run again after a 401, and the call goes on with the new credential" {
    var h: HttpFixture = undefined;
    try h.init();
    defer h.deinit();
    const helper = try std.fmt.allocPrint(testing.allocator, "printf '{{\"Authorization\":\"Bearer %s\"}}' \"$(cat '{s}')\"", .{h.token_path});
    defer testing.allocator.free(helper);
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "remote", .transport = .http, .url = h.url, .headers_helper = helper }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &h.fixture.inherited, h.fixture.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    switch (try r.tools(arena.allocator(), "remote", null)) {
        .tools => |listed| {
            try testing.expectEqual(@as(usize, 1), listed.len);
            try testing.expectEqualStrings("echo", listed[0].name);
        },
        else => return error.ToolsNotListed,
    }
    try testing.expect(h.unauthorized.load(.acquire) >= 1);
    try testing.expect(h.authorized.load(.acquire) >= 2);
}

test "a server that refuses its HTTP endpoint is reached over its SSE stream and lists its tools" {
    var h: SseFixture = undefined;
    try h.init();
    defer h.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "remote", .transport = .http, .url = h.url }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &h.fixture.inherited, h.fixture.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    switch (try r.tools(arena.allocator(), "remote", null)) {
        .tools => |listed| {
            try testing.expectEqual(@as(usize, 1), listed.len);
            try testing.expectEqualStrings("echo", listed[0].name);
        },
        else => return error.ToolsNotListed,
    }
    try testing.expect(h.refused.load(.acquire) >= 1);
    try testing.expect(h.streams.load(.acquire) >= 1);
}

test "tools and calls go through the owner thread, from several threads at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listed = try r.tools(arena.allocator(), "fake", null);
    try testing.expectEqual(@as(usize, 1), listed.tools.len);
    try testing.expectEqualStrings("echo", listed.tools[0].name);
    const status = (try r.statuses(arena.allocator()))[0];
    try testing.expectEqual(State.ready, status.state);
    try testing.expectEqualStrings("2025-11-25", status.version.?);
    try testing.expectEqual(@as(usize, 1), status.tools);

    const Caller = struct {
        fn run(runtime: *Runtime, ok: *std.atomic.Value(u32)) void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            const result = runtime.call(a.allocator(), "fake", "echo", "{}", null, null) catch return;
            if (result == .result and std.mem.find(u8, result.result.content, "hi") != null) _ = ok.fetchAdd(1, .acq_rel);
        }
    };
    var ok: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Caller.run, .{ &r, &ok });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 4), ok.load(.acquire));
}

test "a cancelled call ends, and stopping ends a call that never answers" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    var stopped = false;
    defer if (!stopped) r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
            flag.store(true, .release);
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{&cancel});
    const cancelled = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"slow\"}", &cancel, null);
    canceller.join();
    try testing.expectEqual(engine.Outcome.cancelled, cancelled.ended.outcome);

    const Waiter = struct {
        fn run(runtime: *Runtime, got: *?Error) void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = runtime.call(a.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch |err| {
                got.* = err;
            };
        }
    };
    var got: ?Error = null;
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &r, &got });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    r.deinit();
    stopped = true;
    waiter.join();
    try testing.expectEqual(@as(?Error, error.Stopped), got);
}

test "while a retired host's servers stop, nothing starts a server, and a cancel still gets through" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "late", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try r.tools(a, "fake", null);

    const Caller = struct {
        fn call(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
        fn list(runtime: *Runtime, done: *std.atomic.Value(bool)) void {
            var la: std.heap.ArenaAllocator = .init(testing.allocator);
            defer la.deinit();
            const listed = runtime.tools(la.allocator(), "late", null) catch return;
            if (listed == .tools and listed.tools.len == 1) done.store(true, .release);
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    var outcome: ?engine.Outcome = null;
    const caller = try std.Thread.spawn(.{}, Caller.call, .{ &r, &cancel, &outcome });
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};

    retireStarted();
    var holding = true;
    defer if (holding) retireEnded();
    var listed: std.atomic.Value(bool) = .init(false);
    const lister = try std.Thread.spawn(.{}, Caller.list, .{ &r, &listed });

    cancel.store(true, .release);
    caller.join();
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    try testing.expect(!listed.load(.acquire));
    try testing.expectEqual(State.idle, (try r.statuses(a))[1].state);

    retireEnded();
    holding = false;
    const ended_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    while ((try r.statuses(a))[1].state == .idle) std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};

    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - ended_ms < 500);
    lister.join();
    try testing.expect(listed.load(.acquire));
}

test "a call held while a retired host's servers stop ends when cancelled, and its server never starts" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Caller = struct {
        fn call(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome, done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"late\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
    };
    retireStarted();
    var holding = true;
    defer if (holding) retireEnded();
    var cancel: std.atomic.Value(bool) = .init(false);
    var outcome: ?engine.Outcome = null;
    var done: std.atomic.Value(bool) = .init(false);
    const caller = try std.Thread.spawn(.{}, Caller.call, .{ &r, &cancel, &outcome, &done });

    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    const waited = !done.load(.acquire);
    cancel.store(true, .release);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 2_000;
    while (!done.load(.acquire) and std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    }

    const ended_while_held = done.load(.acquire);
    retireEnded();
    holding = false;
    caller.join();
    try testing.expect(waited);
    try testing.expect(ended_while_held);
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    try testing.expectEqual(State.idle, (try r.statuses(arena.allocator()))[0].state);
}

test "a replaced runtime still in use serves its calls, and holds the others until it's gone" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var old: Runtime = undefined;
    try old.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    var old_up = true;
    defer if (old_up) old.deinit();
    var next: Runtime = undefined;
    try next.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer next.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    old.retire();

    try testing.expectEqual(@as(usize, 1), (try old.tools(a, "fake", null)).tools.len);

    const Lister = struct {
        fn run(runtime: *Runtime, done: *std.atomic.Value(bool)) void {
            var la: std.heap.ArenaAllocator = .init(testing.allocator);
            defer la.deinit();
            const listed = runtime.tools(la.allocator(), "fake", null) catch return;
            if (listed == .tools and listed.tools.len == 1) done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const lister = try std.Thread.spawn(.{}, Lister.run, .{ &next, &done });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    try testing.expect(!done.load(.acquire));
    try testing.expectEqual(State.idle, (try next.statuses(a))[0].state);

    old.deinit();
    old_up = false;
    lister.join();
    try testing.expect(done.load(.acquire));
}

fn pidOf(r: *Runtime, a: Allocator, name: []const u8) ![]const u8 {
    const result = try r.call(a, name, "echo", "{\"text\":\"pid\"}", null, null);
    if (result != .result) return error.TestUnexpectedResult;
    const at = std.mem.find(u8, result.result.content, "pid=") orelse return error.TestUnexpectedResult;
    const digits = result.result.content[at + 4 ..];
    return digits[0 .. std.mem.findNone(u8, digits, "0123456789") orelse digits.len];
}

test "a reload keeps a server whose config is the same on its process, restarts the changed ones, lists a deleted one as removed, and leaves a new one for the next session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var one = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("one") }};
    var two = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("two") }};
    const before = [_]mcp_contract.McpServerConfig{
        .{ .name = "same", .command = f.server, .env = &one },
        .{ .name = "args", .command = f.server },
        .{ .name = "env", .command = f.server, .env = &one },
        .{ .name = "gone", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "same", null)).tools.len);
    const same = try pidOf(&r, a, "same");
    const args = try pidOf(&r, a, "args");
    const env = try pidOf(&r, a, "env");
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "gone", null)).tools.len);
    _ = try pidOf(&r, a, "gone");

    const after = [_]mcp_contract.McpServerConfig{
        .{ .name = "added", .command = f.server },
        .{ .name = "same", .command = f.server, .env = &one },
        .{ .name = "args", .command = f.server, .args = &.{"--new"} },
        .{ .name = "env", .command = f.server, .env = &two },
    };
    const done = try r.reload(&after, &f.inherited);
    try testing.expectEqualSlices(bool, &.{ true, false, false, true }, done.kept);
    try testing.expect(done.dropped);
    const statuses = try r.statuses(a);
    try testing.expectEqual(@as(usize, 4), statuses.len);
    try testing.expectEqualStrings("same", statuses[0].name);
    try testing.expectEqual(State.ready, statuses[0].state);
    try testing.expectEqual(@as(usize, 1), statuses[0].tools);
    try testing.expectEqualStrings("gone", statuses[3].name);
    try testing.expectEqual(State.removed, statuses[3].state);
    try testing.expectEqual(@as(usize, 1), statuses[3].tools);
    try testing.expectEqualStrings(same, try pidOf(&r, a, "same"));
    try testing.expect(!std.mem.eql(u8, args, try pidOf(&r, a, "args")));
    try testing.expect(!std.mem.eql(u8, env, try pidOf(&r, a, "env")));
    try testing.expectEqual(CallResult.unknown_server, try r.call(a, "added", "echo", "{}", null, null));
    try testing.expectEqual(ToolsResult.unknown_server, try r.tools(a, "added", null));

    const refused = try r.call(a, "gone", "echo", "{}", null, null);
    try testing.expectEqual(engine.Outcome.lost, refused.ended.outcome);
    try testing.expect(!refused.ended.maybe_ran);
    try testing.expectEqualStrings(removed_server_call_reason, refused.ended.why.?);
    try testing.expectEqualStrings("the server was removed from the MCP config", (try r.tools(a, "gone", null)).failed);
    try testing.expectError(error.UnknownServer, r.login("gone", false));
    try testing.expectError(error.UnknownServer, r.logout("gone"));

    var more: [5]mcp_contract.McpServerConfig = undefined;
    @memcpy(more[0..4], &after);
    more[4] = .{ .name = "late", .command = f.server };
    try testing.expect(!(try r.reload(&more, &f.inherited)).dropped);
    try testing.expectEqualStrings(same, try pidOf(&r, a, "same"));
    const still = try r.statuses(a);
    try testing.expectEqual(@as(usize, 4), still.len);
    try testing.expectEqual(State.removed, still[3].state);
    try testing.expectEqual(@as(usize, 1), still[3].tools);

    more[4] = .{ .name = "gone", .command = f.server };
    const back = try r.reload(&more, &f.inherited);
    try testing.expectEqualSlices(bool, &.{ true, true, true, false }, back.kept);
    try testing.expect(!back.dropped);
    _ = try pidOf(&r, a, "gone");
    try testing.expectEqualStrings(same, try pidOf(&r, a, "same"));
    for (try r.statuses(a)) |status| try testing.expect(status.state != .removed);
}

test "a reload ends a call on a server it drops, and a call on a server it keeps goes on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = [_]mcp_contract.McpServerConfig{
        .{ .name = "kept", .command = f.server },
        .{ .name = "gone", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try r.tools(a, "kept", null);
    _ = try r.tools(a, "gone", null);

    const Caller = struct {
        server: []const u8,
        cancel: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        ended: ?@FieldType(CallResult, "ended") = null,
        why: [128]u8 = undefined,
        why_len: usize = 0,

        fn run(c: *@This(), runtime: *Runtime) void {
            defer c.done.store(true, .release);
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), c.server, "echo", "{\"text\":\"slow\"}", &c.cancel, null) catch return;
            if (result != .ended) return;
            c.ended = result.ended;
            if (result.ended.why) |why| {
                c.why_len = @min(why.len, c.why.len);
                @memcpy(c.why[0..c.why_len], why[0..c.why_len]);
            }
        }
    };
    var kept: Caller = .{ .server = "kept" };
    var gone: Caller = .{ .server = "gone" };
    const kept_thread = try std.Thread.spawn(.{}, Caller.run, .{ &kept, &r });
    const gone_thread = try std.Thread.spawn(.{}, Caller.run, .{ &gone, &r });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};

    const after = [_]mcp_contract.McpServerConfig{.{ .name = "kept", .command = f.server }};
    _ = try r.reload(&after, &f.inherited);
    gone_thread.join();
    try testing.expectEqual(engine.Outcome.cancelled, gone.ended.?.outcome);

    try testing.expect(gone.ended.?.maybe_ran);
    try testing.expectEqualStrings("the MCP config changed, and fx stopped the server", gone.why[0..gone.why_len]);

    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    try testing.expect(!kept.done.load(.acquire));
    kept.cancel.store(true, .release);
    kept_thread.join();
    try testing.expectEqual(engine.Outcome.cancelled, kept.ended.?.outcome);
    try testing.expectEqual(@as(usize, 0), kept.why_len);
}

test "a changed server's new process starts only once the old one is gone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = [_]mcp_contract.McpServerConfig{.{ .name = "slow-exit", .command = f.server, .args = &.{"linger"} }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "slow-exit"), 10);

    const after = [_]mcp_contract.McpServerConfig{.{ .name = "slow-exit", .command = f.server, .args = &.{ "linger", "again" } }};
    const reloaded_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    _ = try r.reload(&after, &f.inherited);
    const new = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "slow-exit"), 10);
    try testing.expect(new != old);

    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - reloaded_ms >= 900);
    try testing.expectError(error.ProcessNotFound, std.posix.kill(old, @fromBackingInt(@intCast(0))));
}

test "an answer to a withdrawn 2025 question reaches no one, and the next question gets its own" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.questions = .{ .form = true };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();

    const User = struct {
        fn ask(_: *anyopaque, alloc: Allocator, question: Question) anyerror!?[]u8 {
            const which = if (std.mem.find(u8, question.input_requests_json, "\"Q2\"") != null) "Q2" else "Q1";
            return try alloc.print("{{\"elicitation\":{{\"action\":\"accept\",\"content\":{{\"name\":\"for-{s}\"}}}}}}", .{which});
        }
    };
    var user: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"withdraw\"}", null, .{ .context = &user, .ask = User.ask });
    try testing.expect(result == .result);
    try testing.expect(std.mem.find(u8, result.result.content, "e2=for-Q2") != null);
    try testing.expect(std.mem.find(u8, result.result.content, "e1 ") == null);
}

test "a failure says how the process ended, what it wrote instead of MCP, and its last stderr lines" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFailure(&w, "process", .{ .code = 7 }, null, "npm error code E401 / npm error Incorrect or missing password.");
    try testing.expectEqualStrings("its process exited with code 7; its last stderr lines: \"npm error code E401 / npm error Incorrect or missing password.\"", w.buffered());
    w = .fixed(&buf);
    try writeFailure(&w, "initialize_failed", .{ .signal = 15 }, "not json", null);
    try testing.expectEqualStrings("it refused or never answered fx's initialize request; its process exited on signal 15; it wrote \"not json\" instead of MCP", w.buffered());
    w = .fixed(&buf);
    try writeFailure(&w, "FileNotFound", null, null, null);
    try testing.expectEqualStrings("its command was not found", w.buffered());
}

test "a question no call can show is answered cancel, and the server goes on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.questions = .{ .form = true };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"confirm\"}", null, null);
    try testing.expect(result == .result);
    try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"c1=cancel\"}]", result.result.content);
}

test "saved credentials load on the owner thread, and statuses wait for them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const store: credentials.Store = .{ .home = f.home, .backend = .file };
    try store.put(testing.allocator, .{ .name = "web", .url = "https://web.example.invalid/mcp" }, "{\"access\":\"w1\"}");
    try store.put(testing.allocator, .{ .name = "moved", .url = "https://old.example.invalid/mcp" }, "{\"access\":\"m1\"}");

    try store.put(testing.allocator, .{ .name = "team", .url = "https://team.example.invalid/mcp" }, "{\"access\":\"profile\"}");
    try store.put(testing.allocator, .{ .name = "repo", .url = "https://repo.example.invalid/mcp", .workspace = "/Users/example/repo" }, "{\"access\":\"r1\"}");
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "web", .transport = .http, .url = "https://web.example.invalid/mcp" },

        .{ .name = "moved", .transport = .http, .url = "https://new.example.invalid/mcp" },
        .{ .name = "none", .transport = .http, .url = "https://none.example.invalid/mcp" },
        .{ .name = "fake", .command = f.server },
        .{ .name = "team", .transport = .http, .url = "https://team.example.invalid/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
        .{ .name = "repo", .transport = .http, .url = "https://repo.example.invalid/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
    };
    var options = f.options();
    options.workspace_root = "/Users/example/repo";
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.statuses(arena.allocator());
    try testing.expect(got[0].signed_in);
    try testing.expect(!got[1].signed_in);
    try testing.expect(!got[2].signed_in);
    try testing.expect(!got[3].signed_in);
    try testing.expect(!got[4].signed_in);
    try testing.expect(got[5].signed_in);
    try testing.expectEqual(State.idle, got[0].state);
}

test "held servers say why, and unknown names and stdio logins are refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "off", .command = f.server, .enabled = false },
        .{ .name = "pending", .command = f.server, .source = .workspace, .workspace_admission = .pending },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const statuses_ = try r.statuses(a);
    try testing.expectEqual(State.idle, statuses_[0].state);
    try testing.expectEqual(State.disabled, statuses_[1].state);
    try testing.expectEqual(State.waiting_for_approval, statuses_[2].state);
    try testing.expectEqualStrings("the project server is waiting for approval", (try r.tools(a, "pending", null)).failed);
    try testing.expect((try r.tools(a, "nope", null)) == .unknown_server);
    try testing.expectError(error.Held, r.call(a, "off", "echo", null, null, null));
    try testing.expectError(error.NotHttp, r.login("fake", false));
    try testing.expectError(error.UnknownServer, r.logout("nope"));
}

test "a server that keeps failing to start answers a tool request at once while it waits to retry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "flaky", .command = "/bin/sh", .args = &.{ "-c", "exit 1" } }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try r.tools(a, "flaky", null)) == .failed);
    try testing.expectEqual(State.retrying, (try r.statuses(a))[0].state);

    const asked_at = io_mod.milliTimestamp();
    try testing.expect((try r.tools(a, "flaky", null)) == .failed);
    try testing.expect(io_mod.milliTimestamp() - asked_at < 1_000);
    try testing.expectEqual(State.retrying, (try r.statuses(a))[0].state);
}

test "a held call's URLs are opened only when the user accepted every one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"},\"b\":{\"action\":\"accept\"}}", 2) == .accepted);
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"},\"b\":{\"action\":\"decline\"}}", 2) == .declined);
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"cancel\"},\"b\":{\"action\":\"accept\"}}", 2) == .cancelled);

    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"}}", 2) == .cancelled);
    try testing.expect(urlChoice(a, null, 1) == .cancelled);
    try testing.expect(urlChoice(a, "not json", 1) == .cancelled);
}

test "answers go back under the server's keys, and an answer that can't be read declines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const keys = [_][]const u8{ "\"confirm\"", "\"pick\"" };
    const values = inputValues(a, "{\"pick\":{\"action\":\"decline\"},\"confirm\":{\"action\":\"accept\",\"content\":{\"ok\":true}}}", &keys).?;
    try testing.expectEqualStrings("{\"action\":\"accept\",\"content\":{\"ok\":true}}", values[0]);
    try testing.expectEqualStrings("{\"action\":\"decline\"}", values[1]);
    try testing.expect(inputValues(a, "{\"confirm\":{\"action\":\"accept\"}}", &keys) == null);
    try testing.expect(inputValues(a, "[]", &keys) == null);

    const accepted = elicitAnswer(a, "{\"elicitation\":{\"action\":\"accept\",\"content\":{\"choice\":\"x\"}}}").?;
    try testing.expectEqual(.accept, accepted.action);
    try testing.expectEqualStrings("{\"choice\":\"x\"}", accepted.content.?);
    const declined = elicitAnswer(a, "{\"elicitation\":{\"action\":\"decline\"}}").?;
    try testing.expectEqual(.decline, declined.action);
    try testing.expect(declined.content == null);
    try testing.expect(elicitAnswer(a, "{\"elicitation\":{\"action\":\"maybe\"}}") == null);
    try testing.expect(elicitAnswer(a, "{}") == null);
    try testing.expect(elicitAnswer(a, null) == null);
}

test "authenticate refuses unknown, held and stdio servers, and a server that asked for no login is already signed in" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "off", .command = f.server, .enabled = false },
        .{ .name = "web", .transport = .http, .url = "https://web.example.invalid/mcp" },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try r.authenticate(a, "nope", false, null, null)) == .unknown_server);
    try testing.expectError(error.NotHttp, r.authenticate(a, "fake", false, null, null));
    try testing.expectError(error.Held, r.authenticate(a, "off", false, null, null));
    try testing.expect((try r.authenticate(a, "web", false, null, null)) == .already_signed_in);
}

test "a failed authenticate keeps the reason and the authorization address for its caller" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const with_url = try signInFailed(arena.allocator(), sign_in_timed_out, "https://auth.example.test/authorize?state=abc&code_challenge=xyz");
    try testing.expectEqualStrings("the browser didn't come back within 15 minutes", with_url.failed.reason);
    try testing.expectEqualStrings("https://auth.example.test/authorize?state=abc&code_challenge=xyz", with_url.failed.url.?);
    const before_url = try signInFailed(arena.allocator(), "the server refused", null);
    try testing.expect(before_url.failed.url == null);
}

test "the authenticate status shows the authorization address unchanged and the fifteen minute wait" {
    var buffer: [512]u8 = undefined;
    const status = try std.mem.print(&buffer, sign_in_url_status, .{ "linear", "https://auth.example.test/authorize?state=abc" });
    try testing.expectEqualStrings(
        "Open this URL in your browser to authorize \"linear\":\n\nhttps://auth.example.test/authorize?state=abc\n\n" ++
            "Waiting for the OAuth callback (timeout 15 min). If you cancel, call this tool again to restart the flow.",
        status,
    );
}
