const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");

pub const ToolSet = struct {
    registry: tool_dispatch.Registry,
    order: []const []const u8,
    read_only_tool_names: []const []const u8,
};

pub const empty = ToolSet{
    .registry = .{},
    .order = &.{},
    .read_only_tool_names = &.{},
};

pub fn narrow(arena: std.mem.Allocator, base: ToolSet, keep: anytype) !?ToolSet {
    var kept: std.ArrayList(tool_dispatch.Tool) = .empty;
    for (base.registry.tools) |tool| {
        if (keep.allows(tool.name)) try kept.append(arena, tool);
    }
    if (kept.items.len == base.registry.tools.len) return null;
    var narrowed = base;
    narrowed.registry.tools = kept.items;
    narrowed.order = try keepNames(arena, base.order, keep);
    narrowed.read_only_tool_names = try keepNames(arena, base.read_only_tool_names, keep);
    return narrowed;
}

fn keepNames(arena: std.mem.Allocator, names: []const []const u8, keep: anytype) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (names) |name| if (keep.allows(name)) try kept.append(arena, name);
    return kept.items;
}

pub const NameFilter = struct {
    only: ?[]const []const u8 = null,
    except: []const []const u8 = &.{},

    pub fn allows(self: NameFilter, name: []const u8) bool {
        if (self.only) |names| if (!listed(names, name)) return false;
        return !listed(self.except, name);
    }
};

fn listed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

test "a name filter keeps the named tools and drops the excepted ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tools: [3]tool_dispatch.Tool = undefined;
    for (&tools, [_][]const u8{ "read_file", "write_file", "Agent" }) |*tool, name| tool.name = name;
    var base = empty;
    base.registry.tools = &tools;
    base.order = &.{ "read_file", "write_file", "Agent" };
    base.read_only_tool_names = &.{"read_file"};

    const only_two = (try narrow(arena, base, NameFilter{ .only = &.{ "read_file", "Agent" } })).?;
    try std.testing.expectEqual(@as(usize, 2), only_two.registry.tools.len);
    try std.testing.expect(only_two.registry.lookup("write_file") == null);

    const minus_agent = (try narrow(arena, base, NameFilter{ .except = &.{"Agent"} })).?;
    try std.testing.expectEqual(@as(usize, 2), minus_agent.order.len);
    try std.testing.expect(minus_agent.registry.lookup("Agent") == null);

    const none = (try narrow(arena, base, NameFilter{ .only = &.{} })).?;
    try std.testing.expectEqual(@as(usize, 0), none.registry.tools.len);
}

test "narrowing a tool set keeps only the allowed tools, and keeping them all changes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tools: [3]tool_dispatch.Tool = undefined;
    for (&tools, [_][]const u8{ "read_file", "write_file", "Agent" }) |*tool, name| tool.name = name;
    var base = empty;
    base.registry.tools = &tools;
    base.order = &.{ "read_file", "write_file", "Agent" };
    base.read_only_tool_names = &.{"read_file"};

    const ReadOnly = struct {
        fn allows(_: @This(), name: []const u8) bool {
            return std.mem.eql(u8, name, "read_file");
        }
    };
    const narrowed = (try narrow(arena, base, ReadOnly{})).?;
    try std.testing.expectEqual(@as(usize, 1), narrowed.registry.tools.len);
    try std.testing.expect(narrowed.registry.lookup("read_file") != null);
    try std.testing.expect(narrowed.registry.lookup("write_file") == null);
    try std.testing.expectEqual(@as(usize, 1), narrowed.order.len);
    try std.testing.expectEqual(@as(usize, 1), narrowed.read_only_tool_names.len);

    const All = struct {
        fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };
    try std.testing.expect((try narrow(arena, base, All{})) == null);
}
