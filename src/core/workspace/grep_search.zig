const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const glob_pattern = @import("glob_pattern.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const regex = @import("../shared/regex.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_files = @import("tool_files.zig");

const Allocator = std.mem.Allocator;

pub const output_cap: usize = 200;

pub const collection_cap: usize = 2000;

const chunk_bytes: usize = 64 * 1024;
const max_multiline_bytes: usize = 16 * 1024 * 1024;

pub const default_scan_budget_ms: u64 = 10_000;
const long_line_excerpt_lead_bytes: usize = 4 * 1024;
const ignored_probe_extra_candidates: usize = 20_000;

pub const MatchSite = struct {
    match_start: usize = 0,
    line_offset: usize = 0,
};

pub const Match = struct {
    absolute_path: []const u8,
    line_number: usize,
    line: []const u8,
    match_start: usize = 0,
    line_offset: usize = 0,
};

pub const TruncatedReason = enum {
    collection_cap,
    scan_budget,
};

pub const Result = struct {
    matches: []const Match,
    truncated_reason: ?TruncatedReason = null,
    candidate_count: usize = 0,
    candidate_cap: usize = tool_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    candidate_cap_reached: bool = false,
    skipped_overlong: usize = 0,
};

pub const Query = struct {
    pattern: []const u8,
    case_insensitive: bool = false,
    multiline: bool = false,
    scan_budget_ms: u64 = default_scan_budget_ms,

    fn regexOptions(self: Query) regex.Options {
        return .{ .case_insensitive = self.case_insensitive, .dot_matches_newline = self.multiline };
    }
};

pub const CountedFile = struct {
    absolute_path: []const u8,
    occurrences: usize,
};

pub const CountResult = struct {
    occurrences: usize = 0,
    matching_files: usize = 0,
    files: []const CountedFile = &.{},
    candidate_count: usize = 0,
    candidate_cap: usize = tool_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    candidate_cap_reached: bool = false,
    skipped_overlong: usize = 0,
    scan_budget_reached: bool = false,
};

pub const IgnoredCount = struct {
    files: usize = 0,
    lower_bound: bool = false,
};

pub fn countIgnoredCandidates(
    scratch: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
) !IgnoredCount {
    var work_state = std.heap.ArenaAllocator.init(scratch);
    defer work_state.deinit();
    const work = work_state.allocator();
    const searched = try listCandidates(scratch, work, workspace_root, absolute_root, ignored_names, .{});
    const searched_count = (try selectCandidates(work, searched.files, include)).len;
    const everything = try listCandidates(scratch, work, workspace_root, absolute_root, &.{}, .{
        .candidate_cap = searched.files.len +| ignored_probe_extra_candidates,
        .include_ignored = true,
    });
    const everything_count = (try selectCandidates(work, everything.files, include)).len;
    return .{
        .files = everything_count -| searched_count,
        .lower_bound = everything.cap_reached,
    };
}

pub fn collectDirectoryMatches(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    query: Query,
    include: ?glob_pattern.Pattern,
) !Result {
    return collectDirectoryMatchesWithIgnored(scratch, arena, workspace_root, absolute_root, query, tool_files.default_skipped_names, include, false);
}

pub fn collectDirectoryMatchesWithIgnored(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    query: Query,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    include_ignored: bool,
) !Result {
    return collectDirectoryMatchesWithOptions(scratch, arena, workspace_root, absolute_root, query, ignored_names, include, .{ .include_ignored = include_ignored });
}

pub fn countDirectoryMatchesWithIgnored(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    query: Query,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    include_ignored: bool,
) !CountResult {
    return countDirectoryMatchesWithOptions(scratch, arena, workspace_root, absolute_root, query, ignored_names, include, .{ .include_ignored = include_ignored });
}

fn collectDirectoryMatchesWithOptions(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    query: Query,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    list_options: tool_files.Options,
) !Result {
    const listing = try listCandidates(scratch, arena, workspace_root, absolute_root, ignored_names, list_options);
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);
    const truncated_reason = try scanCandidateList(scratch, arena, workspace_root, absolute_root, listing.files, query, include, &matches);
    return finishMatches(arena, &matches, truncated_reason, .fromListing(listing));
}

fn countDirectoryMatchesWithOptions(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    query: Query,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    list_options: tool_files.Options,
) !CountResult {
    const listing = try listCandidates(scratch, arena, workspace_root, absolute_root, ignored_names, list_options);
    var count_result: CountResult = .{ .candidate_cap = listing.candidate_cap };
    try countCandidateList(scratch, arena, workspace_root, absolute_root, listing.files, query, include, &count_result);
    return finishCount(count_result, .fromListing(listing));
}

fn listCandidates(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    ignored_names: []const []const u8,
    list_options: tool_files.Options,
) !tool_files.Listing {
    var options = list_options;
    options.skipped_names = ignored_names;
    options.include_hidden_in_repository = true;
    return tool_files.list(scratch, arena, workspace_root, absolute_root, options);
}

pub fn collectRegularFileRoot(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_path: []const u8,
    query: Query,
    include: ?glob_pattern.Pattern,
) !Result {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);

    if (!try fileRootIncluded(arena, workspace_root, absolute_path, include)) {
        return finishMatches(arena, &matches, null, .{
            .cap = tool_files.default_candidate_cap,
        });
    }

    const truncated_reason = try scanFile(arena, absolute_path, query, &matches);

    return finishMatches(arena, &matches, truncated_reason, .{
        .count = 1,
        .cap = tool_files.default_candidate_cap,
    });
}

pub fn countRegularFileRoot(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_path: []const u8,
    query: Query,
    include: ?glob_pattern.Pattern,
) !CountResult {
    if (!try fileRootIncluded(arena, workspace_root, absolute_path, include)) {
        return finishCount(.{}, .{ .cap = tool_files.default_candidate_cap });
    }

    const file_count = try countFile(arena, absolute_path, query);
    const counted_files: []const CountedFile = if (file_count.occurrences > 0)
        try arena.dupe(CountedFile, &.{.{ .absolute_path = absolute_path, .occurrences = file_count.occurrences }})
    else
        &.{};
    return finishCount(.{
        .occurrences = file_count.occurrences,
        .matching_files = if (file_count.occurrences > 0) 1 else 0,
        .files = counted_files,
    }, .{
        .count = 1,
        .cap = tool_files.default_candidate_cap,
    });
}

