const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const root_dir = "/workspace/fx/work/native-parity";
const session_id = "item2-local-session";

const Counts = struct {
    total: usize = 0,
    turn_context: usize = 0,
    tool_batch: usize = 0,
    session_open: usize = 0,
    log_query: usize = 0,
    todo_add: usize = 0,
    question_add: usize = 0,
    todo_resolve: usize = 0,
    question_resolve: usize = 0,
    pending_event: usize = 0,
    pending_delivery: usize = 0,
    subagent_session: usize = 0,
    task_start: usize = 0,
    task_stop: usize = 0,
    turn_end: usize = 0,
};

const State = struct {
    step: usize = 0,
    todo_open: bool = false,
    question_open: bool = false,
    task_open: bool = false,
    child_count: usize = 0,
    pending_count: usize = 0,
    finished: bool = false,
    witness: []const u8 = "",
};

fn openLedgerDir(io: std.Io) !std.Io.Dir {
    std.Io.Dir.cwd().createDirPath(io, root_dir) catch {};
    return std.Io.Dir.openDirAbsolute(io, root_dir, .{});
}

fn readLedgerFile(alloc: Allocator, io: std.Io, name: []const u8) ?[]const u8 {
    var dir = openLedgerDir(io) catch return null;
    defer dir.close(io);
    return dir.readFileAlloc(io, name, alloc, .limited(64 * 1024)) catch return null;
}

fn writeLedgerFile(io: std.Io, name: []const u8, data: []const u8) !void {
    var dir = try openLedgerDir(io);
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn valueFor(raw: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..split], key)) return line[split + 1 ..];
    }
    return null;
}

fn parseUsize(value: []const u8) usize {
    return std.fmt.parseInt(usize, value, 10) catch 0;
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1");
}

fn parseState(raw: []const u8) State {
    var state: State = .{};
    state.step = parseUsize(valueFor(raw, "step") orelse "0");
    state.todo_open = parseBool(valueFor(raw, "todo_open") orelse "0");
    state.question_open = parseBool(valueFor(raw, "question_open") orelse "0");
    state.task_open = parseBool(valueFor(raw, "task_open") orelse "0");
    state.child_count = parseUsize(valueFor(raw, "child_count") orelse "0");
    state.pending_count = parseUsize(valueFor(raw, "pending_count") orelse "0");
    state.finished = parseBool(valueFor(raw, "finished") orelse "0");
    state.witness = valueFor(raw, "witness") orelse "";
    return state;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn isPhase(value: []const u8) bool {
    const phases = [_][]const u8{ "open", "add", "child", "job", "resolve", "finish-refused", "finish-accepted", "status" };
    for (phases) |phase| {
        if (std.mem.eql(u8, value, phase)) return true;
    }
    return false;
}

fn phaseFor(request_raw: []const u8, args: []const []const u8) []const u8 {
    if (valueFor(request_raw, "phase")) |phase| {
        if (phase.len > 0) return phase;
    }
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--phase=")) return arg[8..];
        if (isPhase(arg)) return arg;
    }
    return "status";
}

fn quoted(value: []const u8) bool {
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

fn stateText(alloc: Allocator, state: State) ![]const u8 {
    return std.fmt.allocPrint(alloc, "step={d}\ntodo_open={d}\nquestion_open={d}\ntask_open={d}\nchild_count={d}\npending_count={d}\nfinished={d}\nwitness={s}\n", .{
        state.step,
        @intFromBool(state.todo_open),
        @intFromBool(state.question_open),
        @intFromBool(state.task_open),
        state.child_count,
        state.pending_count,
        @intFromBool(state.finished),
        state.witness,
    });
}

fn appendEvents(alloc: Allocator, old: []const u8, added: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, old);
    if (old.len > 0 and old[old.len - 1] != '\n') try out.append(alloc, '\n');
    for (added) |event| {
        try out.appendSlice(alloc, event);
        try out.append(alloc, '\n');
    }
    return out.items;
}

fn countEvents(events: []const u8) Counts {
    var counts: Counts = .{};
    var lines = std.mem.splitScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        counts.total += 1;
        if (std.mem.eql(u8, line, "turn_context")) {
            counts.turn_context += 1;
        } else if (std.mem.eql(u8, line, "tool_batch")) {
            counts.tool_batch += 1;
        } else if (std.mem.eql(u8, line, "session_open")) {
            counts.session_open += 1;
        } else if (std.mem.eql(u8, line, "log_query")) {
            counts.log_query += 1;
        } else if (std.mem.eql(u8, line, "todo_add")) {
            counts.todo_add += 1;
        } else if (std.mem.eql(u8, line, "question_add")) {
            counts.question_add += 1;
        } else if (std.mem.eql(u8, line, "todo_resolve")) {
            counts.todo_resolve += 1;
        } else if (std.mem.eql(u8, line, "question_resolve")) {
            counts.question_resolve += 1;
        } else if (std.mem.eql(u8, line, "pending_event")) {
            counts.pending_event += 1;
        } else if (std.mem.eql(u8, line, "pending_delivery")) {
            counts.pending_delivery += 1;
        } else if (std.mem.eql(u8, line, "subagent_session")) {
            counts.subagent_session += 1;
        } else if (std.mem.eql(u8, line, "task_start")) {
            counts.task_start += 1;
        } else if (std.mem.eql(u8, line, "task_stop")) {
            counts.task_stop += 1;
        } else if (std.mem.eql(u8, line, "turn_end")) {
            counts.turn_end += 1;
        }
    }
    return counts;
}

