const std = @import("std");
const cdp = @import("cdp.zig");
const browser_execute = @import("execute.zig");
const orchestrator = @import("orchestrator.zig");
const io_mod = @import("../shared/io.zig");
const kimi_sections = @import("../config/kimi_sections.zig");

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const default_host = kimi_sections.birdman_default_host;
const default_port: u16 = kimi_sections.birdman_default_port;
const default_path = kimi_sections.birdman_default_path;
const max_handshake_bytes = 8192;
const request_id_bytes = 32;
const max_message_bytes = 16 * 1024 * 1024;
const socket_buffer_bytes = 64 * 1024;
const opcode_continuation: u8 = 0x0;
const opcode_text: u8 = 0x1;
const opcode_binary: u8 = 0x2;
const opcode_close: u8 = 0x8;
const opcode_ping: u8 = 0x9;
const opcode_pong: u8 = 0xa;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    path: []const u8 = default_path,
};

pub const TransportError = error{ TransportFailed, OutOfMemory };

pub const Transport = struct {
    context: *anyopaque,
    send_fn: *const fn (context: *anyopaque, text: []const u8) TransportError!void,
    receive_fn: *const fn (context: *anyopaque, alloc: std.mem.Allocator) TransportError![]u8,

    pub fn send(self: Transport, text: []const u8) TransportError!void {
        return self.send_fn(self.context, text);
    }

    pub fn receive(self: Transport, alloc: std.mem.Allocator) TransportError![]u8 {
        return self.receive_fn(self.context, alloc);
    }
};

pub const Error = cdp.Error || TransportError || error{
    ConnectFailed,
    HandshakeFailed,
    NotConnected,
    ConnectionClosed,
    MessageTooLarge,
    MalformedFrame,
    ReadFailed,
    WriteFailed,
    InvalidParams,
    RemoteError,
    MalformedResponse,
    RequestIdTooLong,
};

