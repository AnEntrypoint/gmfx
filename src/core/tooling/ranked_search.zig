const std = @import("std");
const io_mod = @import("../shared/io.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_files = @import("../workspace/tool_files.zig");
const symbol_scan = @import("symbol_scan.zig");

const Allocator = std.mem.Allocator;

pub const default_k: usize = 10;
pub const max_k: usize = 50;
pub const max_file_bytes: usize = 1024 * 1024;
pub const default_posting_cap: usize = 4_000_000;
pub const default_build_budget_ms: i64 = 8_000;
pub const window_lines: u32 = 3;
pub const excerpt_bytes: usize = 200;

const max_query_terms: usize = 32;
const max_word_bytes: usize = 64;
const max_hits_per_file: usize = 3;
const max_cached_indexes: usize = 3;
const max_imports_per_file: usize = 256;
const max_window: u32 = std.math.maxInt(u24);
const k1: f64 = 1.2;
const b: f64 = 0.75;
const path_weight: f64 = 0.5;
const coverage_weight: f64 = 0.25;
const hash_seed: u64 = 0x66785f72616e6b65;

const query_stop_words = [_][]const u8{
    "the", "an",  "of",  "to",   "in",   "is",   "it",   "on",    "or",    "as",   "at",  "be",
    "by",  "and", "for", "that", "this", "with", "from", "which", "where", "what", "how", "does",
    "do",  "are", "was", "when", "into", "its",  "a",
};

const import_suffixes = [_][]const u8{ "", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".zig", ".h", ".hpp", "/index.ts", "/index.tsx", "/index.js", "/index.mjs", "/__init__.py" };

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn partBoundary(word: []const u8, index: usize) bool {
    const previous = word[index - 1];
    const current = word[index];
    if (std.ascii.isUpper(current)) {
        if (std.ascii.isLower(previous) or std.ascii.isDigit(previous)) return true;
        return std.ascii.isUpper(previous) and index + 1 < word.len and std.ascii.isLower(word[index + 1]);
    }
    if (std.ascii.isDigit(current)) return std.ascii.isAlphabetic(previous);
    if (std.ascii.isAlphabetic(current)) return std.ascii.isDigit(previous);
    return false;
}

pub fn tokenize(text: []const u8, sink: anytype) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (!isWordByte(text[index])) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < text.len and isWordByte(text[index])) index += 1;
        try tokenizeWord(text[start..@min(index, start + max_word_bytes)], sink);
    }
}

fn tokenizeWord(word: []const u8, sink: anytype) !void {
    var whole: [max_word_bytes]u8 = undefined;
    var whole_len: usize = 0;
    var parts: usize = 0;
    var part_start: usize = 0;
    var index: usize = 0;
    while (index <= word.len) : (index += 1) {
        const at_end = index == word.len;
        const at_separator = !at_end and word[index] == '_';
        if (!at_end and !at_separator and (index == part_start or !partBoundary(word, index))) continue;
        if (index > part_start) {
            const lowered = std.ascii.lowerString(whole[whole_len..], word[part_start..index]);
            whole_len += lowered.len;
            parts += 1;
            const stemmed = lexical_relevance.stem(lowered);
            if (stemmed.len >= 2) try sink.add(stemmed);
        }
        part_start = if (at_separator) index + 1 else index;
    }
    if (parts > 1 and whole_len >= 2) try sink.add(whole[0..whole_len]);
}

fn hashToken(token: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(hash_seed, token));
}

fn packPosting(hash: u32, window: u32, term_frequency: u8) u64 {
    return (@as(u64, hash) << 32) | (@as(u64, window) << 8) | term_frequency;
}

fn postingWindow(posting: u64) u32 {
    return @intCast((posting >> 8) & max_window);
}

fn postingFrequency(posting: u64) u8 {
    return @truncate(posting);
}

fn lowerBound(postings: []const u64, key: u64) usize {
    var low: usize = 0;
    var high: usize = postings.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (postings[middle] < key) low = middle + 1 else high = middle;
    }
    return low;
}

fn termRange(postings: []const u64, hash: u32) []const u64 {
    const first = lowerBound(postings, @as(u64, hash) << 32);
    const last = if (hash == std.math.maxInt(u32)) postings.len else lowerBound(postings, (@as(u64, hash) + 1) << 32);
    return postings[first..last];
}

fn containsHash(sorted: []const u32, hash: u32) bool {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle] < hash) low = middle + 1 else high = middle;
    }
    return low < sorted.len and sorted[low] == hash;
}

const QueryTerms = struct {
    hashes: [max_query_terms]u32 = undefined,
    len: usize = 0,

    pub fn add(self: *QueryTerms, token: []const u8) !void {
        const hash = hashToken(token);
        for (self.hashes[0..self.len]) |known| {
            if (known == hash) return;
        }
        if (self.len == max_query_terms) return;
        self.hashes[self.len] = hash;
        self.len += 1;
    }

    fn of(query: []const u8) QueryTerms {
        var terms: QueryTerms = .{};
        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (words.next()) |word| {
            if (isStopWord(word)) continue;
            tokenize(word, &terms) catch unreachable;
        }
        return terms;
    }

    fn slice(self: *const QueryTerms) []const u32 {
        return self.hashes[0..self.len];
    }
};

fn isStopWord(word: []const u8) bool {
    for (query_stop_words) |stop| {
        if (std.ascii.eqlIgnoreCase(stop, word)) return true;
    }
    return false;
}

