const std = @import("std");
const full_transcript_metadata = @import("../output/full_transcript_metadata.zig");

const Allocator = std.mem.Allocator;

pub const max_rows: usize = 64;
pub const max_command_bytes: usize = 2000;
pub const max_files: usize = 16;
pub const failed_without_exit_code: i64 = -1;

pub const Outcome = enum { pending, passed, failed };

pub const Selection = enum {
    pending,
    failed,

    pub fn parse(text: []const u8) ?Selection {
        return std.meta.stringToEnum(Selection, text);
    }
};

pub const Row = struct {
    id: []const u8,
    command: []const u8,
    files: []const []const u8 = &.{},
    added_at_ms: i64 = 0,
    runs: u32 = 0,
    exit_code: ?i64 = null,
    wall_ms: ?u64 = null,
    ran_at_ms: ?i64 = null,

    pub fn outcome(self: Row) Outcome {
        const code = self.exit_code orelse return .pending;
        return if (code == 0) .passed else .failed;
    }

    fn selectedBy(self: Row, selection: Selection) bool {
        return switch (selection) {
            .pending => self.outcome() == .pending,
            .failed => self.outcome() == .failed,
        };
    }
};

pub const Counts = struct {
    pending: usize = 0,
    passed: usize = 0,
    failed: usize = 0,

    pub fn total(self: Counts) usize {
        return self.pending + self.passed + self.failed;
    }
};

pub const PutError = Allocator.Error || error{ TooManyChecks, CheckCommandEmpty, CheckCommandTooLong, TooManyCheckFiles };

