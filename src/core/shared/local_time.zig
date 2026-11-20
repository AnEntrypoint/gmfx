const builtin = @import("builtin");
const std = @import("std");

pub const max_timestamp_ms: i64 = 253_402_300_799_999;

const max_zone_name_len = 10;

pub const Zone = struct {
    offset_s: i32,
    name: []const u8,

    pub const utc: Zone = .{ .offset_s = 0, .name = "UTC" };
};

pub var test_zone: if (builtin.is_test) Zone else void = if (builtin.is_test) Zone.utc else {};

pub const Reading = struct {
    year: std.time.epoch.Year,
    month: std.time.epoch.Month,
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
    millisecond: u10,
    zone_name_buf: [max_zone_name_len]u8,
    zone_name_len: u8,

    pub fn zoneName(self: *const Reading) []const u8 {
        return self.zone_name_buf[0..self.zone_name_len];
    }

    pub fn format(self: Reading, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}", .{
            self.year,
            self.month.numeric(),
            self.day,
            self.hour,
            self.minute,
            self.second,
            self.millisecond,
            self.zoneName(),
        });
    }
};

pub fn local(timestamp_ms: i64) ?Reading {
    if (timestamp_ms < 0 or timestamp_ms > max_timestamp_ms) return null;
    return inZone(timestamp_ms, localZoneAt(@divFloor(timestamp_ms, std.time.ms_per_s)));
}

fn inZone(timestamp_ms: i64, requested: Zone) ?Reading {
    if (timestamp_ms < 0 or timestamp_ms > max_timestamp_ms) return null;
    var zone = requested;
    var local_ms = timestamp_ms + @as(i64, zone.offset_s) * std.time.ms_per_s;
    if (@abs(zone.offset_s) >= std.time.s_per_day or local_ms > max_timestamp_ms) {
        zone = .utc;
        local_ms = timestamp_ms;
    }
    const day_ms = std.time.s_per_day * std.time.ms_per_s;
    const days = @divFloor(local_ms, day_ms);
    const ms_of_day = local_ms - days * day_ms;
    const date = civilFromDays(days);
    var reading: Reading = .{
        .year = @intCast(date.year),
        .month = date.month,
        .day = date.day,
        .hour = @intCast(@divFloor(ms_of_day, std.time.ms_per_s * std.time.s_per_hour)),
        .minute = @intCast(@rem(@divFloor(ms_of_day, std.time.ms_per_s * std.time.s_per_min), std.time.s_per_min)),
        .second = @intCast(@rem(@divFloor(ms_of_day, std.time.ms_per_s), std.time.s_per_min)),
        .millisecond = @intCast(@mod(ms_of_day, std.time.ms_per_s)),
        .zone_name_buf = undefined,
        .zone_name_len = 0,
    };
    reading.zone_name_len = @intCast(writeZoneName(zone, &reading.zone_name_buf).len);
    return reading;
}

const CivilDate = struct {
    year: i64,
    month: std.time.epoch.Month,
    day: u5,
};

fn civilFromDays(days: i64) CivilDate {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const march_based_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * march_based_month + 2, 5) + 1;
    const month: i64 = if (march_based_month < 10) march_based_month + 3 else march_based_month - 9;
    return .{
        .year = year_of_era + era * 400 + @intFromBool(month <= 2),
        .month = @fromBackingInt(@intCast(month)),
        .day = @intCast(day),
    };
}

fn writeZoneName(zone: Zone, buf: *[max_zone_name_len]u8) []const u8 {
    if (isPlainZoneName(zone.name)) {
        @memcpy(buf[0..zone.name.len], zone.name);
        return buf[0..zone.name.len];
    }
    const minutes = @abs(zone.offset_s) / std.time.s_per_min;
    buf[0] = if (zone.offset_s < 0) '-' else '+';
    buf[1..3].* = std.fmt.digits2(@intCast(minutes / 60));
    buf[3..5].* = std.fmt.digits2(@intCast(minutes % 60));
    return buf[0..5];
}

fn isPlainZoneName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_zone_name_len) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-') return false;
    }
    return true;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;

fn localZoneAt(epoch_s: i64) Zone {
    if (builtin.is_test) return test_zone;
    if (!builtin.link_libc or builtin.target.os.tag == .wasi) return .utc;
    const timer = std.math.cast(std.c.time_t, epoch_s) orelse return .utc;
    var tm: Tm = undefined;
    if (localtime_r(&timer, &tm) == null) return .utc;
    const offset_s = std.math.cast(i32, tm.gmtoff) orelse return .utc;
    return .{
        .offset_s = offset_s,
        .name = if (tm.zone) |name| std.mem.span(name) else "",
    };
}

const ist: Zone = .{ .offset_s = 5 * 3600 + 30 * 60, .name = "IST" };

fn expectReading(expected: []const u8, reading: ?Reading) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.mem.print(&buf, "{f}", .{reading.?}));
}

test "local time reads a timestamp in the given zone" {
    try expectReading("2024-01-02 03:04:05.006 UTC", inZone(1_704_164_645_006, .utc));

    try expectReading("2024-01-02 08:34:05.006 IST", inZone(1_704_164_645_006, ist));

    try expectReading(
        "2023-12-31 22:04:05.006 EST",
        inZone(1_704_078_245_006, .{ .offset_s = -5 * 3600, .name = "EST" }),
    );
}

test "local time falls back to UTC when the zone cannot apply" {
    try expectReading("1969-12-31 17:00:00.002 PDT", inZone(2, .{ .offset_s = -7 * 3600, .name = "PDT" }));
    try expectReading(
        "2024-01-02 03:04:05.006 UTC",
        inZone(1_704_164_645_006, .{ .offset_s = std.time.s_per_day, .name = "BAD" }),
    );
    try std.testing.expect(inZone(-1, .utc) == null);
    try std.testing.expect(inZone(max_timestamp_ms + 1, .utc) == null);
    try std.testing.expect(local(-1) == null);
    try std.testing.expect(local(max_timestamp_ms + 1) == null);
}

test "local time dates a pre-1970 local time by its own calendar day" {
    try expectReading("1969-12-31 19:00:00.000 EST", inZone(0, .{ .offset_s = -5 * 3600, .name = "EST" }));
}

test "local time shows a zone without a plain name as its offset" {
    try expectReading("2024-01-02 08:49:05.006 +0545", inZone(1_704_164_645_006, .{
        .offset_s = 5 * 3600 + 45 * 60,
        .name = "+0545",
    }));
    try expectReading("2024-01-02 08:34:05.006 +0530", inZone(1_704_164_645_006, .{
        .offset_s = ist.offset_s,
        .name = "",
    }));
    try expectReading("2024-01-01 17:34:05.006 -0930", inZone(1_704_164_645_006, .{
        .offset_s = -(9 * 3600 + 30 * 60),
        .name = "\x1b[2J",
    }));
    try expectReading("2024-01-02 03:04:05.006 +0000", inZone(1_704_164_645_006, .{
        .offset_s = 0,
        .name = "ABCDEFGHIJK",
    }));
}

test "local time follows the test zone" {
    try expectReading("2024-01-02 03:04:05.006 UTC", local(1_704_164_645_006));
    test_zone = ist;
    defer test_zone = .utc;
    try expectReading("2024-01-02 08:34:05.006 IST", local(1_704_164_645_006));
}
