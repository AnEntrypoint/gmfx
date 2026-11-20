const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const session_layout = @import("../core/session/session_layout.zig");
const jsonrpc = @import("../acp/jsonrpc.zig");
const completion = @import("completion.zig");
const logging = @import("logging.zig");
const prompts = @import("prompts.zig");
const resources = @import("resources.zig");
const runs = @import("runs.zig");
const tools = @import("tools.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

const protocol_version = wire.latest_version;
const unsupported_protocol_version: i64 = -32022;
const tick_interval_ms: i32 = 100;
pub const default_runs_dir = "";
const max_message_bytes = 8 * 1024 * 1024;

const supported_versions = wire.supported_versions;

const parse_error: i64 = -32700;
const invalid_request: i64 = -32600;
const method_not_found: i64 = -32601;
const invalid_params: i64 = -32602;
const internal_error: i64 = -32603;
const resource_not_found: i64 = -32002;

const Failure = struct {
    code: i64,
    message: []const u8,
    data: ?[]const u8 = null,
};

const Outcome = union(enum) {
    result: []const u8,
    failure: Failure,
    none,
};

const Digest = resources.Digest;

const ListFlags = struct {
    resources: bool = false,
    tools: bool = false,
    prompts: bool = false,
};

const Watch = struct {
    uri: []u8,
    granted: bool,
    stamp: ?resources.Stamp,
    digest: Digest,
};

const Stream = struct {
    id: []u8,
    watches: []Watch,
    list_changed: bool,
    list_key: u64,
    list_digest: Digest,

    fn deinit(self: *Stream, alloc: Allocator) void {
        for (self.watches) |watch| alloc.free(watch.uri);
        alloc.free(self.watches);
        alloc.free(self.id);
    }
};

const Session = struct {
    alloc: Allocator,
    runs: ?std.Io.Dir,
    log_level: ?logging.Level = null,
    subscriptions: std.ArrayList([]const u8) = .empty,
    streams: std.ArrayList(Stream) = .empty,
    workspace_root: []const u8 = "",
    pending: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator, runs_root: ?std.Io.Dir) Session {
        return .{ .alloc = alloc, .runs = runs_root };
    }

    pub fn deinit(self: *Session) void {
        for (self.subscriptions.items) |uri| self.alloc.free(uri);
        self.subscriptions.deinit(self.alloc);
        for (self.streams.items) |*stream| stream.deinit(self.alloc);
        self.streams.deinit(self.alloc);
        self.pending.deinit(self.alloc);
    }

    pub fn feed(self: *Session, bytes: []const u8, w: *std.Io.Writer) !void {
        try self.pending.appendSlice(self.alloc, bytes);
        while (std.mem.findScalar(u8, self.pending.items, '\n')) |newline| {
            try self.handleLine(self.pending.items[0..newline], w);
            const rest = self.pending.items[newline + 1 ..];
            std.mem.copyForwards(u8, self.pending.items, rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
        if (self.pending.items.len > max_message_bytes) return error.MessageTooLarge;
    }

    fn handleLine(self: *Session, raw: []const u8, w: *std.Io.Writer) !void {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) return;

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch {
            return writeFailure(w, .null, .{ .code = parse_error, .message = "Parse error" });
        };
        const root = parsed.value;
        if (root != .object) {
            return writeFailure(w, .null, .{ .code = invalid_request, .message = "Invalid Request" });
        }
        const id = root.object.get("id");
        if (id) |value| switch (value) {
            .integer, .string, .null => {},
            else => return writeFailure(w, .null, .{ .code = invalid_request, .message = "Invalid Request" }),
        };
        const method_value = root.object.get("method") orelse return;
        if (method_value != .string) {
            return writeFailure(w, id orelse .null, .{ .code = invalid_request, .message = "Invalid Request" });
        }

        const outcome = self.dispatch(a, method_value.string, root.object.get("params") orelse .null, id, w) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => internalFailure(),
        };
        const request_id = id orelse return;
        switch (outcome) {
            .result => |json| try writeResult(w, request_id, json),
            .failure => |failure| try writeFailure(w, request_id, failure),
            .none => {},
        }
    }

    fn dispatch(self: *Session, a: Allocator, method: []const u8, params: std.json.Value, id: ?std.json.Value, w: *std.Io.Writer) !Outcome {
        if (std.mem.eql(u8, method, "initialize")) return .{ .result = try initializeResult(a, params) };
        if (std.mem.eql(u8, method, "notifications/initialized")) return .none;
        if (std.mem.eql(u8, method, "notifications/cancelled")) return self.cancel(a, params, w);
        if (std.mem.eql(u8, method, "ping")) return .{ .result = "{}" };
        if (requestVersion(params)) |requested| {
            if (!wire.isSupported(requested)) return unsupportedVersion(a, requested);
        }
        const modern = if (requestVersion(params)) |requested| std.mem.eql(u8, requested, wire.latest_version) else false;
        if (std.mem.eql(u8, method, "server/discover")) return .{ .result = try discoverResult(a) };
        if (std.mem.eql(u8, method, "subscriptions/listen")) return self.openListen(a, id, params, w);
        if (std.mem.eql(u8, method, "resources/list")) return .{ .result = try listResult(a, self.runs, modern) };
        if (std.mem.eql(u8, method, "resources/templates/list")) return .{ .result = try templatesResult(a, modern) };
        if (std.mem.eql(u8, method, "resources/read")) return self.readResource(a, params, modern);
        if (!modern and std.mem.eql(u8, method, "resources/subscribe")) return self.subscribe(a, params, true);
        if (!modern and std.mem.eql(u8, method, "resources/unsubscribe")) return self.subscribe(a, params, false);
        if (!modern and std.mem.eql(u8, method, "logging/setLevel")) return self.setLevel(params);
        if (std.mem.eql(u8, method, "completion/complete")) return self.complete(a, params, modern);
        if (std.mem.eql(u8, method, "tools/list")) return .{ .result = try toolsListResult(a, modern) };
        if (std.mem.eql(u8, method, "tools/call")) return self.callTool(a, params, modern);
        if (std.mem.eql(u8, method, "prompts/list")) return .{ .result = try promptsListResult(a, modern) };
        if (std.mem.eql(u8, method, "prompts/get")) return getPrompt(a, params, modern);
        return .{ .failure = .{ .code = method_not_found, .message = "Method not found" } };
    }

    fn openListen(self: *Session, a: Allocator, id: ?std.json.Value, params: std.json.Value, w: *std.Io.Writer) !Outcome {
        const request_id = id orelse return invalidParams("subscriptions/listen needs a request id");
        if (params != .object) return invalidParams("params is required");
        const filter = params.object.get("notifications") orelse return invalidParams("params.notifications is required");
        if (filter != .object) return invalidParams("params.notifications is malformed");
        if (requestVersion(params) == null) return invalidParams("params._meta protocolVersion is required");
        var requested: std.ArrayList([]const u8) = .empty;
        if (filter.object.get("resourceSubscriptions")) |listed| {
            if (listed == .array) for (listed.array.items) |value| {
                if (value != .string or !resources.exists(value.string)) continue;
                try requested.append(a, value.string);
            };
        }
        const flags = ListFlags{
            .resources = flagSet(filter, "resourcesListChanged"),
            .tools = flagSet(filter, "toolsListChanged"),
            .prompts = flagSet(filter, "promptsListChanged"),
        };
        const id_text = try jsonText(a, request_id);
        var stream = try newStream(self.alloc, a, self.runs, id_text, flags, requested.items);
        errdefer stream.deinit(self.alloc);
        var granted: std.ArrayList([]const u8) = .empty;
        for (stream.watches) |watch| {
            if (watch.granted) try granted.append(a, watch.uri);
        }
        try writeAcknowledged(w, stream.id, granted.items, flags);
        try self.streams.append(self.alloc, stream);
        return .none;
    }

    fn cancel(self: *Session, a: Allocator, params: std.json.Value, w: *std.Io.Writer) !Outcome {
        if (params != .object) return .none;
        const requested = params.object.get("requestId") orelse return .none;
        const requested_text = try jsonText(a, requested);
        for (self.streams.items, 0..) |*stream, index| {
            if (!std.mem.eql(u8, stream.id, requested_text)) continue;
            try writeListenResult(w, stream.id);
            var removed = self.streams.swapRemove(index);
            removed.deinit(self.alloc);
            break;
        }
        return .none;
    }

    fn callTool(self: *Session, a: Allocator, params: std.json.Value, modern: bool) !Outcome {
        var out: std.Io.Writer.Allocating = .init(a);
        tools.call(a, self.workspace_root, self.runs, params, &out.writer, modern) catch |err| switch (err) {
            error.InvalidParams => return invalidParams("Invalid tool call"),
            error.UnknownTool => return invalidParams("Unknown tool"),
            else => return err,
        };
        return .{ .result = out.written() };
    }

    fn readResource(self: *Session, a: Allocator, params: std.json.Value, modern: bool) !Outcome {
        const uri = stringParam(params, "uri") orelse return invalidParams("Missing uri");
        const content = resources.read(a, self.runs, uri) catch |err| switch (err) {
            error.ResourceNotFound => return resourceNotFound(a, uri),
            error.OutOfMemory => return err,
            else => return internalFailure(),
        };
        var out: std.Io.Writer.Allocating = .init(a);
        try resources.writeContents(&out.writer, content, modern);
        return .{ .result = out.written() };
    }

    fn subscribe(self: *Session, a: Allocator, params: std.json.Value, add: bool) !Outcome {
        const uri = stringParam(params, "uri") orelse return invalidParams("Missing uri");
        if (!resources.exists(uri)) return resourceNotFound(a, uri);
        const index = indexOfSubscription(self.subscriptions.items, uri);
        if (add and index == null) {
            try self.subscriptions.append(self.alloc, try self.alloc.dupe(u8, uri));
        } else if (!add) {
            if (index) |found| {
                self.alloc.free(self.subscriptions.swapRemove(found));
            }
        }
        return .{ .result = "{}" };
    }

    fn setLevel(self: *Session, params: std.json.Value) !Outcome {
        const name = stringParam(params, "level") orelse return invalidParams("Missing level");
        self.log_level = logging.parse(name) orelse return invalidParams("Unknown log level");
        return .{ .result = "{}" };
    }

    fn complete(self: *Session, a: Allocator, params: std.json.Value, modern: bool) !Outcome {
        var out: std.Io.Writer.Allocating = .init(a);
        completion.write(a, self.runs, params, &out.writer, modern) catch |err| switch (err) {
            error.InvalidParams => return invalidParams("Invalid completion request"),
            error.OutOfMemory => return err,
            else => return internalFailure(),
        };
        return .{ .result = out.written() };
    }

    pub fn tick(self: *Session, w: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        for (self.streams.items) |*stream| {
            for (stream.watches) |*watch| try tickWatch(self.runs, a, stream.id, watch, w);
            if (stream.list_changed) try tickList(self.runs, a, stream, w);
        }
    }

    pub fn finish(self: *Session, w: *std.Io.Writer) !void {
        for (self.streams.items) |*stream| {
            try writeListenResult(w, stream.id);
            stream.deinit(self.alloc);
        }
        self.streams.clearRetainingCapacity();
    }
};

