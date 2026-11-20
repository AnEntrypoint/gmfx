const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const command_runner = @import("../execution/command_runner.zig");
const capability_mod = @import("../tooling/mcp_call_capability.zig");
const mcp_call = @import("mcp_call.zig");
const wire = @import("mcp_call_wire.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const supported = capability_mod.supported;

const gpa = std.heap.c_allocator;
const max_connections = 64;
const poll_ms = 100;
const request_deadline_ms: i64 = 10_000;

pub const Registration = struct {
    owner: mcp_call.OwnerId,
    capability: capability_mod.Capability,
    hold: std.atomic.Value(u32) = .init(0),
    in_use: u32 = 0,
    token_hex: [wire.token_hex_len]u8,
    variables: [2]command_runner.EnvironmentVariable = undefined,

    pub fn environment(self: *const Registration) []const command_runner.EnvironmentVariable {
        return &self.variables;
    }
};

const ServedRequest = struct {
    id: mcp_call.RequestId,
    cancel: std.atomic.Value(bool) = .init(false),
};

const Phase = enum { idle, running, stopping };

const Bridge = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    prompt: std.Io.Mutex = .init,
    state: mcp_call.State = .init(mcp_call.default_capacity),
    phase: Phase = .idle,
    dir_path: ?[]u8 = null,
    socket_path: ?[]u8 = null,
    listener: ?std.Io.net.Server = null,
    accept_task: ?std.Io.Future(void) = null,
    connection_tasks: std.Io.Group = .init,
    stop: std.atomic.Value(bool) = .init(false),
    registrations: std.ArrayList(*Registration) = .empty,
    served_requests: std.ArrayList(*ServedRequest) = .empty,
    next_owner: u32 = 1,
    connections: u32 = 0,
};

var bridge: Bridge = .{};

pub fn register(capability: capability_mod.Capability) !*Registration {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    while (bridge.phase == .stopping) bridge.changed.waitUncancelable(io, &bridge.mutex);
    if (bridge.phase == .idle) try startLocked(io);

    if (bridge.registrations.items.len + 1 >= mcp_call.max_owners) return error.McpCallBridgeFull;
    try bridge.registrations.ensureUnusedCapacity(gpa, 1);
    const registration = try gpa.create(Registration);
    var token: mcp_call.Token = undefined;
    io.random(&token);
    registration.* = .{ .owner = nextOwnerLocked(), .capability = capability, .token_hex = wire.tokenHex(token) };
    registration.variables = .{
        .{ .name = wire.socket_env, .value = bridge.socket_path.? },
        .{ .name = wire.token_env, .value = &registration.token_hex },
    };
    bridge.registrations.appendAssumeCapacity(registration);
    applyLocked(mcp_call.step(bridge.state, .{ .owner_added = .{ .owner = registration.owner, .token = token } }));
    return registration;
}

pub fn unregister(registration: *Registration) void {
    const io = io_mod.getIo();
    bridge.mutex.lockUncancelable(io);
    applyLocked(mcp_call.step(bridge.state, .{ .owner_removed = registration.owner }));
    while (registration.in_use > 0) bridge.changed.waitUncancelable(io, &bridge.mutex);
    for (bridge.registrations.items, 0..) |item, index| {
        if (item == registration) {
            _ = bridge.registrations.swapRemove(index);
            break;
        }
    }
    const last = bridge.registrations.items.len == 0;
    var accept_task: ?std.Io.Future(void) = null;
    if (last) {
        applyLocked(mcp_call.step(bridge.state, .stopped));
        bridge.phase = .stopping;
        bridge.stop.store(true, .release);
        accept_task = bridge.accept_task;
        bridge.accept_task = null;
    }
    bridge.mutex.unlock(io);
    gpa.destroy(registration);
    if (!last) return;

    if (accept_task) |*task| task.await(io);
    bridge.connection_tasks.cancel(io);
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    closeListenerLocked(io);
    bridge.stop.store(false, .release);
    bridge.phase = .idle;
    bridge.changed.broadcast(io);
}

