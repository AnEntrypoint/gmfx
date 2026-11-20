const std = @import("std");
const trace = @import("trace.zig");
const records = @import("records.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;

pub const marker = "fx-compactor-v1\n";
const legacy_handoff_open = "<context_handoff>";

pub const Tool = struct {
    number: usize,
    line: []const u8,
    why: []const u8 = "",
};

pub const Turn = struct {
    number: usize = 0,
    users: []const []const u8 = &.{},
    work: []const u8 = "",
    final: []const u8 = "",
    first_tool: usize = 0,
    last_tool: usize = 0,
    tools: []const Tool = &.{},
};

pub const OpenTurn = struct {
    users: []const []const u8 = &.{},
    work: []const u8 = "",
    text: []const u8 = "",
    first_tool: usize = 0,
    last_tool: usize = 0,
    tools: []const Tool = &.{},
};

pub const entry_kinds = "RFDSO";

pub fn replacedIds(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, at, "replaces ")) |found| {
        at = found + "replaces ".len;
        var words = std.mem.tokenizeAny(u8, text[at..], " ,;");
        while (words.next()) |raw| {
            const word = std.mem.trimEnd(u8, raw, ".)]");
            if (std.mem.eql(u8, word, "and")) continue;
            if (!isEntryId(word)) break;
            try out.append(arena, word);
        }
    }
    return out.items;
}

