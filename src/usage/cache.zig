const std = @import("std");
const report = @import("report.zig");
const codex = @import("codex.zig");
const grok = @import("grok.zig");
const json_decode = @import("../core/shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_name = "usage-cache";
pub const schema_version: u32 = 2;
const max_file_bytes: usize = 4 * 1024 * 1024;

pub const Identity = [64]u8;

pub fn identityOf(scope: report.Scope, subject: []const u8, team: []const u8) Identity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-usage-cache-v1\x00");
    hash.update(@tagName(scope));
    hash.update("\x00");
    hash.update(subject);
    hash.update("\x00");
    hash.update(team);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub const Today = struct {
    day: i64,
    at_ms: i64,
    models: []const report.ModelRow,
};

pub const Finished = struct {
    day: i64,
    at_ms: i64,
    days_7: []const report.ModelRow,
    month: []const report.ModelRow,
};

pub const Budget = struct {
    at_ms: i64,
    value: report.Budget,
};

pub const Codex = struct {
    at_ms: i64,
    value: codex.Usage,
};

pub const Grok = struct {
    at_ms: i64,
    value: grok.Usage,
};

pub const Entry = struct {
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub fn merge(stored: Entry, fetched: Entry, now_ms: i64) Entry {
    const s: Entry = .{
        .today = notAfter(Today, stored.today, now_ms),
        .finished = finishedBy(stored.finished, now_ms),
        .budget = notAfter(Budget, stored.budget, now_ms),
        .codex = notAfter(Codex, stored.codex, now_ms),
        .grok = notAfter(Grok, stored.grok, now_ms),
    };
    return .{
        .today = newer(Today, s.today, fetched.today, todayKey),
        .finished = newer(Finished, s.finished, finishedBy(fetched.finished, now_ms), finishedKey),
        .budget = newer(Budget, s.budget, fetched.budget, budgetKey),
        .codex = mergeCodex(s.codex, fetched.codex),
        .grok = mergeGrok(s.grok, fetched.grok),
    };
}

fn finishedBy(part: ?Finished, now_ms: i64) ?Finished {
    const f = part orelse return null;
    return if (f.day > report.utcDay(now_ms)) null else f;
}

fn notAfter(comptime T: type, part: ?T, now_ms: i64) ?T {
    const p = part orelse return null;
    return if (p.at_ms > now_ms) null else p;
}

fn mergeGrok(stored: ?Grok, fetched: ?Grok) ?Grok {
    var result = newer(Grok, stored, fetched, grokKey) orelse return null;
    if (stored) |s| if (result.value.settings == null) {
        result.value.settings = s.value.settings;
    };
    return result;
}

fn grokKey(g: Grok) i64 {
    return g.at_ms;
}

fn mergeCodex(stored: ?Codex, fetched: ?Codex) ?Codex {
    var result = newer(Codex, stored, fetched, codexKey) orelse return null;
    if (stored) |s| {
        if (result.value.profile == null) result.value.profile = s.value.profile;
        if (result.value.breakdown == null) result.value.breakdown = s.value.breakdown;
    }
    return result;
}

fn codexKey(c: Codex) i64 {
    return c.at_ms;
}

fn todayKey(t: Today) i64 {
    return t.at_ms;
}

fn finishedKey(f: Finished) i64 {
    return f.day;
}

fn budgetKey(b: Budget) i64 {
    return b.at_ms;
}

fn newer(comptime T: type, stored: ?T, fetched: ?T, key: fn (T) i64) ?T {
    const s = stored orelse return fetched;
    const f = fetched orelse return s;
    return if (key(f) >= key(s)) f else s;
}

const Wire = struct {
    schema_version: u32,
    identity: []const u8,
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

pub fn encode(alloc: Allocator, identity: Identity, entry: Entry) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Wire{
        .schema_version = schema_version,
        .identity = &identity,
        .today = entry.today,
        .finished = entry.finished,
        .budget = entry.budget,
        .codex = entry.codex,
        .grok = entry.grok,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn decode(gpa: Allocator, identity: Identity, bytes: []const u8) ?Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const wire = json_decode.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch {
        arena.deinit();
        return null;
    };
    if (wire.schema_version != schema_version or
        !std.mem.eql(u8, wire.identity, &identity) or
        !validEntry(.{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok }))
    {
        arena.deinit();
        return null;
    }
    return .{ .arena = arena, .entry = .{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok } };
}

fn validRows(rows: []const report.ModelRow) bool {
    if (rows.len > report.max_models) return false;
    for (rows) |row| {
        if (row.model.len == 0 or row.model.len > 256) return false;
        if (!row.totals.valid()) return false;
    }
    return true;
}

fn validMoney(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn validEntry(entry: Entry) bool {
    if (entry.today) |t| if (!validRows(t.models)) return false;
    if (entry.finished) |f| if (!validRows(f.days_7) or !validRows(f.month)) return false;
    if (entry.budget) |b| if (!validMoney(b.value.limit) or !validMoney(b.value.spent)) return false;
    if (entry.codex) |c| if (!c.value.valid()) return false;
    if (entry.grok) |g| if (!g.value.valid()) return false;
    return true;
}

fn fileName(buf: *[80]u8, identity: Identity, suffix: []const u8) []const u8 {
    return std.mem.print(buf, "{s}{s}", .{ &identity, suffix }) catch unreachable;
}

pub fn read(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity) ?Owned {
    var dir = fx_dir.openDir(io, dir_name, .{}) catch return null;
    defer dir.close(io);
    var name_buf: [80]u8 = undefined;
    const bytes = dir.readFileAlloc(io, fileName(&name_buf, identity, ".json"), gpa, .limited(max_file_bytes)) catch return null;
    defer gpa.free(bytes);
    return decode(gpa, identity, bytes);
}

pub fn own(gpa: Allocator, identity: Identity, entry: Entry) !Owned {
    if (!validEntry(entry)) return error.InvalidCache;
    const bytes = try encode(gpa, identity, entry);
    defer gpa.free(bytes);
    return decode(gpa, identity, bytes) orelse error.InvalidCache;
}

pub fn store(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity, fetched: Entry, now_ms: i64, held: ?Entry) !Owned {
    fx_dir.createDir(io, dir_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try fx_dir.openDir(io, dir_name, .{});
    defer dir.close(io);

    var name_buf: [80]u8 = undefined;
    var lock = try dir.createFile(io, fileName(&name_buf, identity, ".lock"), .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io);

    var stored = read(gpa, io, fx_dir, identity);
    defer if (stored) |*s| s.deinit();
    const base: Entry = if (stored) |s| (if (held) |h| merge(h, s.entry, now_ms) else s.entry) else held orelse .{};
    const merged = merge(base, fetched, now_ms);
    if (!validEntry(merged)) return error.InvalidCache;

    const bytes = try encode(gpa, identity, merged);
    defer gpa.free(bytes);
    var tmp_buf: [80]u8 = undefined;
    const tmp_name = fileName(&tmp_buf, identity, ".tmp");
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.rename(tmp_name, dir, fileName(&name_buf, identity, ".json"), io);

    return decode(gpa, identity, bytes) orelse error.InvalidCache;
}

const testing = std.testing;
const test_now: i64 = 6 * std.time.ms_per_day;

fn oneRow(comptime cost: f64) []const report.ModelRow {
    return &.{.{ .model = "anthropic/claude-opus-5.5", .totals = .{ .request_count = 2, .total_cost = cost } }};
}

test "merge keeps the newer part of each half" {
    const old: Entry = .{
        .today = .{ .day = 10, .at_ms = 200, .models = oneRow(2) },
        .finished = .{ .day = 10, .at_ms = 100, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = 200, .value = .{ .limit = 100, .spent = 5, .period = .monthly } },
    };

    const late = merge(old, .{ .today = .{ .day = 10, .at_ms = 150, .models = oneRow(1) } }, 11 * std.time.ms_per_day);
    try testing.expectEqual(@as(i64, 200), late.today.?.at_ms);
    try testing.expectEqual(@as(f64, 7), late.finished.?.days_7[0].totals.total_cost);

    const fresh = merge(old, .{ .today = .{ .day = 10, .at_ms = 300, .models = oneRow(3) } }, 11 * std.time.ms_per_day);
    try testing.expectEqual(@as(f64, 3), fresh.today.?.models[0].totals.total_cost);
    try testing.expectEqual(@as(i64, 10), fresh.finished.?.day);
    try testing.expectEqual(@as(f64, 5), fresh.budget.?.value.spent);
}

test "the cache file round-trips and rejects other identities" {
    const a = identityOf(.member, "acct_1", "team_1");
    const b = identityOf(.api_key, "acct_1", "team_1");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    const entry: Entry = .{
        .today = .{ .day = 20737, .at_ms = 1, .models = oneRow(1.5) },
        .budget = .{ .at_ms = 1, .value = .{ .limit = 31600, .spent = 6596.55, .period = .monthly } },
    };
    const bytes = try encode(testing.allocator, a, entry);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, "acct_1") == null);
    var decoded = decode(testing.allocator, a, bytes).?;
    defer decoded.deinit();
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
    try testing.expectEqual(report.RefreshPeriod.monthly, decoded.entry.budget.?.value.period);
    try testing.expect(decode(testing.allocator, b, bytes) == null);
    try testing.expect(decode(testing.allocator, a, "{\"schema_version\":2}") == null);
    try testing.expect(decode(testing.allocator, a, "garbage") == null);
}

test "a decoded entry outlives the bytes it came from" {
    const id = identityOf(.api_key, "k", "");
    const encoded = try encode(testing.allocator, id, .{ .today = .{ .day = 1, .at_ms = 1, .models = oneRow(1) } });
    var decoded = decode(testing.allocator, id, encoded).?;
    defer decoded.deinit();
    @memset(encoded, 'x');
    testing.allocator.free(encoded);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
}

test "store merges under the lock and never regresses today" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.member, "acct_1", "team_1");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 500, .models = oneRow(5) },
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    first.deinit();
    var second = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 400, .models = oneRow(4) },
    }, test_now, null);
    defer second.deinit();
    try testing.expectEqual(@as(i64, 500), second.entry.today.?.at_ms);
    try testing.expectEqual(@as(i64, 5), second.entry.finished.?.day);
    var again = read(testing.allocator, io, tmp.dir, id).?;
    defer again.deinit();
    try testing.expectEqual(@as(f64, 5), again.entry.today.?.models[0].totals.total_cost);
}

