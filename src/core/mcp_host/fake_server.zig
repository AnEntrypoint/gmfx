const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Options = @import("runtime.zig").Options;
const testing = std.testing;

pub const script =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
    \\    *'"method":"tools/call"'*slow*) ;;
    \\    *'"method":"tools/call"'*withdraw*)
    \\      call=$id
    \\      printf '{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":{"mode":"form","message":"Q1","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"e1"}}\n'
    \\      printf '{"jsonrpc":"2.0","id":"e2","method":"elicitation/create","params":{"mode":"form","message":"Q2","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}\n' ;;
    \\    *'"method":"tools/call"'*confirm*)
    \\      call=$id
    \\      printf '{"jsonrpc":"2.0","id":"c1","method":"elicitation/create","params":{"mode":"form","message":"Confirm?","requestedSchema":{"type":"object","properties":{"ok":{"type":"boolean"}}}}}\n' ;;
    \\    *'"id":"c1"'*)
    \\      action=$(printf '%s' "$line" | sed -n 's/.*"action":"\([a-z]*\)".*/\1/p')
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"c1=%s"}]}}\n' "$call" "$action" ;;
    \\    *'"id":"e1"'*) got="${got}e1 " ;;
    \\    *'"id":"e2"'*)
    \\      name=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%se2=%s"}]}}\n' "$call" "$got" "$name" ;;
    \\    *'"method":"tools/call"'*pid*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"pid=%s"}]}}\n' "$id" "$$" ;;
    \\    *'"method":"tools/call"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"hi"}]}}\n' "$id" ;;
    \\  esac
    \\done
    \\if [ "$1" = linger ]; then sleep 1; fi
    \\
;

pub const Fixture = struct {
    tmp: testing.TmpDir,
    home: []u8,
    server: []u8,
    inherited: std.process.Environ.Map,

    pub fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = script, .flags = .{ .permissions = .executable_file } });
        f.home = try io_mod.dirRealpathAlloc(testing.allocator, f.tmp.dir, ".");
        errdefer testing.allocator.free(f.home);
        f.server = try std.Io.Dir.path.join(testing.allocator, &.{ f.home, "server" });
        f.inherited = .init(testing.allocator);
    }

    pub fn deinit(f: *Fixture) void {
        f.inherited.deinit();
        testing.allocator.free(f.server);
        testing.allocator.free(f.home);
        f.tmp.cleanup();
    }

    pub fn options(f: *const Fixture) Options {
        return .{ .client_version = "test", .credentials = .{ .store = .{ .home = f.home, .backend = .file } } };
    }
};

pub const HttpFixture = struct {
    fixture: Fixture,
    server: std.Io.net.Server,
    url: []u8,
    token_path: []u8,
    thread: std.Thread,
    stop: std.atomic.Value(bool),
    unauthorized: std.atomic.Value(u32),
    authorized: std.atomic.Value(u32),

    pub fn init(h: *HttpFixture) !void {
        try h.fixture.init();
        errdefer h.fixture.deinit();
        try h.fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "token", .data = "old" });
        h.token_path = try std.Io.Dir.path.join(testing.allocator, &.{ h.fixture.home, "token" });
        errdefer testing.allocator.free(h.token_path);
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        h.server = try address.listen(testing.io, .{});
        errdefer h.server.deinit(testing.io);
        h.url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/mcp", .{h.server.socket.address.getPort()});
        errdefer testing.allocator.free(h.url);
        h.stop = .init(false);
        h.unauthorized = .init(0);
        h.authorized = .init(0);
        h.thread = try std.Thread.spawn(.{}, serve, .{h});
    }

    pub fn deinit(h: *HttpFixture) void {
        h.stop.store(true, .release);
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", h.server.socket.address.getPort()) catch unreachable;
        if (address.connect(testing.io, .{ .mode = .stream })) |stream| stream.close(testing.io) else |_| {}
        h.thread.join();
        h.server.deinit(testing.io);
        testing.allocator.free(h.url);
        testing.allocator.free(h.token_path);
        h.fixture.deinit();
    }

    fn serve(h: *HttpFixture) void {
        while (!h.stop.load(.acquire)) {
            var stream = h.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (h.stop.load(.acquire)) return;
            h.answer(&stream) catch {};
        }
    }

    fn answer(h: *HttpFixture, stream: *std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(testing.io, &read_buffer);
        var head_buffer: [4096]u8 = undefined;
        var head_len: usize = 0;
        while (!std.mem.endsWith(u8, head_buffer[0..head_len], "\r\n\r\n")) {
            if (head_len == head_buffer.len) return error.RequestHeadTooLong;
            head_buffer[head_len] = try reader.interface.takeByte();
            head_len += 1;
        }
        const head = head_buffer[0..head_len];
        const length = try std.fmt.parseInt(usize, headerValue(head, "content-length") orelse "0", 10);
        const body = try testing.allocator.alloc(u8, length);
        defer testing.allocator.free(body);
        for (body) |*byte| byte.* = try reader.interface.takeByte();

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(testing.io, &write_buffer);
        const out = &writer.interface;
        if (std.mem.startsWith(u8, head, "GET ")) return respond(out, "405 Method Not Allowed", "");
        const authorization = headerValue(head, "authorization") orelse "";
        if (!std.mem.eql(u8, authorization, "Bearer new")) {
            if (h.unauthorized.fetchAdd(1, .acq_rel) == 0) try h.fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "token", .data = "new" });
            return respond(out, "401 Unauthorized", "");
        }
        _ = h.authorized.fetchAdd(1, .acq_rel);
        if (std.mem.indexOf(u8, body, "\"id\":") == null) return respond(out, "202 Accepted", "");
        const id = requestId(body);
        if (std.mem.indexOf(u8, body, "\"method\":\"initialize\"") != null) {
            const reply = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"fake\",\"version\":\"1\"}}}}}}", .{id});
            defer testing.allocator.free(reply);
            return respond(out, "200 OK", reply);
        }
        if (std.mem.indexOf(u8, body, "\"method\":\"tools/list\"") != null) {
            const reply = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[{{\"name\":\"echo\",\"description\":\"Echoes\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{id});
            defer testing.allocator.free(reply);
            return respond(out, "200 OK", reply);
        }
        const refusal = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id});
        defer testing.allocator.free(refusal);
        return respond(out, "200 OK", refusal);
    }
};

