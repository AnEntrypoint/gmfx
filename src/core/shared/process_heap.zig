const std = @import("std");
const builtin = @import("builtin");

pub const tunes_glibc_heap = builtin.link_libc and builtin.target.isGnuLibC();

const mmap_threshold_option: c_int = -3;
const large_block_bytes: c_int = 128 * 1024;

const HeapUse = extern struct {
    arena: usize,
    ordblks: usize,
    smblks: usize,
    hblks: usize,
    hblkhd: usize,
    usmblks: usize,
    fsmblks: usize,
    uordblks: usize,
    fordblks: usize,
    keepcost: usize,
};

extern "c" fn mallopt(option: c_int, value: c_int) c_int;
extern "c" fn malloc_trim(pad: usize) c_int;
extern "c" fn mallinfo2() HeapUse;

pub fn giveFreedLargeBlocksBack() void {
    if (comptime !tunes_glibc_heap) return;
    _ = mallopt(mmap_threshold_option, large_block_bytes);
}

pub fn giveFreedPagesBack() void {
    if (comptime !tunes_glibc_heap) return;
    _ = malloc_trim(0);
}

test "process heap gives a freed large block back to the system every time" {
    if (comptime !tunes_glibc_heap) return error.SkipZigTest;
    giveFreedLargeBlocksBack();
    const alloc = std.heap.c_allocator;
    const mapped_before = mallinfo2().hblks;
    for (0..4) |_| {
        const block = try alloc.alloc(u8, 4 * 1024 * 1024);
        @memset(block, 1);
        try std.testing.expectEqual(mapped_before + 1, mallinfo2().hblks);
        alloc.free(block);
        try std.testing.expectEqual(mapped_before, mallinfo2().hblks);
    }
}
