const std = @import("std");
const calendar = @import("calendar.zig");
const expr_mod = @import("expr.zig");

const max_fraction_of_period: f64 = 0.1;
const recurring_max_ms: f64 = 15 * 60_000;
const one_shot_max_ms: f64 = 90_000;
const two_pow_32: f64 = 4294967296.0;

pub fn fractionFromId(id: []const u8) f64 {
    if (id.len == 8) {
        if (std.fmt.parseInt(u32, id, 16)) |value| {
            return @as(f64, @floatFromInt(value)) / two_pow_32;
        } else |_| {}
    }
    var hash: u32 = 5381;
    for (id) |char| hash = hash *% 33 +% @as(u32, char);
    return @as(f64, @floatFromInt(hash)) / two_pow_32;
}

pub fn recurringNext(id: []const u8, expr: expr_mod.Expr, ideal_ms: i64, no_jitter: bool) i64 {
    if (no_jitter) return ideal_ms;
    const period_ms: i64 = if (expr_mod.nextRun(expr, ideal_ms)) |next|
        (if (next > ideal_ms) next - ideal_ms else calendar.ms_per_day)
    else
        calendar.ms_per_day;
    const cap = @min(@as(f64, @floatFromInt(period_ms)) * max_fraction_of_period, recurring_max_ms);
    if (!(cap > 0)) return ideal_ms;
    return ideal_ms + @as(i64, @intFromFloat(@ceil(cap * fractionFromId(id))));
}

pub fn oneShotNext(id: []const u8, ideal_ms: i64, created_ms: i64, no_jitter: bool) i64 {
    if (no_jitter) return ideal_ms;
    if (@mod(ideal_ms, calendar.ms_per_minute) != 0) return ideal_ms;
    const minute = calendar.wallFields(ideal_ms + calendar.offsetMs(ideal_ms)).minute;
    if (minute != 0 and minute != 30) return ideal_ms;
    const shift: i64 = @intFromFloat(@floor(one_shot_max_ms * fractionFromId(id)));
    const shifted = ideal_ms - shift;
    if (shifted < created_ms) return ideal_ms;
    return shifted;
}

test "jitter fraction is stable and lies in [0, 1)" {
    const fraction = fractionFromId("01HZX3K9Y0ABCDEFGHJKMNPQRS");
    try std.testing.expect(fraction >= 0 and fraction < 1);
    try std.testing.expectEqual(fraction, fractionFromId("01HZX3K9Y0ABCDEFGHJKMNPQRS"));
    try std.testing.expectEqual(@as(f64, 0xdeadbeef) / two_pow_32, fractionFromId("deadbeef"));
}

test "recurring jitter stays within a tenth of the period and is disabled by no_jitter" {
    var diag: expr_mod.Diagnostic = .{};
    const expr = try expr_mod.parse("* * * * *", &diag);
    const ideal: i64 = 1_704_067_260_000;
    try std.testing.expectEqual(ideal, recurringNext("01HZX3K9Y0ABCDEFGHJKMNPQRS", expr, ideal, true));
    const jittered = recurringNext("01HZX3K9Y0ABCDEFGHJKMNPQRS", expr, ideal, false);
    try std.testing.expect(jittered >= ideal and jittered <= ideal + 6_000);
}

test "one-shot jitter moves a top-of-hour or half-hour fire earlier and leaves others alone" {
    const created: i64 = 1_704_067_200_000 - 3_600_000;
    const id = "01HZX3K9Y0ABCDEFGHJKMNPQRS";
    const top_of_hour: i64 = 1_704_067_200_000;
    const shifted = oneShotNext(id, top_of_hour, created, false);
    try std.testing.expect(shifted <= top_of_hour and shifted >= top_of_hour - 90_000);
    const quarter: i64 = 1_704_067_200_000 + 15 * 60_000;
    try std.testing.expectEqual(quarter, oneShotNext(id, quarter, created, false));
    try std.testing.expectEqual(top_of_hour, oneShotNext(id, top_of_hour, created, true));
}
