const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const max_frontmatter_bytes: usize = 64 * 1024;
pub const max_name_bytes: usize = 256;
pub const max_body_index_bytes: usize = 2048;

pub fn resource_path_or_main(resource: ?[]const u8) []const u8 {
    const path = resource orelse return "SKILL.md";
    return if (path.len == 0) "SKILL.md" else path;
}

test "skill resource defaulting preserves explicit paths" {
    const cases = [_]struct { input: ?[]const u8, expected: []const u8 }{
        .{ .input = null, .expected = "SKILL.md" },
        .{ .input = "", .expected = "SKILL.md" },
        .{ .input = "SKILL.md", .expected = "SKILL.md" },
        .{ .input = "references/rules.md", .expected = "references/rules.md" },
        .{ .input = " ", .expected = " " },
        .{ .input = "../outside", .expected = "../outside" },
    };
    for (cases) |case| {
        const path = resource_path_or_main(case.input);
        try std.testing.expectEqualStrings(case.expected, path);
        try std.testing.expectEqualStrings(path, resource_path_or_main(path));
        if (case.input) |input| if (input.len > 0) {
            try std.testing.expectEqual(input.ptr, path.ptr);
        };
    }
}

pub const SkillForm = enum { directory, flat_file };

pub const SkillKind = enum {
    prompt,
    inline_text,
    flow,
    reference,

    pub fn fromDeclared(declared: ?[]const u8) ?SkillKind {
        const value = declared orelse return .prompt;
        if (value.len == 0) return .prompt;
        if (std.mem.eql(u8, value, "prompt")) return .prompt;
        if (std.mem.eql(u8, value, "inline")) return .inline_text;
        if (std.mem.eql(u8, value, "flow")) return .flow;
        if (std.mem.eql(u8, value, "reference")) return .reference;
        return null;
    }

    pub fn modelInvocable(self: SkillKind) bool {
        return self == .prompt or self == .inline_text;
    }

    pub fn label(self: SkillKind) []const u8 {
        return switch (self) {
            .prompt => "prompt",
            .inline_text => "inline",
            .flow => "flow",
            .reference => "reference",
        };
    }
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
    source: SkillSource,
    form: SkillForm = .directory,
    read_authority: ?[]const u8 = null,
    body_index: []const u8 = "",
    when_to_use: []const u8 = "",
    kind: SkillKind = .prompt,
    model_invocation_disabled: bool = false,
    user_invocation_disabled: bool = false,
    sub_skill: bool = false,
    metadata_inode: std.Io.File.INode = 0,
    metadata_size: u64 = 0,
    metadata_mtime: std.Io.Timestamp = .zero,

    pub fn modelInvocable(self: Skill) bool {
        return !self.model_invocation_disabled and self.kind.modelInvocable();
    }

    pub fn userInvocable(self: Skill) bool {
        return !self.user_invocation_disabled;
    }

    pub fn listedForModel(self: Skill) bool {
        return self.modelInvocable() and !self.sub_skill;
    }

    pub fn declaresName(self: Skill, declared: []const u8) bool {
        if (std.mem.eql(u8, self.name, declared)) return true;
        if (!self.sub_skill) return false;
        if (self.name.len <= declared.len + 1) return false;
        const separator = self.name.len - declared.len - 1;
        return self.name[separator] == '.' and std.mem.eql(u8, self.name[separator + 1 ..], declared);
    }
};

pub const SkillDiagnosticCause = union(enum) {
    invalid_metadata: InvalidMetadataCause,
    linked_candidate_unavailable,
    unreadable,
    oversized,
    nested_checkout,
};

pub const SkillDiagnosticScope = enum { root, candidate };

pub const SkillDiagnostic = struct {
    path: []const u8,
    source: SkillSource,
    scope: SkillDiagnosticScope,
    cause: SkillDiagnosticCause,
};

pub const PreparedSkill = struct {
    skill: Skill,
    diagnostics: []SkillDiagnostic = &.{},
};

pub const ExecuteOutput = struct {
    model_output: []const u8,
    notice: ?[]const u8 = null,
    diagnostic_notice: ?[]const u8 = null,
    complete: bool = false,
};

pub const CallPreparation = union(enum) {
    selected: PreparedSkill,
    failure: ExecuteOutput,
};

pub const Locations = struct {
    namespace: u64 = 0,
    roots: []const []const u8 = &.{},
    skills: []const Skill = &.{},
    diagnostics: []const SkillDiagnostic = &.{},

    pub fn resolve(self: Locations, alloc: std.mem.Allocator, location: []const u8) ![]u8 {
        if (!std.mem.startsWith(u8, location, "skill:")) return alloc.dupe(u8, location);
        const suffix = location["skill:".len..];
        if (suffix.len < 19 or suffix[16] != ':') return error.InvalidSkillLocation;
        const namespace = std.fmt.parseInt(u64, suffix[0..16], 16) catch return error.InvalidSkillLocation;
        if (namespace != self.namespace) return error.StaleSkillLocation;
        const slash = std.mem.findScalar(u8, suffix[17..], '/') orelse return error.InvalidSkillLocation;
        const index = std.fmt.parseInt(usize, suffix[17..][0..slash], 10) catch return error.InvalidSkillLocation;
        if (index >= self.roots.len) return error.InvalidSkillLocation;
        const encoded_leaf = suffix[17 + slash + 1 ..];
        var position: usize = 0;
        while (position < encoded_leaf.len) : (position += 1) {
            if (encoded_leaf[position] != '%') continue;
            if (encoded_leaf.len - position < 3 or !std.ascii.isHex(encoded_leaf[position + 1]) or !std.ascii.isHex(encoded_leaf[position + 2])) return error.InvalidSkillLocation;
            position += 2;
        }
        const decoded = try alloc.dupe(u8, encoded_leaf);
        defer alloc.free(decoded);
        const leaf = std.Uri.percentDecodeInPlace(decoded);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or
            std.mem.findAny(u8, leaf, "/\\\x00") != null or !std.unicode.utf8ValidateSlice(leaf)) return error.InvalidSkillLocation;
        return std.Io.Dir.path.join(alloc, &.{ self.roots[index], leaf });
    }
};

pub const SkillSource = enum {
    workspace_fx,
    workspace_shared,
    workspace_opencode,
    workspace_codex,
    workspace_claude,
    workspace_agents,
    workspace_claw,
    global_fx,
    global_opencode,
    global_codex,
    global_claude,
    global_agents,
    global_claw,
    explicit_dir,
    extra_dir,
};

pub fn sourcePriority(source: SkillSource) u8 {
    return switch (source) {
        .workspace_fx,
        .workspace_shared,
        .workspace_opencode,
        .workspace_codex,
        .workspace_claude,
        .workspace_agents,
        .workspace_claw,
        => 30,
        .global_fx,
        .global_opencode,
        .global_codex,
        .global_claude,
        .global_agents,
        .global_claw,
        .explicit_dir,
        => 20,
        .extra_dir => 10,
    };
}

test "source priority ranks workspace skills above user skills" {
    try std.testing.expect(sourcePriority(.workspace_fx) > sourcePriority(.global_fx));
    try std.testing.expect(sourcePriority(.workspace_agents) > sourcePriority(.global_agents));
    try std.testing.expectEqual(sourcePriority(.global_fx), sourcePriority(.global_agents));
}

