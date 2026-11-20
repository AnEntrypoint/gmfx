const std = @import("std");
const calendar = @import("calendar.zig");
const expr_mod = @import("expr.zig");
const jitter = @import("jitter.zig");
const ulid = @import("ulid.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const max_jobs = 50;
pub const max_prompt_bytes = 8 * 1024;
pub const stale_after_ms: i64 = 7 * calendar.ms_per_day;
pub const one_shot_horizon_ms: i64 = 350 * calendar.ms_per_day;
const max_coalesced: u32 = 10_000;
const max_id_attempts = 8;

pub const Id = [ulid.length]u8;

pub const Task = struct {
    id: Id,
    cron: []const u8,
    prompt: []const u8,
    created_at_ms: i64,
    recurring: bool,
    last_fired_ms: ?i64 = null,
};

pub const Options = struct {
    disabled: bool = false,
    no_jitter: bool = false,
    no_stale: bool = false,
};

pub const Fire = struct {
    task_id: Id,
    text: []u8,
    advance_to_ms: i64,
    remove: bool,
    stale: bool,
    coalesced_count: u32,
};

pub const AddError = Allocator.Error || error{CapReached};
pub const ReplayError = Allocator.Error || error{InvalidRecord};

const TaskRecord = struct {
    id: []const u8,
    cron: []const u8,
    prompt: []const u8,
    createdAt: i64,
    recurring: bool,
    lastFiredAt: ?i64 = null,
};

const AddEnvelope = struct {
    type: []const u8,
    task: TaskRecord,
};

const DeleteEnvelope = struct {
    type: []const u8,
    ids: []const []const u8,
};

const CursorEnvelope = struct {
    type: []const u8,
    id: []const u8,
    lastFiredAt: i64,
};

const TypeOnly = struct {
    type: []const u8,
};

const AddRecord = struct {
    task: TaskRecord,
};

const DeleteRecord = struct {
    ids: []const []const u8,
};

const CursorRecord = struct {
    id: []const u8,
    lastFiredAt: i64,
};

const Coalesced = struct {
    count: u32,
    last_due: i64,
};

pub const Runtime = struct {
    alloc: Allocator,
    options: Options,
    tasks: std.ArrayList(Task) = .empty,
    journal: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator, options: Options) Runtime {
        return .{ .alloc = alloc, .options = options };
    }

    pub fn deinit(self: *Runtime) void {
        for (self.tasks.items) |task| freeTask(self.alloc, task);
        self.tasks.deinit(self.alloc);
        for (self.journal.items) |line| self.alloc.free(line);
        self.journal.deinit(self.alloc);
    }

    pub fn isDisabled(self: *const Runtime) bool {
        return self.options.disabled;
    }

    pub fn list(self: *const Runtime) []const Task {
        return self.tasks.items;
    }

    pub fn get(self: *const Runtime, id: []const u8) ?Task {
        const index = self.indexOf(id) orelse return null;
        return self.tasks.items[index];
    }

    pub fn newId(self: *const Runtime, now_ms: i64) error{IdUnavailable}!Id {
        var attempt: usize = 0;
        while (attempt < max_id_attempts) : (attempt += 1) {
            var entropy: [10]u8 = undefined;
            io_mod.getIo().random(&entropy);
            const candidate = ulid.encode(now_ms, entropy);
            if (self.indexOf(&candidate) == null) return candidate;
        }
        return error.IdUnavailable;
    }

    pub fn add(
        self: *Runtime,
        id: Id,
        cron: []const u8,
        prompt: []const u8,
        created_at_ms: i64,
        recurring: bool,
    ) AddError!Task {
        if (self.tasks.items.len >= max_jobs) return error.CapReached;
        try self.tasks.ensureUnusedCapacity(self.alloc, 1);
        try self.journal.ensureUnusedCapacity(self.alloc, 1);
        const owned_cron = try self.alloc.dupe(u8, cron);
        errdefer self.alloc.free(owned_cron);
        const owned_prompt = try self.alloc.dupe(u8, prompt);
        errdefer self.alloc.free(owned_prompt);
        const task: Task = .{
            .id = id,
            .cron = owned_cron,
            .prompt = owned_prompt,
            .created_at_ms = created_at_ms,
            .recurring = recurring,
        };
        const line = try encodeAdd(self.alloc, task);
        self.tasks.appendAssumeCapacity(task);
        self.journal.appendAssumeCapacity(line);
        return task;
    }

    pub fn remove(self: *Runtime, id: []const u8) Allocator.Error!bool {
        const index = self.indexOf(id) orelse return false;
        try self.journal.ensureUnusedCapacity(self.alloc, 1);
        const line = try encodeDelete(self.alloc, id);
        freeTask(self.alloc, self.tasks.orderedRemove(index));
        self.journal.appendAssumeCapacity(line);
        return true;
    }

    pub fn acknowledge(self: *Runtime, fire: Fire) Allocator.Error!void {
        if (fire.remove) {
            _ = try self.remove(&fire.task_id);
            return;
        }
        const index = self.indexOf(&fire.task_id) orelse return;
        try self.journal.ensureUnusedCapacity(self.alloc, 1);
        const line = try encodeCursor(self.alloc, &fire.task_id, fire.advance_to_ms);
        self.tasks.items[index].last_fired_ms = fire.advance_to_ms;
        self.journal.appendAssumeCapacity(line);
    }

    pub fn drainJournal(self: *Runtime) Allocator.Error![][]u8 {
        return self.journal.toOwnedSlice(self.alloc);
    }

    pub fn retainJournal(self: *Runtime, lines: []const []u8) Allocator.Error!void {
        if (lines.len == 0) return;
        const copies = try self.alloc.alloc([]u8, lines.len);
        var copied: usize = 0;
        errdefer {
            for (copies[0..copied]) |line| self.alloc.free(line);
            self.alloc.free(copies);
        }
        while (copied < lines.len) : (copied += 1) {
            copies[copied] = try self.alloc.dupe(u8, lines[copied]);
        }
        try self.journal.insertSlice(self.alloc, 0, copies);
        self.alloc.free(copies);
    }

    pub fn replay(self: *Runtime, line: []const u8) ReplayError!void {
        const envelope = try parseRecord(TypeOnly, self.alloc, line);
        defer envelope.deinit();
        const kind = envelope.value.type;
        if (std.mem.eql(u8, kind, "cron.add")) {
            const record = try parseRecord(AddRecord, self.alloc, line);
            defer record.deinit();
            const id = parseId(record.value.task.id) orelse return error.InvalidRecord;
            try self.applyAdd(.{
                .id = id,
                .cron = record.value.task.cron,
                .prompt = record.value.task.prompt,
                .created_at_ms = record.value.task.createdAt,
                .recurring = record.value.task.recurring,
                .last_fired_ms = record.value.task.lastFiredAt,
            });
        } else if (std.mem.eql(u8, kind, "cron.delete")) {
            const record = try parseRecord(DeleteRecord, self.alloc, line);
            defer record.deinit();
            for (record.value.ids) |raw_id| {
                _ = parseId(raw_id) orelse return error.InvalidRecord;
                const index = self.indexOf(raw_id) orelse continue;
                freeTask(self.alloc, self.tasks.orderedRemove(index));
            }
        } else if (std.mem.eql(u8, kind, "cron.cursor")) {
            const record = try parseRecord(CursorRecord, self.alloc, line);
            defer record.deinit();
            _ = parseId(record.value.id) orelse return error.InvalidRecord;
            const index = self.indexOf(record.value.id) orelse return;
            self.tasks.items[index].last_fired_ms = record.value.lastFiredAt;
        } else {
            return error.InvalidRecord;
        }
    }

    pub fn collectDue(self: *Runtime, alloc: Allocator, now_ms: i64, loop_running: bool) Allocator.Error![]Fire {
        var fires: std.ArrayList(Fire) = .empty;
        errdefer {
            for (fires.items) |fire| alloc.free(fire.text);
            fires.deinit(alloc);
        }
        if (self.options.disabled or loop_running) return fires.toOwnedSlice(alloc);
        for (self.tasks.items) |task| {
            const fire = (try self.dueFire(alloc, task, now_ms)) orelse continue;
            errdefer alloc.free(fire.text);
            try fires.append(alloc, fire);
        }
        return fires.toOwnedSlice(alloc);
    }

    pub fn freeFires(alloc: Allocator, fires: []Fire) void {
        for (fires) |fire| alloc.free(fire.text);
        alloc.free(fires);
    }

    pub fn nextFireFor(self: *const Runtime, task: Task, now_ms: i64) ?i64 {
        var diag: expr_mod.Diagnostic = .{};
        const expr = expr_mod.parse(task.cron, &diag) catch return null;
        const ideal = expr_mod.nextRun(expr, baseFor(task, now_ms)) orelse return null;
        return self.jitteredNext(task, expr, ideal);
    }

    pub fn jitteredNext(self: *const Runtime, task: Task, expr: expr_mod.Expr, ideal_ms: i64) i64 {
        if (task.recurring) return jitter.recurringNext(&task.id, expr, ideal_ms, self.options.no_jitter);
        return jitter.oneShotNext(&task.id, ideal_ms, task.created_at_ms, self.options.no_jitter);
    }

    pub fn isStale(self: *const Runtime, task: Task, now_ms: i64) bool {
        if (self.options.no_stale or !task.recurring) return false;
        return now_ms - task.created_at_ms >= stale_after_ms;
    }

    fn indexOf(self: *const Runtime, id: []const u8) ?usize {
        for (self.tasks.items, 0..) |task, index| {
            if (std.mem.eql(u8, &task.id, id)) return index;
        }
        return null;
    }

    fn applyAdd(self: *Runtime, task: Task) Allocator.Error!void {
        const owned_cron = try self.alloc.dupe(u8, task.cron);
        errdefer self.alloc.free(owned_cron);
        const owned_prompt = try self.alloc.dupe(u8, task.prompt);
        errdefer self.alloc.free(owned_prompt);
        var owned = task;
        owned.cron = owned_cron;
        owned.prompt = owned_prompt;
        if (self.indexOf(&task.id)) |index| {
            freeTask(self.alloc, self.tasks.items[index]);
            self.tasks.items[index] = owned;
            return;
        }
        try self.tasks.append(self.alloc, owned);
    }

    fn dueFire(self: *const Runtime, alloc: Allocator, task: Task, now_ms: i64) Allocator.Error!?Fire {
        var diag: expr_mod.Diagnostic = .{};
        const expr = expr_mod.parse(task.cron, &diag) catch return null;
        const ideal = expr_mod.nextRun(expr, baseFor(task, now_ms)) orelse return null;
        if (now_ms < self.jitteredNext(task, expr, ideal)) return null;
        var coalesced: u32 = 1;
        var advance_to = now_ms;
        if (task.recurring) {
            const counted = self.countCoalesced(task, expr, ideal, now_ms);
            coalesced = counted.count;
            advance_to = counted.last_due;
        }
        const stale = self.isStale(task, now_ms);
        const text = try renderFire(alloc, task, coalesced, stale);
        return .{
            .task_id = task.id,
            .text = text,
            .advance_to_ms = advance_to,
            .remove = !task.recurring or stale,
            .stale = stale,
            .coalesced_count = coalesced,
        };
    }

    fn countCoalesced(self: *const Runtime, task: Task, expr: expr_mod.Expr, first_ms: i64, now_ms: i64) Coalesced {
        var count: u32 = 1;
        var cursor = first_ms;
        var last_due = first_ms;
        while (count < max_coalesced) {
            const next = expr_mod.nextRun(expr, cursor) orelse break;
            if (next > now_ms) break;
            if (jitter.recurringNext(&task.id, expr, next, self.options.no_jitter) > now_ms) break;
            count += 1;
            cursor = next;
            last_due = next;
        }
        return .{ .count = count, .last_due = last_due };
    }
};

