const std = @import("std");

var committed_file_mutations: std.atomic.Value(usize) = .init(0);

pub fn bump() void {
    _ = committed_file_mutations.fetchAdd(1, .monotonic);
}

pub fn current() u64 {
    return committed_file_mutations.load(.monotonic);
}

pub fn changedSince(epoch: u64) bool {
    return current() != epoch;
}

test "the tree epoch moves once per committed file mutation" {
    const before = current();
    try std.testing.expect(!changedSince(before));
    bump();
    try std.testing.expect(changedSince(before));
    try std.testing.expectEqual(before + 1, current());
}