fn initializeResult(a: Allocator, params: std.json.Value) ![]const u8 {
    const requested = stringParam(params, "protocolVersion");
    const negotiated = if (requested) |version| blk: {
        for (supported_versions) |supported| {
            if (std.mem.eql(u8, supported, version)) break :blk supported;
        }
        break :blk protocol_version;
    } else protocol_version;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("{\"protocolVersion\":");
    try jsonrpc.writeJsonStr(negotiated, &out.writer);
    try out.writer.writeAll(",\"capabilities\":{\"logging\":{},\"completions\":{},\"resources\":{\"subscribe\":true,\"listChanged\":false}},\"serverInfo\":{\"name\":\"fx\",\"version\":");
    try jsonrpc.writeJsonStr(build_options.app_version, &out.writer);
    try out.writer.writeAll("}}");
    return out.written();
}

fn toolsListResult(a: Allocator, modern: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try tools.writeList(a, &out.writer, modern);
    return out.written();
}

fn promptsListResult(a: Allocator, modern: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try prompts.writeList(&out.writer, modern);
    return out.written();
}

fn getPrompt(a: Allocator, params: std.json.Value, modern: bool) !Outcome {
    const name = stringParam(params, "name") orelse return invalidParams("Missing name");
    var out: std.Io.Writer.Allocating = .init(a);
    prompts.get(&out.writer, name, modern) catch |err| switch (err) {
        error.PromptNotFound => return invalidParams("Unknown prompt"),
        else => return err,
    };
    return .{ .result = out.written() };
}

