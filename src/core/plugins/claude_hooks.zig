const std = @import("std");
const external = @import("../hooks/external.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_hooks_path = "hooks/hooks.json";
pub const plugin_root_placeholder = "${CLAUDE_PLUGIN_ROOT}";
const wrapper_key = "hooks";
const command_handler_type = "command";

pub const Parsed = struct {
    definitions: []const external.Definition = &.{},
    skipped: []const []const u8 = &.{},
};

const Collector = struct {
    arena: Allocator,
    plugin_root: []const u8,
    definitions: std.ArrayList(external.Definition) = .empty,
    skipped: std.ArrayList([]const u8) = .empty,

    fn skip(self: *Collector, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.skipped.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn finish(self: *Collector) Allocator.Error!Parsed {
        return .{
            .definitions = try self.definitions.toOwnedSlice(self.arena),
            .skipped = try self.skipped.toOwnedSlice(self.arena),
        };
    }

    fn appendEvent(self: *Collector, event_name: []const u8, groups: Value) Allocator.Error!void {
        const event = std.meta.stringToEnum(external.Event, event_name) orelse {
            try self.skip("hook event \"{s}\" is not supported", .{event_name});
            return;
        };
        if (groups != .array) {
            try self.skip("hook event \"{s}\" must hold an array of matcher groups", .{event_name});
            return;
        }
        for (groups.array.items) |group| try self.appendGroup(event, event_name, group);
    }

    fn appendGroup(self: *Collector, event: external.Event, event_name: []const u8, group: Value) Allocator.Error!void {
        if (group != .object) {
            try self.skip("hook event \"{s}\" has a matcher group that is not an object", .{event_name});
            return;
        }
        const matcher = stringField(group.object, "matcher");
        const handlers = group.object.get(wrapper_key) orelse {
            try self.skip("hook event \"{s}\" has a matcher group without a hooks array", .{event_name});
            return;
        };
        if (handlers != .array) {
            try self.skip("hook event \"{s}\" has a matcher group whose hooks is not an array", .{event_name});
            return;
        }
        for (handlers.array.items) |handler| try self.appendHandler(event, event_name, matcher, handler);
    }

    fn appendHandler(self: *Collector, event: external.Event, event_name: []const u8, matcher: ?[]const u8, handler: Value) Allocator.Error!void {
        if (handler != .object) {
            try self.skip("hook event \"{s}\" has a handler that is not an object", .{event_name});
            return;
        }
        if (stringField(handler.object, "type")) |handler_type| {
            if (!std.mem.eql(u8, handler_type, command_handler_type)) {
                try self.skip("hook event \"{s}\" has a \"{s}\" handler; only command handlers run", .{ event_name, handler_type });
                return;
            }
        }
        const command_text = stringField(handler.object, "command") orelse {
            try self.skip("hook event \"{s}\" has a command handler without a command", .{event_name});
            return;
        };
        if (command_text.len == 0) {
            try self.skip("hook event \"{s}\" has a command handler with an empty command", .{event_name});
            return;
        }
        try self.definitions.append(self.arena, .{
            .event = event,
            .matcher = if (matcher) |text| try self.arena.dupe(u8, text) else null,
            .command = try std.mem.replaceOwned(u8, self.arena, command_text, plugin_root_placeholder, self.plugin_root),
            .timeout_seconds = timeoutSeconds(handler.object.get("timeout")),
            .cwd = try self.arena.dupe(u8, self.plugin_root),
            .dialect = .claude,
        });
    }
};

pub fn parse(arena: Allocator, value: Value, plugin_root: []const u8) Allocator.Error!Parsed {
    var collector: Collector = .{ .arena = arena, .plugin_root = plugin_root };
    if (value != .object) {
        try collector.skip("a hooks configuration must be an object keyed by event name", .{});
        return collector.finish();
    }
    const events = eventsObject(value.object);
    var entries = events.iterator();
    while (entries.next()) |entry| {
        try collector.appendEvent(entry.key_ptr.*, entry.value_ptr.*);
    }
    return collector.finish();
}

fn eventsObject(object: std.json.ObjectMap) std.json.ObjectMap {
    const wrapped = object.get(wrapper_key) orelse return object;
    return if (wrapped == .object) wrapped.object else object;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn timeoutSeconds(value: ?Value) u32 {
    const present = value orelse return external.default_timeout_seconds;
    if (present != .integer) return external.default_timeout_seconds;
    const clamped = std.math.clamp(present.integer, external.min_timeout_seconds, external.max_timeout_seconds);
    return @intCast(clamped);
}

fn parseText(arena: Allocator, text: []const u8, plugin_root: []const u8) !Parsed {
    const value = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    return parse(arena, value, plugin_root);
}

test "claude hooks read matcher groups under a top-level hooks key with the plugin root as cwd" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"hooks":{"PostToolUse":[{"matcher":"Write|Edit","hooks":[
        \\{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/format.sh","timeout":45},
        \\{"type":"command","command":"./lint.sh"}]}]}}
    , "/p/acme");
    try std.testing.expectEqual(@as(usize, 0), parsed.skipped.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.definitions.len);
    const first = parsed.definitions[0];
    try std.testing.expectEqual(external.Event.PostToolUse, first.event);
    try std.testing.expectEqualStrings("Write|Edit", first.matcher.?);
    try std.testing.expectEqualStrings("/p/acme/scripts/format.sh", first.command);
    try std.testing.expectEqual(@as(u32, 45), first.timeout_seconds);
    try std.testing.expectEqualStrings("/p/acme", first.cwd.?);
    try std.testing.expectEqual(external.Dialect.claude, first.dialect);
    try std.testing.expectEqual(external.default_timeout_seconds, parsed.definitions[1].timeout_seconds);
}

test "claude hooks accept an inline event map without the wrapper key and no matcher" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"SessionStart":[{"hooks":[{"command":"./start.sh","timeout":100000}]}]}
    , "/p/acme");
    try std.testing.expectEqual(@as(usize, 1), parsed.definitions.len);
    try std.testing.expectEqual(external.Event.SessionStart, parsed.definitions[0].event);
    try std.testing.expect(parsed.definitions[0].matcher == null);
    try std.testing.expectEqual(@as(u32, @intCast(external.max_timeout_seconds)), parsed.definitions[0].timeout_seconds);
}

test "claude hooks skip unknown events, non-command handlers and malformed groups with a reason each" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"hooks":{"NoSuchEvent":[],"Stop":[{"hooks":[{"type":"prompt","prompt":"check"},{"type":"command"}]},7],"PreToolUse":{}}}
    , "/p/acme");
    try std.testing.expectEqual(@as(usize, 0), parsed.definitions.len);
    try std.testing.expectEqual(@as(usize, 5), parsed.skipped.len);
    try std.testing.expect(std.mem.find(u8, parsed.skipped[0], "NoSuchEvent") != null);

    const not_object = try parseText(arena, "[]", "/p/acme");
    try std.testing.expectEqual(@as(usize, 0), not_object.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), not_object.skipped.len);
}
