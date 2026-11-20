const std = @import("std");
const build_options = @import("build_options");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const regex = @import("../../core/shared/regex.zig");
const grep_search = @import("../../core/workspace/grep_search.zig");
const tool_files = @import("../../core/workspace/tool_files.zig");
const io_mod = @import("../../core/shared/io.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const env_redaction = @import("../../core/workspace/env_redaction.zig");
const code_search = @import("code_search.zig");

const Allocator = std.mem.Allocator;

const context_lines_cap: usize = 5;
const context_file_byte_cap: usize = 200 * 1024;

const default_head_limit: usize = 250;

const accepted_fields = [_][]const u8{
    "pattern",
    "path",
    "glob",
    "include",
    "type",
    "output_mode",
    "literal",
    "word",
    "regex",
    "-i",
    "case_insensitive",
    "-n",
    "-A",
    "-B",
    "-C",
    "head_limit",
    "offset",
    "multiline",
    "include_ignored",
    "mode",
    "context_lines",
    "k",
    "closure",
    "scope",
};

const regex_metacharacters = ".^$*+?()[]{}|\\";
const word_prefix = "\\b(?:";
const word_suffix = ")\\b";
const excerpt_visible_margin_bytes: usize = 64;

const regex_fallback_note = "... no literal match for the pattern; matched as a regular expression\n";
const literal_fallback_note = "... the pattern is not a valid regular expression; searched as literal text\n";
const excerpt_note = "... long lines are shown as a window around the match\n";

const SearchNote = enum {
    none,
    regex_fallback,
    literal_fallback,
};

const OutputMode = enum {
    matches,
    files_with_matches,
    count,
};

const OutputModeName = enum {
    content,
    matches,
    files_with_matches,
    count_matches,
    count,
};

const FileType = enum {
    c,
    cpp,
    go,
    java,
    js,
    json,
    md,
    py,
    rust,
    ts,
    zig,
};

pub const Input = struct {
    pattern: []u8,
    path: []u8,
    include: ?[]u8,
    case_insensitive: bool,
    mode: OutputMode = .files_with_matches,
    head_limit: usize,
    offset: usize,
    before_context: usize = 0,
    after_context: usize = 0,
    show_line_numbers: bool = true,
    file_type: ?FileType = null,
    include_ignored: bool = false,
    multiline: bool = false,
    search_pattern: ?[]u8 = null,
    regex_fallback_pattern: ?[]u8 = null,
    searched_invalid_regex_as_literal: bool = false,
    scan_budget_ms: u64 = grep_search.default_scan_budget_ms,
    code: ?code_search.Request = null,

    pub fn query(self: *const Input) grep_search.Query {
        return self.queryFor(self.search_pattern orelse self.pattern);
    }

    fn queryFor(self: *const Input, search_pattern: []const u8) grep_search.Query {
        return .{
            .pattern = search_pattern,
            .case_insensitive = self.case_insensitive,
            .multiline = self.multiline,
            .scan_budget_ms = self.scan_budget_ms,
        };
    }

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        if (self.include) |include| alloc.free(include);
        if (self.search_pattern) |search_pattern| alloc.free(search_pattern);
        if (self.regex_fallback_pattern) |fallback| alloc.free(fallback);
        self.* = .{
            .pattern = &.{},
            .path = &.{},
            .include = null,
            .case_insensitive = false,
            .mode = .files_with_matches,
            .head_limit = default_head_limit,
            .offset = 0,
        };
    }
};

fn fileTypeSuffixes(file_type: FileType) []const []const u8 {
    return switch (file_type) {
        .c => &.{ ".c", ".h" },
        .cpp => &.{ ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx" },
        .go => &.{".go"},
        .java => &.{".java"},
        .js => &.{ ".js", ".jsx", ".mjs", ".cjs" },
        .json => &.{".json"},
        .md => &.{ ".md", ".markdown" },
        .py => &.{ ".py", ".pyi" },
        .rust => &.{".rs"},
        .ts => &.{ ".ts", ".tsx", ".mts", ".cts" },
        .zig => &.{".zig"},
    };
}

fn outputModeFromName(name: OutputModeName) OutputMode {
    return switch (name) {
        .content, .matches => .matches,
        .files_with_matches => .files_with_matches,
        .count_matches, .count => .count,
    };
}

fn hasRegexMetacharacter(pattern: []const u8) bool {
    return std.mem.findAny(u8, pattern, regex_metacharacters) != null;
}

fn escapedLiteralPattern(alloc: Allocator, pattern: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, pattern.len);
    for (pattern) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte < 0x80) try out.append(alloc, '\\');
        try out.append(alloc, byte);
    }
    return out.toOwnedSlice(alloc);
}

fn wholeWordPattern(alloc: Allocator, pattern: []u8) Allocator.Error![]u8 {
    defer alloc.free(pattern);
    return std.mem.concat(alloc, u8, &.{ word_prefix, pattern, word_suffix });
}

fn compilesAsRegex(alloc: Allocator, pattern: []const u8, options: regex.Options) Allocator.Error!bool {
    var validation_arena = std.heap.ArenaAllocator.init(alloc);
    defer validation_arena.deinit();
    _ = regex.compile(validation_arena.allocator(), pattern, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern, error.TooComplex => return false,
    };
    return true;
}

const SearchPlan = struct {
    search_pattern: []u8,
    regex_fallback_pattern: ?[]u8 = null,
    searched_invalid_regex_as_literal: bool = false,

    fn deinit(self: SearchPlan, alloc: Allocator) void {
        alloc.free(self.search_pattern);
        if (self.regex_fallback_pattern) |fallback| alloc.free(fallback);
    }
};

const SearchPlanRequest = struct {
    literal: ?bool,
    regex: ?bool,
    word: bool,
    multiline: bool,
    options: regex.Options,

    fn wantsRegex(self: SearchPlanRequest) bool {
        if (self.regex) |enabled| return enabled;
        if (self.literal) |enabled| return !enabled;
        return self.multiline;
    }

    fn allowsRegexFallback(self: SearchPlanRequest) bool {
        return self.literal == null and self.regex == null and !self.word;
    }
};

fn planSearch(alloc: Allocator, pattern: []const u8, request: SearchPlanRequest) Allocator.Error!SearchPlan {
    const valid_regex = try compilesAsRegex(alloc, pattern, request.options);
    if (request.wantsRegex() and valid_regex) {
        const copy = try alloc.dupe(u8, pattern);
        return .{ .search_pattern = if (request.word) try wholeWordPattern(alloc, copy) else copy };
    }
    const escaped = try escapedLiteralPattern(alloc, pattern);
    const search_pattern = if (request.word) try wholeWordPattern(alloc, escaped) else escaped;
    errdefer alloc.free(search_pattern);
    if (request.wantsRegex()) return .{ .search_pattern = search_pattern, .searched_invalid_regex_as_literal = true };
    const retry_as_regex = request.allowsRegexFallback() and valid_regex and hasRegexMetacharacter(pattern);
    return .{
        .search_pattern = search_pattern,
        .regex_fallback_pattern = if (retry_as_regex) try alloc.dupe(u8, pattern) else null,
    };
}

const OptionalBool = union(enum) {
    absent,
    value: bool,
    invalid,

    fn is(self: OptionalBool, expected: bool) bool {
        return self == .value and self.value == expected;
    }

    fn orNull(self: OptionalBool) ?bool {
        return if (self == .value) self.value else null;
    }
};

fn optionalBoolArg(object: std.json.ObjectMap, key: []const u8) OptionalBool {
    const value = object.get(key) orelse return .absent;
    return switch (value) {
        .null => .absent,
        .bool => |enabled| .{ .value = enabled },
        else => .invalid,
    };
}

