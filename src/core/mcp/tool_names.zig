const std = @import("std");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const Allocator = std.mem.Allocator;
const collections = @import("../shared/collections.zig");
const max_mcp_tool_tags: usize = 16;
const mcp_prefix = "mcp__";
const mcp_separator = "__";
const max_mcp_name_len: usize = 64;
const hash_text_capacity = 16;

pub const Registry = struct {
    const max_aliases: usize = 64 * 1024;
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    by_identity: std.StringHashMapUnmanaged([]u8) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        var entries = self.by_identity.iterator();
        while (entries.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.by_identity.deinit(self.alloc);
        self.aliases.deinit(self.alloc);
    }

    pub fn serverName(self: *Registry, alias: []const u8) ?[]const u8 {
        const io = @import("../shared/io.zig").getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.aliases.get(alias);
    }

    pub fn name(self: *Registry, alloc: Allocator, builtins: tool_dispatch.Registry, server: []const u8, tool: []const u8) (Allocator.Error || error{McpToolNameLimitExceeded})![]u8 {
        const io = @import("../shared/io.zig").getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const identity = try self.alloc.print("{d}:{s}{s}", .{ server.len, server, tool });
        defer self.alloc.free(identity);
        if (self.by_identity.get(identity)) |existing| return alloc.dupe(u8, existing);
        if (self.by_identity.count() >= max_aliases) return error.McpToolNameLimitExceeded;
        const base = buildBaseToolName(self.alloc, server, tool) catch return error.OutOfMemory;
        defer self.alloc.free(base);
        var suffix: ?usize = null;
        while (true) {
            const candidate = try candidateWithSuffix(self.alloc, base, suffix);
            if (builtins.lookup(candidate) != null or self.aliases.contains(candidate)) {
                self.alloc.free(candidate);
                suffix = if (suffix) |value| value + 1 else 2;
                continue;
            }
            errdefer self.alloc.free(candidate);
            const owned_key = try self.alloc.dupe(u8, identity);
            errdefer self.alloc.free(owned_key);
            const result = try alloc.dupe(u8, candidate);
            errdefer alloc.free(result);
            try self.by_identity.ensureUnusedCapacity(self.alloc, 1);
            try self.aliases.ensureUnusedCapacity(self.alloc, 1);
            self.by_identity.putAssumeCapacityNoClobber(owned_key, candidate);
            const server_end = owned_key.len - tool.len;
            self.aliases.putAssumeCapacityNoClobber(candidate, owned_key[server_end - server.len .. server_end]);
            return result;
        }
    }
};

pub fn matchesServer(name: []const u8, server_name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, mcp_prefix)) return false;
    const source = if (server_name.len == 0) "server" else server_name;
    var index: usize = mcp_prefix.len;
    var previous: u8 = 0;
    for (source, 0..) |_, position| {
        const normalized = serverSegmentByte(source, position);
        if (normalized == '_' and previous == '_') continue;
        if (index >= name.len or name[index] != normalized) return false;
        index += 1;
        previous = normalized;
    }
    const rest = name[index..];
    if (std.mem.startsWith(u8, rest, mcp_separator)) return rest.len > mcp_separator.len;
    return name.len == max_mcp_name_len and rest.len > 0 and rest[0] == '_';
}

fn sanitizedByte(byte: u8) u8 {
    return if (isIdentifierByte(byte)) byte else '_';
}

const plugin_server_prefix = "plugin-";

fn isPluginServerName(server_name: []const u8) bool {
    if (!std.mem.startsWith(u8, server_name, plugin_server_prefix)) return false;
    return std.mem.findScalar(u8, server_name[plugin_server_prefix.len..], ':') != null;
}

fn serverSegmentByte(server_name: []const u8, position: usize) u8 {
    if (position == plugin_server_prefix.len - 1 and isPluginServerName(server_name)) return '_';
    return sanitizedByte(server_name[position]);
}

fn writeServerSegment(writer: *std.Io.Writer, server_name: []const u8) !void {
    var previous: u8 = 0;
    for (server_name, 0..) |_, position| {
        const normalized = serverSegmentByte(server_name, position);
        if (normalized == '_' and previous == '_') continue;
        try writer.writeByte(normalized);
        previous = normalized;
    }
}

test "plugin MCP servers name their tools mcp__plugin_<plugin>_<server>__<tool>" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();
    const plugin_tool = try registry.name(alloc, .{}, "plugin-acme:docs.site", "read file");
    defer alloc.free(plugin_tool);
    try std.testing.expectEqualStrings("mcp__plugin_acme_docs_site__read_file", plugin_tool);
    try std.testing.expect(matchesServer(plugin_tool, "plugin-acme:docs.site"));
    try std.testing.expect(!matchesServer("mcp__plugin-acme_docs_site__read_file", "plugin-acme:docs.site"));
    const dashed = try registry.name(alloc, .{}, "plugin-tools", "run");
    defer alloc.free(dashed);
    try std.testing.expectEqualStrings("mcp__plugin-tools__run", dashed);
}