fn fileRootIncluded(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8, include: ?glob_pattern.Pattern) Allocator.Error!bool {
    const include_pattern = include orelse return true;
    if (!include_pattern.has_path_separator) return include_pattern.matchesBasename(std.Io.Dir.path.basename(absolute_path));
    return include_pattern.matchesPath(try pathing.workspaceRelativePath(arena, workspace_root, absolute_path));
}

const CandidateStats = struct {
    count: usize = 0,
    cap: usize = tool_files.default_candidate_cap,
    incomplete: bool = false,
    cap_reached: bool = false,
    skipped_overlong: usize = 0,

    fn fromListing(listing: tool_files.Listing) CandidateStats {
        return .{
            .count = listing.files.len,
            .cap = listing.candidate_cap,
            .incomplete = listing.incomplete,
            .cap_reached = listing.cap_reached,
            .skipped_overlong = listing.skipped_overlong,
        };
    }
};

fn finishMatches(arena: Allocator, matches: *std.ArrayList(Match), truncated_reason: ?TruncatedReason, stats: CandidateStats) !Result {
    return .{
        .matches = try matches.toOwnedSlice(arena),
        .truncated_reason = truncated_reason,
        .candidate_count = stats.count,
        .candidate_cap = stats.cap,
        .candidate_incomplete = stats.incomplete,
        .candidate_cap_reached = stats.cap_reached,
        .skipped_overlong = stats.skipped_overlong,
    };
}

fn finishCount(result: CountResult, stats: CandidateStats) CountResult {
    var out = result;
    out.candidate_count = stats.count;
    out.candidate_cap = stats.cap;
    out.candidate_incomplete = stats.incomplete;
    out.candidate_cap_reached = stats.cap_reached;
    out.skipped_overlong += stats.skipped_overlong;
    return out;
}

const CandidateFile = struct {
    display_path: []const u8,
    read_path: []const u8,
};

fn candidateKind(absolute_path: []const u8) !std.Io.File.Kind {
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_path, .{ .follow_symlinks = false });
    return stat.kind;
}

fn resolveCandidateFile(
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidate: []const u8,
    absolute_match_buf: []u8,
) !?CandidateFile {
    const absolute_match = joinAbsolutePathScratch(absolute_match_buf, provider_root, candidate) catch |err| {
        debug_trace.logf("core", "grep_files scan skipped root={s} path={s} err={s}", .{ provider_root, candidate, @errorName(err) });
        return null;
    };
    const entry_kind = candidateKind(absolute_match) catch |err| {
        debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
        return null;
    };
    if (entry_kind != .file and entry_kind != .sym_link) return null;

    const read_path = resolveDirectoryEntryTarget(arena, workspace_root, absolute_match, entry_kind) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
        return null;
    } orelse return null;

    return .{
        .display_path = absolute_match,
        .read_path = read_path,
    };
}

const batch_files: usize = 16;
const parallel_min_files: usize = 64;
const max_scan_workers: usize = 8;

const ScanMode = enum { matches, count };

const FileOutcome = struct {
    matches: []const Match = &.{},
    occurrences: usize = 0,
    path: []const u8 = &.{},
};

const ParallelScan = struct {
    workspace_root: []const u8,
    provider_root: []const u8,
    files: []const []const u8,
    query: Query,
    mode: ScanMode,
    outcomes: []FileOutcome,
    worker_arenas: [max_scan_workers]std.heap.ArenaAllocator,
    deadline_ms: i64,
    budget_reached: std.atomic.Value(bool) = .init(false),
    next_batch: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    done_matches: usize = 0,
    out_of_memory_from: ?usize = null,

    fn deinit(self: *ParallelScan) void {
        for (&self.worker_arenas) |*worker_arena| worker_arena.deinit();
    }

    fn run(self: *ParallelScan, worker: usize) void {
        const work = self.worker_arenas[worker].allocator();
        while (!self.stop.load(.acquire)) {
            if (self.next_batch.load(.monotonic) * batch_files >= self.files.len) return;
            if (io_mod.milliTimestamp() >= self.deadline_ms) {
                self.budget_reached.store(true, .release);
                self.stop.store(true, .release);
                return;
            }
            const batch = self.next_batch.fetchAdd(1, .monotonic);
            const first = batch * batch_files;
            if (first >= self.files.len) return;
            const last = @min(first + batch_files, self.files.len);
            for (first..last) |index| {
                _ = self.scanOne(work, index) catch {
                    self.mutex.lockUncancelable(io_mod.getIo());
                    self.out_of_memory_from = @min(self.out_of_memory_from orelse first, first);
                    self.mutex.unlock(io_mod.getIo());
                    self.stop.store(true, .release);
                    return;
                };
            }
            self.finishBatch(first, last);
        }
    }

    fn scanOne(self: *ParallelScan, work: Allocator, index: usize) Allocator.Error!void {
        var absolute_match_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const candidate_file = try resolveCandidateFile(work, self.workspace_root, self.provider_root, self.files[index], absolute_match_buf[0..]) orelse return;
        switch (self.mode) {
            .matches => {
                var local: std.ArrayList(Match) = .empty;
                _ = scanFileAt(work, candidate_file.display_path, candidate_file.read_path, self.query, &local) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
                    return;
                };
                self.outcomes[index] = .{ .matches = local.items };
            },
            .count => {
                const file_count = countFileAt(work, candidate_file.display_path, candidate_file.read_path, self.query) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
                    return;
                };
                self.outcomes[index] = .{ .occurrences = file_count.occurrences, .path = try work.dupe(u8, candidate_file.display_path) };
            },
        }
    }

    fn finishBatch(self: *ParallelScan, first: usize, last: usize) void {
        var batch_matches: usize = 0;
        for (self.outcomes[first..last]) |outcome| batch_matches += outcome.matches.len;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.done_matches += batch_matches;
        if (self.mode == .matches and self.done_matches >= collection_cap) self.stop.store(true, .release);
    }
};