const IdentitySink = struct {
    hash: ?u32 = null,

    pub fn add(self: *IdentitySink, token: []const u8) !void {
        self.hash = hashToken(token);
    }
};

const MatchSink = struct {
    terms: []const u32,
    seen: u32 = 0,

    pub fn add(self: *MatchSink, token: []const u8) !void {
        const hash = hashToken(token);
        for (self.terms, 0..) |term, index| {
            if (term == hash) self.seen |= @as(u32, 1) << @intCast(index);
        }
    }
};

const KeySink = struct {
    alloc: Allocator,
    keys: *std.ArrayList(u64),
    window: u32,
    count: usize = 0,

    pub fn add(self: *KeySink, token: []const u8) Allocator.Error!void {
        try self.keys.append(self.alloc, packPosting(hashToken(token), self.window, 0));
        self.count += 1;
    }
};

const HashSink = struct {
    alloc: Allocator,
    hashes: *std.ArrayList(u32),

    pub fn add(self: *HashSink, token: []const u8) Allocator.Error!void {
        try self.hashes.append(self.alloc, hashToken(token));
    }
};

const Segment = struct {
    path: []u8,
    state: State = .pending,
    size: u64 = 0,
    mtime_ns: i96 = 0,
    postings: []u64 = &.{},
    lengths: []u16 = &.{},
    path_terms: []u32 = &.{},
    imports: []u8 = &.{},
    token_total: u64 = 0,

    const State = enum { pending, indexed, skipped, over_cap };

    fn dropContent(self: *Segment, alloc: Allocator) usize {
        const released = self.postings.len;
        alloc.free(self.postings);
        alloc.free(self.lengths);
        alloc.free(self.path_terms);
        alloc.free(self.imports);
        self.postings = &.{};
        self.lengths = &.{};
        self.path_terms = &.{};
        self.imports = &.{};
        self.token_total = 0;
        return released;
    }

    fn deinit(self: *Segment, alloc: Allocator) void {
        _ = self.dropContent(alloc);
        alloc.free(self.path);
    }
};

pub const Stats = struct {
    files: usize = 0,
    indexed: usize = 0,
    pending: usize = 0,
    over_cap: usize = 0,
    skipped: usize = 0,
    posting_cap: usize = default_posting_cap,
    budget_ms: i64 = default_build_budget_ms,

    pub fn incomplete(self: Stats) bool {
        return self.pending > 0 or self.over_cap > 0;
    }

    pub fn writeNotes(self: Stats, writer: *std.Io.Writer) error{OutOfMemory}!void {
        if (self.pending > 0) {
            writer.print("... index incomplete: {d} of {d} files indexed within the {d} ms budget; repeat the search to index the rest\n", .{ self.indexed, self.indexed + self.pending + self.over_cap, self.budget_ms }) catch return error.OutOfMemory;
        }
        if (self.over_cap > 0) {
            writer.print("... index incomplete: {d} files left out after the {d}-posting memory cap\n", .{ self.over_cap, self.posting_cap }) catch return error.OutOfMemory;
        }
    }
};

pub const Limits = struct {
    deadline_ms: ?i64 = null,
    cancel: ?*std.atomic.Value(bool) = null,

    fn reached(self: Limits) bool {
        if (self.cancel) |flag| {
            if (flag.load(.acquire)) return true;
        }
        const deadline = self.deadline_ms orelse return false;
        return io_mod.awakeMilliTimestamp() >= deadline;
    }
};

pub const Hit = struct {
    path: []const u8,
    line: usize,
    excerpt: []const u8,
};

pub const Importer = struct {
    path: []const u8,
    depth: usize,
};

pub const Importers = struct {
    files: []const Importer,
    truncated: bool,
};

const Candidate = struct {
    segment: u32,
    window: u32,
    score: f64,

    fn before(self: Candidate, other: Candidate) bool {
        if (self.score != other.score) return self.score > other.score;
        if (self.segment != other.segment) return self.segment < other.segment;
        return self.window < other.window;
    }
};

const Scored = struct {
    window: u32,
    score: f64,

    fn lessThan(_: void, a: Scored, c: Scored) bool {
        return a.window < c.window;
    }
};

