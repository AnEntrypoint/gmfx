const std = @import("std");
const io_mod = @import("../shared/io.zig");
const imports = @import("imports.zig");
const cordis = @import("cordis.zig");
const resolve = @import("resolve.zig");
const host_module = @import("host_module.zig");

const bootstrap: []const u8 = @embedFile("runcode_bootstrap.js");

pub const default_deadline_ms: u64 = 120_000;
const max_console_lines: usize = 200;
const max_console_line_bytes: usize = 512;
const max_console_bytes: usize = 8 * 1024;
const max_read_bytes: usize = 16 * 1024 * 1024;
const max_module_bytes: usize = 4 * 1024 * 1024;

pub const Format = enum { cjs, esm };

pub const Verbs = struct {
    context: *anyopaque,
    catalog: []const u8,
    invoke: *const fn (context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8,
};

pub const Options = struct {
    format: Format = .cjs,
    deadline_ms: u64 = default_deadline_ms,
    body_path: ?[]const u8 = null,
    root: []const u8,
    verbs: Verbs,
    run_id: ?[]const u8 = null,
};

const Host = extern struct {
    context: ?*anyopaque,
    call: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, c_ulonglong) callconv(.c) ?[*:0]u8,
    sink: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    embedded: *const fn (?*anyopaque, [*:0]const u8, *usize) callconv(.c) ?[*]const u8,
};

extern fn fx_runcode_execute(
    bootstrap_source: [*]const u8,
    bootstrap_length: usize,
    verbs: [*:0]const u8,
    root: [*:0]const u8,
    source: [*]const u8,
    source_length: usize,
    source_name: [*:0]const u8,
    is_module: c_int,
    budget_ms: c_ulonglong,
    host: *const Host,
    out_value: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int;

pub const Outcome = struct {
    ok: bool,
    text: []u8,
    console: []u8,
    console_dropped: usize,

    pub fn deinit(self: Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.console);
    }
};

const JournalRecord = struct {
    seq: usize,
    verb: []const u8,
    args: []const u8,
    reply: []const u8,
};

const max_journal_bytes = 64 * 1024 * 1024;

const Session = struct {
    alloc: std.mem.Allocator,
    verbs: Verbs,
    root: []const u8,
    journal_path: ?[]const u8 = null,
    journal_text: std.ArrayList(u8) = .empty,
    seq: usize = 0,
    console: std.ArrayList(u8) = .empty,
    lines: usize = 0,
    bytes: usize = 0,
    dropped: usize = 0,

    fn appendLine(self: *Session, text: []const u8) void {
        const line = text[0..@min(text.len, max_console_line_bytes)];
        if (self.lines >= max_console_lines or self.bytes + line.len > max_console_bytes) {
            self.dropped += 1;
            return;
        }
        self.console.appendSlice(self.alloc, line) catch {
            self.dropped += 1;
            return;
        };
        self.console.append(self.alloc, '\n') catch {
            self.dropped += 1;
            return;
        };
        self.lines += 1;
        self.bytes += line.len;
    }

    fn dispatch(self: *Session, name: []const u8, args_json: []const u8, remaining_ms: u64) ![]u8 {
        if (std.mem.eql(u8, name, "fx.read_text")) return readTextReply(self.alloc, self.root, args_json);
        if (std.mem.eql(u8, name, "fx.resolve")) return resolve.reply(self.alloc, args_json);
        if (self.journal_path != null) {
            self.seq += 1;
            if (try self.replay(name, args_json)) |reply| return reply;
        }
        if (remaining_ms == 0) return replyError(self.alloc, "the body passed its JavaScript deadline before this call");
        const bounded = try clampTimeout(self.alloc, name, args_json, remaining_ms);
        defer self.alloc.free(bounded);
        const reply = try self.verbs.invoke(self.verbs.context, self.alloc, name, bounded);
        if (self.journal_path != null) try self.record(name, args_json, reply);
        return reply;
    }

    fn replay(self: *Session, name: []const u8, args_json: []const u8) !?[]u8 {
        var lines = std.mem.splitScalar(u8, self.journal_text.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(JournalRecord, self.alloc, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.seq != self.seq) continue;
            if (!std.mem.eql(u8, parsed.value.verb, name) or !std.mem.eql(u8, parsed.value.args, args_json)) {
                return try replyError(self.alloc, "the resumed run made a different inner call than its journal");
            }
            return try self.alloc.dupe(u8, parsed.value.reply);
        }
        return null;
    }

    fn record(self: *Session, name: []const u8, args_json: []const u8, reply: []const u8) !void {
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try std.json.Stringify.value(JournalRecord{ .seq = self.seq, .verb = name, .args = args_json, .reply = reply }, .{}, &writer.writer);
        try self.journal_text.appendSlice(self.alloc, writer.written());
        try self.journal_text.append(self.alloc, '\n');
        const path = self.journal_path orelse return;
        try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), std.fs.path.dirname(path) orelse ".");
        var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), path, .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), self.journal_text.items);
    }
};