fn baseFor(task: Task, now_ms: i64) i64 {
    if (task.last_fired_ms) |last| {
        if (last <= now_ms and last > task.created_at_ms) return last;
    }
    return task.created_at_ms;
}

fn freeTask(alloc: Allocator, task: Task) void {
    alloc.free(task.cron);
    alloc.free(task.prompt);
}

fn parseId(text: []const u8) ?Id {
    if (text.len != ulid.length) return null;
    var id: Id = undefined;
    @memcpy(&id, text);
    return id;
}

fn parseRecord(comptime T: type, alloc: Allocator, line: []const u8) ReplayError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRecord,
    };
}

fn encodeAdd(alloc: Allocator, task: Task) Allocator.Error![]u8 {
    const id_text: []const u8 = &task.id;
    return std.json.Stringify.valueAlloc(alloc, AddEnvelope{
        .type = "cron.add",
        .task = .{
            .id = id_text,
            .cron = task.cron,
            .prompt = task.prompt,
            .createdAt = task.created_at_ms,
            .recurring = task.recurring,
            .lastFiredAt = task.last_fired_ms,
        },
    }, .{}) catch return error.OutOfMemory;
}

fn encodeDelete(alloc: Allocator, id: []const u8) Allocator.Error![]u8 {
    const ids = [_][]const u8{id};
    return std.json.Stringify.valueAlloc(alloc, DeleteEnvelope{
        .type = "cron.delete",
        .ids = &ids,
    }, .{}) catch return error.OutOfMemory;
}

