const std = @import("std");
const plugin_commands = @import("../plugins/commands.zig");
const plugin_manager = @import("../plugins/manager.zig");

const Allocator = std.mem.Allocator;

const skill_namespace = "skill";

pub const Invocation = struct {
    slash_name: []const u8,
    arguments: []const u8,
};

pub fn invocation(text: []const u8) ?Invocation {
    if (text.len < 2 or text[0] != '/') return null;
    const token_end = std.mem.findAny(u8, text, " \t\r\n") orelse text.len;
    const slash_name = text[1..token_end];
    const colon = std.mem.findScalar(u8, slash_name, ':') orelse return null;
    const plugin_id = slash_name[0..colon];
    const command_name = slash_name[colon + 1 ..];
    if (plugin_id.len == 0 or command_name.len == 0) return null;
    if (std.mem.findScalar(u8, plugin_id, '/') != null) return null;
    if (std.ascii.eqlIgnoreCase(plugin_id, skill_namespace)) return null;
    return .{
        .slash_name = slash_name,
        .arguments = std.mem.trim(u8, text[token_end..], " \t\r\n"),
    };
}

pub fn promptAmong(arena: Allocator, commands: []const plugin_commands.Command, invoked: Invocation) !?[]const u8 {
    for (commands) |command| {
        if (!std.mem.eql(u8, command.slash_name, invoked.slash_name)) continue;
        return try plugin_commands.expand(arena, command.body, invoked.arguments);
    }
    return null;
}

pub fn promptFor(arena: Allocator, home: []const u8, text: []const u8) !?[]const u8 {
    const invoked = invocation(text) orelse return null;
    const plugins = try plugin_manager.list(arena, home);
    const commands = try plugin_commands.collect(arena, plugins);
    return promptAmong(arena, commands, invoked);
}

test "a plugin command is typed as /<plugin>:<name> with the rest as its arguments" {
    const plain = invocation("/acme:review").?;
    try std.testing.expectEqualStrings("acme:review", plain.slash_name);
    try std.testing.expectEqualStrings("", plain.arguments);

    const with_arguments = invocation("/acme:nested/check  the last commit \n").?;
    try std.testing.expectEqualStrings("acme:nested/check", with_arguments.slash_name);
    try std.testing.expectEqualStrings("the last commit", with_arguments.arguments);
}

test "paths, skill tokens, built-in commands and half names are not plugin commands" {
    try std.testing.expect(invocation("/usr/lib:foo") == null);
    try std.testing.expect(invocation("/skill:review now") == null);
    try std.testing.expect(invocation("/help") == null);
    try std.testing.expect(invocation("/acme:") == null);
    try std.testing.expect(invocation("/:review") == null);
    try std.testing.expect(invocation("acme:review") == null);
    try std.testing.expect(invocation("/") == null);
}

test "a typed plugin command from an installed plugin is expanded by promptFor" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/commands");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/kimi.plugin.json", .data = "{\"name\":\"acme\",\"commands\":\"./commands\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/commands/review.md", .data = "---\ndescription: Review the diff\n---\nReview $ARGUMENTS." });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    _ = try plugin_manager.install(arena, home, try std.Io.Dir.path.join(arena, &.{ base, "src" }), 1, .{ .trusted = true });
    try std.testing.expectEqualStrings("Review the parser.", (try promptFor(arena, home, "/acme:review the parser")) orelse "");
}

test "a typed plugin command becomes its body with the arguments filled in, and an unknown one is left alone" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const commands = [_]plugin_commands.Command{
        .{ .plugin_id = "acme", .name = "review", .slash_name = "acme:review", .description = "Review", .body = "Review $ARGUMENTS carefully.", .path = "/p/commands/review.md" },
        .{ .plugin_id = "acme", .name = "ship", .slash_name = "acme:ship", .description = "Ship", .body = "Ship it.", .path = "/p/commands/ship.md" },
    };

    const review = (try promptAmong(arena, &commands, invocation("/acme:review the parser").?)).?;
    try std.testing.expectEqualStrings("Review the parser carefully.", review);

    const ship = (try promptAmong(arena, &commands, invocation("/acme:ship now").?)).?;
    try std.testing.expectEqualStrings("Ship it.\n\nARGUMENTS: now", ship);

    try std.testing.expect((try promptAmong(arena, &commands, invocation("/acme:missing").?)) == null);
}
