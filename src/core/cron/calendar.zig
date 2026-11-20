const std = @import("std");
const local_time = @import("../shared/local_time.zig");

const Allocator = std.mem.Allocator;

pub const ms_per_minute: i64 = 60_000;
pub const ms_per_hour: i64 = 60 * ms_per_minute;
pub const ms_per_day: i64 = 24 * ms_per_hour;

pub const Fields = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millisecond: i64,
    weekday: i64,
};

pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn wallFields(wall_ms: i64) Fields {
    const days = @divFloor(wall_ms, ms_per_day);
    const day_ms = @mod(wall_ms, ms_per_day);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    var year = yoe + era * 400;
    if (month <= 2) year += 1;
    const minute_of_day = @divFloor(day_ms, ms_per_minute);
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = @divFloor(minute_of_day, 60),
        .minute = @mod(minute_of_day, 60),
        .second = @divFloor(@mod(day_ms, ms_per_minute), 1000),
        .millisecond = @mod(day_ms, 1000),
        .weekday = @mod(days + 4, 7),
    };
}

pub fn offsetMs(utc_ms: i64) i64 {
    const reading = local_time.local(utc_ms) orelse return 0;
    const days = daysFromCivil(@as(i64, reading.year), @as(i64, reading.month.numeric()), @as(i64, reading.day));
    const wall = days * ms_per_day +
        @as(i64, reading.hour) * ms_per_hour +
        @as(i64, reading.minute) * ms_per_minute +
        @as(i64, reading.second) * 1000 +
        @as(i64, reading.millisecond);
    return wall - utc_ms;
}

pub fn utcFromWall(wall_ms: i64) i64 {
    const first = wall_ms - offsetMs(wall_ms);
    return wall_ms - offsetMs(first);
}

pub fn startOfNextMonth(fields: Fields) i64 {
    const next_year = if (fields.month == 12) fields.year + 1 else fields.year;
    const next_month = if (fields.month == 12) 1 else fields.month + 1;
    return daysFromCivil(next_year, next_month, 1) * ms_per_day;
}

pub fn startOfNextDay(wall_ms: i64) i64 {
    return @divFloor(wall_ms, ms_per_day) * ms_per_day + ms_per_day;
}

pub fn startOfNextHour(wall_ms: i64) i64 {
    return @divFloor(wall_ms, ms_per_hour) * ms_per_hour + ms_per_hour;
}

pub fn startOfNextMinute(wall_ms: i64) i64 {
    return @divFloor(wall_ms, ms_per_minute) * ms_per_minute + ms_per_minute;
}

pub fn formatLocalIsoWithOffset(alloc: Allocator, utc_ms: i64) Allocator.Error![]u8 {
    const offset = offsetMs(utc_ms);
    const fields = wallFields(utc_ms + offset);
    const sign: []const u8 = if (offset >= 0) "+" else "-";
    const offset_minutes = @divTrunc(@max(offset, -offset), ms_per_minute);
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}{d:0>2}:{d:0>2}",
        .{
            @as(u64, @intCast(fields.year)),
            @as(u64, @intCast(fields.month)),
            @as(u64, @intCast(fields.day)),
            @as(u64, @intCast(fields.hour)),
            @as(u64, @intCast(fields.minute)),
            @as(u64, @intCast(fields.second)),
            @as(u64, @intCast(fields.millisecond)),
            sign,
            @as(u64, @intCast(@divTrunc(offset_minutes, 60))),
            @as(u64, @intCast(@mod(offset_minutes, 60))),
        },
    );
}

test "calendar maps epoch zero to a Thursday in 1970" {
    const fields = wallFields(0);
    try std.testing.expectEqual(@as(i64, 1970), fields.year);
    try std.testing.expectEqual(@as(i64, 1), fields.month);
    try std.testing.expectEqual(@as(i64, 1), fields.day);
    try std.testing.expectEqual(@as(i64, 4), fields.weekday);
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
}

test "calendar round-trips a leap day through civil fields" {
    const leap_day = daysFromCivil(2024, 2, 29) * ms_per_day;
    const fields = wallFields(leap_day + 14 * ms_per_hour + 30 * ms_per_minute);
    try std.testing.expectEqual(@as(i64, 2024), fields.year);
    try std.testing.expectEqual(@as(i64, 2), fields.month);
    try std.testing.expectEqual(@as(i64, 29), fields.day);
    try std.testing.expectEqual(@as(i64, 14), fields.hour);
    try std.testing.expectEqual(@as(i64, 30), fields.minute);
    try std.testing.expectEqual(@as(i64, 4), fields.weekday);
}

test "calendar formats a local ISO timestamp with its offset" {
    const alloc = std.testing.allocator;
    const text = try formatLocalIsoWithOffset(alloc, 0);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000+00:00", text);
}