fn encodeCursor(alloc: Allocator, id: []const u8, last_fired_ms: i64) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, CursorEnvelope{
        .type = "cron.cursor",
        .id = id,
        .lastFiredAt = last_fired_ms,
    }, .{}) catch return error.OutOfMemory;
}

fn renderFire(alloc: Allocator, task: Task, coalesced: u32, stale: bool) Allocator.Error![]u8 {
    const id_text: []const u8 = &task.id;
    const cron_text = try escapeAttr(alloc, task.cron);
    defer alloc.free(cron_text);
    const recurring_text: []const u8 = if (task.recurring) "true" else "false";
    const stale_text: []const u8 = if (stale) "true" else "false";
    return std.fmt.allocPrint(
        alloc,
        "<cron-fire jobId=\"{s}\" cron=\"{s}\" recurring=\"{s}\" coalescedCount=\"{d}\" stale=\"{s}\">\n<prompt>\n{s}\n</prompt>\n</cron-fire>",
        .{ id_text, cron_text, recurring_text, coalesced, stale_text, task.prompt },
    );
}

fn escapeAttr(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (text) |char| switch (char) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        else => try out.append(alloc, char),
    };
    return out.toOwnedSlice(alloc);
}

fn freeJournal(alloc: Allocator, lines: [][]u8) void {
    for (lines) |line| alloc.free(line);
    alloc.free(lines);
}

