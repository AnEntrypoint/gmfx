const std = @import("std");
const io_mod = @import("../shared/io.zig");
const external = @import("../hooks/external.zig");
const claude_hooks = @import("claude_hooks.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const root_manifest_name = "kimi.plugin.json";
pub const dir_manifest_path = ".kimi-plugin/plugin.json";
pub const claude_manifest_path = ".claude-plugin/plugin.json";
const claude_default_skills_dir = "skills";
const claude_default_commands_dir = "commands";
pub const user_config_placeholder_prefix = "${user_config.";
pub const system_prompt_max_bytes: usize = 32 * 1024;
const max_manifest_bytes: usize = 1024 * 1024;
const utf8_bom = "\xEF\xBB\xBF";

const unsupported_runtime_fields = [_][]const u8{
    "tools", "apps", "inject", "configFile", "config_file", "bootstrap",
};

pub const Severity = enum { err, warn, info };

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
};

pub const ManifestKind = enum { root, dir, claude };

pub const Author = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const Command = struct {
    path: []const u8,
    name: []const u8,
    content: ?[]const u8 = null,
    description: ?[]const u8 = null,
    argument_hint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    allowed_tools: []const []const u8 = &.{},
};

pub const UserConfigOption = struct {
    key: []const u8,
    description: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    sensitive: bool = false,
};

pub const Manifest = struct {
    name: []const u8,
    id: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
    author: ?Author = null,
    skills: []const []const u8 = &.{},
    root_skill_fallback: bool = false,
    agents: []const []const u8 = &.{},
    session_start_skill: ?[]const u8 = null,
    skill_instructions: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    mcp_servers: ?Value = null,
    hooks: []const external.Definition = &.{},
    commands: []const Command = &.{},
    interface: ?Value = null,
    user_config: []const UserConfigOption = &.{},
    default_enabled: bool = true,
};

pub const Result = struct {
    manifest: ?Manifest = null,
    kind: ?ManifestKind = null,
    manifest_path: ?[]const u8 = null,
    shadowed_manifest_path: ?[]const u8 = null,
    diagnostics: []const Diagnostic = &.{},
};

pub fn isValidName(name: []const u8) bool {
    const at = std.mem.findScalar(u8, name, '@');
    const base = if (at) |index| name[0..index] else name;
    if (at) |index| {
        if (!isNameSegment(name[index + 1 ..])) return false;
    }
    var parts = std.mem.splitScalar(u8, base, '.');
    while (parts.next()) |part| {
        if (!isNameSegment(part)) return false;
    }
    return true;
}

fn isNameSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    for (segment) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

pub fn parse(arena: Allocator, plugin_root: []const u8) !Result {
    const io = io_mod.getIo();
    const root_json = try std.Io.Dir.path.join(arena, &.{ plugin_root, root_manifest_name });
    const dir_json = try std.Io.Dir.path.join(arena, &.{ plugin_root, dir_manifest_path });
    const claude_json = try std.Io.Dir.path.join(arena, &.{ plugin_root, claude_manifest_path });
    const root_exists = isFile(io, root_json);
    const dir_exists = isFile(io, dir_json);
    const claude_exists = isFile(io, claude_json);

    var ctx: Context = .{ .arena = arena, .root = plugin_root };
    if (!root_exists and !dir_exists and !claude_exists) {
        try ctx.add(.err, "No manifest at {s}, {s} or {s}", .{ root_manifest_name, dir_manifest_path, claude_manifest_path });
        return ctx.finish(.{});
    }

    const kind: ManifestKind = if (root_exists) .root else if (dir_exists) .dir else .claude;
    ctx.kind = kind;
    const manifest_path = switch (kind) {
        .root => root_json,
        .dir => dir_json,
        .claude => claude_json,
    };
    var result: Result = .{
        .kind = kind,
        .manifest_path = manifest_path,
        .shadowed_manifest_path = if (root_exists and dir_exists) dir_json else null,
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(max_manifest_bytes + 1)) catch |err| {
        try ctx.add(.err, "Failed to read manifest: {s}", .{@errorName(err)});
        return ctx.finish(result);
    };
    const raw = std.json.parseFromSliceLeaky(Value, arena, bytes, .{}) catch |err| {
        try ctx.add(.err, "Failed to parse manifest: {s}", .{@errorName(err)});
        return ctx.finish(result);
    };
    if (raw != .object) {
        try ctx.add(.err, "manifest must be a JSON object", .{});
        return ctx.finish(result);
    }
    const object = raw.object;

    const name = trimmedField(object, "name") orelse {
        try ctx.add(.err, "\"name\" is required", .{});
        return ctx.finish(result);
    };
    if (!isValidName(name)) {
        try ctx.add(.err, "\"name\" must match ^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*(@[A-Za-z0-9_-]+)?$ (got \"{s}\")", .{name});
        return ctx.finish(result);
    }

    var manifest: Manifest = .{
        .name = name,
        .id = try normalizeId(arena, name),
        .version = trimmedField(object, "version"),
        .description = trimmedField(object, "description"),
        .homepage = trimmedField(object, "homepage"),
        .license = trimmedField(object, "license"),
        .keywords = (try stringArrayField(arena, object, "keywords")) orelse &.{},
        .author = try readAuthor(object.get("author")),
        .skill_instructions = rawStringField(object, "skillInstructions"),
    };

    manifest.skills = (try ctx.dirList("skills", object.get("skills"))) orelse &.{};
    if (object.get("skills") == null) {
        const root_skill = try std.Io.Dir.path.join(arena, &.{ plugin_root, "SKILL.md" });
        if (isFile(io, root_skill)) {
            manifest.skills = try arena.dupe([]const u8, &.{plugin_root});
            manifest.root_skill_fallback = true;
        }
    }
    if (kind == .claude and !manifest.root_skill_fallback) {
        manifest.skills = try ctx.withDefaultDir(manifest.skills, claude_default_skills_dir);
    }

    manifest.agents = (try ctx.dirList("agents", object.get("agents"))) orelse &.{};
    if (object.get("agents") == null) {
        const agents_dir = try std.Io.Dir.path.join(arena, &.{ plugin_root, "agents" });
        if (isDir(io, agents_dir)) manifest.agents = try arena.dupe([]const u8, &.{agents_dir});
    }

    manifest.session_start_skill = try ctx.sessionStart(object.get("sessionStart"));
    manifest.system_prompt = try ctx.systemPrompt(object);
    manifest.mcp_servers = try ctx.mcpServers(object.get("mcpServers"));
    manifest.hooks = try ctx.hooks(object.get("hooks"), plugin_root);
    manifest.commands = try ctx.commands(object.get("commands"));
    manifest.interface = interfaceObject(object.get("interface"));
    manifest.user_config = try ctx.userConfig(object.get("userConfig"));
    if (object.get("defaultEnabled")) |flag| {
        if (flag == .bool) {
            manifest.default_enabled = flag.bool;
        } else {
            try ctx.add(.warn, "\"defaultEnabled\" must be true or false", .{});
        }
    }

    for (unsupported_runtime_fields) |field| {
        if (object.get(field) == null) continue;
        try ctx.add(.info, "\"{s}\" is present but not supported by plugins", .{field});
    }

    result.manifest = manifest;
    return ctx.finish(result);
}