fn nextOwnerLocked() mcp_call.OwnerId {
    while (true) {
        const candidate = bridge.next_owner;
        bridge.next_owner +%= 1;
        if (candidate == 0) continue;
        const owner: mcp_call.OwnerId = @fromBackingInt(candidate);
        for (bridge.registrations.items) |registration| {
            if (registration.owner == owner) break;
        } else return owner;
    }
}

fn startLocked(io: std.Io) !void {
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    const tmp = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");

    const base = if (tmp.len + 40 < 100) tmp else "/tmp";
    const dir_path = try gpa.print("{s}/fx-mcp-{s}", .{ base, &hex });
    errdefer gpa.free(dir_path);
    const socket_path = try gpa.print("{s}/s", .{dir_path});
    errdefer gpa.free(socket_path);
    try std.Io.Dir.cwd().createDir(io, dir_path, .fromMode(0o700));
    errdefer std.Io.Dir.cwd().deleteDir(io, dir_path) catch {};
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    errdefer listener.deinit(io);
    bridge.listener = listener;
    bridge.stop.store(false, .release);
    bridge.accept_task = std.Io.concurrent(io, acceptLoop, .{}) catch |err| {
        bridge.listener = null;
        std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        return err;
    };
    bridge.dir_path = dir_path;
    bridge.socket_path = socket_path;
    var main_token: mcp_call.Token = undefined;
    io.random(&main_token);

    applyLocked(mcp_call.step(bridge.state, .{ .started = main_token }));
    bridge.phase = .running;
    debug_trace.logf("mcp-call", "bridge listening socket={s}", .{socket_path});
}

fn closeListenerLocked(io: std.Io) void {
    if (bridge.listener) |*listener| listener.deinit(io);
    bridge.listener = null;
    if (bridge.socket_path) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| debug_trace.logf("mcp-call", "bridge socket not removed err={s}", .{@errorName(err)});
        gpa.free(path);
    }
    if (bridge.dir_path) |path| {
        std.Io.Dir.cwd().deleteDir(io, path) catch |err| debug_trace.logf("mcp-call", "bridge directory not removed err={s}", .{@errorName(err)});
        gpa.free(path);
    }
    bridge.socket_path = null;
    bridge.dir_path = null;
    debug_trace.logf("mcp-call", "bridge closed", .{});
}

fn applyLocked(out: mcp_call.Output) void {
    bridge.state = out.state;
    for (out.effects()) |effect| switch (effect) {
        .cancel => |id| {
            for (bridge.served_requests.items) |served| {
                if (served.id == id) served.cancel.store(true, .release);
            }
        },
        .withdraw => |id| debug_trace.logf("mcp-call", "request={d} client or owner gone; its permission prompt stays until answered, and nothing runs", .{@backingInt(id)}),
        .log => |log| debug_trace.logf("mcp-call", "request={d} dropped={s}", .{ @backingInt(log.id), @tagName(log.drop) }),
        .refuse, .authorize, .call, .reply => {},
    };
}

fn step(event: mcp_call.Event) mcp_call.Output {
    const out = mcp_call.step(bridge.state, event);
    applyLocked(out);
    return out;
}

fn acceptLoop() void {
    const io = io_mod.getIo();
    const listener = &bridge.listener.?;
    while (!bridge.stop.load(.acquire)) {
        var fds = [_]posix.pollfd{.{ .fd = listener.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, poll_ms) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept loop ended err={s}", .{@errorName(err)});
            return;
        };
        if (ready == 0) continue;
        const stream = listener.accept(io) catch |err| {
            debug_trace.logf("mcp-call", "bridge accept failed err={s}", .{@errorName(err)});
            continue;
        };
        bridge.mutex.lockUncancelable(io);
        const room = bridge.connections < max_connections;
        if (room) bridge.connections += 1;
        bridge.mutex.unlock(io);
        if (!room) {
            debug_trace.logf("mcp-call", "bridge connection dropped: {d} already open", .{max_connections});
            stream.close(io);
            continue;
        }
        bridge.connection_tasks.concurrent(io, serve, .{stream}) catch |err| {
            debug_trace.logf("mcp-call", "bridge connection dropped: no task err={s}", .{@errorName(err)});
            finishConnection(io, stream);
            continue;
        };
    }
}

