const std = @import("std");

const Allocator = std.mem.Allocator;

pub const session_occupied_exit_code: u8 = 4;
pub const session_occupied_code = "session.occupied";
pub const session_occupied_message = "This session is in use by another fx process. Stop the session in that process or exit it, then try again.";

pub const OutputFormat = enum {
    text,
    stream_json,

    pub const accepted_values = "text, stream-json";

    pub fn parse(raw: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, raw, "text")) return .text;
        if (std.mem.eql(u8, raw, "stream-json")) return .stream_json;
        return null;
    }
};

pub const EnvDefault = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const InvalidEnvDefault = struct {
    name: []const u8,
    value: []const u8,

    pub fn write(self: InvalidEnvDefault, w: *std.Io.Writer) !void {
        try w.print("Invalid {s} value \"{s}\". Expected one of: {s}.", .{ self.name, self.value, OutputFormat.accepted_values });
    }
};

pub const Resolution = union(enum) {
    format: OutputFormat,
    invalid_env: InvalidEnvDefault,
};

pub fn resolveOutputFormat(flag: ?OutputFormat, env_defaults: []const EnvDefault) Resolution {
    if (flag) |explicit| return .{ .format = explicit };
    for (env_defaults) |entry| {
        const raw = std.mem.trim(u8, entry.value orelse continue, " \t\r\n");
        if (raw.len == 0) continue;
        if (OutputFormat.parse(raw)) |format| return .{ .format = format };
        return .{ .invalid_env = .{ .name = entry.name, .value = raw } };
    }
    return .{ .format = .text };
}

pub const ThinkingBlock = struct {
    started: bool = false,
    at_line_start: bool = false,

    const bullet = "\xe2\x80\xa2 ";
    const indent = "  ";

    pub fn write(self: *ThinkingBlock, w: *std.Io.Writer, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        if (!self.started) {
            self.started = true;
            self.at_line_start = false;
            try w.writeAll(bullet);
        }
        for (chunk) |byte| {
            if (self.at_line_start and byte != '\n') {
                try w.writeAll(indent);
                self.at_line_start = false;
            }
            try w.writeByte(byte);
            if (byte == '\n') self.at_line_start = true;
        }
    }

    pub fn finish(self: *ThinkingBlock, w: *std.Io.Writer) !void {
        if (!self.started) return;
        try w.writeAll(if (self.at_line_start) "\n" else "\n\n");
        self.* = .{};
    }
};

pub fn writeVersion(w: *std.Io.Writer, version: []const u8) !void {
    try w.writeAll("{\"role\":\"meta\",\"type\":\"system.version\",\"version\":");
    try std.json.Stringify.value(version, .{}, w);
    try w.writeAll("}\n");
}

pub fn writeResumeHint(alloc: Allocator, w: *std.Io.Writer, session_id: []const u8) !void {
    const content = try std.fmt.allocPrint(alloc, "To resume this session: fx -r {s}", .{session_id});
    defer alloc.free(content);
    const command = content["To resume this session: ".len..];
    try w.writeAll("{\"role\":\"meta\",\"type\":\"session.resume_hint\",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, w);
    try w.writeAll(",\"command\":");
    try std.json.Stringify.value(command, .{}, w);
    try w.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, w);
    try w.writeAll("}\n");
}

pub fn writeError(w: *std.Io.Writer, code: []const u8, message: []const u8) !void {
    try writeErrorWithSession(w, code, message, null);
}

pub fn writeErrorWithSession(w: *std.Io.Writer, code: []const u8, message: []const u8, session_id: ?[]const u8) !void {
    try w.writeAll("{\"type\":\"error\",\"code\":");
    try std.json.Stringify.value(code, .{}, w);
    try w.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, w);
    if (session_id) |id| {
        try w.writeAll(",\"details\":{\"sessionId\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("}\n");
}

pub fn writeRetrying(w: *std.Io.Writer, next_attempt: usize, message: []const u8) !void {
    try w.print(
        "{{\"role\":\"meta\",\"type\":\"turn.step.retrying\",\"failed_attempt\":{d},\"next_attempt\":{d},\"error_message\":",
        .{ next_attempt -| 1, next_attempt },
    );
    try std.json.Stringify.value(message, .{}, w);
    try w.writeAll("}\n");
}