const Context = struct {
    arena: Allocator,
    root: []const u8,
    kind: ManifestKind = .root,
    loaded_hook_files: std.ArrayList([]const u8) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    fn add(self: *Context, severity: Severity, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.diagnostics.append(self.arena, .{ .severity = severity, .message = message });
    }

    fn finish(self: *Context, base: Result) !Result {
        var result = base;
        result.diagnostics = try self.diagnostics.toOwnedSlice(self.arena);
        return result;
    }

    fn dirList(self: *Context, field: []const u8, value: ?Value) !?[]const []const u8 {
        const raw = value orelse return null;
        const entries = (try stringList(self.arena, raw)) orelse {
            try self.add(.err, "\"{s}\" must be a string or string[]", .{field});
            return &.{};
        };
        var resolved: std.ArrayList([]const u8) = .empty;
        for (entries) |entry| {
            if (!std.mem.startsWith(u8, entry, "./")) {
                try self.add(.err, "\"{s}\" path must start with \"./\" (got \"{s}\")", .{ field, entry });
                continue;
            }
            const real = (try self.containedPath(entry)) orelse {
                try self.add(.err, "\"{s}\" path resolves outside the plugin ({s})", .{ field, entry });
                continue;
            };
            if (!isDir(io_mod.getIo(), real)) {
                try self.add(.warn, "\"{s}\" path is not a directory ({s})", .{ field, entry });
                continue;
            }
            try resolved.append(self.arena, real);
        }
        return try resolved.toOwnedSlice(self.arena);
    }

    fn containedPath(self: *Context, entry: []const u8) !?[]const u8 {
        return resolveInside(self.arena, self.root, entry);
    }

    fn mcpServers(self: *Context, value: ?Value) !?Value {
        const raw = value orelse return null;
        if (raw != .object) {
            try self.add(.warn, "\"mcpServers\" must be an object", .{});
            return null;
        }
        return raw;
    }

    fn withDefaultDir(self: *Context, listed: []const []const u8, name: []const u8) ![]const []const u8 {
        const io = io_mod.getIo();
        const joined = try std.Io.Dir.path.join(self.arena, &.{ self.root, name });
        if (!isDir(io, joined)) return listed;
        const real = realPathOr(io, self.arena, joined);
        for (listed) |path| {
            if (std.mem.eql(u8, path, real)) return listed;
        }
        const out = try self.arena.alloc([]const u8, listed.len + 1);
        out[0] = real;
        @memcpy(out[1..], listed);
        return out;
    }

    fn hooks(self: *Context, value: ?Value, plugin_root: []const u8) ![]const external.Definition {
        var found: std.ArrayList(external.Definition) = .empty;
        if (value) |raw| {
            if (isEventDefinitionArray(raw)) {
                try self.appendEventDefinitions(&found, raw, plugin_root);
            } else switch (raw) {
                .array => |entries| for (entries.items) |entry| try self.appendClaudeHooksEntry(&found, entry, plugin_root),
                else => try self.appendClaudeHooksEntry(&found, raw, plugin_root),
            }
        }
        if (self.kind == .claude) {
            const default_file = try std.Io.Dir.path.join(self.arena, &.{ plugin_root, claude_hooks.default_hooks_path });
            if (isFile(io_mod.getIo(), default_file)) {
                try self.appendClaudeHooksFile(&found, "./" ++ claude_hooks.default_hooks_path, plugin_root);
            }
        }
        return found.toOwnedSlice(self.arena);
    }

    fn appendEventDefinitions(self: *Context, found: *std.ArrayList(external.Definition), raw: Value, plugin_root: []const u8) !void {
        const parsed = external.parseDefinitionsIn(self.arena, raw, plugin_root) catch |err| switch (err) {
            error.InvalidHooksConfig => {
                try self.add(.warn, "\"hooks\" has an invalid entry; no plugin hooks were loaded", .{});
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try found.appendSlice(self.arena, parsed);
    }

    fn appendClaudeHooksEntry(self: *Context, found: *std.ArrayList(external.Definition), entry: Value, plugin_root: []const u8) !void {
        switch (entry) {
            .string => |path| try self.appendClaudeHooksFile(found, path, plugin_root),
            .object => try self.appendClaudeHooks(found, entry, plugin_root),
            else => try self.add(.warn, "\"hooks\" must be an array of hook entries, a hooks object, or a ./ path to a .json file", .{}),
        }
    }

    fn appendClaudeHooksFile(self: *Context, found: *std.ArrayList(external.Definition), entry: []const u8, plugin_root: []const u8) !void {
        if (!std.mem.startsWith(u8, entry, "./")) {
            try self.add(.warn, "\"hooks\" path must start with \"./\" (got \"{s}\")", .{entry});
            return;
        }
        const real = (try self.containedPath(entry)) orelse {
            try self.add(.warn, "\"hooks\" path resolves outside the plugin ({s})", .{entry});
            return;
        };
        for (self.loaded_hook_files.items) |loaded| {
            if (std.mem.eql(u8, loaded, real)) return;
        }
        try self.loaded_hook_files.append(self.arena, real);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), real, self.arena, .limited(max_manifest_bytes + 1)) catch |err| {
            try self.add(.warn, "Failed to read \"hooks\" file ({s}): {s}", .{ entry, @errorName(err) });
            return;
        };
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, bytes, .{}) catch |err| {
            try self.add(.warn, "Failed to parse \"hooks\" file ({s}): {s}", .{ entry, @errorName(err) });
            return;
        };
        try self.appendClaudeHooks(found, parsed, plugin_root);
    }

    fn appendClaudeHooks(self: *Context, found: *std.ArrayList(external.Definition), value: Value, plugin_root: []const u8) !void {
        const parsed = try claude_hooks.parse(self.arena, value, plugin_root);
        try found.appendSlice(self.arena, parsed.definitions);
        for (parsed.skipped) |reason| try self.add(.warn, "\"hooks\": {s}", .{reason});
    }

    fn commands(self: *Context, value: ?Value) ![]const Command {
        const raw = value orelse return self.defaultCommands();
        if (raw == .object) return self.commandMap(raw.object);
        const entries = (try stringList(self.arena, raw)) orelse {
            try self.add(.warn, "\"commands\" must be a string, string[] or an object map", .{});
            return &.{};
        };
        var found: std.ArrayList(Command) = .empty;
        const io = io_mod.getIo();
        for (entries) |entry| {
            if (!std.mem.startsWith(u8, entry, "./")) {
                try self.add(.err, "\"commands\" path must start with \"./\" (got \"{s}\")", .{entry});
                continue;
            }
            const real = (try self.containedPath(entry)) orelse {
                try self.add(.err, "\"commands\" path resolves outside the plugin ({s})", .{entry});
                continue;
            };
            if (isDir(io, real)) {
                try self.collectMarkdown(real, real, &found);
            } else if (isFile(io, real) and std.mem.endsWith(u8, real, ".md")) {
                const base = std.Io.Dir.path.basename(real);
                try found.append(self.arena, .{ .path = real, .name = base[0 .. base.len - ".md".len] });
            } else {
                try self.add(.warn, "\"commands\" entry must be a directory or .md file ({s})", .{entry});
            }
        }
        return self.finishCommands(&found);
    }

    fn finishCommands(self: *Context, found: *std.ArrayList(Command)) ![]const Command {
        if (self.kind == .claude) {
            for (found.items) |*command| {
                command.name = try std.mem.replaceOwned(u8, self.arena, command.name, "/", ":");
            }
        }
        std.mem.sort(Command, found.items, {}, lessThanCommand);
        return found.toOwnedSlice(self.arena);
    }

    fn defaultCommands(self: *Context) ![]const Command {
        if (self.kind != .claude) return &.{};
        const io = io_mod.getIo();
        const joined = try std.Io.Dir.path.join(self.arena, &.{ self.root, claude_default_commands_dir });
        if (!isDir(io, joined)) return &.{};
        const real = realPathOr(io, self.arena, joined);
        var found: std.ArrayList(Command) = .empty;
        try self.collectMarkdown(real, real, &found);
        return self.finishCommands(&found);
    }

    fn commandMap(self: *Context, entries: ObjectMap) ![]const Command {
        var found: std.ArrayList(Command) = .empty;
        var iterator = entries.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const spec = entry.value_ptr.*;
            switch (spec) {
                .string => |source| {
                    if (try self.commandSource(name, source)) |path| try found.append(self.arena, .{ .path = path, .name = name });
                },
                .object => |fields| {
                    var command: Command = .{
                        .path = self.root,
                        .name = name,
                        .description = trimmedField(fields, "description"),
                        .argument_hint = trimmedField(fields, "argumentHint"),
                        .model = trimmedField(fields, "model"),
                    };
                    if (fields.get("allowedTools")) |tools| {
                        command.allowed_tools = (try stringList(self.arena, tools)) orelse &.{};
                    }
                    if (rawStringField(fields, "content")) |content| {
                        command.content = content;
                    } else if (rawStringField(fields, "source")) |source| {
                        command.path = (try self.commandSource(name, source)) orelse continue;
                    } else {
                        try self.add(.warn, "\"commands\" entry \"{s}\" needs a source or content", .{name});
                        continue;
                    }
                    try found.append(self.arena, command);
                },
                else => try self.add(.warn, "\"commands\" entry \"{s}\" must be a path or an object", .{name}),
            }
        }
        return self.finishCommands(&found);
    }

    fn commandSource(self: *Context, name: []const u8, source: []const u8) !?[]const u8 {
        if (!std.mem.startsWith(u8, source, "./")) {
            try self.add(.err, "\"commands\" entry \"{s}\" source must start with \"./\" (got \"{s}\")", .{ name, source });
            return null;
        }
        const real = (try self.containedPath(source)) orelse {
            try self.add(.err, "\"commands\" entry \"{s}\" source resolves outside the plugin ({s})", .{ name, source });
            return null;
        };
        if (!isFile(io_mod.getIo(), real) or !std.mem.endsWith(u8, real, ".md")) {
            try self.add(.warn, "\"commands\" entry \"{s}\" source must be a .md file ({s})", .{ name, source });
            return null;
        }
        return real;
    }

    fn userConfig(self: *Context, value: ?Value) ![]const UserConfigOption {
        const raw = value orelse return &.{};
        if (raw != .object) {
            try self.add(.warn, "\"userConfig\" must be an object", .{});
            return &.{};
        }
        var found: std.ArrayList(UserConfigOption) = .empty;
        var iterator = raw.object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!isUserConfigKey(key)) {
                try self.add(.warn, "\"userConfig\" key \"{s}\" must be letters, digits and underscores", .{key});
                continue;
            }
            const spec = entry.value_ptr.*;
            if (spec != .object) {
                try self.add(.warn, "\"userConfig\" entry \"{s}\" must be an object", .{key});
                continue;
            }
            const sensitive = if (spec.object.get("sensitive")) |flag| flag == .bool and flag.bool else false;
            try found.append(self.arena, .{
                .key = key,
                .description = trimmedField(spec.object, "description"),
                .default_value = try scalarText(self.arena, spec.object.get("default")),
                .sensitive = sensitive,
            });
        }
        return found.toOwnedSlice(self.arena);
    }

    fn collectMarkdown(self: *Context, root: []const u8, dir: []const u8, found: *std.ArrayList(Command)) !void {
        const io = io_mod.getIo();
        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer handle.close(io);
        var entries = handle.iterate();
        while (try entries.next(io)) |entry| {
            const full = try std.Io.Dir.path.join(self.arena, &.{ dir, entry.name });
            switch (entry.kind) {
                .directory => try self.collectMarkdown(root, full, found),
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                    const relative = full[root.len + 1 ..];
                    try found.append(self.arena, .{ .path = full, .name = relative[0 .. relative.len - ".md".len] });
                },
                else => {},
            }
        }
    }

    fn sessionStart(self: *Context, value: ?Value) !?[]const u8 {
        const raw = value orelse return null;
        if (raw != .object) {
            try self.add(.warn, "\"sessionStart\" must be an object", .{});
            return null;
        }
        return trimmedField(raw.object, "skill") orelse {
            try self.add(.warn, "\"sessionStart.skill\" is required when sessionStart is present", .{});
            return null;
        };
    }

    fn systemPrompt(self: *Context, object: ObjectMap) !?[]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        if (object.get("systemPrompt")) |value| {
            if (value != .string) try self.add(.warn, "\"systemPrompt\" must be a string", .{});
        }
        if (trimmedField(object, "systemPrompt")) |inline_prompt| {
            if (inline_prompt.len > system_prompt_max_bytes) {
                try self.add(.warn, "\"systemPrompt\" is {d} bytes, exceeding the {d} KB limit; the field is ignored", .{ inline_prompt.len, system_prompt_max_bytes / 1024 });
            } else {
                try parts.append(self.arena, inline_prompt);
            }
        }
        if (object.get("systemPromptPath")) |value| {
            if (try self.systemPromptFile(value)) |content| try parts.append(self.arena, content);
        }
        if (parts.items.len == 0) return null;
        return try std.mem.join(self.arena, "\n\n", parts.items);
    }

    fn systemPromptFile(self: *Context, value: Value) !?[]const u8 {
        if (value != .string) {
            try self.add(.warn, "\"systemPromptPath\" must be a string", .{});
            return null;
        }
        const entry = std.mem.trim(u8, value.string, " \t\r\n");
        if (entry.len == 0) {
            try self.add(.warn, "\"systemPromptPath\" must not be blank", .{});
            return null;
        }
        if (!std.mem.startsWith(u8, entry, "./")) {
            try self.add(.warn, "\"systemPromptPath\" path must start with \"./\" (got \"{s}\")", .{entry});
            return null;
        }
        const io = io_mod.getIo();
        const real = (try self.containedPath(entry)) orelse {
            try self.add(.warn, "\"systemPromptPath\" path resolves outside the plugin ({s})", .{entry});
            return null;
        };
        const stat = std.Io.Dir.cwd().statFile(io, real, .{}) catch {
            try self.add(.warn, "\"systemPromptPath\" is not a file ({s})", .{entry});
            return null;
        };
        if (stat.kind != .file) {
            try self.add(.warn, "\"systemPromptPath\" is not a file ({s})", .{entry});
            return null;
        }
        if (stat.size > system_prompt_max_bytes) {
            try self.add(.warn, "\"systemPromptPath\" is {d} bytes, exceeding the {d} KB limit; the file is ignored ({s})", .{ stat.size, system_prompt_max_bytes / 1024, entry });
            return null;
        }
        const raw = std.Io.Dir.cwd().readFileAlloc(io, real, self.arena, .limited(system_prompt_max_bytes + 1)) catch |err| {
            try self.add(.warn, "Failed to read \"systemPromptPath\" ({s}): {s}", .{ entry, @errorName(err) });
            return null;
        };
        const without_bom = if (std.mem.startsWith(u8, raw, utf8_bom)) raw[utf8_bom.len..] else raw;
        const content = std.mem.trim(u8, without_bom, " \t\r\n");
        return if (content.len == 0) null else content;
    }
};