pub const Index = struct {
    alloc: Allocator,
    root: []u8,
    include_ignored: bool,
    segments: std.ArrayList(Segment) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    posting_total: usize = 0,
    posting_cap: usize = default_posting_cap,
    last_used: u64 = 0,
    stats: Stats = .{},

    pub fn init(alloc: Allocator, root: []const u8, include_ignored: bool) Allocator.Error!Index {
        return .{ .alloc = alloc, .root = try alloc.dupe(u8, root), .include_ignored = include_ignored };
    }

    pub fn deinit(self: *Index) void {
        for (self.segments.items) |*segment| segment.deinit(self.alloc);
        self.segments.deinit(self.alloc);
        self.by_path.deinit(self.alloc);
        self.alloc.free(self.root);
        self.* = undefined;
    }

    pub fn refresh(self: *Index, files: []const []const u8, limits: Limits) Allocator.Error!void {
        try self.reconcile(files);
        var stats: Stats = .{ .files = self.segments.items.len, .posting_cap = self.posting_cap, .budget_ms = self.stats.budget_ms };
        const io = io_mod.getIo();
        var root_dir = std.Io.Dir.openDirAbsolute(io, self.root, .{}) catch {
            for (self.segments.items) |*segment| {
                self.posting_total -= segment.dropContent(self.alloc);
                segment.state = .skipped;
            }
            stats.skipped = stats.files;
            self.stats = stats;
            return;
        };
        defer root_dir.close(io);

        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(self.alloc);
        for (self.segments.items) |*segment| {
            try self.refreshSegment(root_dir, segment, limits, &keys);
            switch (segment.state) {
                .pending => stats.pending += 1,
                .indexed => stats.indexed += 1,
                .skipped => stats.skipped += 1,
                .over_cap => stats.over_cap += 1,
            }
        }
        self.stats = stats;
    }

    fn reconcile(self: *Index, files: []const []const u8) Allocator.Error!void {
        const old = self.segments.items;
        const taken = try self.alloc.alloc(bool, old.len);
        defer self.alloc.free(taken);
        @memset(taken, false);

        var next: std.ArrayList(Segment) = .empty;
        errdefer next.deinit(self.alloc);
        try next.ensureTotalCapacityPrecise(self.alloc, files.len);
        var created: std.ArrayList([]u8) = .empty;
        defer created.deinit(self.alloc);
        errdefer for (created.items) |path| self.alloc.free(path);
        try self.by_path.ensureTotalCapacity(self.alloc, @intCast(files.len));

        for (files) |path| {
            if (self.by_path.get(path)) |index| {
                if (!taken[index]) {
                    taken[index] = true;
                    next.appendAssumeCapacity(old[index]);
                    continue;
                }
            }
            const owned = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(owned);
            try created.append(self.alloc, owned);
            next.appendAssumeCapacity(.{ .path = owned });
        }

        for (old, taken) |*segment, kept| {
            if (kept) continue;
            self.posting_total -= segment.postings.len;
            segment.deinit(self.alloc);
        }
        self.segments.deinit(self.alloc);
        self.segments = next;
        self.by_path.clearRetainingCapacity();
        for (self.segments.items, 0..) |segment, index| self.by_path.putAssumeCapacity(segment.path, @intCast(index));
    }

    fn refreshSegment(self: *Index, root_dir: std.Io.Dir, segment: *Segment, limits: Limits, keys: *std.ArrayList(u64)) Allocator.Error!void {
        const stat = root_dir.statFile(io_mod.getIo(), segment.path, .{}) catch {
            self.posting_total -= segment.dropContent(self.alloc);
            segment.state = .skipped;
            return;
        };
        if (stat.kind != .file) {
            self.posting_total -= segment.dropContent(self.alloc);
            segment.state = .skipped;
            return;
        }
        const unchanged = segment.size == stat.size and segment.mtime_ns == stat.mtime.nanoseconds;
        if (unchanged and segment.state != .pending) return;

        self.posting_total -= segment.dropContent(self.alloc);
        segment.size = stat.size;
        segment.mtime_ns = stat.mtime.nanoseconds;
        if (stat.size > max_file_bytes) {
            segment.state = .skipped;
            return;
        }
        if (limits.reached()) {
            segment.state = .pending;
            return;
        }
        try self.indexSegment(root_dir, segment, keys);
    }

    fn indexSegment(self: *Index, root_dir: std.Io.Dir, segment: *Segment, keys: *std.ArrayList(u64)) Allocator.Error!void {
        segment.state = .skipped;
        var file = io_mod.openExistingReadOnlyRegularFile(root_dir, segment.path, .no_follow) catch return;
        defer file.close(io_mod.getIo());
        const content = io_mod.readFileToEnd(self.alloc, &file, max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer self.alloc.free(content);
        if (!text_utils.isModelSafeText(content)) return;

        keys.clearRetainingCapacity();
        var lengths: std.ArrayList(u16) = .empty;
        defer lengths.deinit(self.alloc);
        var imports: std.ArrayList(u8) = .empty;
        defer imports.deinit(self.alloc);
        var import_count: usize = 0;
        var token_total: u64 = 0;
        const language = symbol_scan.Language.ofPath(segment.path);

        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| : (line_number += 1) {
            const window = line_number / window_lines;
            if (window > max_window) break;
            if (lengths.items.len <= window) try lengths.append(self.alloc, 0);
            var sink: KeySink = .{ .alloc = self.alloc, .keys = keys, .window = window };
            try tokenize(line, &sink);
            token_total += sink.count;
            lengths.items[window] +|= @intCast(@min(sink.count, std.math.maxInt(u16)));
            if (import_count >= max_imports_per_file) continue;
            const import = symbol_scan.importOf(line, language) orelse continue;
            if (std.mem.findAny(u8, import.specifier, "\n\t") != null) continue;
            if (import.dotted) try imports.append(self.alloc, '\t');
            try imports.appendSlice(self.alloc, import.specifier);
            try imports.append(self.alloc, '\n');
            import_count += 1;
        }

        std.mem.sortUnstable(u64, keys.items, {}, std.sort.asc(u64));
        var unique: usize = 0;
        for (keys.items, 0..) |key, index| {
            if (index == 0 or keys.items[index - 1] != key) unique += 1;
        }
        if (self.posting_total + unique > self.posting_cap) {
            segment.state = .over_cap;
            return;
        }

        const postings = try self.alloc.alloc(u64, unique);
        errdefer self.alloc.free(postings);
        var written: usize = 0;
        for (keys.items, 0..) |key, index| {
            if (index > 0 and keys.items[index - 1] == key) {
                if (postingFrequency(postings[written - 1]) < std.math.maxInt(u8)) postings[written - 1] += 1;
                continue;
            }
            postings[written] = key | 1;
            written += 1;
        }

        var path_hashes: std.ArrayList(u32) = .empty;
        defer path_hashes.deinit(self.alloc);
        var path_sink: HashSink = .{ .alloc = self.alloc, .hashes = &path_hashes };
        try tokenize(segment.path, &path_sink);
        std.mem.sortUnstable(u32, path_hashes.items, {}, std.sort.asc(u32));

        const owned_lengths = try self.alloc.dupe(u16, lengths.items);
        errdefer self.alloc.free(owned_lengths);
        const owned_path_terms = try self.alloc.dupe(u32, path_hashes.items);
        errdefer self.alloc.free(owned_path_terms);
        const owned_imports = try self.alloc.dupe(u8, imports.items);

        segment.postings = postings;
        segment.lengths = owned_lengths;
        segment.path_terms = owned_path_terms;
        segment.imports = owned_imports;
        segment.token_total = token_total;
        segment.state = .indexed;
        self.posting_total += unique;
    }

    pub fn search(self: *const Index, arena: Allocator, query: []const u8, k: usize) Allocator.Error![]Hit {
        const terms = QueryTerms.of(query);
        const hashes = terms.slice();
        const limit = @max(1, @min(k, max_k));
        if (hashes.len == 0) return &.{};

        var document_count: u64 = 0;
        var token_count: u64 = 0;
        var document_frequency: [max_query_terms]u64 = @splat(0);
        for (self.segments.items) |segment| {
            if (segment.state != .indexed) continue;
            document_count += segment.lengths.len;
            token_count += segment.token_total;
            for (hashes, 0..) |hash, index| document_frequency[index] += termRange(segment.postings, hash).len;
        }
        if (document_count == 0) return &.{};

        const documents: f64 = @floatFromInt(document_count);
        const average_length: f64 = @max(1.0, @as(f64, @floatFromInt(token_count)) / documents);
        var inverse_frequency: [max_query_terms]f64 = undefined;
        for (hashes, 0..) |_, index| {
            const frequency: f64 = @floatFromInt(document_frequency[index]);
            inverse_frequency[index] = @log(1.0 + (documents - frequency + 0.5) / (frequency + 0.5));
        }

        var top: std.ArrayList(Candidate) = .empty;
        try top.ensureTotalCapacityPrecise(arena, limit + 1);
        var scored: std.ArrayList(Scored) = .empty;
        for (self.segments.items, 0..) |segment, segment_index| {
            if (segment.state != .indexed) continue;
            scored.clearRetainingCapacity();
            for (hashes, 0..) |hash, index| {
                for (termRange(segment.postings, hash)) |posting| {
                    const window = postingWindow(posting);
                    const frequency: f64 = @floatFromInt(postingFrequency(posting));
                    const length: f64 = @floatFromInt(segment.lengths[window]);
                    const weight = frequency * (k1 + 1.0) / (frequency + k1 * (1.0 - b + b * length / average_length));
                    try scored.append(arena, .{ .window = window, .score = inverse_frequency[index] * weight });
                }
            }
            if (scored.items.len == 0) continue;
            var path_bonus: f64 = 0;
            for (hashes, 0..) |hash, index| {
                if (containsHash(segment.path_terms, hash)) path_bonus += path_weight * inverse_frequency[index];
            }
            std.mem.sortUnstable(Scored, scored.items, {}, Scored.lessThan);

            var best: [max_hits_per_file]Candidate = undefined;
            var best_len: usize = 0;
            var cursor: usize = 0;
            while (cursor < scored.items.len) {
                const window = scored.items[cursor].window;
                var sum: f64 = 0;
                var matched: f64 = 0;
                while (cursor < scored.items.len and scored.items[cursor].window == window) : (cursor += 1) {
                    sum += scored.items[cursor].score;
                    matched += 1;
                }
                const candidate: Candidate = .{
                    .segment = @intCast(segment_index),
                    .window = window,
                    .score = (sum + path_bonus) * (1.0 + coverage_weight * (matched - 1.0)),
                };
                insertCandidate(best[0..], &best_len, candidate);
            }
            for (best[0..best_len]) |candidate| {
                if (top.items.len == limit and !candidate.before(top.items[limit - 1])) continue;
                var at: usize = top.items.len;
                while (at > 0 and candidate.before(top.items[at - 1])) at -= 1;
                top.insertAssumeCapacity(at, candidate);
                if (top.items.len > limit) top.shrinkRetainingCapacity(limit);
            }
        }

        const hits = try arena.alloc(Hit, top.items.len);
        const io = io_mod.getIo();
        const root_dir: ?std.Io.Dir = std.Io.Dir.openDirAbsolute(io, self.root, .{}) catch null;
        defer if (root_dir) |dir| dir.close(io);
        for (top.items, hits) |candidate, *hit| {
            const segment = self.segments.items[candidate.segment];
            hit.* = .{
                .path = try arena.dupe(u8, segment.path),
                .line = @as(usize, candidate.window) * window_lines + 1,
                .excerpt = "",
            };
            const dir = root_dir orelse continue;
            try self.describeHit(arena, dir, hashes, candidate.window, hit);
        }
        return hits;
    }

    fn describeHit(self: *const Index, arena: Allocator, root_dir: std.Io.Dir, hashes: []const u32, window: u32, hit: *Hit) Allocator.Error!void {
        var file = io_mod.openExistingReadOnlyRegularFile(root_dir, hit.path, .no_follow) catch return;
        defer file.close(io_mod.getIo());
        const content = io_mod.readFileToEnd(self.alloc, &file, max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer self.alloc.free(content);

        const first_line = @as(usize, window) * window_lines;
        var best_matches: usize = 0;
        var best_line: ?[]const u8 = null;
        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| : (line_number += 1) {
            if (line_number < first_line) continue;
            if (line_number >= first_line + window_lines) break;
            var sink: MatchSink = .{ .terms = hashes };
            tokenize(line, &sink) catch unreachable;
            const matches = @popCount(sink.seen);
            if (best_line != null and matches <= best_matches) continue;
            if (best_line != null and std.mem.trim(u8, line, " \t\r").len == 0) continue;
            best_matches = matches;
            best_line = line;
            hit.line = line_number + 1;
        }
        const line = std.mem.trim(u8, best_line orelse return, " \t\r");
        const clipped = line[0..text_utils.utf8BackwardBoundary(line, @min(line.len, excerpt_bytes))];
        const excerpt = try arena.dupe(u8, clipped);
        for (excerpt) |*byte| {
            if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
        }
        hit.excerpt = excerpt;
    }

    pub fn filesMentioning(self: *const Index, arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var identity: IdentitySink = .{};
        tokenize(name, &identity) catch unreachable;
        var paths: std.ArrayList([]const u8) = .empty;
        for (self.segments.items) |segment| {
            const wanted = switch (segment.state) {
                .skipped => false,
                .pending, .over_cap => true,
                .indexed => if (identity.hash) |hash| termRange(segment.postings, hash).len > 0 else true,
            };
            if (wanted) try paths.append(arena, try arena.dupe(u8, segment.path));
        }
        return paths.toOwnedSlice(arena);
    }

    pub fn importers(self: *const Index, arena: Allocator, targets: []const []const u8, max_depth: usize, max_files: usize) Allocator.Error!Importers {
        const Edge = struct {
            target: u32,
            importer: u32,

            fn lessThan(_: void, a: @This(), c: @This()) bool {
                if (a.target != c.target) return a.target < c.target;
                return a.importer < c.importer;
            }
        };
        var edges: std.ArrayList(Edge) = .empty;
        for (self.segments.items, 0..) |segment, importer| {
            var specifiers = std.mem.tokenizeScalar(u8, segment.imports, '\n');
            while (specifiers.next()) |raw| {
                const dotted = raw[0] == '\t';
                const target = try self.resolveImport(arena, segment.path, if (dotted) raw[1..] else raw, dotted) orelse continue;
                if (target == importer) continue;
                try edges.append(arena, .{ .target = target, .importer = @intCast(importer) });
            }
        }
        std.mem.sortUnstable(Edge, edges.items, {}, Edge.lessThan);

        const visited = try arena.alloc(bool, self.segments.items.len);
        @memset(visited, false);
        var frontier: std.ArrayList(u32) = .empty;
        for (targets) |path| {
            const index = self.by_path.get(path) orelse continue;
            if (visited[index]) continue;
            visited[index] = true;
            try frontier.append(arena, index);
        }

        var found: std.ArrayList(Importer) = .empty;
        var truncated = false;
        var depth: usize = 1;
        while (depth <= max_depth and frontier.items.len > 0 and !truncated) : (depth += 1) {
            var next: std.ArrayList(u32) = .empty;
            for (frontier.items) |target| {
                var low: usize = 0;
                var high: usize = edges.items.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    if (edges.items[middle].target < target) low = middle + 1 else high = middle;
                }
                while (low < edges.items.len and edges.items[low].target == target) : (low += 1) {
                    const importer = edges.items[low].importer;
                    if (visited[importer]) continue;
                    visited[importer] = true;
                    if (found.items.len == max_files) {
                        truncated = true;
                        break;
                    }
                    try found.append(arena, .{ .path = try arena.dupe(u8, self.segments.items[importer].path), .depth = depth });
                    try next.append(arena, importer);
                }
                if (truncated) break;
            }
            frontier = next;
        }
        return .{ .files = try found.toOwnedSlice(arena), .truncated = truncated };
    }

    fn resolveImport(self: *const Index, arena: Allocator, importer: []const u8, specifier: []const u8, dotted: bool) Allocator.Error!?u32 {
        const directory = std.Io.Dir.path.dirname(importer) orelse "";
        if (dotted) {
            var leading: usize = 0;
            while (leading < specifier.len and specifier[leading] == '.') leading += 1;
            const module = try arena.dupe(u8, specifier[leading..]);
            std.mem.replaceScalar(u8, module, '.', '/');
            if (leading > 0) {
                var base = directory;
                var climbs = leading - 1;
                while (climbs > 0) : (climbs -= 1) base = std.Io.Dir.path.dirname(base) orelse "";
                return self.lookupImport(arena, base, module);
            }
            if (try self.lookupImport(arena, directory, module)) |index| return index;
            return self.lookupImport(arena, "", module);
        }
        if (try self.lookupImport(arena, directory, specifier)) |index| return index;
        if (std.mem.startsWith(u8, specifier, ".")) return null;
        return self.lookupImport(arena, "", specifier);
    }

    fn lookupImport(self: *const Index, arena: Allocator, directory: []const u8, specifier: []const u8) Allocator.Error!?u32 {
        const joined = try normalizeRelative(arena, directory, specifier) orelse return null;
        for (import_suffixes) |suffix| {
            const candidate = try std.mem.concat(arena, u8, &.{ joined, suffix });
            if (self.by_path.get(candidate)) |index| return index;
        }
        if (std.mem.endsWith(u8, joined, ".js")) {
            for ([_][]const u8{ ".ts", ".tsx" }) |suffix| {
                const candidate = try std.mem.concat(arena, u8, &.{ joined[0 .. joined.len - 3], suffix });
                if (self.by_path.get(candidate)) |index| return index;
            }
        }
        return null;
    }
};

fn insertCandidate(best: []Candidate, len: *usize, candidate: Candidate) void {
    var at: usize = len.*;
    while (at > 0 and candidate.before(best[at - 1])) at -= 1;
    if (at == best.len) return;
    const last = @min(len.*, best.len - 1);
    var index = last;
    while (index > at) : (index -= 1) best[index] = best[index - 1];
    best[at] = candidate;
    len.* = @min(len.* + 1, best.len);
}

fn normalizeRelative(arena: Allocator, directory: []const u8, specifier: []const u8) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ directory, specifier }) |text| {
        var pieces = std.mem.tokenizeAny(u8, text, "/\\");
        while (pieces.next()) |piece| {
            if (std.mem.eql(u8, piece, ".")) continue;
            if (std.mem.eql(u8, piece, "..")) {
                if (parts.items.len == 0) return null;
                _ = parts.pop();
                continue;
            }
            try parts.append(arena, piece);
        }
    }
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, "/", parts.items);
}

