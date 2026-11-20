const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const format_version: u32 = 1;
const dir_name = "superagent";
const max_ledger_bytes: usize = 4 * 1024 * 1024;
const max_saved_prompt_bytes: usize = 256 * 1024;

pub const Root = struct {
    agent: []const u8,
    cwd: []const u8,
    session: []const u8,
    prompt: []const u8 = "",
    in_flight: bool = false,
    queue: []const []const u8 = &.{},
    sends: u64 = 0,
    turn_ends: u64 = 0,
};

pub const Ledger = struct {
    v: u32 = format_version,
    workspace: []const u8 = "",
    host_pid: i64 = 0,
    host_stamp: u64 = 0,
    main_session: []const u8 = "",
    roots: []const Root = &.{},
};

pub const HostState = enum { live, gone };

const journal_suffix = ".journal.jsonl";
const max_journal_bytes: u64 = 1024 * 1024;
const max_journal_text_bytes: usize = 240;

pub const JournalEvent = enum { send, turn_end, wait, stop };

pub const JournalEntry = struct {
    at_ms: i64,
    root: []const u8,
    session: []const u8,
    event: JournalEvent,
    by: []const u8 = "runtime",
    decision: []const u8 = "",
    report: []const u8 = "",
    queued: usize = 0,
    text: []const u8 = "",
};

pub fn journalPath(alloc: Allocator, ledger_path: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, ledger_path, ".json")) ledger_path[0 .. ledger_path.len - ".json".len] else ledger_path;
    return std.mem.concat(alloc, u8, &.{ stem, journal_suffix });
}

pub fn journalLine(alloc: Allocator, entry: JournalEntry) ![]u8 {
    var bounded = entry;
    bounded.text = firstLineOf(entry.text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(bounded, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn firstLineOf(text: []const u8) []const u8 {
    const line_end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    var end = @min(line_end, max_journal_text_bytes);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn appendJournal(alloc: Allocator, ledger_path: []const u8, entry: JournalEntry) !void {
    const path = try journalPath(alloc, ledger_path);
    defer alloc.free(path);
    const line = try journalLine(alloc, entry);
    defer alloc.free(line);
    const zio = io_mod.getIo();
    if (std.Io.Dir.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(zio, dir);
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(zio);
    const size = (try file.stat(zio)).size;
    if (size > max_journal_bytes) try file.setLength(zio, 0);
    _ = std.c.lseek(file.handle, 0, std.posix.SEEK.END);
    try file.writeStreamingAll(zio, line);
}

pub fn filePath(alloc: Allocator, home: []const u8, workspace_root: []const u8) ![]u8 {
    var name_buf: [32]u8 = undefined;
    const name = std.mem.print(&name_buf, "{x:0>16}.json", .{std.hash.Wyhash.hash(0, workspace_root)}) catch unreachable;
    return profile_paths.rootPath(alloc, home, &.{ dir_name, name });
}

pub fn read(alloc: Allocator, path: []const u8) !?std.json.Parsed(Ledger) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(Ledger, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.value.v != format_version) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

pub fn write(alloc: Allocator, path: []const u8, ledger: Ledger) !void {
    if (std.Io.Dir.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(ledger, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

pub fn savedPrompt(prompt: []const u8) []const u8 {
    return prompt[0..@min(prompt.len, max_saved_prompt_bytes)];
}

pub fn cutRootCount(ledger: Ledger, host: HostState) usize {
    if (host == .live) return 0;
    var count: usize = 0;
    for (ledger.roots) |root| {
        if (root.in_flight) count += 1;
    }
    return count;
}

pub fn wasCut(ledger: Ledger, host: HostState) bool {
    return host == .gone and ledger.host_pid != 0 and ledger.roots.len > 0;
}

pub fn resumePrompt(alloc: Allocator, root: Root) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "fx restarted while this turn was running: a reboot, crash or exit cut it without warning. " ++
            "Continue the work below from the saved session. First read the tree state (git status, " ++
            "unpushed commits and the task's ledger), and treat every build, test or job that was " ++
            "running as not run.\n\n{s}",
        .{root.prompt},
    );
}

pub fn resumedEvent(alloc: Allocator, ledger: Ledger, host: HostState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("superagent event: fx restarted after its last run was cut. Roots brought back from saved state:\n");
    for (ledger.roots) |root| {
        const cut = root.in_flight and host == .gone;
        try out.writer.print("- {s} {s} session={s} {s}\n", .{
            root.agent,
            root.cwd,
            root.session,
            if (cut) "was cut mid-turn and is running its last prompt again from the saved session" else "was idle and is ready",
        });
    }
    try out.writer.writeAll("Each resumed root sends its turn-end event as usual. Any build, test or job that was running when the cut happened counts as not run.");
    return out.toOwnedSlice();
}

test "a ledger round trips through its file and an absent file reads as nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const path = try std.Io.Dir.path.join(alloc, &.{ dir, "nested", "ledger.json" });
    defer alloc.free(path);

    try std.testing.expect((try read(alloc, path)) == null);

    const roots = [_]Root{
        .{ .agent = "fx", .cwd = "/work/fx", .session = "s-1", .prompt = "finish the queue", .in_flight = true, .queue = &.{ "second item", "third item" }, .sends = 4, .turn_ends = 3 },
        .{ .agent = "docs", .cwd = "/work/docs", .session = "s-2" },
    };
    try write(alloc, path, .{ .workspace = "/work", .host_pid = 42, .host_stamp = 7, .main_session = "s-0", .roots = &roots });

    var loaded = (try read(alloc, path)).?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("/work", loaded.value.workspace);
    try std.testing.expectEqual(@as(i64, 42), loaded.value.host_pid);
    try std.testing.expectEqual(@as(u64, 7), loaded.value.host_stamp);
    try std.testing.expectEqualStrings("s-0", loaded.value.main_session);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.roots.len);
    try std.testing.expect(loaded.value.roots[0].in_flight);
    try std.testing.expectEqualStrings("finish the queue", loaded.value.roots[0].prompt);
    try std.testing.expect(!loaded.value.roots[1].in_flight);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.roots[0].queue.len);
    try std.testing.expectEqualStrings("third item", loaded.value.roots[0].queue[1]);
    try std.testing.expectEqual(@as(u64, 4), loaded.value.roots[0].sends);
    try std.testing.expectEqual(@as(u64, 3), loaded.value.roots[0].turn_ends);
    try std.testing.expectEqual(@as(usize, 0), loaded.value.roots[1].queue.len);
}

test "each send and turn end is one journal line beside the ledger, bounded to its first line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const ledger_path = try std.Io.Dir.path.join(alloc, &.{ dir, "abc.json" });
    defer alloc.free(ledger_path);

    try appendJournal(alloc, ledger_path, .{ .at_ms = 5, .root = "fx", .session = "s-1", .event = .turn_end, .decision = "send_queued_item", .report = "finished", .queued = 1, .text = "REPORT: finished — one\nsecond line" });
    try appendJournal(alloc, ledger_path, .{ .at_ms = 6, .root = "fx", .session = "s-1", .event = .send, .queued = 0, .text = "item two" });

    const path = try journalPath(alloc, ledger_path);
    defer alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "abc.journal.jsonl"));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(64 * 1024));
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.find(u8, first, "\"event\":\"turn_end\"") != null);
    try std.testing.expect(std.mem.find(u8, first, "\"decision\":\"send_queued_item\"") != null);
    try std.testing.expect(std.mem.find(u8, first, "second line") == null);
    try std.testing.expect(std.mem.find(u8, second, "\"event\":\"send\"") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"by\":\"runtime\"") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"text\":\"item two\"") != null);
}