fn workerCount(files: usize) usize {
    if (builtin.single_threaded or files < parallel_min_files) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(max_scan_workers, cpus), std.math.divCeil(usize, files, batch_files) catch 1));
}

fn runParallelScan(scan: *ParallelScan) void {
    const helpers = workerCount(scan.files.len) - 1;
    var threads: [max_scan_workers]std.Thread = undefined;
    var started: usize = 0;
    if (!builtin.single_threaded) {
        while (started < helpers) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, ParallelScan.run, .{ scan, started + 1 }) catch break;
        }
    }
    scan.run(0);
    for (threads[0..started]) |thread| thread.join();
}

fn selectCandidates(work: Allocator, candidates: []const []const u8, include: ?glob_pattern.Pattern) ![]const []const u8 {
    const include_pattern = include orelse return candidates;
    var selected: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        if (include_pattern.matchesPath(candidate)) try selected.append(work, candidate);
    }
    return selected.toOwnedSlice(work);
}

fn initParallelScan(
    work: Allocator,
    scratch: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    files: []const []const u8,
    query: Query,
    mode: ScanMode,
) !ParallelScan {
    const outcomes = try work.alloc(FileOutcome, files.len);
    @memset(outcomes, .{});
    return .{
        .worker_arenas = @splat(std.heap.ArenaAllocator.init(scratch)),
        .workspace_root = workspace_root,
        .provider_root = provider_root,
        .files = files,
        .query = query,
        .mode = mode,
        .outcomes = outcomes,
        .deadline_ms = io_mod.milliTimestamp() +| budgetMilliseconds(query.scan_budget_ms),
    };
}

fn budgetMilliseconds(budget_ms: u64) i64 {
    return std.math.cast(i64, budget_ms) orelse std.math.maxInt(i64);
}

fn scanCandidateList(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    query: Query,
    include: ?glob_pattern.Pattern,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    var work_state = std.heap.ArenaAllocator.init(scratch);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try selectCandidates(work, candidates, include);
    var scan = try initParallelScan(work, scratch, workspace_root, provider_root, files, query, .matches);
    defer scan.deinit();
    runParallelScan(&scan);
    return mergeMatches(arena, &scan, matches);
}

fn mergeMatches(arena: Allocator, scan: *const ParallelScan, matches: *std.ArrayList(Match)) Allocator.Error!?TruncatedReason {
    for (scan.outcomes, 0..) |outcome, index| {
        if (scan.out_of_memory_from) |from| if (index >= from) return error.OutOfMemory;
        var retained_path: ?[]const u8 = null;
        for (outcome.matches) |match| {
            if (matches.items.len >= collection_cap) return .collection_cap;
            try appendMatch(arena, matches, &retained_path, match.absolute_path, match.line_number, match.line, .{
                .match_start = match.match_start,
                .line_offset = match.line_offset,
            });
            if (matches.items.len >= collection_cap) return .collection_cap;
        }
    }
    return if (scan.budget_reached.load(.acquire)) .scan_budget else null;
}

fn countCandidateList(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    query: Query,
    include: ?glob_pattern.Pattern,
    count_result: *CountResult,
) !void {
    var work_state = std.heap.ArenaAllocator.init(scratch);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try selectCandidates(work, candidates, include);
    var scan = try initParallelScan(work, scratch, workspace_root, provider_root, files, query, .count);
    defer scan.deinit();
    runParallelScan(&scan);

    if (scan.out_of_memory_from != null) return error.OutOfMemory;
    count_result.scan_budget_reached = scan.budget_reached.load(.acquire);
    var counted: std.ArrayList(CountedFile) = .empty;
    for (scan.outcomes) |outcome| {
        if (outcome.occurrences == 0) continue;
        count_result.matching_files += 1;
        count_result.occurrences += outcome.occurrences;
        try counted.append(arena, .{ .absolute_path = try arena.dupe(u8, outcome.path), .occurrences = outcome.occurrences });
    }
    count_result.files = try counted.toOwnedSlice(arena);
}

const FileCount = struct {
    occurrences: usize = 0,
};

fn joinAbsolutePathScratch(buffer: []u8, absolute_root: []const u8, entry_path: []const u8) ![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    return std.Io.Dir.path.join(fba.allocator(), &.{ absolute_root, entry_path }) catch |err| switch (err) {
        error.OutOfMemory => error.NameTooLong,
    };
}

fn resolveDirectoryEntryTarget(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8, entry_kind: std.Io.File.Kind) !?[]const u8 {
    const resolved = try io_mod.realpathAlloc(arena, absolute_path);
    if (entry_kind == .sym_link and !pathing.pathInside(workspace_root, resolved)) {
        debug_trace.logf("core", "grep_files skipped external symlink target path={s} target={s}", .{ absolute_path, resolved });
        return null;
    }
    return resolved;
}

fn scanFile(
    arena: Allocator,
    absolute_path: []const u8,
    query: Query,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    return scanFileAt(arena, absolute_path, absolute_path, query, matches);
}

fn countFile(
    arena: Allocator,
    absolute_path: []const u8,
    query: Query,
) !FileCount {
    return countFileAt(arena, absolute_path, absolute_path, query);
}

fn countFileAt(
    scratch: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    query: Query,
) !FileCount {
    var counter: struct {
        occurrences: usize = 0,

        pub fn line(self: *@This(), number: usize, text: []const u8, occurrences: usize, site: MatchSite) Allocator.Error!bool {
            _ = number;
            _ = text;
            _ = site;
            self.occurrences += occurrences;
            return false;
        }
    } = .{};
    return switch (try scanLines(scratch, display_path, read_path, query, &counter)) {
        .done, .stopped => .{ .occurrences = counter.occurrences },
        .not_text => .{},
    };
}

