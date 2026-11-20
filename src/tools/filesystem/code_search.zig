const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const ranked_search = @import("../../core/tooling/ranked_search.zig");
const symbol_scan = @import("../../core/tooling/symbol_scan.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const notes_relative_dir = ".fx/notes";

pub const Mode = enum { ranked, callers, impact };
pub const Scope = enum { workspace, notes };

pub const Request = struct {
    mode: Mode,
    k: usize = ranked_search.default_k,
    closure: bool = false,
    scope: Scope = .workspace,
};

pub const Decoded = union(enum) {
    none,
    request: Request,
    failure: []u8,
};

pub const default_site_page: usize = 50;
pub const max_site_page: usize = 200;
pub const max_impact_depth: usize = 3;
pub const max_impact_files: usize = 100;
const site_collection_cap: usize = 5000;
const scan_budget_ms: i64 = 10_000;
const impact_section_lines: usize = 40;
const closure_hits: usize = 5;
const closure_lines_per_hit: usize = 12;
const closure_names: usize = 12;
const closure_candidate_files: usize = 200;
const closure_output_lines: usize = 20;

pub fn decodeRequest(alloc: Allocator, object: std.json.ObjectMap) Allocator.Error!Decoded {
    const raw_mode = switch (object.get("mode") orelse return .none) {
        .string => |text| text,
        else => return .none,
    };
    const mode = std.meta.stringToEnum(Mode, raw_mode) orelse return .none;
    var request: Request = .{ .mode = mode };

    if (object.get("k")) |value| switch (value) {
        .null => {},
        .integer => |count| {
            if (count < 1) return .{ .failure = try alloc.dupe(u8, "grep_files field \"k\" must be an integer from 1 to 50") };
            request.k = @intCast(@min(count, @as(i64, @intCast(ranked_search.max_k))));
        },
        else => return .{ .failure = try alloc.dupe(u8, "grep_files field \"k\" must be an integer from 1 to 50") },
    };
    if (object.get("closure")) |value| switch (value) {
        .null => {},
        .bool => |enabled| request.closure = enabled,
        else => return .{ .failure = try alloc.dupe(u8, "grep_files field \"closure\" must be a boolean") },
    };
    if (object.get("scope")) |value| switch (value) {
        .null => {},
        .string => |text| request.scope = std.meta.stringToEnum(Scope, text) orelse {
            return .{ .failure = try alloc.dupe(u8, "grep_files field \"scope\" must be one of workspace, notes") };
        },
        else => return .{ .failure = try alloc.dupe(u8, "grep_files field \"scope\" must be one of workspace, notes") },
    };
    if (request.scope == .notes and mode != .ranked) {
        return .{ .failure = try alloc.dupe(u8, "grep_files scope \"notes\" needs mode \"ranked\"") };
    }
    if (request.closure and mode != .ranked) {
        return .{ .failure = try alloc.dupe(u8, "grep_files field \"closure\" needs mode \"ranked\"") };
    }
    return .{ .request = request };
}

pub const Call = struct {
    request: Request,
    query: []const u8,
    path: []const u8 = ".",
    include_ignored: bool = false,
    head_limit: usize = default_site_page,
    offset: usize = 0,
    budget_ms: i64 = ranked_search.default_build_budget_ms,
    index_allocator: Allocator = std.heap.c_allocator,
};

pub fn call(ctx: tool_dispatch.DispatchContext, input: Call) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const query = std.mem.trim(u8, input.query, " \t\r\n");
    if (query.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"pattern\" must not be empty") };
    if (input.request.mode != .ranked and !symbol_scan.isIdentifier(query)) {
        return .{ .failure = try ctx.allocator.print("grep_files mode \"{s}\" needs one identifier in \"pattern\", such as parseHeader", .{@tagName(input.request.mode)}) };
    }

    const absolute_root = switch (input.request.scope) {
        .notes => try std.Io.Dir.path.join(arena, &.{ ctx.workspace_root, notes_relative_dir }),
        .workspace => pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try ctx.allocator.print("Unable to resolve search root: {s} ({s})", .{ input.path, @errorName(err) }) };
        },
    };
    const root_stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_root, .{}) catch |err| {
        if (input.request.scope == .notes) return .{ .success = try ctx.allocator.print("[ranked] no notes yet under {s}\n", .{notes_relative_dir}) };
        return .{ .failure = try ctx.allocator.print("Unable to stat search root: {s} ({s})", .{ absolute_root, @errorName(err) }) };
    };
    if (root_stat.kind != .directory) {
        return .{ .failure = try ctx.allocator.print("grep_files mode \"{s}\" searches a directory; {s} is not one", .{ @tagName(input.request.mode), input.path }) };
    }

    const lease = ranked_search.prepare(input.index_allocator, ctx.scratch_allocator, .{
        .workspace_root = ctx.workspace_root,
        .absolute_root = absolute_root,
        .include_ignored = input.include_ignored or input.request.scope == .notes,
        .budget_ms = input.budget_ms,
        .cancel = ctx.cancel_flag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{ .failure = try ctx.allocator.print("Unable to list search root: {s}", .{absolute_root}) },
    };
    defer lease.release();

    const prefix = displayPrefix(ctx.workspace_root, absolute_root);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const search: Search = .{ .ctx = ctx, .arena = arena, .lease = lease, .prefix = prefix, .writer = &out.writer, .absolute_root = absolute_root };
    switch (input.request.mode) {
        .ranked => try search.ranked(query, input.request),
        .callers => try search.callers(query, input.head_limit, input.offset),
        .impact => try search.impact(query),
    }
    try lease.writeNotes(&out.writer);
    return .{ .success = try out.toOwnedSlice() };
}