pub const Connection = struct {
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    next_id: u64 = 1,
    open: bool = true,

    pub fn send(
        self: *Connection,
        alloc: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        session_id: ?[]const u8,
    ) Error!cdp.Response {
        if (!self.open) return error.NotConnected;
        var id_buffer: [request_id_bytes]u8 = undefined;
        const id = try requestId(&id_buffer, self.next_id);
        self.next_id += 1;
        const envelope = cdp.encodeRequestAlloc(alloc, .{
            .id = id,
            .method = method,
            .params_json = params_json,
            .session_id = session_id,
        }) catch |err| return mapEncodeError(err);
        defer alloc.free(envelope);
        try self.writeFrame(opcode_text, envelope);
        while (true) {
            const text = try self.readMessage();
            defer self.alloc.free(text);
            return cdp.decodeResponseAlloc(alloc, id, text) catch |err| switch (err) {
                error.ResponseIdMismatch => continue,
                error.OutOfMemory => error.OutOfMemory,
                else => error.MalformedFrame,
            };
        }
    }

    pub fn close(self: *Connection) void {
        if (self.open) {
            self.open = false;
            self.writeFrame(opcode_close, &.{}) catch {};
        }
        self.stream.close(io_mod.getIo());
        const alloc = self.alloc;
        alloc.free(self.read_buffer);
        alloc.free(self.write_buffer);
        alloc.destroy(self);
    }

    fn writeFrame(self: *Connection, opcode: u8, payload: []const u8) Error!void {
        var header: [14]u8 = undefined;
        header[0] = 0x80 | opcode;
        var header_len: usize = 2;
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= std.math.maxInt(u16)) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }
        var mask: [4]u8 = undefined;
        io_mod.getIo().random(&mask);
        @memcpy(header[header_len .. header_len + 4], &mask);
        header_len += 4;
        const masked = try self.alloc.alloc(u8, payload.len);
        defer self.alloc.free(masked);
        for (payload, 0..) |byte, index| masked[index] = byte ^ mask[index % 4];
        const writer = &self.writer.interface;
        writer.writeAll(header[0..header_len]) catch return error.WriteFailed;
        writer.writeAll(masked) catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;
    }

    fn readMessage(self: *Connection) Error![]u8 {
        var message: std.ArrayList(u8) = .empty;
        errdefer message.deinit(self.alloc);
        var continuing = false;
        while (true) {
            const first = try self.takeByte();
            const second = try self.takeByte();
            const fin = first & 0x80 != 0;
            const opcode = first & 0x0f;
            if (second & 0x80 != 0) return error.MalformedFrame;
            const length = try self.frameLength(second & 0x7f);
            if (length > max_message_bytes) return error.MessageTooLarge;
            const payload = try self.alloc.alloc(u8, length);
            defer self.alloc.free(payload);
            self.reader.interface.readSliceAll(payload) catch return error.ConnectionClosed;
            switch (opcode) {
                opcode_close => return error.ConnectionClosed,
                opcode_ping => try self.writeFrame(opcode_pong, payload),
                opcode_pong => {},
                opcode_text, opcode_continuation => {
                    if (opcode == opcode_text and continuing) return error.MalformedFrame;
                    if (message.items.len + payload.len > max_message_bytes) return error.MessageTooLarge;
                    message.appendSlice(self.alloc, payload) catch return error.OutOfMemory;
                    if (fin) return message.toOwnedSlice(self.alloc) catch error.OutOfMemory;
                    continuing = true;
                },
                else => return error.MalformedFrame,
            }
        }
    }

    fn frameLength(self: *Connection, short: u8) Error!usize {
        if (short < 126) return short;
        if (short == 126) {
            const length = self.reader.interface.takeInt(u16, .big) catch return error.ConnectionClosed;
            return length;
        }
        const length = self.reader.interface.takeInt(u64, .big) catch return error.ConnectionClosed;
        return std.math.cast(usize, length) orelse error.MessageTooLarge;
    }

    fn takeByte(self: *Connection) Error!u8 {
        return self.reader.interface.takeByte() catch error.ConnectionClosed;
    }

    pub fn sendText(self: *Connection, text: []const u8) Error!void {
        if (!self.open) return error.NotConnected;
        try self.writeFrame(opcode_text, text);
    }

    pub fn receiveText(self: *Connection, alloc: std.mem.Allocator) Error![]u8 {
        if (!self.open) return error.NotConnected;
        const text = try self.readMessage();
        defer self.alloc.free(text);
        return alloc.dupe(u8, text) catch error.OutOfMemory;
    }

    pub fn transport(self: *Connection) Transport {
        return .{ .context = self, .send_fn = sendAdapter, .receive_fn = receiveAdapter };
    }

    fn sendAdapter(context: *anyopaque, text: []const u8) TransportError!void {
        const connection: *Connection = @ptrCast(@alignCast(context));
        connection.sendText(text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransportFailed,
        };
    }

    fn receiveAdapter(context: *anyopaque, alloc: std.mem.Allocator) TransportError![]u8 {
        const connection: *Connection = @ptrCast(@alignCast(context));
        return connection.receiveText(alloc) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TransportFailed,
        };
    }
};

pub fn connect(alloc: std.mem.Allocator, options: Options) Error!*Connection {
    const io = io_mod.getIo();
    const address = std.Io.net.IpAddress.parse(options.host, options.port) catch return error.ConnectFailed;
    const stream = address.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;
    errdefer stream.close(io);

    const connection = try alloc.create(Connection);
    errdefer alloc.destroy(connection);
    const read_buffer = try alloc.alloc(u8, socket_buffer_bytes);
    errdefer alloc.free(read_buffer);
    const write_buffer = try alloc.alloc(u8, socket_buffer_bytes);
    errdefer alloc.free(write_buffer);
    connection.* = .{
        .alloc = alloc,
        .stream = stream,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .reader = stream.reader(io, read_buffer),
        .writer = stream.writer(io, write_buffer),
    };
    try handshake(connection, options);
    return connection;
}