fn isEventDefinitionArray(value: Value) bool {
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .object and item.object.get("event") != null) return true;
    }
    return false;
}

pub fn isUserConfigKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn scalarText(arena: Allocator, value: ?Value) !?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .number_string => |text| text,
        else => null,
    };
}

pub fn userConfigValue(options: []const UserConfigOption, key: []const u8) ?[]const u8 {
    for (options) |option| {
        if (std.mem.eql(u8, option.key, key)) return option.default_value;
    }
    return null;
}

fn lessThanCommand(_: void, lhs: Command, rhs: Command) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn interfaceObject(value: ?Value) ?Value {
    const raw = value orelse return null;
    return if (raw == .object) raw else null;
}

fn readAuthor(value: ?Value) !?Author {
    const raw = value orelse return null;
    switch (raw) {
        .string => |name| return Author{ .name = name },
        .object => |object| {
            const name = trimmedField(object, "name");
            const email = trimmedField(object, "email");
            if (name == null and email == null) return null;
            return Author{ .name = name, .email = email };
        },
        else => return null,
    }
}

fn stringList(arena: Allocator, value: Value) !?[]const []const u8 {
    switch (value) {
        .string => |text| {
            const out = try arena.alloc([]const u8, 1);
            out[0] = text;
            return out;
        },
        .array => |array| {
            const out = try arena.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, index| {
                if (item != .string) return null;
                out[index] = item.string;
            }
            return out;
        },
        else => return null,
    }
}

