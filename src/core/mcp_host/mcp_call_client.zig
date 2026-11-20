const std = @import("std");
const io_mod = @import("../shared/io.zig");
const capability_mod = @import("../tooling/mcp_call_capability.zig");
const mcp_call = @import("mcp_call.zig");
const wire = @import("mcp_call_wire.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const exit = struct {
    pub const ok: u8 = 0;
    pub const failed: u8 = 1;
    pub const usage: u8 = 2;
    pub const unavailable: u8 = 3;
    pub const busy: u8 = 4;
    pub const denied: u8 = 5;
    pub const tool_error: u8 = 6;
};

pub const Reply = struct {
    header: wire.Header,
    bytes: []const u8,
};

pub const CallError = error{ MalformedReply, UnsupportedReply, ConnectionLost, OutOfMemory };

pub const Command = union(enum) {
    call: struct { tool: []const u8, arguments: ?[]const u8 },
    list: []const u8,
    search: []const u8,
    help: []const u8,
    resources: struct { server: []const u8, cursor: ?[]const u8 },
    templates: struct { server: []const u8, cursor: ?[]const u8 },
    read: struct { server: []const u8, uri: []const u8 },
    prompts: struct { server: []const u8, cursor: ?[]const u8 },
    prompt: struct { server: []const u8, name: []const u8, arguments: ?[]const u8 },
};

pub fn call(
    arena: Allocator,
    io: std.Io,
    socket_path: []const u8,
    token: mcp_call.Token,
    operation: wire.Operation,
) (CallError || std.Io.net.UnixAddress.ConnectError || std.Io.net.UnixAddress.InitError)!Reply {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    wire.writeRequest(&writer.interface, token, operation) catch return error.ConnectionLost;
    writer.interface.flush() catch return error.ConnectionLost;
    var read_buffer: [wire.max_header_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.MalformedReply,
        error.ReadFailed => return error.ConnectionLost,
    }) orelse return error.ConnectionLost;
    const header = try wire.parseHeader(arena, line);

    if (header.bytes > capability_mod.max_result_bytes + 64 * 1024) return error.MalformedReply;
    const bytes = reader.interface.readAllocAll(arena, @intCast(header.bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream, error.ReadFailed => return error.ConnectionLost,
    };
    return .{ .header = header, .bytes = bytes };
}

fn readArguments(arena: Allocator, io: std.Io, err: *Writer, arguments: ?[]const u8) !?[]const u8 {
    const arguments_json = blk: {
        const raw = arguments orelse break :blk "{}";
        if (!std.mem.eql(u8, raw, "-")) break :blk raw;
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
        break :blk stdin.interface.allocRemaining(arena, .limited(wire.max_request_bytes)) catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("fx mcp call: the arguments on stdin are larger than {d} bytes.\n", .{wire.max_request_bytes});
                return null;
            },
            else => return e,
        };
    };
    if (!isJsonObject(arena, arguments_json)) {
        try err.writeAll("fx mcp call: the arguments must be one JSON object, such as '{\"team\":\"ENG\"}'.\n");
        return null;
    }
    return arguments_json;
}

pub fn run(arena: Allocator, io: std.Io, out: *Writer, err: *Writer, command: Command) !u8 {
    const operation: wire.Operation = switch (command) {
        .call => |value| .{ .call = .{
            .tool = value.tool,
            .arguments_json = (try readArguments(arena, io, err, value.arguments)) orelse return exit.usage,
        } },
        .list => |server| .{ .list = server },
        .search => |query| .{ .search = query },
        .help => |tool| .{ .help = tool },
        .resources => |value| .{ .resources = .{ .server = value.server, .cursor = value.cursor } },
        .templates => |value| .{ .templates = .{ .server = value.server, .cursor = value.cursor } },
        .read => |value| .{ .read = .{ .server = value.server, .uri = value.uri } },
        .prompts => |value| .{ .prompts = .{ .server = value.server, .cursor = value.cursor } },
        .prompt => |value| .{ .prompt = .{
            .server = value.server,
            .name = value.name,
            .arguments_json = (try readArguments(arena, io, err, value.arguments)) orelse return exit.usage,
        } },
    };
    const tool = operation.subject();
    const socket_path = io_mod.getenv(wire.socket_env) orelse return unavailable(err);
    const token = wire.parseToken(io_mod.getenv(wire.token_env) orelse "") orelse return unavailable(err);

    const reply = call(arena, io, socket_path, token, operation) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.UnsupportedReply => {
            try err.writeAll("fx mcp call: the running fx session is another fx version. Run the fx that started the session, or restart the session with this one.\n");
            return exit.unavailable;
        },
        error.ConnectionLost, error.MalformedReply => {
            try err.print("fx mcp call: the connection to fx was lost ({s}). The call may have run; check its effect before running it again.\n", .{@errorName(e)});
            return exit.failed;
        },
        else => return unavailable(err),
    };
    switch (reply.header.status) {
        .ok => {
            try out.writeAll(reply.bytes);

            if (operation == .call and !stdoutIsTerminal(io)) {
                try err.print("fx mcp call: {s}\n", .{try shapeSummary(arena, reply.bytes)});
            }
            return exit.ok;
        },
        .tool_error => {
            try err.print("fx mcp call: {s} returned an error:\n", .{tool});
            try writeLine(err, reply.bytes);
            return exit.tool_error;
        },
        .failed => {
            try err.writeAll("fx mcp call: ");
            try writeLine(err, reply.bytes);
            return exit.failed;
        },
        .denied => {
            try err.print("fx mcp call: {s} did not run. ", .{tool});
            try writeLine(err, reply.bytes);
            return exit.denied;
        },
        .refused => {
            try err.writeAll("fx mcp call: ");
            try writeLine(err, reply.bytes);
            return if (reply.header.reason == .busy) exit.busy else if (reply.header.reason == .malformed or reply.header.reason == .too_large) exit.usage else exit.unavailable;
        },
    }
}