fn listResult(a: Allocator, root: ?std.Io.Dir, modern: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try resources.writeList(a, root, &out.writer, modern);
    return out.written();
}

fn templatesResult(a: Allocator, modern: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try resources.writeTemplates(&out.writer, modern);
    return out.written();
}

fn discoverResult(a: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeByte('{');
    try wire.writeCacheable(&out.writer, true);
    try out.writer.writeAll("\"supportedVersions\":[");
    for (supported_versions, 0..) |version, index| {
        if (index > 0) try out.writer.writeByte(',');
        try jsonrpc.writeJsonStr(version, &out.writer);
    }
    try out.writer.writeAll("],\"capabilities\":{\"completions\":{},\"prompts\":{\"listChanged\":false},\"resources\":{\"listChanged\":false},\"tools\":{\"listChanged\":false}}}");
    return out.written();
}

fn requestVersion(params: std.json.Value) ?[]const u8 {
    if (params != .object) return null;
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const version = meta.object.get("io.modelcontextprotocol/protocolVersion") orelse return null;
    return if (version == .string) version.string else null;
}

fn unsupportedVersion(a: Allocator, requested: []const u8) !Outcome {
    var data: std.Io.Writer.Allocating = .init(a);
    try data.writer.writeAll("{\"requested\":");
    try jsonrpc.writeJsonStr(requested, &data.writer);
    try data.writer.writeAll(",\"supported\":[");
    for (supported_versions, 0..) |version, index| {
        if (index > 0) try data.writer.writeByte(',');
        try jsonrpc.writeJsonStr(version, &data.writer);
    }
    try data.writer.writeAll("]}");
    return .{ .failure = .{ .code = unsupported_protocol_version, .message = "Unsupported protocol version", .data = data.written() } };
}