pub fn putErrorMessage(err: PutError) []const u8 {
    return switch (err) {
        error.TooManyChecks => "A session records at most 64 checks; remove a todo that carries one first",
        error.CheckCommandEmpty => "A check must be a non-empty command",
        error.CheckCommandTooLong => "A check command is at most 2000 bytes; put a long command in a script and record the script",
        error.TooManyCheckFiles => "A check lists at most 16 files",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn sameCommand(a: []const u8, b: []const u8) bool {
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (true) {
        const x = left.next();
        const y = right.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

fn fileMatches(recorded: []const u8, changed: []const u8) bool {
    if (recorded.len == 0 or changed.len == 0) return false;
    if (std.mem.eql(u8, recorded, changed)) return true;
    return endsWithPath(changed, recorded) or endsWithPath(recorded, changed);
}

fn endsWithPath(long: []const u8, short: []const u8) bool {
    if (long.len <= short.len) return false;
    if (!std.mem.endsWith(u8, long, short)) return false;
    const before = long[long.len - short.len - 1];
    return before == '/' or before == '\\';
}

pub const Ledger = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},

    pub fn deinit(self: *Ledger) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn restore(self: *Ledger, rows: []const Row) Allocator.Error!void {
        var next = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer next.deinit();
        const arena = next.allocator();
        const kept = @min(rows.len, max_rows);
        const owned = try arena.alloc(Row, kept);
        for (rows[0..kept], owned) |source, *target| target.* = try dupeRow(arena, source);
        if (self.arena) |*old| old.deinit();
        self.arena = next;
        self.rows = owned;
    }

    pub fn find(self: *const Ledger, id: []const u8) ?Row {
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.id, id)) return row;
        }
        return null;
    }

    pub fn put(self: *Ledger, id: []const u8, command: []const u8, files: []const []const u8, now_ms: i64) PutError!void {
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) return error.CheckCommandEmpty;
        if (command.len > max_command_bytes) return error.CheckCommandTooLong;
        if (files.len > max_files) return error.TooManyCheckFiles;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var next: std.ArrayList(Row) = .empty;
        var replaced = false;
        for (self.rows) |row| {
            if (!std.mem.eql(u8, row.id, id)) {
                try next.append(scratch, row);
                continue;
            }
            replaced = true;
            if (sameCommand(row.command, command)) {
                var kept = row;
                kept.files = files;
                try next.append(scratch, kept);
            } else {
                try next.append(scratch, .{ .id = id, .command = command, .files = files, .added_at_ms = now_ms });
            }
        }
        if (!replaced) {
            if (next.items.len >= max_rows) return error.TooManyChecks;
            try next.append(scratch, .{ .id = id, .command = command, .files = files, .added_at_ms = now_ms });
        }
        try self.restore(next.items);
    }

    pub fn remove(self: *Ledger, id: []const u8) Allocator.Error!bool {
        if (self.find(id) == null) return false;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var next: std.ArrayList(Row) = .empty;
        for (self.rows) |row| {
            if (!std.mem.eql(u8, row.id, id)) try next.append(scratch, row);
        }
        try self.restore(next.items);
        return true;
    }

    pub fn observe(self: *Ledger, command: []const u8, exit_code: i64, wall_ms: u64, now_ms: i64) Allocator.Error!usize {
        var matched: usize = 0;
        for (self.rows) |row| matched += @intFromBool(sameCommand(row.command, command));
        if (matched == 0) return 0;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const next = try scratch.dupe(Row, self.rows);
        for (next) |*row| {
            if (!sameCommand(row.command, command)) continue;
            row.runs += 1;
            row.exit_code = exit_code;
            row.wall_ms = wall_ms;
            row.ran_at_ms = now_ms;
        }
        try self.restore(next);
        return matched;
    }

    pub fn invalidateFile(self: *Ledger, path: []const u8) Allocator.Error!usize {
        var stale: usize = 0;
        for (self.rows) |row| stale += @intFromBool(rowCoversFile(row, path));
        if (stale == 0) return 0;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const next = try scratch.dupe(Row, self.rows);
        for (next) |*row| {
            if (!rowCoversFile(row.*, path)) continue;
            row.exit_code = null;
            row.wall_ms = null;
            row.ran_at_ms = null;
        }
        try self.restore(next);
        return stale;
    }

    pub fn counts(self: *const Ledger) Counts {
        var result: Counts = .{};
        for (self.rows) |row| switch (row.outcome()) {
            .pending => result.pending += 1,
            .passed => result.passed += 1,
            .failed => result.failed += 1,
        };
        return result;
    }

    pub fn renderSelection(self: *const Ledger, alloc: Allocator, selection: Selection) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        self.writeSelection(&out.writer, selection) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn writeSelection(self: *const Ledger, writer: *std.Io.Writer, selection: Selection) std.Io.Writer.Error!void {
        var selected: usize = 0;
        for (self.rows) |row| selected += @intFromBool(row.selectedBy(selection));
        if (selected == 0) {
            try writer.writeAll(switch (selection) {
                .pending => "No recorded check is waiting to run.",
                .failed => "No recorded check has failed.",
            });
        } else {
            try writer.print("{s} ({d}). Run each once with Bash, exactly as written; send independent commands in one response:", .{
                switch (selection) {
                    .pending => "Recorded checks that have not run",
                    .failed => "Recorded checks that failed",
                },
                selected,
            });
            for (self.rows) |row| {
                if (!row.selectedBy(selection)) continue;
                try writer.print("\n- {s}: `{s}`", .{ row.id, row.command });
                try writeResult(writer, row);
                try writeFiles(writer, row.files);
            }
            try writer.writeAll("\nfx records the exit code and wall time of each against its row when the command finishes.");
        }
        const totals = self.counts();
        if (totals.total() > 0) {
            try writer.print("\nRecorded checks: {d} passed, {d} failed, {d} not run.", .{ totals.passed, totals.failed, totals.pending });
        }
    }
};

fn rowCoversFile(row: Row, path: []const u8) bool {
    if (row.exit_code == null) return false;
    for (row.files) |file| {
        if (fileMatches(file, path)) return true;
    }
    return false;
}