test "a part stored while the clock ran ahead yields to the next fetch" {
    const day: i64 = 20737;
    const at = day * std.time.ms_per_day + 3 * std.time.ms_per_hour;
    const tomorrow = at + std.time.ms_per_day;
    const ahead: Entry = .{
        .today = .{ .day = day + 1, .at_ms = tomorrow, .models = oneRow(6) },
        .finished = .{ .day = day + 1, .at_ms = tomorrow, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = tomorrow, .value = .{ .limit = 100, .spent = 60, .period = .monthly } },
    };
    const fetched: Entry = .{
        .today = .{ .day = day, .at_ms = at, .models = oneRow(3) },
        .finished = .{ .day = day, .at_ms = at, .days_7 = oneRow(70), .month = oneRow(300) },
    };

    const corrected = merge(ahead, fetched, at + std.time.ms_per_min);
    try testing.expectEqual(at, corrected.today.?.at_ms);
    try testing.expectEqual(day, corrected.finished.?.day);
    try testing.expect(corrected.budget == null);

    const later = merge(ahead, fetched, tomorrow + std.time.ms_per_min);
    try testing.expectEqual(tomorrow, later.today.?.at_ms);
    try testing.expectEqual(day + 1, later.finished.?.day);
    try testing.expectEqual(@as(f64, 60), later.budget.?.value.spent);

    const same_day: Entry = .{
        .today = .{ .day = day, .at_ms = at + 10 * std.time.ms_per_min, .models = oneRow(4) },
        .finished = .{ .day = day, .at_ms = at + 10 * std.time.ms_per_min, .days_7 = oneRow(7), .month = oneRow(30) },
    };
    const small = merge(same_day, .{ .today = .{ .day = day, .at_ms = at, .models = oneRow(3) } }, at + std.time.ms_per_min);
    try testing.expectEqual(at, small.today.?.at_ms);
    try testing.expect(small.finished != null);
    try testing.expectEqual(@as(f64, 7), small.finished.?.days_7[0].totals.total_cost);

    const straddling = merge(fetched, ahead, at + std.time.ms_per_min);
    try testing.expectEqual(day, straddling.finished.?.day);
    try testing.expectEqual(tomorrow, straddling.today.?.at_ms);
}