fn boolArg(object: std.json.ObjectMap, key: []const u8, default: bool) ?bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .null => default,
        .bool => |enabled| enabled,
        else => null,
    };
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "grep_files" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    args.rejectUnknown(object, &accepted_fields) catch |err| return .{ .failure = try args.takeFailure(err) };
    const pattern = args.requiredString(object, "pattern") catch |err| return .{ .failure = try args.takeFailure(err) };
    const path_string = args.optionalString(object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };
    const include_string = args.optionalString(object, "include") catch |err| return .{ .failure = try args.takeFailure(err) };
    const glob_string = args.optionalString(object, "glob") catch |err| return .{ .failure = try args.takeFailure(err) };
    const effective_include = include_string orelse glob_string;
    const case_insensitive = (boolArg(object, "case_insensitive", false) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"case_insensitive\" must be a boolean") }) or
        (boolArg(object, "-i", false) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"-i\" must be a boolean") });
    const show_line_numbers = boolArg(object, "-n", true) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"-n\" must be a boolean") };
    const include_ignored = boolArg(object, "include_ignored", false) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"include_ignored\" must be a boolean") };
    const multiline = boolArg(object, "multiline", false) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"multiline\" must be a boolean") };
    const literal = optionalBoolArg(object, "literal");
    if (literal == .invalid) return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"literal\" must be a boolean") };
    const as_regex = optionalBoolArg(object, "regex");
    if (as_regex == .invalid) return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"regex\" must be a boolean") };
    const word = boolArg(object, "word", false) orelse return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"word\" must be a boolean") };
    if (literal.is(true) and as_regex.is(true)) {
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files takes \"literal\" or \"regex\", not both: literal finds the exact text, regex treats the pattern as a regular expression") };
    }

    const code_request: ?code_search.Request = switch (try code_search.decodeRequest(ctx.allocator, object)) {
        .none => null,
        .request => |request| request,
        .failure => |body| return .{ .failure = body },
    };
    const raw_mode = if (code_request != null) null else args.optionalString(object, "mode") catch |err| return .{ .failure = try args.takeFailure(err) };
    const raw_output_mode = args.optionalString(object, "output_mode") catch |err| return .{ .failure = try args.takeFailure(err) };
    const mode: OutputMode = if (raw_output_mode) |raw| blk: {
        const name = std.meta.stringToEnum(OutputModeName, raw) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"output_mode\" must be one of content, files_with_matches, count_matches") };
        };
        break :blk outputModeFromName(name);
    } else if (raw_mode) |raw| blk: {
        break :blk std.meta.stringToEnum(OutputMode, raw) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"mode\" must be one of matches, files_with_matches, count") };
        };
    } else .files_with_matches;

    const raw_type = args.optionalString(object, "type") catch |err| return .{ .failure = try args.takeFailure(err) };
    const file_type: ?FileType = if (raw_type) |raw| blk: {
        break :blk std.meta.stringToEnum(FileType, raw) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"type\" must be one of c, cpp, go, java, js, json, md, py, rust, ts, zig") };
        };
    } else null;

    const head_limit = switch (try parseOptionalInteger(ctx.allocator, object, "head_limit", 0, "non-negative")) {
        .missing => default_head_limit,
        .value => |value| if (value == 0) std.math.maxInt(usize) else value,
        .failure => |body| return .{ .failure = body },
    };
    const offset = switch (try parseOptionalInteger(ctx.allocator, object, "offset", 0, "non-negative")) {
        .missing => 0,
        .value => |value| value,
        .failure => |body| return .{ .failure = body },
    };
    const context_shared = switch (try parseOptionalInteger(ctx.allocator, object, "-C", 0, "non-negative")) {
        .missing => null,
        .value => |value| @min(value, context_lines_cap),
        .failure => |body| return .{ .failure = body },
    };
    const context_legacy = switch (try parseOptionalInteger(ctx.allocator, object, "context_lines", 0, "non-negative")) {
        .missing => null,
        .value => |value| @min(value, context_lines_cap),
        .failure => |body| return .{ .failure = body },
    };
    const context_before = switch (try parseOptionalInteger(ctx.allocator, object, "-B", 0, "non-negative")) {
        .missing => null,
        .value => |value| @min(value, context_lines_cap),
        .failure => |body| return .{ .failure = body },
    };
    const context_after = switch (try parseOptionalInteger(ctx.allocator, object, "-A", 0, "non-negative")) {
        .missing => null,
        .value => |value| @min(value, context_lines_cap),
        .failure => |body| return .{ .failure = body },
    };
    const before_context = context_shared orelse context_legacy orelse context_before orelse 0;
    const after_context = context_shared orelse context_legacy orelse context_after orelse 0;

    const regex_options: regex.Options = .{ .case_insensitive = case_insensitive, .dot_matches_newline = multiline };
    const plan = try planSearch(ctx.allocator, pattern, .{
        .literal = literal.orNull(),
        .regex = as_regex.orNull(),
        .word = word,
        .multiline = multiline,
        .options = regex_options,
    });
    errdefer plan.deinit(ctx.allocator);
    if (!try compilesAsRegex(ctx.allocator, plan.search_pattern, regex_options)) {
        plan.deinit(ctx.allocator);
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"pattern\" is too long or too complex to search") };
    }

    const owned_pattern = try ctx.allocator.dupe(u8, pattern);
    errdefer ctx.allocator.free(owned_pattern);
    const effective_path = if (path_string) |path|
        if (path.len == 0) "." else path
    else
        ".";
    const owned_path = try ctx.allocator.dupe(u8, effective_path);
    errdefer ctx.allocator.free(owned_path);
    const owned_include = if (effective_include) |value| try ctx.allocator.dupe(u8, value) else null;
    errdefer if (owned_include) |include| ctx.allocator.free(include);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .include = owned_include,
        .case_insensitive = case_insensitive,
        .mode = mode,
        .head_limit = head_limit,
        .offset = offset,
        .before_context = before_context,
        .after_context = after_context,
        .show_line_numbers = show_line_numbers,
        .file_type = file_type,
        .include_ignored = include_ignored,
        .multiline = multiline,
        .search_pattern = plan.search_pattern,
        .regex_fallback_pattern = plan.regex_fallback_pattern,
        .searched_invalid_regex_as_literal = plan.searched_invalid_regex_as_literal,
        .code = code_request,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

const OptionalIntegerParse = union(enum) {
    missing,
    value: usize,
    failure: []u8,
};

fn parseOptionalInteger(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    min_value: i64,
    description: []const u8,
) tool_dispatch.DispatchError!OptionalIntegerParse {
    const value = object.get(key) orelse return .missing;
    if (value != .integer or value.integer < min_value) {
        return .{ .failure = try alloc.print("grep_files field \"{s}\" must be a {s} integer", .{ key, description }) };
    }
    return .{ .value = @intCast(value.integer) };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = if (erased.as(Input).code) |request| try code_search.call(ctx, .{
        .request = request,
        .query = erased.as(Input).pattern,
        .path = erased.as(Input).path,
        .include_ignored = erased.as(Input).include_ignored,
        .head_limit = erased.as(Input).head_limit,
        .offset = erased.as(Input).offset,
    }) else try callWithOps(ctx, erased, .{});
    holdForTest();
    return result;
}

fn holdForTest() void {
    if (comptime build_options.libfx) return;
    const release_path = io_mod.getenv("FX_TEST_GREP_RELEASE") orelse return;
    while (true) : (io_mod.sleep(std.time.ns_per_ms)) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), release_path, .{}) catch continue;
        return;
    }
}

const StatRootFn = *const fn ([]const u8) anyerror!std.Io.File.Stat;
const CollectDirectoryFn = *const fn (
    Allocator,
    Allocator,
    []const u8,
    []const u8,
    grep_search.Query,
    []const []const u8,
    ?glob_pattern.Pattern,
    bool,
) anyerror!grep_search.Result;
const CollectFileFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    grep_search.Query,
    ?glob_pattern.Pattern,
) anyerror!grep_search.Result;
const CountDirectoryFn = *const fn (
    Allocator,
    Allocator,
    []const u8,
    []const u8,
    grep_search.Query,
    []const []const u8,
    ?glob_pattern.Pattern,
    bool,
) anyerror!grep_search.CountResult;
const CountFileFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    grep_search.Query,
    ?glob_pattern.Pattern,
) anyerror!grep_search.CountResult;

const CountIgnoredFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    []const []const u8,
    ?glob_pattern.Pattern,
) anyerror!grep_search.IgnoredCount;

const CallOps = struct {
    count_ignored: CountIgnoredFn = grep_search.countIgnoredCandidates,
    stat_root: StatRootFn = statRoot,
    collect_directory: CollectDirectoryFn = grep_search.collectDirectoryMatchesWithIgnored,
    collect_file: CollectFileFn = grep_search.collectRegularFileRoot,
    count_directory: CountDirectoryFn = grep_search.countDirectoryMatchesWithIgnored,
    count_file: CountFileFn = grep_search.countRegularFileRoot,
};

const SearchOutcome = union(enum) {
    matches: grep_search.Result,
    count: grep_search.CountResult,
    failure: []u8,

    fn foundNothing(self: SearchOutcome) bool {
        return switch (self) {
            .matches => |result| result.matches.len == 0,
            .count => |result| result.occurrences == 0,
            .failure => false,
        };
    }

    fn scanBudgetReached(self: SearchOutcome) bool {
        return switch (self) {
            .matches => |result| result.truncated_reason == .scan_budget,
            .count => |result| result.scan_budget_reached,
            .failure => false,
        };
    }
};

fn callWithOps(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, ops: CallOps) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();

    const absolute_root = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "grep_files", input.path, err) };
        }
        return .{ .failure = try ctx.allocator.print("Unable to resolve grep search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };

    var include_pattern: ?glob_pattern.Pattern = null;
    if (input.include) |include| {
        include_pattern = glob_pattern.Pattern.compile(arena, include) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PatternTooLong => return .{ .failure = try ctx.allocator.print("grep_files field \"include\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
        };
    }

    const root_stat = ops.stat_root(absolute_root) catch |err| {
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "grep_files", absolute_root, err) };
        }
        return .{ .failure = try ctx.allocator.print("Unable to stat grep search root: {s} ({s})", .{ absolute_root, @errorName(err) }) };
    };

    var note: SearchNote = if (input.searched_invalid_regex_as_literal) .literal_fallback else .none;
    var outcome = try searchFilteredGrepRoot(ctx, arena, input, input.query(), absolute_root, root_stat, include_pattern, ops);
    if (input.regex_fallback_pattern) |fallback| {
        if (outcome.foundNothing() and !outcome.scanBudgetReached()) {
            const retried = try searchFilteredGrepRoot(ctx, arena, input, input.queryFor(fallback), absolute_root, root_stat, include_pattern, ops);
            switch (retried) {
                .failure => |retry_failure| ctx.allocator.free(retry_failure),
                .matches, .count => if (!retried.foundNothing()) {
                    outcome = retried;
                    note = .regex_fallback;
                },
            }
        }
    }
    const ignored = try countIgnoredAfterMiss(ctx, input, outcome, absolute_root, root_stat, include_pattern, ops);

    const body = switch (outcome) {
        .failure => |failure| return .{ .failure = failure },
        .count => |count_result| try formatCount(ctx.allocator, arena, ctx.workspace_root, input.pattern, count_result, input.head_limit, input.offset),
        .matches => |search_result| switch (input.mode) {
            .matches => try formatMatches(ctx.allocator, arena, ctx.workspace_root, input.pattern, search_result, input.head_limit, input.offset, input.before_context, input.after_context, input.show_line_numbers, ctx.max_read_file_line_len),
            .files_with_matches => try formatFilesWithMatches(ctx.allocator, arena, ctx.workspace_root, input.pattern, search_result, input.head_limit, input.offset),
            .count => unreachable,
        },
    };
    return .{ .success = try appendSearchNotes(ctx.allocator, body, note, ignored) };
}

