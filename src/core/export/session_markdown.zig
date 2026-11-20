const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const ToolCall = types.ToolCall;
const PersistedToolResult = types.PersistedToolResult;
const ExecutionMemory = types.ExecutionMemory;

pub const Input = struct {
    session_id: []const u8,
    work_dir: []const u8,
    exported_at_ms: i64,
    history: []const HistoryTurn,
};

const hint_keys = [_][]const u8{ "path", "file_path", "command", "query", "url", "name", "pattern" };
const max_hint_bytes = 60;
const max_topic_bytes = 80;
const max_loose_value_bytes = 80;
const ellipsis = "\u{2026}";

const CallInfo = struct {
    name: []const u8,
    hint: []u8,
};

pub fn render(alloc: Allocator, input: Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("---\nsession_id: ");
    try w.writeAll(input.session_id);
    try w.writeAll("\nexported_at: ");
    try writeIso8601(w, input.exported_at_ms);
    try w.print("\nwork_dir: {s}\nmessage_count: {d}\n---\n\n# fx Session Export\n\n", .{
        input.work_dir,
        countMessages(input.history),
    });

    try writeOverview(alloc, w, input.history);
    try w.writeAll("\n");

    var number: usize = 0;
    for (input.history) |entry| {
        if (std.meta.activeTag(entry) == .compacted_summary) continue;
        number += 1;
        try writeTurn(alloc, w, entry, number);
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn countMessages(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |entry| {
        switch (entry) {
            .compacted_summary => {},
            .assistant => |turn| {
                count += 1 + executionResultCount(turn.execution);
                if (turn.assistant.len > 0) count += 1;
            },
            .interrupted => |turn| {
                count += 1 + executionResultCount(turn.execution);
                if (turn.assistant) |text| {
                    if (text.len > 0) count += 1;
                }
            },
        }
    }
    return count;
}

fn executionResultCount(execution: ExecutionMemory) usize {
    var count: usize = 0;
    for (execution.tool_steps) |step| count += step.tool_results.len;
    return count;
}

fn executionCallCount(execution: ExecutionMemory) usize {
    var count: usize = 0;
    for (execution.tool_steps) |step| count += step.tool_calls.len;
    return count;
}

fn countTurns(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |entry| {
        if (std.meta.activeTag(entry) != .compacted_summary) count += 1;
    }
    return count;
}

fn countToolCalls(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |entry| {
        switch (entry) {
            .compacted_summary => {},
            .assistant => |turn| count += executionCallCount(turn.execution),
            .interrupted => |turn| {
                count += executionCallCount(turn.execution);
                if (turn.tool_call != null) count += 1;
            },
        }
    }
    return count;
}

fn writeOverview(alloc: Allocator, w: *std.Io.Writer, history: []const HistoryTurn) !void {
    try w.writeAll("## Overview\n\n");
    const topic = firstUserText(history);
    if (topic.len > 0) {
        const shortened = try shorten(alloc, topic, max_topic_bytes);
        defer alloc.free(shortened);
        try w.print("- **Topic**: {s}\n", .{shortened});
    } else {
        try w.writeAll("- **Topic**: (empty)\n");
    }
    try w.print("- **Conversation**: {d} turns | {d} tool calls\n\n---\n", .{
        countTurns(history),
        countToolCalls(history),
    });
}

fn firstUserText(history: []const HistoryTurn) []const u8 {
    for (history) |entry| {
        switch (entry) {
            .compacted_summary => continue,
            .assistant => |turn| return turn.user.text,
            .interrupted => |turn| return turn.user.text,
        }
    }
    return "";
}

fn writeTurn(alloc: Allocator, w: *std.Io.Writer, entry: HistoryTurn, number: usize) !void {
    try w.print("## Turn {d}\n\n", .{number});
    switch (entry) {
        .compacted_summary => {},
        .assistant => |turn| {
            try writeUser(w, turn.user);
            try writeAssistant(alloc, w, turn.execution, turn.assistant, null);
        },
        .interrupted => |turn| {
            try writeUser(w, turn.user);
            try writeAssistant(alloc, w, turn.execution, turn.assistant orelse "", turn.tool_call);
        },
    }
}

fn writeUser(w: *std.Io.Writer, user: types.UserTurn) !void {
    try w.writeAll("### User\n\n");
    if (user.text.len > 0) try w.print("{s}\n\n", .{user.text});
    for (user.images) |_| try w.writeAll("[image]\n\n");
}

fn writeAssistant(
    alloc: Allocator,
    w: *std.Io.Writer,
    execution: ExecutionMemory,
    final_text: []const u8,
    pending_call: ?ToolCall,
) !void {
    if (execution.tool_steps.len == 0 and final_text.len == 0 and pending_call == null) return;

    try w.writeAll("### Assistant\n\n");
    var calls = std.StringHashMap(CallInfo).init(alloc);
    defer {
        var iterator = calls.valueIterator();
        while (iterator.next()) |info| alloc.free(info.hint);
        calls.deinit();
    }

    for (execution.tool_steps) |step| {
        if (step.assistant) |text| {
            if (text.len > 0) try w.print("{s}\n\n", .{text});
        }
        for (step.tool_calls) |call| {
            const hint = try extractToolCallHint(alloc, call.arguments_json);
            errdefer alloc.free(hint);
            try calls.put(call.id, .{ .name = call.name, .hint = hint });
            try writeToolCall(alloc, w, call, hint);
        }
        for (step.tool_results) |result| {
            try writeToolResult(w, result, calls.get(result.tool_call_id));
        }
    }

    if (pending_call) |call| {
        const hint = try extractToolCallHint(alloc, call.arguments_json);
        defer alloc.free(hint);
        try writeToolCall(alloc, w, call, hint);
    }
    if (final_text.len > 0) try w.print("{s}\n\n", .{final_text});
}

fn writeToolCall(alloc: Allocator, w: *std.Io.Writer, call: ToolCall, hint: []const u8) !void {
    try w.print("#### Tool Call: {s}", .{call.name});
    if (hint.len > 0) try w.print(" (`{s}`)", .{hint});
    try w.print("\n<!-- call_id: {s} -->\n```json\n", .{call.id});
    try writePrettyJson(alloc, w, call.arguments_json);
    try w.writeAll("\n```\n\n");
}

fn writeToolResult(w: *std.Io.Writer, result: PersistedToolResult, call: ?CallInfo) !void {
    const name = if (call) |info| info.name else result.tool_name;
    try w.print("<details><summary>Tool Result: {s}", .{name});
    if (call) |info| {
        if (info.hint.len > 0) try w.print(" (`{s}`)", .{info.hint});
    }
    try w.print("</summary>\n\n<!-- call_id: {s} -->\n{s}\n\n</details>\n\n", .{ result.tool_call_id, result.output });
}

fn writePrettyJson(alloc: Allocator, w: *std.Io.Writer, raw: []const u8) !void {
    const source = if (raw.len == 0) "{}" else raw;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        try w.writeAll(source);
        return;
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, w);
}

fn extractToolCallHint(alloc: Allocator, arguments_json: []const u8) ![]u8 {
    const source = if (arguments_json.len == 0) "{}" else arguments_json;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return alloc.dupe(u8, "");
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return alloc.dupe(u8, ""),
    };

    for (hint_keys) |key| {
        const value = object.get(key) orelse continue;
        if (value == .string and std.mem.trim(u8, value.string, &std.ascii.whitespace).len > 0) {
            return shorten(alloc, value.string, max_hint_bytes);
        }
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const text = entry.value_ptr.string;
        if (text.len > 0 and text.len <= max_loose_value_bytes) {
            return shorten(alloc, text, max_hint_bytes);
        }
    }
    return alloc.dupe(u8, "");
}