fn sinkText(context: ?*anyopaque, text: [*]const u8, length: usize) callconv(.c) void {
    const session: *Session = @ptrCast(@alignCast(context.?));
    session.appendLine(text[0..length]);
}

fn callHost(context: ?*anyopaque, name: [*:0]const u8, args: [*:0]const u8, remaining_ms: c_ulonglong) callconv(.c) ?[*:0]u8 {
    const session: *Session = @ptrCast(@alignCast(context.?));
    const reply = session.dispatch(std.mem.span(name), std.mem.span(args), remaining_ms) catch |err| blk: {
        break :blk replyError(session.alloc, @errorName(err)) catch return null;
    };
    defer session.alloc.free(reply);
    return dupeZ(std.heap.c_allocator, reply) catch null;
}

fn embeddedSource(context: ?*anyopaque, name: [*:0]const u8, length: *usize) callconv(.c) ?[*]const u8 {
    _ = context;
    const module_name = std.mem.span(name);
    const embedded = if (std.mem.startsWith(u8, module_name, cordis.prefix)) cordis.source(module_name[cordis.prefix.len..]) else host_module.source(module_name);
    const source = embedded orelse return null;
    length.* = source.len;
    return source.ptr;
}

fn dupeZ(alloc: std.mem.Allocator, text: []const u8) ![:0]u8 {
    const owned = try alloc.allocSentinel(u8, text.len, 0);
    @memcpy(owned[0..text.len], text);
    return owned;
}

fn replyError(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn readTextReply(alloc: std.mem.Allocator, root: []const u8, args_json: []const u8) ![]u8 {
    const Args = struct { path: []const u8 };
    var parsed = std.json.parseFromSlice(Args, alloc, args_json, .{ .ignore_unknown_fields = true }) catch return replyError(alloc, "fx.read_text needs a path");
    defer parsed.deinit();
    const path = if (std.fs.path.isAbsolute(parsed.value.path))
        try alloc.dupe(u8, parsed.value.path)
    else
        try std.fs.path.join(alloc, &.{ root, parsed.value.path });
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch {
        return alloc.dupe(u8, "{\"ok\":false,\"missing\":true}");
    };
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(alloc, &file, max_module_bytes) catch {
        return alloc.dupe(u8, "{\"ok\":false,\"missing\":true}");
    };
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":true,\"text\":");
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn clampTimeout(alloc: std.mem.Allocator, name: []const u8, args_json: []const u8, remaining_ms: u64) ![]u8 {
    const seconds_key: ?[]const u8 = if (std.mem.eql(u8, name, "Bash")) "timeout" else null;
    const ms_key: ?[]const u8 = if (std.mem.eql(u8, name, "run_command")) "timeout_ms" else null;
    if (seconds_key == null and ms_key == null) return alloc.dupe(u8, args_json);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch return alloc.dupe(u8, args_json);
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, args_json);
    const cap: i64 = if (seconds_key) |_| @intCast(@max(@as(u64, 1), remaining_ms / 1000)) else @intCast(remaining_ms);
    const key = seconds_key orelse ms_key.?;
    const current: ?i64 = if (parsed.value.object.get(key)) |value| switch (value) {
        .integer => |n| n,
        else => null,
    } else null;
    if (current != null and current.? <= cap) return alloc.dupe(u8, args_json);
    try parsed.value.object.put(parsed.arena.allocator(), key, .{ .integer = cap });
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "FetchURL keeps the timeout the model gave so the tool can refuse it, while Bash still clamps" {
    const alloc = std.testing.allocator;
    const fetch = try clampTimeout(alloc, "FetchURL", "{\"url\":\"https://example.com\",\"timeout\":600}", 120_000);
    defer alloc.free(fetch);
    try std.testing.expectEqualStrings("{\"url\":\"https://example.com\",\"timeout\":600}", fetch);
    const bash = try clampTimeout(alloc, "Bash", "{\"command\":\"true\",\"timeout\":600}", 120_000);
    defer alloc.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "\"timeout\":120") != null);
}