fn scanFileAt(
    arena: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    query: Query,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    var collector: struct {
        arena: Allocator,
        matches: *std.ArrayList(Match),
        display_path: []const u8,
        retained_path: ?[]const u8 = null,

        pub fn line(self: *@This(), number: usize, text: []const u8, occurrences: usize, site: MatchSite) Allocator.Error!bool {
            _ = occurrences;
            try appendMatch(self.arena, self.matches, &self.retained_path, self.display_path, number, text, site);
            return self.matches.items.len >= collection_cap;
        }
    } = .{ .arena = arena, .matches = matches, .display_path = display_path };
    const first = matches.items.len;
    return switch (try scanLines(arena, display_path, read_path, query, &collector)) {
        .done => null,
        .stopped => .collection_cap,
        .not_text => {
            matches.shrinkRetainingCapacity(first);
            return null;
        },
    };
}

const ScanEnd = enum { done, stopped, not_text };

fn compileMatcher(scratch: Allocator, query: Query) !regex.Matcher {
    const program = try regex.compile(scratch, query.pattern, query.regexOptions());
    return regex.Matcher.init(scratch, program);
}

fn countOccurrences(matcher: *regex.Matcher, text: []const u8) usize {
    var count: usize = 0;
    var from: usize = 0;
    while (from <= text.len) {
        const span = matcher.find(text, from) orelse break;
        count += 1;
        from = if (span.end > span.start) span.end else span.end + 1;
    }
    return count;
}

fn firstMatchStart(matcher: *regex.Matcher, text: []const u8) usize {
    const span = matcher.find(text, 0) orelse return 0;
    return span.start;
}

fn scanLines(
    scratch: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    query: Query,
    sink: anytype,
) !ScanEnd {
    if (query.multiline) return scanWholeFile(scratch, display_path, read_path, query, sink);
    var matcher = try compileMatcher(scratch, query);
    var file = try io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), read_path, .follow);
    defer file.close(io_mod.getIo());

    var read_buf: [chunk_bytes]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &read_buf);
    const reader = &file_reader.interface;
    var long: LongLine = .{};

    var number: usize = 1;
    while (true) {
        const line: []const u8, const last = if (reader.peekDelimiterInclusive('\n')) |with_newline|
            .{ with_newline[0 .. with_newline.len - 1], false }
        else |err| switch (err) {
            error.EndOfStream => .{ reader.buffered(), true },
            error.StreamTooLong => {
                const buffered = reader.buffered();
                const piece = buffered[0 .. buffered.len - incompleteUtf8Tail(buffered)];
                if (!isLineText(display_path, piece)) return .not_text;
                try long.add(scratch, piece, &matcher);
                reader.toss(piece.len);
                continue;
            },
            error.ReadFailed => return file_reader.err.?,
        };
        if (!isLineText(display_path, line)) return .not_text;
        const is_long = long.len != 0;
        if (is_long) try long.add(scratch, line, &matcher);
        const occurrences = if (is_long) long.total(&matcher) else countOccurrences(&matcher, line);
        if (occurrences > 0) {
            const excerpt: LongLine.Excerpt = if (is_long)
                long.excerpt(&matcher)
            else
                .{ .text = line, .site = .{ .match_start = firstMatchStart(&matcher, line) } };
            if (try sink.line(number, excerpt.text, occurrences, excerpt.site)) return .stopped;
        }
        if (last) return .done;
        long.reset();
        reader.toss(line.len + 1);
        number += 1;
    }
}

fn scanWholeFile(
    scratch: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    query: Query,
    sink: anytype,
) !ScanEnd {
    var matcher = try compileMatcher(scratch, query);
    var file = try io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), read_path, .follow);
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(scratch, &file, max_multiline_bytes);
    if (!isLineText(display_path, content)) return .not_text;

    var spans: std.ArrayList(regex.Span) = .empty;
    var from: usize = 0;
    while (from <= content.len) {
        const span = matcher.find(content, from) orelse break;
        try spans.append(scratch, span);
        from = if (span.end > span.start) span.end else span.end + 1;
    }

    var line_start: usize = 0;
    var number: usize = 1;
    var first_span: usize = 0;
    while (true) {
        const line_end = std.mem.findScalarPos(u8, content, line_start, '\n') orelse content.len;
        while (first_span < spans.items.len and spans.items[first_span].end < line_start) first_span += 1;
        var covered = false;
        var starting: usize = 0;
        var first_start_in_line: ?usize = null;
        var index = first_span;
        while (index < spans.items.len and spans.items[index].start <= line_end) : (index += 1) {
            const span = spans.items[index];
            if (span.start >= line_start) {
                starting += 1;
                if (first_start_in_line == null) first_start_in_line = span.start - line_start;
            }
            if (span.end > line_start or span.start >= line_start) covered = true;
        }
        if (covered and try sink.line(number, content[line_start..line_end], starting, .{ .match_start = first_start_in_line orelse 0 })) return .stopped;
        if (line_end >= content.len) return .done;
        line_start = line_end + 1;
        number += 1;
    }
}

const LongLine = struct {
    len: usize = 0,
    occurrences: usize = 0,
    whole: std.ArrayList(u8) = .empty,
    overflowed: bool = false,
    head: [chunk_bytes + 1]u8 = undefined,
    head_len: usize = 0,

    fn reset(self: *LongLine) void {
        self.len = 0;
        self.occurrences = 0;
        self.whole.clearRetainingCapacity();
        self.overflowed = false;
        self.head_len = 0;
    }

    const Excerpt = struct {
        text: []const u8,
        site: MatchSite = .{},
    };

    fn kept(self: *const LongLine) []const u8 {
        return self.head[0..self.head_len];
    }

    fn excerpt(self: *const LongLine, matcher: *regex.Matcher) Excerpt {
        const head = self.kept();
        if (self.overflowed) return .{ .text = head, .site = .{ .match_start = firstMatchStart(matcher, head) } };
        const whole = self.whole.items;
        const span = matcher.find(whole, 0) orelse return .{ .text = head };
        if (span.start < head.len) return .{ .text = head, .site = .{ .match_start = span.start } };
        const start = utf8BoundaryAtOrAfter(whole, span.start -| long_line_excerpt_lead_bytes, span.start);
        const end = utf8BoundaryAtOrBefore(whole, @min(whole.len, start + chunk_bytes), @min(whole.len, span.end));
        return .{
            .text = whole[start..end],
            .site = .{ .match_start = span.start - start, .line_offset = start },
        };
    }

    fn add(self: *LongLine, scratch: Allocator, piece: []const u8, matcher: *regex.Matcher) Allocator.Error!void {
        const take = @min(piece.len, self.head.len - self.head_len);
        @memcpy(self.head[self.head_len..][0..take], piece[0..take]);
        self.head_len += take;
        self.len += piece.len;
        if (!self.overflowed and self.whole.items.len + piece.len > max_multiline_bytes) {
            self.occurrences += countOccurrences(matcher, self.whole.items);
            self.whole.clearRetainingCapacity();
            self.overflowed = true;
        }
        if (self.overflowed) {
            self.occurrences += countOccurrences(matcher, piece);
        } else {
            try self.whole.appendSlice(scratch, piece);
        }
    }

    fn total(self: *const LongLine, matcher: *regex.Matcher) usize {
        if (self.overflowed) return self.occurrences;
        return countOccurrences(matcher, self.whole.items);
    }
};