test "skill locations preserve exact roots and reject stale namespaces" {
    const alloc = std.testing.allocator;
    const locations: Locations = .{ .namespace = 19, .roots = &.{ "/first", "/second" } };
    const exact = try locations.resolve(alloc, "skill:0000000000000013:1/review");
    defer alloc.free(exact);
    try std.testing.expectEqualStrings("/second/review", exact);
    try std.testing.expectError(error.StaleSkillLocation, locations.resolve(alloc, "skill:0000000000000012:1/review"));
    try std.testing.expectError(error.InvalidSkillLocation, locations.resolve(alloc, "skill:0000000000000013:2/review"));
    try std.testing.expectError(error.InvalidSkillLocation, locations.resolve(alloc, "skill:0000000000000013:0/../review"));
    try std.testing.expectError(error.InvalidSkillLocation, locations.resolve(alloc, "skill:0000000000000013:0/.."));
}

test "skill locations decode escaped path characters without permitting traversal" {
    const alloc = std.testing.allocator;
    const locations: Locations = .{ .namespace = 1, .roots = &.{"/root"} };
    const path = try locations.resolve(alloc, "skill:0000000000000001:0/review%26more");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/root/review&more", path);
    try std.testing.expectError(error.InvalidSkillLocation, locations.resolve(alloc, "skill:0000000000000001:0/%2e%2e"));
    try std.testing.expectError(error.InvalidSkillLocation, locations.resolve(alloc, "skill:0000000000000001:0/review%2fother"));
}

pub const RootSpec = struct {
    source: SkillSource,
    path: []const u8,
};

pub const RootPolicy = struct {
    workspace_roots: []const RootSpec = &.{},
    managed_root_source: ?SkillSource,
    global_roots: []const RootSpec = &.{},
};

pub const InvalidMetadataCause = enum {
    frontmatter_too_long,
    missing_closing_delimiter,
    missing_frontmatter,
    missing_name,
    missing_description,
    unsupported_type,
    duplicate_recognized_key,
    invalid_name,
    name_too_long,
    malformed_quote,
    unsupported_multiline,
    invalid_utf8,
    control_byte,
};

pub const MetadataStatus = union(enum) {
    no_frontmatter,
    valid,
    invalid: InvalidMetadataCause,
};

const BlockDescriptionStyle = enum {
    folded_clip,
    folded_strip,
    literal_clip,
};

pub const BlockDescription = struct {
    style: BlockDescriptionStyle,
    base_indent: usize,
    decoded_len: usize,

    fn decode_into(self: BlockDescription, raw: []const u8, output: []u8) void {
        std.debug.assert(output.len == self.decoded_len);
        const written = decode_block_description(raw, self.base_indent, self.style, output);
        std.debug.assert(written == output.len);
    }
};

pub const OptionalText = struct {
    raw: []const u8 = "",
    block: ?BlockDescription = null,

    pub fn len(self: OptionalText) usize {
        if (self.block) |block| return block.decoded_len;
        return self.raw.len;
    }

    pub fn write(self: OptionalText, output: []u8) void {
        std.debug.assert(output.len == self.len());
        if (self.block) |block| {
            block.decode_into(self.raw, output);
        } else {
            @memcpy(output, self.raw);
        }
    }
};

pub const ParsedSkillFile = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    description_block: ?BlockDescription = null,
    skill_type: ?[]const u8 = null,
    when_to_use: OptionalText = .{},
    model_invocation_disabled: bool = false,
    user_invocation_disabled: bool = false,
    has_sub_skill: bool = false,
    declared_arguments: []const u8 = "",
    body: []const u8,
    status: MetadataStatus,
};

pub const SkillTraits = struct {
    kind: SkillKind = .prompt,
    model_invocation_disabled: bool = false,
    user_invocation_disabled: bool = false,
    has_sub_skill: bool = false,
    when_to_use: OptionalText = .{},
};

pub fn skillTraits(parsed: ParsedSkillFile) SkillTraits {
    return .{
        .kind = SkillKind.fromDeclared(parsed.skill_type) orelse .prompt,
        .model_invocation_disabled = parsed.model_invocation_disabled,
        .user_invocation_disabled = parsed.user_invocation_disabled,
        .has_sub_skill = parsed.has_sub_skill,
        .when_to_use = parsed.when_to_use,
    };
}

pub const ArgumentNameIterator = struct {
    declared: []const u8,
    offset: usize = 0,

    const separators = " \t\r\n,[]\"'";

    pub fn next(self: *ArgumentNameIterator) ?[]const u8 {
        while (self.offset < self.declared.len) {
            while (self.offset < self.declared.len and std.mem.findScalar(u8, separators, self.declared[self.offset]) != null) : (self.offset += 1) {}
            const start = self.offset;
            while (self.offset < self.declared.len and std.mem.findScalar(u8, separators, self.declared[self.offset]) == null) : (self.offset += 1) {}
            const token = self.declared[start..self.offset];
            if (token.len == 0 or std.mem.eql(u8, token, "-") or isAllDigits(token)) continue;
            return token;
        }
        return null;
    }
};

pub fn argumentNames(declared: []const u8) ArgumentNameIterator {
    return .{ .declared = declared };
}

fn isAllDigits(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return text.len > 0;
}

pub const body_description_ellipsis = "…";
pub const no_description_placeholder = "No description provided.";
const body_description_max_units: usize = 240;
const body_description_kept_units: usize = 239;

pub const SkillMetadata = struct {
    name: []const u8,
    description: []const u8,
    description_block: ?BlockDescription,
    ellipsis: bool = false,

    pub fn description_len(self: SkillMetadata) usize {
        if (self.description_block) |block| return block.decoded_len;
        return self.description.len + if (self.ellipsis) body_description_ellipsis.len else 0;
    }

    pub fn write_description(self: SkillMetadata, output: []u8) void {
        std.debug.assert(output.len == self.description_len());
        if (self.description_block) |block| {
            block.decode_into(self.description, output);
        } else {
            @memcpy(output[0..self.description.len], self.description);
            if (self.ellipsis) @memcpy(output[self.description.len..], body_description_ellipsis);
        }
    }
};

pub const SkillMetadataResult = union(enum) {
    valid: SkillMetadata,
    invalid: InvalidMetadataCause,
};

fn isSupportedSkillType(skill_type: ?[]const u8) bool {
    return SkillKind.fromDeclared(skill_type) != null;
}

pub fn resolveMetadata(parsed: ParsedSkillFile) SkillMetadataResult {
    return switch (parsed.status) {
        .no_frontmatter => .{ .invalid = .missing_frontmatter },
        .valid => {
            const metadata: SkillMetadata = .{
                .name = parsed.name.?,
                .description = parsed.description orelse "",
                .description_block = parsed.description_block,
            };
            if (metadata.description_len() == 0) return .{ .invalid = .missing_description };
            if (!isSupportedSkillType(parsed.skill_type)) return .{ .invalid = .unsupported_type };
            return .{ .valid = metadata };
        },
        .invalid => |cause| .{ .invalid = cause },
    };
}

pub fn skillFileStem(file_name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file_name, ".md")) file_name[0 .. file_name.len - ".md".len] else file_name;
}

pub fn resolveSkillMetadata(form: SkillForm, parsed: ParsedSkillFile, file_name: []const u8) SkillMetadataResult {
    return switch (form) {
        .directory => resolveMetadata(parsed),
        .flat_file => resolveFlatMetadata(parsed, skillFileStem(file_name)),
    };
}