test "a store never keeps less than the caller holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.api_key, "k", "");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    defer first.deinit();
    var name_buf: [80]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}/{s}", .{ dir_name, fileName(&name_buf, id, ".json") });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "garbage" });

    var second = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 600, .models = oneRow(4) },
    }, test_now, first.entry);
    defer second.deinit();
    try testing.expect(second.entry.finished != null);
    try testing.expectEqual(@as(i64, 5), second.entry.finished.?.day);
    const read_back = read(testing.allocator, io, tmp.dir, id);
    try testing.expect(read_back != null);
    var kept = read_back.?;
    defer kept.deinit();
    try testing.expectEqual(@as(i64, 5), kept.entry.finished.?.day);
    try testing.expectEqual(@as(i64, 600), kept.entry.today.?.at_ms);

    const older = try encode(testing.allocator, id, .{
        .finished = .{ .day = 4, .at_ms = 400, .days_7 = oneRow(1), .month = oneRow(1) },
    });
    defer testing.allocator.free(older);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = older });
    var third = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 700, .models = oneRow(5) },
    }, test_now, second.entry);
    defer third.deinit();
    try testing.expect(third.entry.finished != null);
    try testing.expectEqual(@as(i64, 5), third.entry.finished.?.day);
}

test "store never writes an entry its reader would reject" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.api_key, "k", "");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    first.deinit();
    const huge = [_]report.ModelRow{.{ .model = "m", .totals = .{ .request_count = 1, .total_cost = std.math.inf(f64) } }};
    try testing.expectError(error.InvalidCache, store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 600, .models = &huge },
    }, test_now, null));
    try testing.expectError(error.InvalidCache, own(testing.allocator, id, .{ .today = .{ .day = 5, .at_ms = 600, .models = &huge } }));
    const read_back = read(testing.allocator, io, tmp.dir, id);
    try testing.expect(read_back != null);
    var kept = read_back.?;
    defer kept.deinit();
    try testing.expectEqual(@as(i64, 5), kept.entry.finished.?.day);
    try testing.expect(kept.entry.today == null);
}