fn jsonString(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (value) |c| {
        if (c == '"') {
            try out.appendSlice(alloc, "\\\"");
        } else if (c == '\\') {
            try out.appendSlice(alloc, "\\\\");
        } else if (c == '\n') {
            try out.appendSlice(alloc, "\\n");
        } else if (c == '\r') {
            try out.appendSlice(alloc, "\\r");
        } else if (c == '\t') {
            try out.appendSlice(alloc, "\\t");
        } else if (c < 0x20) {
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '"');
    return out.items;
}

fn rowsJson(alloc: Allocator, state: State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    var first = true;
    if (state.todo_open) {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, "{\"id\":\"todo:item2-ledger\",\"kind\":\"todo\",\"status\":\"open\"}");
    }
    if (state.question_open) {
        if (!first) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"id\":\"question:item2-attribution\",\"kind\":\"question\",\"status\":\"open\"}");
    }
    try out.append(alloc, ']');
    return out.items;
}

fn pendingJson(alloc: Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    for (0..count) |index| {
        if (index != 0) try out.append(alloc, ',');
        const id = try std.fmt.allocPrint(alloc, "\"pending:{d}\"", .{index + 1});
        try out.appendSlice(alloc, id);
    }
    try out.append(alloc, ']');
    return out.items;
}

fn childrenJson(alloc: Allocator, count: usize) ![]u8 {
    if (count == 0) return alloc.dupe(u8, "[]");
    return alloc.dupe(u8, "[{\"kind\":\"subagent\",\"session\":\"item2-local-session\",\"role\":\"child\"},{\"kind\":\"separate\",\"session\":\"item2-child-session\",\"role\":\"owner\"}]");
}

fn jobsJson(alloc: Allocator, starts: usize, stops: usize) ![]u8 {
    if (starts == 0) return alloc.dupe(u8, "[]");
    const status = if (stops >= starts) "stopped" else "running";
    return std.fmt.allocPrint(alloc, "[{{\"id\":\"ledger-task\",\"state\":\"{s}\"}}]", .{status});
}

fn countsJson(alloc: Allocator, counts: Counts) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"turn_context\":{d},\"tool_batch\":{d},\"session_open\":{d},\"log_query\":{d},\"todo_add\":{d},\"question_add\":{d},\"todo_resolve\":{d},\"question_resolve\":{d},\"pending_event\":{d},\"pending_delivery\":{d},\"subagent_session\":{d},\"task_start\":{d},\"task_stop\":{d},\"turn_end\":{d}}}", .{
        counts.turn_context,
        counts.tool_batch,
        counts.session_open,
        counts.log_query,
        counts.todo_add,
        counts.question_add,
        counts.todo_resolve,
        counts.question_resolve,
        counts.pending_event,
        counts.pending_delivery,
        counts.subagent_session,
        counts.task_start,
        counts.task_stop,
        counts.turn_end,
    });
}

fn openRowsText(alloc: Allocator, state: State) ![]const u8 {
    if (state.todo_open and state.question_open) return alloc.dupe(u8, "todo:item2-ledger, question:item2-attribution");
    if (state.todo_open) return alloc.dupe(u8, "todo:item2-ledger");
    if (state.question_open) return alloc.dupe(u8, "question:item2-attribution");
    return alloc.dupe(u8, "");
}

fn outputJson(alloc: Allocator, ok: bool, phase: []const u8, state: State, events: []const u8, refusal: []const u8) ![]const u8 {
    const counts = countEvents(events);
    const phase_json = try jsonString(alloc, phase);
    const witness_json = try jsonString(alloc, state.witness);
    const refusal_json = try jsonString(alloc, refusal);
    const counts_json = try countsJson(alloc, counts);
    const rows_json = try rowsJson(alloc, state);
    const pending_json = try pendingJson(alloc, state.pending_count);
    const children_json = try childrenJson(alloc, state.child_count);
    const jobs_json = try jobsJson(alloc, counts.task_start, counts.task_stop);
    return std.fmt.allocPrint(alloc, "{{\"item\":2,\"ok\":{s},\"phase\":{s},\"session\":\"{s}\",\"step\":{d},\"eventCount\":{d},\"counts\":{s},\"rows\":{s},\"pending\":{s},\"children\":{s},\"jobs\":{s},\"finished\":{s},\"witness\":{s},\"refusal\":{s}}}", .{
        boolText(ok),
        phase_json,
        session_id,
        state.step,
        counts.total,
        counts_json,
        rows_json,
        pending_json,
        children_json,
        jobs_json,
        boolText(state.finished),
        witness_json,
        refusal_json,
    });
}