const max_incomplete_utf8_tail: usize = 3;

fn incompleteUtf8Tail(bytes: []const u8) usize {
    var back: usize = 1;
    while (back <= @min(max_incomplete_utf8_tail, bytes.len)) : (back += 1) {
        const byte = bytes[bytes.len - back];
        if (byte & 0b1100_0000 == 0b1000_0000) continue;
        const needed = std.unicode.utf8ByteSequenceLength(byte) catch return 0;
        return if (needed > back) back else 0;
    }
    return 0;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

pub fn utf8BoundaryAtOrAfter(bytes: []const u8, index: usize, limit: usize) usize {
    var at = index;
    while (at < limit and at < bytes.len and isUtf8Continuation(bytes[at])) at += 1;
    return at;
}

pub fn utf8BoundaryAtOrBefore(bytes: []const u8, index: usize, limit: usize) usize {
    var at = index;
    while (at > limit and at < bytes.len and isUtf8Continuation(bytes[at])) at -= 1;
    return at;
}

fn isLineText(display_path: []const u8, line: []const u8) bool {
    if (text_utils.isModelSafeText(line)) return true;
    debug_trace.logf("core", "grep_files skipped non-text file path={s} reason={s}", .{ display_path, modelUnsafeReason(line) });
    return false;
}

fn appendMatch(
    arena: Allocator,
    matches: *std.ArrayList(Match),
    retained_path: *?[]const u8,
    absolute_path: []const u8,
    line_number: usize,
    line: []const u8,
    site: MatchSite,
) !void {
    try matches.ensureUnusedCapacity(arena, 1);
    const path = retained_path.* orelse path: {
        const owned_path = try arena.dupe(u8, absolute_path);
        retained_path.* = owned_path;
        break :path owned_path;
    };
    const owned_line = try arena.dupe(u8, line);
    matches.appendAssumeCapacity(.{
        .absolute_path = path,
        .line_number = line_number,
        .line = owned_line,
        .match_start = site.match_start,
        .line_offset = site.line_offset,
    });
}

fn modelUnsafeReason(content: []const u8) []const u8 {
    if (std.mem.findScalar(u8, content, 0) != null) return "contains_nul";
    if (!std.unicode.utf8ValidateSlice(content)) return "invalid_utf8";
    return "not_model_safe";
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn createBrokenSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn createSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn contentWithPrefix(alloc: Allocator, len: usize, prefix: []const u8) ![]u8 {
    const content = try alloc.alloc(u8, len);
    @memset(content, 'x');
    const prefix_len = @min(prefix.len, content.len);
    @memcpy(content[0..prefix_len], prefix[0..prefix_len]);
    return content;
}

fn readTrace(alloc: Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(4096));
}

test "grep search preserves explicitly requested ignored directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const ignored = try writeTempFile(alloc, &tmp, "node_modules/pkg/ignored.txt", "needle ignored\n");
    defer alloc.free(ignored);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, try io_mod.dirRealpathAlloc(arena_state.allocator(), tmp.dir, "node_modules/pkg"), .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "node_modules/pkg/ignored.txt"));
    try std.testing.expectEqualStrings("needle ignored", result.matches[0].line);
}

test "grep search preserves explicitly requested ignored file roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const ignored = try writeTempFile(alloc, &tmp, "node_modules/pkg/ignored.txt", "needle ignored\n");
    defer alloc.free(ignored);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, ignored, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "node_modules/pkg/ignored.txt"));
    try std.testing.expectEqualStrings("needle ignored", result.matches[0].line);
}

test "grep search does not ignore workspace because ignored name is outside workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(alloc, &tmp, "build/workspace/src/file.txt", "needle kept\n");
    defer alloc.free(path);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "build/workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/file.txt"));
}

test "grep search falls back to Zig scanner outside git repositories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "src/main.zig", "needle fallback\n");
    defer alloc.free(file_path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/main.zig"));
    try std.testing.expectEqualStrings("needle fallback", result.matches[0].line);
}

test "grep search scans untracked files after git grep tracked backend" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "no match\n");
    defer alloc.free(tracked);
    try runGitForTest(alloc, workspace, &.{ "add", "tracked.txt" });
    const untracked = try writeTempFile(alloc, &tmp, "untracked.txt", "needle untracked\n");
    defer alloc.free(untracked);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "untracked.txt"));
    try std.testing.expectEqualStrings("needle untracked", result.matches[0].line);
}

test "grep search git grep backend skips files with unsafe bytes outside matched line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const unsafe = try writeTempFile(alloc, &tmp, "unsafe.txt", "needle safe\ninvalid \xff bytes\n");
    defer alloc.free(unsafe);
    try runGitForTest(alloc, workspace, &.{ "add", "unsafe.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
}

test "grep search logs skipped non-model-safe files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const binary = try writeTempFile(alloc, &tmp, "binary.txt", "needle\x00binary\n");
    defer alloc.free(binary);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, binary, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped non-text file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "binary.txt") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reason=contains_nul") != null);
}