pub const SseFixture = struct {
    fixture: Fixture,
    server: std.Io.net.Server,
    url: []u8,
    thread: std.Thread,
    stream_thread: ?std.Thread,
    stop: std.atomic.Value(bool),
    sink: std.atomic.Value(usize),
    refused: std.atomic.Value(u32),
    streams: std.atomic.Value(u32),

    pub fn init(h: *SseFixture) !void {
        try h.fixture.init();
        errdefer h.fixture.deinit();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        h.server = try address.listen(testing.io, .{});
        errdefer h.server.deinit(testing.io);
        h.url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/mcp", .{h.server.socket.address.getPort()});
        errdefer testing.allocator.free(h.url);
        h.stream_thread = null;
        h.stop = .init(false);
        h.sink = .init(0);
        h.refused = .init(0);
        h.streams = .init(0);
        h.thread = try std.Thread.spawn(.{}, serve, .{h});
    }

    pub fn deinit(h: *SseFixture) void {
        h.stop.store(true, .release);
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", h.server.socket.address.getPort()) catch unreachable;
        if (address.connect(testing.io, .{ .mode = .stream })) |stream| stream.close(testing.io) else |_| {}
        h.thread.join();
        if (h.stream_thread) |thread| thread.join();
        h.server.deinit(testing.io);
        testing.allocator.free(h.url);
        h.fixture.deinit();
    }

    fn serve(h: *SseFixture) void {
        while (!h.stop.load(.acquire)) {
            var stream = h.server.accept(testing.io) catch return;
            if (h.stop.load(.acquire)) return stream.close(testing.io);
            const handed_off = h.handle(&stream) catch false;
            if (!handed_off) stream.close(testing.io);
        }
    }

    fn handle(h: *SseFixture, stream: *std.Io.net.Stream) !bool {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(testing.io, &read_buffer);
        var head_buffer: [4096]u8 = undefined;
        var head_len: usize = 0;
        while (!std.mem.endsWith(u8, head_buffer[0..head_len], "\r\n\r\n")) {
            if (head_len == head_buffer.len) return error.RequestHeadTooLong;
            head_buffer[head_len] = try reader.interface.takeByte();
            head_len += 1;
        }
        const head = head_buffer[0..head_len];
        if (std.mem.startsWith(u8, head, "GET ")) {
            if (h.stream_thread != null) return false;
            h.stream_thread = try std.Thread.spawn(.{}, streamLoop, .{ h, stream.* });
            _ = h.streams.fetchAdd(1, .acq_rel);
            return true;
        }
        const length = try std.fmt.parseInt(usize, headerValue(head, "content-length") orelse "0", 10);
        const body = try testing.allocator.alloc(u8, length);
        defer testing.allocator.free(body);
        for (body) |*byte| byte.* = try reader.interface.takeByte();

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(testing.io, &write_buffer);
        const out = &writer.interface;
        if (std.mem.startsWith(u8, head, "POST /messages ")) {
            try respondText(out, "202 Accepted", "");
            try h.reply(body);
        } else {
            _ = h.refused.fetchAdd(1, .acq_rel);
            try respondText(out, "404 Not Found", "Not Found");
        }
        return false;
    }

    fn streamLoop(h: *SseFixture, stream: std.Io.net.Stream) void {
        var own = stream;
        defer own.close(testing.io);
        var write_buffer: [1024]u8 = undefined;
        var writer = own.writer(testing.io, &write_buffer);
        const out = &writer.interface;
        out.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\nevent: endpoint\ndata: /messages\n\n") catch return;
        out.flush() catch return;
        h.sink.store(@intFromPtr(out), .release);
        while (!h.stop.load(.acquire)) std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch return;
        h.sink.store(0, .release);
    }

    fn reply(h: *SseFixture, body: []const u8) !void {
        if (std.mem.indexOf(u8, body, "\"id\":") == null) return;
        const sink = h.sink.load(.acquire);
        if (sink == 0) return error.NoStream;
        const out: *std.Io.Writer = @ptrFromInt(sink);
        const id = requestId(body);
        const message = if (std.mem.indexOf(u8, body, "\"method\":\"initialize\"") != null)
            try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"sse\",\"version\":\"1\"}}}}}}", .{id})
        else if (std.mem.indexOf(u8, body, "\"method\":\"tools/list\"") != null)
            try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[{{\"name\":\"echo\",\"description\":\"Echoes\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{id})
        else
            try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id});
        defer testing.allocator.free(message);
        try out.print("event: message\ndata: {s}\n\n", .{message});
        try out.flush();
    }
};

fn respondText(out: *std.Io.Writer, status: []const u8, body: []const u8) !void {
    try out.print("HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
    try out.flush();
}

fn respond(out: *std.Io.Writer, status: []const u8, body: []const u8) !void {
    try out.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
    try out.flush();
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn requestId(body: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, body, "\"id\":") orelse return "0";
    const rest = body[at + 5 ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse rest.len;
    return rest[0..end];
}