pub fn resolveFlatMetadata(parsed: ParsedSkillFile, stem: []const u8) SkillMetadataResult {
    const name = switch (parsed.status) {
        .no_frontmatter => stem,
        .valid => parsed.name.?,
        .invalid => |cause| if (cause == .missing_name) stem else return .{ .invalid = cause },
    };
    if (invalidSkillNameCause(name)) |cause| return .{ .invalid = cause };
    if (!isSupportedSkillType(parsed.skill_type)) return .{ .invalid = .unsupported_type };

    const declared_description_present = if (parsed.description_block) |block|
        block.decoded_len > 0
    else
        (parsed.description orelse @as([]const u8, "")).len > 0;
    if (declared_description_present) return .{ .valid = .{
        .name = name,
        .description = parsed.description orelse "",
        .description_block = parsed.description_block,
    } };

    const line = firstBodyLine(parsed.body) orelse return .{ .valid = .{
        .name = name,
        .description = no_description_placeholder,
        .description_block = null,
    } };
    if (!std.unicode.utf8ValidateSlice(line)) return .{ .invalid = .invalid_utf8 };
    const kept = utf16PrefixLength(line, body_description_max_units);
    if (kept == line.len) return .{ .valid = .{
        .name = name,
        .description = line,
        .description_block = null,
    } };
    return .{ .valid = .{
        .name = name,
        .description = line[0..utf16PrefixLength(line, body_description_kept_units)],
        .description_block = null,
        .ellipsis = true,
    } };
}

fn firstBodyLine(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\x0b\x0c");
        if (line.len > 0) return line;
    }
    return null;
}

pub fn utf16PrefixLength(text: []const u8, max_units: usize) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const codepoint_units: usize = if (sequence_length == 4) 2 else 1;
        if (units + codepoint_units > max_units) break;
        units += codepoint_units;
        index = @min(index + sequence_length, text.len);
    }
    return index;
}

