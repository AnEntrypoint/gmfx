const std = @import("std");
const builtin = @import("builtin");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const io_mod = @import("../../core/shared/io.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const tool_files = @import("../../core/workspace/tool_files.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const file_facts = @import("file_facts.zig");

const Allocator = std.mem.Allocator;

const OutputMode = enum {
    matches,
    count,
};

const EntryKind = enum {
    file,
    dir,
    any,
};

const DirectoryScope = enum {
    none,
    direct_children,
    all,
};

const default_head_limit: usize = 100;
const max_fact_line_scan_bytes: usize = 10 * 1024 * 1024;
const accepted_fields = [_][]const u8{ "pattern", "path", "mode", "kind", "head_limit", "offset", "include_ignored" };
pub const glob_no_ignore_env = "CLAUDE_CODE_GLOB_NO_IGNORE";

fn includeIgnoredByDefault(raw: ?[]const u8) bool {
    const text = std.mem.trim(u8, raw orelse return false, " \t\r\n");
    return std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true");
}

pub const Input = struct {
    pattern: []u8,
    path: []u8,
    mode: OutputMode = .matches,
    kind: ?EntryKind = null,
    head_limit: usize = default_head_limit,
    offset: usize = 0,
    include_ignored: bool = false,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        self.* = .{ .pattern = &.{}, .path = &.{}, .mode = .matches };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "glob_files" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    args.rejectUnknown(object, &accepted_fields) catch |err| return .{ .failure = try args.takeFailure(err) };
    const pattern = args.requiredString(object, "pattern") catch |err| return .{ .failure = try args.takeFailure(err) };
    const path_string = args.optionalString(object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };
    const raw_mode = args.optionalString(object, "mode") catch |err| return .{ .failure = try args.takeFailure(err) };
    const mode: OutputMode = if (raw_mode) |raw| std.meta.stringToEnum(OutputMode, raw) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"mode\" must be one of matches, count") };
    } else .matches;
    const raw_kind = args.optionalString(object, "kind") catch |err| return .{ .failure = try args.takeFailure(err) };
    const kind: ?EntryKind = if (raw_kind) |raw| std.meta.stringToEnum(EntryKind, raw) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"kind\" must be one of file, dir, any") };
    } else null;
    const head_limit = countArg(object, "head_limit", default_head_limit) orelse return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"head_limit\" must be a non-negative integer") };
    const offset = countArg(object, "offset", 0) orelse return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"offset\" must be a non-negative integer") };
    const include_ignored = if (object.get("include_ignored")) |value| switch (value) {
        .null => includeIgnoredByDefault(io_mod.getenv(glob_no_ignore_env)),
        .bool => |enabled| enabled,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"include_ignored\" must be a boolean") },
    } else includeIgnoredByDefault(io_mod.getenv(glob_no_ignore_env));

    const owned_pattern = try ctx.allocator.dupe(u8, pattern);
    errdefer ctx.allocator.free(owned_pattern);
    const effective_path = if (path_string) |path|
        if (path.len == 0) "." else path
    else
        ".";
    const owned_path = try ctx.allocator.dupe(u8, effective_path);
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .mode = mode,
        .kind = kind,
        .head_limit = head_limit,
        .offset = offset,
        .include_ignored = include_ignored,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn countArg(object: std.json.ObjectMap, key: []const u8, default: usize) ?usize {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .null => default,
        .integer => |number| std.math.cast(usize, number),
        else => null,
    };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithWorkspaceOptions(ctx, erased, .{});
}

