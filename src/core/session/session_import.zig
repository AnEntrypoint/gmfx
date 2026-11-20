const std = @import("std");
const session_event = @import("session_event.zig");
const session_adapter = @import("session_adapter.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Source = enum {
    claude_code,
    codex,
};

pub const ImportError = error{
    MalformedLine,
    InvalidTranscriptEvent,
    WriteFailed,
    OutOfMemory,
};

pub const Diagnostic = struct {
    line: usize = 0,
};

pub const TimedEvent = struct {
    timestamp_ms: i64,
    event: session_event.ConversationEvent,
};

pub const Transcript = struct {
    arena: std.heap.ArenaAllocator,
    source_id: []const u8,
    cwd: []const u8,
    events: []const TimedEvent,
    skipped_records: usize,

    pub fn deinit(self: *Transcript) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const whitespace = " \t\r\n";
const image_omitted = "[image omitted]";
const control_prefixes = [_][]const u8{
    "<command-",
    "<local-command",
    "<system-reminder>",
    "<task-notification>",
    "<environment_context>",
    "# AGENTS.md instructions for ",
};

pub fn parseTranscript(
    alloc: Allocator,
    source: Source,
    bytes: []const u8,
    diagnostic: *Diagnostic,
) ImportError!Transcript {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder{ .arena = arena };
    var skipped: usize = 0;
    var timestamp_ms: i64 = 0;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            diagnostic.line = line_number;
            return error.MalformedLine;
        };
        if (record != .object) {
            diagnostic.line = line_number;
            return error.MalformedLine;
        }
        const object = record.object;
        timestamp_ms = timestampMs(object) orelse timestamp_ms;
        const consumed = switch (source) {
            .claude_code => try claudeRecord(&builder, object, timestamp_ms),
            .codex => try codexRecord(&builder, object, timestamp_ms),
        };
        if (!consumed) skipped += 1;
    }
    try builder.closeTurn(timestamp_ms);

    return .{
        .arena = arena_state,
        .source_id = builder.source_id,
        .cwd = builder.cwd,
        .events = try builder.events.toOwnedSlice(arena),
        .skipped_records = skipped,
    };
}

pub fn writeEnvelopes(writer: *std.Io.Writer, transcript: *const Transcript) !void {
    for (transcript.events, 1..) |timed, seq| {
        const envelope = session_event.ConversationEnvelope{
            .seq = @intCast(seq),
            .timestamp_ms = timed.timestamp_ms,
            .event = timed.event,
        };
        try std.json.Stringify.value(envelope, .{}, writer);
        try writer.writeByte('\n');
    }
}