fn stringArrayField(arena: Allocator, object: ObjectMap, key: []const u8) !?[]const []const u8 {
    const value = object.get(key) orelse return null;
    if (value != .array) return null;
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return null;
        out[index] = item.string;
    }
    return out;
}

fn rawStringField(object: ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn trimmedField(object: ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn normalizeId(arena: Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

pub fn resolveInside(arena: Allocator, root: []const u8, entry: []const u8) !?[]const u8 {
    const io = io_mod.getIo();
    const absolute = try std.Io.Dir.path.resolveAlloc(arena, &.{ root, entry });
    const root_real = realPathOr(io, arena, root);
    const real = realPathOr(io, arena, absolute);
    return if (isWithin(real, root_real)) real else null;
}

fn realPathOr(io: std.Io, arena: Allocator, path: []const u8) []const u8 {
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch return path;
    return real;
}

fn isWithin(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return (parent.len > 0 and parent[parent.len - 1] == '/') or child[parent.len] == '/';
}

fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn isDir(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

test "manifest name accepts the plugin id grammar" {
    try std.testing.expect(isValidName("review"));
    try std.testing.expect(isValidName("My_Plugin-2"));
    try std.testing.expect(isValidName("acme.tools"));
    try std.testing.expect(isValidName("acme.tools@market"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("bad name"));
    try std.testing.expect(!isValidName("trailing."));
    try std.testing.expect(!isValidName(".leading"));
    try std.testing.expect(!isValidName("a..b"));
    try std.testing.expect(!isValidName("a@b@c"));
    try std.testing.expect(!isValidName("a@"));
    try std.testing.expect(!isValidName("../escape"));
}

test "manifest containment accepts the root and its children only" {
    try std.testing.expect(isWithin("/plugins/a", "/plugins/a"));
    try std.testing.expect(isWithin("/plugins/a/skills", "/plugins/a"));
    try std.testing.expect(!isWithin("/plugins/ab", "/plugins/a"));
    try std.testing.expect(!isWithin("/plugins/outside", "/plugins/a"));
    try std.testing.expect(isWithin("/x", "/"));
}

fn writeFixture(tmp: *std.testing.TmpDir, sub_path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |dir| try tmp.dir.createDirPath(std.testing.io, dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

fn tmpRoot(tmp: *std.testing.TmpDir, arena: Allocator) ![]const u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
}

test "manifest root file wins over the dot-directory file and reports it shadowed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"root-one\"}");
    try writeFixture(&tmp, ".kimi-plugin/plugin.json", "{\"name\":\"dir-one\"}");
    const root = try tmpRoot(&tmp, arena);

    const result = try parse(arena, root);
    try std.testing.expectEqual(ManifestKind.root, result.kind.?);
    try std.testing.expect(std.mem.endsWith(u8, result.shadowed_manifest_path.?, ".kimi-plugin/plugin.json"));
    try std.testing.expectEqualStrings("root-one", result.manifest.?.name);
}

test "manifest falls back to the dot-directory file and lowercases the id" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".kimi-plugin/plugin.json", "{\"name\":\"Acme.Tools\",\"version\":\" 1.2 \",\"keywords\":[\"a\",\"b\"]}");
    const root = try tmpRoot(&tmp, arena);

    const result = try parse(arena, root);
    try std.testing.expectEqual(ManifestKind.dir, result.kind.?);
    try std.testing.expect(result.shadowed_manifest_path == null);
    const manifest = result.manifest.?;
    try std.testing.expectEqualStrings("Acme.Tools", manifest.name);
    try std.testing.expectEqualStrings("acme.tools", manifest.id);
    try std.testing.expectEqualStrings("1.2", manifest.version.?);
    try std.testing.expectEqual(@as(usize, 2), manifest.keywords.len);
}

test "manifest without any file reports the missing manifest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, arena);

    const result = try parse(arena, root);
    try std.testing.expect(result.manifest == null);
    try std.testing.expectEqual(Severity.err, result.diagnostics[0].severity);
}

test "manifest rejects an invalid name and a missing name without a manifest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"bad name\"}");
    const root = try tmpRoot(&tmp, arena);
    const invalid = try parse(arena, root);
    try std.testing.expect(invalid.manifest == null);

    var tmp_missing = std.testing.tmpDir(.{});
    defer tmp_missing.cleanup();
    try writeFixture(&tmp_missing, "kimi.plugin.json", "{\"version\":\"1\"}");
    const missing_root = try tmpRoot(&tmp_missing, arena);
    const missing = try parse(arena, missing_root);
    try std.testing.expect(missing.manifest == null);
    try std.testing.expectEqualStrings("\"name\" is required", missing.diagnostics[0].message);
}