fn callWithWorkspaceOptions(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, list_options: tool_files.Options) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();

    const requested_root = resolveSearchRoot(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", input.path, err) };
        }
        return .{ .failure = try ctx.allocator.print("Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };
    const static_base = if (requested_root.is_directory)
        extractStaticGlobBase(input.pattern)
    else
        StaticGlobBase{ .base = "", .pattern = input.pattern };
    const maybe_root = if (requested_root.is_directory)
        resolveStaticBaseRoot(arena, requested_root.absolute, static_base.base) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", requested_root.absolute, err) };
            }
            return .{ .failure = try ctx.allocator.print("Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
        }
    else
        requested_root;
    const exact_pattern = firstGlobChar(input.pattern) == null;
    const root = maybe_root orelse {
        if (input.mode == .count) {
            return .{ .success = try formatCount(ctx.allocator, input.pattern, 0, .{}) };
        }
        return .{ .success = try formatMatches(ctx.allocator, input.pattern, &.{}, null, .{}, null) };
    };
    const root_relative = try pathing.workspaceRelativePath(arena, ctx.workspace_root, root.absolute);
    var compiled_pattern = glob_pattern.Pattern.compile(arena, static_base.pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PatternTooLong => return .{ .failure = try ctx.allocator.print("glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
    };
    defer compiled_pattern.deinit(arena);

    var collector: MatchCollector = .{
        .arena = arena,
        .pattern = compiled_pattern,
        .root_relative = root_relative,
        .count_only = input.mode == .count,
        .offset = input.offset,
        .page_limit = if (input.head_limit == 0) std.math.maxInt(usize) else input.head_limit,
    };
    defer collector.matches.deinit(arena);
    var completeness: tool_files.Completeness = .{};
    var options = list_options;
    if (input.include_ignored) {
        options.include_ignored = true;
        options.skipped_names = &.{};
    } else {
        options.skipped_names = ctx.ignored_list_entries;
    }
    options.include_hidden = options.include_hidden or shouldIncludeHidden(root_relative, input.pattern);

    if (root.is_directory) {
        const listing = tool_files.list(ctx.scratch_allocator, arena, ctx.workspace_root, root.absolute, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return .{ .failure = try ctx.allocator.print("Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) },
        };
        completeness = .of(listing);
        const directory_scope = directoryScope(input.kind, static_base.pattern);
        const directories = try collectDirectories(arena, listing.files, directory_scope);
        const files: []const []const u8 = if (input.kind == .dir) &.{} else listing.files;
        try collector.addMerged(files, directories);
    } else {
        const basename = std.Io.Dir.path.basename(root_relative);
        if (input.kind != .dir and compiled_pattern.matchesPath(basename)) {
            collector.match_count += 1;
            if (input.mode == .matches and input.offset == 0) {
                try collector.matches.append(arena, try arena.dupe(u8, root_relative));
            }
        }
    }

    if (input.mode == .count) {
        return .{ .success = try formatCount(ctx.allocator, input.pattern, collector.match_count, completeness) };
    }
    if (exact_pattern and collector.match_count == 0 and requested_root.is_directory) {
        return .{ .success = try formatUnlistedExactPath(ctx.allocator, arena, requested_root.absolute, ctx.workspace_root, input.pattern, completeness) };
    }
    const single_facts = if (exact_pattern and collector.match_count == 1 and collector.matches.items.len == 1)
        try singleMatchFacts(arena, ctx.workspace_root, collector.matches.items[0])
    else
        null;
    return .{ .success = try formatMatches(ctx.allocator, input.pattern, collector.matches.items, collector.next_offset, completeness, single_facts) };
}

const MatchCollector = struct {
    arena: Allocator,
    pattern: glob_pattern.Pattern,
    root_relative: []const u8,
    count_only: bool,
    offset: usize,
    page_limit: usize,
    matches: std.ArrayList([]u8) = .empty,
    match_count: usize = 0,
    next_offset: ?usize = null,
    page_full: bool = false,

    fn addMerged(self: *MatchCollector, files: []const []const u8, directories: []const []const u8) Allocator.Error!void {
        var file_index: usize = 0;
        var directory_index: usize = 0;
        while (!self.page_full and (file_index < files.len or directory_index < directories.len)) {
            const take_directory = file_index >= files.len or
                (directory_index < directories.len and std.mem.lessThan(u8, directories[directory_index], files[file_index]));
            if (take_directory) {
                try self.add(directories[directory_index], true);
                directory_index += 1;
            } else {
                try self.add(files[file_index], false);
                file_index += 1;
            }
        }
    }

    fn add(self: *MatchCollector, candidate: []const u8, is_directory: bool) Allocator.Error!void {
        if (!self.pattern.matchesPath(candidate)) return;

        const position = self.match_count;
        self.match_count += 1;
        if (self.count_only or position < self.offset) return;

        if (self.matches.items.len >= self.page_limit) {
            self.next_offset = self.offset + self.matches.items.len;
            self.page_full = true;
            return;
        }

        const joined = try joinRelativeSearchPath(self.arena, self.root_relative, candidate);
        if (!is_directory) return self.matches.append(self.arena, joined);
        try self.matches.append(self.arena, try std.mem.concat(self.arena, u8, &.{ joined, "/" }));
    }
};

fn directoryScope(kind: ?EntryKind, pattern_after_base: []const u8) DirectoryScope {
    const requested = kind orelse return if (isOneLevelPattern(pattern_after_base)) .direct_children else .none;
    return switch (requested) {
        .file => .none,
        .dir, .any => .all,
    };
}

fn isOneLevelPattern(pattern_after_base: []const u8) bool {
    if (firstGlobChar(pattern_after_base) == null) return false;
    if (std.mem.find(u8, pattern_after_base, "**") != null) return false;
    return lastPathSeparator(pattern_after_base) == null;
}

fn collectDirectories(arena: Allocator, files: []const []const u8, scope: DirectoryScope) Allocator.Error![]const []const u8 {
    if (scope == .none) return &.{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (files) |file| {
        var search_from: usize = 0;
        while (std.mem.findScalarPos(u8, file, search_from, '/')) |separator| {
            if (separator > 0) try seen.put(arena, file[0..separator], {});
            if (scope == .direct_children) break;
            search_from = separator + 1;
        }
    }
    const directories = try arena.alloc([]const u8, seen.count());
    var keys = seen.keyIterator();
    var index: usize = 0;
    while (keys.next()) |key| : (index += 1) directories[index] = key.*;
    sort_utils.sort([]const u8, directories, {}, pathLessThan);
    return directories;
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn singleMatchFacts(arena: Allocator, workspace_root: []const u8, shown_path: []const u8) Allocator.Error!?[]const u8 {
    const absolute = pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, shown_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return pathFacts(arena, absolute);
}

fn pathFacts(arena: Allocator, absolute: []const u8) Allocator.Error!?[]const u8 {
    const zio = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(zio, absolute, .{}) catch return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    if (stat.kind == .directory) {
        out.writer.writeAll("directory, modified ") catch return error.OutOfMemory;
        file_facts.writeUtcTimestamp(&out.writer, stat.mtime.nanoseconds) catch return error.OutOfMemory;
        return out.written();
    }
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), absolute, .no_follow) catch return null;
    defer file.close(zio);
    var line_count: usize = 0;
    var scanned: u64 = 0;
    var last_byte: u8 = '\n';
    var read_buffer: [8192]u8 = undefined;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(zio, &read_buffer);
    while (scanned < max_fact_line_scan_bytes) {
        const read_len = reader.interface.readSliceShort(&buffer) catch return null;
        if (read_len == 0) break;
        line_count += std.mem.countScalar(u8, buffer[0..read_len], '\n');
        last_byte = buffer[read_len - 1];
        scanned += read_len;
    }
    if (last_byte != '\n') line_count += 1;
    file_facts.write(&out.writer, .{
        .size_bytes = stat.size,
        .line_count = line_count,
        .line_count_complete = scanned >= stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    }) catch return error.OutOfMemory;
    return out.written();
}

fn formatUnlistedExactPath(
    alloc: Allocator,
    arena: Allocator,
    root_absolute: []const u8,
    workspace_root: []const u8,
    pattern: []const u8,
    completeness: tool_files.Completeness,
) tool_dispatch.DispatchError![]u8 {
    const absolute = pathing.resolveWorkspacePath(arena, root_absolute, pattern, .existing) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return formatMatches(alloc, pattern, &.{}, null, completeness, null),
    };
    const facts = try pathFacts(arena, absolute) orelse return formatMatches(alloc, pattern, &.{}, null, completeness, null);
    const shown = try pathing.workspaceRelativePath(arena, workspace_root, absolute);
    const is_directory = std.mem.startsWith(u8, facts, "directory");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.print("[glob] 1 matches for {s}\n - {s}{s}\n   {s}\n", .{ pattern, shown, if (is_directory) "/" else "", facts }) catch return error.OutOfMemory;
    if (is_directory) {
        out.writer.print("... this path is a directory; pass kind=\"dir\" to match directories, or pattern {s}/* to list inside it\n", .{pattern}) catch return error.OutOfMemory;
    } else {
        out.writer.writeAll("... this file exists but the default listing leaves it out as ignored or hidden; pass include_ignored=true to list such files\n") catch return error.OutOfMemory;
    }
    try completeness.writeNotes(&out.writer);
    return try out.toOwnedSlice();
}

fn formatCount(
    alloc: Allocator,
    pattern: []const u8,
    match_count: usize,
    completeness: tool_files.Completeness,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[glob] count {d} matches for {s}\n", .{ match_count, pattern }) catch return error.OutOfMemory;
    try completeness.writeNotes(&out.writer);
    return try out.toOwnedSlice();
}

fn formatMatches(
    alloc: Allocator,
    pattern: []const u8,
    matches: []const []const u8,
    next_offset: ?usize,
    completeness: tool_files.Completeness,
    single_match_facts: ?[]const u8,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (matches.len == 0) {
        out.writer.print("[glob] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
        try completeness.writeNotes(&out.writer);
        return try out.toOwnedSlice();
    }

    out.writer.print("[glob] {d} matches for {s}\n", .{ matches.len, pattern }) catch return error.OutOfMemory;
    for (matches) |match| {
        out.writer.print(" - {s}\n", .{match}) catch return error.OutOfMemory;
    }
    if (single_match_facts) |facts| {
        out.writer.print("   {s}\n", .{facts}) catch return error.OutOfMemory;
    }
    if (next_offset) |offset| {
        out.writer.print("... more matches after this page; pass offset={d} to continue\n", .{offset}) catch return error.OutOfMemory;
    }
    try completeness.writeNotes(&out.writer);

    return try out.toOwnedSlice();
}

const SearchRoot = struct {
    absolute: []const u8,
    is_directory: bool,
};

fn resolveSearchRoot(arena: Allocator, workspace_root: []const u8, requested: []const u8) !SearchRoot {
    const absolute = try pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, requested);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return .{ .absolute = absolute, .is_directory = false },
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

fn resolveStaticBaseRoot(arena: Allocator, requested_root: []const u8, static_base: []const u8) !?SearchRoot {
    if (static_base.len == 0 or std.mem.eql(u8, static_base, ".")) {
        return .{ .absolute = requested_root, .is_directory = true };
    }
    const absolute = pathing.resolveWorkspacePath(arena, requested_root, static_base, .existing) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return null,
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

const StaticGlobBase = struct {
    base: []const u8,
    pattern: []const u8,
};

fn extractStaticGlobBase(pattern: []const u8) StaticGlobBase {
    const first_glob = firstGlobChar(pattern) orelse {
        const dirname = std.Io.Dir.path.dirname(pattern) orelse return .{ .base = "", .pattern = pattern };
        return .{ .base = dirname, .pattern = std.Io.Dir.path.basename(pattern) };
    };
    const static_prefix = pattern[0..first_glob];
    const last_sep = lastPathSeparator(static_prefix) orelse return .{ .base = "", .pattern = pattern };
    if (last_sep == 0 and isPathSeparator(static_prefix[0])) {
        return .{ .base = static_prefix[0..1], .pattern = pattern[1..] };
    }
    return .{ .base = static_prefix[0..last_sep], .pattern = pattern[last_sep + 1 ..] };
}

fn firstGlobChar(pattern: []const u8) ?usize {
    for (pattern, 0..) |ch, index| {
        switch (ch) {
            '*', '?', '[', '{' => return index,
            else => {},
        }
    }
    return null;
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (isPathSeparator(path[index])) return index;
    }
    return null;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn joinRelativeSearchPath(arena: Allocator, root_relative: []const u8, child_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) {
        return arena.dupe(u8, child_relative);
    }
    return std.Io.Dir.path.join(arena, &.{ root_relative, child_relative });
}

fn shouldIncludeHidden(root_relative: []const u8, pattern: []const u8) bool {
    return tool_files.pathContainsHiddenDirectoryComponent(root_relative) or patternContainsHiddenDirectoryComponent(pattern);
}

fn patternContainsHiddenDirectoryComponent(pattern: []const u8) bool {
    return tool_files.pathContainsHiddenDirectoryComponent(pattern);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const glob_files_dispatch_tool = tool_dispatch.Tool{
    .name = "glob_files",
    .description = "Glob files dispatch test fixture.",
    .model_schema = .{
        .name = "glob_files",
        .description = "Glob files dispatch test fixture.",
    },
    .executor_kind = .glob_files,
    .activity_kind = .list,
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

fn expectDecodeInput(args_json: []const u8, pattern: []const u8, input_path: []const u8) !void {
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
        },
    }
}

fn globArgsJson(alloc: Allocator, pattern: []const u8, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGlobFiles(alloc: Allocator, workspace_root: []const u8, pattern: []const u8, maybe_path: ?[]const u8) !tool_dispatch.DispatchResult {
    const args = try globArgsJson(alloc, pattern, maybe_path);
    defer alloc.free(args);

    return dispatchGlobFilesRaw(alloc, workspace_root, args);
}

fn dispatchGlobFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{glob_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "glob_files",
        .arguments_json = args_json,
    });
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

fn writeTempFileWithMtime(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    content: []const u8,
    mtime_ns: i96,
) ![]u8 {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    try file.setTimestamps(io_mod.getIo(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn createNumberedFiles(tmp: *std.testing.TmpDir, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{i});
        if (std.Io.Dir.path.dirname(name)) |parent| {
            try tmp.dir.createDirPath(io_mod.getIo(), parent);
        }
        {
            var file = try tmp.dir.createFile(std.testing.io, name, .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "x\n");
        }
    }
}

test "glob_files decodes invalid argument shapes as failures" {
    try expectDecodeFailure("{", "glob_files arguments must be valid JSON");
    try expectDecodeFailure("[]", "glob_files arguments must be an object");
    try expectDecodeFailure("{\"path\":\".\"}", "glob_files requires string field \"pattern\"");
    try expectDecodeFailure("{\"pattern\":1}", "glob_files field \"pattern\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"path\":1}", "glob_files field \"path\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"mode\":\"files\"}", "glob_files field \"mode\" must be one of matches, count");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"mode\":true}", "glob_files field \"mode\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"head_limit\":-1}", "glob_files field \"head_limit\" must be a non-negative integer");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"head_limit\":\"5\"}", "glob_files field \"head_limit\" must be a non-negative integer");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"offset\":-2}", "glob_files field \"offset\" must be a non-negative integer");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"include_ignored\":\"yes\"}", "glob_files field \"include_ignored\" must be a boolean");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"kind\":\"folder\"}", "glob_files field \"kind\" must be one of file, dir, any");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"kind\":3}", "glob_files field \"kind\" must be a string");
    try expectDecodeFailure(
        "{\"pattern\":\"*.zig\",\"limit\":5}",
        "glob_files does not take argument \"limit\"; accepted fields: pattern, path, mode, kind, head_limit, offset, include_ignored",
    );
}