fn searchFilteredGrepRoot(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: *const Input,
    query: grep_search.Query,
    absolute_root: []const u8,
    root_stat: std.Io.File.Stat,
    include_pattern: ?glob_pattern.Pattern,
    ops: CallOps,
) tool_dispatch.DispatchError!SearchOutcome {
    return switch (try searchGrepRoot(ctx, arena, input, query, absolute_root, root_stat, include_pattern, ops)) {
        .failure => |body| .{ .failure = body },
        .count => |count_result| .{ .count = try filterCountByFileType(arena, count_result, input.file_type) },
        .matches => |search_result| .{ .matches = try filterByFileType(arena, search_result, input.file_type) },
    };
}

fn countIgnoredAfterMiss(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
    outcome: SearchOutcome,
    absolute_root: []const u8,
    root_stat: std.Io.File.Stat,
    include_pattern: ?glob_pattern.Pattern,
    ops: CallOps,
) Allocator.Error!grep_search.IgnoredCount {
    if (input.include_ignored or root_stat.kind != .directory) return .{};
    if (!outcome.foundNothing() or outcome.scanBudgetReached()) return .{};
    return ops.count_ignored(ctx.scratch_allocator, ctx.workspace_root, absolute_root, ctx.ignored_list_entries, include_pattern) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{};
    };
}

fn appendSearchNotes(
    alloc: Allocator,
    body: []u8,
    note: SearchNote,
    ignored: grep_search.IgnoredCount,
) Allocator.Error![]u8 {
    if (note == .none and ignored.files == 0) return body;
    defer alloc.free(body);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeSearchNotes(&out.writer, body, note, ignored) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn writeSearchNotes(
    writer: *std.Io.Writer,
    body: []const u8,
    note: SearchNote,
    ignored: grep_search.IgnoredCount,
) !void {
    try writer.writeAll(body);
    switch (note) {
        .none => {},
        .regex_fallback => try writer.writeAll(regex_fallback_note),
        .literal_fallback => try writer.writeAll(literal_fallback_note),
    }
    if (ignored.files == 0) return;
    try writer.print("... {s}{d} ignored file{s} not searched; pass include_ignored=true to search {s}\n", .{
        if (ignored.lower_bound) "at least " else "",
        ignored.files,
        if (ignored.files == 1) " was" else "s were",
        if (ignored.files == 1) "it" else "them",
    });
}

fn filterCountByFileType(arena: Allocator, result: grep_search.CountResult, file_type: ?FileType) Allocator.Error!grep_search.CountResult {
    const selected = file_type orelse return result;
    const suffixes = fileTypeSuffixes(selected);
    var kept: std.ArrayList(grep_search.CountedFile) = .empty;
    var total: usize = 0;
    for (result.files) |file| {
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, file.absolute_path, suffix)) {
                try kept.append(arena, file);
                total += file.occurrences;
                break;
            }
        }
    }
    var filtered = result;
    filtered.files = try kept.toOwnedSlice(arena);
    filtered.occurrences = total;
    filtered.matching_files = filtered.files.len;
    return filtered;
}

fn filterByFileType(arena: Allocator, result: grep_search.Result, file_type: ?FileType) Allocator.Error!grep_search.Result {
    const selected = file_type orelse return result;
    const suffixes = fileTypeSuffixes(selected);
    var kept: std.ArrayList(grep_search.Match) = .empty;
    for (result.matches) |match| {
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, match.absolute_path, suffix)) {
                try kept.append(arena, match);
                break;
            }
        }
    }
    var filtered = result;
    filtered.matches = try kept.toOwnedSlice(arena);
    return filtered;
}

fn searchGrepRoot(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: *const Input,
    query: grep_search.Query,
    absolute_root: []const u8,
    root_stat: std.Io.File.Stat,
    include_pattern: ?glob_pattern.Pattern,
    ops: CallOps,
) tool_dispatch.DispatchError!SearchOutcome {
    const ignored_names: []const []const u8 = if (input.include_ignored) &.{} else ctx.ignored_list_entries;
    return switch (root_stat.kind) {
        .directory => switch (input.mode) {
            .count => .{ .count = ops.count_directory(ctx.scratch_allocator, arena, ctx.workspace_root, absolute_root, query, ignored_names, include_pattern, input.include_ignored) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "walk grep search root", err);
            } },
            .matches, .files_with_matches => .{ .matches = ops.collect_directory(ctx.scratch_allocator, arena, ctx.workspace_root, absolute_root, query, ignored_names, include_pattern, input.include_ignored) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "walk grep search root", err);
            } },
        },
        .file => switch (input.mode) {
            .count => .{ .count = ops.count_file(arena, ctx.workspace_root, absolute_root, query, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "scan grep file root", err);
            } },
            .matches, .files_with_matches => .{ .matches = ops.collect_file(arena, ctx.workspace_root, absolute_root, query, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "scan grep file root", err);
            } },
        },
        else => .{ .failure = try ctx.allocator.print("Not a regular file or directory: {s}", .{absolute_root}) },
    };
}

fn searchFailure(
    alloc: Allocator,
    absolute_root: []const u8,
    action: []const u8,
    err: anyerror,
) tool_dispatch.DispatchError!SearchOutcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (tool_result_errors.isFilesystemAccessDenied(err)) {
        return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(alloc, "grep_files", absolute_root, err) };
    }
    return .{ .failure = try alloc.print("Unable to {s}: {s} ({s})", .{ action, absolute_root, @errorName(err) }) };
}

fn statRoot(absolute_root: []const u8) anyerror!std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_root, .{});
}

fn formatMatches(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    result: grep_search.Result,
    head_limit: usize,
    offset: usize,
    before_context: usize,
    after_context: usize,
    show_line_numbers: bool,
    max_read_file_line_len: usize,
) tool_dispatch.DispatchError![]u8 {
    const matches = result.matches;
    const start = @min(offset, matches.len);
    const end = pageEnd(start, head_limit, matches.len);
    const emitted = end - start;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var shows_window = false;

    if (matches.len == 0) {
        out.writer.print("[grep] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
    } else if (emitted == 0) {
        out.writer.print("[grep] no matches for {s} at offset {d} ({d} total matches)\n", .{ pattern, offset, matches.len }) catch return error.OutOfMemory;
    } else {
        if (start == 0 and end == matches.len) {
            out.writer.print("[grep] {d} matches for {s}\n", .{ emitted, pattern }) catch return error.OutOfMemory;
        } else {
            out.writer.print("[grep] {d} matches for {s} (showing {d}-{d} of {d})\n", .{ emitted, pattern, start + 1, end, matches.len }) catch return error.OutOfMemory;
        }
        for (matches[start..end]) |match| {
            const display_path = displayPath(arena, workspace_root, match.absolute_path) catch |err| fallback: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break :fallback match.absolute_path;
            };
            const windowed = writeMatchWithContext(arena, &out.writer, match, display_path, before_context, after_context, show_line_numbers, max_read_file_line_len) catch return error.OutOfMemory;
            shows_window = shows_window or windowed;
        }
    }

    if (end < matches.len) {
        out.writer.print("... more matches available; use offset {d} to continue\n", .{end}) catch return error.OutOfMemory;
    }
    if (shows_window) out.writer.writeAll(excerpt_note) catch return error.OutOfMemory;
    try writeGrepResultNotes(&out.writer, result);

    return try out.toOwnedSlice();
}

fn pageEnd(start: usize, limit: usize, total: usize) usize {
    if (limit >= total - start) return total;
    return start + limit;
}

fn writeMatchWithContext(
    arena: Allocator,
    writer: *std.Io.Writer,
    match: grep_search.Match,
    display_path: []const u8,
    before_context: usize,
    after_context: usize,
    show_line_numbers: bool,
    max_read_file_line_len: usize,
) !bool {
    const redacts_values = env_redaction.isSensitiveEnvFile(match.absolute_path);
    const content = if (before_context > 0 or after_context > 0) try readContextContent(arena, match.absolute_path) else null;
    if (content) |text| {
        const first_line = if (match.line_number > before_context) match.line_number - before_context else 1;
        try writeContextRange(arena, writer, display_path, text, first_line, match.line_number, show_line_numbers, max_read_file_line_len, redacts_values);
    }
    const shown: grep_search.Match = if (redacts_values) .{
        .absolute_path = match.absolute_path,
        .line_number = match.line_number,
        .line = try env_redaction.redactEnvAssignmentLine(arena, match.line),
    } else match;
    const windowed = try writeMatchLine(writer, display_path, shown, show_line_numbers, max_read_file_line_len);
    if (content) |text| {
        try writeContextRange(arena, writer, display_path, text, match.line_number + 1, match.line_number + after_context + 1, show_line_numbers, max_read_file_line_len, redacts_values);
    }
    return windowed;
}

