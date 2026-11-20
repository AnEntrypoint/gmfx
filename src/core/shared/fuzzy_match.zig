const std = @import("std");
const display_width = @import("display_width.zig");
const ascii_case = @import("ascii_case.zig");

pub const Tier = enum {
    fuzzy,
    words,
    substring,
    prefix,
    exact,

    pub fn isAsTyped(tier: Tier) bool {
        return @backingInt(tier) >= @backingInt(Tier.substring);
    }
};

const max_fuzzy_chars = 64;

pub const Field = struct {
    text: []const u8,
    kind: Kind = .name,

    pub const Kind = enum {
        name,
        text,
    };
};

pub const Match = struct {
    tier: Tier,
    field: usize,
};

const whitespace = " \t\r\n";

pub fn match(query: []const u8, fields: []const Field) ?Match {
    std.debug.assert(fields.len > 0);
    const text = std.mem.trim(u8, query, whitespace);
    if (text.len == 0) return .{ .tier = .exact, .field = 0 };

    var sets: [cached_field_sets]CharSet = undefined;
    const cached = @min(fields.len, cached_field_sets);
    for (fields[0..cached], sets[0..cached]) |field, *set| set.* = .of(field.text);

    if (wholeQueryMatch(text, fields, &sets)) |found| return found;
    if (overFuzzyLimit(text)) return null;
    return wordsMatch(text, fields, &sets);
}

fn overFuzzyLimit(text: []const u8) bool {
    if (text.len <= max_fuzzy_chars) return false;
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += charLen(text, index)) {
        count += 1;
        if (count > max_fuzzy_chars) return true;
    }
    return false;
}

fn wholeQueryMatch(text: []const u8, fields: []const Field, sets: *const [cached_field_sets]CharSet) ?Match {
    var query: ?struct { needed: CharSet, ascii: bool } = null;
    var best: ?Match = null;
    for (fields, 0..) |field, index| {
        if (field.text.len < text.len) continue;
        if (query == null) query = .{ .needed = .of(text), .ascii = !hasNonAscii(text) };
        if (!fieldSet(sets, index).covers(query.?.needed)) continue;
        const tier = wholeQueryTier(field, text, query.?.ascii) orelse continue;
        if (best == null or @backingInt(tier) > @backingInt(best.?.tier)) best = .{ .tier = tier, .field = index };
        if (tier == .exact) break;
    }
    return best;
}

fn wholeQueryTier(field: Field, text: []const u8, ascii: bool) ?Tier {
    if (field.kind == .name) {
        if (matchAt(field.text, 0, text)) |end| return if (end == field.text.len) .exact else .prefix;
    }
    if (contains(field.text, text, ascii)) return .substring;
    return null;
}

fn wordsMatch(text: []const u8, fields: []const Field, sets: *const [cached_field_sets]CharSet) ?Match {
    var tier: Tier = .words;
    var field_index: usize = std.math.maxInt(usize);
    var saw_word = false;
    var words = std.mem.tokenizeAny(u8, text, whitespace);
    while (words.next()) |word| {
        if (skipSeparators(word, 0) == word.len) continue;
        saw_word = true;
        const found = bestWordMatch(word, word.len == text.len, fields, sets) orelse return null;
        if (found.tier == .fuzzy) tier = .fuzzy;
        field_index = @min(field_index, found.field);
    }

    if (!saw_word) return null;
    return .{ .tier = tier, .field = field_index };
}

fn bestWordMatch(word: []const u8, is_whole_query: bool, fields: []const Field, sets: *const [cached_field_sets]CharSet) ?Match {
    const needed: CharSet = .ofWordChars(word);
    const ascii = !hasNonAscii(word);
    for (fields, 0..) |field, index| {
        if (!fieldSet(sets, index).covers(needed)) continue;
        const found = switch (field.kind) {
            .name => containsRun(field.text, word, ascii),
            .text => !is_whole_query and contains(field.text, word, ascii),
        };
        if (found) return .{ .tier = .words, .field = index };
    }
    for (fields, 0..) |field, index| {
        if (field.kind != .name or !fieldSet(sets, index).covers(needed)) continue;
        if (containsWordStartSubsequence(field.text, word)) return .{ .tier = .fuzzy, .field = index };
    }
    return null;
}

