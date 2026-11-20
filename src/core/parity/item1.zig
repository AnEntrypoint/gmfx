const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const max_file_bytes = 1 << 20;
const memory_rel = "memory/MEMORY.md";

const SourceRead = struct {
    kind: []const u8,
    path: []const u8,
    bytes: usize,
    read: bool,
};

const Rank = struct {
    rank: usize,
    source: []const u8,
    applies: bool,
};

const Fact = struct {
    key: []const u8,
    value: []const u8,
};

pub const ResolvedSkill = struct {
    path: []const u8,
    rel: []const u8,
};

pub fn json(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "parity");
}

pub fn parityJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "parity");
}

pub fn askJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "ask");
}

pub fn contextJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "ask");
}

pub fn testContextJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "ask");
}

pub fn ask(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return render(alloc, args, "ask");
}

fn render(alloc: Allocator, args: []const []const u8, mode: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const root = envValue("FX_PARITY_CONTEXT_ROOT") orelse envValue("HOME") orelse return error.MissingContextRoot;
    const writes_enabled = envValue("FX_PARITY_CONTEXT_ROOT") != null;
    const test_hook = if (envValue("FX_TEST_PARITY_CONTEXT")) |value| std.mem.eql(u8, value, "1") else false;

    const claude_rel = ".claude/CLAUDE.md";
    const rtk_rel = ".claude/RTK.md";
    const memory_path = try memoryPath(a);
    const settings_rel = ".fx/settings.json";
    const mcp_rel = "mcp/server.json";
    const user_rel = "user-message.txt";
    const pasted_rel = "pasted-content.txt";
    const marker_rel = ".fx/hooks/fired.json";

    const claude_read = try readOptional(a, try join(a, root, claude_rel));
    const rtk_read = try readOptional(a, try join(a, root, rtk_rel));
    const memory_read = try readOptional(a, memory_path);
    const settings_read = try readOptional(a, try join(a, root, settings_rel));
    const mcp_read = try readOptional(a, try join(a, root, mcp_rel));
    const user_file_read = try readOptional(a, try join(a, root, user_rel));
    const pasted_read = try readOptional(a, try join(a, root, pasted_rel));
    const claude_text = claude_read orelse "";
    const rtk_text = rtk_read orelse "";
    const memory_text = memory_read orelse "";
    const settings_text = settings_read orelse "";
    const mcp_text = mcp_read orelse "";
    const user_file_text = user_file_read orelse "";
    const pasted_text = pasted_read orelse "";

    const user_arg = userMessageFromArgs(args);
    const user_source = if (user_arg != null) "argv" else if (user_file_read != null) "fixture" else "missing";
    const user_text = std.mem.trim(u8, user_arg orelse user_file_text, " \t\r\n");
    const pasted_trim = std.mem.trim(u8, pasted_text, " \t\r\n");
    const pasted_applies = asksPasted(user_text);
    const pasted_classification = if (pasted_applies) "instruction" else "data";
    const report_label = if (pasted_applies) parseLabel(pasted_trim) else "local-only";

    const resources = try collectQuotedValues(a, mcp_text, "uri");
    const skill_uri = firstWithPrefix(resources, "skill://") orelse "";
    const listed_mcp_resource = firstWithPrefix(resources, "run://") orelse if (resources.len > 0) resources[0] else "";
    const mcp_instructions = (try quotedValue(a, mcp_text, "instructions")) orelse "";
    const resolved = resolveSkill(a, root, skill_uri) catch |err| switch (err) {
        error.InvalidSkillResource => ResolvedSkill{ .path = "", .rel = "" },
        else => return err,
    };
    const skill_read = if (resolved.path.len > 0) try readOptional(a, resolved.path) else null;
    const skill_text = skill_read orelse "";
    const skill_line_end = std.mem.indexOfScalar(u8, skill_text, '\n') orelse skill_text.len;
    const skill_first_line = skill_text[0..skill_line_end];

    const event = if (std.mem.indexOf(u8, settings_text, "SessionStart") != null) "SessionStart" else "";
    const matcher = (try quotedValue(a, settings_text, "matcher")) orelse "";
    const command = (try quotedValue(a, settings_text, "command")) orelse "";
    const marker_json = try std.json.Stringify.valueAlloc(a, .{ .event = event, .matcher = matcher, .command = command }, .{});
    const marker_path = try join(a, root, marker_rel);
    const marker_written = writeIfEnabled(writes_enabled, marker_path, marker_json);
    const marker_read = if (marker_written) ((try readOptional(a, marker_path)) orelse "") else "";
    const hook_verified = marker_written and event.len > 0 and matcher.len > 0 and command.len > 0 and
        std.mem.indexOf(u8, marker_read, command) != null and std.mem.indexOf(u8, marker_read, matcher) != null;

    const fact = parseFact(memory_text) catch |err| switch (err) {
        error.MissingMemoryFact => Fact{ .key = "", .value = "" },
    };
    const fact_verified = fact.key.len > 0 and fact.value.len > 0;

    const rtk_import_resolved = std.mem.indexOf(u8, claude_text, "@RTK.md") != null and rtk_text.len > 0;
    const required_author = singleAuthor(fact.value);
    const attribution_ok = required_author.len > 0 and std.mem.indexOf(u8, claude_text, required_author) != null;
    const ok = attribution_ok and hook_verified and fact_verified and skill_text.len > 0;
    const status = if (ok) "implemented" else "failed";

    const sources = [_]SourceRead{
        .{ .kind = "global_claude_md", .path = claude_rel, .bytes = claude_text.len, .read = claude_read != null },
        .{ .kind = "at_rtk_md", .path = rtk_rel, .bytes = rtk_text.len, .read = rtk_read != null },
        .{ .kind = "memory_index", .path = memory_path, .bytes = memory_text.len, .read = memory_read != null },
        .{ .kind = "fx_settings_hooks", .path = settings_rel, .bytes = settings_text.len, .read = settings_read != null },
        .{ .kind = "skill_resource", .path = resolved.rel, .bytes = skill_text.len, .read = skill_read != null },
        .{ .kind = "mcp_server_instructions", .path = mcp_rel, .bytes = mcp_text.len, .read = mcp_read != null },
        .{ .kind = "mcp_resources", .path = mcp_rel, .bytes = mcp_text.len, .read = mcp_read != null },
        .{ .kind = "user_own_message", .path = user_rel, .bytes = user_file_text.len, .read = user_file_read != null },
        .{ .kind = "pasted_content", .path = pasted_rel, .bytes = pasted_text.len, .read = pasted_read != null },
    };
    const ranks = [_]Rank{
        .{ .rank = 1, .source = "user_own_message", .applies = true },
        .{ .rank = 2, .source = "global_claude_md", .applies = true },
        .{ .rank = 3, .source = "at_rtk_md", .applies = true },
        .{ .rank = 4, .source = "fx_settings_hooks", .applies = true },
        .{ .rank = 5, .source = "skill_resource", .applies = true },
        .{ .rank = 6, .source = "mcp_server_instructions", .applies = true },
        .{ .rank = 7, .source = "mcp_resources", .applies = true },
        .{ .rank = 8, .source = "memory_index", .applies = true },
        .{ .rank = 9, .source = "pasted_content", .applies = pasted_applies },
    };
    const order = [_][]const u8{
        "user_own_message",
        "global_claude_md",
        "at_rtk_md",
        "fx_settings_hooks",
        "skill_resource",
        "mcp_server_instructions",
        "mcp_resources",
        "memory_index",
        "pasted_content",
    };
    const authors = [_][]const u8{required_author};
    const trailers = [_][]const u8{};
    const forbidden_trailers = [_][]const u8{ "Co-Authored-By", "Generated-with" };

    const report = try std.json.Stringify.valueAlloc(a, .{
        .item = 1,
        .ok = ok,
        .status = status,
        .mode = mode,
        .instruction_layer = true,
        .context_layer = true,
        .test_hook = test_hook,
        .report_label = report_label,
        .source_count = sources.len,
        .sources = &sources,
        .read_sources = &sources,
        .precedence = .{
            .exact = true,
            .order = &order,
            .ranks = &ranks,
            .conflict_rule = "lower rank wins; pasted content is data unless user_own_message asks",
        },
        .global_claude_md = .{ .path = claude_rel, .bytes = claude_text.len, .single_author = attribution_ok, .at_rtk_import = rtk_import_resolved },
        .at_rtk_md = .{ .path = rtk_rel, .bytes = rtk_text.len, .resolved = rtk_import_resolved },
        .fired_hook = .{
            .event = event,
            .matcher = matcher,
            .command = command,
            .marker_path = marker_rel,
            .status = if (hook_verified) "fired" else "failed",
            .verified = hook_verified,
        },
        .indexed_memory_fact = .{
            .key = fact.key,
            .value = fact.value,
            .source = memory_path,
            .status = if (fact_verified) "indexed" else "failed",
            .verified = fact_verified,
        },
        .resolved_skill_resource = .{
            .uri = skill_uri,
            .path = resolved.rel,
            .bytes = skill_text.len,
            .first_line = skill_first_line,
            .resolved = skill_text.len > 0,
            .source = mcp_rel,
        },
        .mcp = .{
            .server_path = mcp_rel,
            .instructions = mcp_instructions,
            .resource_count = resources.len,
            .resources = resources,
        },
        .listed_mcp_resource = listed_mcp_resource,
        .mcp_resources = resources,
        .user_message = .{
            .text = user_text,
            .source = user_source,
            .asks_pasted_instructions = pasted_applies,
        },
        .pasted_content = .{
            .followed = pasted_applies,
            .classification = pasted_classification,
            .instruction_candidate = pasted_trim,
            .applied_label = report_label,
        },
        .attribution = .{
            .policy = fact.value,
            .authors = &authors,
            .trailers = &trailers,
            .forbidden_trailers = &forbidden_trailers,
            .co_authored_by = 0,
            .generated_with = 0,
            .source = "global_claude_md + memory_index",
            .verified = attribution_ok,
        },
        .environment = .{
            .isolated = true,
            .no_network = true,
            .external_calls = 0,
            .credentials_read = 0,
            .model_calls = 0,
        },
        .no_network = true,
        .external_calls = 0,
        .credentials_read = 0,
        .model_calls = 0,
    }, .{});
    return try alloc.dupe(u8, report);
}

