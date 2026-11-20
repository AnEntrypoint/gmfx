const std = @import("std");
const types = @import("../shared/types.zig");
const skill_contract = @import("skill_contract.zig");

const Allocator = std.mem.Allocator;

pub const default_fork_agent = "general-purpose";

pub const ValueList = struct {
    inline_text: []const u8 = "",
    block_text: []const u8 = "",

    pub fn iterator(self: ValueList) Iterator {
        return .{ .inline_text = self.inline_text, .block_text = self.block_text };
    }

    pub fn isEmpty(self: ValueList) bool {
        var items = self.iterator();
        return items.next() == null;
    }

    pub const Iterator = struct {
        inline_text: []const u8,
        block_text: []const u8,
        inline_index: usize = 0,
        block_index: usize = 0,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.nextInline()) |item| return item;
            return self.nextBlock();
        }

        fn nextInline(self: *Iterator) ?[]const u8 {
            const text = self.inline_text;
            var index = self.inline_index;
            while (index < text.len and isInlineSeparator(text[index])) : (index += 1) {}
            if (index >= text.len) {
                self.inline_index = index;
                return null;
            }
            const start = index;
            var depth: usize = 0;
            var quote: ?u8 = null;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (quote) |open| {
                    if (byte == open) quote = null;
                    continue;
                }
                if (byte == '"' or byte == '\'') {
                    quote = byte;
                } else if (byte == '(') {
                    depth += 1;
                } else if (byte == ')') {
                    depth -|= 1;
                } else if (depth == 0 and isInlineSeparator(byte)) {
                    break;
                }
            }
            self.inline_index = index;
            return unquoted(text[start..index]);
        }

        fn nextBlock(self: *Iterator) ?[]const u8 {
            while (self.block_index < self.block_text.len) {
                const line = lineAt(self.block_text, self.block_index);
                self.block_index = line.next;
                const trimmed = std.mem.trim(u8, line.bytes, " \t");
                if (trimmed.len < 2 or trimmed[0] != '-') continue;
                const item = unquoted(trimmed[1..]);
                if (item.len > 0) return item;
            }
            return null;
        }
    };
};

pub const Fields = struct {
    argument_hint: ?[]const u8 = null,
    allowed_tools: ValueList = .{},
    disallowed_tools: ValueList = .{},
    paths: ValueList = .{},
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    license: ?[]const u8 = null,
    compatibility: ?[]const u8 = null,
    context_fork: bool = false,
    background: bool = true,

    pub fn forkAgent(self: Fields) []const u8 {
        return self.agent orelse default_fork_agent;
    }

    fn assign(self: *Fields, key: []const u8, value: []const u8, block: []const u8) void {
        const list: ValueList = .{
            .inline_text = withoutFlowBrackets(value),
            .block_text = if (value.len == 0) block else "",
        };
        if (keyNamed(key, "argumenthint")) {
            self.argument_hint = nonEmpty(value);
        } else if (keyNamed(key, "allowedtools")) {
            self.allowed_tools = list;
        } else if (keyNamed(key, "disallowedtools")) {
            self.disallowed_tools = list;
        } else if (keyNamed(key, "paths")) {
            self.paths = list;
        } else if (keyNamed(key, "model")) {
            self.model = nonEmpty(value);
        } else if (keyNamed(key, "effort")) {
            self.effort = nonEmpty(value);
        } else if (keyNamed(key, "agent")) {
            self.agent = nonEmpty(value);
        } else if (keyNamed(key, "shell")) {
            self.shell = nonEmpty(value);
        } else if (keyNamed(key, "license")) {
            self.license = nonEmpty(value);
        } else if (keyNamed(key, "compatibility")) {
            self.compatibility = nonEmpty(value);
        } else if (keyNamed(key, "context")) {
            self.context_fork = std.ascii.eqlIgnoreCase(value, "fork");
        } else if (keyNamed(key, "background")) {
            self.background = booleanValue(value) orelse true;
        }
    }
};

pub fn parse(content: []const u8) Fields {
    var fields: Fields = .{};
    const header = frontmatterHeader(content) orelse return fields;
    var offset: usize = 0;
    while (offset < header.len) {
        const line = lineAt(header, offset);
        offset = line.next;
        if (!startsTopLevelKey(line.bytes)) continue;
        const colon = std.mem.findScalar(u8, line.bytes, ':') orelse continue;
        const key = std.mem.trim(u8, line.bytes[0..colon], " \t");
        fields.assign(key, unquoted(line.bytes[colon + 1 ..]), blockAfter(header, offset));
    }
    return fields;
}

pub fn parseLoadedSkillContent(model_output: []const u8) Fields {
    const opening_end = std.mem.find(u8, model_output, ">\n") orelse return .{};
    return parse(model_output[opening_end + 2 ..]);
}

const Line = struct {
    bytes: []const u8,
    next: usize,
};

fn lineAt(text: []const u8, start: usize) Line {
    const newline = std.mem.findScalar(u8, text[start..], '\n');
    const end = if (newline) |offset| start + offset else text.len;
    return .{
        .bytes = std.mem.trimEnd(u8, text[start..end], "\r"),
        .next = if (newline != null) end + 1 else end,
    };
}