test "manifest defaults to the root SKILL.md and the agents directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"defaults\"}");
    try writeFixture(&tmp, "SKILL.md", "---\nname: root\n---\n");
    try writeFixture(&tmp, "agents/helper.md", "helper");
    const root = try tmpRoot(&tmp, arena);

    const manifest = (try parse(arena, root)).manifest.?;
    try std.testing.expect(manifest.root_skill_fallback);
    try std.testing.expectEqual(@as(usize, 1), manifest.skills.len);
    try std.testing.expectEqualStrings(root, manifest.skills[0]);
    try std.testing.expectEqual(@as(usize, 1), manifest.agents.len);
    try std.testing.expect(std.mem.endsWith(u8, manifest.agents[0], "/agents"));
}

test "manifest keeps contained directory fields and rejects escapes and bare paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"paths\",\"skills\":[\"./skills\",\"../outside\",\"skills\"],\"agents\":\"./missing\"}");
    try writeFixture(&tmp, "skills/a/SKILL.md", "x");
    const root = try tmpRoot(&tmp, arena);

    const result = try parse(arena, root);
    const manifest = result.manifest.?;
    try std.testing.expectEqual(@as(usize, 1), manifest.skills.len);
    try std.testing.expect(std.mem.endsWith(u8, manifest.skills[0], "/skills"));
    try std.testing.expect(!manifest.root_skill_fallback);
    try std.testing.expectEqual(@as(usize, 0), manifest.agents.len);
    var errors: usize = 0;
    var warnings: usize = 0;
    for (result.diagnostics) |diagnostic| switch (diagnostic.severity) {
        .err => errors += 1,
        .warn => warnings += 1,
        .info => {},
    };
    try std.testing.expectEqual(@as(usize, 2), errors);
    try std.testing.expectEqual(@as(usize, 1), warnings);
}