var cache_lock: std.Io.Mutex = .init;
var cached_indexes: [max_cached_indexes]?*Index = @splat(null);
var cache_clock: u64 = 0;

pub const Request = struct {
    workspace_root: []const u8,
    absolute_root: []const u8,
    include_ignored: bool = false,
    budget_ms: i64 = default_build_budget_ms,
    cancel: ?*std.atomic.Value(bool) = null,
};

pub const Lease = struct {
    index: *Index,
    completeness: tool_files.Completeness,

    pub fn release(self: Lease) void {
        _ = self;
        cache_lock.unlock(io_mod.getIo());
    }

    pub fn writeNotes(self: Lease, writer: *std.Io.Writer) error{OutOfMemory}!void {
        try self.index.stats.writeNotes(writer);
        try self.completeness.writeNotes(writer);
    }
};

pub const PrepareError = Allocator.Error || error{FileNotFound};

pub fn prepare(lifetime: Allocator, scratch: Allocator, request: Request) PrepareError!Lease {
    var listing_arena = std.heap.ArenaAllocator.init(scratch);
    defer listing_arena.deinit();
    const listing = try tool_files.list(scratch, listing_arena.allocator(), request.workspace_root, request.absolute_root, .{
        .include_ignored = request.include_ignored,
        .include_hidden = request.include_ignored,
        .include_hidden_in_repository = true,
    });

    cache_lock.lockUncancelable(io_mod.getIo());
    errdefer cache_lock.unlock(io_mod.getIo());
    const index = try cachedIndex(lifetime, request.absolute_root, request.include_ignored);
    index.stats.budget_ms = request.budget_ms;
    try index.refresh(listing.files, .{
        .deadline_ms = io_mod.awakeMilliTimestamp() + request.budget_ms,
        .cancel = request.cancel,
    });
    return .{ .index = index, .completeness = tool_files.Completeness.of(listing) };
}

