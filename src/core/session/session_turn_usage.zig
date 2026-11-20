const std = @import("std");
const types = @import("../shared/types.zig");

const field_count: usize = 6;

pub const TurnUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    context_window_tokens: u64 = 0,

    pub fn fromUsage(usage: types.Usage, context_window_tokens: u64) TurnUsage {
        return .{
            .input_tokens = usage.input_tokens orelse 0,
            .output_tokens = usage.output_tokens orelse 0,
            .cache_read_tokens = usage.cache_read_tokens orelse 0,
            .cache_write_tokens = usage.cache_write_tokens orelse 0,
            .reasoning_tokens = usage.reasoning_tokens orelse 0,
            .context_window_tokens = context_window_tokens,
        };
    }

    pub fn isZero(self: TurnUsage) bool {
        return self.input_tokens == 0 and
            self.output_tokens == 0 and
            self.cache_read_tokens == 0 and
            self.cache_write_tokens == 0 and
            self.reasoning_tokens == 0 and
            self.context_window_tokens == 0;
    }

    pub fn add(self: *TurnUsage, other: TurnUsage) void {
        self.input_tokens +|= other.input_tokens;
        self.output_tokens +|= other.output_tokens;
        self.cache_read_tokens +|= other.cache_read_tokens;
        self.cache_write_tokens +|= other.cache_write_tokens;
        self.reasoning_tokens +|= other.reasoning_tokens;
        if (other.context_window_tokens != 0) self.context_window_tokens = other.context_window_tokens;
    }

    pub fn writeJson(self: TurnUsage, writer: *std.Io.Writer) !void {
        try writer.print(
            "{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":{d},\"context_window_tokens\":{d}}}",
            .{
                self.input_tokens,
                self.output_tokens,
                self.cache_read_tokens,
                self.cache_write_tokens,
                self.reasoning_tokens,
                self.context_window_tokens,
            },
        );
    }

    pub fn parseJson(value: std.json.Value) !TurnUsage {
        if (value != .object) return error.InvalidTurnUsage;
        const object = value.object;
        if (object.count() != field_count) return error.InvalidTurnUsage;
        return .{
            .input_tokens = try field(object, "input_tokens"),
            .output_tokens = try field(object, "output_tokens"),
            .cache_read_tokens = try field(object, "cache_read_tokens"),
            .cache_write_tokens = try field(object, "cache_write_tokens"),
            .reasoning_tokens = try field(object, "reasoning_tokens"),
            .context_window_tokens = try field(object, "context_window_tokens"),
        };
    }
};

fn field(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidTurnUsage;
    return switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse error.InvalidTurnUsage,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidTurnUsage,
        else => error.InvalidTurnUsage,
    };
}

test "turn usage converts optional provider usage and leaves missing counts at zero" {
    const turn = TurnUsage.fromUsage(.{ .input_tokens = 12, .output_tokens = 4, .cache_read_tokens = 9 }, 200_000);
    try std.testing.expectEqual(@as(u64, 12), turn.input_tokens);
    try std.testing.expectEqual(@as(u64, 4), turn.output_tokens);
    try std.testing.expectEqual(@as(u64, 9), turn.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 0), turn.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 0), turn.reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 200_000), turn.context_window_tokens);
    try std.testing.expect(!turn.isZero());
    try std.testing.expect((TurnUsage{}).isZero());
}

test "turn usage add sums counts and keeps the latest known context window" {
    var total: TurnUsage = .{};
    total.add(.{ .input_tokens = 10, .output_tokens = 3, .context_window_tokens = 100 });
    total.add(.{ .input_tokens = 20, .output_tokens = 5, .cache_write_tokens = 7 });
    try std.testing.expectEqual(@as(u64, 30), total.input_tokens);
    try std.testing.expectEqual(@as(u64, 8), total.output_tokens);
    try std.testing.expectEqual(@as(u64, 7), total.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 100), total.context_window_tokens);
    total.add(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), total.input_tokens);
}

test "turn usage JSON round trips through the event value shape" {
    const alloc = std.testing.allocator;
    const turn = TurnUsage{
        .input_tokens = 1,
        .output_tokens = 2,
        .cache_read_tokens = 3,
        .cache_write_tokens = 4,
        .reasoning_tokens = 5,
        .context_window_tokens = 6,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try turn.writeJson(&out.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{ .parse_numbers = false });
    defer parsed.deinit();
    try std.testing.expectEqualDeep(turn, try TurnUsage.parseJson(parsed.value));
    try std.testing.expectError(error.InvalidTurnUsage, TurnUsage.parseJson(.{ .integer = 1 }));
}