fn jsonText(a: Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn digestOf(alloc: Allocator, root: ?std.Io.Dir, uri: []const u8) ?Digest {
    const content = resources.read(alloc, root, uri) catch return null;
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(content.text, &digest, .{});
    return digest;
}

fn newStream(
    alloc: Allocator,
    a: Allocator,
    root: ?std.Io.Dir,
    id: []const u8,
    flags: ListFlags,
    uris: []const []const u8,
) !Stream {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const watches = try alloc.alloc(Watch, uris.len);
    var built: usize = 0;
    errdefer {
        for (watches[0..built]) |watch| alloc.free(watch.uri);
        alloc.free(watches);
    }
    for (uris) |uri| {
        watches[built] = .{ .uri = try alloc.dupe(u8, uri), .granted = false, .stamp = null, .digest = undefined };
        built += 1;
    }
    for (watches) |*watch| {
        const current = resources.stamp(root, watch.uri) orelse continue;
        const digest = digestOf(a, root, watch.uri) orelse continue;
        watch.* = .{ .uri = watch.uri, .granted = true, .stamp = current, .digest = digest };
    }
    var list_key: u64 = 0;
    var list_digest: Digest = undefined;
    if (flags.resources) {
        list_key = try resources.listKey(root);
        list_digest = try resources.listDigest(a, root);
    }
    return .{
        .id = owned_id,
        .watches = watches,
        .list_changed = flags.resources,
        .list_key = list_key,
        .list_digest = list_digest,
    };
}

fn writeAcknowledged(w: *std.Io.Writer, id: []const u8, uris: []const []const u8, flags: ListFlags) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":");
    try w.writeAll(id);
    try w.writeAll("},\"notifications\":{");
    if (flags.resources) try w.writeAll("\"resourcesListChanged\":true,");
    if (flags.tools) try w.writeAll("\"toolsListChanged\":true,");
    if (flags.prompts) try w.writeAll("\"promptsListChanged\":true,");
    try w.writeAll("\"resourceSubscriptions\":[");
    for (uris, 0..) |uri, index| {
        if (index > 0) try w.writeByte(',');
        try jsonrpc.writeJsonStr(uri, w);
    }
    try w.writeAll("]}}}\n");
}

fn writeListChanged(w: *std.Io.Writer, id: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":");
    try w.writeAll(id);
    try w.writeAll("}}}\n");
}

fn tickWatch(root: ?std.Io.Dir, a: Allocator, id: []const u8, watch: *Watch, w: *std.Io.Writer) !void {
    const current = resources.stamp(root, watch.uri) orelse return;
    if (watch.stamp) |known| {
        if (std.meta.eql(known, current)) return;
    }
    const digest = digestOf(a, root, watch.uri) orelse return;
    watch.stamp = current;
    if (watch.granted and std.mem.eql(u8, &digest, &watch.digest)) return;
    if (!watch.granted) {
        watch.granted = true;
        try writeAcknowledged(w, id, &.{watch.uri}, .{});
    }
    watch.digest = digest;
    try writeUpdated(w, id, watch.uri);
}

fn tickList(root: ?std.Io.Dir, a: Allocator, stream: *Stream, w: *std.Io.Writer) !void {
    const key = try resources.listKey(root);
    if (key == stream.list_key) return;
    stream.list_key = key;
    const digest = try resources.listDigest(a, root);
    if (std.mem.eql(u8, &digest, &stream.list_digest)) return;
    stream.list_digest = digest;
    try writeListChanged(w, stream.id);
}

fn flagSet(filter: std.json.Value, name: []const u8) bool {
    const value = filter.object.get(name) orelse return false;
    return switch (value) {
        .bool => |on| on,
        else => false,
    };
}

fn writeListenResult(w: *std.Io.Writer, id: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.writeAll(id);
    try w.writeAll(",\"result\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":");
    try w.writeAll(id);
    try w.writeAll("},\"resultType\":\"complete\"}}\n");
}

fn writeUpdated(w: *std.Io.Writer, id: []const u8, uri: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":");
    try w.writeAll(id);
    try w.writeAll("},\"uri\":");
    try jsonrpc.writeJsonStr(uri, w);
    try w.writeAll("}}\n");
}

