const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Id = u32;

pub const TakeError = Allocator.Error || error{ AttachmentUnavailable, AttachmentTooLarge };
pub const PutError = Allocator.Error || error{AttachmentStoreFull};

pub const Store = struct {
    context: ?*anyopaque = null,
    take_fn: *const fn (?*anyopaque, Allocator, Id, usize) TakeError![]u8,
    put_fn: *const fn (?*anyopaque, []const u8) PutError!Id,

    pub fn take(self: Store, alloc: Allocator, id: Id, max_bytes: usize) TakeError![]u8 {
        return self.take_fn(self.context, alloc, id, max_bytes);
    }

    pub fn put(self: Store, bytes: []const u8) PutError!Id {
        return self.put_fn(self.context, bytes);
    }
};

pub fn idFromJson(value: std.json.Value) ?Id {
    if (value != .integer) return null;
    const id = std.math.cast(Id, value.integer) orelse return null;
    return if (id == 0) null else id;
}

test "idFromJson accepts only positive u32 integers" {
    try std.testing.expectEqual(@as(?Id, 7), idFromJson(.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?Id, std.math.maxInt(Id)), idFromJson(.{ .integer = std.math.maxInt(Id) }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = 0 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = @as(i64, std.math.maxInt(Id)) + 1 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .string = "1" }));
}