fn displayPrefix(workspace_root: []const u8, absolute_root: []const u8) []const u8 {
    if (!pathing.pathInside(workspace_root, absolute_root)) return absolute_root;
    const relative = pathing.workspaceRelative(workspace_root, absolute_root);
    return if (std.mem.eql(u8, relative, ".")) "" else relative;
}

const Site = struct {
    path: []const u8,
    line: usize,
    kind: symbol_scan.OccurrenceKind,
};

const Sites = struct {
    items: []const Site,
    partial: bool,
    capped: bool,

    fn count(self: Sites, kind: symbol_scan.OccurrenceKind) usize {
        var total: usize = 0;
        for (self.items) |site| total += @intFromBool(site.kind == kind);
        return total;
    }
};

const FileCount = struct {
    path: []const u8,
    count: usize,
};

const NameSet = struct {
    arena: Allocator,
    names: std.ArrayList([]const u8) = .empty,
    limit: usize,

    pub fn add(self: *NameSet, name: []const u8) Allocator.Error!void {
        if (self.names.items.len >= self.limit) return;
        for (self.names.items) |known| {
            if (std.mem.eql(u8, known, name)) return;
        }
        try self.names.append(self.arena, try self.arena.dupe(u8, name));
    }
};

const Search = struct {
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    lease: ranked_search.Lease,
    prefix: []const u8,
    writer: *std.Io.Writer,
    absolute_root: []const u8,

    fn print(self: Search, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        self.writer.print(fmt, args) catch return error.OutOfMemory;
    }

    fn printPath(self: Search, path: []const u8) error{OutOfMemory}!void {
        if (self.prefix.len == 0) return self.print("{s}", .{path});
        return self.print("{s}/{s}", .{ self.prefix, path });
    }

    fn ranked(self: Search, query: []const u8, request: Request) tool_dispatch.DispatchError!void {
        const hits = try self.lease.index.search(self.arena, query, request.k);
        if (hits.len == 0) {
            try self.print("[ranked] no results for {s}\n", .{query});
            return;
        }
        try self.print("[ranked] {d} results for {s}\n", .{ hits.len, query });
        for (hits) |hit| {
            try self.printPath(hit.path);
            try self.print(":{d}: {s}\n", .{ hit.line, hit.excerpt });
        }
        if (request.closure) try self.closure(hits);
    }

    fn closure(self: Search, hits: []const ranked_search.Hit) tool_dispatch.DispatchError!void {
        const io = io_mod.getIo();
        var root_dir = std.Io.Dir.openDirAbsolute(io, self.absolute_root, .{}) catch return;
        defer root_dir.close(io);

        var called: NameSet = .{ .arena = self.arena, .limit = closure_names };
        for (hits[0..@min(hits.len, closure_hits)]) |hit| {
            const content = try readText(self.arena, root_dir, hit.path) orelse continue;
            const language = symbol_scan.Language.ofPath(hit.path);
            var line_number: usize = 1;
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| : (line_number += 1) {
                if (line_number < hit.line) continue;
                if (line_number >= hit.line + closure_lines_per_hit) break;
                try symbol_scan.callNames(line, language, &called);
            }
        }

        var written: usize = 0;
        var header_written = false;
        const limits: ranked_search.Limits = .{ .deadline_ms = io_mod.awakeMilliTimestamp() + scan_budget_ms, .cancel = self.ctx.cancel_flag };
        for (called.names.items) |name| {
            if (written >= closure_output_lines) break;
            const candidates = try self.lease.index.filesMentioning(self.arena, name);
            if (candidates.len > closure_candidate_files) continue;
            const sites = try collectSites(self.arena, self.ctx.scratch_allocator, root_dir, candidates, name, limits, true);
            for (sites.items) |site| {
                if (written >= closure_output_lines) break;
                if (hitCovers(hits, site)) continue;
                if (!header_written) {
                    try self.print("closure: definitions of functions the top results call\n", .{});
                    header_written = true;
                }
                try self.printPath(site.path);
                try self.print(":{d} defines {s}\n", .{ site.line, name });
                written += 1;
            }
        }
        if (!header_written) try self.print("closure: no definitions found outside the results\n", .{});
    }

    fn callers(self: Search, name: []const u8, head_limit: usize, offset: usize) tool_dispatch.DispatchError!void {
        const sites = try self.sitesOf(name) orelse return;
        const total = sites.items.len;
        if (total == 0) {
            try self.print("[callers] no definitions or call sites for {s}\n", .{name});
            try self.sitesNotes(sites);
            return;
        }
        const page = @max(1, @min(head_limit, max_site_page));
        const start = @min(offset, total);
        const end = start + @min(page, total - start);
        try self.print("[callers] {d} sites for {s} ({d} definitions, {d} calls, {d} member calls)", .{ total, name, sites.count(.definition), sites.count(.call), sites.count(.member) });
        if (start > 0 or end < total) try self.print(" showing {d}-{d}", .{ start + @intFromBool(end > start), end });
        try self.print("\n", .{});
        for (sites.items[start..end]) |site| {
            try self.printPath(site.path);
            try self.print(":{d} [{s}]\n", .{ site.line, site.kind.label() });
        }
        if (end < total) try self.print("... more sites available; use offset {d} to continue\n", .{end});
        try self.sitesNotes(sites);
    }

    fn impact(self: Search, name: []const u8) tool_dispatch.DispatchError!void {
        const sites = try self.sitesOf(name) orelse return;
        const defining = try fileCounts(self.arena, sites.items, true);
        const calling = try fileCounts(self.arena, sites.items, false);
        const defining_paths = try self.arena.alloc([]const u8, defining.len);
        for (defining, defining_paths) |file, *path| path.* = file.path;
        const importing = try self.lease.index.importers(self.arena, defining_paths, max_impact_depth, max_impact_files);

        try self.print("[impact] {s}: {d} defining files, {d} calling files, {d} importing files to depth {d}\n", .{ name, defining.len, calling.len, importing.files.len, max_impact_depth });
        try self.countSection("defines", "definitions", defining);
        try self.countSection("calls", "call sites", calling);
        var depth: usize = 1;
        while (depth <= max_impact_depth) : (depth += 1) {
            var at_depth: usize = 0;
            for (importing.files) |file| at_depth += @intFromBool(file.depth == depth);
            if (at_depth == 0) continue;
            try self.print("imports the defining files (depth {d}): {d} files\n", .{ depth, at_depth });
            var shown: usize = 0;
            for (importing.files) |file| {
                if (file.depth != depth) continue;
                if (shown == impact_section_lines) {
                    try self.print("  ... and {d} more\n", .{at_depth - shown});
                    break;
                }
                try self.print("  ", .{});
                try self.printPath(file.path);
                try self.print("\n", .{});
                shown += 1;
            }
        }
        if (importing.truncated) try self.print("... importer list stopped at {d} files\n", .{max_impact_files});
        try self.sitesNotes(sites);
    }

    fn countSection(self: Search, title: []const u8, unit: []const u8, files: []const FileCount) error{OutOfMemory}!void {
        if (files.len == 0) return;
        try self.print("{s}:\n", .{title});
        for (files, 0..) |file, index| {
            if (index == impact_section_lines) {
                try self.print("  ... and {d} more\n", .{files.len - index});
                break;
            }
            try self.print("  ", .{});
            try self.printPath(file.path);
            try self.print(" ({d} {s})\n", .{ file.count, unit });
        }
    }

    fn sitesOf(self: Search, name: []const u8) tool_dispatch.DispatchError!?Sites {
        const io = io_mod.getIo();
        var root_dir = std.Io.Dir.openDirAbsolute(io, self.absolute_root, .{}) catch |err| {
            try self.print("Unable to open search root: {s} ({s})\n", .{ self.absolute_root, @errorName(err) });
            return null;
        };
        defer root_dir.close(io);
        const candidates = try self.lease.index.filesMentioning(self.arena, name);
        const limits: ranked_search.Limits = .{ .deadline_ms = io_mod.awakeMilliTimestamp() + scan_budget_ms, .cancel = self.ctx.cancel_flag };
        return try collectSites(self.arena, self.ctx.scratch_allocator, root_dir, candidates, name, limits, false);
    }

    fn sitesNotes(self: Search, sites: Sites) error{OutOfMemory}!void {
        if (sites.capped) try self.print("... site collection cap reached at {d} sites before every candidate file was scanned\n", .{site_collection_cap});
        if (sites.partial) try self.print("... scan stopped at the {d} ms budget; results are partial\n", .{scan_budget_ms});
    }
};