fn stringParam(params: std.json.Value, name: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const value = params.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn indexOfSubscription(items: []const []const u8, uri: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, uri)) return index;
    }
    return null;
}

fn invalidParams(message: []const u8) Outcome {
    return .{ .failure = .{ .code = invalid_params, .message = message } };
}

fn internalFailure() Outcome {
    return .{ .failure = .{ .code = internal_error, .message = "Internal error" } };
}

fn resourceNotFound(a: Allocator, uri: []const u8) !Outcome {
    var data: std.Io.Writer.Allocating = .init(a);
    try data.writer.writeAll("{\"uri\":");
    try jsonrpc.writeJsonStr(uri, &data.writer);
    try data.writer.writeByte('}');
    return .{ .failure = .{ .code = resource_not_found, .message = "Resource not found", .data = data.written() } };
}

fn writeResult(w: *std.Io.Writer, id: std.json.Value, json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"result\":");
    try w.writeAll(json);
    try w.writeAll("}\n");
}

fn writeFailure(w: *std.Io.Writer, id: std.json.Value, failure: Failure) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{failure.code});
    try jsonrpc.writeJsonStr(failure.message, w);
    if (failure.data) |data| {
        try w.writeAll(",\"data\":");
        try w.writeAll(data);
    }
    try w.writeAll("}}\n");
}

fn sessionStorePath(alloc: Allocator, requested: []const u8) !?[]u8 {
    if (requested.len > 0) return try alloc.dupe(u8, requested);
    const home = io_mod.homeDir() orelse return null;
    const sessions = try profile_paths.sessionsDir(alloc, home);
    defer alloc.free(sessions);
    return try std.Io.Dir.path.join(alloc, &.{ sessions, session_layout.sessions_v2_dir });
}

pub fn run(alloc: Allocator, runs_dir: []const u8) !void {
    const store_path = try sessionStorePath(alloc, runs_dir);
    defer if (store_path) |path| alloc.free(path);
    var runs_root = if (store_path) |path| runs.openRoot(path) else null;
    defer if (runs_root) |*dir| dir.close(io_mod.getIo());
    var session = Session.init(alloc, runs_root);
    defer session.deinit();
    const workspace = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace);
    session.workspace_root = workspace;

    var chunk: [64 * 1024]u8 = undefined;
    var open = true;
    while (open) {
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const timeout: i32 = if (session.streams.items.len > 0) tick_interval_ms else -1;
        const ready = std.posix.poll(&fds, timeout) catch break;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (ready > 0) {
            const count = std.posix.read(std.posix.STDIN_FILENO, &chunk) catch 0;
            if (count == 0) {
                try session.finish(&out.writer);
                open = false;
            } else {
                try session.feed(chunk[0..count], &out.writer);
            }
        }
        try session.tick(&out.writer);
        if (out.written().len > 0) {
            try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), out.written());
        }
    }
}

fn fixtureSessions(tmp: *std.testing.TmpDir) !void {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "sess-a");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sess-a/log.jsonl",
        .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n{\"seq\":2,\"kind\":\"item\",\"turn\":1,\"type\":\"assistant\",\"data\":{\"text\":\"evidence text\"}}\n",
    });
    try tmp.dir.createDirPath(io, "sess-b");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sess-b/log.jsonl",
        .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n",
    });
}

fn exchange(session: *Session, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session.feed(input, &out.writer);
    return try std.testing.allocator.dupe(u8, out.written());
}

test "initialize negotiates a supported protocol version and declares the server surface" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}\n");
    defer std.testing.allocator.free(got);
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"logging\":{},\"completions\":{},\"resources\":{\"subscribe\":true,\"listChanged\":false}},\"serverInfo\":{\"name\":\"fx\",\"version\":\"" ++ build_options.app_version ++ "\"}}}\n";
    try std.testing.expectEqualStrings(expected, got);
}

test "initialize answers the latest protocol version for an unknown request" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{\"protocolVersion\":\"2026-07-28\","));
}

test "ping returns an empty result" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n", got);
}

test "tools/list names the read-only tools with their input schemas" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/list\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":15,\"result\":{\"tools\":[{\"name\":\"read_file\","));
    try std.testing.expect(std.mem.indexOf(u8, got, ",{\"name\":\"glob_files\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, ",{\"name\":\"grep_files\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":\"write_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":\"edit_file\"") == null);
}

test "prompts/list names the working loop and the system prompt" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"prompts/list\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"result\":{\"prompts\":[{\"name\":\"fx-working-loop\",\"description\":\"The fx working loop: the default habits for planning, batching, waiting, verifying and reporting.\",\"arguments\":[]},{\"name\":\"fx-system\",\"description\":\"The default fx system prompt, with the working loop as its last section.\",\"arguments\":[]}]}}\n",
        got,
    );
}