pub const Stream = struct {
    alloc: Allocator,
    text: std.ArrayList(u8) = .empty,
    response_start: usize = 0,
    calls: std.ArrayList(Call) = .empty,
    answered: std.ArrayList([]u8) = .empty,

    const Call = struct {
        id: []u8,
        name: []u8,
        arguments: []u8,

        fn deinit(self: Call, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.name);
            alloc.free(self.arguments);
        }
    };

    pub fn init(alloc: Allocator) Stream {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Stream) void {
        self.text.deinit(self.alloc);
        for (self.calls.items) |call| call.deinit(self.alloc);
        self.calls.deinit(self.alloc);
        for (self.answered.items) |id| self.alloc.free(id);
        self.answered.deinit(self.alloc);
    }

    pub fn beginResponse(self: *Stream) void {
        self.response_start = self.text.items.len;
    }

    pub fn restartResponse(self: *Stream) void {
        self.text.shrinkRetainingCapacity(@min(self.response_start, self.text.items.len));
    }

    pub fn appendAssistantText(self: *Stream, chunk: []const u8) !void {
        const fresh = if (self.text.items.len == 0) std.mem.trimStart(u8, chunk, "\n") else chunk;
        try self.text.appendSlice(self.alloc, fresh);
    }

    pub fn noteToolCall(self: *Stream, id: []const u8, name: []const u8, arguments: []const u8) !void {
        if (self.hasAnswered(id)) return;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const owned_arguments = try self.alloc.dupe(u8, arguments);
        errdefer self.alloc.free(owned_arguments);
        for (self.calls.items) |*call| {
            if (!std.mem.eql(u8, call.id, id)) continue;
            self.alloc.free(call.name);
            self.alloc.free(call.arguments);
            call.name = owned_name;
            call.arguments = owned_arguments;
            return;
        }
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        try self.calls.append(self.alloc, .{ .id = owned_id, .name = owned_name, .arguments = owned_arguments });
    }

    pub fn writeToolResult(self: *Stream, w: *std.Io.Writer, id: []const u8, content: []const u8) !void {
        if (self.hasAnswered(id)) return;
        {
            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            try self.answered.append(self.alloc, owned_id);
        }
        try self.flushAssistant(w);
        try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeAll(",\"content\":");
        try std.json.Stringify.value(content, .{}, w);
        try w.writeAll("}\n");
    }

    pub fn flushAssistant(self: *Stream, w: *std.Io.Writer) !void {
        if (self.text.items.len == 0 and self.calls.items.len == 0) return;
        try w.writeAll("{\"role\":\"assistant\"");
        if (self.text.items.len > 0) {
            try w.writeAll(",\"content\":");
            try std.json.Stringify.value(self.text.items, .{}, w);
        }
        if (self.calls.items.len > 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (self.calls.items, 0..) |call, index| {
                if (index > 0) try w.writeByte(',');
                try w.writeAll("{\"type\":\"function\",\"id\":");
                try std.json.Stringify.value(call.id, .{}, w);
                try w.writeAll(",\"function\":{\"name\":");
                try std.json.Stringify.value(call.name, .{}, w);
                try w.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments, .{}, w);
                try w.writeAll("}}");
            }
            try w.writeByte(']');
        }
        try w.writeAll("}\n");
        self.text.clearRetainingCapacity();
        self.response_start = 0;
        for (self.calls.items) |call| call.deinit(self.alloc);
        self.calls.clearRetainingCapacity();
    }

    fn hasAnswered(self: *const Stream, id: []const u8) bool {
        for (self.answered.items) |answered_id| {
            if (std.mem.eql(u8, answered_id, id)) return true;
        }
        return false;
    }
};

test "output format resolves flag first, then the first set env default, then text" {
    try std.testing.expectEqual(OutputFormat.text, resolveOutputFormat(null, &.{}).format);
    try std.testing.expectEqual(OutputFormat.stream_json, resolveOutputFormat(null, &.{
        .{ .name = "FX_OUTPUT_FORMAT", .value = null },
        .{ .name = "KIMI_MODEL_OUTPUT_FORMAT", .value = " stream-json\n" },
    }).format);
    try std.testing.expectEqual(OutputFormat.text, resolveOutputFormat(.text, &.{
        .{ .name = "FX_OUTPUT_FORMAT", .value = "stream-json" },
    }).format);
    try std.testing.expectEqual(OutputFormat.text, resolveOutputFormat(.text, &.{
        .{ .name = "FX_OUTPUT_FORMAT", .value = "bogus" },
    }).format);
    try std.testing.expectEqual(OutputFormat.text, resolveOutputFormat(null, &.{
        .{ .name = "FX_OUTPUT_FORMAT", .value = "   " },
    }).format);
}