pub fn isEntryId(word: []const u8) bool {
    if (word.len < 2 or std.mem.findScalar(u8, entry_kinds, word[0]) == null) return false;
    for (word[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub const Entry = struct {
    id: []const u8,
    text: []const u8,
};

pub const Used = struct {
    kind: Kind,
    name: []const u8,
    calls: usize = 1,
    first_tool: usize = 0,
    last_tool: usize = 0,

    pub const Kind = enum { skill, mcp };
};

pub const Payload = struct {
    entries: []const Entry = &.{},
    used: []const Used = &.{},
    earlier: []const u8 = "",
    turns: []const Turn = &.{},
    open: ?OpenTurn = null,
    turn_count: usize = 0,
    tool_count: usize = 0,
    ledger_count: usize = 0,
    highest: [entry_kinds.len]usize = @splat(0),
    saved: bool = true,
    todo_list: []const u8 = "",
    cost: Cost = .{},
};

pub const todo_list_heading = "## TODO List";

pub const Cost = struct {
    duration_ms: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
};

pub fn highestIds(payload: Payload) [entry_kinds.len]usize {
    var highest = payload.highest;
    for (payload.entries) |entry| {
        if (!isEntryId(entry.id)) continue;
        const kind = std.mem.findScalar(u8, entry_kinds, entry.id[0]).?;
        const number = std.fmt.parseUnsigned(usize, entry.id[1..], 10) catch continue;
        highest[kind] = @max(highest[kind], number);
    }
    return highest;
}

pub fn wasUsed(id: []const u8, highest: [entry_kinds.len]usize) bool {
    if (!isEntryId(id)) return false;
    const kind = std.mem.findScalar(u8, entry_kinds, id[0]).?;
    const number = std.fmt.parseUnsigned(usize, id[1..], 10) catch return false;
    return number > 0 and number <= highest[kind];
}

pub fn encode(alloc: Allocator, payload: Payload) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(marker) catch return error.OutOfMemory;
    std.json.Stringify.value(payload, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn isPayload(summary: []const u8) bool {
    return std.mem.startsWith(u8, summary, marker);
}

pub fn replacesPriorContext(summary: []const u8) bool {
    return isPayload(summary) or std.mem.startsWith(u8, summary, legacy_handoff_open);
}

pub const LegacyStateRef = struct {
    handle: []const u8,
    bytes: usize,
    sha256: [32]u8,
};

const legacy_state_tag = "fx-compaction-state-v1 ";

pub fn legacyStateRef(summary: []const u8) ?LegacyStateRef {
    if (isPayload(summary)) return null;
    const start = (std.mem.find(u8, summary, legacy_state_tag) orelse return null) + legacy_state_tag.len;
    const line_end = std.mem.findScalarPos(u8, summary, start, '\n') orelse summary.len;
    var fields = std.mem.tokenizeScalar(u8, summary[start..line_end], ' ');
    const handle = fields.next() orelse return null;
    const bytes = std.fmt.parseUnsigned(usize, fields.next() orelse return null, 10) catch return null;
    const digest_hex = fields.next() orelse return null;
    if (digest_hex.len != 64) return null;
    var ref: LegacyStateRef = .{ .handle = handle, .bytes = bytes, .sha256 = undefined };
    _ = std.fmt.hexToBytes(&ref.sha256, digest_hex) catch return null;
    return ref;
}

pub fn parseLegacyState(arena: Allocator, ref: LegacyStateRef, bytes: []const u8) Allocator.Error!?Payload {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (bytes.len != ref.bytes or !std.mem.eql(u8, &digest, &ref.sha256)) {
        trace.log(true, "earlier state file does not match its checkpoint handle={s} bytes={d}", .{ ref.handle, bytes.len });
        return null;
    }
    const State = struct { summary: []const u8, users: []const []const u8 };
    const state = json_decode.parseFromSliceLeaky(State, arena, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            trace.log(true, "earlier state file unreadable handle={s} err={s}", .{ ref.handle, @errorName(err) });
            return null;
        },
    };
    const turns = try arena.alloc(Turn, state.users.len);
    for (turns, 0..) |*turn, index| turn.* = .{ .users = state.users[index .. index + 1] };
    return .{ .earlier = state.summary, .turns = turns };
}

pub fn parse(arena: Allocator, summary: []const u8) Allocator.Error!?Payload {
    if (!isPayload(summary)) return null;
    const payload = json_decode.parseFromSliceLeaky(Payload, arena, summary[marker.len..], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unreadable(summary, @errorName(err)),
    };
    const counts = [_]usize{ payload.turn_count, payload.tool_count, payload.ledger_count };
    if (std.mem.max(usize, &counts) > records.max_number) return unreadable(summary, "CountOutOfRange");
    return payload;
}

fn unreadable(summary: []const u8, reason: []const u8) ?Payload {
    debug_trace.logf("context_compaction", "checkpoint payload unreadable bytes={d} err={s}; using its raw text", .{ summary.len, reason });
    return null;
}

pub fn render(alloc: Allocator, payload: Payload) Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.appendSlice(alloc, "<compacted_conversation>\nThis is the earlier part of this conversation, compacted. The user's messages and the assistant's final replies shown here are exact. " ++
        "What the assistant did in between is summarized, and each tool call has a line saying what it was and what it showed.\n\n");
    if (payload.ledger_count > 0) {
        try text.appendSlice(alloc, "Earlier compactions are saved whole as ");
        try appendRange(alloc, &text, 'L', 1, payload.ledger_count);
        try text.appendSlice(alloc, ", with their exact messages, notes and entries; open one with read_tool_result when the work needs it.");
        if (payload.earlier.len > 0) try text.print(alloc, " In short:\n{s}", .{payload.earlier});
        try text.appendSlice(alloc, "\n\n");
    } else if (payload.earlier.len > 0) {
        try text.print(alloc, "Earlier summary:\n{s}\n\n", .{payload.earlier});
    }
    for (payload.turns) |turn| try renderTurn(alloc, &text, turn);
    if (payload.open) |open| {
        try text.appendSlice(alloc, "Turn in progress, whose first user message follows this:\n");
        for (open.users) |user| try text.print(alloc, "User, added while the assistant worked:\n{s}\n\n", .{user});
        if (open.work.len > 0) try text.print(alloc, "Assistant, in between so far:\n{s}\n\n", .{open.work});
        try appendTools(alloc, &text, "Its tools so far", open.tools, open.first_tool, open.last_tool);
    }
    try appendEntries(alloc, &text, payload.entries);
    try appendUsed(alloc, &text, payload.used);
    try appendCheckNote(alloc, &text, payload);
    try appendSavedLine(alloc, &text, payload);
    const todo_list = std.mem.trim(u8, payload.todo_list, "\n");
    if (todo_list.len > 0) try text.print(alloc, todo_list_heading ++ "\n{s}\n\n", .{todo_list});
    try text.appendSlice(alloc, "</compacted_conversation>\n");
    return text.toOwnedSlice(alloc);
}

fn renderTurn(alloc: Allocator, text: *std.ArrayList(u8), turn: Turn) Allocator.Error!void {
    if (turn.number > 0) try text.print(alloc, "Turn {d}\n", .{turn.number});
    for (turn.users, 0..) |user, index| {
        try appendLabel(alloc, text, "User", turn.number);
        if (index > 0) try text.appendSlice(alloc, ", added while the assistant worked");
        try text.print(alloc, ":\n{s}\n\n", .{user});
    }
    if (turn.work.len > 0) {
        try appendLabel(alloc, text, "Assistant", turn.number);
        try text.print(alloc, ", in between:\n{s}\n\n", .{turn.work});
    }
    try appendTools(alloc, text, "Tools", turn.tools, turn.first_tool, turn.last_tool);
    if (turn.final.len > 0) {
        try appendLabel(alloc, text, "Assistant", turn.number);
        try text.print(alloc, ", final reply:\n{s}\n\n", .{turn.final});
    }
}

fn appendTools(alloc: Allocator, text: *std.ArrayList(u8), heading: []const u8, tools: []const Tool, first: usize, last: usize) Allocator.Error!void {
    if (tools.len > 0) {
        try text.print(alloc, "{s}:\n", .{heading});
        for (tools) |tool| {
            try text.print(alloc, "  T{d} {s}", .{ tool.number, tool.line });
            if (tool.why.len > 0) try text.print(alloc, ": {s}", .{tool.why});
            try text.append(alloc, '\n');
        }
        try text.append(alloc, '\n');
    } else if (first > 0) {
        try text.print(alloc, "{s}: ", .{heading});
        try appendRange(alloc, text, 'T', first, last);
        try text.appendSlice(alloc, "\n\n");
    }
}

fn appendEntries(alloc: Allocator, text: *std.ArrayList(u8), entries: []const Entry) Allocator.Error!void {
    var scratch_state: std.heap.ArenaAllocator = .init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const replaced_by = try scratch.alloc(?[]const u8, entries.len);
    @memset(replaced_by, null);
    for (entries) |entry| for (try replacedIds(scratch, entry.text)) |id| {
        for (entries, replaced_by) |older, *slot| if (std.mem.eql(u8, older.id, id)) {
            slot.* = entry.id;
        };
    };
    const Section = struct { heading: []const u8, kinds: []const u8 };
    const sections = [_]Section{
        .{ .heading = "Rules of the session:", .kinds = "R" },
        .{ .heading = "Facts of the session:", .kinds = "F" },
        .{ .heading = "Decisions:", .kinds = "D" },
        .{ .heading = "Status and open:", .kinds = "SO" },
    };
    for (sections) |section| {
        var written: usize = 0;
        for (entries, replaced_by) |entry, replacer| {
            if (entry.id.len == 0 or std.mem.findScalar(u8, section.kinds, entry.id[0]) == null) continue;
            if (written == 0) try text.print(alloc, "{s}\n", .{section.heading});
            try text.appendSlice(alloc, entry.text);
            if (replacer) |id| try text.print(alloc, replaced_mark ++ "{s})", .{id});
            try text.append(alloc, '\n');
            written += 1;
        }
        if (written > 0) try text.append(alloc, '\n');
    }
}

pub const check_mark = " [check: ";

pub const replaced_mark = " (replaced by ";

fn appendCheckNote(alloc: Allocator, text: *std.ArrayList(u8), payload: Payload) Allocator.Error!void {
    if (!hasCheckMark(payload)) return;
    try text.appendSlice(alloc, "A note or entry marked [check: ...] says something code could not confirm in the saved turns and tool calls; confirm it there before relying on it.\n");
}

fn hasCheckMark(payload: Payload) bool {
    for (payload.entries) |entry| if (isMarked(entry.text)) return true;
    for (payload.turns) |turn| if (isMarked(turn.work) or toolsMarked(turn.tools)) return true;
    if (payload.open) |open| return isMarked(open.work) or toolsMarked(open.tools);
    return false;
}

fn isMarked(text: []const u8) bool {
    return std.mem.find(u8, text, check_mark) != null;
}

fn toolsMarked(tools: []const Tool) bool {
    for (tools) |tool| if (isMarked(tool.why)) return true;
    return false;
}

fn appendLabel(alloc: Allocator, text: *std.ArrayList(u8), who: []const u8, number: usize) Allocator.Error!void {
    try text.appendSlice(alloc, who);
    if (number > 0) try text.print(alloc, " {d}", .{number});
}

fn appendRange(alloc: Allocator, text: *std.ArrayList(u8), prefix: u8, first: usize, last: usize) Allocator.Error!void {
    try text.print(alloc, "{c}{d}", .{ prefix, first });
    if (last > first) try text.print(alloc, "–{c}{d}", .{ prefix, last });
}

fn appendUsed(alloc: Allocator, text: *std.ArrayList(u8), used: []const Used) Allocator.Error!void {
    if (used.len == 0) return;
    try text.appendSlice(alloc, "Skills and MCP tools used:\n");
    for (used) |entry| {
        try text.print(alloc, "- {s} {s}: ", .{ if (entry.kind == .skill) "skill" else "MCP tool", entry.name });
        if (entry.calls == 1) {
            try text.print(alloc, "1 call, T{d}\n", .{entry.first_tool});
        } else {
            try text.print(alloc, "{d} calls, first T{d}, last T{d}\n", .{ entry.calls, entry.first_tool, entry.last_tool });
        }
    }
    try text.appendSlice(alloc, "\n");
}

fn appendSavedLine(alloc: Allocator, text: *std.ArrayList(u8), payload: Payload) Allocator.Error!void {
    if (!payload.saved) return;
    const Part = struct { count: usize, one: []const u8, many: []const u8, letter: u8 };
    const parts = [_]Part{
        .{ .count = payload.turn_count, .one = "turn ", .many = "turns ", .letter = 'M' },
        .{ .count = payload.tool_count, .one = "tool call ", .many = "tool calls ", .letter = 'T' },
        .{ .count = payload.ledger_count, .one = "earlier compaction ", .many = "earlier compactions ", .letter = 'L' },
    };
    var shown: usize = 0;
    for (parts) |part| shown += @intFromBool(part.count > 0);
    if (shown == 0) return;
    try text.appendSlice(alloc, "Saved word for word: ");
    var index: usize = 0;
    for (parts) |part| if (part.count > 0) {
        if (index > 0) try text.appendSlice(alloc, if (index + 1 == shown) " and " else ", ");
        try text.appendSlice(alloc, if (part.count == 1) part.one else part.many);
        try appendRange(alloc, text, part.letter, 1, part.count);
        index += 1;
    };
    try text.appendSlice(alloc, ". Search them by text, or open one by its ID (like ");
    index = 0;
    for (parts) |part| if (part.count > 0) {
        if (index > 0) try text.appendSlice(alloc, if (index + 1 == shown) " or " else ", ");
        try text.print(alloc, "{c}{d}", .{ part.letter, part.count });
        index += 1;
    };
    try text.appendSlice(alloc, "), with read_tool_result.\n");
}

pub fn shapeProblem(earlier: Payload, payload: Payload) ?[]const u8 {
    if (payload.turns.len < earlier.turns.len) return "an earlier turn is missing";
    for (earlier.turns, payload.turns[0..earlier.turns.len]) |before, after| {
        if (!sameTurn(before, after)) return "an earlier turn changed";
    }
    if (payload.ledger_count < earlier.ledger_count) return "a saved ledger is missing";
    for (payload.highest, earlier.highest) |after, before| if (after < before) return "the highest entry numbers went down";
    if (payload.entries.len < earlier.entries.len) return "an earlier entry is missing";
    for (earlier.entries, payload.entries[0..earlier.entries.len]) |before, after| {
        if (!std.mem.eql(u8, before.id, after.id) or !std.mem.eql(u8, before.text, after.text)) return "an earlier entry changed";
    }
    var next_turn = earlier.turn_count + 1;
    var previous_tool: usize = 0;
    var new_tools: usize = 0;
    for (payload.turns[earlier.turns.len..]) |turn| {
        if (turn.number != next_turn) return "the new turns are not numbered in order";
        next_turn += 1;
        if (turn.users.len == 0) return "a new turn has no user message";
        if (toolsProblem(turn.tools, turn.first_tool, turn.last_tool, payload.tool_count, &previous_tool)) |problem| return problem;
        new_tools += linesAbove(turn.tools, earlier.tool_count);
    }
    if (next_turn - 1 != payload.turn_count) return "the turn count does not match the turns";
    if (payload.open) |open| {
        if (toolsProblem(open.tools, open.first_tool, open.last_tool, payload.tool_count, &previous_tool)) |problem| return problem;
        new_tools += linesAbove(open.tools, earlier.tool_count);
    }
    if (earlier.tool_count + new_tools != payload.tool_count) return "a new tool call has no line";
    for (payload.entries, 0..) |entry, index| {
        if (!isEntryId(entry.id)) return "an entry has a malformed ID";
        if (!std.mem.startsWith(u8, entry.text, entry.id)) return "an entry does not start with its ID";
        for (payload.entries[0..index]) |other| if (std.mem.eql(u8, other.id, entry.id)) return "two entries share an ID";
    }
    return null;
}

fn sameTurn(a: Turn, b: Turn) bool {
    if (a.number != b.number or a.first_tool != b.first_tool or a.last_tool != b.last_tool) return false;
    if (!std.mem.eql(u8, a.work, b.work) or !std.mem.eql(u8, a.final, b.final)) return false;
    if (a.users.len != b.users.len or a.tools.len != b.tools.len) return false;
    for (a.users, b.users) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    for (a.tools, b.tools) |x, y| {
        if (x.number != y.number or !std.mem.eql(u8, x.line, y.line) or !std.mem.eql(u8, x.why, y.why)) return false;
    }
    return true;
}

fn toolsProblem(tools: []const Tool, first: usize, last: usize, count: usize, previous: *usize) ?[]const u8 {
    if (first > last or last > count) return "a turn's tool calls are out of range";
    for (tools) |tool| {
        if (tool.number < first or tool.number > last) return "a tool line is outside its turn";
        if (tool.number <= previous.*) return "the tool lines are out of order";
        if (tool.line.len == 0) return "a tool line is empty";
        previous.* = tool.number;
    }
    return null;
}

fn linesAbove(tools: []const Tool, number: usize) usize {
    var count: usize = 0;
    for (tools) |tool| count += @intFromBool(tool.number > number);
    return count;
}

pub fn modelText(alloc: Allocator, summary: []const u8) Allocator.Error!?[]u8 {
    if (!isPayload(summary)) return null;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const payload = try parse(arena_state.allocator(), summary) orelse
        return try alloc.dupe(u8, summary[marker.len..]);
    return try render(alloc, payload);
}

const testing = std.testing;

const sample_payload: Payload = .{
    .earlier = "The assistant set up the repo and verified the build [M1].",
    .turns = &.{
        .{
            .number = 2,
            .users = &.{ "Fix the build.\nIt fails on main.", "also check the tests" },
            .work = "Found a missing semicolon (T4), fixed it, and ran the tests (T5).",
            .final = "Fixed. The build and all 12 tests pass.",
            .first_tool = 4,
            .last_tool = 5,
            .tools = &.{
                .{ .number = 4, .line = "shell zig build (failed, exit 1, 3 lines)", .why = "built to see the failure; a missing semicolon at src/a.zig:4" },
                .{ .number = 5, .line = "shell zig build test (exit 0, 12 lines)" },
            },
        },
        .{ .number = 3, .users = &.{"thanks"}, .final = "You're welcome." },
    },
    .entries = &.{
        .{ .id = "S1", .text = "S1: the build and tests pass (T5)" },
        .{ .id = "R1", .text = "R1 [M2]: \"also check the tests\"" },
        .{ .id = "F1", .text = "F1 (T4): src/a.zig:4 was missing a semicolon" },
        .{ .id = "O1", .text = "O1: nothing open" },
    },
    .turn_count = 3,
    .tool_count = 5,
};

test "payload checkpoints round trip and render each turn in order, then the entries" {
    const alloc = testing.allocator;
    const saved = try encode(alloc, sample_payload);
    defer alloc.free(saved);
    try testing.expect(isPayload(saved));
    try testing.expect(replacesPriorContext(saved));

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const back = (try parse(arena.allocator(), saved)).?;
    try testing.expectEqual(@as(usize, 2), back.turns.len);
    try testing.expectEqualStrings("also check the tests", back.turns[0].users[1]);
    try testing.expectEqualStrings("shell zig build test (exit 0, 12 lines)", back.turns[0].tools[1].line);
    try testing.expectEqualStrings("F1", back.entries[2].id);
    try testing.expectEqual(@as(usize, 5), back.tool_count);
    try testing.expect(back.open == null);

    const text = (try modelText(alloc, saved)).?;
    defer alloc.free(text);
    const expected =
        \\Earlier summary:
        \\The assistant set up the repo and verified the build [M1].
        \\
        \\Turn 2
        \\User 2:
        \\Fix the build.
        \\It fails on main.
        \\
        \\User 2, added while the assistant worked:
        \\also check the tests
        \\
        \\Assistant 2, in between:
        \\Found a missing semicolon (T4), fixed it, and ran the tests (T5).
        \\
        \\Tools:
        \\  T4 shell zig build (failed, exit 1, 3 lines): built to see the failure; a missing semicolon at src/a.zig:4
        \\  T5 shell zig build test (exit 0, 12 lines)
        \\
        \\Assistant 2, final reply:
        \\Fixed. The build and all 12 tests pass.
        \\
        \\Turn 3
        \\User 3:
        \\thanks
        \\
        \\Assistant 3, final reply:
        \\You're welcome.
        \\
        \\Rules of the session:
        \\R1 [M2]: "also check the tests"
        \\
        \\Facts of the session:
        \\F1 (T4): src/a.zig:4 was missing a semicolon
        \\
        \\Status and open:
        \\S1: the build and tests pass (T5)
        \\O1: nothing open
        \\
        \\Saved word for word: turns M1–M3 and tool calls T1–T5. Search them by text, or open one by its ID (like M3 or T5), with read_tool_result.
        \\</compacted_conversation>
        \\
    ;
    try testing.expect(std.mem.endsWith(u8, text, expected));
    try testing.expect(std.mem.startsWith(u8, text, "<compacted_conversation>\n"));
    try testing.expect(std.mem.find(u8, text, marker) == null);
    try testing.expect(std.mem.find(u8, text, "\"turn_count\"") == null);
}

test "a checkpoint keeps its open todos under a TODO List heading and records what the compaction cost" {
    const alloc = testing.allocator;
    var payload = sample_payload;
    payload.todo_list = "- [in_progress] t1 write the parser\n- [pending] t4 add the test\n";
    payload.cost = .{ .duration_ms = 1_250, .input_tokens = 9_000, .output_tokens = 700, .cache_read_tokens = 4_000 };
    const saved = try encode(alloc, payload);
    defer alloc.free(saved);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const back = (try parse(arena.allocator(), saved)).?;
    try testing.expectEqualStrings(payload.todo_list, back.todo_list);
    try testing.expectEqual(@as(u64, 1_250), back.cost.duration_ms);
    try testing.expectEqual(@as(u64, 9_000), back.cost.input_tokens);
    try testing.expectEqual(@as(u64, 700), back.cost.output_tokens);
    try testing.expectEqual(@as(u64, 4_000), back.cost.cache_read_tokens);
    try testing.expectEqual(@as(u64, 0), back.cost.cache_write_tokens);

    const text = (try modelText(alloc, saved)).?;
    defer alloc.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "read_tool_result.\n## TODO List\n- [in_progress] t1 write the parser\n- [pending] t4 add the test\n\n</compacted_conversation>\n"));
    try testing.expect(std.mem.find(u8, text, "duration_ms") == null);

    const without = try render(alloc, sample_payload);
    defer alloc.free(without);
    try testing.expect(std.mem.find(u8, without, todo_list_heading) == null);

    const older = (try parse(arena.allocator(), marker ++ "{\"turn_count\":1}")).?;
    try testing.expectEqualStrings("", older.todo_list);
    try testing.expectEqual(@as(u64, 0), older.cost.duration_ms);
}