fn charLen(text: []const u8, index: usize) usize {
    if (text[index] < 0x80) return 1;
    return display_width.decodeNextRune(text, index).len;
}

fn isWordChar(text: []const u8, index: usize) bool {
    const byte = text[index];
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte);
}

fn hasNonAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return true;
    }
    return false;
}

fn sameChar(a: []const u8, a_index: usize, a_len: usize, b: []const u8, b_index: usize, b_len: usize) bool {
    if (a_len != b_len) return false;
    if (a_len == 1) return std.ascii.toLower(a[a_index]) == std.ascii.toLower(b[b_index]);
    return std.mem.eql(u8, a[a_index..][0..a_len], b[b_index..][0..b_len]);
}

fn skipSeparators(text: []const u8, index: usize) usize {
    var position = index;
    while (position < text.len and !isWordChar(text, position)) position += 1;
    return position;
}

fn isWordStart(text: []const u8, previous: ?usize, index: usize) bool {
    if (!isWordChar(text, index)) return false;
    const before = previous orelse return true;
    if (!isWordChar(text, before)) return true;
    return std.ascii.isDigit(text[before]) != std.ascii.isDigit(text[index]);
}

fn matchAt(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var h = start;
    var n: usize = 0;
    while (n < needle.len) {
        if (h >= haystack.len) return null;
        const h_len = charLen(haystack, h);
        const n_len = charLen(needle, n);
        if (!sameChar(haystack, h, h_len, needle, n, n_len)) return null;
        h += h_len;
        n += n_len;
    }
    return h;
}

fn contains(haystack: []const u8, needle: []const u8, needle_is_ascii: bool) bool {
    if (needle_is_ascii) return ascii_case.containsIgnoreCase(haystack, needle);
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start < haystack.len) : (start += charLen(haystack, start)) {
        if (matchAt(haystack, start, needle) != null) return true;
    }
    return false;
}

fn containsRun(field: []const u8, word: []const u8, word_is_ascii: bool) bool {
    const first = skipSeparators(word, 0);
    const first_lower = std.ascii.toLower(word[first]);

    var needed: usize = 0;
    for (word) |byte| needed += @intFromBool(byte >= 0x80 or std.ascii.isAlphanumeric(byte));
    if (needed > field.len) return false;
    const last_start = field.len - needed;

    var start: usize = 0;
    while (start <= last_start) {
        if (std.ascii.toLower(field[start]) == first_lower) {
            if (if (word_is_ascii) runAtAscii(field, start, word[first..]) else runAt(field, start, word)) return true;
        }

        start += if (word_is_ascii) 1 else charLen(field, start);
    }
    return false;
}

fn runAtAscii(field: []const u8, start: usize, word: []const u8) bool {
    var f = start;
    var w: usize = 0;
    while (true) {
        while (w < word.len and !std.ascii.isAlphanumeric(word[w])) w += 1;
        if (w == word.len) return true;
        while (f < field.len and field[f] < 0x80 and !std.ascii.isAlphanumeric(field[f])) f += 1;
        if (f == field.len) return false;
        if (std.ascii.toLower(field[f]) != std.ascii.toLower(word[w])) return false;
        f += 1;
        w += 1;
    }
}

fn runAt(field: []const u8, start: usize, word: []const u8) bool {
    var f = start;
    var w = skipSeparators(word, 0);
    while (w < word.len) {
        f = skipSeparators(field, f);
        if (f >= field.len) return false;
        const f_len = charLen(field, f);
        const w_len = charLen(word, w);
        if (!sameChar(field, f, f_len, word, w, w_len)) return false;
        f += f_len;
        w = skipSeparators(word, w + w_len);
    }
    return true;
}