pub fn parseIsoMs(text: []const u8) ?i64 {
    if (text.len < 19) return null;
    if (text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return null;
    const year = parseDigits(text[0..4]) orelse return null;
    const month = parseDigits(text[5..7]) orelse return null;
    const day = parseDigits(text[8..10]) orelse return null;
    const hour = parseDigits(text[11..13]) orelse return null;
    const minute = parseDigits(text[14..16]) orelse return null;
    const second = parseDigits(text[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;

    var index: usize = 19;
    var millis: i64 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        const digits = @min(index - start, 3);
        if (digits == 0) return null;
        millis = parseDigits(text[start .. start + digits]) orelse return null;
        for (digits..3) |_| millis *= 10;
    }

    var offset_minutes: i64 = 0;
    if (index < text.len) {
        switch (text[index]) {
            'Z', 'z' => {
                index += 1;
            },
            '+', '-' => {
                if (text.len != index + 6 or text[index + 3] != ':') return null;
                const hours = parseDigits(text[index + 1 .. index + 3]) orelse return null;
                const minutes = parseDigits(text[index + 4 .. index + 6]) orelse return null;
                const magnitude = hours * 60 + minutes;
                offset_minutes = if (text[index] == '-') -magnitude else magnitude;
                index = text.len;
            },
            else => return null,
        }
    }
    if (index != text.len) return null;

    const days = daysFromCivil(year, month, day);
    const seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset_minutes * 60;
    return seconds * 1000 + millis;
}

fn parseDigits(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const shifted_month = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub const default_import_days: u16 = 30;
pub const max_import_days: u16 = 365;
pub const import_batch_limit: usize = 100;
pub const max_imported_text_bytes: usize = 64 * 1024;
pub const ledger_file_name = "imported-sessions.jsonl";
const max_transcript_bytes: usize = 256 * 1024 * 1024;
const max_ledger_bytes: usize = 16 * 1024 * 1024;
const transcript_extension = ".jsonl";
const codex_rollout_prefix = "rollout-";
const truncation_note = "\n[imported text truncated]";

pub const Candidate = struct {
    source: Source,
    path: []u8,
    modified_ms: i64,
};

pub fn freeCandidates(alloc: Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| alloc.free(candidate.path);
    alloc.free(candidates);
}

pub fn sourceHome(alloc: Allocator, override: ?[]const u8, home: []const u8, dir_name: []const u8) ![]u8 {
    if (override) |value| {
        const trimmed = std.mem.trim(u8, value, whitespace);
        if (trimmed.len > 0) return alloc.dupe(u8, trimmed);
    }
    return std.Io.Dir.path.join(alloc, &.{ home, dir_name });
}

pub fn discover(alloc: Allocator, claude_home: []const u8, codex_home: []const u8, since_ms: i64) ![]Candidate {
    var found: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (found.items) |candidate| alloc.free(candidate.path);
        found.deinit(alloc);
    }
    try discoverClaude(alloc, &found, claude_home, since_ms);
    try discoverCodex(alloc, &found, codex_home, since_ms);
    std.mem.sort(Candidate, found.items, {}, newestFirst);
    return found.toOwnedSlice(alloc);
}

fn newestFirst(_: void, a: Candidate, b: Candidate) bool {
    if (a.modified_ms != b.modified_ms) return a.modified_ms > b.modified_ms;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn modifiedMs(dir: std.Io.Dir, sub_path: []const u8) ?i64 {
    const stat = dir.statFile(io_mod.getIo(), sub_path, .{}) catch return null;
    return std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms));
}

fn discoverClaude(alloc: Allocator, found: *std.ArrayList(Candidate), claude_home: []const u8, since_ms: i64) !void {
    const io = io_mod.getIo();
    const projects_path = try std.Io.Dir.path.join(alloc, &.{ claude_home, "projects" });
    defer alloc.free(projects_path);
    var projects = std.Io.Dir.cwd().openDir(io, projects_path, .{ .iterate = true }) catch return;
    defer projects.close(io);
    var project_entries = projects.iterate();
    while (project_entries.next(io) catch return) |project| {
        if (project.kind != .directory) continue;
        var project_dir = projects.openDir(io, project.name, .{ .iterate = true }) catch continue;
        defer project_dir.close(io);
        var files = project_dir.iterate();
        while (files.next(io) catch break) |file| {
            if (file.kind != .file or !std.mem.endsWith(u8, file.name, transcript_extension)) continue;
            const modified_ms = modifiedMs(project_dir, file.name) orelse continue;
            if (modified_ms < since_ms) continue;
            const path = try std.Io.Dir.path.join(alloc, &.{ projects_path, project.name, file.name });
            errdefer alloc.free(path);
            try found.append(alloc, .{ .source = .claude_code, .path = path, .modified_ms = modified_ms });
        }
    }
}

fn discoverCodex(alloc: Allocator, found: *std.ArrayList(Candidate), codex_home: []const u8, since_ms: i64) !void {
    const io = io_mod.getIo();
    const sessions_path = try std.Io.Dir.path.join(alloc, &.{ codex_home, "sessions" });
    defer alloc.free(sessions_path);
    var sessions = std.Io.Dir.cwd().openDir(io, sessions_path, .{ .iterate = true }) catch return;
    defer sessions.close(io);
    var walker = try sessions.walk(alloc);
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        const name = std.Io.Dir.path.basename(entry.path);
        if (!std.mem.startsWith(u8, name, codex_rollout_prefix) or !std.mem.endsWith(u8, name, transcript_extension)) continue;
        const modified_ms = modifiedMs(sessions, entry.path) orelse continue;
        if (modified_ms < since_ms) continue;
        const path = try std.Io.Dir.path.join(alloc, &.{ sessions_path, entry.path });
        errdefer alloc.free(path);
        try found.append(alloc, .{ .source = .codex, .path = path, .modified_ms = modified_ms });
    }
}

fn boundedText(arena: Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_imported_text_bytes) return arena.dupe(u8, text);
    var cut = max_imported_text_bytes;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return std.mem.concat(arena, u8, &.{ text[0..cut], truncation_note });
}