fn stdoutIsTerminal(io: std.Io) bool {
    return std.Io.File.stdout().isTty(io) catch false;
}

const max_summary_chars = 1500;
const max_shape_depth = 8;
const max_repeated_text_values = 8;
const max_repeated_text_bytes = 32;

pub fn shapeSummary(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    if (bytes.len == 0) return "wrote 0 bytes";
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const lines = std.mem.countScalar(u8, bytes, '\n') + @intFromBool(bytes[bytes.len - 1] != '\n');
            return arena.print("wrote {d} bytes of text in {d} lines", .{ bytes.len, lines });
        },
    };

    var buffer: [max_summary_chars]u8 = undefined;
    var shape: Writer = .fixed(&buffer);
    const whole = if (describeShape(&shape, value, 0, &.{})) |_| true else |_| false;
    var text = shape.buffered();
    while (!std.unicode.utf8ValidateSlice(text)) text = text[0 .. text.len - 1];
    return arena.print("wrote {d} bytes of JSON: {s}{s}", .{ bytes.len, text, if (whole) "" else "…" });
}

fn describeShape(w: *Writer, value: std.json.Value, depth: u8, list_items: []const std.json.Value) Writer.Error!void {
    if (depth >= max_shape_depth) return w.writeAll("…");
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => try w.writeAll("boolean"),
        .integer, .float, .number_string => try w.writeAll("number"),
        .string => try w.writeAll("string"),
        .array => |items| {
            if (items.items.len == 0) return w.writeAll("[]");
            try w.print("[{d} × ", .{items.items.len});
            try describeShape(w, items.items[0], depth + 1, items.items);
            try w.writeAll("]");
        },
        .object => |object| {
            try w.writeAll("{");
            var it = object.iterator();
            var index: usize = 0;
            while (it.next()) |entry| : (index += 1) {
                if (index > 0) try w.writeAll(", ");
                try writeKey(w, entry.key_ptr.*);
                var hint_buffer: [max_repeated_text_values][]const u8 = undefined;
                if (repeatedValues(list_items, entry.key_ptr.*, &hint_buffer)) |values| {
                    try w.writeAll(": ");
                    for (values, 0..) |hint, hint_index| {
                        if (hint_index > 0) try w.writeAll("|");
                        try std.json.Stringify.value(hint, .{}, w);
                    }
                } else if (depth < 2) {
                    try w.writeAll(": ");
                    try describeShape(w, entry.value_ptr.*, depth + 1, &.{});
                }
            }
            try w.writeAll("}");
        },
    }
}

fn writeKey(w: *Writer, key: []const u8) Writer.Error!void {
    const plain = key.len > 0 and for (key) |byte| {
        if (byte < 0x20 or byte == 0x7f or std.mem.findScalar(u8, "\"\\,:{}[]|", byte) != null) break false;
    } else true;
    if (plain) return w.writeAll(key);
    return std.json.Stringify.value(key, .{}, w);
}

fn repeatedValues(items: []const std.json.Value, key: []const u8, out: *[max_repeated_text_values][]const u8) ?[]const []const u8 {
    var distinct: usize = 0;
    var seen: usize = 0;
    for (items) |item| {
        if (item != .object) continue;
        const field = item.object.get(key) orelse continue;
        switch (field) {
            .null => continue,
            .string => |text| {
                if (text.len > max_repeated_text_bytes) return null;
                seen += 1;
                for (out[0..distinct]) |known| {
                    if (std.mem.eql(u8, known, text)) break;
                } else {
                    if (distinct == max_repeated_text_values) return null;
                    out[distinct] = text;
                    distinct += 1;
                }
            },
            else => return null,
        }
    }
    if (distinct == 0 or distinct >= seen) return null;
    return out[0..distinct];
}