fn handshake(connection: *Connection, options: Options) Error!void {
    var key_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&key_bytes);
    var key_buffer: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buffer, &key_bytes);
    const writer = &connection.writer.interface;
    writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{ options.path, options.host, options.port, key },
    ) catch return error.HandshakeFailed;
    writer.flush() catch return error.HandshakeFailed;

    var response_buffer: [max_handshake_bytes]u8 = undefined;
    var length: usize = 0;
    while (!std.mem.endsWith(u8, response_buffer[0..length], "\r\n\r\n")) {
        if (length == response_buffer.len) return error.HandshakeFailed;
        response_buffer[length] = connection.takeByte() catch return error.HandshakeFailed;
        length += 1;
    }
    const expected = acceptKey(key);
    if (!try validHandshakeResponse(response_buffer[0..length], &expected)) return error.HandshakeFailed;
}

pub fn acceptKey(key: []const u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(websocket_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

fn validHandshakeResponse(response: []const u8, expected_accept: []const u8) !bool {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    const status = lines.next() orelse return false;
    if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.mem.eql(u8, value, expected_accept);
    }
    return false;
}

fn requestId(buffer: []u8, counter: u64) Error![]u8 {
    return std.fmt.bufPrint(buffer, "fx-{d}", .{counter}) catch error.RequestIdTooLong;
}

fn mapEncodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId => error.InvalidSessionId,
        error.InvalidMethod => error.InvalidMethod,
        else => error.InvalidParams,
    };
}

pub const Client = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    next_id: u64 = 1,
    inbox: std.StringHashMapUnmanaged([]u8) = .empty,
    last_error: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, transport: Transport) Client {
        return .{ .alloc = alloc, .transport = transport };
    }

    pub fn deinit(self: *Client) void {
        var pending = self.inbox.iterator();
        while (pending.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.inbox.deinit(self.alloc);
        if (self.last_error) |message| self.alloc.free(message);
        self.* = undefined;
    }

    pub fn connect(self: *Client) Error!void {
        const response = try self.send("Target.getVersion", "{}", null);
        cdp.responseOwnedDeinit(self.alloc, response);
    }

    pub fn targets(self: *Client) Error![]u8 {
        const response = try self.send("Target.getTargets", "{}", null);
        defer cdp.responseOwnedDeinit(self.alloc, response);
        return self.alloc.dupe(u8, response.result_json);
    }

    pub fn open(self: *Client, url: []const u8) Error![]u8 {
        const params = try self.paramsJson(.{ .url = url });
        defer self.alloc.free(params);
        return self.resultString("Target.createTarget", params, null, "targetId");
    }

    pub fn attach(self: *Client, target_id: []const u8) Error![]u8 {
        const params = try self.paramsJson(.{ .targetId = target_id, .flatten = true });
        defer self.alloc.free(params);
        return self.resultString("Target.attachToTarget", params, null, "sessionId");
    }

    pub fn send(self: *Client, method: []const u8, params_json: []const u8, session_id: ?[]const u8) Error!cdp.Response {
        var id_buffer: [request_id_bytes]u8 = undefined;
        const id = try requestId(&id_buffer, self.next_id);
        self.next_id += 1;
        const envelope = cdp.encodeRequestAlloc(self.alloc, .{
            .id = id,
            .method = method,
            .params_json = params_json,
            .session_id = session_id,
        }) catch |err| return mapEncodeError(err);
        defer self.alloc.free(envelope);
        try self.transport.send(envelope);
        const text = try self.awaitResponse(id);
        defer self.alloc.free(text);
        const response = cdp.decodeResponseAlloc(self.alloc, id, text) catch |err| return mapDecodeError(err);
        if (response.error_message) |message| {
            defer cdp.responseOwnedDeinit(self.alloc, response);
            try self.setLastError(message);
            return error.RemoteError;
        }
        return response;
    }

    pub fn exchange(self: *Client, request_json: []const u8) Error![]u8 {
        const id = (try messageId(self.alloc, request_json)) orelse return error.MalformedResponse;
        defer self.alloc.free(id);
        try self.transport.send(request_json);
        return self.awaitResponse(id);
    }

    fn resultString(self: *Client, method: []const u8, params_json: []const u8, session_id: ?[]const u8, field: []const u8) Error![]u8 {
        const response = try self.send(method, params_json, session_id);
        defer cdp.responseOwnedDeinit(self.alloc, response);
        return (try cdp.resultStringAlloc(self.alloc, response.result_json, field)) orelse error.MalformedResponse;
    }

    fn awaitResponse(self: *Client, id: []const u8) Error![]u8 {
        if (self.inbox.fetchRemove(id)) |entry| {
            self.alloc.free(entry.key);
            return entry.value;
        }
        while (true) {
            const text = try self.transport.receive(self.alloc);
            const message_id = messageId(self.alloc, text) catch |err| {
                self.alloc.free(text);
                return err;
            };
            const owned_id = message_id orelse {
                self.alloc.free(text);
                continue;
            };
            if (std.mem.eql(u8, owned_id, id)) {
                self.alloc.free(owned_id);
                return text;
            }
            const slot = self.inbox.getOrPut(self.alloc, owned_id) catch |err| {
                self.alloc.free(owned_id);
                self.alloc.free(text);
                return err;
            };
            if (slot.found_existing) {
                self.alloc.free(owned_id);
                self.alloc.free(text);
            } else {
                slot.value_ptr.* = text;
            }
        }
    }

    fn setLastError(self: *Client, message: []const u8) Error!void {
        const owned = try self.alloc.dupe(u8, message);
        if (self.last_error) |previous| self.alloc.free(previous);
        self.last_error = owned;
    }

    fn paramsJson(self: *Client, value: anytype) Error![]u8 {
        return std.json.Stringify.valueAlloc(self.alloc, value, .{});
    }
};