test "prompts/get returns the working loop as a user message" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"prompts/get\",\"params\":{\"name\":\"fx-working-loop\"}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{\"description\":\"The fx working loop: the default habits"));
    try std.testing.expect(std.mem.indexOf(u8, got, "\"text\":\"# Working loop\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, ",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\"}}]}}\n"));
}

test "prompts/get refuses an unknown prompt with invalid params" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"prompts/get\",\"params\":{\"name\":\"nope\"}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":18,\"error\":{\"code\":-32602,\"message\":\"Unknown prompt\"}}\n", got);
}

test "tools/call runs a read-only tool inside the workspace" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello from fx\n" });
    const workspace = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(workspace);
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    session.workspace_root = workspace;
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"note.txt\"}}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":19,\"result\":{\"content\":[{\"type\":\"text\",\"text\":"));
    try std.testing.expect(std.mem.indexOf(u8, got, "hello from fx") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\"isError\":false}}\n"));
}

test "tools/call refuses a tool that is not exposed over MCP" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"write_file\",\"arguments\":{}}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":20,\"error\":{\"code\":-32602,\"message\":\"Unknown tool\"}}\n", got);
}

test "subscriptions/listen needs a protocol version and a request id" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const no_version = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{}}}\n");
    defer std.testing.allocator.free(no_version);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":21,\"error\":{\"code\":-32602,\"message\":\"params._meta protocolVersion is required\"}}\n", no_version);
}

test "subscriptions/listen requires a notifications filter" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"subscriptions/listen\",\"params\":{}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":22,\"error\":{\"code\":-32602,\"message\":\"params.notifications is required\"}}\n", got);
}

test "completion names a served prompt for a name argument" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"fx-system\"},\"argument\":{\"name\":\"name\",\"value\":\"fx-w\"}}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":23,\"result\":{\"completion\":{\"values\":[\"fx-working-loop\"],\"total\":1,\"hasMore\":false}}}\n", got);
}

test "notifications get no response" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"unknown/thing\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "a message split across reads is answered once it is complete" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const first = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"pi");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("", first);
    const second = try exchange(&session, "ng\"}\n");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n", second);
}

test "resources/list names the served texts and the sessions that have logs" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resources\":[" ++
            "{\"uri\":\"skill://fx/WORKING-LOOP.md\",\"name\":\"fx/WORKING-LOOP.md\",\"mimeType\":\"text/markdown\"}," ++
            "{\"uri\":\"skill://fx/SYSTEM.md\",\"name\":\"fx/SYSTEM.md\",\"mimeType\":\"text/markdown\"}," ++
            "{\"uri\":\"fx://session/sess-a/log\",\"name\":\"sess-a log\",\"mimeType\":\"application/x-ndjson\"}," ++
            "{\"uri\":\"fx://session/sess-a/witness\",\"name\":\"sess-a witness\",\"mimeType\":\"text/plain\"}," ++
            "{\"uri\":\"fx://session/sess-b/log\",\"name\":\"sess-b log\",\"mimeType\":\"application/x-ndjson\"}" ++
            "]}}\n",
        got,
    );
}

test "resources/templates/list names the skill and session templates" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/templates/list\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"resourceTemplates\":[" ++
            "{\"uriTemplate\":\"skill://{skill}/{file}\",\"name\":\"skill file\",\"mimeType\":\"text/markdown\"}," ++
            "{\"uriTemplate\":\"fx://session/{session}/log\",\"name\":\"session log\",\"mimeType\":\"application/x-ndjson\"}," ++
            "{\"uriTemplate\":\"fx://session/{session}/witness\",\"name\":\"session witness\",\"mimeType\":\"text/plain\"}" ++
            "]}}\n",
        got,
    );
}

test "resources/read returns the working loop text" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"skill://fx/WORKING-LOOP.md\"}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"contents\":[{\"uri\":\"skill://fx/WORKING-LOOP.md\",\"mimeType\":\"text/markdown\",\"text\":\""));
    try std.testing.expect(std.mem.endsWith(u8, got, "\"}]}}\n"));
}

test "resources/read returns a session witness and log" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const witness = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/read\",\"params\":{\"uri\":\"fx://session/sess-a/witness\"}}\n");
    defer std.testing.allocator.free(witness);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"contents\":[{\"uri\":\"fx://session/sess-a/witness\",\"mimeType\":\"text/plain\",\"text\":\"evidence text\"}]}}\n",
        witness,
    );
    const log = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/read\",\"params\":{\"uri\":\"fx://session/sess-b/log\"}}\n");
    defer std.testing.allocator.free(log);
    try std.testing.expect(std.mem.startsWith(u8, log, "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"contents\":[{\"uri\":\"fx://session/sess-b/log\",\"mimeType\":\"application/x-ndjson\",\"text\":\"{\\\"seq\\\":1,\\\"kind\\\":\\\"turn_started\\\",\\\"turn\\\":1}\\n\"}]}}\n"));
}

