const std = @import("std");

const Allocator = std.mem.Allocator;

pub const extension = ".md";

pub const Field = struct {
    key: []const u8,
    value: []const u8 = "",
    items: []const []const u8 = &.{},
};

pub const Document = struct {
    fields: []const Field = &.{},
    body: []const u8 = "",
};

const ToolAlias = struct {
    claude: []const u8,
    fx: []const u8,
};

const tool_aliases = [_]ToolAlias{
    .{ .claude = "Read", .fx = "read_file" },
    .{ .claude = "Write", .fx = "write_file" },
    .{ .claude = "Edit", .fx = "edit_file" },
    .{ .claude = "MultiEdit", .fx = "edit_file" },
    .{ .claude = "Grep", .fx = "grep_files" },
    .{ .claude = "Glob", .fx = "glob_files" },
    .{ .claude = "WebFetch", .fx = "FetchURL" },
    .{ .claude = "TodoWrite", .fx = "TodoList" },
    .{ .claude = "Task", .fx = "Agent" },
};

const Pending = struct {
    key: []const u8,
    raw: []const u8,
    items: std.ArrayList([]const u8) = .empty,
    text: std.ArrayList([]const u8) = .empty,

    fn take(self: *Pending, arena: Allocator, trimmed: []const u8) Allocator.Error!void {
        if (trimmed[0] != '-' or (trimmed.len > 1 and trimmed[1] != ' ')) {
            try self.text.append(arena, trimmed);
            return;
        }
        const item = unquote(std.mem.trim(u8, trimmed[1..], " \t"));
        if (item.len > 0) try self.items.append(arena, item);
    }

    fn finish(self: *Pending, arena: Allocator) Allocator.Error!Field {
        if (isBlockScalar(self.raw)) {
            const separator: []const u8 = if (self.raw[0] == '|') "\n" else " ";
            return .{ .key = self.key, .value = try std.mem.join(arena, separator, self.text.items) };
        }
        if (self.raw.len >= 2 and self.raw[0] == '[' and self.raw[self.raw.len - 1] == ']') {
            return .{ .key = self.key, .items = try commaSeparated(arena, self.raw[1 .. self.raw.len - 1]) };
        }
        return .{ .key = self.key, .value = unquote(self.raw), .items = self.items.items };
    }
};

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Document {
    const split = splitFrontmatter(text);
    var fields: std.ArrayList(Field) = .empty;
    var pending: ?Pending = null;
    var lines = std.mem.splitScalar(u8, split.header, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (line[0] == ' ' or line[0] == '\t' or line[0] == '-') {
            if (pending) |*open| try open.take(arena, trimmed);
            continue;
        }
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (pending) |*open| try fields.append(arena, try open.finish(arena));
        pending = .{
            .key = std.mem.trim(u8, line[0..colon], " \t"),
            .raw = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
    }
    if (pending) |*open| try fields.append(arena, try open.finish(arena));
    return .{ .fields = fields.items, .body = std.mem.trim(u8, split.body, " \t\r\n") };
}

pub fn names(arena: Allocator, field: Field) Allocator.Error![]const []const u8 {
    if (field.items.len > 0) return field.items;
    return commaSeparated(arena, field.value);
}

pub fn fxToolName(name: []const u8) []const u8 {
    const negated = name.len > 1 and name[0] == '!';
    const bare = if (negated) name[1..] else name;
    const base = if (std.mem.findScalar(u8, bare, '(')) |paren| std.mem.trim(u8, bare[0..paren], " \t") else bare;
    for (tool_aliases) |alias| {
        if (std.mem.eql(u8, alias.claude, base)) return alias.fx;
    }
    return base;
}

pub fn fxToolNames(arena: Allocator, listed: []const []const u8, refuse: bool) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, listed.len);
    for (listed, out) |name, *slot| {
        const mapped = fxToolName(name);
        const negated = refuse or (name.len > 1 and name[0] == '!');
        slot.* = if (negated) try std.fmt.allocPrint(arena, "!{s}", .{mapped}) else mapped;
    }
    return out;
}

fn commaSeparated(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        switch (byte) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                try appendName(arena, &out, text[start..index]);
                start = index + 1;
            },
            else => {},
        }
    }
    try appendName(arena, &out, text[start..]);
    return out.items;
}