test "the turn in progress shows its summary, added messages and tools" {
    const alloc = testing.allocator;

    const text = try render(alloc, .{
        .turns = &.{},
        .open = .{ .users = &.{"use the staging db"}, .work = "Ran the migration dry run (T1).", .text = "exact text", .first_tool = 1, .last_tool = 1 },
        .tool_count = 1,
    });
    defer alloc.free(text);
    try testing.expect(std.mem.find(u8, text, "Turn in progress, whose first user message follows this:\nUser, added while the assistant worked:\nuse the staging db\n") != null);
    try testing.expect(std.mem.find(u8, text, "Assistant, in between so far:\nRan the migration dry run (T1).\n") != null);
    try testing.expect(std.mem.find(u8, text, "Its tools so far: T1\n") != null);
    try testing.expect(std.mem.find(u8, text, "exact text") == null);
    try testing.expect(std.mem.find(u8, text, "Saved word for word: tool call T1. Search them by text, or open one by its ID (like T1)") != null);
}

test "an entry a later one replaces is shown replaced, and check marks are explained" {
    const alloc = testing.allocator;
    const marked = try render(alloc, .{ .entries = &.{
        .{ .id = "S1", .text = "S1 (T1): tests fail" },
        .{ .id = "D1", .text = "D1 (M1): cache the index" },
        .{ .id = "S2", .text = "S2 (T2): tests pass; replaces S1 and D1." },
        .{ .id = "F1", .text = "F1 (T2): 142 tests [check: not in the saved record: 142]" },
    }, .turn_count = 1, .tool_count = 2 });
    defer alloc.free(marked);
    try testing.expect(std.mem.find(u8, marked, "S1 (T1): tests fail (replaced by S2)\n") != null);
    try testing.expect(std.mem.find(u8, marked, "D1 (M1): cache the index (replaced by S2)\n") != null);
    try testing.expect(std.mem.find(u8, marked, "S2 (T2): tests pass; replaces S1 and D1.\n") != null);
    try testing.expect(std.mem.find(u8, marked, "A note or entry marked [check: ...]") != null);

    const clean = try render(alloc, .{ .entries = &.{.{ .id = "F1", .text = "F1 (T2): 141 tests" }}, .turn_count = 1, .tool_count = 2 });
    defer alloc.free(clean);
    try testing.expect(std.mem.find(u8, clean, "[check:") == null);
    try testing.expect(std.mem.find(u8, clean, "replaced by") == null);
}