test "resources/read reports an unknown or unserved resource as not found" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const unserved = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"resources/read\",\"params\":{\"uri\":\"skill://fx/NOT-SERVED.md\"}}\n");
    defer std.testing.allocator.free(unserved);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32002,\"message\":\"Resource not found\",\"data\":{\"uri\":\"skill://fx/NOT-SERVED.md\"}}}\n",
        unserved,
    );
    const no_witness = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/read\",\"params\":{\"uri\":\"fx://session/sess-b/witness\"}}\n");
    defer std.testing.allocator.free(no_witness);
    try std.testing.expect(std.mem.indexOf(u8, no_witness, "\"code\":-32002") != null);
    const traversal = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"resources/read\",\"params\":{\"uri\":\"fx://session/../log\"}}\n");
    defer std.testing.allocator.free(traversal);
    try std.testing.expect(std.mem.indexOf(u8, traversal, "\"code\":-32002") != null);
    const missing_uri = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"resources/read\",\"params\":{}}\n");
    defer std.testing.allocator.free(missing_uri);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"error\":{\"code\":-32602,\"message\":\"Missing uri\"}}\n",
        missing_uri,
    );
}

test "resources/subscribe and unsubscribe track a served resource" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const subscribed = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"skill://fx/WORKING-LOOP.md\"}}\n");
    defer std.testing.allocator.free(subscribed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":13,\"result\":{}}\n", subscribed);
    try std.testing.expectEqual(@as(usize, 1), session.subscriptions.items.len);
    const again = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"skill://fx/WORKING-LOOP.md\"}}\n");
    defer std.testing.allocator.free(again);
    try std.testing.expectEqual(@as(usize, 1), session.subscriptions.items.len);
    const unsubscribed = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"skill://fx/WORKING-LOOP.md\"}}\n");
    defer std.testing.allocator.free(unsubscribed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":15,\"result\":{}}\n", unsubscribed);
    try std.testing.expectEqual(@as(usize, 0), session.subscriptions.items.len);
    const unknown = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"skill://fx/NOT-SERVED.md\"}}\n");
    defer std.testing.allocator.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "\"code\":-32002") != null);
    try std.testing.expectEqual(@as(usize, 0), session.subscriptions.items.len);
}

test "logging/setLevel stores a valid level and rejects others" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const set = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"warning\"}}\n");
    defer std.testing.allocator.free(set);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{}}\n", set);
    try std.testing.expectEqual(logging.Level.warning, session.log_level.?);
    const bad = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"loud\"}}\n");
    defer std.testing.allocator.free(bad);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":18,\"error\":{\"code\":-32602,\"message\":\"Unknown log level\"}}\n", bad);
    try std.testing.expectEqual(logging.Level.warning, session.log_level.?);
}

test "completion/complete suggests skill names, file names and session ids by prefix" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const skill = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"skill://{skill}/{file}\"},\"argument\":{\"name\":\"skill\",\"value\":\"\"}}}\n");
    defer std.testing.allocator.free(skill);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":19,\"result\":{\"completion\":{\"values\":[\"fx\"],\"total\":1,\"hasMore\":false}}}\n", skill);
    const run_case = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"fx://session/{session}/log\"},\"argument\":{\"name\":\"session\",\"value\":\"sess-\"}}}\n");
    defer std.testing.allocator.free(run_case);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":20,\"result\":{\"completion\":{\"values\":[\"sess-a\",\"sess-b\"],\"total\":2,\"hasMore\":false}}}\n", run_case);
    const file = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"skill://{skill}/{file}\"},\"argument\":{\"name\":\"file\",\"value\":\"W\"}}}\n");
    defer std.testing.allocator.free(file);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":21,\"result\":{\"completion\":{\"values\":[\"WORKING-LOOP.md\"],\"total\":1,\"hasMore\":false}}}\n", file);
    const bad_ref = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/tool\"},\"argument\":{\"name\":\"skill\",\"value\":\"\"}}}\n");
    defer std.testing.allocator.free(bad_ref);
    try std.testing.expect(std.mem.indexOf(u8, bad_ref, "\"code\":-32602") != null);
}

test "unknown methods and malformed JSON get JSON-RPC errors" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const unknown = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"no/such\"}\n");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":23,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n", unknown);
    const malformed = try exchange(&session, "{not json\n");
    defer std.testing.allocator.free(malformed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n", malformed);
}