test "only a ledger whose host is gone counts as cut, and only its in-flight roots run again" {
    const roots = [_]Root{
        .{ .agent = "a", .cwd = "/a", .session = "1", .prompt = "p", .in_flight = true },
        .{ .agent = "b", .cwd = "/b", .session = "2" },
    };
    const ledger = Ledger{ .host_pid = 9, .roots = &roots };
    try std.testing.expect(wasCut(ledger, .gone));
    try std.testing.expect(!wasCut(ledger, .live));
    try std.testing.expectEqual(@as(usize, 1), cutRootCount(ledger, .gone));
    try std.testing.expectEqual(@as(usize, 0), cutRootCount(ledger, .live));
    try std.testing.expect(!wasCut(.{ .host_pid = 9 }, .gone));
    try std.testing.expect(!wasCut(.{ .roots = &roots }, .gone));
}

test "a resume prompt names the cut and carries the saved prompt whole" {
    const alloc = std.testing.allocator;
    const text = try resumePrompt(alloc, .{ .agent = "fx", .cwd = "/work/fx", .session = "s", .prompt = "run the witness list", .in_flight = true });
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "cut it without warning") != null);
    try std.testing.expect(std.mem.find(u8, text, "as not run") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "run the witness list"));
}

test "the restart event lists every root and says which were cut" {
    const alloc = std.testing.allocator;
    const roots = [_]Root{
        .{ .agent = "a", .cwd = "/a", .session = "1", .prompt = "p", .in_flight = true },
        .{ .agent = "b", .cwd = "/b", .session = "2" },
    };
    const text = try resumedEvent(alloc, .{ .host_pid = 9, .roots = &roots }, .gone);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "superagent event: fx restarted"));
    try std.testing.expect(std.mem.find(u8, text, "- a /a session=1 was cut mid-turn") != null);
    try std.testing.expect(std.mem.find(u8, text, "- b /b session=2 was idle and is ready") != null);
}