test "the shape check passes what compaction builds and names what breaks it" {
    const first_tools = [_]Tool{.{ .number = 1, .line = "shell make (2 bytes)" }};
    const earlier: Payload = .{
        .turns = &.{.{ .number = 1, .users = &.{"build it"}, .final = "Built.", .first_tool = 1, .last_tool = 1, .tools = &first_tools }},
        .entries = &.{.{ .id = "F1", .text = "F1 (T1): make works" }},
        .turn_count = 1,
        .tool_count = 1,
    };
    const new_tools = [_]Tool{ .{ .number = 2, .line = "shell make test (3 lines)" }, .{ .number = 3, .line = "read_file a.zig (9 lines)" } };
    const good: Payload = .{
        .turns = &.{ earlier.turns[0], .{ .number = 2, .users = &.{"test it"}, .final = "Tested.", .first_tool = 2, .last_tool = 3, .tools = &new_tools } },
        .entries = &.{ earlier.entries[0], .{ .id = "S1", .text = "S1 (T2): tests pass" } },
        .turn_count = 2,
        .tool_count = 3,
    };
    try testing.expect(shapeProblem(earlier, good) == null);

    var bad = good;
    bad.turns = &.{ .{ .number = 1, .users = &.{"build it again"}, .final = "Built.", .first_tool = 1, .last_tool = 1, .tools = &first_tools }, good.turns[1] };
    try testing.expectEqualStrings("an earlier turn changed", shapeProblem(earlier, bad).?);
    bad = good;
    bad.entries = &.{ .{ .id = "F1", .text = "F1 (T1): make is broken" }, good.entries[1] };
    try testing.expectEqualStrings("an earlier entry changed", shapeProblem(earlier, bad).?);
    bad = good;
    bad.turns = &.{ earlier.turns[0], .{ .number = 3, .users = &.{"test it"}, .first_tool = 2, .last_tool = 3, .tools = &new_tools } };
    try testing.expectEqualStrings("the new turns are not numbered in order", shapeProblem(earlier, bad).?);
    bad = good;
    bad.turns = &.{ earlier.turns[0], .{ .number = 2, .users = &.{"test it"}, .first_tool = 2, .last_tool = 3, .tools = new_tools[0..1] } };
    try testing.expectEqualStrings("a new tool call has no line", shapeProblem(earlier, bad).?);
    bad = good;
    bad.turn_count = 5;
    try testing.expectEqualStrings("the turn count does not match the turns", shapeProblem(earlier, bad).?);
    bad = good;
    bad.entries = &.{ earlier.entries[0], .{ .id = "F1", .text = "F1 (T2): again" } };
    try testing.expectEqualStrings("two entries share an ID", shapeProblem(earlier, bad).?);
    bad = good;
    bad.entries = &.{ earlier.entries[0], .{ .id = "S1", .text = "tests pass" } };
    try testing.expectEqualStrings("an entry does not start with its ID", shapeProblem(earlier, bad).?);

    var folded = earlier;
    folded.ledger_count = 2;
    folded.highest = .{ 0, 4, 0, 0, 0 };
    var kept = good;
    kept.ledger_count = 2;
    kept.highest = folded.highest;
    try testing.expect(shapeProblem(folded, kept) == null);
    bad = kept;
    bad.ledger_count = 1;
    try testing.expectEqualStrings("a saved ledger is missing", shapeProblem(folded, bad).?);
    bad = kept;
    bad.highest = .{ 0, 3, 0, 0, 0 };
    try testing.expectEqualStrings("the highest entry numbers went down", shapeProblem(folded, bad).?);
}