fn cachedIndex(lifetime: Allocator, root: []const u8, include_ignored: bool) Allocator.Error!*Index {
    cache_clock += 1;
    var free_slot: ?usize = null;
    var oldest_slot: usize = 0;
    for (cached_indexes, 0..) |entry, slot| {
        const index = entry orelse {
            if (free_slot == null) free_slot = slot;
            continue;
        };
        if (index.include_ignored == include_ignored and std.mem.eql(u8, index.root, root)) {
            index.last_used = cache_clock;
            return index;
        }
        if (cached_indexes[oldest_slot] == null or index.last_used < cached_indexes[oldest_slot].?.last_used) oldest_slot = slot;
    }
    const created = try lifetime.create(Index);
    errdefer lifetime.destroy(created);
    created.* = try Index.init(lifetime, root, include_ignored);
    created.last_used = cache_clock;
    const slot = free_slot orelse oldest_slot;
    if (cached_indexes[slot]) |evicted| {
        const owner = evicted.alloc;
        evicted.deinit();
        owner.destroy(evicted);
    }
    cached_indexes[slot] = created;
    return created;
}

pub fn dropCachedIndexes() void {
    cache_lock.lockUncancelable(io_mod.getIo());
    defer cache_lock.unlock(io_mod.getIo());
    for (&cached_indexes) |*entry| {
        const index = entry.* orelse continue;
        const owner = index.alloc;
        index.deinit();
        owner.destroy(index);
        entry.* = null;
    }
}