fn hitCovers(hits: []const ranked_search.Hit, site: Site) bool {
    for (hits) |hit| {
        if (!std.mem.eql(u8, hit.path, site.path)) continue;
        if (site.line + ranked_search.window_lines > hit.line and site.line < hit.line + ranked_search.window_lines) return true;
    }
    return false;
}

fn readText(alloc: Allocator, root_dir: std.Io.Dir, path: []const u8) Allocator.Error!?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(root_dir, path, .no_follow) catch return null;
    defer file.close(io_mod.getIo());
    const content = io_mod.readFileToEnd(alloc, &file, ranked_search.max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!text_utils.isModelSafeText(content)) {
        alloc.free(content);
        return null;
    }
    return content;
}

fn collectSites(
    arena: Allocator,
    scratch: Allocator,
    root_dir: std.Io.Dir,
    paths: []const []const u8,
    name: []const u8,
    limits: ranked_search.Limits,
    definitions_only: bool,
) Allocator.Error!Sites {
    var definitions: std.ArrayList(Site) = .empty;
    var uses: std.ArrayList(Site) = .empty;
    var partial = false;
    var capped = false;
    scan: for (paths) |path| {
        if (limits.deadline_ms != null and io_mod.awakeMilliTimestamp() >= limits.deadline_ms.?) partial = true;
        if (limits.cancel) |flag| partial = partial or flag.load(.acquire);
        if (partial) break;
        const content = try readText(scratch, root_dir, path) orelse continue;
        defer scratch.free(content);
        if (std.mem.find(u8, content, name) == null) continue;
        const language = symbol_scan.Language.ofPath(path);
        var line_number: usize = 1;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| : (line_number += 1) {
            const kind = symbol_scan.classify(line, name, language) orelse continue;
            if (definitions_only and kind != .definition) continue;
            if (definitions.items.len + uses.items.len == site_collection_cap) {
                capped = true;
                break :scan;
            }
            const site: Site = .{ .path = path, .line = line_number, .kind = kind };
            if (kind == .definition) try definitions.append(arena, site) else try uses.append(arena, site);
        }
    }
    try definitions.appendSlice(arena, uses.items);
    return .{ .items = try definitions.toOwnedSlice(arena), .partial = partial, .capped = capped };
}

