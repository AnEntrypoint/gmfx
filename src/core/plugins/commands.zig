const std = @import("std");
const io_mod = @import("../shared/io.zig");
const manifest = @import("manifest.zig");
const manager = @import("manager.zig");

const Allocator = std.mem.Allocator;

pub const max_command_bytes: usize = 256 * 1024;
const description_max_bytes: usize = 240;
const arguments_placeholder = "$ARGUMENTS";
const default_description = "No description provided.";

pub const Command = struct {
    plugin_id: []const u8,
    name: []const u8,
    slash_name: []const u8,
    description: []const u8,
    body: []const u8,
    path: []const u8,
    argument_hint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    allowed_tools: []const []const u8 = &.{},
};

pub fn collect(arena: Allocator, plugins: []const manager.Plugin) ![]const Command {
    var out: std.ArrayList(Command) = .empty;
    const io = io_mod.getIo();
    for (plugins) |plugin| {
        if (!plugin.record.enabled or !plugin.isOk()) continue;
        const loaded = plugin.manifest orelse continue;
        for (loaded.commands) |entry| {
            const text = entry.content orelse (std.Io.Dir.cwd().readFileAlloc(io, entry.path, arena, .limited(max_command_bytes)) catch continue);
            try out.append(arena, try parse(arena, plugin.record.id, entry, text));
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn parse(arena: Allocator, plugin_id: []const u8, entry: manifest.Command, text: []const u8) !Command {
    const parts = splitFrontmatter(text);
    const name = frontmatterValue(parts.header, "name") orelse entry.name;
    const body = std.mem.trim(u8, parts.body, " \t\r\n");
    const description = entry.description orelse frontmatterValue(parts.header, "description") orelse try descriptionFromBody(arena, body);
    return .{
        .plugin_id = plugin_id,
        .name = name,
        .slash_name = try std.fmt.allocPrint(arena, "{s}:{s}", .{ plugin_id, name }),
        .description = description,
        .body = body,
        .path = entry.path,
        .argument_hint = entry.argument_hint orelse frontmatterValue(parts.header, "argument-hint"),
        .model = entry.model orelse frontmatterValue(parts.header, "model"),
        .allowed_tools = entry.allowed_tools,
    };
}

pub fn expand(arena: Allocator, body: []const u8, arguments: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, body, arguments_placeholder) == null) {
        if (arguments.len == 0) return body;
        return std.fmt.allocPrint(arena, "{s}\n\nARGUMENTS: {s}", .{ body, arguments });
    }
    var out: std.ArrayList(u8) = .empty;
    var rest = body;
    while (std.mem.indexOf(u8, rest, arguments_placeholder)) |index| {
        try out.appendSlice(arena, rest[0..index]);
        try out.appendSlice(arena, arguments);
        rest = rest[index + arguments_placeholder.len ..];
    }
    try out.appendSlice(arena, rest);
    return out.toOwnedSlice(arena);
}

const Frontmatter = struct {
    header: []const u8,
    body: []const u8,
};

fn splitFrontmatter(text: []const u8) Frontmatter {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return .{ .header = "", .body = text };
    if (!isFence(first)) return .{ .header = "", .body = text };
    const header_start = first.len + 1;
    var offset = header_start;
    while (lines.next()) |line| {
        if (isFence(line)) {
            return .{ .header = text[header_start..offset], .body = text[offset + line.len ..] };
        }
        offset += line.len + 1;
    }
    return .{ .header = "", .body = text };
}

fn isFence(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), "---");
}

fn frontmatterValue(header: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.mem.eql(u8, field, key)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\"'");
        return if (value.len == 0) null else value;
    }
    return null;
}

fn descriptionFromBody(arena: Allocator, body: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line.len <= description_max_bytes) return line;
        return std.fmt.allocPrint(arena, "{s}…", .{line[0 .. description_max_bytes - 1]});
    }
    return default_description;
}

test "plugin command reads frontmatter name and description" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = try parse(arena, "acme", .{ .path = "/p/commands/review.md", .name = "review" }, "---\nname: ship\ndescription: \"Ship the change\"\n---\n\nDo the thing.\n");
    try std.testing.expectEqualStrings("ship", command.name);
    try std.testing.expectEqualStrings("acme:ship", command.slash_name);
    try std.testing.expectEqualStrings("Ship the change", command.description);
    try std.testing.expectEqualStrings("Do the thing.", command.body);
    try std.testing.expectEqualStrings("/p/commands/review.md", command.path);
}

test "plugin command falls back to the file name and the first body line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = try parse(arena, "acme", .{ .path = "/p/commands/nested/check.md", .name = "nested/check" }, "\n  Check the diff.\nMore detail.");
    try std.testing.expectEqualStrings("nested/check", command.name);
    try std.testing.expectEqualStrings("acme:nested/check", command.slash_name);
    try std.testing.expectEqualStrings("Check the diff.", command.description);
    try std.testing.expectEqualStrings("Check the diff.\nMore detail.", command.body);

    const empty = try parse(arena, "acme", .{ .path = "/p/commands/none.md", .name = "none" }, "---\nname: \"\"\n---\n");
    try std.testing.expectEqualStrings("none", empty.name);
    try std.testing.expectEqualStrings("No description provided.", empty.description);
}

test "plugin command takes inline content and manifest metadata over the file and its frontmatter" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inline_commands = [_]manifest.Command{.{
        .path = "/p",
        .name = "git:sync",
        .content = "---\ndescription: From frontmatter\nargument-hint: [branch]\nmodel: haiku\n---\nSync $ARGUMENTS.",
        .description = "From the manifest",
        .model = "sonnet",
    }};
    const plugins = [_]manager.Plugin{.{
        .record = .{ .id = "acme", .root = "/p", .source = "/p" },
        .manifest = .{ .name = "acme", .id = "acme", .commands = &inline_commands },
    }};

    const collected = try collect(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqualStrings("acme:git:sync", collected[0].slash_name);
    try std.testing.expectEqualStrings("From the manifest", collected[0].description);
    try std.testing.expectEqualStrings("[branch]", collected[0].argument_hint.?);
    try std.testing.expectEqualStrings("sonnet", collected[0].model.?);
    try std.testing.expectEqualStrings("Sync $ARGUMENTS.", collected[0].body);
}

test "plugin command expands ARGUMENTS and appends arguments when no placeholder is present" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Review auth now, auth.", try expand(arena, "Review $ARGUMENTS now, $ARGUMENTS.", "auth"));
    try std.testing.expectEqualStrings("Plain\n\nARGUMENTS: x", try expand(arena, "Plain", "x"));
    try std.testing.expectEqualStrings("Plain", try expand(arena, "Plain", ""));
}

test "plugin command collection skips disabled plugins and unreadable command files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "Body text" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const present = try std.Io.Dir.path.join(arena, &.{ root, "a.md" });
    const missing = try std.Io.Dir.path.join(arena, &.{ root, "gone.md" });

    const live_commands = [_]manifest.Command{
        .{ .path = present, .name = "a" },
        .{ .path = missing, .name = "gone" },
    };
    const disabled_commands = [_]manifest.Command{.{ .path = present, .name = "a" }};
    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "acme", .root = root, .source = root },
            .manifest = .{ .name = "acme", .id = "acme", .commands = &live_commands },
        },
        .{
            .record = .{ .id = "off", .root = root, .source = root, .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .commands = &disabled_commands },
        },
    };

    const collected = try collect(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqualStrings("acme:a", collected[0].slash_name);
    try std.testing.expectEqualStrings("Body text", collected[0].body);
}