test "CLAUDE_CODE_GLOB_NO_IGNORE=true makes a glob that names no include_ignored list ignored files" {
    try std.testing.expect(!includeIgnoredByDefault(null));
    try std.testing.expect(!includeIgnoredByDefault("false"));
    try std.testing.expect(!includeIgnoredByDefault("0"));
    try std.testing.expect(!includeIgnoredByDefault("maybe"));
    try std.testing.expect(includeIgnoredByDefault(" true\n"));
    try std.testing.expect(includeIgnoredByDefault("1"));
}

test "glob_files decodes head_limit, offset, and include_ignored with their defaults" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        head_limit: usize,
        offset: usize,
        include_ignored: bool,
    }{
        .{ .json = "{\"pattern\":\"*.zig\"}", .head_limit = 100, .offset = 0, .include_ignored = false },
        .{ .json = "{\"pattern\":\"*.zig\",\"head_limit\":null,\"offset\":null,\"include_ignored\":null}", .head_limit = 100, .offset = 0, .include_ignored = false },
        .{ .json = "{\"pattern\":\"*.zig\",\"head_limit\":0,\"offset\":7,\"include_ignored\":true}", .head_limit = 0, .offset = 7, .include_ignored = true },
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
        try std.testing.expectEqual(case.head_limit, input.head_limit);
        try std.testing.expectEqual(case.offset, input.offset);
        try std.testing.expectEqual(case.include_ignored, input.include_ignored);
    }
}