test "grep search logs skipped per-file scan errors during directory traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const good = try writeTempFile(alloc, &tmp, "good.txt", "needle good\n");
    defer alloc.free(good);
    try createBrokenSymlinkOrSkip(&tmp, "missing-target.txt", "broken.txt");
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var pattern = try glob_pattern.Pattern.compile(alloc, "*.txt");
    defer pattern.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, pattern);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files scan skipped path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "broken.txt") != null);
}

test "grep search directory traversal skips external symlink targets with trace" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();

    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const internal_target = try writeTempFile(alloc, &workspace_tmp, "target/internal.txt", "needle internal\n");
    defer alloc.free(internal_target);
    const external_target = try writeTempFile(alloc, &external_tmp, "outside.txt", "needle external\n");
    defer alloc.free(external_target);
    try workspace_tmp.dir.createDirPath(io_mod.getIo(), "links");
    try createSymlinkOrSkip(&workspace_tmp, "../target/internal.txt", "links/internal.txt");
    try createSymlinkOrSkip(&workspace_tmp, external_target, "links/external.txt");

    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const links_root = try io_mod.dirRealpathAlloc(arena_state.allocator(), workspace_tmp.dir, "links");
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, links_root, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "links/internal.txt"));
    try std.testing.expectEqualStrings("needle internal", result.matches[0].line);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped external symlink target path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "links/external.txt") != null);
    try std.testing.expect(std.mem.find(u8, trace, external_target) != null);
}

test "grep search skips a symlink to a FIFO instead of waiting for a writer" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const real = try writeTempFile(alloc, &workspace_tmp, "docs/real.txt", "needle real\n");
    defer alloc.free(real);
    const fifo = try std.Io.Dir.path.joinZ(alloc, &.{ workspace, "pipe" });
    defer alloc.free(fifo);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try createSymlinkOrSkip(&workspace_tmp, "../pipe", "docs/trap.txt");

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "docs/real.txt"));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "grep search scans a file root of any size" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    for (0..3000) |_| try content.appendSlice(alloc, text_utils.repeat("x", 99) ++ "\n");
    try content.appendSlice(alloc, "needle late\n");
    const large = try writeTempFile(alloc, &tmp, "large.txt", content.items);
    defer alloc.free(large);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, large, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqual(@as(usize, 3001), result.matches[0].line_number);
    try std.testing.expectEqualStrings("needle late", result.matches[0].line);

    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, large, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 1), counted.occurrences);
}

test "grep search searches large files during directory traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const good = try writeTempFile(alloc, &tmp, "good.txt", "needle good\n");
    defer alloc.free(good);
    const content = try contentWithPrefix(alloc, 300 * 1024, "needle first\n");
    defer alloc.free(content);
    const large = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(large);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
}

test "grep search finds a match split across the chunks of a long line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const content = try alloc.alloc(u8, 3 * chunk_bytes + 1);
    defer alloc.free(content);
    @memset(content, 'x');
    @memcpy(content[chunk_bytes - 3 ..][0..6], "needle");
    content[content.len - 1] = '\n';
    const long = try writeTempFile(alloc, &tmp, "long.txt", content);
    defer alloc.free(long);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    for ([_]struct { pattern: []const u8, case_insensitive: bool }{
        .{ .pattern = "needle", .case_insensitive = false },
        .{ .pattern = "NEEDLE", .case_insensitive = true },
    }) |case| {
        const result = try collectRegularFileRoot(arena_state.allocator(), workspace, long, .{ .pattern = case.pattern, .case_insensitive = case.case_insensitive }, null);
        try std.testing.expectEqual(@as(usize, 1), result.matches.len);
        try std.testing.expectEqual(@as(usize, 1), result.matches[0].line_number);

        try std.testing.expectEqual(chunk_bytes + 1, result.matches[0].line.len);
    }
    const missing = try collectRegularFileRoot(arena_state.allocator(), workspace, long, .{ .pattern = "needles" }, null);
    try std.testing.expectEqual(@as(usize, 0), missing.matches.len);
}

test "grep search keeps a UTF-8 character cut by a chunk edge as text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.append(alloc, 'a');
    for (0..chunk_bytes) |_| try content.appendSlice(alloc, "\u{e9}");
    try content.appendSlice(alloc, "\nneedle after\n");
    const wide = try writeTempFile(alloc, &tmp, "wide.txt", content.items);
    defer alloc.free(wide);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, wide, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqual(@as(usize, 2), result.matches[0].line_number);
}

test "grep search skips a file whose NUL byte comes after a match" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try contentWithPrefix(alloc, 2 * chunk_bytes, "needle early\n");
    defer alloc.free(content);
    content[content.len - 2] = 0;
    const binary = try writeTempFile(alloc, &tmp, "binary.dat", content);
    defer alloc.free(binary);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, binary, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, binary, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 0), counted.occurrences);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped non-text file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reason=contains_nul") != null);
}

test "grep search include matches a file root by its workspace path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file = try writeTempFile(alloc, &tmp, "src/main.zig", "needle\n");
    defer alloc.free(file);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { include: []const u8, matches: usize }{
        .{ .include = "src/*.zig", .matches = 1 },
        .{ .include = "src/main.zig", .matches = 1 },
        .{ .include = "main.zig", .matches = 1 },
        .{ .include = "lib/*.zig", .matches = 0 },
        .{ .include = "*.ts", .matches = 0 },
    }) |case| {
        var include = try glob_pattern.Pattern.compile(arena, case.include);
        defer include.deinit(arena);
        const result = try collectRegularFileRoot(arena, workspace, file, .{ .pattern = "needle" }, include);
        try std.testing.expectEqual(case.matches, result.matches.len);
        const counted = try countRegularFileRoot(arena, workspace, file, .{ .pattern = "needle" }, include);
        try std.testing.expectEqual(case.matches, counted.occurrences);
    }
}