pub const Link = struct {
    connection: *Connection,
    client: Client,

    pub fn open(alloc: std.mem.Allocator, options: Options) Error!Link {
        const connection = try connect(alloc, options);
        errdefer connection.close();
        var client = Client.init(alloc, connection.transport());
        errdefer client.deinit();
        try client.connect();
        return .{ .connection = connection, .client = client };
    }

    pub fn close(self: *Link) void {
        self.client.deinit();
        self.connection.close();
    }

    pub fn executeTransport(self: *Link) browser_execute.Transport {
        return executeTransportFor(&self.client);
    }
};

pub fn executeTransportFor(client: *Client) browser_execute.Transport {
    return .{ .context = client, .send_fn = executeSend };
}

fn executeSend(context: *anyopaque, alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
    _ = alloc;
    const client: *Client = @ptrCast(@alignCast(context));
    return client.exchange(request_json);
}

fn messageId(alloc: std.mem.Allocator, text: []const u8) Error!?[]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return error.MalformedResponse;
    const object = switch (parsed) {
        .object => |object| object,
        else => return error.MalformedResponse,
    };
    const value = object.get("id") orelse return null;
    return switch (value) {
        .string => |string| try alloc.dupe(u8, string),
        else => null,
    };
}

fn mapDecodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedResponse,
    };
}

test "birdman accept key matches the RFC 6455 example" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "birdman handshake accepts only a 101 answer with the matching accept key" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    const good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try std.testing.expect(try validHandshakeResponse(good, &accept));
    const wrong_key = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: AAAA\r\n\r\n";
    try std.testing.expect(!try validHandshakeResponse(wrong_key, &accept));
    const not_upgraded = "HTTP/1.1 404 Not Found\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try std.testing.expect(!try validHandshakeResponse(not_upgraded, &accept));
}

test "birdman maps envelope encoding failures to typed errors" {
    try std.testing.expectEqual(error.InvalidMethod, mapEncodeError(error.InvalidMethod));
    try std.testing.expectEqual(error.InvalidSessionId, mapEncodeError(error.InvalidSessionId));
    try std.testing.expectEqual(error.InvalidParams, mapEncodeError(error.InvalidParams));
    try std.testing.expectEqual(error.OutOfMemory, mapEncodeError(error.OutOfMemory));
}