test "glob_files decodes omitted path and valid input" {
    try expectDecodeInput("{\"pattern\":\"*.zig\"}", "*.zig", ".");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":\"\"}", "*.zig", ".");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":\"src\"}", "*.zig", "src");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":null,\"mode\":null}", "*.zig", ".");
}

test "glob_files validate preserves active raw pattern and path values" {
    const alloc = std.testing.allocator;
    var empty = Input{
        .pattern = try alloc.dupe(u8, " \t\n "),
        .path = try alloc.dupe(u8, "   "),
    };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings(" \t\n ", empty.pattern);
    try std.testing.expectEqualStrings("   ", empty.path);

    var valid = Input{
        .pattern = try alloc.dupe(u8, "  **/*.zig  "),
        .path = try alloc.dupe(u8, "  src  "),
    };
    defer valid.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &valid, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings("  **/*.zig  ", valid.pattern);
    try std.testing.expectEqualStrings("  src  ", valid.path);
}

test "glob_files reports overlong patterns during matching" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pattern = try alloc.alloc(u8, glob_pattern.max_pattern_bytes + 1);
    defer alloc.free(pattern);
    @memset(pattern, '*');

    var input = Input{
        .pattern = try alloc.dupe(u8, pattern),
        .path = try alloc.dupe(u8, "."),
    };
    defer input.deinit(alloc);

    const result = try call(.{ .allocator = alloc, .scratch_allocator = alloc, .workspace_root = workspace }, .{ .ptr = &input, .deinit_fn = noopInputDeinit });
    defer result.deinit(alloc);
    const expected = try alloc.print("glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes});
    defer alloc.free(expected);
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
        .success => try std.testing.expect(false),
    }
}