pub fn parseSkillFile(content: []const u8) ParsedSkillFile {
    const header_start = frontmatterHeaderStart(content) orelse {
        return .{
            .name = null,
            .description = null,
            .body = content,
            .status = .no_frontmatter,
        };
    };
    const closing = findClosingDelimiter(content[0..@min(content.len, max_frontmatter_bytes + 1)], header_start) orelse {
        return .{
            .name = null,
            .description = null,
            .body = content,
            .status = .{ .invalid = if (content.len > max_frontmatter_bytes) .frontmatter_too_long else .missing_closing_delimiter },
        };
    };
    if (closing.body_start > max_frontmatter_bytes) return .{
        .name = null,
        .description = null,
        .body = content,
        .status = .{ .invalid = .frontmatter_too_long },
    };

    const header = content[header_start..closing.header_end];
    const body = std.mem.trimStart(u8, content[closing.body_start..], "\r\n");

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var description_block: ?BlockDescription = null;
    var skill_type: ?[]const u8 = null;
    var when_to_use: OptionalText = .{};
    var model_invocation_disabled = false;
    var user_invocation_disabled = false;
    var has_sub_skill = false;
    var declared_arguments: []const u8 = "";
    var invalid_cause: ?InvalidMetadataCause = null;
    var saw_name = false;
    var saw_description = false;
    var saw_type = false;
    var previous_line_recognized = false;

    var line_offset: usize = 0;
    while (headerLineAt(header, line_offset)) |line| {
        line_offset = line.next;
        const trimmed = std.mem.trim(u8, line.bytes, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (previous_line_recognized and (line.bytes[0] == ' ' or line.bytes[0] == '\t')) {
            setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
            previous_line_recognized = false;
            continue;
        }

        const colon_idx = std.mem.find(u8, trimmed, ":") orelse {
            previous_line_recognized = false;
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
        const raw_value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            previous_line_recognized = true;
            if (saw_name) setFirstInvalidCause(&invalid_cause, .duplicate_recognized_key);
            saw_name = true;
            const parsed_value = parseRecognizedValue(raw_value);
            name = parsed_value.value;
            if (parsed_value.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
        } else if (std.mem.eql(u8, key, "description")) {
            if (saw_description) setFirstInvalidCause(&invalid_cause, .duplicate_recognized_key);
            saw_description = true;
            if (block_description_style(raw_value)) |style| {
                const parsed_block = parse_block_description(header, line_offset, style);
                description = parsed_block.value;
                description_block = parsed_block.block;
                line_offset = parsed_block.next_offset;
                previous_line_recognized = false;
                if (parsed_block.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
            } else {
                previous_line_recognized = true;
                const parsed_value = parseRecognizedValue(raw_value);
                description = parsed_value.value;
                description_block = null;
                if (parsed_value.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
            }
        } else if (std.mem.eql(u8, key, "type")) {
            previous_line_recognized = true;
            if (saw_type) setFirstInvalidCause(&invalid_cause, .duplicate_recognized_key);
            saw_type = true;
            const parsed_value = parseRecognizedValue(raw_value);
            skill_type = parsed_value.value;
            if (parsed_value.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
        } else if (isAnyKey(key, &.{ "whenToUse", "when-to-use", "when_to_use" })) {
            previous_line_recognized = false;
            if (block_description_style(raw_value)) |style| {
                const parsed_block = parse_block_description(header, line_offset, style);
                line_offset = parsed_block.next_offset;
                when_to_use = if (parsed_block.invalid_cause == null)
                    .{ .raw = parsed_block.value, .block = parsed_block.block }
                else
                    .{};
            } else {
                const parsed_value = parseRecognizedValue(raw_value);
                when_to_use = if (parsed_value.invalid_cause == null and invalidTextCause(parsed_value.value) == null)
                    .{ .raw = parsed_value.value }
                else
                    .{};
            }
        } else if (isAnyKey(key, &.{ "disableModelInvocation", "disable-model-invocation", "disable_model_invocation" })) {
            previous_line_recognized = false;
            model_invocation_disabled = isYamlTrue(raw_value);
        } else if (isAnyKey(key, &.{ "user-invocable", "userInvocable", "user_invocable" })) {
            previous_line_recognized = false;
            user_invocation_disabled = isYamlFalse(raw_value);
        } else if (isAnyKey(key, &.{ "has-sub-skill", "hasSubSkill" })) {
            previous_line_recognized = false;
            has_sub_skill = isYamlTrue(raw_value);
        } else if (std.mem.eql(u8, key, "arguments")) {
            previous_line_recognized = false;
            if (raw_value.len > 0) {
                declared_arguments = raw_value;
            } else {
                const list_start = line_offset;
                var list_end = line_offset;
                while (headerLineAt(header, list_end)) |item| {
                    const item_text = std.mem.trim(u8, item.bytes, " \t");
                    if (item_text.len > 0 and item_text[0] != '-') break;
                    list_end = item.next;
                }
                declared_arguments = header[list_start..list_end];
                line_offset = list_end;
            }
        } else {
            previous_line_recognized = false;
        }
    }

    if (name) |skill_name| {
        if (invalidSkillNameCause(skill_name)) |cause| setFirstInvalidCause(&invalid_cause, cause);
    } else {
        setFirstInvalidCause(&invalid_cause, .missing_name);
    }
    if (description_block == null) {
        if (description) |skill_description| {
            if (invalidTextCause(skill_description)) |cause| {
                setFirstInvalidCause(&invalid_cause, cause);
            }
        }
    }
    if (invalid_cause) |cause| {
        if (cause != .missing_name) description_block = null;
    }

    return .{
        .name = name,
        .description = description,
        .description_block = description_block,
        .skill_type = skill_type,
        .when_to_use = when_to_use,
        .model_invocation_disabled = model_invocation_disabled,
        .user_invocation_disabled = user_invocation_disabled,
        .has_sub_skill = has_sub_skill,
        .declared_arguments = declared_arguments,
        .body = body,
        .status = if (invalid_cause) |cause| .{ .invalid = cause } else .valid,
    };
}

fn isAnyKey(key: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn isYamlTrue(raw_value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(parseRecognizedValue(raw_value).value, "true");
}

fn isYamlFalse(raw_value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(parseRecognizedValue(raw_value).value, "false");
}

test "user-invocable false marks a skill as hidden from the user and defaults to visible" {
    for ([_][]const u8{ "user-invocable", "userInvocable", "user_invocable" }) |alias| {
        const hidden = try std.fmt.allocPrint(std.testing.allocator, "---\nname: a\ndescription: b\n{s}: false\n---\n", .{alias});
        defer std.testing.allocator.free(hidden);
        const parsed = parseSkillFile(hidden);
        try std.testing.expect(parsed.user_invocation_disabled);
        try std.testing.expect(skillTraits(parsed).user_invocation_disabled);
        try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    }
    try std.testing.expect(!parseSkillFile("---\nname: a\ndescription: b\nuser-invocable: true\n---\n").user_invocation_disabled);
    try std.testing.expect(!parseSkillFile("---\nname: a\ndescription: b\n---\n").user_invocation_disabled);
    const visible: Skill = .{ .name = "x", .description = "", .path = "/p", .source = .workspace_fx };
    try std.testing.expect(visible.userInvocable());
    const hidden_skill: Skill = .{ .name = "x", .description = "", .path = "/p", .source = .workspace_fx, .user_invocation_disabled = true };
    try std.testing.expect(!hidden_skill.userInvocable());
    try std.testing.expect(hidden_skill.modelInvocable());
}

const HeaderLine = struct {
    start: usize,
    bytes: []const u8,
    next: usize,
};

fn headerLineAt(header: []const u8, start: usize) ?HeaderLine {
    if (start >= header.len) return null;
    const newline_offset = std.mem.findScalar(u8, header[start..], '\n');
    const line_end = if (newline_offset) |offset| start + offset else header.len;
    const raw_line = header[start..line_end];
    const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
        raw_line[0 .. raw_line.len - 1]
    else
        raw_line;
    return .{
        .start = start,
        .bytes = line,
        .next = if (newline_offset != null) line_end + 1 else line_end,
    };
}

const ParsedBlockDescription = struct {
    value: []const u8,
    block: BlockDescription,
    next_offset: usize,
    invalid_cause: ?InvalidMetadataCause,
};

fn parse_block_description(header: []const u8, start: usize, style: BlockDescriptionStyle) ParsedBlockDescription {
    var base_indent: ?usize = null;
    var invalid_cause: ?InvalidMetadataCause = null;
    var can_decode = true;
    var line_offset = start;
    var block_end = header.len;

    while (headerLineAt(header, line_offset)) |line| {
        line_offset = line.next;
        if (is_structural_blank(line.bytes)) continue;

        const indent = leading_space_count(line.bytes);
        if (indent == 0) {
            if (line.bytes[0] == '\t') {
                setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
                can_decode = false;
                continue;
            }
            block_end = line.start;
            line_offset = line.start;
            break;
        }
        if (indent < line.bytes.len and line.bytes[indent] == '\t') {
            setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
            can_decode = false;
            continue;
        }

        if (base_indent) |established_indent| {
            if (indent < established_indent) {
                setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
                can_decode = false;
                continue;
            }
        } else {
            base_indent = indent;
        }

        const content_line = line.bytes[base_indent.?..];
        if (invalidTextCause(content_line)) |cause| setFirstInvalidCause(&invalid_cause, cause);
    }

    const raw_value = header[start..block_end];
    const decoded_len = if (can_decode)
        decode_block_description(raw_value, base_indent orelse 0, style, null)
    else
        0;

    return .{
        .value = raw_value,
        .block = .{
            .style = style,
            .base_indent = base_indent orelse 0,
            .decoded_len = decoded_len,
        },
        .next_offset = line_offset,
        .invalid_cause = invalid_cause,
    };
}

fn block_description_style(value: []const u8) ?BlockDescriptionStyle {
    if (std.mem.eql(u8, value, ">")) return .folded_clip;
    if (std.mem.eql(u8, value, ">-")) return .folded_strip;
    if (std.mem.eql(u8, value, "|")) return .literal_clip;
    return null;
}

fn is_structural_blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn leading_space_count(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

const DescriptionEmitter = struct {
    output: ?[]u8,
    len: usize = 0,

    fn write(self: *DescriptionEmitter, value: []const u8) void {
        const end = std.math.add(usize, self.len, value.len) catch std.math.maxInt(usize);
        if (self.output) |output| {
            std.debug.assert(end <= output.len);
            @memcpy(output[self.len..end], value);
        }
        self.len = end;
    }
};

fn decode_block_description(
    raw: []const u8,
    base_indent: usize,
    style: BlockDescriptionStyle,
    output: ?[]u8,
) usize {
    var last_nonblank_next: usize = 0;
    var line_offset: usize = 0;
    while (headerLineAt(raw, line_offset)) |line| {
        line_offset = line.next;
        if (!is_structural_blank(line.bytes)) last_nonblank_next = line.next;
    }
    if (last_nonblank_next == 0) return 0;

    var emitter: DescriptionEmitter = .{ .output = output };
    var previous_nonblank = false;
    var first = true;
    line_offset = 0;
    while (line_offset < last_nonblank_next) {
        const line = headerLineAt(raw, line_offset) orelse break;
        line_offset = line.next;
        const nonblank = !is_structural_blank(line.bytes);
        if (!first) {
            const separator = switch (style) {
                .literal_clip => "\n",
                .folded_clip, .folded_strip => if (previous_nonblank and nonblank) " " else "\n",
            };
            emitter.write(separator);
        }
        if (nonblank) emitter.write(line.bytes[base_indent..]);
        previous_nonblank = nonblank;
        first = false;
    }
    switch (style) {
        .folded_clip, .literal_clip => emitter.write("\n"),
        .folded_strip => {},
    }
    return emitter.len;
}

const ClosingDelimiter = struct {
    header_end: usize,
    body_start: usize,
};

pub fn frontmatterHeaderStart(content: []const u8) ?usize {
    if (std.mem.startsWith(u8, content, "---\r\n")) return 5;
    if (std.mem.startsWith(u8, content, "---\n")) return 4;
    if (std.mem.eql(u8, content, "---")) return 3;
    return null;
}

const SkillMetadataScanner = struct {
    offset: usize,
    line_prefix: [4]u8 = undefined,
    line_len: usize = 0,

    fn init(header_start: usize) SkillMetadataScanner {
        return .{ .offset = header_start };
    }

    fn scan(self: *SkillMetadataScanner, content: []const u8, complete: bool) bool {
        while (self.offset < content.len) {
            const byte = content[self.offset];
            self.offset += 1;
            if (byte == '\n') {
                const closing = self.isClosingLine(true);
                self.line_len = 0;
                if (closing) return true;
                continue;
            }
            if (self.line_len < self.line_prefix.len) {
                self.line_prefix[self.line_len] = byte;
            }
            self.line_len += 1;
        }
        return complete and self.isClosingLine(false);
    }

    fn isClosingLine(self: SkillMetadataScanner, newline_terminated: bool) bool {
        if (self.line_len == 3 and std.mem.eql(u8, self.line_prefix[0..3], "---")) return true;
        return newline_terminated and
            self.line_len == 4 and
            std.mem.eql(u8, self.line_prefix[0..4], "---\r");
    }
};

pub fn readMetadataPrefix(alloc: std.mem.Allocator, file: *std.Io.File, file_size: usize) ![]u8 {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    const readable_size = @min(file_size, max_frontmatter_bytes + 1);
    var scanner: ?SkillMetadataScanner = null;
    var metadata_complete = false;

    while (content.items.len < readable_size) {
        const wanted = @min(chunk.len, readable_size - content.items.len);
        const read = try file.readPositionalAll(io_mod.getIo(), chunk[0..wanted], content.items.len);
        if (read == 0) return error.UnexpectedEndOfFile;
        try content.appendSlice(alloc, chunk[0..read]);

        const file_complete = content.items.len == file_size;
        if (scanner == null) {
            if (content.items.len < 5 and !file_complete) continue;
            const header_start = frontmatterHeaderStart(content.items) orelse {
                metadata_complete = true;
                break;
            };
            scanner = SkillMetadataScanner.init(header_start);
        }
        if (scanner.?.scan(content.items, file_complete)) {
            metadata_complete = true;
            break;
        }
    }
    if (!metadata_complete and content.items.len < file_size) return error.StreamTooLong;
    return try content.toOwnedSlice(alloc);
}

fn findClosingDelimiter(content: []const u8, header_start: usize) ?ClosingDelimiter {
    var line_start = header_start;
    while (line_start <= content.len) {
        const newline_offset = std.mem.findScalar(u8, content[line_start..], '\n');
        const line_end = if (newline_offset) |offset| line_start + offset else content.len;
        const raw_line = content[line_start..line_end];
        const line = if (newline_offset != null and raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (std.mem.eql(u8, line, "---")) {
            return .{
                .header_end = line_start,
                .body_start = if (newline_offset != null) line_end + 1 else line_end,
            };
        }
        if (newline_offset == null) return null;
        line_start = line_end + 1;
    }
    return null;
}

const ParsedRecognizedValue = struct {
    value: []const u8,
    invalid_cause: ?InvalidMetadataCause = null,
};

fn parseRecognizedValue(value: []const u8) ParsedRecognizedValue {
    if (value.len > 0 and (value[0] == '|' or value[0] == '>')) {
        return .{ .value = value, .invalid_cause = .unsupported_multiline };
    }

    const starts_with_quote = value.len > 0 and (value[0] == '\'' or value[0] == '"');
    const ends_with_quote = value.len > 0 and (value[value.len - 1] == '\'' or value[value.len - 1] == '"');
    if (starts_with_quote or ends_with_quote) {
        if (value.len >= 2 and value[0] == value[value.len - 1]) {
            return .{ .value = value[1 .. value.len - 1] };
        }
        return .{ .value = value, .invalid_cause = .malformed_quote };
    }
    return .{ .value = value };
}

fn setFirstInvalidCause(current: *?InvalidMetadataCause, cause: InvalidMetadataCause) void {
    if (current.* == null) current.* = cause;
}

fn invalidTextCause(value: []const u8) ?InvalidMetadataCause {
    if (!std.unicode.utf8ValidateSlice(value)) return .invalid_utf8;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return .control_byte;
    }
    return null;
}

pub fn invalidSkillNameCause(name: []const u8) ?InvalidMetadataCause {
    if (name.len == 0) return .missing_name;
    if (name.len > max_name_bytes) return .name_too_long;
    if (invalidTextCause(name)) |cause| return cause;
    validateManagedSkillName(name) catch return .invalid_name;
    return null;
}

pub fn validateManagedSkillName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidSkillName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidSkillName;
    if (std.Io.Dir.path.isAbsolute(name)) return error.InvalidSkillName;
    if (std.mem.findScalar(u8, name, '/') != null) return error.InvalidSkillName;
    if (std.mem.findScalar(u8, name, '\\') != null) return error.InvalidSkillName;
}

test "parseSkillFile reads the Kimi model fields and their key aliases" {
    const camel = parseSkillFile(
        "---\nname: deploy\ndescription: Ships a build\ntype: flow\nwhenToUse: when a release is ready\n" ++
            "disableModelInvocation: true\narguments: [target, 2, region]\nmetadata:\n  has-sub-skill: true\n---\nBody",
    );
    try std.testing.expectEqual(MetadataStatus.valid, camel.status);
    try std.testing.expectEqualStrings("when a release is ready", camel.when_to_use.raw);
    try std.testing.expect(camel.model_invocation_disabled);
    try std.testing.expect(camel.has_sub_skill);
    const traits = skillTraits(camel);
    try std.testing.expectEqual(SkillKind.flow, traits.kind);
    try std.testing.expect(!traits.kind.modelInvocable());
    var names = argumentNames(camel.declared_arguments);
    try std.testing.expectEqualStrings("target", names.next().?);
    try std.testing.expectEqualStrings("region", names.next().?);
    try std.testing.expect(names.next() == null);

    for ([_][]const u8{ "when-to-use", "when_to_use" }) |alias| {
        var buffer: [128]u8 = undefined;
        const content = try std.fmt.bufPrint(&buffer, "---\nname: a\ndescription: b\n{s}: \"quoted hint\"\n---\n", .{alias});
        try std.testing.expectEqualStrings("quoted hint", parseSkillFile(content).when_to_use.raw);
    }
    for ([_][]const u8{ "disable-model-invocation", "disable_model_invocation" }) |alias| {
        var buffer: [128]u8 = undefined;
        const content = try std.fmt.bufPrint(&buffer, "---\nname: a\ndescription: b\n{s}: true\n---\n", .{alias});
        try std.testing.expect(parseSkillFile(content).model_invocation_disabled);
    }
    try std.testing.expect(!parseSkillFile("---\nname: a\ndescription: b\ndisableModelInvocation: false\n---\n").model_invocation_disabled);
}

test "parseSkillFile reads block lists of arguments and folded when-to-use text without rejecting the skill" {
    const parsed = parseSkillFile(
        "---\nname: review\narguments:\n  - issue\n  - branch\ndescription: Reviews\nwhen_to_use: >-\n  after a change\n  lands\n---\nBody",
    );
    try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    try std.testing.expectEqualStrings("Reviews", parsed.description.?);
    var names = argumentNames(parsed.declared_arguments);
    try std.testing.expectEqualStrings("issue", names.next().?);
    try std.testing.expectEqualStrings("branch", names.next().?);
    try std.testing.expect(names.next() == null);
    var hint: [64]u8 = undefined;
    const hint_len = parsed.when_to_use.len();
    parsed.when_to_use.write(hint[0..hint_len]);
    try std.testing.expectEqualStrings("after a change lands", hint[0..hint_len]);

    const control = parseSkillFile("---\nname: review\ndescription: Reviews\nwhenToUse: bad\x01hint\n---\n");
    try std.testing.expectEqual(MetadataStatus.valid, control.status);
    try std.testing.expectEqual(@as(usize, 0), control.when_to_use.len());

    var plain = argumentNames("first second 7");
    try std.testing.expectEqualStrings("first", plain.next().?);
    try std.testing.expectEqualStrings("second", plain.next().?);
    try std.testing.expect(plain.next() == null);
}

test "skill kinds follow the Kimi type set and sub-skill names match their declared leaf" {
    try std.testing.expectEqual(SkillKind.prompt, SkillKind.fromDeclared(null).?);
    try std.testing.expectEqual(SkillKind.prompt, SkillKind.fromDeclared("").?);
    try std.testing.expectEqual(SkillKind.inline_text, SkillKind.fromDeclared("inline").?);
    try std.testing.expectEqual(SkillKind.reference, SkillKind.fromDeclared("reference").?);
    try std.testing.expect(SkillKind.fromDeclared("agent") == null);
    try std.testing.expect(SkillKind.inline_text.modelInvocable());
    try std.testing.expect(!SkillKind.reference.modelInvocable());

    const child: Skill = .{ .name = "pack.review", .description = "", .path = "/p", .source = .workspace_fx, .sub_skill = true };
    try std.testing.expect(child.declaresName("review"));
    try std.testing.expect(child.declaresName("pack.review"));
    try std.testing.expect(!child.declaresName("view"));
    try std.testing.expect(!child.listedForModel());
    try std.testing.expect(child.modelInvocable());
    const plain: Skill = .{ .name = "pack.review", .description = "", .path = "/p", .source = .workspace_fx };
    try std.testing.expect(!plain.declaresName("review"));
    const disabled: Skill = .{ .name = "x", .description = "", .path = "/p", .source = .workspace_fx, .model_invocation_disabled = true };
    try std.testing.expect(!disabled.modelInvocable());
}

test "parseSkillFile with full frontmatter" {
    const content =
        \\---
        \\name: my-skill
        \\description: Helps with testing
        \\---
        \\
        \\# My Skill
        \\
        \\Do the thing.
    ;
    const parsed = parseSkillFile(content);
    try std.testing.expectEqualStrings("my-skill", parsed.name.?);
    try std.testing.expectEqualStrings("Helps with testing", parsed.description.?);
    try std.testing.expectEqualStrings("# My Skill\n\nDo the thing.", parsed.body);
}

test "parseSkillFile accepts supported description block forms" {
    const cases = [_][]const u8{
        "---\nname: folded\ndescription: >\n  Fold this\n  onto one line.\n---\nBody",
        "---\nname: folded-strip\ndescription: >-\n  Fold without\n  a trailing newline.\n---\nBody",
        "---\nname: literal\ndescription: |\n  Keep this\n  on two lines.\n---\nBody",
    };

    for (cases) |content| {
        const parsed = parseSkillFile(content);
        try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    }
}

test "description blocks preserve folded literal and trailing newline semantics" {
    try expectResolvedDescription(
        "---\nname: folded\ndescription: >\n  Fold this\n  onto one line.\n\n  Keep this paragraph.\n---\nBody",
        "Fold this onto one line.\n\nKeep this paragraph.\n",
    );
    try expectResolvedDescription(
        "---\nname: folded-strip\ndescription: >-\n  Fold without\n  a trailing newline.\n---\nBody",
        "Fold without a trailing newline.",
    );
    try expectResolvedDescription(
        "---\nname: literal\ndescription: |\n  Keep this\n  on two lines.\n---\nBody",
        "Keep this\non two lines.\n",
    );
    try expectResolvedDescription(
        "---\r\nname: crlf\r\ndescription: |\r\n  first\r\n  second\r\n---\r\nBody",
        "first\nsecond\n",
    );
    switch (resolveMetadata(parseSkillFile("---\nname: empty\ndescription: >\n\n---\nBody"))) {
        .invalid => |cause| try std.testing.expectEqual(InvalidMetadataCause.missing_description, cause),
        .valid => return error.TestExpectedInvalidMetadata,
    }
}

test "description blocks return to top-level metadata and reject malformed structure" {
    const valid = parseSkillFile(
        "---\n" ++
            "description: >-\n" ++
            "  first\n" ++
            "    extra indent\n" ++
            "name: after-block\n" ++
            "---\nBody",
    );
    try std.testing.expectEqual(MetadataStatus.valid, valid.status);
    try std.testing.expectEqualStrings("after-block", valid.name.?);
    try expectResolvedDescription(
        "---\ndescription: >-\n  first\n    extra indent\nname: after-block\n---\nBody",
        "first   extra indent",
    );

    const Case = struct {
        content: []const u8,
        cause: InvalidMetadataCause,
    };
    const cases = [_]Case{
        .{
            .content = "---\nname: unsupported\ndescription: >+\n  value\n---\n",
            .cause = .unsupported_multiline,
        },
        .{
            .content = "---\nname: >\n  block names stay invalid\n---\n",
            .cause = .unsupported_multiline,
        },
        .{
            .content = "---\nname: tabbed\ndescription: >\n\tvalue\n---\n",
            .cause = .unsupported_multiline,
        },
        .{
            .content = "---\nname: shallow\ndescription: >\n   first\n  smaller indent\n---\n",
            .cause = .unsupported_multiline,
        },
        .{
            .content = "---\nname: invalid-utf8\ndescription: >\n  bad\xff\n---\n",
            .cause = .invalid_utf8,
        },
        .{
            .content = "---\nname: control\ndescription: >\n  bad\x01\n---\n",
            .cause = .control_byte,
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            MetadataStatus{ .invalid = case.cause },
            parseSkillFile(case.content).status,
        );
    }
}

test "skill metadata accepts descriptions within the frontmatter bound" {
    const description = text_utils.repeat("use this workflow for the specified task ", 160);
    const content = "---\nname: thorough\ndescription: " ++ description ++ "\n---\nbody";
    try std.testing.expectEqual(MetadataStatus.valid, parseSkillFile(content).status);
}

test "description blocks respect the complete frontmatter bound" {
    const prefix = "---\nname: bounded\ndescription: >-\n  ";
    const suffix = "\n---\n";
    const exact = text_utils.repeat("d", max_frontmatter_bytes - prefix.len - suffix.len);
    const over = exact ++ "d";
    try std.testing.expectEqual(
        MetadataStatus.valid,
        parseSkillFile(prefix ++ exact ++ suffix).status,
    );
    try std.testing.expectEqual(
        MetadataStatus{ .invalid = .frontmatter_too_long },
        parseSkillFile(prefix ++ over ++ suffix).status,
    );
}

fn expectResolvedDescription(content: []const u8, expected: []const u8) !void {
    const metadata = switch (resolveMetadata(parseSkillFile(content))) {
        .valid => |value| value,
        .invalid => return error.TestExpectedValidMetadata,
    };
    const description = try std.testing.allocator.alloc(u8, metadata.description_len());
    defer std.testing.allocator.free(description);
    metadata.write_description(description);
    try std.testing.expectEqualStrings(expected, description);
}

test "metadata scanner examines malformed and late delimiters once" {
    const alloc = std.testing.allocator;
    const chunk_bytes = 16 * 1024;

    const malformed = try alloc.alloc(u8, 256 * 1024 + 37);
    defer alloc.free(malformed);
    @memset(malformed, 'a');
    const malformed_header = "---\nname: linear\n";
    @memcpy(malformed[0..malformed_header.len], malformed_header);
    var malformed_scanner = SkillMetadataScanner.init(4);
    var malformed_end: usize = 0;
    var malformed_found = false;
    while (malformed_end < malformed.len) {
        malformed_end = @min(malformed_end + chunk_bytes, malformed.len);
        malformed_found = malformed_scanner.scan(malformed[0..malformed_end], malformed_end == malformed.len);
    }
    try std.testing.expect(!malformed_found);
    try std.testing.expectEqual(malformed.len, malformed_scanner.offset);

    const late = try alloc.alloc(u8, 256 * 1024 + 37);
    defer alloc.free(late);
    @memset(late, 'b');
    const late_header = "---\nname: late\n";
    @memcpy(late[0..late_header.len], late_header);
    @memcpy(late[late.len - 4 ..], "\n---");
    var late_scanner = SkillMetadataScanner.init(4);
    var late_end: usize = 0;
    var late_found = false;
    while (late_end < late.len and !late_found) {
        late_end = @min(late_end + chunk_bytes, late.len);
        late_found = late_scanner.scan(late[0..late_end], late_end == late.len);
    }
    try std.testing.expect(late_found);
    try std.testing.expectEqual(late.len, late_scanner.offset);
}

test "parseSkillFile without frontmatter returns full content as body" {
    const content = "# Just Markdown\n\nSome content.";
    const parsed = parseSkillFile(content);
    try std.testing.expectEqual(MetadataStatus.no_frontmatter, parsed.status);
    try std.testing.expect(parsed.name == null);
    try std.testing.expect(parsed.description == null);
    try std.testing.expectEqualStrings(content, parsed.body);
}

test "parseSkillFile with partial frontmatter" {
    const content =
        \\---
        \\name: partial
        \\---
        \\
        \\Body here.
    ;
    const parsed = parseSkillFile(content);
    try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    try std.testing.expectEqualStrings("partial", parsed.name.?);
    try std.testing.expect(parsed.description == null);
    try std.testing.expectEqualStrings("Body here.", parsed.body);
}

test "parseSkillFile enforces hard metadata field bounds" {
    const valid_name = text_utils.repeat("n", max_name_bytes);
    const oversized_name = valid_name ++ "n";
    const prefix = "---\nname: valid\ndescription: ";
    const suffix = "\n---\n";
    const valid_description = text_utils.repeat("d", max_frontmatter_bytes - prefix.len - suffix.len);
    const oversized_description = valid_description ++ "d";

    const name_at_limit = parseSkillFile("---\nname: " ++ valid_name ++ "\n---\n");
    try std.testing.expectEqual(MetadataStatus.valid, name_at_limit.status);
    const name_over_limit = parseSkillFile("---\nname: " ++ oversized_name ++ "\n---\n");
    try std.testing.expectEqual(
        MetadataStatus{ .invalid = .name_too_long },
        name_over_limit.status,
    );

    const description_at_limit = parseSkillFile(
        prefix ++ valid_description ++ suffix,
    );
    try std.testing.expectEqual(MetadataStatus.valid, description_at_limit.status);
    const description_over_limit = parseSkillFile(
        prefix ++ oversized_description ++ suffix,
    );
    try std.testing.expectEqual(
        MetadataStatus{ .invalid = .frontmatter_too_long },
        description_over_limit.status,
    );
}

test "parseSkillFile normalizes CRLF delimiters and simply quoted values" {
    const content = "---\r\nname: \"windows-newline\"\r\ndescription: 'quoted description'\r\n---\r\nBody";
    const parsed = parseSkillFile(content);
    try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    try std.testing.expectEqualStrings("windows-newline", parsed.name.?);
    try std.testing.expectEqualStrings("quoted description", parsed.description.?);
    try std.testing.expectEqualStrings("Body", parsed.body);

    const mixed = parseSkillFile("---\r\nname: mixed-endings\ndescription: mixed\r\n---\nBody");
    try std.testing.expectEqual(MetadataStatus.valid, mixed.status);
    try std.testing.expectEqualStrings("mixed-endings", mixed.name.?);
    try std.testing.expectEqualStrings("mixed", mixed.description.?);
    try std.testing.expectEqualStrings("Body", mixed.body);
}

test "parseSkillFile ignores unknown keys and colonless lines" {
    const content =
        \\---
        \\ignored
        \\name: known
        \\extra: value
        \\description: useful
        \\---
        \\Body
    ;
    const parsed = parseSkillFile(content);
    try std.testing.expectEqualStrings("known", parsed.name.?);
    try std.testing.expectEqualStrings("useful", parsed.description.?);
    try std.testing.expectEqualStrings("Body", parsed.body);
}

test "parseSkillFile removes one matching pair of outer quotes" {
    const content =
        \\---
        \\name: "quoted-name"
        \\description: 'quoted description'
        \\---
        \\Body
    ;
    const parsed = parseSkillFile(content);
    try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    try std.testing.expectEqualStrings("quoted-name", parsed.name.?);
    try std.testing.expectEqualStrings("quoted description", parsed.description.?);
}

test "resolveMetadata gives discovery and installation one validity result" {
    const no_frontmatter = resolveMetadata(parseSkillFile("# Legacy\n"));
    try std.testing.expectEqual(InvalidMetadataCause.missing_frontmatter, no_frontmatter.invalid);

    const valid = resolveMetadata(
        parseSkillFile("---\nname: review\ndescription: 'review helper'\n---\nbody"),
    );
    try std.testing.expectEqualStrings("review", valid.valid.name);
    try std.testing.expectEqualStrings("review helper", valid.valid.description);

    const missing_description = resolveMetadata(parseSkillFile("---\nname: review\n---\nbody"));
    try std.testing.expectEqual(InvalidMetadataCause.missing_description, missing_description.invalid);

    const empty_description = resolveMetadata(parseSkillFile("---\nname: review\ndescription:\n---\nbody"));
    try std.testing.expectEqual(InvalidMetadataCause.missing_description, empty_description.invalid);

    const malformed = resolveMetadata(
        parseSkillFile("---\nname: first\nname: second\n---\nbody"),
    );
    try std.testing.expectEqual(InvalidMetadataCause.duplicate_recognized_key, malformed.invalid);

    const unsafe_name = resolveMetadata(parseSkillFile("---\nname: ../unsafe\ndescription: x\n---\nbody"));
    try std.testing.expectEqual(InvalidMetadataCause.invalid_name, unsafe_name.invalid);
}

test "resolveMetadata accepts the Kimi skill type set and rejects other types" {
    const supported = [_][]const u8{ "prompt", "inline", "flow", "reference" };
    for (supported) |skill_type| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "---\nname: typed\ndescription: d\ntype: {s}\n---\nbody", .{skill_type});
        defer std.testing.allocator.free(content);
        switch (resolveMetadata(parseSkillFile(content))) {
            .valid => {},
            .invalid => return error.TestExpectedValidMetadata,
        }
    }

    const unsupported = parseSkillFile("---\nname: typed\ndescription: d\ntype: workflow\n---\nbody");
    try std.testing.expectEqual(InvalidMetadataCause.unsupported_type, resolveMetadata(unsupported).invalid);

    const untyped = resolveMetadata(parseSkillFile("---\nname: plain\ndescription: d\n---\nbody"));
    try std.testing.expectEqualStrings("plain", untyped.valid.name);
}

test "parseSkillFile accepts an exact closing delimiter at end of file" {
    const parsed = parseSkillFile("---\nname: eof-close\n---");
    try std.testing.expectEqual(MetadataStatus.valid, parsed.status);
    try std.testing.expectEqualStrings("eof-close", parsed.name.?);
    try std.testing.expectEqualStrings("", parsed.body);
}

test "parseSkillFile classifies invalid recognized metadata" {
    const Case = struct {
        content: []const u8,
        cause: InvalidMetadataCause,
        expected_name: ?[]const u8,
    };
    const cases = [_]Case{
        .{
            .content = "---\nname: unclosed",
            .cause = .missing_closing_delimiter,
            .expected_name = null,
        },
        .{
            .content = "---\nname: prefixed-close\n---suffix\nBody",
            .cause = .missing_closing_delimiter,
            .expected_name = null,
        },
        .{
            .content = "---\nname: bare-cr-close\n---\r",
            .cause = .missing_closing_delimiter,
            .expected_name = null,
        },
        .{
            .content = "---\ndescription: missing name\n---\nBody",
            .cause = .missing_name,
            .expected_name = null,
        },
        .{
            .content = "---\nname: \"\"\n---\nBody",
            .cause = .missing_name,
            .expected_name = "",
        },
        .{
            .content = "---\nname: first\nname: second\n---\nBody",
            .cause = .duplicate_recognized_key,
            .expected_name = "second",
        },
        .{
            .content = "---\nname: ../unsafe\n---\nBody",
            .cause = .invalid_name,
            .expected_name = "../unsafe",
        },
        .{
            .content = "---\nname: \"unterminated\n---\nBody",
            .cause = .malformed_quote,
            .expected_name = "\"unterminated",
        },
        .{
            .content = "---\nname: multiline\ndescription: |2\n---\nBody",
            .cause = .unsupported_multiline,
            .expected_name = "multiline",
        },
        .{
            .content = "---\nname: invalid\xff\n---\nBody",
            .cause = .invalid_utf8,
            .expected_name = "invalid\xff",
        },
        .{
            .content = "---\nname: control\x01byte\n---\nBody",
            .cause = .control_byte,
            .expected_name = "control\x01byte",
        },
    };

    for (cases) |case| {
        const parsed = parseSkillFile(case.content);
        switch (parsed.status) {
            .invalid => |cause| try std.testing.expectEqual(case.cause, cause),
            else => return error.TestExpectedInvalidMetadata,
        }
        if (case.expected_name) |expected_name| {
            try std.testing.expectEqualStrings(expected_name, parsed.name.?);
        } else {
            try std.testing.expect(parsed.name == null);
        }
    }
}

test "parseSkillFile rejects indented continuations for recognized metadata" {
    const cases = [_][]const u8{
        "---\nname: workflow\n  continued name\ndescription: helper\n---\nBody",
        "---\nname: workflow\ndescription: first line\n  continued description\n---\nBody",
        "---\nname: workflow\ndescription: first line\n  continued: description\n---\nBody",
        "---\nname: workflow\ndescription:\n  continued description\n---\nBody",
    };

    for (cases) |content| {
        const parsed = parseSkillFile(content);
        try std.testing.expectEqual(
            MetadataStatus{ .invalid = .unsupported_multiline },
            parsed.status,
        );
    }
}

test "parseSkillFile keeps fuzzed borrowed slices inside the input" {
    try std.testing.fuzz({}, fuzzParseSkillFile, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "plain body",
            "---\nname: valid\n---\nbody",
            "---\r\nname: \"valid\"\r\n---\r\nbody",
            "---\nname: quoted\ndescription: 'single line'\n---\nbody",
            "---\nname: block\ndescription: >-\n  first line\n  second line\n---\nbody",
        }) ++ @import("fuzz_corpus").skill_file.*),
    });
}