test "an invalid output format env default names the variable, the value and the accepted values" {
    const resolution = resolveOutputFormat(null, &.{
        .{ .name = "FX_OUTPUT_FORMAT", .value = "json" },
    });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try resolution.invalid_env.write(&out.writer);
    try std.testing.expectEqualStrings(
        "Invalid FX_OUTPUT_FORMAT value \"json\". Expected one of: text, stream-json.",
        out.written(),
    );
}

test "a thinking block starts with a bullet, indents continuation lines and ends with a blank line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var block: ThinkingBlock = .{};
    try block.finish(&out.writer);
    try block.write(&out.writer, "first");
    try block.write(&out.writer, " line\nsecond");
    try block.finish(&out.writer);
    try block.write(&out.writer, "again\n");
    try block.finish(&out.writer);
    try std.testing.expectEqualStrings(
        "\xe2\x80\xa2 first line\n  second\n\n\xe2\x80\xa2 again\n\n",
        out.written(),
    );
}

test "stream-json emits one assistant line with its tool calls before each tool result" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    stream.beginResponse();
    try stream.appendAssistantText("\n\nLooking.");
    try stream.noteToolCall("call_1", "Read", "{\"path\":\"a\"}");
    try stream.noteToolCall("call_2", "Bash", "{\"command\":\"ls\"}");
    try stream.writeToolResult(&out.writer, "call_1", "contents");
    try stream.writeToolResult(&out.writer, "call_2", "listing");
    try stream.writeToolResult(&out.writer, "call_2", "listing again");
    stream.beginResponse();
    try stream.appendAssistantText("Done.");
    try stream.flushAssistant(&out.writer);
    try stream.flushAssistant(&out.writer);

    try std.testing.expectEqualStrings(
        "{\"role\":\"assistant\",\"content\":\"Looking.\",\"tool_calls\":[" ++
            "{\"type\":\"function\",\"id\":\"call_1\",\"function\":{\"name\":\"Read\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}," ++
            "{\"type\":\"function\",\"id\":\"call_2\",\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}\n" ++
            "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"contents\"}\n" ++
            "{\"role\":\"tool\",\"tool_call_id\":\"call_2\",\"content\":\"listing\"}\n" ++
            "{\"role\":\"assistant\",\"content\":\"Done.\"}\n",
        out.written(),
    );
}

test "stream-json drops the text of a restarted response and keeps earlier text" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.appendAssistantText("kept ");
    stream.beginResponse();
    try stream.appendAssistantText("half-formed");
    stream.restartResponse();
    stream.beginResponse();
    try stream.appendAssistantText("answer");
    try stream.flushAssistant(&out.writer);
    try std.testing.expectEqualStrings("{\"role\":\"assistant\",\"content\":\"kept answer\"}\n", out.written());
}

test "stream-json meta lines carry the version, the retry and the resume hint" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeVersion(&out.writer, "1.2.3");
    try writeRetrying(&out.writer, 2, "Offline");
    try writeResumeHint(std.testing.allocator, &out.writer, "abc");
    try writeError(&out.writer, session_occupied_code, session_occupied_message);
    try std.testing.expectEqualStrings(
        "{\"role\":\"meta\",\"type\":\"system.version\",\"version\":\"1.2.3\"}\n" ++
            "{\"role\":\"meta\",\"type\":\"turn.step.retrying\",\"failed_attempt\":1,\"next_attempt\":2,\"error_message\":\"Offline\"}\n" ++
            "{\"role\":\"meta\",\"type\":\"session.resume_hint\",\"session_id\":\"abc\",\"command\":\"fx -r abc\",\"content\":\"To resume this session: fx -r abc\"}\n" ++
            "{\"type\":\"error\",\"code\":\"session.occupied\",\"message\":\"This session is in use by another fx process. Stop the session in that process or exit it, then try again.\"}\n",
        out.written(),
    );
}

test "a session error line carries its session id in details, and a line without one stays bare" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeErrorWithSession(&out.writer, session_occupied_code, "busy", "01JABC");
    try writeError(&out.writer, session_occupied_code, "busy");
    try std.testing.expectEqualStrings(
        "{\"type\":\"error\",\"code\":\"session.occupied\",\"message\":\"busy\",\"details\":{\"sessionId\":\"01JABC\"}}\n" ++
            "{\"type\":\"error\",\"code\":\"session.occupied\",\"message\":\"busy\"}\n",
        out.written(),
    );
}