fn wrapBody(alloc: std.mem.Allocator, body: []const u8, format: Format) ![:0]u8 {
    switch (format) {
        .cjs => return std.fmt.allocPrintSentinel(alloc, "(async function body(gm, require, tjs) {{{s}\n}})", .{body}, 0),
        .esm => {
            const hoisted = try imports.hoist(alloc, body);
            defer hoisted.deinit(alloc);
            return std.fmt.allocPrintSentinel(alloc, "{s}export default async function body(gm, require, tjs) {{{s}\n}}\n", .{ hoisted.imports, hoisted.code }, 0);
        },
    }
}

fn openJournal(alloc: std.mem.Allocator, session: *Session, root: []const u8, run_id: []const u8) !void {
    const file_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{run_id});
    defer alloc.free(file_name);
    const path = try std.fs.path.join(alloc, &.{ root, ".fx", "runs", file_name });
    session.journal_path = path;
    var existing = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return;
    defer existing.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &existing, max_journal_bytes);
    defer alloc.free(text);
    try session.journal_text.appendSlice(alloc, text);
}

pub fn execute(alloc: std.mem.Allocator, body: []const u8, options: Options) !Outcome {
    var session: Session = .{ .alloc = alloc, .verbs = options.verbs, .root = options.root };
    defer session.console.deinit(alloc);
    defer session.journal_text.deinit(alloc);
    if (options.run_id) |run_id| try openJournal(alloc, &session, options.root, run_id);
    defer if (session.journal_path) |path| alloc.free(path);
    const source = try wrapBody(alloc, body, options.format);
    defer alloc.free(source);
    const catalog = try dupeZ(alloc, options.verbs.catalog);
    defer alloc.free(catalog);
    const root = try dupeZ(alloc, options.root);
    defer alloc.free(root);
    const source_name = try dupeZ(alloc, options.body_path orelse "<body>");
    defer alloc.free(source_name);
    const host: Host = .{ .context = @ptrCast(&session), .call = callHost, .sink = sinkText, .embedded = embeddedSource };
    var value: ?[*:0]u8 = null;
    var error_text: ?[*:0]u8 = null;
    const status = fx_runcode_execute(bootstrap.ptr, bootstrap.len, catalog.ptr, root.ptr, source.ptr, source.len, source_name.ptr, @intFromBool(options.format == .esm), options.deadline_ms, &host, &value, &error_text);
    defer if (value) |text| std.c.free(@ptrCast(text));
    defer if (error_text) |text| std.c.free(@ptrCast(text));
    const console = try alloc.dupe(u8, session.console.items);
    errdefer alloc.free(console);
    const text = if (status == 0)
        try alloc.dupe(u8, if (value) |v| std.mem.span(v) else "null")
    else
        try alloc.dupe(u8, if (error_text) |e| std.mem.span(e) else "unknown error");
    return .{ .ok = status == 0, .text = text, .console = console, .console_dropped = session.dropped };
}