fn finishConnection(io: std.Io, stream: std.Io.net.Stream) void {
    stream.close(io);
    bridge.mutex.lockUncancelable(io);
    defer bridge.mutex.unlock(io);
    bridge.connections -= 1;
}

const ReadError = error{ TooLarge, Silent, Closed, ReadFailed, OutOfMemory, Canceled };

fn readRequestLine(arena: Allocator, fd: posix.socket_t) ReadError![]const u8 {
    const io = io_mod.getIo();
    var line: std.ArrayList(u8) = .empty;
    const deadline = io_mod.milliTimestamp() + request_deadline_ms;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        try io.checkCancel();
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.Silent;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, @intCast(@min(remaining, poll_ms))) catch return error.ReadFailed;
        if (ready == 0) continue;
        const rc = std.c.recv(fd, &chunk, chunk.len, 0);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR or posix.errno(rc) == .AGAIN) continue;
            return error.ReadFailed;
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.Closed;
        if (std.mem.findScalar(u8, chunk[0..n], '\n')) |end| {
            if (line.items.len + end > wire.max_request_bytes) return error.TooLarge;
            try line.appendSlice(arena, chunk[0..end]);
            return line.items;
        }
        if (line.items.len + n > wire.max_request_bytes) return error.TooLarge;
        try line.appendSlice(arena, chunk[0..n]);
    }
}

fn writeReply(stream: std.Io.net.Stream, status: wire.Status, reason: ?wire.Reason, bytes: []const u8) bool {
    const io = io_mod.getIo();
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    wire.writeHeader(&writer.interface, .{ .status = status, .reason = reason, .bytes = bytes.len }) catch return false;
    writer.interface.writeAll(bytes) catch return false;
    writer.interface.flush() catch return false;
    return true;
}

fn refusalMessage(reason: wire.Reason) []const u8 {
    return switch (reason) {
        .closed => "The fx session's shell call that started this command has ended. Run fx mcp call from a command in a new shell call.",
        .unauthorized => "This command was not started by a running fx shell call, or that call has ended. Run fx mcp call from a command fx's shell tool runs, not from one left running in the background.",
        .unsupported_version => "This fx mcp call is from another fx version than the running session. Run the fx that started the session, or restart the session with this one.",
        .busy => "Too many fx mcp call requests are running in this session. Nothing ran; try again when one finishes.",
        .malformed => "The request was not an fx mcp call request. Send requests with the fx that started the session.",
        .too_large => "The request is over 1 MiB. Pass smaller arguments.",
    };
}

const Watch = struct {
    fd: posix.socket_t,
    id: mcp_call.RequestId,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        const io = io_mod.getIo();
        while (!self.done.load(.acquire)) {
            var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, poll_ms) catch return;
            if (ready == 0) continue;
            var probe: [1]u8 = undefined;
            const rc = std.c.recv(self.fd, &probe, 1, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            const hung_up = (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0;
            if (rc == 0 or hung_up) {
                bridge.mutex.lockUncancelable(io);
                _ = step(.{ .client_gone = self.id });
                bridge.mutex.unlock(io);
                return;
            }

            io_mod.sleep(poll_ms * std.time.ns_per_ms);
        }
    }
};