fn testTask(runtime: *Runtime, id_seed: u8, cron: []const u8, created_at_ms: i64, recurring: bool) !Task {
    const id = ulid.encode(created_at_ms, @as([10]u8, @splat(id_seed)));
    return runtime.add(id, cron, "check build", created_at_ms, recurring);
}

test "cron runtime coalesces missed recurring fires and advances its cursor" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, .{ .no_jitter = true });
    defer runtime.deinit();
    const created: i64 = 1_704_067_230_000;
    const task = try testTask(&runtime, 1, "* * * * *", created, true);
    const fires = try runtime.collectDue(alloc, created + 120_000, false);
    defer Runtime.freeFires(alloc, fires);
    try std.testing.expectEqual(@as(usize, 1), fires.len);
    try std.testing.expectEqual(@as(u32, 2), fires[0].coalesced_count);
    try std.testing.expect(std.mem.indexOf(u8, fires[0].text, "coalescedCount=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fires[0].text, "<prompt>\ncheck build\n</prompt>") != null);
    try runtime.acknowledge(fires[0]);
    try std.testing.expectEqual(@as(?i64, created + 90_000), runtime.get(&task.id).?.last_fired_ms);
    const again = try runtime.collectDue(alloc, created + 120_000, false);
    defer Runtime.freeFires(alloc, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
}

test "cron runtime removes a one-shot job once it fires" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, .{ .no_jitter = true });
    defer runtime.deinit();
    const new_year: i64 = 1_704_067_200_000;
    const task = try testTask(&runtime, 2, "0 0 1 1 *", new_year - 60_000, false);
    const fires = try runtime.collectDue(alloc, new_year + 1_000, false);
    defer Runtime.freeFires(alloc, fires);
    try std.testing.expectEqual(@as(usize, 1), fires.len);
    try std.testing.expect(fires[0].remove);
    try runtime.acknowledge(fires[0]);
    try std.testing.expect(runtime.get(&task.id) == null);
    const lines = try runtime.drainJournal();
    defer freeJournal(alloc, lines);
    try std.testing.expect(std.mem.indexOf(u8, lines[lines.len - 1], "\"type\":\"cron.delete\"") != null);
}