test "grep search returns a window around a match far into a long line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const needle_at = 3 * chunk_bytes + 17;
    const content = try alloc.alloc(u8, 5 * chunk_bytes);
    defer alloc.free(content);
    @memset(content, 'x');
    @memcpy(content[needle_at..][0..6], "needle");
    content[content.len - 1] = '\n';
    const long = try writeTempFile(alloc, &tmp, "long.txt", content);
    defer alloc.free(long);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, long, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    const match = result.matches[0];
    try std.testing.expectEqual(needle_at - long_line_excerpt_lead_bytes, match.line_offset);
    try std.testing.expectEqual(long_line_excerpt_lead_bytes, match.match_start);
    try std.testing.expectEqual(chunk_bytes, match.line.len);
    try std.testing.expectEqualStrings("needle", match.line[match.match_start..][0..6]);
}

test "grep search records where the first match starts in each line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "sites.txt", "needle first\nthen a needle and a needle\nalpha\nomega needle\n");
    defer alloc.free(path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const per_line = try collectRegularFileRoot(arena_state.allocator(), workspace, path, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 3), per_line.matches.len);
    try std.testing.expectEqual(@as(usize, 0), per_line.matches[0].match_start);
    try std.testing.expectEqual(@as(usize, 7), per_line.matches[1].match_start);
    try std.testing.expectEqual(@as(usize, 6), per_line.matches[2].match_start);
    try std.testing.expectEqual(@as(usize, 0), per_line.matches[2].line_offset);

    const spanning = try collectRegularFileRoot(arena_state.allocator(), workspace, path, .{ .pattern = "alpha\\nomega needle", .multiline = true }, null);
    try std.testing.expectEqual(@as(usize, 2), spanning.matches.len);
    try std.testing.expectEqual(@as(usize, 0), spanning.matches[0].match_start);
    try std.testing.expectEqual(@as(usize, 0), spanning.matches[1].match_start);
}

test "grep search stops at the scan budget and marks the result incomplete" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.txt", "needle one\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "b.txt", "needle two\n"));

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stopped = try collectDirectoryMatches(alloc, arena, workspace, workspace, .{ .pattern = "needle", .scan_budget_ms = 0 }, null);
    try std.testing.expectEqual(@as(usize, 0), stopped.matches.len);
    try std.testing.expectEqual(@as(?TruncatedReason, .scan_budget), stopped.truncated_reason);

    const counted = try countDirectoryMatchesWithIgnored(alloc, arena, workspace, workspace, .{ .pattern = "needle", .scan_budget_ms = 0 }, tool_files.default_skipped_names, null, false);
    try std.testing.expectEqual(@as(usize, 0), counted.occurrences);
    try std.testing.expect(counted.scan_budget_reached);

    const complete = try collectDirectoryMatches(alloc, arena, workspace, workspace, .{ .pattern = "needle" }, null);
    try std.testing.expectEqual(@as(usize, 2), complete.matches.len);
    try std.testing.expect(complete.truncated_reason == null);

    const complete_count = try countDirectoryMatchesWithIgnored(alloc, arena, workspace, workspace, .{ .pattern = "needle" }, tool_files.default_skipped_names, null, false);
    try std.testing.expectEqual(@as(usize, 2), complete_count.occurrences);
    try std.testing.expect(!complete_count.scan_budget_reached);

    const unbounded = try collectDirectoryMatches(alloc, arena, workspace, workspace, .{ .pattern = "needle", .scan_budget_ms = std.math.maxInt(u64) }, null);
    try std.testing.expectEqual(@as(usize, 2), unbounded.matches.len);
    try std.testing.expect(unbounded.truncated_reason == null);
}

test "grep search counts the ignored files a default search leaves out" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "plain\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/index.zig", "needle\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/readme.md", "needle\n"));

    const all = try countIgnoredCandidates(alloc, workspace, workspace, tool_files.default_skipped_names, null);
    try std.testing.expectEqual(@as(usize, 2), all.files);
    try std.testing.expect(!all.lower_bound);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const only_zig = try glob_pattern.Pattern.compile(arena_state.allocator(), "*.zig");
    const narrowed = try countIgnoredCandidates(alloc, workspace, workspace, tool_files.default_skipped_names, only_zig);
    try std.testing.expectEqual(@as(usize, 1), narrowed.files);

    const nothing_skipped = try countIgnoredCandidates(alloc, workspace, workspace, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), nothing_skipped.files);
}

test "grep search UTF-8 boundary helpers never split a character" {
    const text = "a\u{e9}b";
    try std.testing.expectEqual(@as(usize, 3), utf8BoundaryAtOrAfter(text, 2, text.len));
    try std.testing.expectEqual(@as(usize, 1), utf8BoundaryAtOrAfter(text, 1, text.len));
    try std.testing.expectEqual(@as(usize, 2), utf8BoundaryAtOrAfter(text, 2, 2));
    try std.testing.expectEqual(@as(usize, 1), utf8BoundaryAtOrBefore(text, 2, 0));
    try std.testing.expectEqual(@as(usize, 3), utf8BoundaryAtOrBefore(text, 3, 0));
    try std.testing.expectEqual(text.len, utf8BoundaryAtOrBefore(text, text.len, 0));
}

test "grep search retained allocations scale with matches not scanned bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const nonmatching_content = try contentWithPrefix(alloc, 12 * 1024, "not here\n");
    defer alloc.free(nonmatching_content);

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "large/file-{d}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, nonmatching_content);
        alloc.free(path);
    }
    const matching = try writeTempFile(alloc, &tmp, "large/match.txt", "needle kept\n");
    defer alloc.free(matching);

    var retained_buf: [8 * 1024]u8 = undefined;
    var retained_fba = std.heap.FixedBufferAllocator.init(&retained_buf);
    const result = try collectDirectoryMatches(std.testing.allocator, retained_fba.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "large/match.txt"));
    try std.testing.expectEqualStrings("needle kept", result.matches[0].line);
}

test "grep search finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var i: usize = 0;
    while (i < 2050) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, "not here\n");
        alloc.free(path);
    }
    const late = try writeTempFile(alloc, &tmp, "zzzz/match.txt", "needle late\n");
    defer alloc.free(late);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "zzzz/match.txt"));
}