fn containsWordStartSubsequence(field: []const u8, word: []const u8) bool {
    const first = skipSeparators(word, 0);
    const first_len = charLen(word, first);

    var f: usize = 0;
    var previous: ?usize = null;
    while (f < field.len) {
        const f_len = charLen(field, f);
        const anchored = isWordStart(field, previous, f) and sameChar(field, f, f_len, word, first, first_len);
        previous = f;
        f += f_len;
        if (anchored) break;
    } else return false;

    var w = skipSeparators(word, first + first_len);
    while (w < word.len) {
        const w_len = charLen(word, w);
        while (true) {
            if (f >= field.len) return false;
            const f_len = charLen(field, f);
            const same = sameChar(field, f, f_len, word, w, w_len);
            f += f_len;
            if (same) break;
        }
        w = skipSeparators(word, w + w_len);
    }
    return true;
}

const CharSet = struct {
    bits: u64 = 0,

    const all: CharSet = .{ .bits = std.math.maxInt(u64) };

    fn of(text: []const u8) CharSet {
        var bits: u64 = 0;
        for (text) |byte| bits |= byte_bits[byte];
        return .{ .bits = bits };
    }

    fn ofWordChars(word: []const u8) CharSet {
        var bits: u64 = 0;
        for (word) |byte| {
            if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) bits |= byte_bits[byte];
        }
        return .{ .bits = bits };
    }

    fn covers(set: CharSet, needed: CharSet) bool {
        return needed.bits & ~set.bits == 0;
    }

    const byte_bits: [256]u64 = table: {
        var table: [256]u64 = undefined;
        for (&table, 0..) |*bit, index| {
            const byte: u8 = @intCast(index);
            const position: u6 = if (byte >= 0x80)
                36
            else if (std.ascii.isAlphabetic(byte))
                @intCast(std.ascii.toLower(byte) - 'a')
            else if (std.ascii.isDigit(byte))
                @intCast(26 + byte - '0')
            else
                @intCast(37 + byte % 27);
            bit.* = @as(u64, 1) << position;
        }
        break :table table;
    };
};

const cached_field_sets = 8;

fn fieldSet(sets: *const [cached_field_sets]CharSet, index: usize) CharSet {
    return if (index < cached_field_sets) sets[index] else .all;
}

pub fn Ranking(comptime Context: type) type {
    return struct {
        context: Context,
        len: usize,

        const Self = @This();

        pub fn count(self: Self) usize {
            var total: usize = 0;
            for (0..self.len) |position| {
                if (self.context.matchAt(position) != null) total += 1;
            }
            return total;
        }

        pub fn at(self: Self, rank: usize) ?usize {
            var counts: [rank_bucket_count]usize = @splat(0);
            for (0..self.len) |position| {
                if (self.context.matchAt(position)) |found| counts[rankBucket(found)] += 1;
            }
            var remaining = rank;
            var bucket: usize = rank_bucket_count;
            const target = while (bucket > 0) {
                bucket -= 1;
                if (remaining < counts[bucket]) break bucket;
                remaining -= counts[bucket];
            } else return null;

            for (0..self.len) |position| {
                const found = self.context.matchAt(position) orelse continue;
                if (rankBucket(found) != target) continue;
                if (remaining == 0) return position;
                remaining -= 1;
            }
            return null;
        }

        pub fn rankOf(self: Self, position: usize) ?usize {
            const target = rankBucket(self.context.matchAt(position) orelse return null);
            var rank: usize = 0;
            for (0..self.len) |other| {
                const found = self.context.matchAt(other) orelse continue;
                const bucket = rankBucket(found);
                if (bucket > target or (bucket == target and other < position)) rank += 1;
            }
            return rank;
        }

        pub fn iterator(self: Self) Iterator {
            var present: u64 = 0;
            for (0..self.len) |position| {
                if (self.context.matchAt(position)) |found| present |= @as(u64, 1) << @intCast(rankBucket(found));
            }
            return .{ .ranking = self, .present = present };
        }

        pub const Iterator = struct {
            ranking: Self,
            present: u64,
            position: usize = 0,

            pub fn next(self: *Iterator) ?usize {
                while (self.present != 0) {
                    const bucket: usize = 63 - @clz(self.present);
                    while (self.position < self.ranking.len) {
                        const position = self.position;
                        self.position += 1;
                        const found = self.ranking.context.matchAt(position) orelse continue;
                        if (rankBucket(found) == bucket) return position;
                    }
                    self.present &= ~(@as(u64, 1) << @intCast(bucket));
                    self.position = 0;
                }
                return null;
            }
        };
    };
}