fn buildBaseToolName(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll(mcp_prefix);
    try writeServerSegment(&out.writer, if (server_name.len == 0) "server" else server_name);
    try out.writer.writeAll(mcp_separator);
    try writeSanitizedSegment(&out.writer, if (tool_name.len == 0) "tool" else tool_name);

    const full = try out.toOwnedSlice();
    if (full.len <= max_mcp_name_len) return full;
    defer alloc.free(full);
    var hash_buf: [hash_text_capacity]u8 = undefined;
    const hash = stableHashText(&hash_buf, full);
    return alloc.print("{s}_{s}", .{ full[0 .. max_mcp_name_len - hash.len - 1], hash });
}

fn writeSanitizedSegment(writer: *std.Io.Writer, segment: []const u8) !void {
    var previous: u8 = 0;
    for (segment) |byte| {
        const normalized = sanitizedByte(byte);
        if (normalized == '_' and previous == '_') continue;
        try writer.writeByte(normalized);
        previous = normalized;
    }
}

fn stableHashText(buf: *[hash_text_capacity]u8, input: []const u8) []const u8 {
    var hash: u32 = 0x811c9dc5;
    for (input) |byte| {
        hash ^= @as(u32, byte);
        hash *%= 0x01000193;
    }
    const negative = @as(i32, @bitCast(hash)) < 0;
    const magnitude: u32 = if (negative) 0 -% hash else hash;
    var digits: [hash_text_capacity]u8 = undefined;
    const body = std.fmt.bufPrint(&digits, "{s}{x}", .{ if (negative) "-" else "", magnitude }) catch unreachable;
    return std.fmt.bufPrint(buf, "{s:0>8}", .{body}) catch unreachable;
}

fn candidateWithSuffix(alloc: Allocator, base: []const u8, suffix_index: ?usize) ![]u8 {
    const max_name_len = 64;
    if (suffix_index) |index| {
        const suffix = try alloc.print("_{d}", .{index});
        defer alloc.free(suffix);

        const prefix_len = @min(base.len, max_name_len - suffix.len);
        return alloc.print("{s}{s}", .{ base[0..prefix_len], suffix });
    }

    return alloc.dupe(u8, base[0..@min(base.len, max_name_len)]);
}

test "MCP tool names use the mcp__ prefix, collapse underscores, and hash long names" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();
    const plain = try registry.name(alloc, .{}, "web", "read..file");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("mcp__web__read_file", plain);
    const long = try registry.name(alloc, .{}, "server", &@as([80]u8, @splat('x')));
    defer alloc.free(long);
    try std.testing.expectEqual(max_mcp_name_len, long.len);
    try std.testing.expect(std.mem.startsWith(u8, long, "mcp__server__xxx"));
    try std.testing.expect(matchesServer(long, "server"));
}

test "matchesServer recognises the server segment of mcp__ names" {
    try std.testing.expect(matchesServer("mcp__web__read_file", "web"));
    try std.testing.expect(!matchesServer("mcp__webx__read", "web"));
    try std.testing.expect(!matchesServer("mcp_web_read", "web"));
    try std.testing.expect(!matchesServer("mcp__web__", "web"));
}

test "session tool aliases survive replacement and cannot retarget a collision" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();
    const first = try registry.name(alloc, .{}, "a/b", "c");
    defer alloc.free(first);
    const collision = try registry.name(alloc, .{}, "a_b", "c");
    defer alloc.free(collision);
    try std.testing.expect(!std.mem.eql(u8, first, collision));
    const refreshed = try registry.name(alloc, .{}, "a/b", "c");
    defer alloc.free(refreshed);
    try std.testing.expectEqualStrings(first, refreshed);
    const recovered = try registry.name(alloc, .{}, "a_b", "c");
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(collision, recovered);
}

pub fn tagsFor(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]const []u8 {
    var tags: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &tags);

    try appendTag(alloc, &tags, "mcp");
    try appendTagTokens(alloc, &tags, server_name);
    try appendTagTokens(alloc, &tags, tool_name);

    return try tags.toOwnedSlice(alloc);
}

fn appendTagTokens(alloc: Allocator, tags: *std.ArrayList([]u8), text: []const u8) !void {
    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (isIdentifierByte(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |s| {
            try appendTag(alloc, tags, text[s..index]);
            start = null;
        }
    }
    if (start) |s| try appendTag(alloc, tags, text[s..]);
}

fn appendTag(alloc: Allocator, tags: *std.ArrayList([]u8), raw: []const u8) !void {
    if (raw.len == 0 or tags.items.len >= max_mcp_tool_tags) return;

    const normalized = try std.ascii.allocLowerString(alloc, raw);
    errdefer alloc.free(normalized);
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, normalized)) {
            alloc.free(normalized);
            return;
        }
    }
    try tags.append(alloc, normalized);
}

pub fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}