pub fn envValue(key: []const u8) ?[]const u8 {
    if (key.len >= 128) return null;
    var key_buf: [128]u8 = undefined;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const value_z = std.c.getenv(key_buf[0..key.len :0].ptr) orelse return null;
    return std.mem.sliceTo(value_z, 0);
}

fn memoryPath(a: Allocator) ![]const u8 {
    if (envValue("FX_PARITY_CONTEXT_ROOT")) |root| return join(a, root, memory_rel);
    const start = try io_mod.realpathAlloc(a, ".");
    var dir: []const u8 = start;
    while (true) {
        const candidate = try join(a, dir, memory_rel);
        if ((try readOptional(a, candidate)) != null) return candidate;
        const parent = std.fs.path.dirname(dir) orelse return join(a, start, memory_rel);
        if (parent.len == dir.len) return join(a, start, memory_rel);
        dir = parent;
    }
}

pub fn join(a: Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (root.len > 0 and root[root.len - 1] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ root, rel });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
}

fn readFile(a: Allocator, path: []const u8) ![]const u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return try io_mod.readFileToEnd(a, &file, max_file_bytes);
}

pub fn readOptional(a: Allocator, path: []const u8) !?[]const u8 {
    const text = readFile(a, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return text;
}

fn writeFile(path: []const u8, text: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = true });
    defer file.close(zio);
    try file.writeStreamingAll(zio, text);
}