fn appendName(arena: Allocator, out: *std.ArrayList([]const u8), raw: []const u8) Allocator.Error!void {
    const name = unquote(std.mem.trim(u8, raw, " \t"));
    if (name.len > 0) try out.append(arena, name);
}

fn isBlockScalar(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 2) return false;
    if (raw[0] != '|' and raw[0] != '>') return false;
    return raw.len == 1 or raw[1] == '-' or raw[1] == '+';
}

fn unquote(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    const first = text[0];
    if ((first == '"' or first == '\'') and text[text.len - 1] == first) return text[1 .. text.len - 1];
    return text;
}

const Split = struct {
    header: []const u8,
    body: []const u8,
};

fn splitFrontmatter(text: []const u8) Split {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return .{ .header = "", .body = text };
    if (!isFence(first)) return .{ .header = "", .body = text };
    const header_start = @min(first.len + 1, text.len);
    var offset = header_start;
    while (lines.next()) |line| {
        if (isFence(line)) return .{ .header = text[header_start..offset], .body = text[offset + line.len ..] };
        offset += line.len + 1;
    }
    return .{ .header = "", .body = text };
}

fn isFence(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), "---");
}

fn fieldOf(document: Document, key: []const u8) ?Field {
    for (document.fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field;
    }
    return null;
}

test "a markdown agent file splits into frontmatter fields and a body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parse(arena,
        \\---
        \\name: code-reviewer
        \\description: "Reviews code for quality"
        \\tools: Read, Grep, Bash(git diff *, git log *)
        \\# a comment
        \\disallowedTools:
        \\  - Write
        \\  - 'Edit'
        \\mcpServers: [github, "linear"]
        \\when: >-
        \\  after a change
        \\  lands
        \\model: inherit
        \\---
        \\
        \\You are a reviewer.
        \\
    );
    try std.testing.expectEqualStrings("You are a reviewer.", document.body);
    try std.testing.expectEqualStrings("code-reviewer", fieldOf(document, "name").?.value);
    try std.testing.expectEqualStrings("Reviews code for quality", fieldOf(document, "description").?.value);
    const tools = try names(arena, fieldOf(document, "tools").?);
    try std.testing.expectEqual(@as(usize, 3), tools.len);
    try std.testing.expectEqualStrings("Bash(git diff *, git log *)", tools[2]);
    const refused = try names(arena, fieldOf(document, "disallowedTools").?);
    try std.testing.expectEqual(@as(usize, 2), refused.len);
    try std.testing.expectEqualStrings("Edit", refused[1]);
    const servers = try names(arena, fieldOf(document, "mcpServers").?);
    try std.testing.expectEqualStrings("linear", servers[1]);
    try std.testing.expectEqualStrings("after a change lands", fieldOf(document, "when").?.value);
    try std.testing.expect(fieldOf(document, "missing") == null);
}

test "a markdown agent file without frontmatter is all body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try parse(arena, "Just a prompt.\n");
    try std.testing.expectEqual(@as(usize, 0), plain.fields.len);
    try std.testing.expectEqualStrings("Just a prompt.", plain.body);

    const unclosed = try parse(arena, "---\ndescription: x\n");
    try std.testing.expectEqual(@as(usize, 0), unclosed.fields.len);
}

test "Claude Code tool names map to fx tool names and keep MCP patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("read_file", fxToolName("Read"));
    try std.testing.expectEqualStrings("Bash", fxToolName("Bash(git add *)"));
    try std.testing.expectEqualStrings("FetchURL", fxToolName("WebFetch"));
    try std.testing.expectEqualStrings("mcp__github__*", fxToolName("mcp__github__*"));
    try std.testing.expectEqualStrings("Agent", fxToolName("Agent(worker, researcher)"));

    const allowed = try fxToolNames(arena, &.{ "Read", "!Write", "mcp__*" }, false);
    try std.testing.expectEqualStrings("read_file", allowed[0]);
    try std.testing.expectEqualStrings("!write_file", allowed[1]);
    try std.testing.expectEqualStrings("mcp__*", allowed[2]);
    const refused = try fxToolNames(arena, &.{ "Edit", "!Grep" }, true);
    try std.testing.expectEqualStrings("!edit_file", refused[0]);
    try std.testing.expectEqualStrings("!grep_files", refused[1]);
}