fn fuzzParseSkillFile(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];
    const parsed = parseSkillFile(input);

    try expectBorrowedSlice(input, parsed.body);
    if (parsed.name) |name| try expectBorrowedSlice(input, name);
    if (parsed.description) |description| {
        try expectBorrowedSlice(input, description);
        if (parsed.description_block) |block| {
            try std.testing.expect(block.decoded_len <= input.len);
            var decoded: [buffer.len]u8 = undefined;
            block.decode_into(description, decoded[0..block.decoded_len]);
        }
    }
}

fn expectBorrowedSlice(input: []const u8, borrowed: []const u8) !void {
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const borrowed_start = @intFromPtr(borrowed.ptr);
    const borrowed_end = borrowed_start + borrowed.len;
    try std.testing.expect(borrowed_start >= input_start);
    try std.testing.expect(borrowed_end <= input_end);
}

test "validateManagedSkillName accepts plain names and rejects path shapes" {
    try validateManagedSkillName("review");

    const invalid_names = [_][]const u8{ "", ".", "..", "nested/name", "nested\\name", "/absolute" };
    for (invalid_names) |name| {
        try std.testing.expectError(error.InvalidSkillName, validateManagedSkillName(name));
    }
}

test "flat skill metadata takes the file stem and the first body line" {
    const parsed = parseSkillFile("\n  Review the diff first.\nMore detail.\n");
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "review.md")) {
        .valid => |value| value,
        .invalid => |cause| {
            std.debug.print("unexpected invalid cause {s}\n", .{@tagName(cause)});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expectEqualStrings("review", metadata.name);
    try std.testing.expectEqualStrings("Review the diff first.", metadata.description);
    try std.testing.expect(!metadata.ellipsis);
    try std.testing.expectEqual(@as(usize, 22), metadata.description_len());
}

test "flat skill metadata keeps the frontmatter name and description over the stem and body" {
    const parsed = parseSkillFile("---\nname: declared\ndescription: from frontmatter\n---\nbody line\n");
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "stem.md")) {
        .valid => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("declared", metadata.name);
    try std.testing.expectEqualStrings("from frontmatter", metadata.description);
}

