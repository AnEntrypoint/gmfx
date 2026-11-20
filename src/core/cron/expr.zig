const std = @import("std");
const calendar = @import("calendar.zig");

const Allocator = std.mem.Allocator;

pub const Mask = u64;

pub const Expr = struct {
    minutes: Mask,
    hours: Mask,
    days_of_month: Mask,
    months: Mask,
    days_of_week: Mask,
    days_of_month_wildcard: bool,
    days_of_week_wildcard: bool,
};

pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const ParseError = error{CronExpressionInvalid};

const whitespace = " \t\n\r\x0b\x0c";
const five_years_minutes: i64 = 5 * 366 * 24 * 60;
const hard_iteration_cap: u32 = 10_000_000;
const weekdays_mask: Mask = bit(1) | bit(2) | bit(3) | bit(4) | bit(5);
const weekends_mask: Mask = bit(0) | bit(6);
const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

fn bit(value: u64) Mask {
    return @as(Mask, 1) << @as(u6, @intCast(value));
}

fn has(mask: Mask, value: i64) bool {
    return ((mask >> @as(u6, @intCast(value))) & 1) == 1;
}

fn fullRange(min: u64, max: u64) Mask {
    var out: Mask = 0;
    var value = min;
    while (value <= max) : (value += 1) out |= bit(value);
    return out;
}

fn fail(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) ParseError {
    const written = std.fmt.bufPrint(&diag.buf, fmt, args) catch diag.buf[0..0];
    diag.len = written.len;
    return error.CronExpressionInvalid;
}

pub fn parse(raw: []const u8, diag: *Diagnostic) ParseError!Expr {
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, raw, whitespace);
    while (tokens.next()) |token| : (count += 1) {
        if (count < fields.len) fields[count] = token;
    }
    if (count == 0) return fail(diag, "cron expression is empty", .{});
    if (count != fields.len) {
        return fail(diag, "cron expression must have exactly 5 fields (minute hour day-of-month month day-of-week); got {d}", .{count});
    }
    const minutes = try parseField(diag, fields[0], 0, 59, "minute");
    const hours = try parseField(diag, fields[1], 0, 23, "hour");
    const days_of_month = try parseField(diag, fields[2], 1, 31, "day-of-month");
    const months = try parseField(diag, fields[3], 1, 12, "month");
    const days_of_week_raw = try parseField(diag, fields[4], 0, 7, "day-of-week");
    return .{
        .minutes = minutes,
        .hours = hours,
        .days_of_month = days_of_month,
        .months = months,
        .days_of_week = (days_of_week_raw | (days_of_week_raw >> 7)) & 0x7f,
        .days_of_month_wildcard = std.mem.eql(u8, fields[2], "*"),
        .days_of_week_wildcard = std.mem.eql(u8, fields[4], "*"),
    };
}

fn parseField(diag: *Diagnostic, field: []const u8, min: u64, max: u64, name: []const u8) ParseError!Mask {
    if (field.len == 0) return fail(diag, "cron {s} field is empty", .{name});
    var out: Mask = 0;
    var terms = std.mem.splitScalar(u8, field, ',');
    while (terms.next()) |term| {
        if (term.len == 0) return fail(diag, "cron {s} field has empty term in list", .{name});
        out |= try parseTerm(diag, term, min, max, name);
    }
    return out;
}

fn parseDigits(diag: *Diagnostic, text: []const u8, name: []const u8, role: []const u8) ParseError!u64 {
    var valid = text.len > 0;
    for (text) |char| valid = valid and std.ascii.isDigit(char);
    if (!valid) {
        return fail(diag, "cron {s} {s} must be a non-negative integer with digits only (got \"{s}\")", .{ name, role, text });
    }
    return std.fmt.parseInt(u64, text, 10) catch std.math.maxInt(u64);
}