test "manifest joins inline and file system prompts and drops oversized ones" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"prompts\",\"systemPrompt\":\"  inline  \",\"systemPromptPath\":\"./prompt.md\"}");
    try writeFixture(&tmp, "prompt.md", "\xEF\xBB\xBF file body \n");
    const root = try tmpRoot(&tmp, arena);

    const manifest = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqualStrings("inline\n\nfile body", manifest.system_prompt.?);

    var big = std.testing.tmpDir(.{});
    defer big.cleanup();
    const oversized = try arena.alloc(u8, system_prompt_max_bytes + 1);
    @memset(oversized, 'x');
    const big_manifest = try std.fmt.allocPrint(arena, "{{\"name\":\"big\",\"systemPrompt\":\"{s}\"}}", .{oversized});
    try writeFixture(&big, "kimi.plugin.json", big_manifest);
    const big_root = try tmpRoot(&big, arena);
    const big_result = try parse(arena, big_root);
    try std.testing.expect(big_result.manifest.?.system_prompt == null);
    try std.testing.expectEqual(Severity.warn, big_result.diagnostics[0].severity);
}

test "manifest ignores unsupported runtime fields with an info diagnostic" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"runtime\",\"tools\":[],\"bootstrap\":\"x\"}");
    const root = try tmpRoot(&tmp, arena);

    const result = try parse(arena, root);
    try std.testing.expect(result.manifest != null);
    var infos: usize = 0;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.severity == .info) infos += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), infos);
}

test "manifest reads the session start skill and author forms" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"start\",\"author\":\"Ada\",\"sessionStart\":{\"skill\":\" intro \"}}");
    const root = try tmpRoot(&tmp, arena);

    const manifest = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqualStrings("intro", manifest.session_start_skill.?);
    try std.testing.expectEqualStrings("Ada", manifest.author.?.name.?);
    try std.testing.expect(manifest.author.?.email == null);
}

test "manifest reads hooks with the plugin root as their working directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":[{\"event\":\"PreToolUse\",\"command\":\"./check.sh\"}]}");
    const root = try tmpRoot(&tmp, arena);

    const loaded = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 1), loaded.hooks.len);
    try std.testing.expectEqualStrings("./check.sh", loaded.hooks[0].command);
    try std.testing.expectEqualStrings(root, loaded.hooks[0].cwd.?);
}