test "the saved line names only what can be opened" {
    const alloc = testing.allocator;
    const none = try render(alloc, .{ .turns = &.{.{ .number = 1, .users = &.{"hi"} }} });
    defer alloc.free(none);
    try testing.expect(std.mem.find(u8, none, "Saved") == null);
    const unsaved = try render(alloc, .{ .turn_count = 4, .tool_count = 9, .saved = false });
    defer alloc.free(unsaved);
    try testing.expect(std.mem.find(u8, unsaved, "read_tool_result") == null);
    const one = try render(alloc, .{ .turn_count = 1 });
    defer alloc.free(one);
    try testing.expect(std.mem.find(u8, one, "Saved word for word: turn M1. Search them by text, or open one by its ID (like M1)") != null);
}

test "older checkpoints are recognized but not parsed" {
    const alloc = testing.allocator;
    const handoff = legacy_handoff_open ++ "\n## Conversation summary\n> earlier\n</context_handoff>";
    try testing.expect(replacesPriorContext(handoff));
    try testing.expect(!isPayload(handoff));
    try testing.expect(try modelText(alloc, handoff) == null);
    try testing.expect(!replacesPriorContext("Budget trimmed summary"));
}

test "a damaged payload falls back to its raw text" {
    const alloc = testing.allocator;
    const damaged = marker ++ "{\"turns\":[\"cut off";
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try testing.expect(try parse(arena.allocator(), damaged) == null);
    const text = (try modelText(alloc, damaged)).?;
    defer alloc.free(text);
    try testing.expectEqualStrings("{\"turns\":[\"cut off", text);
}