fn readContextContent(arena: Allocator, absolute_path: []const u8) !?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const content = io_mod.readFileToEnd(arena, &file, context_file_byte_cap + 1) catch return null;
    if (content.len > context_file_byte_cap) return null;
    if (!text_utils.isModelSafeText(content)) return null;
    return content;
}

fn writeContextRange(
    arena: Allocator,
    writer: *std.Io.Writer,
    display_path: []const u8,
    content: []const u8,
    start_line: usize,
    end_line_exclusive: usize,
    show_line_numbers: bool,
    max_read_file_line_len: usize,
    redacts_values: bool,
) !void {
    var line_number: usize = 1;
    var cursor: usize = 0;
    while (nextRealLine(content, &cursor)) |line| : (line_number += 1) {
        if (line_number < start_line) continue;
        if (line_number >= end_line_exclusive) break;
        if (show_line_numbers) {
            try writer.print("   {s}:{d}- ", .{ display_path, line_number });
        } else {
            try writer.print("   {s}- ", .{display_path});
        }
        try writeClippedLine(writer, if (redacts_values) try env_redaction.redactEnvAssignmentLine(arena, line) else line, max_read_file_line_len);
    }
}

fn nextRealLine(content: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= content.len) return null;

    const start = cursor.*;
    if (std.mem.findScalar(u8, content[start..], '\n')) |newline_offset| {
        const end = start + newline_offset;
        cursor.* = end + 1;
        return content[start..end];
    }

    cursor.* = content.len;
    return content[start..];
}

fn writeMatchLine(
    writer: *std.Io.Writer,
    display_path: []const u8,
    match: grep_search.Match,
    show_line_numbers: bool,
    max_read_file_line_len: usize,
) !bool {
    if (show_line_numbers) {
        try writer.print(" - {s}:{d}: ", .{ display_path, match.line_number });
    } else {
        try writer.print(" - {s}: ", .{display_path});
    }
    const window = matchWindow(match.line, match.match_start, max_read_file_line_len);
    const starts_inside_line = window.start > 0 or match.line_offset > 0;
    if (starts_inside_line) try writer.writeAll("...");
    try writer.writeAll(match.line[window.start..window.end]);
    if (window.end < match.line.len) try writer.writeAll("...");
    try writer.writeByte('\n');
    return starts_inside_line;
}

const LineWindow = struct {
    start: usize,
    end: usize,
};

fn matchWindow(line: []const u8, match_start: usize, max_len: usize) LineWindow {
    if (line.len <= max_len) return .{ .start = 0, .end = line.len };
    const first_match_byte = @min(match_start, line.len);
    if (first_match_byte + @min(excerpt_visible_margin_bytes, max_len / 4) <= max_len) return .{ .start = 0, .end = max_len };
    const lead = max_len / 3;
    const start = grep_search.utf8BoundaryAtOrAfter(line, @min(first_match_byte -| lead, line.len - max_len), first_match_byte);
    const end = grep_search.utf8BoundaryAtOrBefore(line, @min(line.len, start + max_len), start);
    return .{ .start = start, .end = end };
}

fn writeClippedLine(writer: *std.Io.Writer, line: []const u8, max_read_file_line_len: usize) !void {
    const clipped_len = @min(line.len, max_read_file_line_len);
    try writer.writeAll(line[0..clipped_len]);
    if (line.len > max_read_file_line_len) {
        try writer.writeAll("...");
    }
    try writer.writeByte('\n');
}

fn formatFilesWithMatches(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    result: grep_search.Result,
    head_limit: usize,
    offset: usize,
) tool_dispatch.DispatchError![]u8 {
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    for (result.matches) |match| {
        if (seen.contains(match.absolute_path)) continue;
        try seen.put(match.absolute_path, {});
        const display_path = displayPath(arena, workspace_root, match.absolute_path) catch |err| fallback: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :fallback match.absolute_path;
        };
        try files.append(arena, display_path);
    }

    const start = @min(offset, files.items.len);
    const end = pageEnd(start, head_limit, files.items.len);
    const emitted = end - start;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (files.items.len == 0) {
        out.writer.print("[grep] no files with matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
    } else if (emitted == 0) {
        out.writer.print("[grep] no files with matches for {s} at offset {d} ({d} total files)\n", .{ pattern, offset, files.items.len }) catch return error.OutOfMemory;
    } else {
        if (start == 0 and end == files.items.len) {
            out.writer.print("[grep] {d} files with matches for {s}\n", .{ emitted, pattern }) catch return error.OutOfMemory;
        } else {
            out.writer.print("[grep] {d} files with matches for {s} (showing {d}-{d} of {d})\n", .{ emitted, pattern, start + 1, end, files.items.len }) catch return error.OutOfMemory;
        }
        for (files.items[start..end]) |path| {
            out.writer.print(" - {s}\n", .{path}) catch return error.OutOfMemory;
        }
    }
    if (end < files.items.len) {
        out.writer.print("... more files available; use offset {d} to continue\n", .{end}) catch return error.OutOfMemory;
    }
    try writeGrepResultNotes(&out.writer, result);

    return try out.toOwnedSlice();
}

fn writeGrepResultNotes(
    writer: *std.Io.Writer,
    result: grep_search.Result,
) error{OutOfMemory}!void {
    if (result.truncated_reason) |reason| {
        switch (reason) {
            .collection_cap => writer.print("... match collection cap reached at {d} matches before all candidate files were scanned\n", .{grep_search.collection_cap}) catch return error.OutOfMemory,
            .scan_budget => try writeScanBudgetNote(writer),
        }
    }
    try candidateCompleteness(result).writeNotes(writer);
}

fn writeScanBudgetNote(writer: *std.Io.Writer) error{OutOfMemory}!void {
    writer.print("... scan stopped at the {d} s time budget before all candidate files were searched, so results are incomplete; narrow path or include to finish\n", .{grep_search.default_scan_budget_ms / std.time.ms_per_s}) catch return error.OutOfMemory;
}

fn candidateCompleteness(result: anytype) tool_files.Completeness {
    return .{
        .incomplete = result.candidate_incomplete,
        .cap_reached = result.candidate_cap_reached,
        .candidate_cap = result.candidate_cap,
        .skipped_overlong = result.skipped_overlong,
    };
}

fn formatCount(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    result: grep_search.CountResult,
    head_limit: usize,
    offset: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[grep] Found {d} total occurrences across {d} files for {s}\n", .{ result.occurrences, result.matching_files, pattern }) catch return error.OutOfMemory;
    const start = @min(offset, result.files.len);
    const end = @min(result.files.len, start +| head_limit);
    for (result.files[start..end]) |file| {
        const shown = try displayPath(arena, workspace_root, file.absolute_path);
        out.writer.print("{s}:{d}\n", .{ shown, file.occurrences }) catch return error.OutOfMemory;
    }
    if (end < result.files.len) {
        out.writer.print("[grep] more files remain; use offset={d} to see more\n", .{end}) catch return error.OutOfMemory;
    }
    if (result.scan_budget_reached) try writeScanBudgetNote(&out.writer);
    try candidateCompleteness(result).writeNotes(&out.writer);
    return try out.toOwnedSlice();
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    if (workspace_root.len == 0) return absolute_path;
    return pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const grep_files_dispatch_tool = tool_dispatch.Tool{
    .name = "grep_files",
    .description = "Grep files dispatch test fixture.",
    .model_schema = .{
        .name = "grep_files",
        .description = "Grep files dispatch test fixture.",
    },
    .executor_kind = .grep_files,
    .activity_kind = .read,
    .permission_target_kind = .path_optional_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

fn expectDecodeFailure(args_json: []const u8, reason: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(reason, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectDecodeInput(
    args_json: []const u8,
    pattern: []const u8,
    input_path: []const u8,
    include: ?[]const u8,
    case_insensitive: bool,
    head_limit: usize,
    offset: usize,
) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(pattern, input.pattern);
            try std.testing.expectEqualStrings(input_path, input.path);
            if (include) |expected| {
                try std.testing.expect(input.include != null);
                try std.testing.expectEqualStrings(expected, input.include.?);
            } else {
                try std.testing.expect(input.include == null);
            }
            try std.testing.expectEqual(case_insensitive, input.case_insensitive);
            try std.testing.expectEqual(head_limit, input.head_limit);
            try std.testing.expectEqual(offset, input.offset);
        },
    }
}

fn grepArgsJson(
    alloc: Allocator,
    pattern: []const u8,
    maybe_path: ?[]const u8,
    maybe_include: ?[]const u8,
    case_insensitive: ?bool,
    head_limit: ?usize,
    offset: ?usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    try out.writer.writeAll(",\"output_mode\":\"content\"");
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    if (maybe_include) |include| {
        try out.writer.writeAll(",\"include\":");
        try std.json.Stringify.value(include, .{}, &out.writer);
    }
    if (case_insensitive) |value| {
        try out.writer.print(",\"case_insensitive\":{}", .{value});
    }
    if (head_limit) |value| {
        try out.writer.print(",\"head_limit\":{d}", .{value});
    }
    if (offset) |value| {
        try out.writer.print(",\"offset\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGrepFiles(
    alloc: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    maybe_path: ?[]const u8,
    maybe_include: ?[]const u8,
    case_insensitive: ?bool,
    head_limit: ?usize,
    offset: ?usize,
) !tool_dispatch.DispatchResult {
    const args = try grepArgsJson(alloc, pattern, maybe_path, maybe_include, case_insensitive, head_limit, offset);
    defer alloc.free(args);

    return dispatchGrepFilesRaw(alloc, workspace_root, args);
}

fn dispatchGrepFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{grep_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "grep_files",
        .arguments_json = args_json,
    });
}

test "grep_files keeps only its result in the turn's allocator" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), "many");
    for (0..2050) |i| {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = if (i == 1) "needle\n" else "x\n" });
    }
    const args = try grepArgsJson(alloc, "needle", null, null, null, null, null);
    defer alloc.free(args);

    var turn_state = std.heap.ArenaAllocator.init(alloc);
    defer turn_state.deinit();
    const registry = tool_dispatch.Registry{ .tools = &.{grep_files_dispatch_tool} };
    for (0..2) |_| {
        const before = turn_state.queryCapacity();
        const result = try tool_dispatch.dispatchToolCall(.{
            .allocator = turn_state.allocator(),
            .scratch_allocator = alloc,
            .permission_mode = .auto,
            .workspace_root = workspace,
        }, registry, .{ .id = "call_1", .name = "grep_files", .arguments_json = args });
        try std.testing.expectEqual(.success, result.status);
        try std.testing.expect(std.mem.find(u8, result.body, "many/file-0001.txt") != null);

        try std.testing.expect(turn_state.queryCapacity() - before < 64 * 1024);
    }
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

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn matchingLines(alloc: Allocator, count: usize) ![]grep_search.Match {
    const matches = try alloc.alloc(grep_search.Match, count);
    for (matches, 0..) |*match, i| {
        match.* = .{
            .absolute_path = "many.txt",
            .line_number = i + 1,
            .line = "needle",
        };
    }
    return matches;
}