test "glob_files Input ownership duplicates and frees under testing allocator" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"*.zig\",\"path\":\"src\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            const input = erased.as(Input);
            try std.testing.expectEqualStrings("*.zig", input.pattern);
            try std.testing.expectEqualStrings("src", input.path);
            erased.deinit(alloc);
        },
    }
}

test "glob_files regular-file search root matches basename only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "single.txt", "one\n");
    defer alloc.free(file_path);

    var one = try dispatchGlobFiles(alloc, workspace, "*.txt", file_path);
    defer one.deinit(alloc);
    try std.testing.expectEqual(.success, one.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for *.txt\n - single.txt\n", one.body);

    var segmented = try dispatchGlobFiles(alloc, workspace, "dir/*.txt", file_path);
    defer segmented.deinit(alloc);
    try std.testing.expectEqual(.success, segmented.status);
    try std.testing.expectEqualStrings("[glob] no matches for dir/*.txt\n", segmented.body);
}

test "glob_files regular-file root follows active basename behavior inside ignored directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const ignored_file = try writeTempFile(alloc, &tmp, "node_modules/pkg/file.zig", "ignored\n");
    defer alloc.free(ignored_file);

    var result = try dispatchGlobFiles(alloc, workspace, "*.zig", ignored_file);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for *.zig\n - node_modules/pkg/file.zig\n", result.body);
}

test "glob_files explicit ignored directory root follows active behavior" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const ignored_file = try writeTempFile(alloc, &tmp, "node_modules/pkg/file.zig", "ignored\n");
    defer alloc.free(ignored_file);

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", "node_modules");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for **/*.zig\n - node_modules/pkg/file.zig\n", result.body);
}

test "glob_files resolver error for missing path returns failure result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var result = try dispatchGlobFiles(alloc, workspace, "*.zig", "missing");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve glob search root: missing (FileNotFound)", result.body);
}