pub fn Filter(comptime Context: type) type {
    return struct {
        context: Context,
        len: usize,
        floor: Tier,

        const Self = @This();

        pub fn init(context: Context, len: usize) Self {
            const floor: Tier = for (0..len) |position| {
                const found = context.matchAt(position) orelse continue;
                if (found.tier.isAsTyped()) break .substring;
            } else .fuzzy;
            return .{ .context = context, .len = len, .floor = floor };
        }

        pub fn keeps(self: Self, position: usize) bool {
            const found = self.context.matchAt(position) orelse return false;
            return @backingInt(found.tier) >= @backingInt(self.floor);
        }

        pub fn count(self: Self) usize {
            var total: usize = 0;
            for (0..self.len) |position| total += @intFromBool(self.keeps(position));
            return total;
        }

        pub fn at(self: Self, index: usize) ?usize {
            var remaining = index;
            for (0..self.len) |position| {
                if (!self.keeps(position)) continue;
                if (remaining == 0) return position;
                remaining -= 1;
            }
            return null;
        }
    };
}

pub const LabelMatches = struct {
    labels: []const []const u8,
    query: []const u8,

    pub fn matchAt(self: LabelMatches, position: usize) ?Match {
        return match(self.query, &.{.{ .text = self.labels[position] }});
    }
};

pub const ranked_field_limit = 8;
const rank_bucket_count = @typeInfo(Tier).@"enum".field_names.len * ranked_field_limit;

comptime {
    std.debug.assert(rank_bucket_count <= 64);
}

fn rankBucket(found: Match) usize {
    std.debug.assert(found.field < ranked_field_limit);
    return @as(usize, @backingInt(found.tier)) * ranked_field_limit + (ranked_field_limit - 1 - found.field);
}

fn nameField(text: []const u8) Field {
    return .{ .text = text };
}

fn textField(text: []const u8) Field {
    return .{ .text = text, .kind = .text };
}

fn expectMatch(expected: ?Match, query: []const u8, fields: []const Field) !void {
    try std.testing.expectEqual(expected, match(query, fields));
}

test "whole queries rank exact, then prefix, then substring" {
    const id = [_]Field{nameField("anthropic/claude-sonnet-4.5")};
    try expectMatch(.{ .tier = .exact, .field = 0 }, "Anthropic/Claude-Sonnet-4.5", &id);
    try expectMatch(.{ .tier = .prefix, .field = 0 }, "  anthropic/cl ", &id);
    try expectMatch(.{ .tier = .substring, .field = 0 }, "claude-sonnet", &id);
    try expectMatch(.{ .tier = .exact, .field = 0 }, " \t", &id);

    try expectMatch(.{ .tier = .substring, .field = 0 }, "fix renderer", &.{textField("fix renderer")});

    try expectMatch(.{ .tier = .prefix, .field = 1 }, "rel", &.{ textField("release"), nameField("release-notes") });
    try expectMatch(.{ .tier = .substring, .field = 0 }, "notes", &.{ textField("notes"), nameField("release-notes") });
}

test "words match across punctuation in names and as typed in text" {
    const id = [_]Field{nameField("anthropic/claude-sonnet-4.5")};
    try expectMatch(.{ .tier = .words, .field = 0 }, "anthropic sonnet", &id);
    try expectMatch(.{ .tier = .words, .field = 0 }, "sonnet45", &id);
    try expectMatch(.{ .tier = .words, .field = 0 }, "fxcommit", &.{nameField("fx-commit")});
    try expectMatch(.{ .tier = .words, .field = 0 }, "z.ai glm", &.{nameField("zai/glm-4.7")});

    try expectMatch(null, "fxcommit", &.{textField("fx-commit")});
    try expectMatch(.{ .tier = .words, .field = 0 }, "renderer fix", &.{textField("Fix the renderer")});

    try expectMatch(.{ .tier = .words, .field = 0 }, "commit land", &.{ nameField("fx-commit"), textField("land a change") });
    try expectMatch(null, "commit nowhere", &.{ nameField("fx-commit"), textField("land a change") });
}

