const std = @import("std");
const testing = std.testing;

pub const Scripted = struct {
    server: std.Io.net.Server,
    url: []u8,
    thread: std.Thread,
    response: []const u8,
    content_type: []const u8,
    status_line: []const u8,
    request: [64 * 1024]u8 = undefined,
    request_len: usize = 0,

    pub fn init(self: *Scripted, response: []const u8, content_type: []const u8, status_line: []const u8) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try address.listen(testing.io, .{});
        errdefer self.server.deinit(testing.io);
        self.url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/v1", .{self.server.socket.address.getPort()});
        errdefer testing.allocator.free(self.url);
        self.response = response;
        self.content_type = content_type;
        self.status_line = status_line;
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn deinit(self: *Scripted) void {
        if (std.Io.net.IpAddress.parseIp4("127.0.0.1", self.server.socket.address.getPort())) |address| {
            if (address.connect(testing.io, .{ .mode = .stream })) |stream| stream.close(testing.io) else |_| {}
        } else |_| {}
        self.thread.join();
        self.server.deinit(testing.io);
        testing.allocator.free(self.url);
    }

    pub fn recorded(self: *const Scripted) []const u8 {
        return self.request[0..self.request_len];
    }

    fn serve(self: *Scripted) void {
        var stream = self.server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        self.request_len = read_request(&stream, &self.request) catch return;
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(testing.io, &write_buffer);
        writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status_line, self.content_type, self.response.len, self.response }) catch return;
        writer.interface.flush() catch return;
    }
};

fn read_request(stream: *std.Io.net.Stream, out: []u8) !usize {
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(testing.io, &read_buffer);
    var len: usize = 0;
    while (!std.mem.endsWith(u8, out[0..len], "\r\n\r\n")) {
        if (len == out.len) return error.RequestTooLong;
        out[len] = try reader.interface.takeByte();
        len += 1;
    }
    const length = if (header(out[0..len], "content-length")) |text| try std.fmt.parseInt(usize, text, 10) else 0;
    if (length > out.len - len) return error.RequestTooLong;
    for (out[len..][0..length]) |*byte| byte.* = try reader.interface.takeByte();
    return len + length;
}

pub fn header(request: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.find(u8, request, "\r\n\r\n") orelse request.len;
    var lines = std.mem.splitSequence(u8, request[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}