const FakeBridge = struct {
    alloc: std.mem.Allocator,
    sent: std.ArrayList([]u8) = .empty,
    inbound: std.ArrayList([]u8) = .empty,
    delivered: usize = 0,

    fn deinit(self: *FakeBridge) void {
        for (self.sent.items) |text| self.alloc.free(text);
        self.sent.deinit(self.alloc);
        for (self.inbound.items) |text| self.alloc.free(text);
        self.inbound.deinit(self.alloc);
    }

    fn queue(self: *FakeBridge, text: []const u8) !void {
        try self.inbound.append(self.alloc, try self.alloc.dupe(u8, text));
    }

    fn transport(self: *FakeBridge) Transport {
        return .{ .context = self, .send_fn = fakeSend, .receive_fn = fakeReceive };
    }

    fn fakeSend(context: *anyopaque, text: []const u8) TransportError!void {
        const self: *FakeBridge = @ptrCast(@alignCast(context));
        const copy = try self.alloc.dupe(u8, text);
        self.sent.append(self.alloc, copy) catch |err| {
            self.alloc.free(copy);
            return err;
        };
    }

    fn fakeReceive(context: *anyopaque, alloc: std.mem.Allocator) TransportError![]u8 {
        const self: *FakeBridge = @ptrCast(@alignCast(context));
        if (self.delivered == self.inbound.items.len) return error.TransportFailed;
        const text = self.inbound.items[self.delivered];
        self.delivered += 1;
        return alloc.dupe(u8, text);
    }
};

test "birdman target-level send frames an envelope without a session id" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"fx-1\",\"result\":{\"targetInfos\":[]}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    const targets = try client.targets();
    defer alloc.free(targets);
    try std.testing.expectEqualStrings("{\"targetInfos\":[]}", targets);

    try std.testing.expectEqual(@as(usize, 1), bridge.sent.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bridge.sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fx-1", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("Target.getTargets", parsed.value.object.get("method").?.string);
    try std.testing.expect(parsed.value.object.get("sessionId") == null);
}

test "birdman session-level send carries the session id and params" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"fx-1\",\"result\":{\"result\":{\"type\":\"string\",\"value\":\"Inbox\"}}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    const response = try client.send("Runtime.evaluate", "{\"expression\":\"document.title\"}", "S-7");
    defer cdp.responseOwnedDeinit(alloc, response);
    try std.testing.expectEqualStrings("{\"result\":{\"type\":\"string\",\"value\":\"Inbox\"}}", response.result_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bridge.sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("S-7", parsed.value.object.get("sessionId").?.string);
    try std.testing.expectEqualStrings(
        "document.title",
        parsed.value.object.get("params").?.object.get("expression").?.string,
    );
}

test "birdman matches responses by id when they arrive out of order" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"method\":\"Target.targetCreated\",\"params\":{}}");
    try bridge.queue("{\"id\":\"fx-2\",\"result\":{\"product\":\"two\"}}");
    try bridge.queue("{\"id\":\"fx-1\",\"result\":{\"product\":\"one\"}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    const first = try client.send("Target.getVersion", "{}", null);
    defer cdp.responseOwnedDeinit(alloc, first);
    const second = try client.send("Target.getVersion", "{}", null);
    defer cdp.responseOwnedDeinit(alloc, second);

    try std.testing.expectEqualStrings("fx-1", first.id);
    try std.testing.expectEqualStrings("{\"product\":\"one\"}", first.result_json);
    try std.testing.expectEqualStrings("fx-2", second.id);
    try std.testing.expectEqualStrings("{\"product\":\"two\"}", second.result_json);
    try std.testing.expectEqual(@as(usize, 3), bridge.delivered);
    try std.testing.expect(client.inbox.count() == 0);
}