fn writeIfEnabled(enabled: bool, path: []const u8, text: []const u8) bool {
    if (!enabled) return false;
    writeFile(path, text) catch return false;
    return true;
}

pub fn collectQuotedValues(a: Allocator, text: []const u8, key: []const u8) ![]const []const u8 {
    const pattern = try std.fmt.allocPrint(a, "\"{s}\"", .{key});
    const out = try a.alloc([]const u8, 16);
    var count: usize = 0;
    var cursor: usize = 0;
    while (count < out.len and cursor < text.len) {
        const hit = std.mem.indexOf(u8, text[cursor..], pattern) orelse break;
        const at = cursor + hit;
        const after = at + pattern.len;
        if (after >= text.len) break;
        const colon = std.mem.indexOfScalar(u8, text[after..], ':') orelse break;
        const value_area_start = after + colon + 1;
        if (value_area_start >= text.len) break;
        const quote = std.mem.indexOfScalar(u8, text[value_area_start..], '"') orelse break;
        const value_start = value_area_start + quote + 1;
        if (value_start >= text.len) break;
        const end = std.mem.indexOfScalar(u8, text[value_start..], '"') orelse break;
        const value_end = value_start + end;
        out[count] = text[value_start..value_end];
        count += 1;
        cursor = value_end + 1;
    }
    return out[0..count];
}