test "flat skill metadata falls back to the body when frontmatter has no description" {
    const parsed = parseSkillFile("---\nname: declared\n---\n\nFirst body line.\n");
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "stem.md")) {
        .valid => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("declared", metadata.name);
    try std.testing.expectEqualStrings("First body line.", metadata.description);
}

test "flat skill metadata caps the body-line description at 240 UTF-16 units with an ellipsis" {
    const long_line = &@as([300]u8, @splat('a'));
    const parsed = parseSkillFile(long_line);
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "long.md")) {
        .valid => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expect(metadata.ellipsis);
    try std.testing.expectEqual(@as(usize, 239), metadata.description.len);
    const output = try std.testing.allocator.alloc(u8, metadata.description_len());
    defer std.testing.allocator.free(output);
    metadata.write_description(output);
    try std.testing.expectEqualStrings(@as([239]u8, @splat('a')) ++ body_description_ellipsis, output);
}

test "flat skill metadata counts astral characters as two UTF-16 units" {
    const astral_line: []const u8 = comptime astral: {
        var buf: [520]u8 = undefined;
        for (0..130) |i| @memcpy(buf[i * 4 ..][0..4], "\xf0\x9f\x98\x80");
        const final = buf;
        break :astral &final;
    };
    const parsed = parseSkillFile(astral_line);
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "emoji.md")) {
        .valid => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expect(metadata.ellipsis);
    try std.testing.expectEqual(@as(usize, 119 * 4), metadata.description.len);
}