fn fileCounts(arena: Allocator, sites: []const Site, definitions: bool) Allocator.Error![]const FileCount {
    var files: std.ArrayList(FileCount) = .empty;
    for (sites) |site| {
        if ((site.kind == .definition) != definitions) continue;
        if (files.items.len > 0 and std.mem.eql(u8, files.items[files.items.len - 1].path, site.path)) {
            files.items[files.items.len - 1].count += 1;
            continue;
        }
        try files.append(arena, .{ .path = site.path, .count = 1 });
    }
    return files.toOwnedSlice(arena);
}

const TestWorkspace = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !TestWorkspace {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".") };
    }

    fn deinit(self: *TestWorkspace) void {
        ranked_search.dropCachedIndexes();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn file(self: *TestWorkspace, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn run(self: *TestWorkspace, input: Call) ![]u8 {
        const alloc = std.testing.allocator;
        const ctx: tool_dispatch.DispatchContext = .{
            .allocator = alloc,
            .workspace_root = self.root,
            .scratch_allocator = alloc,
        };
        var owned_input = input;
        owned_input.index_allocator = alloc;
        const result = try call(ctx, owned_input);
        return switch (result) {
            .success => |body| body,
            else => {
                result.deinit(alloc);
                return error.TestUnexpectedResult;
            },
        };
    }

    fn fixture(self: *TestWorkspace) !void {
        try self.file("src/retry.zig",
            \\const clock = @import("clock.zig");
            \\
            \\pub fn parseRetryAfter(header: []const u8) u64 {
            \\    return clock.nowMs() + header.len;
            \\}
            \\
        );
        try self.file("src/clock.zig",
            \\pub fn nowMs() u64 {
            \\    return 0;
            \\}
            \\
        );
        try self.file("src/client.zig",
            \\const retry = @import("retry.zig");
            \\
            \\pub fn waitFor(header: []const u8) u64 {
            \\    return retry.parseRetryAfter(header);
            \\}
            \\
        );
        try self.file("src/main.zig",
            \\const client = @import("client.zig");
            \\
            \\pub fn main() void {
            \\    _ = client.waitFor("3");
            \\}
            \\
        );
        try self.file("web/app.py",
            \\from web.util import load_settings
            \\
            \\def start():
            \\    return load_settings("app")
            \\
        );
        try self.file("web/util.py",
            \\def load_settings(name):
            \\    return {"name": name}
            \\
        );
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack });
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn parseArgs(alloc: Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "code search decodes the ranked, callers and impact modes and leaves the text modes alone" {
    const alloc = std.testing.allocator;
    const plain = try parseArgs(alloc, "{\"pattern\":\"x\",\"mode\":\"count\"}");
    defer plain.deinit();
    try std.testing.expect((try decodeRequest(alloc, plain.value.object)) == .none);

    const ranked = try parseArgs(alloc, "{\"pattern\":\"x\",\"mode\":\"ranked\",\"k\":80,\"closure\":true,\"scope\":\"notes\"}");
    defer ranked.deinit();
    const request = (try decodeRequest(alloc, ranked.value.object)).request;
    try std.testing.expectEqual(Mode.ranked, request.mode);
    try std.testing.expectEqual(ranked_search.max_k, request.k);
    try std.testing.expect(request.closure);
    try std.testing.expectEqual(Scope.notes, request.scope);

    for ([_][]const u8{
        "{\"pattern\":\"x\",\"mode\":\"ranked\",\"k\":0}",
        "{\"pattern\":\"x\",\"mode\":\"callers\",\"closure\":true}",
        "{\"pattern\":\"x\",\"mode\":\"impact\",\"scope\":\"notes\"}",
        "{\"pattern\":\"x\",\"mode\":\"ranked\",\"scope\":\"web\"}",
    }) |json| {
        const parsed = try parseArgs(alloc, json);
        defer parsed.deinit();
        const decoded = try decodeRequest(alloc, parsed.value.object);
        try std.testing.expect(decoded == .failure);
        alloc.free(decoded.failure);
    }
}

test "code search ranked mode finds a function from a description as path:line: excerpt" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const body = try workspace.run(.{ .request = .{ .mode = .ranked }, .query = "parse the retry after header" });
    defer std.testing.allocator.free(body);
    try expectContains(body, "[ranked] ");
    try expectContains(body, "src/retry.zig:3: pub fn parseRetryAfter(header: []const u8) u64 {\n");
    try std.testing.expect(std.mem.find(u8, body, "index incomplete") == null);

    const none = try workspace.run(.{ .request = .{ .mode = .ranked }, .query = "kubernetes" });
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("[ranked] no results for kubernetes\n", none);
}

test "code search ranked mode says when the index is incomplete" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const body = try workspace.run(.{ .request = .{ .mode = .ranked }, .query = "retry", .budget_ms = -1 });
    defer std.testing.allocator.free(body);
    try expectContains(body, "... index incomplete: 0 of 6 files indexed");
}