test "fuzzy letters start at a field word and never match text" {
    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "cs45", &.{nameField("anthropic/claude-sonnet-4.5")});
    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "sonet 4.6", &.{nameField("anthropic/claude-sonnet-4.6")});
    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "zbp", &.{nameField("zig-best-practices")});
    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "/mdl", &.{nameField("/model")});

    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "go", &.{nameField("gpt-4o")});
    try expectMatch(null, "pg", &.{nameField("gpt-4o")});

    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "omi", &.{nameField("acme/gpt4omni")});
    try expectMatch(null, "mi", &.{nameField("acme/gpt4omni")});

    try expectMatch(.{ .tier = .words, .field = 0 }, "pt4", &.{nameField("gpt-4o")});
    try expectMatch(null, "zbp", &.{textField("zig-best-practices")});

    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "zig bp", &.{nameField("zig-best-practices")});
}

test "a query of only punctuation matches only as typed" {
    try expectMatch(.{ .tier = .prefix, .field = 0 }, "/", &.{nameField("/model")});
    try expectMatch(null, "-", &.{nameField("model")});
    try expectMatch(null, "- /", &.{ textField("x"), nameField("y") });

    try expectMatch(null, "//", &.{nameField("/help")});
    try expectMatch(.{ .tier = .substring, .field = 1 }, "--", &.{ nameField("x"), textField("use -- to stop") });

    try expectMatch(.{ .tier = .words, .field = 0 }, "a -", &.{nameField("a")});
}

test "non-ASCII characters are word characters compared whole" {
    try expectMatch(.{ .tier = .words, .field = 0 }, "réglages café", &.{textField("café et réglages")});
    try expectMatch(.{ .tier = .words, .field = 0 }, "cafe2", &.{nameField("Cafe-2")});
    try expectMatch(null, "CAFÉ", &.{nameField("café")});
    try expectMatch(.{ .tier = .substring, .field = 0 }, "AFÉ", &.{nameField("cAfÉ")});

    try expectMatch(.{ .tier = .fuzzy, .field = 0 }, "fz", &.{nameField("c-faz")});
    try expectMatch(null, "fz", &.{nameField("cÉfaz")});

    try expectMatch(null, "\xc3", &.{nameField("caf\xc3\xa9")});
    try expectMatch(.{ .tier = .substring, .field = 0 }, "\xc3", &.{nameField("caf\xc3x")});
}

test "the character filter keeps every field that can match" {
    try expectMatch(.{ .tier = .substring, .field = 0 }, "4.5", &.{nameField("sonnet-4.5")});
    try expectMatch(.{ .tier = .substring, .field = 0 }, "\xff", &.{textField("a \xff b")});
    try expectMatch(.{ .tier = .words, .field = 0 }, "\xff b", &.{textField("b x \xff")});

    var many: [12]Field = @splat(nameField("zzz"));
    many[11] = nameField("needle-here");
    try expectMatch(.{ .tier = .prefix, .field = 11 }, "needle", &many);
    try expectMatch(.{ .tier = .fuzzy, .field = 11 }, "nh", &many);
}

const TestItems = struct {
    items: []const []const Field,
    query: []const u8,

    pub fn matchAt(self: TestItems, position: usize) ?Match {
        return match(self.query, self.items[position]);
    }
};

const RankedTestEntry = struct { position: usize, found: Match };

fn rankedTestLessThan(_: void, a: RankedTestEntry, b: RankedTestEntry) bool {
    if (a.found.tier != b.found.tier) return @backingInt(a.found.tier) > @backingInt(b.found.tier);
    if (a.found.field != b.found.field) return a.found.field < b.found.field;
    return a.position < b.position;
}

