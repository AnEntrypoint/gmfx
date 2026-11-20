const std = @import("std");
const skill_contract = @import("skill_contract.zig");

const Allocator = std.mem.Allocator;

pub const PluginInstructions = struct {
    plugin_id: []const u8,
    text: []const u8,
};

pub const Context = struct {
    skill_dir: []const u8 = "",
    session_id: []const u8 = "",
    plugin: ?PluginInstructions = null,
};

const block_open = "<skill_content ";
const block_close = "\n</skill_content>";
const all_arguments_name = "ARGUMENTS";

pub fn skillDirectory(skill: skill_contract.Skill) []const u8 {
    return switch (skill.form) {
        .directory => skill.path,
        .flat_file => std.Io.Dir.path.dirname(skill.path) orelse skill.path,
    };
}

pub fn tokenize(alloc: Allocator, raw: []const u8) Allocator.Error![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer {
        for (tokens.items) |token| alloc.free(token);
        tokens.deinit(alloc);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);
    var quote: ?u8 = null;
    var has_content = false;
    for (raw) |byte| {
        if (quote) |active| {
            if (byte == active) {
                quote = null;
            } else {
                try current.append(alloc, byte);
            }
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            has_content = true;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            if (has_content) {
                try appendToken(alloc, &tokens, current.items);
                current.clearRetainingCapacity();
                has_content = false;
            }
            continue;
        }
        try current.append(alloc, byte);
        has_content = true;
    }
    if (has_content) try appendToken(alloc, &tokens, current.items);
    return tokens.toOwnedSlice(alloc);
}

fn appendToken(alloc: Allocator, tokens: *std.ArrayList([]u8), text: []const u8) Allocator.Error!void {
    const owned = try alloc.dupe(u8, text);
    tokens.append(alloc, owned) catch |err| {
        alloc.free(owned);
        return err;
    };
}

pub fn freeTokens(alloc: Allocator, tokens: [][]u8) void {
    for (tokens) |token| alloc.free(token);
    alloc.free(tokens);
}

pub fn expand(
    alloc: Allocator,
    body: []const u8,
    raw_args: []const u8,
    declared_arguments: []const u8,
    context: Context,
) Allocator.Error![]u8 {
    const tokens = try tokenize(alloc, raw_args);
    defer freeTokens(alloc, tokens);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var argument_placeholder_seen = false;
    var index: usize = 0;
    while (index < body.len) {
        if (body[index] != '$') {
            try out.append(alloc, body[index]);
            index += 1;
            continue;
        }
        const rest = body[index..];
        if (environmentPlaceholder(rest, context)) |match| {
            try out.appendSlice(alloc, match.value);
            index += match.len;
            continue;
        }
        if (argumentPlaceholder(rest, tokens, raw_args, declared_arguments)) |match| {
            try appendEscaped(alloc, &out, match.value);
            argument_placeholder_seen = true;
            index += match.len;
            continue;
        }
        try out.append(alloc, '$');
        index += 1;
    }
    if (!argument_placeholder_seen and raw_args.len > 0) {
        try out.appendSlice(alloc, "\n\nARGUMENTS: ");
        try appendEscaped(alloc, &out, raw_args);
    }
    return out.toOwnedSlice(alloc);
}

pub fn expandLoadedBlock(
    alloc: Allocator,
    model_output: []const u8,
    raw_args: []const u8,
    context: Context,
) Allocator.Error![]u8 {
    const inner = loadedBlockInner(model_output) orelse {
        if (raw_args.len == 0) return alloc.dupe(u8, model_output);
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(alloc);
        try plain.appendSlice(alloc, model_output);
        try plain.appendSlice(alloc, "\n\nARGUMENTS: ");
        try appendEscaped(alloc, &plain, raw_args);
        return plain.toOwnedSlice(alloc);
    };
    const body = model_output[inner.start..inner.end];
    const expanded = try expand(alloc, body, raw_args, skill_contract.parseSkillFile(body).declared_arguments, context);
    defer alloc.free(expanded);
    const framed = if (context.plugin) |plugin| try withPluginInstructions(alloc, plugin, expanded) else null;
    defer if (framed) |text| alloc.free(text);
    return std.mem.concat(alloc, u8, &.{ model_output[0..inner.start], framed orelse expanded, model_output[inner.end..] });
}