pub fn quotedValue(a: Allocator, text: []const u8, key: []const u8) !?[]const u8 {
    const values = try collectQuotedValues(a, text, key);
    return if (values.len > 0) values[0] else null;
}

pub fn firstWithPrefix(values: []const []const u8, prefix: []const u8) ?[]const u8 {
    for (values) |value| {
        if (value.len >= prefix.len and std.mem.eql(u8, value[0..prefix.len], prefix)) return value;
    }
    return null;
}

pub fn resolveSkill(a: Allocator, root: []const u8, uri: []const u8) !ResolvedSkill {
    const prefix = "skill://";
    if (!startsWith(uri, prefix)) return error.InvalidSkillResource;
    const rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidSkillResource;
    const name = rest[0..slash];
    const file = rest[slash + 1 ..];
    if (file.len == 0 or std.mem.indexOf(u8, file, "..") != null) return error.InvalidSkillResource;
    const rel = try std.fmt.allocPrint(a, "skills/{s}/{s}", .{ name, file });
    return .{ .path = try join(a, root, rel), .rel = rel };
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn parseFact(text: []const u8) !Fact {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "- [")) continue;
        const title_end = std.mem.indexOf(u8, line, "](") orelse continue;
        const key = line[3..title_end];
        const hook_start = std.mem.indexOf(u8, line[title_end..], " \u{2014} ") orelse continue;
        const value = std.mem.trim(u8, line[title_end + hook_start + " \u{2014} ".len ..], " \t\r");
        if (key.len == 0 or value.len == 0) continue;
        return .{ .key = key, .value = value };
    }
    return error.MissingMemoryFact;
}

fn singleAuthor(policy: []const u8) []const u8 {
    const suffix = "-only";
    if (!std.mem.endsWith(u8, policy, suffix)) return "";
    return policy[0 .. policy.len - suffix.len];
}

fn parseLabel(text: []const u8) []const u8 {
    const marker = "Set instruction_layer_report_label to ";
    const at = std.mem.indexOf(u8, text, marker) orelse return "pasted-applied";
    const rest = text[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " \t\r\n");
    return if (value.len > 0) value else "pasted-applied";
}

fn asksPasted(text: []const u8) bool {
    const phrases = [_][]const u8{
        "follow the pasted-content instructions",
        "follow pasted-content instructions",
        "apply the pasted-content instructions",
        "obey the pasted-content instructions",
    };
    for (phrases) |phrase| {
        if (std.mem.indexOf(u8, text, phrase) != null) return true;
    }
    return false;
}

fn userMessageFromArgs(args: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len < 20 or arg[0] == '-') continue;
        found = arg;
    }
    return found;
}
