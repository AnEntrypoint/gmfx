const std = @import("std");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");

const Allocator = std.mem.Allocator;
const TranscriptEntry = transcript_blocks.TranscriptEntry;
const EntryRenderAction = transcript_blocks.EntryRenderAction;
const PreparationResume = transcript_blocks.PreparationResume;

pub const Mode = enum { prepared, plain };

pub const Slot = struct {
    key: u64,
    state: PreparationResume,
    alloc: Allocator,
    lines: ?Lines = null,
};

pub const Lines = struct {
    complete_end: usize,
    starts: []usize,
    visual_rows: []u16,
};

pub const FrozenPrefix = struct {
    slots: [2]?Slot = .{ null, null },
    hits: u64 = 0,
    misses: u64 = 0,
    captures: u64 = 0,

    pub fn deinit(self: *FrozenPrefix) void {
        for (&self.slots) |*slot| clear(slot);
    }

    pub fn valid(
        self: *FrozenPrefix,
        mode: Mode,
        entries: []const TranscriptEntry,
        actions: []const EntryRenderAction,
        cols: u16,
        styles: transcript_blocks.Styles,
        limit: usize,
    ) ?*const PreparationResume {
        const slot = &(self.slots[@backingInt(mode)] orelse return null);
        const count = slot.state.entry_count;
        if (count > limit or count > entries.len) return null;
        if (slot.key != key(mode, entries[0..count], actionsFor(actions, count), cols, styles)) return null;
        return &slot.state;
    }

    pub fn store(self: *FrozenPrefix, mode: Mode, slot_key: u64, state: PreparationResume, alloc: Allocator) void {
        const slot = &self.slots[@backingInt(mode)];
        clear(slot);
        slot.* = .{ .key = slot_key, .state = state, .alloc = alloc };
        self.captures += 1;
    }

    pub fn lines(self: *const FrozenPrefix, mode: Mode) ?*const Lines {
        const slot = &(self.slots[@backingInt(mode)] orelse return null);
        return if (slot.lines) |*value| value else null;
    }

    pub fn attachLines(
        self: *FrozenPrefix,
        mode: Mode,
        bytes: []const u8,
        starts: []const usize,
        visual_rows: []const u16,
    ) !void {
        const slot = &(self.slots[@backingInt(mode)] orelse return);
        if (slot.lines != null) return;
        const prefix = slot.state.bytes;
        const last_newline = std.mem.findScalarLast(u8, prefix, '\n') orelse return;
        const complete_end = last_newline + 1;
        if (complete_end > bytes.len or !std.mem.eql(u8, bytes[0..complete_end], prefix[0..complete_end])) return;
        var count: usize = 0;
        while (count < starts.len and starts[count] < complete_end) count += 1;

        const owned_starts = try slot.alloc.dupe(usize, starts[0..count]);
        errdefer slot.alloc.free(owned_starts);
        const owned_rows = try slot.alloc.dupe(u16, visual_rows[0..count]);
        slot.lines = .{
            .complete_end = complete_end,
            .starts = owned_starts,
            .visual_rows = owned_rows,
        };
    }

    pub fn discard(self: *FrozenPrefix, mode: Mode) void {
        clear(&self.slots[@backingInt(mode)]);
    }

    fn clear(slot: *?Slot) void {
        if (slot.*) |*value| {
            value.state.deinit(value.alloc);
            if (value.lines) |held| {
                value.alloc.free(held.starts);
                value.alloc.free(held.visual_rows);
            }
        }
        slot.* = null;
    }
};

pub fn boundary(entries: []const TranscriptEntry) usize {
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        switch (entries[index]) {
            .raw_bytes => |raw| if (raw.class == .turn_summary) return index + 1,
            else => {},
        }
    }
    return 0;
}

fn actionsFor(actions: []const EntryRenderAction, count: usize) []const EntryRenderAction {
    return if (actions.len == 0) &.{} else actions[0..count];
}

pub fn key(
    mode: Mode,
    entries: []const TranscriptEntry,
    actions: []const EntryRenderAction,
    cols: u16,
    styles: transcript_blocks.Styles,
) u64 {
    var h: u64 = 0x7472616e73637269;
    h = mix(h, @backingInt(mode));
    h = mix(h, cols);
    h = mix(h, deepHash(styles));
    h = mix(h, entries.len);
    for (entries) |entry| h = hashEntry(h, entry);
    h = mix(h, actions.len);
    for (actions) |action| h = hashAction(h, action);
    return h;
}

fn mix(h: u64, value: u64) u64 {
    return std.hash.int(h ^ value);
}

fn bytesHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn deepHash(value: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&hasher, value, .Deep);
    return hasher.final();
}