test "cron runtime journals each change and replays it into a fresh runtime" {
    const alloc = std.testing.allocator;
    var source = Runtime.init(alloc, .{ .no_jitter = true });
    defer source.deinit();
    const created: i64 = 1_704_067_230_000;
    const task = try testTask(&source, 3, "*/10 * * * *", created, true);
    const first = try source.drainJournal();
    defer freeJournal(alloc, first);
    var restored = Runtime.init(alloc, .{});
    defer restored.deinit();
    for (first) |line| try restored.replay(line);
    try std.testing.expectEqual(@as(usize, 1), restored.list().len);
    try std.testing.expectEqualStrings("check build", restored.list()[0].prompt);
    try std.testing.expectEqualSlices(u8, &task.id, &restored.list()[0].id);
    try std.testing.expect(try source.remove(&task.id));
    const second = try source.drainJournal();
    defer freeJournal(alloc, second);
    for (second) |line| try restored.replay(line);
    try std.testing.expectEqual(@as(usize, 0), restored.list().len);
}

test "cron runtime refuses a job beyond the session cap" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, .{});
    defer runtime.deinit();
    var index: usize = 0;
    while (index < max_jobs) : (index += 1) {
        _ = try testTask(&runtime, 4, "0 0 * * *", @as(i64, @intCast(1_000 + index)), true);
    }
    try std.testing.expectError(error.CapReached, testTask(&runtime, 4, "0 0 * * *", 9_999, true));
}

test "cron runtime marks week-old recurring jobs stale unless stale checks are off" {
    const alloc = std.testing.allocator;
    const created: i64 = 1_704_067_200_000;
    var runtime = Runtime.init(alloc, .{});
    defer runtime.deinit();
    const task = try testTask(&runtime, 5, "0 0 * * *", created, true);
    try std.testing.expect(runtime.isStale(task, created + 8 * calendar.ms_per_day));
    try std.testing.expect(!runtime.isStale(task, created + calendar.ms_per_day));
    var quiet = Runtime.init(alloc, .{ .no_stale = true });
    defer quiet.deinit();
    const quiet_task = try testTask(&quiet, 5, "0 0 * * *", created, true);
    try std.testing.expect(!quiet.isStale(quiet_task, created + 8 * calendar.ms_per_day));
}

test "cron runtime fires nothing while disabled or while the loop is busy" {
    const alloc = std.testing.allocator;
    const created: i64 = 1_704_067_200_000;
    var disabled = Runtime.init(alloc, .{ .disabled = true, .no_jitter = true });
    defer disabled.deinit();
    _ = try testTask(&disabled, 6, "* * * * *", created, true);
    const none = try disabled.collectDue(alloc, created + 300_000, false);
    defer Runtime.freeFires(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var busy = Runtime.init(alloc, .{ .no_jitter = true });
    defer busy.deinit();
    _ = try testTask(&busy, 7, "* * * * *", created, true);
    const held = try busy.collectDue(alloc, created + 300_000, true);
    defer Runtime.freeFires(alloc, held);
    try std.testing.expectEqual(@as(usize, 0), held.len);
}

test "cron runtime mints ULID ids that the store has not seen" {
    var runtime = Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const id = try runtime.newId(1_704_067_200_000);
    try std.testing.expect(ulid.isId(&id));
    try std.testing.expect(runtime.get(&id) == null);
}