pub fn historyTurns(arena: Allocator, transcript: *const Transcript) ![]types.HistoryTurn {
    var turns: std.ArrayList(types.HistoryTurn) = .empty;
    var prompt: ?[]u8 = null;
    var reply: []u8 = &.{};
    for (transcript.events) |timed| switch (timed.event) {
        .user => |entry| {
            prompt = try boundedText(arena, entry.text);
            reply = &.{};
        },
        .assistant => |entry| reply = try boundedText(arena, entry.text),
        .turn_completed => {
            const text = prompt orelse continue;
            try turns.append(arena, .{ .assistant = .{ .user = .{ .text = text }, .assistant = reply } });
            prompt = null;
        },
        else => {},
    };
    return turns.toOwnedSlice(arena);
}

fn sourceName(source: Source) []const u8 {
    return switch (source) {
        .claude_code => "claude_code",
        .codex => "codex",
    };
}

fn transcriptStem(path: []const u8) []const u8 {
    const name = std.Io.Dir.path.basename(path);
    return if (std.mem.endsWith(u8, name, transcript_extension)) name[0 .. name.len - transcript_extension.len] else name;
}

pub fn ledgerSessionId(arena: Allocator, ledger: []const u8, source: Source, source_id: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, ledger, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (record != .object) continue;
        const listed_source = stringField(record.object, "source") orelse continue;
        const listed_id = stringField(record.object, "source_id") orelse continue;
        if (!std.mem.eql(u8, listed_source, sourceName(source)) or !std.mem.eql(u8, listed_id, source_id)) continue;
        return stringField(record.object, "session_id") orelse continue;
    }
    return null;
}

const LedgerLine = struct {
    source: []const u8,
    source_id: []const u8,
    session_id: []const u8,
    source_path: []const u8,
    imported_at_ms: i64,
};

fn ledgerWithLine(arena: Allocator, ledger: []const u8, line: LedgerLine) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(ledger);
    if (ledger.len > 0 and ledger[ledger.len - 1] != '\n') try out.writer.writeByte('\n');
    try std.json.Stringify.value(line, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

pub const Report = struct {
    found: usize = 0,
    imported: usize = 0,
    already_imported: usize = 0,
    missing_folder: usize = 0,
    empty: usize = 0,
    failed: usize = 0,
    days: u16 = default_import_days,
};

pub const Options = struct {
    default_model: []const u8,
    claude_home: []const u8,
    codex_home: []const u8,
    ledger_path: []const u8,
    now_ms: i64,
    days: u16 = default_import_days,
};

const Outcome = enum { imported, already_imported, missing_folder, empty, failed };

pub fn importRecent(alloc: Allocator, store: *session_adapter.Store, options: Options) !Report {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const since_ms = options.now_ms - @as(i64, options.days) * std.time.ms_per_day;
    const candidates = try discover(alloc, options.claude_home, options.codex_home, since_ms);
    defer freeCandidates(alloc, candidates);

    var ledger: []const u8 = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), options.ledger_path, arena, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var report: Report = .{ .found = candidates.len, .days = options.days };
    for (candidates[0..@min(candidates.len, import_batch_limit)]) |candidate| {
        switch (try importOne(alloc, arena, store, options, candidate, &ledger)) {
            .imported => report.imported += 1,
            .already_imported => report.already_imported += 1,
            .missing_folder => report.missing_folder += 1,
            .empty => report.empty += 1,
            .failed => report.failed += 1,
        }
    }
    return report;
}