fn parseTerm(diag: *Diagnostic, term: []const u8, min: u64, max: u64, name: []const u8) ParseError!Mask {
    var range_part = term;
    var step: u64 = 1;
    var stepped = false;
    if (std.mem.indexOfScalar(u8, term, '/')) |slash| {
        range_part = term[0..slash];
        const step_text = term[slash + 1 ..];
        if (step_text.len == 0) return fail(diag, "cron {s} step is empty in \"{s}\"", .{ name, term });
        step = try parseDigits(diag, step_text, name, "step");
        if (step == 0) return fail(diag, "cron {s} step must be a positive integer (got \"{s}\")", .{ name, step_text });
        if (range_part.len == 0) {
            return fail(diag, "cron {s} step needs a range or \"*\" before \"/\" in \"{s}\"", .{ name, term });
        }
        stepped = true;
    }
    var lo: u64 = min;
    var hi: u64 = max;
    if (std.mem.eql(u8, range_part, "*")) {
        lo = min;
        hi = max;
    } else if (std.mem.indexOfScalar(u8, range_part, '-')) |dash| {
        lo = try parseDigits(diag, range_part[0..dash], name, "range lower bound");
        hi = try parseDigits(diag, range_part[dash + 1 ..], name, "range upper bound");
        if (lo < min or hi > max or lo > hi) {
            return fail(diag, "cron {s} range {d}-{d} out of bounds (must be {d}..{d}, ascending)", .{ name, lo, hi, min, max });
        }
    } else {
        const single = try parseDigits(diag, range_part, name, "value");
        if (single < min or single > max) {
            return fail(diag, "cron {s} value {d} out of range {d}..{d}", .{ name, single, min, max });
        }
        if (!stepped) return bit(single);
        lo = single;
    }
    var out: Mask = 0;
    var value = lo;
    while (true) {
        out |= bit(value);
        if (hi - value < step) break;
        value += step;
    }
    return out;
}

pub fn nextRun(expr: Expr, from_ms: i64) ?i64 {
    return nextRunWithin(expr, from_ms, five_years_minutes);
}

pub fn hasFireWithinYears(expr: Expr, years: i64, from_ms: i64) bool {
    return nextRunWithin(expr, from_ms, @max(1, years * 366 * 24 * 60)) != null;
}

fn nextRunWithin(expr: Expr, from_ms: i64, cap_minutes: i64) ?i64 {
    const from_wall = from_ms + calendar.offsetMs(from_ms);
    var wall = calendar.startOfNextMinute(from_wall);
    const deadline = from_wall + cap_minutes * calendar.ms_per_minute;
    var iterations: u32 = 0;
    while (wall <= deadline and iterations < hard_iteration_cap) : (iterations += 1) {
        const fields = calendar.wallFields(wall);
        if (!has(expr.months, fields.month)) {
            wall = calendar.startOfNextMonth(fields);
            continue;
        }
        if (!dayMatches(expr, fields)) {
            wall = calendar.startOfNextDay(wall);
            continue;
        }
        if (!has(expr.hours, fields.hour)) {
            wall = calendar.startOfNextHour(wall);
            continue;
        }
        if (!has(expr.minutes, fields.minute)) {
            wall = calendar.startOfNextMinute(wall);
            continue;
        }
        return calendar.utcFromWall(wall);
    }
    return null;
}

fn dayMatches(expr: Expr, fields: calendar.Fields) bool {
    const dom_ok = has(expr.days_of_month, fields.day);
    const dow_ok = has(expr.days_of_week, fields.weekday);
    if (expr.days_of_month_wildcard and expr.days_of_week_wildcard) return true;
    if (expr.days_of_month_wildcard) return dow_ok;
    if (expr.days_of_week_wildcard) return dom_ok;
    return dom_ok or dow_ok;
}

fn detectStep(mask: Mask) ?u64 {
    if (@popCount(mask) < 2) return null;
    const first: u64 = @ctz(mask);
    if (first != 0) return null;
    const second: u64 = @ctz(mask & (mask - 1));
    const step = second - first;
    var expected: u64 = 0;
    var rest = mask;
    while (rest != 0) : (rest &= rest - 1) {
        const value: u64 = @ctz(rest);
        if (value != expected) return null;
        expected += step;
    }
    return step;
}

fn dowText(alloc: Allocator, mask: Mask) Allocator.Error![]u8 {
    if (mask == weekdays_mask) return alloc.dupe(u8, "weekdays");
    if (mask == weekends_mask) return alloc.dupe(u8, "weekends");
    var buf: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var first = true;
    for (day_names, 0..) |name, index| {
        if (!has(mask, @intCast(index))) continue;
        if (!first) writer.writeAll(", ") catch unreachable;
        first = false;
        writer.writeAll(name) catch unreachable;
    }
    return alloc.dupe(u8, writer.buffered());
}