fn grepFilesFailureWithOps(
    alloc: Allocator,
    workspace_root: []const u8,
    path: []const u8,
    include: ?[]const u8,
    ops: CallOps,
) ![]u8 {
    var input = Input{
        .pattern = try alloc.dupe(u8, "needle"),
        .path = try alloc.dupe(u8, path),
        .include = if (include) |value| try alloc.dupe(u8, value) else null,
        .case_insensitive = false,
        .head_limit = default_head_limit,
        .offset = 0,
    };
    defer input.deinit(alloc);

    const result = try callWithOps(.{ .allocator = alloc, .scratch_allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = &input, .deinit_fn = noopInputDeinit }, ops);
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| return body,
        .success => |body| {
            defer alloc.free(body);
            return error.ExpectedFailure;
        },
    }
}

fn fakeStat(kind: std.Io.File.Kind) std.Io.File.Stat {
    return .{
        .inode = 0,
        .nlink = 1,
        .size = 0,
        .permissions = .default_file,
        .kind = kind,
        .atime = null,
        .mtime = .{ .nanoseconds = 0 },
        .ctime = .{ .nanoseconds = 0 },
        .block_size = 1,
    };
}

fn failingStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return error.InjectedStatFailure;
}

fn accessDeniedStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return error.AccessDenied;
}

fn directoryStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.directory);
}

fn fileStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.file);
}

fn namedPipeStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.named_pipe);
}

fn failingCollectDirectory(
    _: Allocator,
    _: Allocator,
    _: []const u8,
    _: []const u8,
    _: grep_search.Query,
    _: []const []const u8,
    _: ?glob_pattern.Pattern,
    _: bool,
) anyerror!grep_search.Result {
    return error.InjectedWalkFailure;
}

fn failingCollectFile(
    _: Allocator,
    _: []const u8,
    _: []const u8,
    _: grep_search.Query,
    _: ?glob_pattern.Pattern,
) anyerror!grep_search.Result {
    return error.InjectedScanFailure;
}

test "grep_files decodes invalid argument shapes as failures" {
    try expectDecodeFailure("{", "grep_files arguments must be valid JSON");
    try expectDecodeFailure("[]", "grep_files arguments must be an object");
    try expectDecodeFailure("{\"path\":\".\"}", "grep_files requires string field \"pattern\"");
    try expectDecodeFailure("{\"pattern\":1}", "grep_files field \"pattern\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"path\":1}", "grep_files field \"path\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"include\":[\"*.zig\"]}", "grep_files field \"include\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"case_insensitive\":\"true\"}", "grep_files field \"case_insensitive\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"mode\":\"files\"}", "grep_files field \"mode\" must be one of matches, files_with_matches, count");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"mode\":2}", "grep_files field \"mode\" must be a string");
}

test "grep_files validate preserves active raw pattern and path values" {
    const alloc = std.testing.allocator;
    var empty = Input{
        .pattern = try alloc.dupe(u8, " \t\n "),
        .path = try alloc.dupe(u8, "   "),
        .include = null,
        .case_insensitive = false,
        .head_limit = default_head_limit,
        .offset = 0,
    };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings(" \t\n ", empty.pattern);
    try std.testing.expectEqualStrings("   ", empty.path);
}

test "grep_files decodes defaults and all fields" {
    try expectDecodeInput("{\"pattern\":\"needle\"}", "needle", ".", null, false, default_head_limit, 0);
    try expectDecodeInput("{\"pattern\":\"needle\",\"path\":\"\"}", "needle", ".", null, false, default_head_limit, 0);
    try expectDecodeInput(
        "{\"pattern\":\"needle\",\"path\":\"src\",\"include\":\"*.zig\",\"case_insensitive\":true,\"head_limit\":5,\"offset\":2}",
        "needle",
        "src",
        "*.zig",
        true,
        5,
        2,
    );
    try expectDecodeInput("{\"pattern\":\"needle\",\"path\":null,\"include\":null,\"case_insensitive\":null,\"mode\":null}", "needle", ".", null, false, default_head_limit, 0);
}

test "grep_files decodes context_lines above cap as bounded" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"needle\",\"context_lines\":99}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqual(context_lines_cap, input.before_context);
            try std.testing.expectEqual(context_lines_cap, input.after_context);
        },
    }
}

test "grep_files Input ownership duplicates and frees under testing allocator" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"needle\",\"path\":\"src\",\"include\":\"*.zig\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            const input = erased.as(Input);
            try std.testing.expectEqualStrings("needle", input.pattern);
            try std.testing.expectEqualStrings("src", input.path);
            try std.testing.expectEqualStrings("*.zig", input.include.?);
            erased.deinit(alloc);
        },
    }
}

test "grep_files reports resolver errors as model-visible failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", "missing.txt", null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "Unable to resolve grep search root: missing.txt ("));
}

test "grep_files reports overlong include patterns before scanning" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);
    const include = try alloc.alloc(u8, glob_pattern.max_pattern_bytes + 1);
    defer alloc.free(include);
    @memset(include, 'a');

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, include, null, null, null);
    defer result.deinit(alloc);

    const expected = try alloc.print("grep_files field \"include\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes});
    defer alloc.free(expected);
    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
}

test "grep_files reports stat failures after root resolution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = failingStatRoot });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to stat grep search root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedStatFailure)"));
}

test "grep_files access denial returns structured recovery" {
    const alloc = std.testing.allocator;
    const root = try alloc.print("/tmp/fx-grep-files-access-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const workspace = try io_mod.realpathAlloc(alloc, root);
    defer alloc.free(workspace);
    const path = try std.Io.Dir.path.join(alloc, &.{ workspace, "file.txt" });
    defer alloc.free(path);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "needle\n");
    }

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = accessDeniedStatRoot });
    defer alloc.free(body);

    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(body));
    try std.testing.expect(std.mem.find(u8, body, "\"tool_name\":\"grep_files\"") != null);
    try std.testing.expect(std.mem.find(u8, body, path) != null);
    try std.testing.expect(std.mem.find(u8, body, "AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, body, "symlink") != null);
}

test "grep_files reports walk failures for directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const body = try grepFilesFailureWithOps(alloc, workspace, ".", null, .{
        .stat_root = directoryStatRoot,
        .collect_directory = failingCollectDirectory,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to walk grep search root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedWalkFailure)"));
}

test "grep_files reports scan failures for regular-file roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{
        .stat_root = fileStatRoot,
        .collect_file = failingCollectFile,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to scan grep file root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedScanFailure)"));
}

test "grep_files single-file non-text root returns empty matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "binary.txt", "needle\x00binary\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.body);
}

test "grep_files single-file oversized root returns empty matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(content);
    @memset(content, 'n');
    const path = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.body);
}

test "grep_files reports non-file non-directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = namedPipeStatRoot });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Not a regular file or directory: "));
}

test "grep_files single-file search returns matching lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "single.txt", "one\nneedle here\n");
    defer alloc.free(file_path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", file_path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - single.txt:2: needle here\n", result.body);
}

