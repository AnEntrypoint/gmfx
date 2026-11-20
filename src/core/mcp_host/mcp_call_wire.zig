const std = @import("std");
const capability_mod = @import("../tooling/mcp_call_capability.zig");
const mcp_call = @import("mcp_call.zig");

const Allocator = std.mem.Allocator;

pub const socket_env = "FX_MCP_CALL_SOCKET";
pub const token_env = "FX_MCP_CALL_TOKEN";

pub const max_request_bytes: usize = 1024 * 1024;
pub const max_header_bytes: usize = 4 * 1024;

pub const token_hex_len = 2 * @sizeOf(mcp_call.Token);

pub fn tokenHex(token: mcp_call.Token) [token_hex_len]u8 {
    return std.fmt.bytesToHex(token, .lower);
}

pub fn parseToken(hex: []const u8) ?mcp_call.Token {
    if (hex.len != token_hex_len) return null;
    var token: mcp_call.Token = undefined;
    _ = std.fmt.hexToBytes(&token, hex) catch return null;
    return token;
}

pub const Cursored = struct { server: []const u8, cursor: ?[]const u8 };

pub const Operation = union(enum) {
    call: struct { tool: []const u8, arguments_json: []const u8 },
    list: []const u8,
    search: []const u8,
    help: []const u8,
    resources: Cursored,
    templates: Cursored,
    read: struct { server: []const u8, uri: []const u8 },
    prompts: Cursored,
    prompt: struct { server: []const u8, name: []const u8, arguments_json: []const u8 },

    pub fn lookup(self: Operation) ?capability_mod.Lookup {
        return switch (self) {
            .call => null,
            .list => |server| .{ .list = server },
            .search => |query| .{ .search = query },
            .help => |tool| .{ .help = tool },
            .resources => |value| .{ .resource = .{ .server = value.server, .op = .{ .list = value.cursor } } },
            .templates => |value| .{ .resource = .{ .server = value.server, .op = .{ .templates = value.cursor } } },
            .read => |value| .{ .resource = .{ .server = value.server, .op = .{ .read = value.uri } } },
            .prompts => |value| .{ .resource = .{ .server = value.server, .op = .{ .prompts = value.cursor } } },
            .prompt => |value| .{ .resource = .{ .server = value.server, .op = .{ .prompt = .{ .name = value.name, .arguments = value.arguments_json } } } },
        };
    }

    pub fn subject(self: Operation) []const u8 {
        return switch (self) {
            .call => |value| value.tool,
            .list, .search, .help => |text| text,
            .resources, .templates, .prompts => |value| value.server,
            .read => |value| value.server,
            .prompt => |value| value.server,
        };
    }
};

pub const Request = struct {
    version: u32,
    token: ?mcp_call.Token,
    operation: Operation,
};

pub const RequestError = error{ MalformedRequest, OutOfMemory };

pub fn parseRequest(arena: Allocator, line: []const u8) RequestError!Request {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedRequest,
    };
    if (value != .object) return error.MalformedRequest;
    const object = value.object;
    const version = object.get("v") orelse return error.MalformedRequest;
    if (version != .integer or version.integer < 0 or version.integer > std.math.maxInt(u32)) return error.MalformedRequest;
    const token = object.get("token") orelse return error.MalformedRequest;
    if (token != .string) return error.MalformedRequest;
    const op = object.get("op") orelse return error.MalformedRequest;
    if (op != .string) return error.MalformedRequest;
    const kind = std.meta.stringToEnum(std.meta.Tag(Operation), op.string) orelse return error.MalformedRequest;
    const operation: Operation = switch (kind) {
        .call => blk: {
            const arguments = object.get("arguments") orelse return error.MalformedRequest;
            if (arguments != .object) return error.MalformedRequest;
            var out: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(arguments, .{}, &out.writer) catch return error.OutOfMemory;
            break :blk .{ .call = .{ .tool = try nonEmptyString(object, "tool"), .arguments_json = out.written() } };
        },
        .list => .{ .list = try nonEmptyString(object, "server") },
        .search => .{ .search = try nonEmptyString(object, "query") },
        .help => .{ .help = try nonEmptyString(object, "tool") },
        .resources => .{ .resources = .{ .server = try nonEmptyString(object, "server"), .cursor = try optionalString(object, "cursor") } },
        .templates => .{ .templates = .{ .server = try nonEmptyString(object, "server"), .cursor = try optionalString(object, "cursor") } },
        .read => .{ .read = .{ .server = try nonEmptyString(object, "server"), .uri = try nonEmptyString(object, "uri") } },
        .prompts => .{ .prompts = .{ .server = try nonEmptyString(object, "server"), .cursor = try optionalString(object, "cursor") } },
        .prompt => .{ .prompt = .{ .server = try nonEmptyString(object, "server"), .name = try nonEmptyString(object, "name"), .arguments_json = try objectString(arena, object, "arguments") } },
    };
    return .{
        .version = @intCast(version.integer),
        .token = parseToken(token.string),
        .operation = operation,
    };
}

fn objectString(arena: Allocator, object: std.json.ObjectMap, key: []const u8) RequestError![]const u8 {
    const value = object.get(key) orelse return "{}";
    if (value != .object) return error.MalformedRequest;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) RequestError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.MalformedRequest;
    return value.string;
}

fn nonEmptyString(object: std.json.ObjectMap, key: []const u8) RequestError![]const u8 {
    const value = object.get(key) orelse return error.MalformedRequest;
    if (value != .string or value.string.len == 0) return error.MalformedRequest;
    return value.string;
}