test "grep_files path narrowing applies before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.txt", "needle outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/core/target.txt", "needle target\n");
    defer alloc.free(target);
    const narrowed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src/core");
    defer alloc.free(narrowed_root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatchesWithOptions(
        std.testing.allocator,
        arena_state.allocator(),
        workspace,
        narrowed_root,
        .{ .pattern = "needle" },
        tool_files.default_skipped_names,
        null,
        .{ .candidate_cap = 1 },
    );

    try std.testing.expectEqual(@as(usize, 1), result.candidate_count);
    try std.testing.expect(!result.candidate_incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/core/target.txt"));
    try std.testing.expectEqualStrings("needle target", result.matches[0].line);
}

test "grep search collection cap saturation reports metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    var i: usize = 0;
    while (i < collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const path = try writeTempFile(alloc, &tmp, "many.txt", content.written());
    defer alloc.free(path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, path, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(collection_cap, result.matches.len);
    try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
}

test "grep search collection cap takes precedence at traversal boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "file-{d:0>4}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, "not here\n");
        alloc.free(path);
    }

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    i = 0;
    while (i < collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const match_path = try writeTempFile(alloc, &tmp, "zzzz/many.txt", content.written());
    defer alloc.free(match_path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);

    try std.testing.expectEqual(collection_cap, result.matches.len);
    try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
}

test "grep search does not import tool dispatch layer" {
    const alloc = std.testing.allocator;
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), "src/core/workspace/grep_search.zig", .{});
    defer file.close(io_mod.getIo());
    const source = try io_mod.readFileToEnd(alloc, &file, 128 * 1024);
    defer alloc.free(source);

    const forbidden = "tool_" ++ "dispatch.zig";
    try std.testing.expect(std.mem.find(u8, source, forbidden) == null);
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

test "grep search parallel scan matches single-threaded order and cap truncation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const content = "needle one\nother\nneedle two\n";
    for (0..1500) |index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{index});
        alloc.free(try writeTempFile(alloc, &tmp, name, content));
    }

    for (0..5) |_| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, null);
        try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
        try std.testing.expectEqual(collection_cap, result.matches.len);
        for (result.matches, 0..) |match, position| {
            var want_buf: [64]u8 = undefined;
            const want = try std.mem.print(&want_buf, "many/file-{d:0>4}.txt", .{position / 2});
            try std.testing.expect(std.mem.endsWith(u8, match.absolute_path, want));
            try std.testing.expectEqual(2 * (position % 2) + 1, match.line_number);
        }

        const counted = try countDirectoryMatchesWithIgnored(std.testing.allocator, arena_state.allocator(), workspace, workspace, .{ .pattern = "needle" }, tool_files.default_skipped_names, null, false);
        try std.testing.expectEqual(@as(usize, 3000), counted.occurrences);
        try std.testing.expectEqual(@as(usize, 1500), counted.matching_files);
    }
}

test "parallel grep stops once finished batches hold the cap, even with an earlier batch still running" {
    var work_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try work.alloc([]const u8, batch_files * 4);
    for (files) |*file| file.* = "f";
    var scan = try initParallelScan(work, std.testing.allocator, "/w", "/w", files, .{ .pattern = "x" }, .matches);
    defer scan.deinit();
    const many = try work.alloc(Match, collection_cap);
    for (many) |*match| match.* = .{ .absolute_path = "/w/f", .line_number = 1, .line = "x" };

    scan.outcomes[batch_files] = .{ .matches = many };
    scan.finishBatch(batch_files, batch_files * 2);
    try std.testing.expect(scan.stop.load(.acquire));

    var short = try initParallelScan(work, std.testing.allocator, "/w", "/w", files, .{ .pattern = "x" }, .matches);
    defer short.deinit();
    short.outcomes[batch_files] = .{ .matches = many[0 .. collection_cap - 1] };
    short.finishBatch(batch_files, batch_files * 2);
    try std.testing.expect(!short.stop.load(.acquire));
}

test "grep fails for running out of memory only before the cut" {
    var work_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try work.alloc([]const u8, batch_files * 3);
    for (files) |*file| file.* = "f";
    const many = try work.alloc(Match, collection_cap);
    for (many) |*match| match.* = .{ .absolute_path = "/w/f", .line_number = 1, .line = "x" };

    var past = try initParallelScan(work, std.testing.allocator, "/w", "/w", files, .{ .pattern = "x" }, .matches);
    defer past.deinit();
    past.outcomes[0] = .{ .matches = many };
    past.out_of_memory_from = batch_files * 2;
    var kept: std.ArrayList(Match) = .empty;
    try std.testing.expectEqual(@as(?TruncatedReason, .collection_cap), try mergeMatches(work, &past, &kept));
    try std.testing.expectEqual(collection_cap, kept.items.len);

    var before = try initParallelScan(work, std.testing.allocator, "/w", "/w", files, .{ .pattern = "x" }, .matches);
    defer before.deinit();
    before.outcomes[0] = .{ .matches = many[0..10] };
    before.out_of_memory_from = batch_files;
    var partial: std.ArrayList(Match) = .empty;
    try std.testing.expectError(error.OutOfMemory, mergeMatches(work, &before, &partial));
}

test "grep search counts multiline occurrences and lists the file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "block.txt", "alpha\nomega\nalpha\nomega\n");
    defer alloc.free(path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, path, .{ .pattern = "alpha\\nomega", .multiline = true }, null);
    try std.testing.expectEqual(@as(usize, 2), counted.occurrences);
    try std.testing.expectEqual(@as(usize, 1), counted.files.len);
    try std.testing.expectEqualStrings(path, counted.files[0].absolute_path);
}

test "grep search counts regex occurrences per line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "digits.txt", "a1 b22 c333\nnone\n");
    defer alloc.free(path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, path, .{ .pattern = "[0-9]+" }, null);
    try std.testing.expectEqual(@as(usize, 3), counted.occurrences);
    try std.testing.expectEqual(@as(usize, 1), counted.matching_files);
}