test "grep_files single-file include matches the base name or the workspace path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "src/single.zig", "needle\n");
    defer alloc.free(file_path);

    var basename_match = try dispatchGrepFiles(alloc, workspace, "needle", file_path, "*.zig", null, null, null);
    defer basename_match.deinit(alloc);
    try std.testing.expectEqual(.success, basename_match.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - src/single.zig:1: needle\n", basename_match.body);

    var path_pattern_match = try dispatchGrepFiles(alloc, workspace, "needle", file_path, "src/*.zig", null, null, null);
    defer path_pattern_match.deinit(alloc);
    try std.testing.expectEqual(.success, path_pattern_match.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - src/single.zig:1: needle\n", path_pattern_match.body);

    var path_pattern_miss = try dispatchGrepFiles(alloc, workspace, "needle", file_path, "lib/*.zig", null, null, null);
    defer path_pattern_miss.deinit(alloc);
    try std.testing.expectEqual(.success, path_pattern_miss.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", path_pattern_miss.body);
}

test "grep_files walks multiple files without sorting" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const first = try writeTempFile(alloc, &tmp, "src/a.txt", "needle a\n");
    defer alloc.free(first);
    const second = try writeTempFile(alloc, &tmp, "src/nested/b.txt", "needle b\n");
    defer alloc.free(second);
    const miss = try writeTempFile(alloc, &tmp, "src/c.txt", "other\n");
    defer alloc.free(miss);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] 2 matches for needle\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "src/a.txt:1: needle a") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "src/nested/b.txt:1: needle b") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "src/c.txt") == null);
}

test "grep_files finds match beyond former traversal cap" {
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

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "zzzz/match.txt:1: needle late") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "traversal cap") == null);
}

test "grep_files include filters walked files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const kept = try writeTempFile(alloc, &tmp, "src/main.zig", "needle in zig\n");
    defer alloc.free(kept);
    const skipped = try writeTempFile(alloc, &tmp, "src/notes.txt", "needle in text\n");
    defer alloc.free(skipped);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, "*.zig", null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "src/main.zig:1: needle in zig") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "notes.txt") == null);
}

test "grep_files supports ASCII case-insensitive matching" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "case.txt", "Needle Here\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, true, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - case.txt:1: Needle Here\n", result.body);
}

test "grep_files paginates matching line output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "matches.txt", "needle one\nneedle two\nneedle three\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, 1, 1);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle (showing 2-2 of 3)\n" ++
            " - matches.txt:2: needle two\n" ++
            "... more matches available; use offset 2 to continue\n",
        result.body,
    );
}

test "grep_files context_lines includes nearby lines around emitted matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "context.txt", "one\ntwo\nneedle here\nfour\nfive\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"context.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   context.txt:2- two\n" ++
            " - context.txt:3: needle here\n" ++
            "   context.txt:4- four\n",
        result.body,
    );
}

test "grep_files context_lines skips synthetic trailing line after final newline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "trailing.txt", "before\nneedle\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"trailing.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   trailing.txt:1- before\n" ++
            " - trailing.txt:2: needle\n",
        result.body,
    );
}

test "grep_files context_lines skips after-context at EOF without final newline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "no-trailing.txt", "before\nneedle");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"no-trailing.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   no-trailing.txt:1- before\n" ++
            " - no-trailing.txt:2: needle\n",
        result.body,
    );
}

test "grep_files context_lines preserves real blank lines in range" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "blank-context.txt", "before\nneedle\n\nafter\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"blank-context.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   blank-context.txt:1- before\n" ++
            " - blank-context.txt:2: needle\n" ++
            "   blank-context.txt:3- \n",
        result.body,
    );
}

test "grep_files context_lines follows match pagination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "paged.txt", "before one\nneedle one\nafter one\nbefore two\nneedle two\nafter two\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"paged.txt\",\"head_limit\":1,\"offset\":1,\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle (showing 2-2 of 2)\n" ++
            "   paged.txt:4- before two\n" ++
            " - paged.txt:5: needle two\n" ++
            "   paged.txt:6- after two\n",
        result.body,
    );
}

test "grep_files context_lines does not affect files_with_matches or count modes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "modes.txt", "before\nneedle\nafter\n");
    defer alloc.free(path);

    var files_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"modes.txt\",\"mode\":\"files_with_matches\",\"context_lines\":1}");
    defer files_result.deinit(alloc);
    try std.testing.expectEqual(.success, files_result.status);
    try std.testing.expectEqualStrings("[grep] 1 files with matches for needle\n - modes.txt\n", files_result.body);

    var count_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"modes.txt\",\"mode\":\"count\",\"context_lines\":1}");
    defer count_result.deinit(alloc);
    try std.testing.expectEqual(.success, count_result.status);
    try std.testing.expectEqualStrings("[grep] Found 1 total occurrences across 1 files for needle\nmodes.txt:1\n", count_result.body);
}

test "grep_files files_with_matches mode returns unique paginated paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const one = try writeTempFile(alloc, &tmp, "one.txt", "needle first\nneedle second\n");
    defer alloc.free(one);
    const two = try writeTempFile(alloc, &tmp, "two.txt", "needle third\n");
    defer alloc.free(two);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"mode\":\"files_with_matches\",\"head_limit\":10}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] 2 files with matches for needle\n"));
    try std.testing.expect(std.mem.find(u8, result.body, " - one.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.body, " - two.txt\n") != null);
    try std.testing.expectEqual(@as(usize, 2), countEmittedResultLines(result.body));
}

test "grep_files formatter uses active pagination cap" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, 3);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, 2, 0, 0, 0, true, 2000);
    defer alloc.free(body);

    try std.testing.expectEqualStrings(
        "[grep] 2 matches for needle (showing 1-2 of 3)\n" ++
            " - many.txt:1: needle\n" ++
            " - many.txt:2: needle\n" ++
            "... more matches available; use offset 2 to continue\n",
        body,
    );
}

test "grep_files formatter does not report output truncation for exactly active cap" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, tool_dispatch.default_max_list_entries);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, tool_dispatch.default_max_list_entries, 0, 0, 0, true, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.find(u8, body, "more matches available") == null);
}

test "grep_files formatter reports active truncation when cap hides matches" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, tool_dispatch.default_max_list_entries + 1);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, tool_dispatch.default_max_list_entries, 0, 0, 0, true, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle (showing 1-100 of 101)\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.endsWith(u8, body, "... more matches available; use offset 100 to continue\n"));
}

test "grep_files formatter reports collection cap separately from output truncation" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, grep_search.collection_cap);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{
        .matches = matches,
        .truncated_reason = .collection_cap,
    }, tool_dispatch.default_max_list_entries, 0, 0, 0, true, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle (showing 1-100 of 2000)\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.find(u8, body, "... more matches available; use offset 100 to continue\n") != null);
    try std.testing.expect(std.mem.find(u8, body, "match collection cap reached at 2000 matches") != null);
}

test "grep_files count mode reports exact matching lines beyond collection cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    var i: usize = 0;
    while (i < grep_search.collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const path = try writeTempFile(alloc, &tmp, "many.txt", content.written());
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"mode\":\"count\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] Found 2001 total occurrences across 1 files for needle\nmany.txt:2001\n", result.body);
    try std.testing.expectEqual(@as(usize, 0), countEmittedResultLines(result.body));
}

test "grep_files formatter reports candidate cap without output truncation wording" {
    const alloc = std.testing.allocator;

    const body = try formatMatches(alloc, alloc, "", "needle", .{
        .matches = &.{},
        .candidate_incomplete = true,
        .candidate_cap_reached = true,
        .candidate_cap = 2,
    }, tool_dispatch.default_max_list_entries, 0, 0, 0, true, 2000);
    defer alloc.free(body);

    try std.testing.expectEqualStrings("[grep] no matches for needle\n... candidate list may be incomplete; candidate cap 2 reached before all files were discovered\n", body);

    const unreadable = try formatMatches(alloc, alloc, "", "needle", .{
        .matches = &.{},
        .candidate_incomplete = true,
        .candidate_cap = 100000,
    }, tool_dispatch.default_max_list_entries, 0, 0, 0, true, 2000);
    defer alloc.free(unreadable);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n... candidate list may be incomplete; some folders or git files could not be read\n", unreadable);
}

test "grep_files rejects Kimi parameter shapes it cannot honour or misreads" {
    try expectDecodeFailure("{\"pattern\":\"needle\",\"output_mode\":\"lines\"}", "grep_files field \"output_mode\" must be one of content, files_with_matches, count_matches");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"type\":\"cobol\"}", "grep_files field \"type\" must be one of c, cpp, go, java, js, json, md, py, rust, ts, zig");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"literal\":1}", "grep_files field \"literal\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"regex\":\"yes\"}", "grep_files field \"regex\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"word\":1}", "grep_files field \"word\" must be a boolean");
    try expectDecodeFailure(
        "{\"pattern\":\"needle\",\"literal\":true,\"regex\":true}",
        "grep_files takes \"literal\" or \"regex\", not both: literal finds the exact text, regex treats the pattern as a regular expression",
    );
    try expectDecodeFailure("{\"pattern\":\"needle\",\"-i\":\"yes\"}", "grep_files field \"-i\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"-n\":1}", "grep_files field \"-n\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"-A\":-1}", "grep_files field \"-A\" must be a non-negative integer");
    try expectDecodeFailure("{\"pattern\":\"needle\",\"include_ignored\":1}", "grep_files field \"include_ignored\" must be a boolean");
}