fn withPluginInstructions(alloc: Allocator, plugin: PluginInstructions, content: []const u8) Allocator.Error![]u8 {
    if (std.mem.trim(u8, plugin.text, " \t\r\n").len == 0) return alloc.dupe(u8, content);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "<plugin-instructions plugin=\"");
    try appendAttributeEscaped(alloc, &out, plugin.plugin_id);
    try out.appendSlice(alloc, "\">\n");
    try out.appendSlice(alloc, plugin.text);
    try out.appendSlice(alloc, "\n</plugin-instructions>\n\n");
    try out.appendSlice(alloc, content);
    return out.toOwnedSlice(alloc);
}

fn appendAttributeEscaped(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| switch (byte) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        else => try out.append(alloc, byte),
    };
}

const BlockInner = struct {
    start: usize,
    end: usize,
};

fn loadedBlockInner(model_output: []const u8) ?BlockInner {
    const open = std.mem.find(u8, model_output, block_open) orelse return null;
    const open_line_end = std.mem.findScalar(u8, model_output[open..], '\n') orelse return null;
    const start = open + open_line_end + 1;
    const end = std.mem.findLast(u8, model_output, block_close) orelse return null;
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

const Placeholder = struct {
    len: usize,
    value: []const u8,
};

fn environmentPlaceholder(rest: []const u8, context: Context) ?Placeholder {
    const Variable = struct { text: []const u8, session: bool };
    const variables = [_]Variable{
        .{ .text = "${FX_SKILL_DIR}", .session = false },
        .{ .text = "${KIMI_SKILL_DIR}", .session = false },
        .{ .text = "${CLAUDE_SKILL_DIR}", .session = false },
        .{ .text = "${FX_SESSION_ID}", .session = true },
        .{ .text = "${KIMI_SESSION_ID}", .session = true },
        .{ .text = "${CLAUDE_SESSION_ID}", .session = true },
    };
    for (variables) |variable| {
        if (!std.mem.startsWith(u8, rest, variable.text)) continue;
        return .{
            .len = variable.text.len,
            .value = if (variable.session) context.session_id else context.skill_dir,
        };
    }
    return null;
}

fn argumentPlaceholder(
    rest: []const u8,
    tokens: []const []u8,
    raw_args: []const u8,
    declared_arguments: []const u8,
) ?Placeholder {
    const after = rest[1..];
    var names = skill_contract.argumentNames(declared_arguments);
    var position: usize = 0;
    while (names.next()) |name| : (position += 1) {
        if (!std.mem.startsWith(u8, after, name)) continue;
        if (after.len > name.len and (after[name.len] == '[' or isWordByte(after[name.len]))) continue;
        return .{ .len = 1 + name.len, .value = tokenAt(tokens, position) };
    }
    if (std.mem.startsWith(u8, after, all_arguments_name)) {
        const tail = after[all_arguments_name.len..];
        if (tail.len > 0 and tail[0] == '[') {
            const digits = leadingDigitCount(tail[1..]);
            if (digits > 0 and tail.len > 1 + digits and tail[1 + digits] == ']') {
                return .{
                    .len = 1 + all_arguments_name.len + digits + 2,
                    .value = tokenAt(tokens, tokenIndex(tail[1 .. 1 + digits])),
                };
            }
        }
        return .{ .len = 1 + all_arguments_name.len, .value = raw_args };
    }
    const digits = leadingDigitCount(after);
    if (digits > 0 and (after.len == digits or !isWordByte(after[digits]))) {
        return .{ .len = 1 + digits, .value = tokenAt(tokens, tokenIndex(after[0..digits])) };
    }
    return null;
}

fn tokenAt(tokens: []const []u8, position: usize) []const u8 {
    return if (position < tokens.len) tokens[position] else "";
}

fn tokenIndex(digits: []const u8) usize {
    return std.fmt.parseInt(usize, digits, 10) catch std.math.maxInt(usize);
}

fn leadingDigitCount(text: []const u8) usize {
    var count: usize = 0;
    while (count < text.len and std.ascii.isDigit(text[count])) : (count += 1) {}
    return count;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn appendEscaped(alloc: Allocator, out: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    for (value) |byte| switch (byte) {
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        else => try out.append(alloc, byte),
    };
}

fn expectExpansion(expected: []const u8, body: []const u8, raw_args: []const u8, declared_arguments: []const u8) !void {
    const alloc = std.testing.allocator;
    const expanded = try expand(alloc, body, raw_args, declared_arguments, .{ .skill_dir = "/skills/deploy", .session_id = "session-7" });
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "skill arguments split on whitespace and keep quoted groups as one token" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "  -m \"fix bug\" 'a b'c \"\" last ");
    defer freeTokens(alloc, tokens);
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualStrings("-m", tokens[0]);
    try std.testing.expectEqualStrings("fix bug", tokens[1]);
    try std.testing.expectEqualStrings("a bc", tokens[2]);
    try std.testing.expectEqualStrings("", tokens[3]);
    try std.testing.expectEqualStrings("last", tokens[4]);

    const none = try tokenize(alloc, " \t\n");
    defer freeTokens(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "skill placeholders expand named, indexed and whole arguments" {
    try expectExpansion("fix 12 on main; all: 12 main", "fix $issue on $branch; all: $ARGUMENTS", "12 main", "issue branch");
    try expectExpansion("first=12 second=main third=", "first=$ARGUMENTS[0] second=$1 third=$2", "12 main", "");
    try expectExpansion("$issues stays, $issue[0] stays, 12 goes", "$issues stays, $issue[0] stays, $issue goes", "12", "[issue]");
    try expectExpansion("$1x stays and costs $ stay", "$1x stays and costs $ stay", "", "");
    try expectExpansion("quoted: fix bug", "quoted: $0", "\"fix bug\" rest", "");
}

test "skill placeholders expand the skill directory and session id without counting as arguments" {
    try expectExpansion(
        "read /skills/deploy/ref.md and /skills/deploy/b.md and /skills/deploy/c.md in session-7 session-7 session-7\n\nARGUMENTS: now",
        "read ${FX_SKILL_DIR}/ref.md and ${KIMI_SKILL_DIR}/b.md and ${CLAUDE_SKILL_DIR}/c.md in ${FX_SESSION_ID} ${KIMI_SESSION_ID} ${CLAUDE_SESSION_ID}",
        "now",
        "",
    );
    try expectExpansion("${OTHER} stays", "${OTHER} stays", "", "");
}

test "skill arguments without a placeholder are appended and angle brackets are escaped" {
    try expectExpansion("Do the work.\n\nARGUMENTS: -m &lt;tag&gt;", "Do the work.", "-m <tag>", "");
    try expectExpansion("Do the work.", "Do the work.", "", "");
    try expectExpansion("use &lt;b&gt;", "use $ARGUMENTS", "<b>", "");
}

test "a loaded skill block keeps its wrapper and expands only the skill text" {
    const alloc = std.testing.allocator;
    const loaded = "<skill_content name=\"deploy\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"80\">\n" ++
        "---\nname: deploy\ndescription: ships\narguments: [target]\n---\nShip $target from ${FX_SKILL_DIR}." ++
        "\n</skill_content>";
    const expanded = try expandLoadedBlock(alloc, loaded, "prod extra", .{ .skill_dir = "/skills/deploy" });
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings(
        "<skill_content name=\"deploy\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"80\">\n" ++
            "---\nname: deploy\ndescription: ships\narguments: [target]\n---\nShip prod from /skills/deploy." ++
            "\n</skill_content>",
        expanded,
    );

    const plain = try expandLoadedBlock(alloc, "no block here", "arg", .{});
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("no block here\n\nARGUMENTS: arg", plain);

    const unchanged = try expandLoadedBlock(alloc, "no block here", "", .{});
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings("no block here", unchanged);
}

test "plugin instructions frame the skill body inside its wrapper and stay out of expansion" {
    const alloc = std.testing.allocator;
    const loaded = "<skill_content name=\"deploy\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"20\">\n" ++
        "Ship it.\n</skill_content>";
    const framed = try expandLoadedBlock(alloc, loaded, "", .{
        .skill_dir = "/skills/deploy",
        .plugin = .{ .plugin_id = "kit&co", .text = "Use <kit> tools." },
    });
    defer alloc.free(framed);
    try std.testing.expectEqualStrings(
        "<skill_content name=\"deploy\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"20\">\n" ++
            "<plugin-instructions plugin=\"kit&amp;co\">\nUse <kit> tools.\n</plugin-instructions>\n\n" ++
            "Ship it.\n</skill_content>",
        framed,
    );

    const blank = try expandLoadedBlock(alloc, loaded, "", .{ .plugin = .{ .plugin_id = "kit", .text = " \n" } });
    defer alloc.free(blank);
    try std.testing.expectEqualStrings(
        "<skill_content name=\"deploy\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"20\">\nShip it.\n</skill_content>",
        blank,
    );
}

test "skill directory is the folder that holds the skill file" {
    try std.testing.expectEqualStrings("/skills/deploy", skillDirectory(.{ .name = "deploy", .description = "", .path = "/skills/deploy", .source = .workspace_fx }));
    try std.testing.expectEqualStrings("/skills", skillDirectory(.{ .name = "flat", .description = "", .path = "/skills/flat.md", .source = .workspace_fx, .form = .flat_file }));
}