fn shorten(alloc: Allocator, text: []const u8, width: usize) ![]u8 {
    if (text.len <= width) return alloc.dupe(u8, text);
    var cut = width;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ text[0..cut], ellipsis });
}

const session_id_prefix = "session_";
const short_session_id_bytes = 8;

fn shortSessionId(session_id: []const u8) []const u8 {
    const unique = if (std.mem.startsWith(u8, session_id, session_id_prefix) and session_id.len > session_id_prefix.len)
        session_id[session_id_prefix.len..]
    else
        session_id;
    return unique[0..@min(unique.len, short_session_id_bytes)];
}

pub fn defaultFileName(alloc: Allocator, session_id: []const u8, timestamp_ms: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const short_id = shortSessionId(session_id);
    const cal = Calendar.of(timestamp_ms);
    try out.writer.print("fx-export-{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.md", .{
        short_id,
        cal.year,
        cal.month,
        cal.day,
        cal.hour,
        cal.minute,
        cal.second,
    });
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const Calendar = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millis: u16,

    fn of(timestamp_ms: i64) Calendar {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(timestamp_ms, 1000)) };
        const day_seconds = epoch.getDaySeconds();
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{
            .year = year_day.year,
            .month = @backingInt(month_day.month),
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
            .millis = @intCast(@mod(timestamp_ms, 1000)),
        };
    }
};

fn writeIso8601(w: *std.Io.Writer, timestamp_ms: i64) !void {
    const cal = Calendar.of(timestamp_ms);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        cal.year,
        cal.month,
        cal.day,
        cal.hour,
        cal.minute,
        cal.second,
        cal.millis,
    });
}

test "the default export name carries eight distinguishing id characters and a UTC timestamp" {
    const alloc = std.testing.allocator;
    const prefixed = try defaultFileName(alloc, "session_0f8fad5b-d9cb-469f-a165-70867728950e", 1_700_000_000_000);
    defer alloc.free(prefixed);
    try std.testing.expectEqualStrings("fx-export-0f8fad5b-20231114-221320.md", prefixed);

    const bare = try defaultFileName(alloc, "abcdefghijkl", 0);
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("fx-export-abcdefgh-19700101-000000.md", bare);

    const unsaved = try defaultFileName(alloc, "unsaved", 0);
    defer alloc.free(unsaved);
    try std.testing.expectEqualStrings("fx-export-unsaved-19700101-000000.md", unsaved);
}

test "the export body opens with front matter and an overview of topic, turns and tool calls" {
    const alloc = std.testing.allocator;
    const markdown = try render(alloc, .{
        .session_id = "session_0f8fad5b",
        .work_dir = "/work/app",
        .exported_at_ms = 1_700_000_000_000,
        .history = &.{},
    });
    defer alloc.free(markdown);
    try std.testing.expect(std.mem.startsWith(u8, markdown, "---\nsession_id: session_0f8fad5b\nexported_at: 2023-11-14T22:13:20.000Z\nwork_dir: /work/app\nmessage_count: 0\n---\n"));
    try std.testing.expect(std.mem.find(u8, markdown, "## Overview\n\n- **Topic**: (empty)\n- **Conversation**: 0 turns | 0 tool calls\n") != null);
}