test "flat skill metadata uses the placeholder when no body text exists" {
    const parsed = parseSkillFile("\n \n\t\n");
    const metadata = switch (resolveSkillMetadata(.flat_file, parsed, "empty.md")) {
        .valid => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("No description provided.", metadata.description);
}

test "flat skill metadata rejects invalid names and broken frontmatter" {
    const bad_stem = resolveSkillMetadata(.flat_file, parseSkillFile("body\n"), "bad\\name.md");
    try std.testing.expectEqual(InvalidMetadataCause.invalid_name, bad_stem.invalid);
    const broken = resolveSkillMetadata(.flat_file, parseSkillFile("---\nname: open\nbody\n"), "open.md");
    try std.testing.expectEqual(InvalidMetadataCause.missing_closing_delimiter, broken.invalid);
    const unsupported = resolveSkillMetadata(.flat_file, parseSkillFile("---\ntype: other\n---\nbody\n"), "typed.md");
    try std.testing.expectEqual(InvalidMetadataCause.unsupported_type, unsupported.invalid);
}

test "directory skill metadata still requires name and description through resolveSkillMetadata" {
    const result = resolveSkillMetadata(.directory, parseSkillFile("body only\n"), "SKILL.md");
    try std.testing.expectEqual(InvalidMetadataCause.missing_frontmatter, result.invalid);
}