fn flags(a: bool, b: bool) u64 {
    return @as(u64, @intFromBool(a)) | @as(u64, @intFromBool(b)) << 1;
}

fn hashEntry(start: u64, entry: TranscriptEntry) u64 {
    var h = mix(start, @backingInt(std.meta.activeTag(entry)));
    switch (entry) {
        .raw_bytes => |value| {
            comptime std.debug.assert(@typeInfo(@TypeOf(value)).@"struct".field_names.len == 6);
            h = mix(h, value.id);
            h = mix(h, @bitCast(value.created_at_ms));
            h = mix(h, flags(value.inline_hidden, value.lifecycle_pinned));
            h = mix(h, @backingInt(value.class));
            h = mix(h, bytesHash(value.bytes));
        },

        .assistant_turn => |value| {
            h = mix(h, value.id);
            h = mix(h, @bitCast(value.created_at_ms));
            h = mix(h, flags(value.inline_hidden, false));
            h = mix(h, bytesHash(value.segments.text.items));
        },

        .user_turn => |value| {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, value.id);
            std.hash.autoHash(&hasher, value.created_at_ms);
            std.hash.autoHash(&hasher, value.inline_hidden);
            std.hash.autoHashStrat(&hasher, value.turn.text, .Deep);
            std.hash.autoHashStrat(&hasher, value.turn.work_id, .Deep);
            std.hash.autoHashStrat(&hasher, value.skill_tokens, .Deep);
            std.hash.autoHash(&hasher, value.turn.images.len);
            for (value.turn.images) |image| {
                std.hash.autoHash(&hasher, image.id);
                std.hash.autoHashStrat(&hasher, image.path, .Deep);
                std.hash.autoHashStrat(&hasher, image.media_type, .Deep);
                std.hash.autoHashStrat(&hasher, image.snapshot_path, .Deep);
                std.hash.autoHashStrat(&hasher, image.snapshot_sha256, .Deep);
                std.hash.autoHashStrat(&hasher, image.source_ref, .Deep);
                std.hash.autoHashStrat(&hasher, image.blob_path, .Deep);
                std.hash.autoHash(&hasher, if (image.inline_data) |data| data.len else 0);
            }
            h = mix(h, hasher.final());
        },
        inline else => |value| h = mix(h, deepHash(value)),
    }
    return h;
}

fn hashAction(start: u64, action: EntryRenderAction) u64 {
    return switch (action) {
        .keep => mix(start, 1),
        .hide => mix(start, 2),
        .override => |value| blk: {
            comptime std.debug.assert(@typeInfo(@TypeOf(value)).@"struct".field_names.len == 3);
            var h = mix(start, 3);
            h = mix(h, @backingInt(value.kind));
            h = mix(h, bytesHash(value.bytes));
            h = mix(h, value.line_provenance.len);
            for (value.line_provenance) |line| h = mix(h, provenanceWord(line));
            break :blk h;
        },
    };
}

fn provenanceWord(line: transcript_blocks.LineProvenance) u64 {
    const tag: u64 = @backingInt(std.meta.activeTag(line));
    return switch (line) {
        .entry => |value| tag | @as(u64, value.entry_id) << 8 |
            @as(u64, @backingInt(value.entry_class)) << 40 |
            @as(u64, @backingInt(value.projection_part)) << 52,
        .folded_command_output => |value| tag |
            (if (value.entry_id) |id| @as(u64, id) << 8 | 1 << 40 else 0) |
            @as(u64, @backingInt(value.stream)) << 41,
        .block_separator, .boundary_blank, .capped_continuation, .unattributed, .empty_transcript => tag,
    };
}

const testing = std.testing;

fn rawEntry(id: u32, bytes: []const u8, class: transcript_blocks.RawEntryClass) TranscriptEntry {
    return .{ .raw_bytes = .{ .id = id, .bytes = bytes, .class = class } };
}

test "the boundary is just after the last turn summary" {
    try testing.expectEqual(@as(usize, 0), boundary(&.{}));
    try testing.expectEqual(@as(usize, 0), boundary(&.{rawEntry(1, "welcome\n", .welcome)}));
    const entries = [_]TranscriptEntry{
        rawEntry(1, "welcome\n", .welcome),
        rawEntry(2, "● Read\n", .tool_status),
        rawEntry(3, "0s\n", .turn_summary),
        rawEntry(4, "● Ran\n", .tool_status),
        rawEntry(5, "1s\n", .turn_summary),
        rawEntry(6, "● Running\n", .tool_status),
    };
    try testing.expectEqual(@as(usize, 5), boundary(&entries));
    try testing.expectEqual(@as(usize, 3), boundary(entries[0..4]));
}