test "glob_files permission denied directory returns structured recovery" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const root = try alloc.print("/tmp/fx-glob-files-access-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const workspace = try io_mod.realpathAlloc(alloc, root);
    defer alloc.free(workspace);
    const blocked = try std.Io.Dir.path.join(alloc, &.{ workspace, "blocked" });
    defer alloc.free(blocked);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), blocked);

    std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), blocked, std.Io.File.Permissions.fromMode(0), .{}) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), blocked, std.Io.File.Permissions.fromMode(0o700), .{}) catch {};

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", blocked);
    defer result.deinit(alloc);
    if (result.status == .success) return error.SkipZigTest;

    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(result.body));
    try std.testing.expect(std.mem.find(u8, result.body, "\"tool_name\":\"glob_files\"") != null);
    try std.testing.expect(std.mem.find(u8, result.body, blocked) != null);
    try std.testing.expect(std.mem.find(u8, result.body, "AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "symlink") != null);
}

test "glob_files formats zero, one, and multiple results" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const one_path = try writeTempFileWithMtime(alloc, &tmp, "one.txt", "one\n", 1_000_000_000);
    defer alloc.free(one_path);
    const two_path = try writeTempFileWithMtime(alloc, &tmp, "two.txt", "two\n", 2_000_000_000);
    defer alloc.free(two_path);

    var zero = try dispatchGlobFiles(alloc, workspace, "*.zig", null);
    defer zero.deinit(alloc);
    try std.testing.expectEqual(.success, zero.status);
    try std.testing.expectEqualStrings("[glob] no matches for *.zig\n", zero.body);

    var one = try dispatchGlobFiles(alloc, workspace, "one.txt", null);
    defer one.deinit(alloc);
    try std.testing.expectEqual(.success, one.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for one.txt\n - one.txt\n   4 bytes, 1 line, modified 1970-01-01T00:00:01Z\n", one.body);

    var multiple = try dispatchGlobFiles(alloc, workspace, "*.txt", null);
    defer multiple.deinit(alloc);
    try std.testing.expectEqual(.success, multiple.status);
    try std.testing.expect(std.mem.startsWith(u8, multiple.body, "[glob] 2 matches for *.txt\n"));
    try std.testing.expect(std.mem.find(u8, multiple.body, " - one.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, multiple.body, " - two.txt\n") != null);
}

test "glob_files pages output at the default head limit with a continuation offset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 150);

    const result = try dispatchGlobFiles(alloc, workspace, "**/*.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[glob] 100 matches for **/*.txt\n"));
    try std.testing.expectEqual(@as(usize, 100), countEmittedResultLines(result.body));
    try std.testing.expect(std.mem.find(u8, result.body, "... more matches after this page; pass offset=100 to continue\n") != null);
}

test "glob_files head_limit and offset page through matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 5);

    var first = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"head_limit\":2}");
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, first.body, "[glob] 2 matches for **/*.txt\n"));
    try std.testing.expect(std.mem.find(u8, first.body, "... more matches after this page; pass offset=2 to continue\n") != null);

    var last = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"head_limit\":2,\"offset\":4}");
    defer last.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, last.body, "[glob] 1 matches for **/*.txt\n"));
    try std.testing.expect(std.mem.find(u8, last.body, "more matches") == null);

    var past_end = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"offset\":5}");
    defer past_end.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] no matches for **/*.txt\n", past_end.body);
}

test "glob_files head_limit zero removes the match-count limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 150);

    var result = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"head_limit\":0}");
    defer result.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(u8, result.body, "[glob] 150 matches for **/*.txt\n"));
    try std.testing.expectEqual(@as(usize, 150), countEmittedResultLines(result.body));
    try std.testing.expect(std.mem.find(u8, result.body, "more matches") == null);
}

test "glob_files include_ignored lists gitignored files and skipped build outputs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const gitignore = try writeTempFileWithMtime(alloc, &tmp, ".gitignore", "secret.txt\n", 1_000_000_000);
    defer alloc.free(gitignore);
    const secret = try writeTempFileWithMtime(alloc, &tmp, "secret.txt", "s\n", 1_000_000_000);
    defer alloc.free(secret);
    const plain = try writeTempFileWithMtime(alloc, &tmp, "plain.txt", "p\n", 1_000_000_000);
    defer alloc.free(plain);
    const dependency = try writeTempFileWithMtime(alloc, &tmp, "node_modules/dep/index.txt", "d\n", 1_000_000_000);
    defer alloc.free(dependency);

    var default_result = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\"}");
    defer default_result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, default_result.body, " - plain.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, default_result.body, "secret.txt") == null);
    try std.testing.expect(std.mem.find(u8, default_result.body, "node_modules") == null);

    var included = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"include_ignored\":true}");
    defer included.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, included.body, " - secret.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, included.body, " - node_modules/dep/index.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, included.body, " - plain.txt\n") != null);
}

test "glob_files count mode reports exact matches without rendering entries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 150);

    var result = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"mode\":\"count\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] count 150 matches for **/*.txt\n", result.body);
    try std.testing.expectEqual(@as(usize, 0), countEmittedResultLines(result.body));
}

test "glob_files formatter names the continuation offset" {
    const alloc = std.testing.allocator;
    const matches = [_][]const u8{ "a.txt", "b.txt" };
    const body = try formatMatches(alloc, "*.txt", &matches, 2, .{}, null);
    defer alloc.free(body);

    try std.testing.expectEqualStrings("[glob] 2 matches for *.txt\n - a.txt\n - b.txt\n... more matches after this page; pass offset=2 to continue\n", body);
}

test "glob_files path narrowing applies before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.txt", "outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/core/workspace/target.zig", "target\n");
    defer alloc.free(target);

    var input = Input{
        .pattern = try alloc.dupe(u8, "target.zig"),
        .path = try alloc.dupe(u8, "src/core/workspace"),
    };
    defer input.deinit(alloc);

    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = noopInputDeinit };
    var result = try callWithWorkspaceOptions(.{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace,
        .max_list_entries = 10,
    }, erased, .{
        .candidate_cap = 1,
    });
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expect(std.mem.startsWith(u8, body, "[glob] 1 matches for target.zig\n - src/core/workspace/target.zig\n   7 bytes, 1 line, modified ")),
        .failure => try std.testing.expect(false),
    }
}

test "glob_files extracts static base before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.zig", "outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/tools/target.zig", "target\n");
    defer alloc.free(target);

    var input = Input{
        .pattern = try alloc.dupe(u8, "src/tools/**/*.zig"),
        .path = try alloc.dupe(u8, "."),
    };
    defer input.deinit(alloc);

    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = noopInputDeinit };
    var result = try callWithWorkspaceOptions(.{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace,
        .max_list_entries = 10,
    }, erased, .{
        .candidate_cap = 1,
    });
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expectEqualStrings("[glob] 1 matches for src/tools/**/*.zig\n - src/tools/target.zig\n", body),
        .failure => try std.testing.expect(false),
    }
}