pub fn humanSchedule(alloc: Allocator, expr: Expr, raw: []const u8) Allocator.Error![]u8 {
    const all_hours = expr.hours == fullRange(0, 23);
    const all_months = expr.months == fullRange(1, 12);
    const all_dom = expr.days_of_month_wildcard;
    const all_dow = expr.days_of_week_wildcard;
    const single_minute = @popCount(expr.minutes) == 1;
    const single_hour = @popCount(expr.hours) == 1;
    if (all_hours and all_dom and all_months and all_dow) {
        if (detectStep(expr.minutes)) |step| {
            if (step > 1) return std.fmt.allocPrint(alloc, "every {d} minutes", .{step});
        }
        if (expr.minutes == fullRange(0, 59)) return alloc.dupe(u8, "every minute");
        if (single_minute) return std.fmt.allocPrint(alloc, "at minute {d} of every hour", .{@ctz(expr.minutes)});
    }
    if (single_minute and all_dom and all_months and all_dow) {
        if (detectStep(expr.hours)) |step| {
            if (step > 1) return std.fmt.allocPrint(alloc, "every {d} hours at minute {d:0>2}", .{ step, @ctz(expr.minutes) });
        }
    }
    if (single_minute and single_hour and all_dom and all_months) {
        const clock = try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ @ctz(expr.hours), @ctz(expr.minutes) });
        defer alloc.free(clock);
        if (all_dow) return std.fmt.allocPrint(alloc, "at {s} every day", .{clock});
        const days = try dowText(alloc, expr.days_of_week);
        defer alloc.free(days);
        return std.fmt.allocPrint(alloc, "at {s} on {s}", .{ clock, days });
    }
    if (single_minute and single_hour and @popCount(expr.days_of_month) == 1 and @popCount(expr.months) == 1 and all_dow) {
        const clock = try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ @ctz(expr.hours), @ctz(expr.minutes) });
        defer alloc.free(clock);
        const month_name = month_names[@as(usize, @ctz(expr.months)) - 1];
        return std.fmt.allocPrint(alloc, "at {s} on day {d} of {s}", .{ clock, @ctz(expr.days_of_month), month_name });
    }
    return alloc.dupe(u8, raw);
}

test "cron parses the five fields into value sets" {
    var diag: Diagnostic = .{};
    const expr = try parse("*/15 9-17 * * 1-5", &diag);
    try std.testing.expect(has(expr.minutes, 0) and has(expr.minutes, 45) and !has(expr.minutes, 10));
    try std.testing.expect(has(expr.hours, 9) and has(expr.hours, 17) and !has(expr.hours, 18));
    try std.testing.expect(expr.days_of_month_wildcard and !expr.days_of_week_wildcard);
    try std.testing.expectEqual(weekdays_mask, expr.days_of_week);
}

test "cron folds day-of-week 7 onto Sunday" {
    var diag: Diagnostic = .{};
    const expr = try parse("0 0 * * 7", &diag);
    try std.testing.expectEqual(bit(0), expr.days_of_week);
}

test "cron reports field count and range errors with the field name" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.CronExpressionInvalid, parse("* * * *", &diag));
    try std.testing.expectEqualStrings("cron expression must have exactly 5 fields (minute hour day-of-month month day-of-week); got 4", diag.text());
    try std.testing.expectError(error.CronExpressionInvalid, parse("60 * * * *", &diag));
    try std.testing.expectEqualStrings("cron minute value 60 out of range 0..59", diag.text());
    try std.testing.expectError(error.CronExpressionInvalid, parse("*/0 * * * *", &diag));
    try std.testing.expectEqualStrings("cron minute step must be a positive integer (got \"0\")", diag.text());
}

test "cron finds the next minute that matches in UTC" {
    var diag: Diagnostic = .{};
    const from = 1_704_067_200_000;
    const expr = try parse("30 14 * * *", &diag);
    try std.testing.expectEqual(@as(?i64, from + 52_200_000), nextRun(expr, from));
    const leap = try parse("0 0 29 2 *", &diag);
    try std.testing.expectEqual(@as(?i64, 1_709_164_800_000), nextRun(leap, from));
}

test "cron reports no fire for an impossible day" {
    var diag: Diagnostic = .{};
    const expr = try parse("0 0 31 2 *", &diag);
    try std.testing.expect(!hasFireWithinYears(expr, 5, 1_704_067_200_000));
}

test "cron renders a human schedule for common shapes" {
    const alloc = std.testing.allocator;
    var diag: Diagnostic = .{};
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "*/5 * * * *", .want = "every 5 minutes" },
        .{ .raw = "* * * * *", .want = "every minute" },
        .{ .raw = "15 * * * *", .want = "at minute 15 of every hour" },
        .{ .raw = "0 */2 * * *", .want = "every 2 hours at minute 00" },
        .{ .raw = "30 14 * * *", .want = "at 14:30 every day" },
        .{ .raw = "0 9 * * 1-5", .want = "at 09:00 on weekdays" },
        .{ .raw = "0 9 * * 0,6", .want = "at 09:00 on weekends" },
        .{ .raw = "30 14 28 2 *", .want = "at 14:30 on day 28 of February" },
        .{ .raw = "1,2 3 * * *", .want = "1,2 3 * * *" },
    };
    for (cases) |case| {
        const expr = try parse(case.raw, &diag);
        const text = try humanSchedule(alloc, expr, case.raw);
        defer alloc.free(text);
        try std.testing.expectEqualStrings(case.want, text);
    }
}