fn expectSameWire(input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };
    const expected = std.json.parseFromSliceLeaky(Wire, arena, input, options);
    const actual = json_decode.parseFromSliceLeaky(Wire, arena, input, options);
    if (expected) |value| {
        try testing.expectEqualDeep(value, try actual);
    } else |err| {
        try testing.expectError(err, actual);
    }
}

test "decode reads every cache file exactly as std.json does" {
    const codex_body =
        \\{"plan_type":"pro",
        \\ "rate_limit":{"allowed":true,"limit_reached":false,
        \\  "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":7980,"reset_at":1791759980},
        \\  "secondary_window":{"used_percent":18.5,"limit_window_seconds":604800,"reset_after_seconds":300000,"reset_at":null}},
        \\ "additional_rate_limits":[{"limit_name":"cloud tasks","metered_feature":"cloud","rate_limit":{"allowed":true,"limit_reached":false,
        \\  "primary_window":{"used_percent":3,"limit_window_seconds":86400,"reset_after_seconds":100,"reset_at":1791752100}}}],
        \\ "credits":{"has_credits":true,"unlimited":false,"balance":"12.40"},
        \\ "spend_control":{"reached":true,"individual_limit":null}}
    ;
    const grok_body =
        \\{"config":{"creditUsagePercent":42.5,
        \\"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},
        \\"onDemandCap":{"val":5000},"onDemandUsed":{"val":300},"prepaidBalance":{"val":1250},
        \\"productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":61.2},{"product":"PRODUCT_CHAT"}]}}
    ;
    var codex_usage = try codex.parse(testing.allocator, codex_body, 1_791_752_000_000);
    defer codex_usage.deinit();
    var grok_usage = try grok.parseBilling(testing.allocator, grok_body);
    defer grok_usage.deinit();
    const id = identityOf(.member, "acct_1", "team_1");
    const bytes = try encode(testing.allocator, id, .{
        .today = .{ .day = 20737, .at_ms = 9, .models = oneRow(1.5) },
        .finished = .{ .day = 20736, .at_ms = 8, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = 7, .value = .{ .limit = 100, .spent = 2.5, .period = .weekly } },
        .codex = .{ .at_ms = 6, .value = codex_usage.usage },
        .grok = .{ .at_ms = 5, .value = grok_usage.usage },
    });
    defer testing.allocator.free(bytes);
    try expectSameWire(bytes);

    var prng: std.Random.DefaultPrng = .init(0x75736167);
    const random = prng.random();
    const alphabet = "{}[]\",:-.0123456789eanrtlu ";
    var buf: [8192]u8 = undefined;
    for (0..2000) |_| {
        var len = bytes.len;
        @memcpy(buf[0..len], bytes);
        const at = random.uintLessThan(usize, len);
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                @memmove(buf[at .. len - 1], buf[at + 1 .. len]);
                len -= 1;
            },
            1 => {
                @memmove(buf[at + 1 .. len + 1], buf[at..len]);
                buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                len += 1;
            },
            else => buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)],
        }
        try expectSameWire(buf[0..len]);
    }
}