const TestTokens = struct {
    alloc: Allocator,
    tokens: std.ArrayList([]u8) = .empty,

    pub fn add(self: *TestTokens, token: []const u8) Allocator.Error!void {
        const owned = try self.alloc.dupe(u8, token);
        errdefer self.alloc.free(owned);
        try self.tokens.append(self.alloc, owned);
    }

    fn deinit(self: *TestTokens) void {
        for (self.tokens.items) |token| self.alloc.free(token);
        self.tokens.deinit(self.alloc);
    }

    fn expect(self: *const TestTokens, expected: []const []const u8) !void {
        errdefer for (self.tokens.items) |token| std.debug.print("  got {s}\n", .{token});
        try std.testing.expectEqual(expected.len, self.tokens.items.len);
        for (expected, self.tokens.items) |want, have| try std.testing.expectEqualStrings(want, have);
    }
};

fn expectTokens(text: []const u8, expected: []const []const u8) !void {
    var tokens: TestTokens = .{ .alloc = std.testing.allocator };
    defer tokens.deinit();
    try tokenize(text, &tokens);
    try tokens.expect(expected);
}

const TestTree = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !TestTree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".") };
    }

    fn deinit(self: *TestTree) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn file(self: *TestTree, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }
};

const fixture_retry =
    \\const std = @import("std");
    \\const clock = @import("clock.zig");
    \\
    \\pub fn parseRetryAfter(header: []const u8) ?u64 {
    \\    return std.fmt.parseInt(u64, header, 10) catch null;
    \\}
    \\