test "code search closure adds the files that define functions called from the top results" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const body = try workspace.run(.{ .request = .{ .mode = .ranked, .closure = true, .k = 3 }, .query = "parse the retry after header" });
    defer std.testing.allocator.free(body);
    try expectContains(body, "closure: definitions of functions the top results call\n");
    try expectContains(body, "src/clock.zig:1 defines nowMs\n");
}

test "code search callers lists definitions first, then calls and member calls, in pages" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const body = try workspace.run(.{ .request = .{ .mode = .callers }, .query = "parseRetryAfter" });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        \\[callers] 2 sites for parseRetryAfter (1 definitions, 0 calls, 1 member calls)
        \\src/retry.zig:3 [definition]
        \\src/client.zig:4 [member]
        \\
    , body);

    const paged = try workspace.run(.{ .request = .{ .mode = .callers }, .query = "parseRetryAfter", .head_limit = 1 });
    defer std.testing.allocator.free(paged);
    try expectContains(paged, "showing 1-1\nsrc/retry.zig:3 [definition]\n... more sites available; use offset 1 to continue\n");

    const python = try workspace.run(.{ .request = .{ .mode = .callers }, .query = "load_settings" });
    defer std.testing.allocator.free(python);
    try expectContains(python, "web/util.py:1 [definition]\nweb/app.py:4 [call]\n");

    const absent = try workspace.run(.{ .request = .{ .mode = .callers }, .query = "neverDefined" });
    defer std.testing.allocator.free(absent);
    try std.testing.expectEqualStrings("[callers] no definitions or call sites for neverDefined\n", absent);
}