test "the key changes with an entry, an action, the width, and the styles" {
    const entries = [_]TranscriptEntry{ rawEntry(1, "one\n", .unknown_raw), rawEntry(2, "two\n", .tool_status) };
    const changed = [_]TranscriptEntry{ rawEntry(1, "one\n", .unknown_raw), rawEntry(2, "two!\n", .tool_status) };
    const actions = [_]EntryRenderAction{ .keep, .keep };
    const hidden = [_]EntryRenderAction{ .keep, .hide };
    const base = key(.prepared, &entries, &actions, 80, .{});
    try testing.expectEqual(base, key(.prepared, &entries, &actions, 80, .{}));
    try testing.expect(base != key(.prepared, &changed, &actions, 80, .{}));
    try testing.expect(base != key(.prepared, &entries, &hidden, 80, .{}));
    try testing.expect(base != key(.prepared, &entries, &actions, 81, .{}));
    try testing.expect(base != key(.prepared, &entries, &actions, 80, .{ .dim_style = "\x1b[2m" }));
    try testing.expect(base != key(.plain, &entries, &.{}, 80, .{}));
    const pinned = [_]TranscriptEntry{ rawEntry(1, "one\n", .unknown_raw), .{ .raw_bytes = .{ .id = 2, .bytes = "two\n", .class = .tool_status, .lifecycle_pinned = true } } };
    try testing.expect(base != key(.prepared, &pinned, &actions, 80, .{}));
    const header = [_]transcript_blocks.LineProvenance{.{ .entry = .{ .entry_id = 2, .entry_class = .tool_status, .projection_part = .group_header } }};
    const child = [_]transcript_blocks.LineProvenance{.{ .entry = .{ .entry_id = 2, .entry_class = .tool_status, .projection_part = .group_child } }};
    const as_header = [_]EntryRenderAction{ .keep, .{ .override = .{ .kind = .tool_status, .bytes = "x\n", .line_provenance = &header } } };
    const as_child = [_]EntryRenderAction{ .keep, .{ .override = .{ .kind = .tool_status, .bytes = "x\n", .line_provenance = &child } } };
    try testing.expect(key(.prepared, &entries, &as_header, 80, .{}) != key(.prepared, &entries, &as_child, 80, .{}));
}

test "an assistant entry keys by its text, not its buffer capacity" {
    const alloc = testing.allocator;
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(alloc);
    try small.appendSlice(alloc, "same text");
    var large: std.ArrayList(u8) = .empty;
    defer large.deinit(alloc);
    try large.ensureTotalCapacity(alloc, 4096);
    try large.appendSlice(alloc, "same text");
    const a = [_]TranscriptEntry{.{ .assistant_turn = .{ .id = 1, .segments = .{ .text = small } } }};
    const b = [_]TranscriptEntry{.{ .assistant_turn = .{ .id = 1, .segments = .{ .text = large } } }};
    try testing.expectEqual(key(.plain, &a, &.{}, 80, .{}), key(.plain, &b, &.{}, 80, .{}));
}

test "a slot is valid only while its entries hash the same" {
    const alloc = testing.allocator;
    var store: FrozenPrefix = .{};
    defer store.deinit();
    const entries = [_]TranscriptEntry{ rawEntry(1, "one\n", .unknown_raw), rawEntry(2, "0s\n", .turn_summary), rawEntry(3, "live\n", .tool_status) };
    var captured: ?PreparationResume = null;
    var rendered = try transcript_blocks.renderEntriesForPreparation(alloc, &entries, 80, .{}, .{
        .capture_at = 2,
        .captured = &captured,
    });
    rendered.deinit(alloc);
    store.store(.plain, key(.plain, entries[0..2], &.{}, 80, .{}), captured.?, alloc);
    try testing.expect(store.valid(.plain, &entries, &.{}, 80, .{}, 3) != null);

    try testing.expect(store.valid(.plain, &entries, &.{}, 80, .{}, 1) == null);
    try testing.expect(store.valid(.plain, &entries, &.{}, 70, .{}, 3) == null);

    const changed = [_]TranscriptEntry{ rawEntry(1, "uno\n", .unknown_raw), rawEntry(2, "0s\n", .turn_summary), rawEntry(3, "live\n", .tool_status) };
    try testing.expect(store.valid(.plain, &changed, &.{}, 80, .{}, 3) == null);

    const later = [_]TranscriptEntry{ rawEntry(1, "one\n", .unknown_raw), rawEntry(2, "0s\n", .turn_summary), rawEntry(3, "done\n", .tool_status) };
    try testing.expect(store.valid(.plain, &later, &.{}, 80, .{}, 3) != null);
    store.discard(.plain);
    try testing.expect(store.valid(.plain, &entries, &.{}, 80, .{}, 3) == null);
}