test "grep_files maps Kimi output modes, context flags, and line numbers" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        mode: OutputMode,
        before: usize,
        after: usize,
        show_line_numbers: bool,
        head_limit: usize,
    }{
        .{ .json = "{\"pattern\":\"needle\"}", .mode = .files_with_matches, .before = 0, .after = 0, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"content\"}", .mode = .matches, .before = 0, .after = 0, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"count_matches\"}", .mode = .count, .before = 0, .after = 0, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"mode\":\"count\"}", .mode = .count, .before = 0, .after = 0, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"-C\":2}", .mode = .matches, .before = 2, .after = 2, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"-B\":1,\"-A\":3}", .mode = .matches, .before = 1, .after = 3, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"-C\":2,\"-A\":4}", .mode = .matches, .before = 2, .after = 2, .show_line_numbers = true, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"-n\":false}", .mode = .matches, .before = 0, .after = 0, .show_line_numbers = false, .head_limit = 250 },
        .{ .json = "{\"pattern\":\"needle\",\"head_limit\":0}", .mode = .files_with_matches, .before = 0, .after = 0, .show_line_numbers = true, .head_limit = std.math.maxInt(usize) },
    };

    for (cases) |case| {
        const decoded = try decode(.{ .allocator = alloc }, case.json);
        const erased = switch (decoded) {
            .input => |input| input,
            .failure => |reason| {
                defer alloc.free(reason);
                return error.TestExpectedDecodedInput;
            },
        };
        defer erased.deinit(alloc);
        const input = erased.as(Input);
        try std.testing.expectEqual(case.mode, input.mode);
        try std.testing.expectEqual(case.before, input.before_context);
        try std.testing.expectEqual(case.after, input.after_context);
        try std.testing.expectEqual(case.show_line_numbers, input.show_line_numbers);
        try std.testing.expectEqual(case.head_limit, input.head_limit);
    }
}

test "grep_files glob is an alias of include and -i of case_insensitive" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"needle\",\"glob\":\"*.zig\",\"-i\":true}");
    const erased = switch (decoded) {
        .input => |input| input,
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
    defer erased.deinit(alloc);
    const input = erased.as(Input);
    try std.testing.expectEqualStrings("*.zig", input.include.?);
    try std.testing.expect(input.case_insensitive);
}

test "grep_files -n false drops line numbers from content lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "one.txt", "other\nneedle here\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"-n\":false}");
    defer result.deinit(alloc);

    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - one.txt: needle here\n", result.body);
}

test "grep_files type restricts matches to the named file kind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "needle zig\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "b.txt", "needle txt\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"type\":\"zig\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqualStrings("[grep] 1 files with matches for needle\n - a.zig\n", result.body);
}

test "grep_files count_matches reports per-file occurrences restricted by type" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "needle needle\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "b.txt", "needle\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"count_matches\"}");
    defer result.deinit(alloc);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] Found 3 total occurrences across 2 files for needle\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "a.zig:2\n") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "b.txt:1\n") != null);

    var typed = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"count_matches\",\"type\":\"zig\"}");
    defer typed.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] Found 2 total occurrences across 1 files for needle\na.zig:2\n", typed.body);
}

test "grep_files multiline lets the pattern span lines and dot cross newlines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "block.txt", "alpha\nomega\nend\n"));

    var spanning = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"alpha\\\\nomega\",\"multiline\":true,\"output_mode\":\"count_matches\",\"path\":\"block.txt\"}");
    defer spanning.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] Found 1 total occurrences across 1 files for alpha\\nomega\nblock.txt:1\n", spanning.body);

    var dotted = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"alpha.omega\",\"multiline\":true,\"output_mode\":\"count_matches\",\"path\":\"block.txt\"}");
    defer dotted.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, dotted.body, "[grep] Found 1 total occurrences"));

    var per_line = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"alpha.omega\",\"output_mode\":\"count_matches\",\"path\":\"block.txt\"}");
    defer per_line.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, per_line.body, "[grep] Found 0 total occurrences"));
}

test "grep_files pattern is a regular expression" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "digits.txt", "id 42\nid x\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"id \\\\d+\",\"output_mode\":\"count_matches\",\"path\":\"digits.txt\"}");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] Found 1 total occurrences across 1 files for id \\d+\ndigits.txt:1\n" ++ regex_fallback_note, result.body);

    var explicit = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"id \\\\d+\",\"regex\":true,\"output_mode\":\"count_matches\",\"path\":\"digits.txt\"}");
    defer explicit.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] Found 1 total occurrences across 1 files for id \\d+\ndigits.txt:1\n", explicit.body);
}

fn expectSearchPlan(
    args_json: []const u8,
    search_pattern: []const u8,
    regex_fallback_pattern: ?[]const u8,
    searched_invalid_regex_as_literal: bool,
) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(search_pattern, input.search_pattern.?);
            if (regex_fallback_pattern) |expected| {
                try std.testing.expectEqualStrings(expected, input.regex_fallback_pattern.?);
            } else {
                try std.testing.expect(input.regex_fallback_pattern == null);
            }
            try std.testing.expectEqual(searched_invalid_regex_as_literal, input.searched_invalid_regex_as_literal);
        },
    }
}

test "grep_files plans literal, word and regex searches from the flags" {
    try expectSearchPlan("{\"pattern\":\"needle\"}", "needle", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b(c)\"}", "a\\.b\\(c\\)", "a.b(c)", false);
    try expectSearchPlan("{\"pattern\":\"a.b(c)\",\"literal\":true}", "a\\.b\\(c\\)", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b\",\"literal\":false}", "a.b", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b\",\"regex\":true}", "a.b", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b\",\"regex\":false}", "a\\.b", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b\",\"multiline\":true}", "a.b", null, false);
    try expectSearchPlan("{\"pattern\":\"a.b\",\"multiline\":true,\"literal\":true}", "a\\.b", null, false);
    try expectSearchPlan("{\"pattern\":\"get.id\",\"word\":true}", "\\b(?:get\\.id)\\b", null, false);
    try expectSearchPlan("{\"pattern\":\"get|set\",\"word\":true,\"regex\":true}", "\\b(?:get|set)\\b", null, false);
    try expectSearchPlan("{\"pattern\":\"(ab\"}", "\\(ab", null, false);
    try expectSearchPlan("{\"pattern\":\"(ab\",\"regex\":true}", "\\(ab", null, true);
    try expectSearchPlan("{\"pattern\":\"a{2,1}\",\"literal\":false}", "a\\{2\\,1\\}", null, true);
    try expectSearchPlan("{\"pattern\":\"caf\\u00e9 au_lait\"}", "caf\u{e9}\\ au\\_lait", null, false);
}

test "grep_files refuses an unknown argument by name and lists the accepted fields" {
    try expectDecodeFailure(
        "{\"pattern\":\"needle\",\"max_count\":3}",
        "grep_files does not take argument \"max_count\"; accepted fields: pattern, path, glob, include, type, output_mode, literal, word, regex, -i, case_insensitive, -n, -A, -B, -C, head_limit, offset, multiline, include_ignored, mode, context_lines, k, closure, scope",
    );
}

test "grep_files matches regex characters literally by default" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "prices.txt", "price is $5.00 (net)\nprice is $5x00 [net]\n"));

    var literal = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"$5.00 (net)\",\"output_mode\":\"content\",\"path\":\"prices.txt\"}");
    defer literal.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for $5.00 (net)\n - prices.txt:1: price is $5.00 (net)\n", literal.body);

    var insensitive = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"PRICE IS $5.00\",\"-i\":true,\"output_mode\":\"content\",\"path\":\"prices.txt\"}");
    defer insensitive.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for PRICE IS $5.00\n - prices.txt:1: price is $5.00 (net)\n", insensitive.body);
}

test "grep_files retries a literal miss as a regular expression and says which matched" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "ids.txt", "id 42\nid none\n"));

    var fallback = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"id [0-9]+$\",\"output_mode\":\"content\",\"path\":\"ids.txt\"}");
    defer fallback.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for id [0-9]+$\n - ids.txt:1: id 42\n" ++ regex_fallback_note, fallback.body);

    var files = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"id [0-9]+$\",\"path\":\"ids.txt\"}");
    defer files.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 files with matches for id [0-9]+$\n - ids.txt\n" ++ regex_fallback_note, files.body);

    var strict = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"id [0-9]+$\",\"literal\":true,\"output_mode\":\"content\",\"path\":\"ids.txt\"}");
    defer strict.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] no matches for id [0-9]+$\n", strict.body);

    var both_miss = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"zz [0-9]+$\",\"output_mode\":\"content\",\"path\":\"ids.txt\"}");
    defer both_miss.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] no matches for zz [0-9]+$\n", both_miss.body);
}

test "grep_files searches an invalid regular expression as literal text and says so" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "calls.txt", "run(ab\nrun ab\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"(ab\",\"regex\":true,\"output_mode\":\"content\",\"path\":\"calls.txt\"}");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for (ab\n - calls.txt:1: run(ab\n" ++ literal_fallback_note, result.body);
}

test "grep_files word matches whole words only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "words.txt", "get id\ngetter id\nforget id\n"));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"get\",\"word\":true,\"output_mode\":\"content\",\"path\":\"words.txt\"}");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for get\n - words.txt:1: get id\n", result.body);
}

test "grep_files reports ignored files after a miss and names include_ignored" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "plain zig\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/index.zig", "needle dep\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/other.zig", "other dep\n"));

    var missed = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\"}");
    defer missed.deinit(alloc);
    try std.testing.expectEqualStrings(
        "[grep] no files with matches for needle\n... 2 ignored files were not searched; pass include_ignored=true to search them\n",
        missed.body,
    );

    var counted = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"count_matches\",\"include\":\"index.*\"}");
    defer counted.deinit(alloc);
    try std.testing.expectEqualStrings(
        "[grep] Found 0 total occurrences across 0 files for needle\n... 1 ignored file was not searched; pass include_ignored=true to search it\n",
        counted.body,
    );

    var found = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"plain\"}");
    defer found.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 files with matches for plain\n - a.zig\n", found.body);

    var included = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"absent\",\"include_ignored\":true}");
    defer included.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] no files with matches for absent\n", included.body);
}