fn frontmatterHeader(content: []const u8) ?[]const u8 {
    const start = skill_contract.frontmatterHeaderStart(content) orelse return null;
    var offset = start;
    while (offset < content.len) {
        const line = lineAt(content, offset);
        if (std.mem.eql(u8, line.bytes, "---")) return content[start..offset];
        offset = line.next;
    }
    return null;
}

fn startsTopLevelKey(line: []const u8) bool {
    if (line.len == 0) return false;
    return switch (line[0]) {
        ' ', '\t', '#', '-' => false,
        else => true,
    };
}

fn blockAfter(header: []const u8, start: usize) []const u8 {
    var offset = start;
    while (offset < header.len) {
        const line = lineAt(header, offset);
        if (startsTopLevelKey(line.bytes)) break;
        offset = line.next;
    }
    return header[start..offset];
}

fn isInlineSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == ',';
}

fn unquoted(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == trimmed[trimmed.len - 1] and (trimmed[0] == '"' or trimmed[0] == '\'')) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn withoutFlowBrackets(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') return value[1 .. value.len - 1];
    return value;
}

fn nonEmpty(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn booleanValue(value: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    for ([_][]const u8{ "false", "no", "off" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return false;
    }
    return null;
}

fn keyNamed(key: []const u8, canonical: []const u8) bool {
    var matched: usize = 0;
    for (key) |byte| {
        if (byte == '-' or byte == '_') continue;
        if (matched >= canonical.len or std.ascii.toLower(byte) != canonical[matched]) return false;
        matched += 1;
    }
    return matched == canonical.len;
}

pub const ToolRule = struct {
    tool: []const u8,
    target: ?[]const u8 = null,

    pub fn parse(item: []const u8) ?ToolRule {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len == 0) return null;
        const open = std.mem.findScalar(u8, trimmed, '(') orelse return .{ .tool = trimmed };
        if (open == 0 or trimmed[trimmed.len - 1] != ')') return null;
        const target = std.mem.trim(u8, trimmed[open + 1 .. trimmed.len - 1], " \t");
        return .{ .tool = trimmed[0..open], .target = nonEmpty(target) };
    }

    pub fn runsShellCommands(self: ToolRule) bool {
        for ([_][]const u8{ "Bash", "run_command", "Shell" }) |name| {
            if (std.ascii.eqlIgnoreCase(self.tool, name)) return true;
        }
        return false;
    }

    fn namesOneToolFamily(self: ToolRule) bool {
        if (std.mem.startsWith(u8, self.tool, "mcp__")) return true;
        return std.mem.findAny(u8, self.tool, "*?{") == null;
    }
};

pub fn turnGrants(alloc: Allocator, allowed_tools: ValueList) Allocator.Error![]types.PermissionGrant {
    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        for (grants.items) |grant| {
            alloc.free(grant.tool_name);
            alloc.free(grant.target_path);
        }
        grants.deinit(alloc);
    }
    var items = allowed_tools.iterator();
    while (items.next()) |item| {
        const rule = ToolRule.parse(item) orelse continue;
        if (rule.runsShellCommands() or !rule.namesOneToolFamily()) continue;
        try grants.ensureUnusedCapacity(alloc, 1);
        const tool_name = try alloc.dupe(u8, rule.tool);
        errdefer alloc.free(tool_name);
        const target_path = try alloc.dupe(u8, rule.target orelse "*");
        grants.appendAssumeCapacity(.{ .tool_name = tool_name, .target_path = target_path });
    }
    return grants.toOwnedSlice(alloc);
}

pub fn writeForkDirective(writer: *std.Io.Writer, fields: Fields, skill_name: []const u8) std.Io.Writer.Error!void {
    if (!fields.context_fork) return;
    try writer.writeAll("<skill_fork>\nThis skill declares context: fork, so it runs in a subagent and not in this conversation. Call the Agent tool once with prompt set to the skill text below together with the user's request, description \"");
    try writer.writeAll(skill_name);
    try writer.writeByte('"');
    const agent = fields.forkAgent();
    if (!std.mem.eql(u8, agent, default_fork_agent)) {
        try writer.writeAll(", subagent_type \"");
        try writer.writeAll(agent);
        try writer.writeByte('"');
    }
    if (fields.model) |model| {
        if (!std.ascii.eqlIgnoreCase(model, "inherit")) {
            try writer.writeAll(", model \"");
            try writer.writeAll(model);
            try writer.writeByte('"');
        }
    }
    try writer.writeAll(if (fields.background)
        ", and run_in_background true. Do not follow the skill's steps yourself; the report arrives when the subagent ends.\n</skill_fork>\n"
    else
        ", and run_in_background false. Do not follow the skill's steps yourself; relay the report the call returns.\n</skill_fork>\n");
}