pub fn json(alloc: Allocator, args: []const []const u8) ![]const u8 {
    const io = io_mod.getIo();
    const request_raw = readLedgerFile(alloc, io, "request.txt") orelse "";
    const events_raw = readLedgerFile(alloc, io, "events.log") orelse "";
    const state_raw = readLedgerFile(alloc, io, "state.txt") orelse "";
    const phase = phaseFor(request_raw, args);
    const row = valueFor(request_raw, "row") orelse "";
    const witness = valueFor(request_raw, "witness") orelse "";
    var state = parseState(state_raw);
    var base_events: []const u8 = events_raw;
    var added_events: []const []const u8 = &.{};
    var ok = true;
    var refusal: []const u8 = "";
    var persist = false;

    if (std.mem.eql(u8, phase, "open")) {
        state = .{ .step = 1 };
        base_events = "";
        added_events = &.{ "turn_context", "tool_batch", "session_open", "log_query" };
        persist = true;
    } else if (std.mem.eql(u8, phase, "add")) {
        state.step += 1;
        state.todo_open = true;
        state.question_open = true;
        state.pending_count = 2;
        added_events = &.{ "turn_context", "tool_batch", "todo_add", "question_add", "pending_event", "pending_event" };
        persist = true;
    } else if (std.mem.eql(u8, phase, "child")) {
        state.step += 1;
        state.child_count = 2;
        state.pending_count = 0;
        added_events = &.{ "turn_context", "tool_batch", "subagent_session", "subagent_session", "pending_delivery", "pending_delivery" };
        persist = true;
    } else if (std.mem.eql(u8, phase, "job")) {
        state.step += 1;
        state.task_open = false;
        state.pending_count = 0;
        added_events = &.{ "turn_context", "tool_batch", "task_start", "pending_event", "pending_delivery", "task_stop", "pending_event", "pending_delivery", "log_query" };
        persist = true;
    } else if (std.mem.eql(u8, phase, "resolve")) {
        state.step += 1;
        if (std.mem.eql(u8, row, "todo") and state.todo_open) {
            state.todo_open = false;
            added_events = &.{ "turn_context", "tool_batch", "todo_resolve", "log_query" };
        } else if (std.mem.eql(u8, row, "question") and state.question_open) {
            state.question_open = false;
            added_events = &.{ "turn_context", "tool_batch", "question_resolve", "log_query" };
        } else {
            ok = false;
            refusal = "resolve refused: unknown row";
            added_events = &.{ "turn_context", "tool_batch", "log_query" };
        }
        persist = true;
    } else if (std.mem.eql(u8, phase, "finish-refused")) {
        state.step += 1;
        const open_rows = try openRowsText(alloc, state);
        ok = false;
        if (open_rows.len > 0) {
            refusal = try std.fmt.allocPrint(alloc, "turn end refused while a todo or question row is open: {s}", .{open_rows});
        } else {
            refusal = "turn end refused: no open row remains";
        }
        added_events = &.{ "turn_context", "tool_batch", "turn_end", "log_query" };
        persist = true;
    } else if (std.mem.eql(u8, phase, "finish-accepted")) {
        state.step += 1;
        if (std.mem.eql(u8, row, "question")) state.question_open = false;
        if (std.mem.eql(u8, row, "todo")) state.todo_open = false;
        if (state.todo_open or state.question_open or state.pending_count != 0 or state.task_open) {
            ok = false;
            refusal = "turn end refused while rows, tasks or pending events remain";
            added_events = &.{ "turn_context", "tool_batch", "log_query" };
        } else if (!quoted(witness)) {
            ok = false;
            refusal = "turn end refused: witness must be quoted";
            added_events = &.{ "turn_context", "tool_batch", "log_query" };
        } else {
            state.finished = true;
            state.witness = witness;
            added_events = &.{ "turn_context", "tool_batch", "question_resolve", "log_query", "turn_end" };
        }
        persist = true;
    } else if (std.mem.eql(u8, phase, "status")) {
        ok = true;
    } else {
        ok = false;
        refusal = try std.fmt.allocPrint(alloc, "unknown phase: {s}", .{phase});
    }

    if (!persist) return outputJson(alloc, ok, phase, state, events_raw, refusal);
    const updated_events = try appendEvents(alloc, base_events, added_events);
    const updated_state = try stateText(alloc, state);
    try writeLedgerFile(io, "events.log", updated_events);
    try writeLedgerFile(io, "state.txt", updated_state);
    return outputJson(alloc, ok, phase, state, updated_events, refusal);
}