fn serve(stream: std.Io.net.Stream) void {
    const io = io_mod.getIo();
    defer finishConnection(io, stream);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = readRequestLine(arena, stream.socket.handle) catch |err| {
        debug_trace.logf("mcp-call", "bridge request not read err={s}", .{@errorName(err)});
        if (err == error.TooLarge) _ = writeReply(stream, .refused, .too_large, refusalMessage(.too_large));
        if (err == error.Silent) _ = writeReply(stream, .refused, .malformed, refusalMessage(.malformed));
        return;
    };
    const request = wire.parseRequest(arena, line) catch |err| {
        debug_trace.logf("mcp-call", "bridge request malformed err={s}", .{@errorName(err)});
        _ = writeReply(stream, .refused, .malformed, refusalMessage(.malformed));
        return;
    };

    var served: ServedRequest = undefined;
    var registration: *Registration = undefined;
    bridge.mutex.lockUncancelable(io);
    bridge.served_requests.ensureUnusedCapacity(gpa, 1) catch {
        bridge.mutex.unlock(io);
        _ = writeReply(stream, .failed, null, "fx could not take this request: out of memory.");
        return;
    };
    const admitted = step(.{ .request = .{ .token = request.token orelse @splat(0), .version = request.version } });
    const work: mcp_call.Work = for (admitted.effects()) |effect| switch (effect) {
        .authorize => |value| break value,
        .refuse => |refusal| {
            bridge.mutex.unlock(io);
            const reason = wire.Reason.fromRefusal(refusal);
            debug_trace.logf("mcp-call", "bridge refused op={s} reason={s}", .{ @tagName(request.operation), @tagName(reason) });
            _ = writeReply(stream, .refused, reason, refusalMessage(reason));
            return;
        },
        else => {},
    } else {
        bridge.mutex.unlock(io);
        return;
    };
    registration = for (bridge.registrations.items) |item| {
        if (item.owner == work.owner) break item;
    } else unreachable;
    served = .{ .id = work.id };
    bridge.served_requests.appendAssumeCapacity(&served);
    registration.in_use += 1;
    _ = registration.hold.fetchAdd(1, .acq_rel);
    bridge.mutex.unlock(io);
    defer {
        bridge.mutex.lockUncancelable(io);
        for (bridge.served_requests.items, 0..) |item, index| {
            if (item == &served) {
                _ = bridge.served_requests.swapRemove(index);
                break;
            }
        }
        _ = registration.hold.fetchSub(1, .acq_rel);
        registration.in_use -= 1;
        bridge.changed.broadcast(io);
        bridge.mutex.unlock(io);
    }

    var watch: Watch = .{ .fd = stream.socket.handle, .id = work.id };
    var watcher: ?std.Io.Future(void) = std.Io.concurrent(io, Watch.run, .{&watch}) catch |err| blk: {
        debug_trace.logf("mcp-call", "request={d} runs without a disconnect watch err={s}", .{ @backingInt(work.id), @errorName(err) });
        break :blk null;
    };
    defer if (watcher) |*task| {
        watch.done.store(true, .release);
        task.await(io);
    };

    const request_id = arena.print("fx-mcp-call-{d}", .{@backingInt(work.id)}) catch "fx-mcp-call";

    const authorization: capability_mod.Authorization = switch (request.operation) {
        .call => |value| blk: {
            bridge.prompt.lockUncancelable(io);
            defer bridge.prompt.unlock(io);
            break :blk registration.capability.authorize(arena, request_id, value.tool, value.arguments_json) catch |err|
                .{ .deny = arena.print("The permission check for {s} failed: {s}", .{ value.tool, @errorName(err) }) catch "The permission check failed." };
        },
        .list, .search, .help, .resources, .templates, .read, .prompts, .prompt => .{ .allow = .{} },
    };
    bridge.mutex.lockUncancelable(io);
    const decided = step(.{ .authorized = .{ .id = work.id, .decision = if (authorization == .allow) .allow else .deny } });
    bridge.mutex.unlock(io);

    var reply: ?struct { status: wire.Status, bytes: []const u8 } = null;
    for (decided.effects()) |effect| switch (effect) {
        .call => {
            const outcome = runOperation(arena, registration.capability, request_id, request.operation, authorization.allow, &served.cancel) catch |err|
                capability_mod.CallOutcome{ .status = .failed, .bytes = arena.print("The MCP call failed: {s}", .{@errorName(err)}) catch "The MCP call failed." };
            bridge.mutex.lockUncancelable(io);
            const finished = step(.{ .call_finished = .{ .id = work.id, .outcome = switch (outcome.status) {
                .ok => .ok,
                .tool_error => .tool_error,
                .failed => .failed,
            } } });
            bridge.mutex.unlock(io);
            for (finished.effects()) |done| switch (done) {
                .reply => |value| reply = .{ .status = switch (value.outcome) {
                    .ok => .ok,
                    .tool_error => .tool_error,
                    .failed => .failed,
                    .denied => .denied,
                }, .bytes = outcome.bytes },
                else => {},
            };
        },
        .reply => reply = .{ .status = .denied, .bytes = authorization.deny },
        else => {},
    };
    const answer = reply orelse return;
    const delivered = writeReply(stream, answer.status, null, answer.bytes);
    bridge.mutex.lockUncancelable(io);
    _ = step(.{ .reply_done = .{ .id = work.id, .delivery = if (delivered) .delivered else .lost } });
    bridge.mutex.unlock(io);
}