pub fn writeResult(writer: *std.Io.Writer, row: Row) std.Io.Writer.Error!void {
    const code = row.exit_code orelse return;
    if (code == 0) {
        try writer.writeAll(" (passed");
    } else if (code == failed_without_exit_code) {
        try writer.writeAll(" (failed without an exit code");
    } else {
        try writer.print(" (failed, exit {d}", .{code});
    }
    if (row.wall_ms) |wall_ms| {
        try writer.writeAll(", ");
        try full_transcript_metadata.writeDuration(writer, wall_ms);
    }
    if (row.runs > 1) try writer.print(", run {d} times", .{row.runs});
    try writer.writeByte(')');
}

fn writeFiles(writer: *std.Io.Writer, files: []const []const u8) std.Io.Writer.Error!void {
    if (files.len == 0) return;
    try writer.writeAll(" files: ");
    for (files, 0..) |file, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll(file);
    }
}

fn dupeRow(arena: Allocator, source: Row) Allocator.Error!Row {
    const files = try arena.alloc([]const u8, @min(source.files.len, max_files));
    for (source.files[0..files.len], files) |file, *target| target.* = try arena.dupe(u8, file);
    var copy = source;
    copy.id = try arena.dupe(u8, source.id);
    copy.command = try arena.dupe(u8, source.command);
    copy.files = files;
    return copy;
}

test "a recorded check is pending until its command runs, then keeps exit code and wall time" {
    var ledger: Ledger = .{};
    defer ledger.deinit();
    try ledger.put("t1", "zig build test", &.{"src/a.zig"}, 100);
    try std.testing.expectEqual(Outcome.pending, ledger.find("t1").?.outcome());
    try std.testing.expectEqual(@as(usize, 0), try ledger.observe("ls", 0, 5, 150));
    try std.testing.expectEqual(@as(usize, 1), try ledger.observe("  zig   build\ttest ", 1, 2300, 200));
    const failed = ledger.find("t1").?;
    try std.testing.expectEqual(Outcome.failed, failed.outcome());
    try std.testing.expectEqual(@as(i64, 1), failed.exit_code.?);
    try std.testing.expectEqual(@as(u64, 2300), failed.wall_ms.?);
    try std.testing.expectEqual(@as(i64, 200), failed.ran_at_ms.?);
    try std.testing.expectEqual(@as(u32, 1), failed.runs);
    try std.testing.expectEqual(@as(i64, 100), failed.added_at_ms);
    try std.testing.expectEqual(@as(usize, 1), try ledger.observe("zig build test", 0, 900, 300));
    const passed = ledger.find("t1").?;
    try std.testing.expectEqual(Outcome.passed, passed.outcome());
    try std.testing.expectEqual(@as(u32, 2), passed.runs);
}

test "the pending selection lists only rows that never ran and the failed selection only failed rows" {
    const alloc = std.testing.allocator;
    var ledger: Ledger = .{};
    defer ledger.deinit();
    try ledger.put("t1", "make unit", &.{}, 1);
    try ledger.put("t2", "make lint", &.{"lint.cfg"}, 2);
    try ledger.put("t3", "make e2e", &.{}, 3);
    _ = try ledger.observe("make unit", 0, 1200, 10);
    _ = try ledger.observe("make lint", 2, 61_000, 11);

    const pending = try ledger.renderSelection(alloc, .pending);
    defer alloc.free(pending);
    try std.testing.expectEqualStrings(
        "Recorded checks that have not run (1). Run each once with Bash, exactly as written; send independent commands in one response:\n" ++
            "- t3: `make e2e`\n" ++
            "fx records the exit code and wall time of each against its row when the command finishes.\n" ++
            "Recorded checks: 1 passed, 1 failed, 1 not run.",
        pending,
    );

    const failed = try ledger.renderSelection(alloc, .failed);
    defer alloc.free(failed);
    try std.testing.expectEqualStrings(
        "Recorded checks that failed (1). Run each once with Bash, exactly as written; send independent commands in one response:\n" ++
            "- t2: `make lint` (failed, exit 2, 1m 1s) files: lint.cfg\n" ++
            "fx records the exit code and wall time of each against its row when the command finishes.\n" ++
            "Recorded checks: 1 passed, 1 failed, 1 not run.",
        failed,
    );

    _ = try ledger.observe("make lint", 0, 500, 12);
    _ = try ledger.observe("make e2e", 0, 500, 13);
    const none_failed = try ledger.renderSelection(alloc, .failed);
    defer alloc.free(none_failed);
    try std.testing.expectEqualStrings("No recorded check has failed.\nRecorded checks: 3 passed, 0 failed, 0 not run.", none_failed);
}