test "rankings list matches by tier, then field, then base order" {
    const items = [_][]const Field{
        &.{ nameField("zig-best-practices"), textField("zig code") },
        &.{ nameField("zig"), textField("compiler") },
        &.{ nameField("ziggy"), textField("zig zag") },
        &.{ nameField("other"), textField("zig") },
        &.{ nameField("unrelated"), textField("none") },
        &.{ nameField("zag-ig"), textField("x") },
    };
    const ranking: Ranking(TestItems) = .{ .context = .{ .items = &items, .query = "zig" }, .len = items.len };
    const expected = [_]usize{ 1, 0, 2, 3, 5 };
    try std.testing.expectEqual(expected.len, ranking.count());
    for (expected, 0..) |position, rank| {
        try std.testing.expectEqual(@as(?usize, position), ranking.at(rank));
        try std.testing.expectEqual(@as(?usize, rank), ranking.rankOf(position));
    }
    try std.testing.expectEqual(@as(?usize, null), ranking.at(expected.len));
    try std.testing.expectEqual(@as(?usize, null), ranking.rankOf(4));

    var it = ranking.iterator();
    for (expected) |position| try std.testing.expectEqual(@as(?usize, position), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "rankings agree with a stable sort on random items" {
    const alphabet = [_][]const u8{ "a", "b", "A", "1", "-", " ", "\xc3\xa9", "\xc3" };
    var prng: std.Random.DefaultPrng = .init(0x6a7a);
    const random = prng.random();

    var texts: [24][3][8]u8 = undefined;
    var lens: [24][3]usize = undefined;
    var field_lists: [24][3]Field = undefined;
    var items: [24][]const Field = undefined;
    var query_buf: [6]u8 = undefined;
    var entries: [24]RankedTestEntry = undefined;

    for (0..300) |_| {
        const item_count = 1 + random.uintLessThan(usize, items.len);
        for (0..item_count) |i| {
            const field_count = 1 + random.uintLessThan(usize, 3);
            for (0..field_count) |f| {
                var len: usize = 0;
                while (len < 5) {
                    const piece = alphabet[random.uintLessThan(usize, alphabet.len)];
                    if (len + piece.len > texts[i][f].len or random.uintLessThan(u8, 4) == 0) break;
                    @memcpy(texts[i][f][len..][0..piece.len], piece);
                    len += piece.len;
                }
                lens[i][f] = len;
                field_lists[i][f] = .{ .text = texts[i][f][0..len], .kind = if (random.boolean()) .name else .text };
            }
            items[i] = field_lists[i][0..field_count];
        }
        var query_len: usize = 0;
        while (query_len < 3) {
            const piece = alphabet[random.uintLessThan(usize, 6)];
            if (random.uintLessThan(u8, 3) == 0) break;
            query_buf[query_len] = piece[0];
            query_len += 1;
        }

        const context: TestItems = .{ .items = items[0..item_count], .query = query_buf[0..query_len] };
        var matched: usize = 0;
        for (0..item_count) |position| {
            if (context.matchAt(position)) |found| {
                entries[matched] = .{ .position = position, .found = found };
                matched += 1;
            }
        }
        std.mem.sort(RankedTestEntry, entries[0..matched], {}, rankedTestLessThan);

        const ranking: Ranking(TestItems) = .{ .context = context, .len = item_count };
        try std.testing.expectEqual(matched, ranking.count());
        var it = ranking.iterator();
        for (entries[0..matched], 0..) |entry, rank| {
            try std.testing.expectEqual(@as(?usize, entry.position), ranking.at(rank));
            try std.testing.expectEqual(@as(?usize, rank), ranking.rankOf(entry.position));
            try std.testing.expectEqual(@as(?usize, entry.position), it.next());
        }
        try std.testing.expectEqual(@as(?usize, null), it.next());
        try std.testing.expectEqual(@as(?usize, null), ranking.at(matched));
    }
}

test "filters keep as-typed matches when any exist and otherwise fall back" {
    const items = [_][]const Field{
        &.{ nameField("Save the workspace A transcript."), textField("/tmp/3b0sh/workspace-a") },
        &.{ nameField("Save the workspace B transcript."), textField("/tmp/x/workspace-b") },
        &.{ nameField("Unrelated"), textField("/tmp/y") },
    };

    const exact: Filter(TestItems) = .init(.{ .items = &items, .query = "workspace B" }, items.len);
    try std.testing.expectEqual(Tier.substring, exact.floor);
    try std.testing.expectEqual(@as(usize, 1), exact.count());
    try std.testing.expectEqual(@as(?usize, 1), exact.at(0));
    try std.testing.expectEqual(@as(?usize, null), exact.at(1));
    try std.testing.expect(!exact.keeps(0));

    const fallback: Filter(TestItems) = .init(.{ .items = &items, .query = "wrkspc trnscrpt" }, items.len);
    try std.testing.expectEqual(Tier.fuzzy, fallback.floor);
    try std.testing.expectEqual(@as(usize, 2), fallback.count());
    try std.testing.expectEqual(@as(?usize, 0), fallback.at(0));
    try std.testing.expectEqual(@as(?usize, 1), fallback.at(1));

    const none: Filter(TestItems) = .init(.{ .items = &items, .query = "zzz" }, items.len);
    try std.testing.expectEqual(@as(usize, 0), none.count());

    const labels = [_][]const u8{ "low", "medium", "high" };
    const picked: Filter(LabelMatches) = .init(.{ .labels = &labels, .query = "hgh" }, labels.len);
    try std.testing.expectEqual(@as(?usize, 2), picked.at(0));
}

fn fuzzMatchLaws(_: void, smith: *std.testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];

    var fields: [6]Field = undefined;
    var parts = std.mem.splitScalar(u8, input, 0);
    const query = parts.first();
    var field_count: usize = 0;
    while (parts.next()) |part| {
        if (field_count == fields.len - 1) break;
        fields[field_count] = if (part.len > 0 and part[0] == 1) textField(part[1..]) else nameField(part);
        field_count += 1;
    }
    if (field_count == 0) {
        fields[0] = nameField("");
        field_count = 1;
    }
    const item = fields[0..field_count];

    const answer = match(query, item);
    try std.testing.expectEqual(answer, match(query, item));
    if (answer) |found| try std.testing.expect(found.field < item.len);
    if (std.mem.trim(u8, query, whitespace).len == 0) try std.testing.expectEqual(@as(?Match, .{ .tier = .exact, .field = 0 }), answer);

    var upper: [512]u8 = undefined;
    try std.testing.expectEqual(answer, match(std.ascii.upperString(&upper, query), item));

    if (answer != null) {
        var end: usize = 0;
        var has_word = false;
        while (end < query.len) {
            has_word = has_word or isWordChar(query, end);
            end += charLen(query, end);
            const blank = std.mem.trim(u8, query[0..end], whitespace).len == 0;
            if (has_word or blank) try std.testing.expect(match(query[0..end], item) != null);
        }
    }

    const trimmed = std.mem.trim(u8, query, whitespace);
    const punctuation_only = trimmed.len > 0 and for (trimmed) |byte| {
        if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) break false;
    } else true;
    if (punctuation_only) {
        const held = for (item) |field| {
            if (std.mem.find(u8, field.text, trimmed) != null) break true;
        } else false;
        try std.testing.expectEqual(held, answer != null);
    }
    if (answer) |found| {
        if (overFuzzyLimit(trimmed)) try std.testing.expect(found.tier.isAsTyped());
    }
    for (item, 0..) |field, index| {
        if (trimmed.len == 0 or !std.mem.eql(u8, field.text, trimmed)) continue;
        const best: Tier = if (field.kind == .name) .exact else .substring;
        try std.testing.expect(@backingInt(answer.?.tier) >= @backingInt(best));
        if (field.kind == .name) try std.testing.expect(answer.?.field <= index);
    }

    fields[field_count] = nameField(query);
    const wider = match(query, fields[0 .. field_count + 1]) orelse return error.TestUnexpectedResult;
    if (answer) |found| try std.testing.expect(@backingInt(wider.tier) >= @backingInt(found.tier));
}

test "fuzzy match keeps the model's laws on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzMatchLaws, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "sonet 4.6\x00anthropic/claude-sonnet-4.6",
            "fx commit\x00fx-commit\x00\x01Land a change",
            "cs45\x00anthropic/claude-sonnet-4.5\x00\x01Claude Sonnet 4.5",
            "- /\x00model",
            "caf\xc3\xa9 \xc3\x00Caf\xc3\xa9\x00\x01caf\xc3x",
            "\xff\xfe\x00\xff\x00\x01\xfe",
            " \t\r\n\x00\x00\x00",
        }) ++ @import("fuzz_corpus").fuzzy_match.*),
    });
}