test "grep_files ignored-file note marks a capped count as a lower bound" {
    const alloc = std.testing.allocator;
    const body = try appendSearchNotes(alloc, try alloc.dupe(u8, "[grep] no matches for x\n"), .none, .{ .files = 20000, .lower_bound = true });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "[grep] no matches for x\n... at least 20000 ignored files were not searched; pass include_ignored=true to search them\n",
        body,
    );
}

fn filled(comptime byte: u8, comptime len: usize) *const [len]u8 {
    const bytes: [len]u8 = comptime @splat(byte);
    return &bytes;
}

test "grep_files shows a long line as a window around the match" {
    const alloc = std.testing.allocator;
    const line = comptime filled('a', 500) ++ "needle" ++ filled('b', 500);
    const matches = [_]grep_search.Match{.{ .absolute_path = "min.js", .line_number = 1, .line = line, .match_start = 500 }};

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = &matches }, 10, 0, 0, 0, true, 90);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        comptime "[grep] 1 matches for needle\n - min.js:1: ..." ++ filled('a', 30) ++ "needle" ++ filled('b', 54) ++ "...\n" ++ excerpt_note,
        body,
    );
}

test "grep_files keeps the start of a long line when the match is near it" {
    const alloc = std.testing.allocator;
    const line = comptime "needle" ++ filled('b', 500);
    const matches = [_]grep_search.Match{.{ .absolute_path = "min.js", .line_number = 1, .line = line }};

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = &matches }, 10, 0, 0, 0, true, 90);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(comptime "[grep] 1 matches for needle\n - min.js:1: needle" ++ filled('b', 84) ++ "...\n", body);
}

test "grep_files match window covers the end of the line and keeps UTF-8 characters whole" {
    const tail = matchWindow(comptime filled('x', 200) ++ "needle", 200, 60);
    try std.testing.expectEqual(@as(usize, 146), tail.start);
    try std.testing.expectEqual(@as(usize, 206), tail.end);

    var accented_buffer: [406]u8 = undefined;
    for (0..100) |index| {
        @memcpy(accented_buffer[index * 2 ..][0..2], "\u{e9}");
        @memcpy(accented_buffer[206 + index * 2 ..][0..2], "\u{e9}");
    }
    @memcpy(accented_buffer[200..206], "needle");
    const accented: []const u8 = &accented_buffer;
    const window = matchWindow(accented, 200, 61);
    try std.testing.expect(std.unicode.utf8ValidateSlice(accented[window.start..window.end]));
    try std.testing.expect(window.start <= 200 and window.end >= 206);

    const short = matchWindow("needle", 0, 60);
    try std.testing.expectEqual(@as(usize, 0), short.start);
    try std.testing.expectEqual(@as(usize, 6), short.end);
}

test "grep_files finds a match far into a minified line and marks the cut start" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try alloc.alloc(u8, 300 * 1024);
    defer alloc.free(content);
    @memset(content, 'x');
    @memcpy(content[200 * 1024 ..][0..6], "needle");
    content[content.len - 1] = '\n';
    alloc.free(try writeTempFile(alloc, &tmp, "bundle.min.js", content));

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"path\":\"bundle.min.js\"}");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] 1 matches for needle\n - bundle.min.js:1: ...x"));
    try std.testing.expect(std.mem.find(u8, result.body, "xneedlex") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.body, "x...\n" ++ excerpt_note));
}

test "grep_files marks a scan that stopped at the time budget as incomplete" {
    const alloc = std.testing.allocator;
    const matches = [_]grep_search.Match{.{ .absolute_path = "a.txt", .line_number = 1, .line = "needle" }};
    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = &matches, .truncated_reason = .scan_budget }, 10, 0, 0, 0, true, 2000);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n - a.txt:1: needle\n... scan stopped at the 10 s time budget before all candidate files were searched, so results are incomplete; narrow path or include to finish\n",
        body,
    );

    const count_body = try formatCount(alloc, alloc, "", "needle", .{ .scan_budget_reached = true }, 10, 0);
    defer alloc.free(count_body);
    try std.testing.expectEqualStrings(
        "[grep] Found 0 total occurrences across 0 files for needle\n... scan stopped at the 10 s time budget before all candidate files were searched, so results are incomplete; narrow path or include to finish\n",
        count_body,
    );
}

test "grep_files does not retry or count ignored files after the time budget stops the scan" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "ids.txt", "id 42\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/index.txt", "id 7\n"));

    var input = Input{
        .pattern = try alloc.dupe(u8, "id [0-9]+"),
        .path = try alloc.dupe(u8, "."),
        .include = null,
        .case_insensitive = false,
        .mode = .matches,
        .head_limit = default_head_limit,
        .offset = 0,
        .search_pattern = try alloc.dupe(u8, "id\\ \\[0\\-9\\]\\+"),
        .regex_fallback_pattern = try alloc.dupe(u8, "id [0-9]+"),
        .scan_budget_ms = 0,
    };
    defer input.deinit(alloc);

    const result = try callWithOps(.{ .allocator = alloc, .scratch_allocator = alloc, .workspace_root = workspace }, .{ .ptr = &input, .deinit_fn = noopInputDeinit }, .{});
    const body = result.success;
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "[grep] no matches for id [0-9]+\n... scan stopped at the 10 s time budget before all candidate files were searched, so results are incomplete; narrow path or include to finish\n",
        body,
    );
}

test "grep_files shows env file values as redacted" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, ".env", "PLAIN=1\nAPI_TOKEN=tok-12345\nOTHER=2\n"));
    alloc.free(try writeTempFile(alloc, &tmp, ".env.example", "API_TOKEN=example\n"));

    var secret = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"API_TOKEN\",\"output_mode\":\"content\",\"path\":\".env\",\"-C\":1}");
    defer secret.deinit(alloc);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for API_TOKEN\n   .env:1- PLAIN=<redacted>\n - .env:2: API_TOKEN=<redacted>\n   .env:3- OTHER=<redacted>\n",
        secret.body,
    );
    try std.testing.expect(std.mem.find(u8, secret.body, "tok-12345") == null);

    var example = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"API_TOKEN\",\"output_mode\":\"content\",\"path\":\".env.example\"}");
    defer example.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for API_TOKEN\n - .env.example:1: API_TOKEN=example\n", example.body);
}

test "grep_files defaults to files_with_matches and glob narrows content output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "needle zig\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "b.txt", "needle txt\n"));

    var default_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\"}");
    defer default_result.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, default_result.body, "[grep] 2 files with matches for needle\n"));

    var glob_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"output_mode\":\"content\",\"glob\":\"*.zig\"}");
    defer glob_result.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - a.zig:1: needle zig\n", glob_result.body);
}

test "grep_files include_ignored searches gitignored and skipped folders" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "a.zig", "needle zig\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "node_modules/dep/index.zig", "needle dep\n"));

    var default_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"type\":\"zig\"}");
    defer default_result.deinit(alloc);
    try std.testing.expectEqualStrings("[grep] 1 files with matches for needle\n - a.zig\n", default_result.body);

    var included = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"type\":\"zig\",\"include_ignored\":true}");
    defer included.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, included.body, " - node_modules/dep/index.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, included.body, " - a.zig\n") != null);
}

test "grep_files classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .pattern = try std.testing.allocator.dupe(u8, "needle"),
        .path = try std.testing.allocator.dupe(u8, "."),
        .include = null,
        .case_insensitive = false,
        .head_limit = default_head_limit,
        .offset = 0,
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

test "grep_files mode ranked, callers and impact answer from the ranked and symbol search" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    alloc.free(try writeTempFile(alloc, &tmp, "retry.zig", "pub fn parseRetryAfter(header: []const u8) u64 {\n    return header.len;\n}\n"));
    alloc.free(try writeTempFile(alloc, &tmp, "client.zig", "const retry = @import(\"retry.zig\");\npub fn wait() u64 {\n    return retry.parseRetryAfter(\"3\");\n}\n"));

    var ranked = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"parse (the retry header\",\"mode\":\"ranked\",\"k\":5}");
    defer ranked.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, ranked.body, "[ranked] "));
    try std.testing.expect(std.mem.find(u8, ranked.body, "retry.zig:1: pub fn parseRetryAfter(header: []const u8) u64 {\n") != null);

    var callers = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"parseRetryAfter\",\"mode\":\"callers\"}");
    defer callers.deinit(alloc);
    try std.testing.expectEqualStrings("[callers] 2 sites for parseRetryAfter (1 definitions, 0 calls, 1 member calls)\nretry.zig:1 [definition]\nclient.zig:3 [member]\n", callers.body);

    var impact = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"parseRetryAfter\",\"mode\":\"impact\"}");
    defer impact.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, impact.body, "imports the defining files (depth 1): 1 files\n  client.zig\n") != null);

    var counted = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"parseRetryAfter\",\"mode\":\"count\"}");
    defer counted.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, counted.body, "[grep] "));

    var refused = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"parseRetryAfter\",\"mode\":\"callers\",\"closure\":true}");
    defer refused.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, refused.body, "grep_files field \"closure\" needs mode \"ranked\"") != null);
}