test "older checkpoints yield their exact users from the named state file" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state = "{\"version\":1,\"summary\":\"Earlier work.\",\"users\":[\"okay so you saying that if 2 GB exeeds then what happens ? \",\"yes\"],\"archives\":[]}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(state, &digest, .{});
    const summary = try arena.print("{s}\n## Conversation summary\n> fx-compaction-state-v1 result-state-1-2.txt {d} {x}\n> Task state:\n", .{ legacy_handoff_open, state.len, digest });
    const ref = legacyStateRef(summary).?;
    try testing.expectEqualStrings("result-state-1-2.txt", ref.handle);
    const payload = (try parseLegacyState(arena, ref, state)).?;
    try testing.expectEqual(@as(usize, 2), payload.turns.len);
    try testing.expectEqualStrings("okay so you saying that if 2 GB exeeds then what happens ? ", payload.turns[0].users[0]);
    try testing.expectEqual(@as(usize, 0), payload.turns[0].number);
    try testing.expectEqualStrings("yes", payload.turns[1].users[0]);
    try testing.expectEqualStrings("Earlier work.", payload.earlier);
    try testing.expectEqual(@as(usize, 0), payload.tool_count);
    try testing.expectEqual(@as(usize, 0), payload.turn_count);

    try testing.expect(try parseLegacyState(arena, ref, state[0 .. state.len - 1]) == null);
    try testing.expect(legacyStateRef(legacy_handoff_open ++ "no state here") == null);
    try testing.expect(legacyStateRef(marker ++ "{}") == null);
}