test "manifest reports a non-array hooks field and loads no hooks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":{\"event\":\"PreToolUse\"}}");
    const root = try tmpRoot(&tmp, arena);

    const parsed = try parse(arena, root);
    try std.testing.expectEqual(@as(usize, 0), parsed.manifest.?.hooks.len);
    try std.testing.expectEqual(Severity.warn, parsed.diagnostics[0].severity);
}

test "manifest collects markdown commands from directories and files, sorted by name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"cmds\",\"commands\":[\"./commands\",\"./extra/one.md\"]}");
    try writeFixture(&tmp, "commands/review.md", "review");
    try writeFixture(&tmp, "commands/nested/deep.md", "deep");
    try writeFixture(&tmp, "commands/notes.txt", "not a command");
    try writeFixture(&tmp, "extra/one.md", "one");
    const root = try tmpRoot(&tmp, arena);

    const loaded = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 3), loaded.commands.len);
    try std.testing.expectEqualStrings("nested/deep", loaded.commands[0].name);
    try std.testing.expectEqualStrings("one", loaded.commands[1].name);
    try std.testing.expectEqualStrings("review", loaded.commands[2].name);
    try std.testing.expect(std.mem.endsWith(u8, loaded.commands[1].path, "extra/one.md"));
}

test "manifest rejects command paths that escape the plugin" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "plugin/kimi.plugin.json", "{\"name\":\"cmds\",\"commands\":\"./../outside\"}");
    try writeFixture(&tmp, "outside/secret.md", "secret");
    const root = try std.Io.Dir.path.join(arena, &.{ try tmpRoot(&tmp, arena), "plugin" });

    const parsed = try parse(arena, root);
    try std.testing.expectEqual(@as(usize, 0), parsed.manifest.?.commands.len);
    try std.testing.expectEqual(Severity.err, parsed.diagnostics[0].severity);
}

test "manifest keeps an object interface and ignores other shapes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"ui\",\"interface\":{\"displayName\":\"Acme\"}}");
    const root = try tmpRoot(&tmp, arena);

    const loaded = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqualStrings("Acme", loaded.interface.?.object.get("displayName").?.string);

    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"ui\",\"interface\":\"Acme\"}");
    const other = (try parse(arena, root)).manifest.?;
    try std.testing.expect(other.interface == null);
}

test "claude manifest is read from .claude-plugin when no kimi manifest exists and kimi manifests win" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"claude-one\",\"lspServers\":{},\"outputStyles\":\"./styles\",\"dependencies\":[]}");
    const root = try tmpRoot(&tmp, arena);

    const only_claude = try parse(arena, root);
    try std.testing.expectEqual(ManifestKind.claude, only_claude.kind.?);
    try std.testing.expect(std.mem.endsWith(u8, only_claude.manifest_path.?, claude_manifest_path));
    try std.testing.expectEqualStrings("claude-one", only_claude.manifest.?.name);
    try std.testing.expectEqual(@as(usize, 0), only_claude.diagnostics.len);

    try writeFixture(&tmp, ".kimi-plugin/plugin.json", "{\"name\":\"dir-one\"}");
    const with_kimi = try parse(arena, root);
    try std.testing.expectEqual(ManifestKind.dir, with_kimi.kind.?);
    try std.testing.expectEqualStrings("dir-one", with_kimi.manifest.?.name);
}

test "claude manifest scans skills/ by default and the skills key adds to it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"skilled\",\"skills\":[\"./extra\",\"./skills\"]}");
    try writeFixture(&tmp, "skills/review/SKILL.md", "x");
    try writeFixture(&tmp, "extra/audit/SKILL.md", "x");
    const root = try tmpRoot(&tmp, arena);

    const listed = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 2), listed.skills.len);
    try std.testing.expect(std.mem.endsWith(u8, listed.skills[0], "/extra"));
    try std.testing.expect(std.mem.endsWith(u8, listed.skills[1], "/skills"));

    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"skilled\",\"skills\":\"./extra\"}");
    const added = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 2), added.skills.len);
    try std.testing.expect(std.mem.endsWith(u8, added.skills[0], "/skills"));
    try std.testing.expect(std.mem.endsWith(u8, added.skills[1], "/extra"));

    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"skilled\"}");
    const defaulted = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 1), defaulted.skills.len);
    try std.testing.expect(std.mem.endsWith(u8, defaulted.skills[0], "/skills"));
    try std.testing.expect(!defaulted.root_skill_fallback);
}

test "kimi manifest does not scan skills/ or commands/ by default" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "kimi.plugin.json", "{\"name\":\"plain\"}");
    try writeFixture(&tmp, "skills/review/SKILL.md", "x");
    try writeFixture(&tmp, "commands/go.md", "go");
    try writeFixture(&tmp, "hooks/hooks.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./done.sh\"}]}]}}");
    const root = try tmpRoot(&tmp, arena);

    const loaded = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.commands.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.hooks.len);
}