fn isDirectory(path: []const u8) bool {
    if (path.len == 0 or !std.Io.Dir.path.isAbsolute(path)) return false;
    const io = io_mod.getIo();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn importOne(
    alloc: Allocator,
    arena: Allocator,
    store: *session_adapter.Store,
    options: Options,
    candidate: Candidate,
    ledger: *[]const u8,
) !Outcome {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), candidate.path, scratch, .limited(max_transcript_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .failed,
    };
    var diagnostic: Diagnostic = .{};
    const transcript = parseTranscript(scratch, candidate.source, bytes, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .failed,
    };
    const turns = try historyTurns(scratch, &transcript);
    if (turns.len == 0) return .empty;
    const source_id = if (transcript.source_id.len > 0) transcript.source_id else transcriptStem(candidate.path);
    if (ledgerSessionId(scratch, ledger.*, candidate.source, source_id) != null) return .already_imported;
    if (!isDirectory(transcript.cwd)) return .missing_folder;

    const session = session_adapter.Session.create(alloc, store, transcript.cwd, .ask, .{
        .preferences = .{ .model = try scratch.dupe(u8, options.default_model), .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .failed,
    };
    defer session.close();
    var committed: usize = 0;
    for (turns) |turn| {
        session.commitTurn(turn, types.ConversationLanguage.default()) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        committed += 1;
    }
    if (committed == 0) return .failed;

    const updated = try ledgerWithLine(arena, ledger.*, .{
        .source = sourceName(candidate.source),
        .source_id = source_id,
        .session_id = session.id(),
        .source_path = candidate.path,
        .imported_at_ms = options.now_ms,
    });
    try io_mod.writeFileAtomic(alloc, options.ledger_path, updated);
    ledger.* = updated;
    return .imported;
}

pub fn renderReport(alloc: Allocator, report: Report) ![]u8 {
    if (report.found == 0) {
        return std.fmt.allocPrint(alloc, "No Claude Code or Codex sessions from the last {d} days were found.", .{report.days});
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Imported {d} of {d} Claude Code and Codex sessions from the last {d} days.", .{ report.imported, report.found, report.days });
    if (report.already_imported > 0) try w.print(" {d} already imported.", .{report.already_imported});
    if (report.missing_folder > 0) try w.print(" {d} skipped because the project folder no longer exists.", .{report.missing_folder});
    if (report.empty > 0) try w.print(" {d} had no conversation.", .{report.empty});
    if (report.failed > 0) try w.print(" {d} could not be read.", .{report.failed});
    if (report.found > import_batch_limit) try w.print(" Only the newest {d} are imported per run; run it again for the rest.", .{import_batch_limit});
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const Builder = struct {
    arena: Allocator,
    events: std.ArrayList(TimedEvent) = .empty,
    pending: std.ArrayList(u8) = .empty,
    turn_open: bool = false,
    source_id: []const u8 = "",
    cwd: []const u8 = "",

    fn append(self: *Builder, timestamp_ms: i64, event: session_event.ConversationEvent) ImportError!void {
        session_event.validateConversationEventShape(event, session_event.conversation_schema_version) catch {
            return error.InvalidTranscriptEvent;
        };
        try self.events.append(self.arena, .{ .timestamp_ms = timestamp_ms, .event = event });
    }

    fn closeTurn(self: *Builder, timestamp_ms: i64) ImportError!void {
        if (!self.turn_open) return;
        if (self.pending.items.len > 0) {
            const text = try self.arena.dupe(u8, self.pending.items);
            try self.append(timestamp_ms, .{ .assistant = .{ .text = text } });
            self.pending.clearRetainingCapacity();
        }
        try self.append(timestamp_ms, .{ .turn_completed = .{} });
        self.turn_open = false;
    }

    fn prompt(self: *Builder, timestamp_ms: i64, text: []const u8) ImportError!bool {
        const trimmed = std.mem.trim(u8, text, whitespace);
        if (trimmed.len == 0 or isControlText(trimmed)) return false;
        try self.closeTurn(timestamp_ms);
        const owned = try self.arena.dupe(u8, trimmed);
        try self.append(timestamp_ms, .{ .user = .{ .text = owned } });
        self.turn_open = true;
        return true;
    }

    fn assistantText(self: *Builder, text: []const u8) ImportError!bool {
        return self.appendLine(std.mem.trim(u8, text, whitespace));
    }

    fn appendLine(self: *Builder, line: []const u8) ImportError!bool {
        if (line.len == 0 or !self.turn_open) return false;
        if (self.pending.items.len > 0) try self.pending.append(self.arena, '\n');
        try self.pending.appendSlice(self.arena, line);
        return true;
    }
};

fn claudeRecord(builder: *Builder, object: std.json.ObjectMap, timestamp_ms: i64) ImportError!bool {
    if (boolField(object, "isSidechain") or boolField(object, "isMeta")) return false;
    if (builder.source_id.len == 0) {
        if (stringField(object, "sessionId")) |id| builder.source_id = try builder.arena.dupe(u8, id);
    }
    if (builder.cwd.len == 0) {
        if (stringField(object, "cwd")) |cwd| builder.cwd = try builder.arena.dupe(u8, cwd);
    }
    const kind = stringField(object, "type") orelse return false;
    const message = objectField(object, "message") orelse return false;
    const content = message.get("content") orelse return false;
    if (std.mem.eql(u8, kind, "user")) return claudeUser(builder, timestamp_ms, content);
    if (std.mem.eql(u8, kind, "assistant")) return claudeAssistant(builder, content);
    return false;
}

fn claudeUser(builder: *Builder, timestamp_ms: i64, content: std.json.Value) ImportError!bool {
    switch (content) {
        .string => |text| return builder.prompt(timestamp_ms, text),
        .array => |array| {
            var consumed = false;
            for (array.items) |block| {
                if (block != .object) continue;
                if (!std.mem.eql(u8, stringField(block.object, "type") orelse "", "tool_result")) continue;
                if (try claudeToolResult(builder, block.object)) consumed = true;
            }
            const text = try contentText(builder.arena, array.items);
            if (try builder.prompt(timestamp_ms, text)) consumed = true;
            return consumed;
        },
        else => return false,
    }
}

fn claudeAssistant(builder: *Builder, content: std.json.Value) ImportError!bool {
    switch (content) {
        .string => |text| return builder.assistantText(text),
        .array => |array| {
            var consumed = false;
            for (array.items) |block| {
                if (block != .object) continue;
                const kind = stringField(block.object, "type") orelse continue;
                if (std.mem.eql(u8, kind, "text")) {
                    if (stringField(block.object, "text")) |text| {
                        if (try builder.assistantText(text)) consumed = true;
                    }
                } else if (std.mem.eql(u8, kind, "tool_use")) {
                    if (try claudeToolUse(builder, block.object)) consumed = true;
                }
            }
            return consumed;
        },
        else => return false,
    }
}

fn claudeToolUse(builder: *Builder, object: std.json.ObjectMap) ImportError!bool {
    const name = stringField(object, "name") orelse "tool";
    const input = object.get("input") orelse std.json.Value{ .null = {} };
    const arguments = try jsonText(builder.arena, input);
    return builder.appendLine(try std.fmt.allocPrint(builder.arena, "[tool: {s}] {s}", .{ name, arguments }));
}

fn claudeToolResult(builder: *Builder, object: std.json.ObjectMap) ImportError!bool {
    const output = try toolOutput(builder.arena, object.get("content") orelse std.json.Value{ .null = {} });
    return builder.appendLine(try std.fmt.allocPrint(builder.arena, "[tool result] {s}", .{output}));
}

fn codexRecord(builder: *Builder, object: std.json.ObjectMap, timestamp_ms: i64) ImportError!bool {
    const kind = stringField(object, "type") orelse return false;
    const payload = objectField(object, "payload") orelse return false;
    if (std.mem.eql(u8, kind, "session_meta")) {
        if (stringField(payload, "id")) |id| builder.source_id = try builder.arena.dupe(u8, id);
        if (stringField(payload, "cwd")) |cwd| builder.cwd = try builder.arena.dupe(u8, cwd);
        return false;
    }
    if (!std.mem.eql(u8, kind, "response_item")) return false;
    const payload_type = stringField(payload, "type") orelse return false;

    if (std.mem.eql(u8, payload_type, "message")) {
        const role = stringField(payload, "role") orelse return false;
        const parts = arrayField(payload, "content") orelse return false;
        const text = try contentText(builder.arena, parts);
        if (std.mem.eql(u8, role, "user")) return builder.prompt(timestamp_ms, text);
        if (std.mem.eql(u8, role, "assistant")) return builder.assistantText(text);
        return false;
    }
    if (std.mem.eql(u8, payload_type, "function_call") or std.mem.eql(u8, payload_type, "custom_tool_call")) {
        const name = stringField(payload, "name") orelse "tool";
        const arguments = stringField(payload, "arguments") orelse stringField(payload, "input") orelse "";
        return builder.appendLine(try std.fmt.allocPrint(builder.arena, "[tool: {s}] {s}", .{ name, arguments }));
    }
    if (std.mem.eql(u8, payload_type, "function_call_output") or std.mem.eql(u8, payload_type, "custom_tool_call_output")) {
        const output = try toolOutput(builder.arena, payload.get("output") orelse std.json.Value{ .null = {} });
        return builder.appendLine(try std.fmt.allocPrint(builder.arena, "[tool result] {s}", .{output}));
    }
    return false;
}

fn toolOutput(arena: Allocator, value: std.json.Value) ImportError![]const u8 {
    return switch (value) {
        .string => |text| text,
        .array => |items| try contentText(arena, items.items),
        else => "",
    };
}

fn contentText(arena: Allocator, parts: []const std.json.Value) ImportError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        if (part != .object) continue;
        const piece = partText(part.object) orelse continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, piece);
    }
    return out.items;
}

fn partText(object: std.json.ObjectMap) ?[]const u8 {
    if (stringField(object, "text")) |text| return text;
    const kind = stringField(object, "type") orelse return null;
    if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "input_image")) return image_omitted;
    return null;
}