test "code search impact lists defining files, calling files and importers by depth" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const body = try workspace.run(.{ .request = .{ .mode = .impact }, .query = "parseRetryAfter" });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        \\[impact] parseRetryAfter: 1 defining files, 1 calling files, 2 importing files to depth 3
        \\defines:
        \\  src/retry.zig (1 definitions)
        \\calls:
        \\  src/client.zig (1 call sites)
        \\imports the defining files (depth 1): 1 files
        \\  src/client.zig
        \\imports the defining files (depth 2): 1 files
        \\  src/main.zig
        \\
    , body);

    const python = try workspace.run(.{ .request = .{ .mode = .impact }, .query = "load_settings" });
    defer std.testing.allocator.free(python);
    try expectContains(python, "imports the defining files (depth 1): 1 files\n  web/app.py\n");
}

test "code search refuses a non-identifier for callers and searches a subdirectory with its prefix" {
    var workspace = try TestWorkspace.init();
    defer workspace.deinit();
    try workspace.fixture();
    const alloc = std.testing.allocator;
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .workspace_root = workspace.root, .scratch_allocator = alloc };
    const refused = try call(ctx, .{ .request = .{ .mode = .callers }, .query = "parse retry", .index_allocator = alloc });
    defer refused.deinit(alloc);
    try expectContains(refused.failure, "needs one identifier");

    const scoped = try workspace.run(.{ .request = .{ .mode = .callers }, .query = "load_settings", .path = "web" });
    defer alloc.free(scoped);
    try expectContains(scoped, "web/util.py:1 [definition]\n");

    const notes = try workspace.run(.{ .request = .{ .mode = .ranked, .scope = .notes }, .query = "anything" });
    defer alloc.free(notes);
    try std.testing.expectEqualStrings("[ranked] no notes yet under .fx/notes\n", notes);
}