test "claude manifest merges hooks/hooks.json with manifest hooks given as a path, an inline object or an array" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "hooks/hooks.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./done.sh\"}]}]}}");
    try writeFixture(&tmp, "config/extra.json", "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"${CLAUDE_PLUGIN_ROOT}/start.sh\"}]}]}}");
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"hooky\",\"hooks\":\"./config/extra.json\"}");
    const root = try tmpRoot(&tmp, arena);

    const from_path = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 2), from_path.hooks.len);
    try std.testing.expectEqual(external.Event.SessionStart, from_path.hooks[0].event);
    try std.testing.expect(std.mem.startsWith(u8, from_path.hooks[0].command, root));
    try std.testing.expect(std.mem.endsWith(u8, from_path.hooks[0].command, "/start.sh"));
    try std.testing.expectEqual(external.Event.Stop, from_path.hooks[1].event);
    try std.testing.expectEqualStrings(root, from_path.hooks[1].cwd.?);

    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"hooky\",\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"./check.sh\"}]}]}}");
    const from_object = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 2), from_object.hooks.len);
    try std.testing.expectEqualStrings("Bash", from_object.hooks[0].matcher.?);

    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"hooky\",\"hooks\":[\"./config/extra.json\",\"./hooks/hooks.json\",{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./check.sh\"}]}]}]}");
    const from_array = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 3), from_array.hooks.len);
    try std.testing.expectEqual(external.Event.Stop, from_array.hooks[1].event);
    try std.testing.expectEqual(external.Event.PreToolUse, from_array.hooks[2].event);
}

test "claude manifest scans commands/ by default and joins subdirectories with colons" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"cmds\"}");
    try writeFixture(&tmp, "commands/review.md", "review");
    try writeFixture(&tmp, "commands/git/sync.md", "sync");
    const root = try tmpRoot(&tmp, arena);

    const loaded = (try parse(arena, root)).manifest.?;
    try std.testing.expectEqual(@as(usize, 2), loaded.commands.len);
    try std.testing.expectEqualStrings("git:sync", loaded.commands[0].name);
    try std.testing.expectEqualStrings("review", loaded.commands[1].name);
}

test "manifest reads a commands object map with source, inline content and metadata" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"cmds\",\"commands\":{\"about\":{\"content\":\"Say hello.\",\"description\":\"Greets\",\"argumentHint\":\"[name]\",\"model\":\"sonnet\",\"allowedTools\":[\"Read\",\"Bash(git add *)\"]},\"ship\":{\"source\":\"./docs/ship.md\"},\"plain\":\"./docs/ship.md\",\"broken\":{},\"escape\":{\"source\":\"../x.md\"}}}");
    try writeFixture(&tmp, "docs/ship.md", "ship it");
    const root = try tmpRoot(&tmp, arena);

    const parsed = try parse(arena, root);
    const loaded = parsed.manifest.?;
    try std.testing.expectEqual(@as(usize, 3), loaded.commands.len);
    try std.testing.expectEqualStrings("about", loaded.commands[0].name);
    try std.testing.expectEqualStrings("Say hello.", loaded.commands[0].content.?);
    try std.testing.expectEqualStrings("Greets", loaded.commands[0].description.?);
    try std.testing.expectEqualStrings("[name]", loaded.commands[0].argument_hint.?);
    try std.testing.expectEqualStrings("sonnet", loaded.commands[0].model.?);
    try std.testing.expectEqual(@as(usize, 2), loaded.commands[0].allowed_tools.len);
    try std.testing.expectEqualStrings("plain", loaded.commands[1].name);
    try std.testing.expectEqualStrings("ship", loaded.commands[2].name);
    try std.testing.expect(loaded.commands[2].content == null);
    try std.testing.expect(std.mem.endsWith(u8, loaded.commands[2].path, "docs/ship.md"));
    try std.testing.expectEqual(@as(usize, 2), parsed.diagnostics.len);
}

test "manifest reads userConfig options with their defaults and sensitivity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"configured\",\"userConfig\":{\"api_endpoint\":{\"description\":\"Endpoint\",\"default\":\"https://api.example\"},\"retries\":{\"default\":3},\"api_token\":{\"sensitive\":true},\"bad key\":{},\"shape\":7}}");
    const root = try tmpRoot(&tmp, arena);

    const parsed = try parse(arena, root);
    const options = parsed.manifest.?.user_config;
    try std.testing.expectEqual(@as(usize, 3), options.len);
    try std.testing.expectEqualStrings("api_endpoint", options[0].key);
    try std.testing.expectEqualStrings("Endpoint", options[0].description.?);
    try std.testing.expectEqualStrings("https://api.example", userConfigValue(options, "api_endpoint").?);
    try std.testing.expectEqualStrings("3", userConfigValue(options, "retries").?);
    try std.testing.expect(options[2].sensitive);
    try std.testing.expect(userConfigValue(options, "api_token") == null);
    try std.testing.expect(userConfigValue(options, "missing") == null);
    try std.testing.expectEqual(@as(usize, 2), parsed.diagnostics.len);
}

test "manifest reads defaultEnabled and keeps plugins enabled by default" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"quiet\",\"defaultEnabled\":false}");
    const root = try tmpRoot(&tmp, arena);
    try std.testing.expect(!(try parse(arena, root)).manifest.?.default_enabled);

    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"quiet\",\"defaultEnabled\":\"no\"}");
    const mistyped = try parse(arena, root);
    try std.testing.expect(mistyped.manifest.?.default_enabled);
    try std.testing.expectEqual(Severity.warn, mistyped.diagnostics[0].severity);
}

test {
    _ = @import("claude_hooks.zig");
    _ = @import("bin_path.zig");
    _ = @import("claude_marketplace.zig");
    _ = @import("validate.zig");
    _ = @import("manager.zig");
    _ = @import("mcp_servers.zig");
    _ = @import("source.zig");
    _ = @import("commands.zig");
    _ = @import("contributions.zig");
}