pub fn reportJson(alloc: std.mem.Allocator, outcome: Outcome, notice: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (outcome.ok) {
        try out.writer.writeAll("{\"ok\":true,\"value\":");
        try out.writer.writeAll(outcome.text);
    } else {
        try out.writer.writeAll("{\"ok\":false,\"error\":");
        try std.json.Stringify.value(outcome.text, .{}, &out.writer);
    }
    try out.writer.writeAll(",\"console\":");
    try std.json.Stringify.value(outcome.console, .{}, &out.writer);
    try out.writer.print(",\"console_dropped\":{d}", .{outcome.console_dropped});
    if (notice) |text| {
        try out.writer.writeAll(",\"notice\":");
        try std.json.Stringify.value(text, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub const CliOptions = struct {
    file: []const u8,
    deadline_ms: u64 = default_deadline_ms,
    format: Format = .cjs,
    run_id: ?[]const u8 = null,
};

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var file_path: ?[]const u8 = null;
    var format_given = false;
    var options: CliOptions = .{ .file = "" };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--file") and index + 1 < args.len) {
            index += 1;
            file_path = args[index];
        } else if (std.mem.eql(u8, arg, "--deadline-ms") and index + 1 < args.len) {
            index += 1;
            options.deadline_ms = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--run-id") and index + 1 < args.len) {
            index += 1;
            options.run_id = args[index];
        } else if (std.mem.eql(u8, arg, "--format") and index + 1 < args.len) {
            index += 1;
            format_given = true;
            options.format = if (std.mem.eql(u8, args[index], "esm")) .esm else .cjs;
        } else if (file_path == null and !std.mem.startsWith(u8, arg, "--")) {
            file_path = arg;
        } else {
            return error.UsageRunCode;
        }
    }
    options.file = file_path orelse return error.UsageRunCode;
    if (!format_given and std.mem.endsWith(u8, options.file, ".mjs")) options.format = .esm;
    return options;
}

pub fn runCommand(alloc: std.mem.Allocator, args: []const []const u8, verbs: Verbs) !u8 {
    const cli = try parseCliArgs(args);
    const absolute = try io_mod.realpathAlloc(alloc, cli.file);
    defer alloc.free(absolute);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute, .{});
    defer file.close(io_mod.getIo());
    const body = try io_mod.readFileToEnd(alloc, &file, max_read_bytes);
    defer alloc.free(body);
    const root = std.fs.path.dirname(absolute) orelse "/";
    const outcome = try execute(alloc, body, .{ .format = cli.format, .deadline_ms = cli.deadline_ms, .body_path = absolute, .root = root, .verbs = verbs, .run_id = cli.run_id });
    defer outcome.deinit(alloc);
    const report = try reportJson(alloc, outcome, null);
    defer alloc.free(report);
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), report);
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), "\n");
    return if (outcome.ok) 0 else 1;
}

test "fx js takes the file as its first argument and keeps the run-code flags" {
    const short = try parseCliArgs(&.{ "body.cjs", "--deadline-ms", "250" });
    try std.testing.expectEqualStrings("body.cjs", short.file);
    try std.testing.expectEqual(@as(u64, 250), short.deadline_ms);
    try std.testing.expectEqual(Format.cjs, short.format);
    const long = try parseCliArgs(&.{ "--file", "body.cjs" });
    try std.testing.expectEqualStrings("body.cjs", long.file);
}

test "a .mjs file runs as esm unless the format is given, and a second file or no file is a usage error" {
    try std.testing.expectEqual(Format.esm, (try parseCliArgs(&.{"main.mjs"})).format);
    try std.testing.expectEqual(Format.cjs, (try parseCliArgs(&.{ "main.mjs", "--format", "cjs" })).format);
    try std.testing.expectError(error.UsageRunCode, parseCliArgs(&.{ "a.mjs", "b.mjs" }));
    try std.testing.expectError(error.UsageRunCode, parseCliArgs(&.{"--deadline-ms"}));
    try std.testing.expectError(error.UsageRunCode, parseCliArgs(&.{}));
}

test "the wrapped body ends in a NUL byte past its length, so the engine's lexer never reads beyond it" {
    const cjs = try wrapBody(std.testing.allocator, "return 1;", .cjs);
    defer std.testing.allocator.free(cjs);
    try std.testing.expectEqual(@as(u8, 0), cjs[cjs.len]);
    const esm = try wrapBody(std.testing.allocator, "return 1;", .esm);
    defer std.testing.allocator.free(esm);
    try std.testing.expectEqual(@as(u8, 0), esm[esm.len]);
}