test "changing a check's command resets its result and keeping the command keeps it" {
    var ledger: Ledger = .{};
    defer ledger.deinit();
    try ledger.put("t1", "make unit", &.{}, 1);
    _ = try ledger.observe("make unit", 0, 10, 2);
    try ledger.put("t1", "make  unit", &.{"a.zig"}, 3);
    try std.testing.expectEqual(Outcome.passed, ledger.find("t1").?.outcome());
    try std.testing.expectEqualStrings("a.zig", ledger.find("t1").?.files[0]);
    try ledger.put("t1", "make all", &.{}, 4);
    const row = ledger.find("t1").?;
    try std.testing.expectEqual(Outcome.pending, row.outcome());
    try std.testing.expectEqual(@as(i64, 4), row.added_at_ms);
    try std.testing.expectEqual(@as(usize, 1), ledger.rows.len);
}

test "a change to a recorded file sends a finished check back to pending" {
    var ledger: Ledger = .{};
    defer ledger.deinit();
    try ledger.put("t1", "make unit", &.{"src/core/a.zig"}, 1);
    try ledger.put("t2", "make lint", &.{"b.zig"}, 1);
    _ = try ledger.observe("make unit", 0, 10, 2);
    _ = try ledger.observe("make lint", 0, 10, 2);
    try std.testing.expectEqual(@as(usize, 1), try ledger.invalidateFile("/work/src/core/a.zig"));
    try std.testing.expectEqual(Outcome.pending, ledger.find("t1").?.outcome());
    try std.testing.expectEqual(Outcome.passed, ledger.find("t2").?.outcome());
    try std.testing.expectEqual(@as(usize, 0), try ledger.invalidateFile("/work/src/core/a.zig"));
    try std.testing.expectEqual(@as(usize, 0), try ledger.invalidateFile("/work/src/core/xa.zig"));
}

test "a ledger refuses an empty command, a 65th row and too many files, and removes by id" {
    var ledger: Ledger = .{};
    defer ledger.deinit();
    try std.testing.expectError(error.CheckCommandEmpty, ledger.put("t1", " \n", &.{}, 1));
    const many_files: [max_files + 1][]const u8 = @splat("f");
    try std.testing.expectError(error.TooManyCheckFiles, ledger.put("t1", "make", &many_files, 1));
    var id_buffer: [16]u8 = undefined;
    for (0..max_rows) |index| {
        const id = std.mem.print(&id_buffer, "t{d}", .{index + 1}) catch unreachable;
        try ledger.put(id, "make", &.{}, 1);
    }
    try std.testing.expectError(error.TooManyChecks, ledger.put("extra", "make", &.{}, 1));
    try std.testing.expect(try ledger.remove("t1"));
    try std.testing.expect(!try ledger.remove("t1"));
    try ledger.put("extra", "make", &.{}, 1);
    try std.testing.expectEqual(max_rows, ledger.rows.len);
}

test "two sessions keep separate ledgers" {
    var first: Ledger = .{};
    defer first.deinit();
    var second: Ledger = .{};
    defer second.deinit();
    try first.put("t1", "make unit", &.{}, 1);
    try second.put("t1", "make unit", &.{}, 1);
    try std.testing.expectEqual(@as(usize, 1), try first.observe("make unit", 0, 10, 2));
    try std.testing.expectEqual(Outcome.passed, first.find("t1").?.outcome());
    try std.testing.expectEqual(Outcome.pending, second.find("t1").?.outcome());
}