test "glob_files root git discovery includes untracked files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "tracked\n");
    defer alloc.free(tracked);
    try runGitForTest(alloc, workspace, &.{ "add", "tracked.txt" });
    const untracked = try writeTempFile(alloc, &tmp, "untracked-target.txt", "untracked\n");
    defer alloc.free(untracked);

    var result = try dispatchGlobFiles(alloc, workspace, "untracked-*.txt", ".");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for untracked-*.txt\n - untracked-target.txt\n", result.body);
}

test "glob_files static base extraction handles literal and wildcard patterns" {
    var base = extractStaticGlobBase("src/core/**/*.zig");
    try std.testing.expectEqualStrings("src/core", base.base);
    try std.testing.expectEqualStrings("**/*.zig", base.pattern);

    base = extractStaticGlobBase("src/main.zig");
    try std.testing.expectEqualStrings("src", base.base);
    try std.testing.expectEqualStrings("main.zig", base.pattern);

    base = extractStaticGlobBase("*.zig");
    try std.testing.expectEqualStrings("", base.base);
    try std.testing.expectEqualStrings("*.zig", base.pattern);
}

test "glob_files finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 2050);
    const late = try writeTempFile(alloc, &tmp, "zzzz/target.zig", "target\n");
    defer alloc.free(late);

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "zzzz/target.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "traversal cap") == null);
}

test "glob_files keeps only its result in the turn's allocator" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 2050);
    const args = try globArgsJson(alloc, "**/file-0001.txt", null);
    defer alloc.free(args);

    var turn_state = std.heap.ArenaAllocator.init(alloc);
    defer turn_state.deinit();
    const registry = tool_dispatch.Registry{ .tools = &.{glob_files_dispatch_tool} };
    for (0..2) |_| {
        const before = turn_state.queryCapacity();
        const result = try tool_dispatch.dispatchToolCall(.{
            .allocator = turn_state.allocator(),
            .scratch_allocator = alloc,
            .permission_mode = .auto,
            .workspace_root = workspace,
        }, registry, .{ .id = "call_1", .name = "glob_files", .arguments_json = args });
        try std.testing.expectEqual(.success, result.status);
        try std.testing.expect(std.mem.find(u8, result.body, "many/file-0001.txt") != null);

        try std.testing.expect(turn_state.queryCapacity() - before < 64 * 1024);
    }
}

test "glob_files distinguishes candidate cap from output cap" {
    const alloc = std.testing.allocator;
    const matches = [_][]const u8{ "a.txt", "b.txt" };
    const body = try formatMatches(alloc, "*.txt", &matches, 2, .{ .incomplete = true, .cap_reached = true, .candidate_cap = 2 }, null);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "... more matches after this page; pass offset=2 to continue\n") != null);
    try std.testing.expect(std.mem.find(u8, body, "candidate cap 2 reached") != null);
}

test "glob_files allows external absolute path search roots" {
    const alloc = std.testing.allocator;

    const root = try alloc.print("/tmp/fx-glob-external-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    const workspace_dir = try std.Io.Dir.path.join(alloc, &.{ root, "workspace" });
    defer alloc.free(workspace_dir);
    const external_dir = try std.Io.Dir.path.join(alloc, &.{ root, "external" });
    defer alloc.free(external_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), workspace_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), external_dir);

    const workspace = try io_mod.realpathAlloc(alloc, workspace_dir);
    defer alloc.free(workspace);
    const external = try io_mod.realpathAlloc(alloc, external_dir);
    defer alloc.free(external);
    const external_file = try std.Io.Dir.path.join(alloc, &.{ external, "outside.txt" });
    defer alloc.free(external_file);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), external_file, .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "outside\n");
    }

    const result = try dispatchGlobFiles(alloc, workspace, "*.txt", external);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    const expected = try alloc.print("[glob] 1 matches for *.txt\n - {s}\n", .{external_file});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, result.body);
}

test "glob_files pattern static base cannot escape the approved search root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const outside = try writeTempFile(alloc, &tmp, "external/outside.txt", "outside\n");
    defer alloc.free(outside);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const absolute_pattern = try std.Io.Dir.path.join(alloc, &.{ external, "*.txt" });
    defer alloc.free(absolute_pattern);

    const patterns = [_][]const u8{
        "../external/*.txt",
        absolute_pattern,
    };
    for (patterns) |pattern| {
        var result = try dispatchGlobFiles(alloc, workspace, pattern, ".");
        defer result.deinit(alloc);

        try std.testing.expectEqual(.failure, result.status);
        try std.testing.expect(std.mem.find(u8, result.body, "PathOutsideWorkspace") != null);
    }
}

const TreeFixture = struct {
    tmp: std.testing.TmpDir,
    workspace: []u8,

    fn init(alloc: Allocator) !TreeFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const tree_files = [_][]const u8{ "a.txt", "docs/guide.md", "docs/deep/x.md", "src/main.zig" };
        for (tree_files) |sub_path| {
            const written = try writeTempFile(alloc, &tmp, sub_path, "line\n");
            alloc.free(written);
        }
        return .{ .tmp = tmp, .workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".") };
    }

    fn deinit(self: *TreeFixture, alloc: Allocator) void {
        alloc.free(self.workspace);
        self.tmp.cleanup();
    }
};

fn expectListed(body: []const u8, comptime entry: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, body, " - " ++ entry ++ "\n") != null);
}