fn jsonText(arena: Allocator, value: std.json.Value) ImportError![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn isControlText(text: []const u8) bool {
    for (control_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

fn timestampMs(object: std.json.ObjectMap) ?i64 {
    const text = stringField(object, "timestamp") orelse return null;
    return parseIsoMs(text);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn arrayField(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse return null;
    return if (value == .array) value.array.items else null;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

fn expectFramesDecode(transcript: *const Transcript) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEnvelopes(&out.writer, transcript);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rest = out.written();
    var frames: usize = 0;
    while (rest.len > 0) {
        const end = (std.mem.indexOfScalar(u8, rest, '\n') orelse return error.MissingFrameTerminator) + 1;
        _ = try session_event.decodeConversationFrameLeaky(arena.allocator(), rest[0..end], .alloc_always);
        rest = rest[end..];
        frames += 1;
    }
    try std.testing.expectEqual(transcript.events.len, frames);
}

test "claude code transcript imports user and assistant turns" {
    const fixture =
        \\{"type":"user","uuid":"u1","sessionId":"abc-123","timestamp":"2026-01-02T03:04:05.000Z","message":{"role":"user","content":"fix the bug"}}
        \\{"type":"assistant","uuid":"a1","timestamp":"2026-01-02T03:04:06.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"Done."}]}}
        \\{"type":"summary","summary":"earlier"}
        \\{"type":"user","uuid":"u2","timestamp":"2026-01-02T03:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"thanks"}]}}
        \\{"type":"assistant","uuid":"a2","timestamp":"2026-01-02T03:05:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"You are welcome."}]}}
        \\
    ;
    var diagnostic: Diagnostic = .{};
    var transcript = try parseTranscript(std.testing.allocator, .claude_code, fixture, &diagnostic);
    defer transcript.deinit();

    try std.testing.expectEqualStrings("abc-123", transcript.source_id);
    try std.testing.expectEqual(@as(usize, 1), transcript.skipped_records);
    try std.testing.expectEqual(@as(usize, 6), transcript.events.len);
    try std.testing.expectEqualStrings("fix the bug", transcript.events[0].event.user.text);
    try std.testing.expectEqual(@as(i64, 1767323045000), transcript.events[0].timestamp_ms);
    try std.testing.expectEqualStrings("Done.", transcript.events[1].event.assistant.text);
    try std.testing.expect(transcript.events[2].event == .turn_completed);
    try std.testing.expectEqualStrings("thanks", transcript.events[3].event.user.text);
    try std.testing.expectEqualStrings("You are welcome.", transcript.events[4].event.assistant.text);
    try std.testing.expect(transcript.events[5].event == .turn_completed);
    try expectFramesDecode(&transcript);
}

test "codex rollout imports messages and skips unknown records" {
    const fixture =
        \\{"timestamp":"2026-01-02T03:04:05.000Z","type":"session_meta","payload":{"id":"rollout-7","cwd":"/work/app"}}
        \\{"timestamp":"2026-01-02T03:04:05.100Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/work/app"}}
        \\{"timestamp":"2026-01-02T03:04:06.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        \\{"timestamp":"2026-01-02T03:04:06.000Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
        \\{"timestamp":"2026-01-02T03:04:07.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null}}
        \\{"timestamp":"2026-01-02T03:04:08.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi there"}]}}
        \\{"timestamp":"2026-01-02T03:04:09.000Z","type":"mystery_record","payload":{"x":1}}
        \\{"timestamp":"2026-01-02T03:05:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"second"}]}}
        \\
    ;
    var diagnostic: Diagnostic = .{};
    var transcript = try parseTranscript(std.testing.allocator, .codex, fixture, &diagnostic);
    defer transcript.deinit();

    try std.testing.expectEqualStrings("rollout-7", transcript.source_id);
    try std.testing.expectEqual(@as(usize, 5), transcript.skipped_records);
    try std.testing.expectEqual(@as(usize, 5), transcript.events.len);
    try std.testing.expectEqualStrings("hello", transcript.events[0].event.user.text);
    try std.testing.expectEqualStrings("hi there", transcript.events[1].event.assistant.text);
    try std.testing.expect(transcript.events[2].event == .turn_completed);
    try std.testing.expectEqualStrings("second", transcript.events[3].event.user.text);
    try std.testing.expect(transcript.events[4].event == .turn_completed);
    try expectFramesDecode(&transcript);
}

test "import rejects a malformed line with its line number" {
    const fixture =
        \\{"type":"user","message":{"role":"user","content":"ok"}}
        \\
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"broken"}]
        \\
    ;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.MalformedLine,
        parseTranscript(std.testing.allocator, .claude_code, fixture, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
}

test "a transcript carries the working directory its source recorded" {
    var diagnostic: Diagnostic = .{};
    var claude = try parseTranscript(std.testing.allocator, .claude_code,
        \\{"type":"user","sessionId":"abc","cwd":"/work/app","message":{"role":"user","content":"hi"}}
        \\
    , &diagnostic);
    defer claude.deinit();
    try std.testing.expectEqualStrings("/work/app", claude.cwd);

    var codex = try parseTranscript(std.testing.allocator, .codex,
        \\{"type":"session_meta","payload":{"id":"rollout-7","cwd":"/work/api"}}
        \\
    , &diagnostic);
    defer codex.deinit();
    try std.testing.expectEqualStrings("/work/api", codex.cwd);
}

test "history turns pair each prompt with its reply and keep an unanswered prompt" {
    var diagnostic: Diagnostic = .{};
    var transcript = try parseTranscript(std.testing.allocator, .claude_code,
        \\{"type":"user","sessionId":"abc","message":{"role":"user","content":"fix the bug"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}
        \\{"type":"user","message":{"role":"user","content":"thanks"}}
        \\
    , &diagnostic);
    defer transcript.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const turns = try historyTurns(arena.allocator(), &transcript);
    try std.testing.expectEqual(@as(usize, 2), turns.len);
    try std.testing.expectEqualStrings("fix the bug", turns[0].assistant.user.text);
    try std.testing.expectEqualStrings("Done.", turns[0].assistant.assistant);
    try std.testing.expectEqualStrings("thanks", turns[1].assistant.user.text);
    try std.testing.expectEqualStrings("", turns[1].assistant.assistant);
}

test "imported text over the cap is cut on a character boundary and marked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = try arena.allocator().alloc(u8, max_imported_text_bytes + 10);
    @memset(long, 'a');
    const bounded = try boundedText(arena.allocator(), long);
    try std.testing.expectEqual(max_imported_text_bytes + truncation_note.len, bounded.len);
    try std.testing.expect(std.mem.endsWith(u8, bounded, truncation_note));
    const short = try boundedText(arena.allocator(), "short");
    try std.testing.expectEqualStrings("short", short);
}

test "the import ledger finds a source it has listed and no other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try ledgerWithLine(a, "", .{ .source = "claude_code", .source_id = "abc", .session_id = "session_1", .source_path = "/t/abc.jsonl", .imported_at_ms = 5 });
    const both = try ledgerWithLine(a, first, .{ .source = "codex", .source_id = "abc", .session_id = "session_2", .source_path = "/t/rollout-abc.jsonl", .imported_at_ms = 6 });
    try std.testing.expectEqualStrings("session_1", ledgerSessionId(a, both, .claude_code, "abc").?);
    try std.testing.expectEqualStrings("session_2", ledgerSessionId(a, both, .codex, "abc").?);
    try std.testing.expect(ledgerSessionId(a, both, .codex, "other") == null);
    try std.testing.expect(ledgerSessionId(a, "not json\n", .codex, "abc") == null);
}

test "source homes follow their environment override and default under the home directory" {
    const alloc = std.testing.allocator;
    const overridden = try sourceHome(alloc, " /custom/claude ", "/home/u", ".claude");
    defer alloc.free(overridden);
    try std.testing.expectEqualStrings("/custom/claude", overridden);
    const blank = try sourceHome(alloc, "  ", "/home/u", ".codex");
    defer alloc.free(blank);
    try std.testing.expectEqualStrings("/home/u/.codex", blank);
    const defaulted = try sourceHome(alloc, null, "/home/u", ".claude");
    defer alloc.free(defaulted);
    try std.testing.expectEqualStrings("/home/u/.claude", defaulted);
}

test "the import report names what was imported and what was skipped" {
    const alloc = std.testing.allocator;
    const none = try renderReport(alloc, .{ .days = 15 });
    defer alloc.free(none);
    try std.testing.expectEqualStrings("No Claude Code or Codex sessions from the last 15 days were found.", none);
    const mixed = try renderReport(alloc, .{ .found = 5, .imported = 2, .already_imported = 1, .missing_folder = 1, .failed = 1 });
    defer alloc.free(mixed);
    try std.testing.expectEqualStrings(
        "Imported 2 of 5 Claude Code and Codex sessions from the last 30 days. 1 already imported. 1 skipped because the project folder no longer exists. 1 could not be read.",
        mixed,
    );
}

test "import-sessions discovers Claude Code and Codex transcripts, saves each once and skips them on a rerun" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.createDirPath(io, ".claude/projects/-work");
    try tmp.dir.createDirPath(io, ".claude/projects/-work/abc-123/subagents");
    try tmp.dir.createDirPath(io, ".codex/sessions/2026/01/02");

    const claude_transcript = try std.fmt.allocPrint(alloc,
        \\{{"type":"user","sessionId":"abc-123","cwd":"{s}/work","message":{{"role":"user","content":"fix the bug"}}}}
        \\{{"type":"assistant","message":{{"role":"assistant","content":[{{"type":"text","text":"Done."}}]}}}}
        \\
    , .{home});
    defer alloc.free(claude_transcript);
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/-work/abc-123.jsonl", .data = claude_transcript });
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/-work/abc-123/subagents/agent-1.jsonl", .data = claude_transcript });
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/-work/notes.txt", .data = "not a transcript" });

    const codex_transcript = try std.fmt.allocPrint(alloc,
        \\{{"type":"session_meta","payload":{{"id":"rollout-7","cwd":"{s}/work"}}}}
        \\{{"type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"hello"}}]}}}}
        \\{{"type":"response_item","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"hi there"}}]}}}}
        \\
    , .{home});
    defer alloc.free(codex_transcript);
    try tmp.dir.writeFile(io, .{ .sub_path = ".codex/sessions/2026/01/02/rollout-7.jsonl", .data = codex_transcript });
    try tmp.dir.writeFile(io, .{ .sub_path = ".codex/sessions/2026/01/02/rollout-gone.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"rollout-gone","cwd":"/no/such/folder/anywhere"}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        \\
    });

    const claude_home = try std.Io.Dir.path.join(alloc, &.{ home, ".claude" });
    defer alloc.free(claude_home);
    const codex_home = try std.Io.Dir.path.join(alloc, &.{ home, ".codex" });
    defer alloc.free(codex_home);
    const ledger_path = try std.Io.Dir.path.join(alloc, &.{ home, ledger_file_name });
    defer alloc.free(ledger_path);

    var store = try session_adapter.Store.open(alloc, home);
    defer store.deinit(alloc);
    const options: Options = .{
        .default_model = "test-model",
        .claude_home = claude_home,
        .codex_home = codex_home,
        .ledger_path = ledger_path,
        .now_ms = io_mod.milliTimestamp(),
    };

    const first = try importRecent(alloc, &store, options);
    try std.testing.expectEqual(@as(usize, 3), first.found);
    try std.testing.expectEqual(@as(usize, 2), first.imported);
    try std.testing.expectEqual(@as(usize, 1), first.missing_folder);
    try std.testing.expectEqual(@as(usize, 0), first.failed);

    var page = try session_adapter.listPage(&store, alloc, null, null, 10);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page.summaries.items.len);

    const second = try importRecent(alloc, &store, options);
    try std.testing.expectEqual(@as(usize, 0), second.imported);
    try std.testing.expectEqual(@as(usize, 2), second.already_imported);
    try std.testing.expectEqual(@as(usize, 1), second.missing_folder);

    const old = try importRecent(alloc, &store, .{
        .default_model = "test-model",
        .claude_home = claude_home,
        .codex_home = codex_home,
        .ledger_path = ledger_path,
        .now_ms = io_mod.milliTimestamp() + 400 * std.time.ms_per_day,
    });
    try std.testing.expectEqual(@as(usize, 0), old.found);
}
