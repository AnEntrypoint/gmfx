const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const session_id_prefix = "session_";
const session_id_random_bytes: usize = 16;
const session_id_uuid_len: usize = 36;
const hex_digits = "0123456789abcdef";
const terminal_session_id_prefix = "shell-";
const terminal_session_id_random_bytes: usize = 16;

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    return std.Io.Dir.path.join(alloc, &.{ sessions_dir, session_id });
}

pub const sessions_v2_dir = "v2";

pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 255 or
        std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, "..") or
        std.ascii.eqlIgnoreCase(session_id, sessions_v2_dir))
    {
        return error.InvalidSessionId;
    }
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidSessionId;
        }
    }
}

pub fn generateSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;
    const id = try alloc.alloc(u8, session_id_prefix.len + session_id_uuid_len);
    @memcpy(id[0..session_id_prefix.len], session_id_prefix);
    var out = session_id_prefix.len;
    for (random_bytes, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            id[out] = '-';
            out += 1;
        }
        id[out] = hex_digits[byte >> 4];
        id[out + 1] = hex_digits[byte & 0x0f];
        out += 2;
    }
    return id;
}

pub fn generateTerminalSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [terminal_session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const id = try alloc.alloc(u8, terminal_session_id_prefix.len + encoded_len);
    @memcpy(id[0..terminal_session_id_prefix.len], terminal_session_id_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        id[terminal_session_id_prefix.len..],
        &random_bytes,
    );
    return id;
}

test "generated session id is session_ followed by a version 4 UUID" {
    const id = try generateSessionId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expectEqual(@as(usize, 44), id.len);
    try std.testing.expect(std.mem.startsWith(u8, id, "session_"));
    try validateSessionId(id);
    for (id["session_".len..], 0..) |byte, index| {
        switch (index) {
            8, 13, 18, 23 => try std.testing.expectEqual(@as(u8, '-'), byte),
            14 => try std.testing.expectEqual(@as(u8, '4'), byte),
            19 => try std.testing.expect(std.mem.findScalar(u8, "89ab", byte) != null),
            else => try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte)),
        }
    }

    try validateSessionId("1786460757753-1786460757753277000-ef75d8fd94fdab1");
}

test "generated terminal session id is compact and path safe" {
    const id = try generateTerminalSessionId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expectEqual(terminal_session_id_prefix.len + 22, id.len);
    try std.testing.expect(std.mem.startsWith(u8, id, terminal_session_id_prefix));
    try validateSessionId(id);
}

test "session directory path rejects unsafe ids" {
    const alloc = std.testing.allocator;
    inline for (.{ "", ".", "..", "../outside", "/tmp/outside", "nested/session", "nested\\session" }) |id| {
        try std.testing.expectError(error.InvalidSessionId, sessionDirPath(alloc, "/tmp/sessions", id));
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &unsupported),
    );

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &too_long),
    );

    const dotted = try sessionDirPath(alloc, "/tmp/sessions", "session.v3");
    defer alloc.free(dotted);
    try std.testing.expectEqualStrings("/tmp/sessions/session.v3", dotted);
    inline for (.{
        ".hidden-session",
        "session..branch",
        "last",
        "resume",
    }) |id| {
        const valid = try sessionDirPath(alloc, "/tmp/sessions", id);
        alloc.free(valid);
    }

    const nul_id = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &nul_id),
    );

    var max_id: [255]u8 = undefined;
    @memset(&max_id, 'a');
    const maximum = try sessionDirPath(alloc, "/tmp/sessions", &max_id);
    defer alloc.free(maximum);
    try std.testing.expect(std.mem.endsWith(u8, maximum, &max_id));
}

test "the sessions v2 root is never a v1 session id" {
    try std.testing.expectError(error.InvalidSessionId, validateSessionId(sessions_v2_dir));
    try std.testing.expectError(error.InvalidSessionId, validateSessionId("V2"));
    try validateSessionId("v2x");
}