fn expectNotListed(body: []const u8, comptime entry: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, body, " - " ++ entry ++ "\n") == null);
}

test "glob_files one-level pattern lists direct child directories with a trailing slash" {
    const alloc = std.testing.allocator;
    var tree = try TreeFixture.init(alloc);
    defer tree.deinit(alloc);

    var result = try dispatchGlobFiles(alloc, tree.workspace, "*", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[glob] 6 matches for *\n"));
    try expectListed(result.body, "a.txt");
    try expectListed(result.body, "docs/");
    try expectListed(result.body, "docs/guide.md");
    try expectListed(result.body, "docs/deep/x.md");
    try expectListed(result.body, "src/");
    try expectListed(result.body, "src/main.zig");
    try expectNotListed(result.body, "docs/deep/");

    var nested = try dispatchGlobFiles(alloc, tree.workspace, "docs/*", null);
    defer nested.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, nested.body, "[glob] 3 matches for docs/*\n"));
    try expectListed(nested.body, "docs/deep/");
    try expectListed(nested.body, "docs/guide.md");
    try expectListed(nested.body, "docs/deep/x.md");

    var recursive = try dispatchGlobFiles(alloc, tree.workspace, "**/*.md", null);
    defer recursive.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, recursive.body, "[glob] 2 matches for **/*.md\n"));
}

test "glob_files kind selects files, directories, or both" {
    const alloc = std.testing.allocator;
    var tree = try TreeFixture.init(alloc);
    defer tree.deinit(alloc);

    var directories = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"*\",\"kind\":\"dir\"}");
    defer directories.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] 3 matches for *\n - docs/\n - docs/deep/\n - src/\n", directories.body);

    var named = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"**/deep\",\"kind\":\"dir\"}");
    defer named.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] 1 matches for **/deep\n - docs/deep/\n", named.body);

    var files = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"*\",\"kind\":\"file\"}");
    defer files.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, files.body, "[glob] 4 matches for *\n"));
    try expectNotListed(files.body, "docs/");

    var any = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"*\",\"kind\":\"any\"}");
    defer any.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, any.body, "[glob] 7 matches for *\n"));
    try expectListed(any.body, "docs/deep/");
    try expectListed(any.body, "src/main.zig");

    var counted = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"*\",\"kind\":\"dir\",\"mode\":\"count\"}");
    defer counted.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] count 3 matches for *\n", counted.body);

    var paged = try dispatchGlobFilesRaw(alloc, tree.workspace, "{\"pattern\":\"*\",\"kind\":\"dir\",\"head_limit\":1,\"offset\":1}");
    defer paged.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] 1 matches for *\n - docs/deep/\n... more matches after this page; pass offset=2 to continue\n", paged.body);
}

test "glob_files answers a single exact path with size, line count and modification time" {
    const alloc = std.testing.allocator;
    var tree = try TreeFixture.init(alloc);
    defer tree.deinit(alloc);
    const ignored = try writeTempFile(alloc, &tree.tmp, "node_modules/pkg/file.zig", "ignored\n");
    defer alloc.free(ignored);

    var exact = try dispatchGlobFiles(alloc, tree.workspace, "docs/guide.md", null);
    defer exact.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, exact.body, "[glob] 1 matches for docs/guide.md\n - docs/guide.md\n   5 bytes, 1 line, modified 2"));
    try std.testing.expect(std.mem.endsWith(u8, exact.body, "Z\n"));

    var unlisted = try dispatchGlobFiles(alloc, tree.workspace, "node_modules/pkg/file.zig", null);
    defer unlisted.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, unlisted.body, "[glob] 1 matches for node_modules/pkg/file.zig\n - node_modules/pkg/file.zig\n   8 bytes, 1 line, modified 2"));

    var directory = try dispatchGlobFiles(alloc, tree.workspace, "docs", null);
    defer directory.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, directory.body, "[glob] 1 matches for docs\n - docs/\n   directory, modified 2"));
    try std.testing.expect(std.mem.endsWith(u8, directory.body, "... this path is a directory; pass kind=\"dir\" to match directories, or pattern docs/* to list inside it\n"));

    var missing = try dispatchGlobFiles(alloc, tree.workspace, "nope.txt", null);
    defer missing.deinit(alloc);
    try std.testing.expectEqualStrings("[glob] no matches for nope.txt\n", missing.body);
}

test "glob_files directory scope follows kind and the pattern shape" {
    try std.testing.expectEqual(DirectoryScope.direct_children, directoryScope(null, "*"));
    try std.testing.expectEqual(DirectoryScope.direct_children, directoryScope(null, "*.md"));
    try std.testing.expectEqual(DirectoryScope.none, directoryScope(null, "**/*.md"));
    try std.testing.expectEqual(DirectoryScope.none, directoryScope(null, "a/*.md"));
    try std.testing.expectEqual(DirectoryScope.none, directoryScope(null, "main.zig"));
    try std.testing.expectEqual(DirectoryScope.none, directoryScope(.file, "*"));
    try std.testing.expectEqual(DirectoryScope.all, directoryScope(.dir, "**/*.md"));
    try std.testing.expectEqual(DirectoryScope.all, directoryScope(.any, "main.zig"));
}

test "glob_files classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .pattern = try std.testing.allocator.dupe(u8, "*.zig"),
        .path = try std.testing.allocator.dupe(u8, ""),
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
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