test "skill frontmatter reads the invocation fields with their defaults" {
    const defaults = parse("---\nname: plain\ndescription: plain skill\n---\nbody\n");
    try std.testing.expect(!defaults.context_fork);
    try std.testing.expect(defaults.background);
    try std.testing.expect(defaults.allowed_tools.isEmpty());
    try std.testing.expectEqualStrings(default_fork_agent, defaults.forkAgent());
    try std.testing.expect(defaults.argument_hint == null);

    const fields = parse(
        "---\r\nname: deploy\r\ndescription: Ship it\r\nwhen_to_use: \"After a release is cut\"\r\nargument-hint: [environment]\r\n" ++
            "arguments: environment region\r\ndisable-model-invocation: true\r\nuser-invocable: false\r\n" ++
            "allowed-tools: Read, Bash(git add *), mcp__github__create_issue\r\ndisallowed-tools:\r\n  - Write\r\n  - \"Edit\"\r\n" ++
            "model: sonnet\r\neffort: high\r\ncontext: fork\r\nagent: Explore\r\nbackground: false\r\npaths: [src/**, docs/**]\r\n" ++
            "shell: bash\r\nlicense: MIT\r\ncompatibility: fx 1.0\r\nmetadata:\r\n  owner: team\r\n---\r\nbody\r\n",
    );
    try std.testing.expectEqualStrings("[environment]", fields.argument_hint.?);
    try std.testing.expect(fields.context_fork);
    try std.testing.expect(!fields.background);
    try std.testing.expectEqualStrings("Explore", fields.forkAgent());
    try std.testing.expectEqualStrings("sonnet", fields.model.?);
    try std.testing.expectEqualStrings("high", fields.effort.?);
    try std.testing.expectEqualStrings("bash", fields.shell.?);
    try std.testing.expectEqualStrings("MIT", fields.license.?);
    try std.testing.expectEqualStrings("fx 1.0", fields.compatibility.?);

    var allowed = fields.allowed_tools.iterator();
    try std.testing.expectEqualStrings("Read", allowed.next().?);
    try std.testing.expectEqualStrings("Bash(git add *)", allowed.next().?);
    try std.testing.expectEqualStrings("mcp__github__create_issue", allowed.next().?);
    try std.testing.expect(allowed.next() == null);

    var disallowed = fields.disallowed_tools.iterator();
    try std.testing.expectEqualStrings("Write", disallowed.next().?);
    try std.testing.expectEqualStrings("Edit", disallowed.next().?);
    try std.testing.expect(disallowed.next() == null);

    var paths = fields.paths.iterator();
    try std.testing.expectEqualStrings("src/**", paths.next().?);
    try std.testing.expectEqualStrings("docs/**", paths.next().?);
    try std.testing.expect(paths.next() == null);
}

test "skill frontmatter is read back from loaded skill content" {
    const fields = parseLoadedSkillContent("<skill_content name=\"deploy\" location=\"/skills/deploy\" resource=\"SKILL.md\" complete=\"true\">\n---\nname: deploy\ndescription: Ship it\ncontext: fork\nallowed-tools: Read\n---\nbody\n</skill_content>");
    try std.testing.expect(fields.context_fork);
    try std.testing.expect(!fields.allowed_tools.isEmpty());
    try std.testing.expect(!parseLoadedSkillContent("no tag here").context_fork);
}

test "allowed-tools grants cover the listed non-shell tools for the turn and leave shell commands to approval" {
    const alloc = std.testing.allocator;
    const fields = parse("---\nname: commit\ndescription: Commit work\nallowed-tools: Read, Edit(src/**), Bash(git add *), mcp__github__create_issue, *\n---\n");
    const grants = try turnGrants(alloc, fields.allowed_tools);
    defer types.freePermissionGrantSlice(alloc, grants);
    try std.testing.expectEqual(@as(usize, 3), grants.len);
    try std.testing.expectEqualStrings("Read", grants[0].tool_name);
    try std.testing.expectEqualStrings("*", grants[0].target_path);
    try std.testing.expectEqualStrings("Edit", grants[1].tool_name);
    try std.testing.expectEqualStrings("src/**", grants[1].target_path);
    try std.testing.expectEqualStrings("mcp__github__create_issue", grants[2].tool_name);
    try std.testing.expectEqualStrings("*", grants[2].target_path);

    const none = try turnGrants(alloc, .{});
    defer types.freePermissionGrantSlice(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn run(failing: Allocator, list: ValueList) !void {
            const owned = try turnGrants(failing, list);
            types.freePermissionGrantSlice(failing, owned);
        }
    }.run, .{fields.allowed_tools});
}

test "a fork skill tells the model to run it through the Agent tool" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeForkDirective(&out.writer, parse("---\nname: plain\ndescription: d\n---\n"), "plain");
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    try writeForkDirective(&out.writer, parse("---\nname: audit\ndescription: d\ncontext: fork\n---\n"), "audit");
    try std.testing.expect(std.mem.find(u8, out.written(), "description \"audit\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "subagent_type") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "run_in_background true") != null);

    out.clearRetainingCapacity();
    try writeForkDirective(&out.writer, parse("---\nname: audit\ndescription: d\ncontext: fork\nagent: explore\nmodel: opus\nbackground: false\n---\n"), "audit");
    try std.testing.expect(std.mem.find(u8, out.written(), "subagent_type \"explore\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "model \"opus\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "run_in_background false") != null);
}