;
const fixture_clock =
    \\pub fn nowMs() i64 {
    \\    return 0;
    \\}
    \\
;
const fixture_client =
    \\import { loadConfig } from './config';
    \\
    \\export function connect(url) {
    \\  return loadConfig(url);
    \\}
    \\
;
const fixture_config =
    \\export function loadConfig(path) {
    \\  return { path };
    \\}
    \\
;

fn writeFixture(tree: *TestTree) !void {
    try tree.file("src/net/retry.zig", fixture_retry);
    try tree.file("src/net/clock.zig", fixture_clock);
    try tree.file("web/client.js", fixture_client);
    try tree.file("web/config.js", fixture_config);
    try tree.file("docs/notes.md", "Release checklist\n\nRun the unit tests before tagging.\n");
}

const fixture_files = [_][]const u8{ "docs/notes.md", "src/net/clock.zig", "src/net/retry.zig", "web/client.js", "web/config.js" };

test "ranked search tokens include an identifier and its camel, snake, kebab and path parts" {
    try expectTokens("parseRetryAfter", &.{ "pars", "retry", "aft", "parseretryafter" });
    try expectTokens("parse_retry_after", &.{ "pars", "retry", "aft", "parseretryafter" });
    try expectTokens("retry-after", &.{ "retry", "aft" });
    try expectTokens("src/net/http_client.zig", &.{ "src", "net", "http", "client", "httpclient", "zig" });
    try expectTokens("HTTPServer2", &.{ "http", "serv", "httpserver2" });
    try expectTokens("a b", &.{});
    try expectTokens("headers", &.{"head"});
}

test "ranked search finds a function from a description and ranks it first" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&fixture_files, .{});
    try std.testing.expectEqual(@as(usize, 5), index.stats.indexed);
    try std.testing.expect(!index.stats.incomplete());

    const hits = try index.search(arena, "parse the retry after header", 10);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqualStrings("src/net/retry.zig", hits[0].path);
    try std.testing.expectEqual(@as(usize, 4), hits[0].line);
    try std.testing.expectEqualStrings("pub fn parseRetryAfter(header: []const u8) ?u64 {", hits[0].excerpt);

    const config_hits = try index.search(arena, "load_config", 5);
    var defining_file_found = false;
    for (config_hits) |hit| {
        try std.testing.expect(std.mem.startsWith(u8, hit.path, "web/"));
        if (std.mem.eql(u8, hit.path, "web/config.js") and hit.line == 1) defining_file_found = true;
    }
    try std.testing.expect(defining_file_found);

    try std.testing.expectEqual(@as(usize, 0), (try index.search(arena, "kubernetes", 10)).len);
    try std.testing.expectEqual(@as(usize, 0), (try index.search(arena, "the of and", 10)).len);
}

test "ranked search keeps at most k hits and at most three per file" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    for (0..40) |_| try body.appendSlice(alloc, "widget assembly line\n\n\n");
    try tree.file("one.txt", body.items);
    try tree.file("two.txt", body.items);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&.{ "one.txt", "two.txt" }, .{});
    const hits = try index.search(arena_state.allocator(), "widget", 5);
    try std.testing.expectEqual(@as(usize, 5), hits.len);
    var from_one: usize = 0;
    for (hits) |hit| from_one += @intFromBool(std.mem.eql(u8, hit.path, "one.txt"));
    try std.testing.expectEqual(@as(usize, 3), from_one);
    const capped = try index.search(arena_state.allocator(), "widget", 500);
    try std.testing.expectEqual(@as(usize, 6), capped.len);
}