test "server/discover advertises 2026-07-28 first with the capabilities it serves" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"server/discover\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":30,\"result\":{\"resultType\":\"complete\",\"cacheScope\":\"public\",\"ttlMs\":0,\"_meta\":{"));
    try std.testing.expect(std.mem.indexOf(u8, got, "\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"capabilities\":{\"completions\":{}") != null);
}

test "server/discover on 2026-07-28 does not advertise resources.subscribe it refuses" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"server/discover\"}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"resources\":{\"listChanged\":false},\"tools\":{\"listChanged\":false}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"subscribe\"") == null);
    const refused = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"resources/subscribe\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"uri\":\"skill://fx/WORKING-LOOP.md\"}}\n");
    defer std.testing.allocator.free(refused);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":34,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n", refused);
}

test "a request naming an unsupported protocol version is refused with the supported list" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1999-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":31,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":\"1999-01-01\",\"supported\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\"]}}}\n", got);
}

test "tools/list answers the 2026-07-28 shape when the request names that version" {
    var session = Session.init(std.testing.allocator, null);
    defer session.deinit();
    const got = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"jsonrpc\":\"2.0\",\"id\":32,\"result\":{\"resultType\":\"complete\",\"cacheScope\":\"public\",\"ttlMs\":0,\"_meta\":{"));
    try std.testing.expect(std.mem.indexOf(u8, got, "\"tools\":[{\"name\":\"read_file\",") != null);
}

test "subscriptions/listen opens a stream, delivers one update, and ends with a response on cancel" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const ack = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"subscriptions/listen\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"notifications\":{\"resourceSubscriptions\":[\"fx://session/sess-a/log\"]}}}\n");
    defer std.testing.allocator.free(ack);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":40},\"notifications\":{\"resourceSubscriptions\":[\"fx://session/sess-a/log\"]}}}\n", ack);
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-a/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n{\"seq\":3,\"kind\":\"turn_committed\",\"turn\":1}\n" });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session.tick(&out.writer);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":40},\"uri\":\"fx://session/sess-a/log\"}}\n", out.written());
    var quiet: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer quiet.deinit();
    try session.tick(&quiet.writer);
    try std.testing.expectEqualStrings("", quiet.written());
    const ended = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":40}}\n");
    defer std.testing.allocator.free(ended);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":40,\"result\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":40},\"resultType\":\"complete\"}}\n", ended);
    try std.testing.expectEqual(@as(usize, 0), session.streams.items.len);
}

test "subscriptions/listen grants a URI that did not exist at listen time once it appears" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const ack = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"subscriptions/listen\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"notifications\":{\"resourceSubscriptions\":[\"fx://session/sess-late/log\"]}}}\n");
    defer std.testing.allocator.free(ack);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":41},\"notifications\":{\"resourceSubscriptions\":[]}}}\n", ack);
    var quiet: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer quiet.deinit();
    try session.tick(&quiet.writer);
    try std.testing.expectEqualStrings("", quiet.written());
    try tmp.dir.createDirPath(io, "sess-late");
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-late/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n" });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session.tick(&out.writer);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":41},\"notifications\":{\"resourceSubscriptions\":[\"fx://session/sess-late/log\"]}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":41},\"uri\":\"fx://session/sess-late/log\"}}\n",
        out.written(),
    );
}

test "subscriptions/listen sends resources/list_changed when the session list changes and not when a log only grows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixtureSessions(&tmp);
    var session = Session.init(std.testing.allocator, tmp.dir);
    defer session.deinit();
    const ack = try exchange(&session, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"subscriptions/listen\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"notifications\":{\"resourcesListChanged\":true,\"toolsListChanged\":true,\"resourceSubscriptions\":[]}}}\n");
    defer std.testing.allocator.free(ack);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":42},\"notifications\":{\"resourcesListChanged\":true,\"toolsListChanged\":true,\"resourceSubscriptions\":[]}}}\n", ack);
    var quiet: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer quiet.deinit();
    try session.tick(&quiet.writer);
    try std.testing.expectEqualStrings("", quiet.written());
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-b/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n{\"seq\":2,\"kind\":\"turn_committed\",\"turn\":1}\n" });
    var grown: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer grown.deinit();
    try session.tick(&grown.writer);
    try std.testing.expectEqualStrings("", grown.written());
    try tmp.dir.createDirPath(io, "sess-new");
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-new/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n" });
    var added: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer added.deinit();
    try session.tick(&added.writer);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":42}}}\n", added.written());
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-b/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n{\"seq\":2,\"kind\":\"item\",\"turn\":1,\"type\":\"assistant\",\"data\":{\"text\":\"done\"}}\n" });
    var witnessed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer witnessed.deinit();
    try session.tick(&witnessed.writer);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":42}}}\n", witnessed.written());
}
