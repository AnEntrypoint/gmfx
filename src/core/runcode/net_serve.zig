const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Conn = struct {
    stream: std.Io.net.Stream,
    client: bool = false,
    read_buf: [8192]u8 = undefined,
    write_buf: [8192]u8 = undefined,
};

pub const Request = struct {
    method: []u8,
    path: []u8,
    upgrade: bool,
    key: []u8,
    body: []u8,

    pub fn deinit(self: *Request, alloc: Allocator) void {
        alloc.free(self.method);
        alloc.free(self.path);
        alloc.free(self.key);
        alloc.free(self.body);
    }
};

pub const Frame = struct {
    opcode: u8,
    payload: []u8,
};

pub fn listen(alloc: Allocator, io: std.Io, host: []const u8, port: u16) !*std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parse(host, port);
    const server = try alloc.create(std.Io.net.Server);
    server.* = try address.listen(io, .{ .reuse_address = true });
    return server;
}

pub fn accept(alloc: Allocator, io: std.Io, server: *std.Io.net.Server) !*Conn {
    const conn = try alloc.create(Conn);
    conn.* = .{ .stream = try server.accept(io) };
    return conn;
}

pub fn readRequest(alloc: Allocator, io: std.Io, conn: *Conn) !Request {
    var reader = conn.stream.reader(io, &conn.read_buf);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(alloc);
    while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) {
        try head.append(alloc, try reader.interface.takeByte());
    }
    var lines = std.mem.splitSequence(u8, head.items, "\r\n");
    const first = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = try alloc.dupe(u8, parts.next() orelse return error.BadRequest);
    errdefer alloc.free(method);
    const path = try alloc.dupe(u8, parts.next() orelse return error.BadRequest);
    errdefer alloc.free(path);
    var content_length: usize = 0;
    var wants_upgrade = false;
    var key: []const u8 = "";
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) content_length = try std.fmt.parseInt(usize, value, 10);
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) wants_upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key = value;
    }
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const body = try alloc.alloc(u8, content_length);
    errdefer alloc.free(body);
    for (body) |*byte| byte.* = try reader.interface.takeByte();
    return .{ .method = method, .path = path, .upgrade = wants_upgrade, .key = key_copy, .body = body };
}

pub fn respond(alloc: Allocator, io: std.Io, conn: *Conn, status: u16, body: []const u8) !void {
    var writer = conn.stream.writer(io, &conn.write_buf);
    const head = try std.fmt.allocPrint(alloc, "HTTP/1.1 {d} OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    defer alloc.free(head);
    try writer.interface.writeAll(head);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
    conn.stream.close(io);
}

pub fn upgrade(io: std.Io, conn: *Conn, key: []const u8) !void {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var digest: [20]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(guid);
    sha.final(&digest);
    var encoded: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    var writer = conn.stream.writer(io, &conn.write_buf);
    try writer.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
    try writer.interface.writeAll(&encoded);
    try writer.interface.writeAll("\r\n\r\n");
    try writer.interface.flush();
}

pub fn wsSend(io: std.Io, conn: *Conn, payload: []const u8) !void {
    var writer = conn.stream.writer(io, &conn.write_buf);
    const mask_bit: u8 = if (conn.client) 0x80 else 0;
    var header: [4]u8 = undefined;
    header[0] = 0x81;
    var header_len: usize = 2;
    if (payload.len < 126) {
        header[1] = mask_bit | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        header[1] = mask_bit | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else return error.PayloadTooLarge;
    try writer.interface.writeAll(header[0..header_len]);
    if (conn.client) {
        var mask: [4]u8 = undefined;
        try io.randomSecure(&mask);
        try writer.interface.writeAll(&mask);
        for (payload, 0..) |byte, index| try writer.interface.writeByte(byte ^ mask[index % 4]);
    } else {
        try writer.interface.writeAll(payload);
    }
    try writer.interface.flush();
}

pub fn connect(alloc: Allocator, io: std.Io, host: []const u8, port: u16, path: []const u8) !*Conn {
    const address = try std.Io.net.IpAddress.parse(host, port);
    const conn = try alloc.create(Conn);
    errdefer alloc.destroy(conn);
    conn.* = .{ .stream = try address.connect(io, .{}), .client = true };
    var key_bytes: [16]u8 = undefined;
    try io.randomSecure(&key_bytes);
    var key_text: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_text, &key_bytes);
    const request = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, host, port, key_text });
    defer alloc.free(request);
    var writer = conn.stream.writer(io, &conn.write_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var reader = conn.stream.reader(io, &conn.read_buf);
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(alloc);
    while (!std.mem.endsWith(u8, response.items, "\r\n\r\n")) {
        try response.append(alloc, try reader.interface.takeByte());
    }
    if (!std.mem.startsWith(u8, response.items, "HTTP/1.1 101")) return error.WebSocketHandshakeFailed;
    return conn;
}

fn readExact(reader: anytype, dest: []u8) !void {
    for (dest) |*byte| byte.* = try reader.interface.takeByte();
}

pub fn wsRecv(alloc: Allocator, io: std.Io, conn: *Conn) !Frame {
    var reader = conn.stream.reader(io, &conn.read_buf);
    const first = try reader.interface.takeByte();
    const second = try reader.interface.takeByte();
    const masked = second & 0x80 != 0;
    var length: usize = second & 0x7f;
    if (length == 126) {
        var ext: [2]u8 = undefined;
        try readExact(&reader, &ext);
        length = std.mem.readInt(u16, &ext, .big);
    } else if (length == 127) {
        var ext: [8]u8 = undefined;
        try readExact(&reader, &ext);
        length = @intCast(std.mem.readInt(u64, &ext, .big));
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) try readExact(&reader, &mask);
    const payload = try alloc.alloc(u8, length);
    errdefer alloc.free(payload);
    try readExact(&reader, payload);
    if (masked) for (payload, 0..) |*byte, index| {
        byte.* ^= mask[index % 4];
    };
    return .{ .opcode = first & 0x0f, .payload = payload };
}