fn unavailable(err: *Writer) !u8 {
    try err.writeAll("fx mcp call: no running fx shell call to reach. It works only in a command that fx's shell tool runs, while that call runs.\n");
    return exit.unavailable;
}

fn writeLine(w: *Writer, text: []const u8) !void {
    try w.writeAll(text);
    if (!std.mem.endsWith(u8, text, "\n")) try w.writeByte('\n');
}

fn isJsonObject(arena: Allocator, text: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return false;
    return value == .object;
}

test "fx mcp call outside a shell call reports it is unavailable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var err: std.Io.Writer.Allocating = .init(arena_state.allocator());
    if (io_mod.getenv(wire.socket_env) != null) return error.SkipZigTest;
    try std.testing.expectEqual(exit.unavailable, try run(arena_state.allocator(), std.testing.io, &out.writer, &err.writer, .{ .call = .{ .tool = "mcp_s_t", .arguments = null } }));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(std.mem.find(u8, err.written(), "no running fx shell call") != null);
    try std.testing.expectEqual(exit.usage, try run(arena_state.allocator(), std.testing.io, &out.writer, &err.writer, .{ .call = .{ .tool = "mcp_s_t", .arguments = "[1]" } }));

    try std.testing.expectEqual(exit.unavailable, try run(arena_state.allocator(), std.testing.io, &out.writer, &err.writer, .{ .list = "linear" }));
}

test "a shape summary of one item names sizes, keys, and types, not values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summary = try shapeSummary(arena,
        \\{"issues":[{"id":"LABS-1202","title":"ZQX secret","labels":["bug"],"priority":{"value":1,"name":"Urgent"}}],"hasNextPage":false}
    );
    try std.testing.expectEqualStrings("wrote 128 bytes of JSON: {issues: [1 × {id, title, labels, priority}], hasNextPage: boolean}", summary);
    for ([_][]const u8{ "LABS-1202", "ZQX", "bug", "Urgent" }) |value| try std.testing.expect(std.mem.find(u8, summary, value) == null);
    try std.testing.expectEqualStrings("wrote 12 bytes of text in 2 lines", try shapeSummary(arena, "first\nsecond"));
    try std.testing.expectEqualStrings("wrote 0 bytes", try shapeSummary(arena, ""));
}

test "a shape summary shows the values of repeated short text fields only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summary = try shapeSummary(arena,
        \\[{"id":"A-1","state":"open","title":"ZQX one","tag":"\u001b[31m"},{"id":"A-2","state":"done","title":"ZQX two","tag":"\u001b[31m"},{"id":"A-3","state":"open","title":"ZQX three","tag":null}]
    );
    try std.testing.expectEqualStrings(
        \\wrote 190 bytes of JSON: [3 × {id: string, state: "open"|"done", title: string, tag: "\u001b[31m"}]
    , summary);
    try std.testing.expect(std.mem.findScalar(u8, summary, 0x1b) == null);
    for ([_][]const u8{ "A-1", "ZQX" }) |value| try std.testing.expect(std.mem.find(u8, summary, value) == null);
}

test "a shape summary stays bounded on deep, wide, and odd input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const depth = 100_000;
    const deep = try arena.alloc(u8, depth * 2);
    @memset(deep[0..depth], '[');
    @memset(deep[depth..], ']');
    const deep_summary = try shapeSummary(arena, deep);
    try std.testing.expect(std.mem.endsWith(u8, deep_summary, "[1 × …]]]]]]]]"));

    var wide: std.Io.Writer.Allocating = .init(arena);
    try wide.writer.writeAll("{");
    for (0..400) |index| try wide.writer.print("{s}\"field_é_{d}\":{d}", .{ if (index > 0) "," else "", index, index });
    try wide.writer.writeAll("}");
    const wide_summary = try shapeSummary(arena, wide.written());
    try std.testing.expect(std.mem.endsWith(u8, wide_summary, "…"));
    try std.testing.expect(wide_summary.len < max_summary_chars + 64);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_summary));

    const odd_summary = try shapeSummary(arena,
        \\[{"a\u001bb":"x","c,d":"y"},{"a\u001bb":"x","c,d":"y"}]
    );
    try std.testing.expectEqualStrings(
        \\wrote 55 bytes of JSON: [2 × {"a\u001bb": "x", "c,d": "y"}]
    , odd_summary);
    try std.testing.expect(std.mem.findScalar(u8, odd_summary, 0x1b) == null);
}