test "ranked search index is invalidated by a file's size and time and drops removed files" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&fixture_files, .{});
    const postings_before = index.posting_total;
    try index.refresh(&fixture_files, .{ .deadline_ms = -1 });
    try std.testing.expectEqual(@as(usize, 0), index.stats.pending);
    try std.testing.expectEqual(postings_before, index.posting_total);

    try tree.file("src/net/clock.zig", "pub fn monotonicNanoseconds() u64 {\n    return 42;\n}\n");
    try index.refresh(&fixture_files, .{});
    const renamed = try index.search(arena, "monotonic nanoseconds", 3);
    try std.testing.expectEqual(@as(usize, 1), renamed.len);
    try std.testing.expectEqualStrings("src/net/clock.zig", renamed[0].path);
    try std.testing.expectEqual(@as(usize, 0), (try index.search(arena, "nowMs", 3)).len);

    try index.refresh(&.{ "docs/notes.md", "src/net/clock.zig" }, .{});
    try std.testing.expectEqual(@as(usize, 2), index.stats.files);
    try std.testing.expectEqual(@as(usize, 0), (try index.search(arena, "parseRetryAfter", 3)).len);
}

test "ranked search marks the index incomplete when the build budget is spent and finishes on the next call" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&fixture_files, .{ .deadline_ms = -1 });
    try std.testing.expectEqual(@as(usize, 5), index.stats.pending);
    try std.testing.expect(index.stats.incomplete());
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try index.stats.writeNotes(&out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "index incomplete: 0 of 5 files indexed") != null);

    try index.refresh(&fixture_files, .{});
    try std.testing.expectEqual(@as(usize, 0), index.stats.pending);
    try std.testing.expectEqual(@as(usize, 5), index.stats.indexed);
}

test "ranked search stops adding files at the posting cap and says so" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    index.posting_cap = 12;
    try index.refresh(&fixture_files, .{});
    try std.testing.expect(index.posting_total <= 12);
    try std.testing.expect(index.stats.over_cap > 0);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try index.stats.writeNotes(&out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "12-posting memory cap") != null);
}

test "ranked search skips binary files and files over one megabyte" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.file("image.bin", "needle\x00needle");
    const large = try alloc.alloc(u8, max_file_bytes + 1);
    defer alloc.free(large);
    @memset(large, 'n');
    try tree.file("large.txt", large);
    try tree.file("small.txt", "needle in a haystack\n");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&.{ "image.bin", "large.txt", "small.txt", "missing.txt" }, .{});
    try std.testing.expectEqual(@as(usize, 3), index.stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), index.stats.indexed);
    const hits = try index.search(arena_state.allocator(), "needle", 10);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("small.txt", hits[0].path);
}

test "ranked search index lists the files that mention a name and the files that import a file" {
    const alloc = std.testing.allocator;
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);
    try tree.file("web/app.js", "import { connect } from './client.js';\nconnect('x');\n");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = try Index.init(alloc, tree.root, false);
    defer index.deinit();
    try index.refresh(&.{ "docs/notes.md", "src/net/clock.zig", "src/net/retry.zig", "web/app.js", "web/client.js", "web/config.js" }, .{});

    const mentioning = try index.filesMentioning(arena, "loadConfig");
    try std.testing.expectEqual(@as(usize, 2), mentioning.len);
    try std.testing.expectEqualStrings("web/client.js", mentioning[0]);
    try std.testing.expectEqualStrings("web/config.js", mentioning[1]);

    const direct = try index.importers(arena, &.{"web/config.js"}, 1, 10);
    try std.testing.expectEqual(@as(usize, 1), direct.files.len);
    try std.testing.expectEqualStrings("web/client.js", direct.files[0].path);

    const deep = try index.importers(arena, &.{"web/config.js"}, 3, 10);
    try std.testing.expectEqual(@as(usize, 2), deep.files.len);
    try std.testing.expectEqualStrings("web/app.js", deep.files[1].path);
    try std.testing.expectEqual(@as(usize, 2), deep.files[1].depth);
    try std.testing.expect(!deep.truncated);

    const bounded = try index.importers(arena, &.{"web/config.js"}, 3, 1);
    try std.testing.expectEqual(@as(usize, 1), bounded.files.len);
    try std.testing.expect(bounded.truncated);

    const zig_importers = try index.importers(arena, &.{"src/net/clock.zig"}, 2, 10);
    try std.testing.expectEqual(@as(usize, 1), zig_importers.files.len);
    try std.testing.expectEqualStrings("src/net/retry.zig", zig_importers.files[0].path);
}

test "ranked search reuses the cached index for a workspace and keeps a bounded number of them" {
    const alloc = std.testing.allocator;
    defer dropCachedIndexes();
    var tree = try TestTree.init();
    defer tree.deinit();
    try writeFixture(&tree);

    const first = try prepare(alloc, alloc, .{ .workspace_root = tree.root, .absolute_root = tree.root });
    const first_index = first.index;
    try std.testing.expectEqual(@as(usize, 5), first.index.stats.indexed);
    first.release();

    const second = try prepare(alloc, alloc, .{ .workspace_root = tree.root, .absolute_root = tree.root, .budget_ms = 0 });
    try std.testing.expectEqual(first_index, second.index);
    try std.testing.expectEqual(@as(usize, 5), second.index.stats.indexed);
    try std.testing.expectEqual(@as(usize, 0), second.index.stats.pending);
    second.release();

    for ([_][]const u8{ "docs", "src", "web", "src/net" }) |sub| {
        const sub_root = try std.Io.Dir.path.join(alloc, &.{ tree.root, sub });
        defer alloc.free(sub_root);
        const lease = try prepare(alloc, alloc, .{ .workspace_root = tree.root, .absolute_root = sub_root });
        lease.release();
    }
    var live: usize = 0;
    for (cached_indexes) |entry| live += @intFromBool(entry != null);
    try std.testing.expectEqual(max_cached_indexes, live);
}