fn runOperation(
    arena: Allocator,
    capability: capability_mod.Capability,
    request_id: []const u8,
    operation: wire.Operation,
    allowed: @FieldType(capability_mod.Authorization, "allow"),
    cancel: *std.atomic.Value(bool),
) anyerror!capability_mod.CallOutcome {
    if (operation.lookup()) |question| return capability.lookup(arena, question, cancel);
    return capability.call(arena, request_id, operation.call.tool, operation.call.arguments_json, allowed, cancel);
}

const FakeTool = struct {
    allow: bool = true,
    gate: std.atomic.Value(bool) = .init(false),
    authorizing: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),

    fn capability(self: *FakeTool) capability_mod.Capability {
        return .{ .context = @ptrCast(self), .authorize_fn = authorize, .call_fn = run, .lookup_fn = lookup };
    }

    fn lookup(raw: *anyopaque, arena: Allocator, question: capability_mod.Lookup, cancel: *std.atomic.Value(bool)) anyerror!capability_mod.CallOutcome {
        _ = .{ raw, cancel };
        return switch (question) {
            .list, .search, .help => |text| .{ .status = .ok, .bytes = try arena.print("{s} {s}\n", .{ @tagName(question), text }) },
            .resource => |value| .{ .status = .ok, .bytes = try arena.print("resource {s}\n", .{value.server}) },
        };
    }

    fn authorize(raw: *anyopaque, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8) anyerror!capability_mod.Authorization {
        _ = .{ arena, request_id, tool, arguments_json };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        self.authorizing.store(true, .release);
        while (self.gate.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
        return if (self.allow) .{ .allow = .{} } else .{ .deny = "Denied by the test." };
    }

    fn run(raw: *anyopaque, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(capability_mod.Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!capability_mod.CallOutcome {
        _ = .{ request_id, allowed, cancel };
        const self: *FakeTool = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        return .{ .status = .ok, .bytes = try arena.print("{s} {s}\n", .{ tool, arguments_json }) };
    }
};

fn waitFor(flag: *const std.atomic.Value(bool)) !void {
    var waited: u32 = 0;
    while (!flag.load(.acquire)) : (waited += 1) {
        if (waited > 1000) return error.TestTimedOut;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
}

const client = @import("mcp_call_client.zig");

test "a shell call's command reaches its MCP tool, and a forged token reaches nothing" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    defer unregister(registration);
    const variables = registration.environment();
    try std.testing.expectEqualStrings(wire.socket_env, variables[0].name);
    const socket_path = variables[0].value;
    const token = wire.parseToken(variables[1].value).?;

    const reply = try client.call(arena, std.testing.io, socket_path, token, .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{\"team\":\"ENG\"}" } });
    try std.testing.expectEqual(wire.Status.ok, reply.header.status);
    try std.testing.expectEqualStrings("mcp_linear_list_issues {\"team\":\"ENG\"}\n", reply.bytes);

    const forged = try client.call(arena, std.testing.io, socket_path, @splat(7), .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.refused, forged.header.status);
    try std.testing.expectEqual(wire.Reason.unauthorized, forged.header.reason.?);
    try std.testing.expectEqual(@as(u32, 1), tool.calls.load(.acquire));
}

test "a denied call does not run" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool: FakeTool = .{ .allow = false };
    const registration = try register(tool.capability());
    defer unregister(registration);
    const variables = registration.environment();
    const reply = try client.call(arena, std.testing.io, variables[0].value, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try std.testing.expectEqual(wire.Status.denied, reply.header.status);
    try std.testing.expectEqualStrings("Denied by the test.", reply.bytes);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a lookup answers without a permission check, and a forged token gets none" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tool: FakeTool = .{ .allow = false };
    tool.gate.store(true, .release);
    defer tool.gate.store(false, .release);
    const registration = try register(tool.capability());
    defer unregister(registration);
    const variables = registration.environment();
    const token = wire.parseToken(variables[1].value).?;
    for ([_]wire.Operation{ .{ .list = "linear" }, .{ .search = "open issues" }, .{ .help = "mcp_linear_list_issues" } }) |operation| {
        const reply = try client.call(arena, std.testing.io, variables[0].value, token, operation);
        try std.testing.expectEqual(wire.Status.ok, reply.header.status);
        try std.testing.expectEqualStrings(try arena.print("{s} {s}\n", .{ @tagName(operation), operation.subject() }), reply.bytes);
        const forged = try client.call(arena, std.testing.io, variables[0].value, @splat(7), operation);
        try std.testing.expectEqual(wire.Reason.unauthorized, forged.header.reason.?);
    }
    try std.testing.expect(!tool.authorizing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "a command that leaves while its call waits for permission runs nothing, and holds the yield meanwhile" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    tool.gate.store(true, .release);
    const registration = try register(tool.capability());
    const variables = registration.environment();
    const address = try std.Io.net.UnixAddress.init(variables[0].value);
    const stream = try address.connect(io);
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try wire.writeRequest(&writer.interface, wire.parseToken(variables[1].value).?, .{ .call = .{ .tool = "mcp_s_t", .arguments_json = "{}" } });
    try writer.interface.flush();
    try waitFor(&tool.authorizing);
    try std.testing.expectEqual(@as(u32, 1), registration.hold.load(.acquire));
    stream.close(io);

    io_mod.sleep(4 * poll_ms * std.time.ns_per_ms);
    tool.gate.store(false, .release);
    unregister(registration);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}

test "the bridge removes its socket after the last shell call" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tool: FakeTool = .{};
    const first = try register(tool.capability());
    const second = try register(tool.capability());
    const socket_path = try arena_state.allocator().dupe(u8, first.environment()[0].value);
    try std.testing.expectEqualStrings(socket_path, second.environment()[0].value);
    unregister(first);
    try std.Io.Dir.cwd().access(io, socket_path, .{});
    unregister(second);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket_path, .{}));
}

test "the bridge stops at once, and ends a silent client's connection with it" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tool: FakeTool = .{};
    const registration = try register(tool.capability());
    const address = try std.Io.net.UnixAddress.init(registration.environment()[0].value);
    const stream = try address.connect(io);
    defer stream.close(io);
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (true) {
        bridge.mutex.lockUncancelable(io);
        const open = bridge.connections;
        bridge.mutex.unlock(io);
        if (open == 1) break;
        if (io_mod.milliTimestamp() > deadline) return error.TestTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    const started = io_mod.milliTimestamp();
    unregister(registration);

    try std.testing.expect(io_mod.milliTimestamp() - started < request_deadline_ms / 2);
    try std.testing.expectEqual(@as(u32, 0), bridge.connections);
    try std.testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
}