pub fn writeRequest(writer: *std.Io.Writer, token: mcp_call.Token, operation: Operation) std.Io.Writer.Error!void {
    const hex = tokenHex(token);
    try writer.print("{{\"v\":{d},\"token\":\"{s}\",\"op\":\"{s}\"", .{ mcp_call.protocol_version, &hex, @tagName(operation) });
    switch (operation) {
        .call => |value| {
            try writer.writeAll(",\"tool\":");
            try std.json.Stringify.value(value.tool, .{}, writer);
            try writer.writeAll(",\"arguments\":");
            try writer.writeAll(value.arguments_json);
        },
        .list => |server| try writeField(writer, "server", server),
        .search => |query| try writeField(writer, "query", query),
        .help => |tool| try writeField(writer, "tool", tool),
        .resources, .templates, .prompts => |value| {
            try writeField(writer, "server", value.server);
            if (value.cursor) |cursor| try writeField(writer, "cursor", cursor);
        },
        .prompt => |value| {
            try writeField(writer, "server", value.server);
            try writeField(writer, "name", value.name);
            try writer.writeAll(",\"arguments\":");
            try writer.writeAll(value.arguments_json);
        },
        .read => |value| {
            try writeField(writer, "server", value.server);
            try writeField(writer, "uri", value.uri);
        },
    }
    try writer.writeAll("}\n");
}

fn writeField(writer: *std.Io.Writer, comptime key: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try std.json.Stringify.value(text, .{}, writer);
}

pub const Status = enum { ok, tool_error, failed, denied, refused };

pub const Reason = enum {
    closed,
    unauthorized,
    unsupported_version,
    busy,
    malformed,
    too_large,

    pub fn fromRefusal(refusal: mcp_call.Refusal) Reason {
        return switch (refusal) {
            .closed => .closed,
            .unauthorized => .unauthorized,
            .unsupported_version => .unsupported_version,
            .busy => .busy,
        };
    }
};

pub const Header = struct {
    status: Status,
    reason: ?Reason = null,
    bytes: u64,
};

pub fn writeHeader(writer: *std.Io.Writer, header: Header) std.Io.Writer.Error!void {
    try writer.print("{{\"v\":{d},\"status\":\"{s}\"", .{ mcp_call.protocol_version, @tagName(header.status) });
    if (header.reason) |reason| try writer.print(",\"reason\":\"{s}\"", .{@tagName(reason)});
    try writer.print(",\"bytes\":{d}}}\n", .{header.bytes});
}

pub const HeaderError = error{ MalformedReply, UnsupportedReply, OutOfMemory };

pub fn parseHeader(arena: Allocator, line: []const u8) HeaderError!Header {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedReply,
    };
    if (value != .object) return error.MalformedReply;
    const version = value.object.get("v") orelse return error.MalformedReply;
    if (version != .integer) return error.MalformedReply;
    if (version.integer != mcp_call.protocol_version) return error.UnsupportedReply;
    const status = value.object.get("status") orelse return error.MalformedReply;
    if (status != .string) return error.MalformedReply;
    const bytes = value.object.get("bytes") orelse return error.MalformedReply;
    if (bytes != .integer or bytes.integer < 0) return error.MalformedReply;
    const reason: ?Reason = if (value.object.get("reason")) |raw| blk: {
        if (raw != .string) return error.MalformedReply;
        break :blk std.meta.stringToEnum(Reason, raw.string) orelse return error.MalformedReply;
    } else null;
    return .{
        .status = std.meta.stringToEnum(Status, status.string) orelse return error.MalformedReply,
        .reason = reason,
        .bytes = @intCast(bytes.integer),
    };
}

test "a request line round-trips, and a bad token parses as no token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0xab);
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(&out.writer, token, .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{\"team\":\"ENG\"}" } });
    const line = out.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(@as(u32, 1), parsed.version);
    try std.testing.expectEqualSlices(u8, &token, &parsed.token.?);
    try std.testing.expectEqualStrings("mcp_linear_list_issues", parsed.operation.call.tool);
    try std.testing.expectEqualStrings("{\"team\":\"ENG\"}", parsed.operation.call.arguments_json);

    const forged = try parseRequest(arena, "{\"v\":1,\"token\":\"nothex\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}");
    try std.testing.expect(forged.token == null);
}

test "each lookup round-trips with its text, quotes included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x01);
    for ([_]Operation{
        .{ .list = "linear" },
        .{ .search = "open \"issues\" for me" },
        .{ .help = "mcp_linear_list_issues" },
    }) |operation| {
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeRequest(&out.writer, token, operation);
        const line = out.written();
        const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
        try std.testing.expectEqual(std.meta.activeTag(operation), std.meta.activeTag(parsed.operation));
        try std.testing.expectEqualStrings(operation.subject(), parsed.operation.subject());
        try std.testing.expect(parsed.operation.lookup() != null);
    }
}

test "garbage request lines are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "",
        "not json",
        "[]",
        "{\"v\":1,\"token\":\"\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"run\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":[]}",
        "{\"v\":-1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":7,\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"list\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"search\",\"query\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"help\",\"tool\":7}",
    }) |line| try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

test "a reply header round-trips and rejects another version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeHeader(&out.writer, .{ .status = .refused, .reason = .busy, .bytes = 12 });
    const line = out.written();
    const header = try parseHeader(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(Status.refused, header.status);
    try std.testing.expectEqual(Reason.busy, header.reason.?);
    try std.testing.expectEqual(@as(u64, 12), header.bytes);
    try std.testing.expectError(error.UnsupportedReply, parseHeader(arena, "{\"v\":2,\"status\":\"ok\",\"bytes\":0}"));
    try std.testing.expectError(error.MalformedReply, parseHeader(arena, "{\"v\":1,\"status\":\"maybe\",\"bytes\":0}"));
}