test "birdman surfaces an error response as RemoteError with its message" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"fx-1\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    try std.testing.expectError(error.RemoteError, client.send("Bogus.method", "{}", null));
    try std.testing.expectEqualStrings("Method not found", client.last_error.?);
}

test "birdman connect probes Target.getVersion through the transport" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"fx-1\",\"result\":{\"product\":\"Birdman\"}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    try client.connect();

    try std.testing.expectEqual(@as(usize, 1), bridge.sent.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bridge.sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Target.getVersion", parsed.value.object.get("method").?.string);
}

test "birdman exchange forwards a framed envelope and returns its matching reply out of order" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"thebird-8\",\"result\":{}}");
    try bridge.queue("{\"id\":\"thebird-9\",\"result\":{\"value\":\"ok\"}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();
    const request = "{\"id\":\"thebird-9\",\"method\":\"Runtime.evaluate\",\"params\":{},\"sessionId\":\"S-1\"}";

    const reply = try client.exchange(request);
    defer alloc.free(reply);

    try std.testing.expectEqualStrings("{\"id\":\"thebird-9\",\"result\":{\"value\":\"ok\"}}", reply);
    try std.testing.expectEqual(@as(usize, 1), bridge.sent.items.len);
    try std.testing.expectEqualStrings(request, bridge.sent.items[0]);
}

test "birdman exchange rejects a request without a string id before sending" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    try std.testing.expectError(error.MalformedResponse, client.exchange("{\"method\":\"Target.getTargets\"}"));
    try std.testing.expectEqual(@as(usize, 0), bridge.sent.items.len);
}

test "birdman exchange reports a dropped transport as TransportFailed" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    try std.testing.expectError(error.TransportFailed, client.exchange("{\"id\":\"fx-1\",\"method\":\"Target.getTargets\"}"));
}

test "birdman execute transport runs a browser-layer targets step and tracks its tabs" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"list-1\",\"result\":{\"targetInfos\":[{\"type\":\"page\"}]}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();
    var orchestration = orchestrator.Orchestrator.init("birdman-test");
    defer orchestration.deinit(alloc);
    const commands = [_]browser_execute.Command{.{ .run_id = "list", .request_id = "list-1", .action = .targets }};
    var out: [1]cdp.Response = undefined;

    const count = try orchestration.runSequence(alloc, executeTransportFor(&client), "list", &commands, &out);
    defer for (out[0..count]) |response| cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("{\"targetInfos\":[{\"type\":\"page\"}]}", out[0].result_json);
    try std.testing.expectEqual(@as(usize, 1), orchestration.browserStatus().tab_count);
    try std.testing.expectEqual(@as(usize, 1), bridge.sent.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bridge.sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Target.getTargets", parsed.value.object.get("method").?.string);
}

test "birdman transport failure marks the browser step failed and returns the error" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();
    var orchestration = orchestrator.Orchestrator.init("birdman-failure");
    defer orchestration.deinit(alloc);
    const commands = [_]browser_execute.Command{.{ .run_id = "gone", .request_id = "gone-1", .action = .targets }};
    var out: [1]cdp.Response = undefined;

    try std.testing.expectError(error.TransportFailed, orchestration.runSequence(alloc, executeTransportFor(&client), "gone", &commands, &out));
    try std.testing.expectEqual(orchestrator.RouteState.failed, orchestration.snapshot.state);
}

test "birdman attach frames a flattened attach and returns the session id" {
    const alloc = std.testing.allocator;
    var bridge = FakeBridge{ .alloc = alloc };
    defer bridge.deinit();
    try bridge.queue("{\"id\":\"fx-1\",\"result\":{\"sessionId\":\"S-42\"}}");
    var client = Client.init(alloc, bridge.transport());
    defer client.deinit();

    const session = try client.attach("T-1");
    defer alloc.free(session);
    try std.testing.expectEqualStrings("S-42", session);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bridge.sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Target.attachToTarget", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("T-1", parsed.value.object.get("params").?.object.get("targetId").?.string);
    try std.testing.expect(parsed.value.object.get("params").?.object.get("flatten").?.bool);
}
