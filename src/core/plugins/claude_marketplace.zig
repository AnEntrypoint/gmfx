const std = @import("std");
const io_mod = @import("../shared/io.zig");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const file_path = ".claude-plugin/marketplace.json";
pub const default_command_timeout_seconds: u32 = 60;
const max_marketplace_bytes: usize = 4 * 1024 * 1024;
const github_host = "https://github.com/";
const sha_hex_len = 40;
const sha256_hex_len = 64;

const component_keys = [_][]const u8{ "skills", "commands", "agents", "hooks", "mcpServers", "lspServers", "outputStyles" };

pub const Owner = struct {
    name: []const u8,
    email: ?[]const u8 = null,
};

pub const Github = struct {
    repo: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

pub const Git = struct {
    url: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

pub const GitSubdir = struct {
    url: []const u8,
    path: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

pub const Npm = struct {
    package: []const u8,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
};

pub const Archive = struct {
    url: []const u8,
    sha256: ?[]const u8 = null,
};

pub const CommandMode = enum { copy, link };

pub const Command = struct {
    command: []const u8,
    timeout_seconds: u32 = default_command_timeout_seconds,
    mode: CommandMode = .copy,
};

pub const Source = union(enum) {
    relative_path: []const u8,
    github: Github,
    url: Git,
    git_subdir: GitSubdir,
    npm: Npm,
    archive: Archive,
    command: Command,
};

pub const Entry = struct {
    name: []const u8,
    source: Source,
    strict: bool = true,
    default_enabled: bool = true,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    declares_components: bool = false,
};

pub const Marketplace = struct {
    name: []const u8,
    owner: Owner,
    plugins: []const Entry = &.{},
    plugin_root: ?[]const u8 = null,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const Result = struct {
    marketplace: ?Marketplace = null,
    diagnostics: []const manifest.Diagnostic = &.{},

    pub fn hasErrors(self: Result) bool {
        for (self.diagnostics) |diagnostic| {
            if (diagnostic.severity == .err) return true;
        }
        return false;
    }
};

const Context = struct {
    arena: Allocator,
    diagnostics: std.ArrayList(manifest.Diagnostic) = .empty,

    fn add(self: *Context, severity: manifest.Severity, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.diagnostics.append(self.arena, .{ .severity = severity, .message = message });
    }

    fn finish(self: *Context, marketplace: ?Marketplace) Result {
        return .{ .marketplace = marketplace, .diagnostics = self.diagnostics.items };
    }

    fn parseEntry(self: *Context, index: usize, value: Value) Allocator.Error!?Entry {
        if (value != .object) {
            try self.add(.err, "plugins[{d}] must be an object", .{index});
            return null;
        }
        const object = value.object;
        const name = trimmed(object, "name") orelse {
            try self.add(.err, "plugins[{d}] needs a \"name\"", .{index});
            return null;
        };
        if (!manifest.isValidName(name)) {
            try self.add(.err, "plugins[{d}] has an invalid name \"{s}\"", .{ index, name });
            return null;
        }
        const raw_source = object.get("source") orelse {
            try self.add(.err, "plugin \"{s}\" needs a \"source\"", .{name});
            return null;
        };
        const parsed_source = (try self.parseSource(name, raw_source)) orelse return null;
        return .{
            .name = name,
            .source = parsed_source,
            .strict = boolField(object, "strict") orelse true,
            .default_enabled = boolField(object, "defaultEnabled") orelse true,
            .description = trimmed(object, "description"),
            .version = trimmed(object, "version"),
            .declares_components = declaresComponents(object),
        };
    }

    fn parseSource(self: *Context, name: []const u8, value: Value) Allocator.Error!?Source {
        switch (value) {
            .string => |path| {
                if (!isRelativeSource(path)) {
                    try self.add(.err, "plugin \"{s}\" has a relative source that must start with \"./\" and stay inside the marketplace (got \"{s}\")", .{ name, path });
                    return null;
                }
                return .{ .relative_path = path };
            },
            .object => |object| return self.typedSource(name, object),
            else => {
                try self.add(.err, "plugin \"{s}\" has a source that is neither a path nor an object", .{name});
                return null;
            },
        }
    }

    fn typedSource(self: *Context, name: []const u8, object: ObjectMap) Allocator.Error!?Source {
        const kind = trimmed(object, "source") orelse {
            try self.add(.err, "plugin \"{s}\" has a source object without a \"source\" type", .{name});
            return null;
        };
        if (std.mem.eql(u8, kind, "github")) {
            const repo = (try self.required(name, kind, object, "repo")) orelse return null;
            if (!isOwnerRepo(repo)) {
                try self.add(.err, "plugin \"{s}\" has a github repo that is not owner/repo (got \"{s}\")", .{ name, repo });
                return null;
            }
            if (!try self.validCommitSha(name, object)) return null;
            return .{ .github = .{ .repo = repo, .ref = trimmed(object, "ref"), .sha = trimmed(object, "sha") } };
        }
        if (std.mem.eql(u8, kind, "url")) {
            const url = (try self.required(name, kind, object, "url")) orelse return null;
            if (!try self.validCommitSha(name, object)) return null;
            return .{ .url = .{ .url = url, .ref = trimmed(object, "ref"), .sha = trimmed(object, "sha") } };
        }
        if (std.mem.eql(u8, kind, "git-subdir")) {
            const url = (try self.required(name, kind, object, "url")) orelse return null;
            const path = (try self.required(name, kind, object, "path")) orelse return null;
            if (!try self.validCommitSha(name, object)) return null;
            return .{ .git_subdir = .{ .url = url, .path = path, .ref = trimmed(object, "ref"), .sha = trimmed(object, "sha") } };
        }
        if (std.mem.eql(u8, kind, "npm")) {
            const package = (try self.required(name, kind, object, "package")) orelse return null;
            return .{ .npm = .{ .package = package, .version = trimmed(object, "version"), .registry = trimmed(object, "registry") } };
        }
        if (std.mem.eql(u8, kind, "archive")) {
            const url = (try self.required(name, kind, object, "url")) orelse return null;
            const sha256 = trimmed(object, "sha256");
            if (sha256) |digest| {
                if (!isHex(digest, sha256_hex_len)) {
                    try self.add(.err, "plugin \"{s}\" has an archive sha256 that is not 64 hex digits", .{name});
                    return null;
                }
            }
            return .{ .archive = .{ .url = url, .sha256 = sha256 } };
        }
        if (std.mem.eql(u8, kind, "command")) {
            const command = (try self.required(name, kind, object, "command")) orelse return null;
            var parsed: Command = .{ .command = command };
            if (object.get("timeout")) |timeout| {
                if (timeout != .integer or timeout.integer < 1 or timeout.integer > std.math.maxInt(u32)) {
                    try self.add(.err, "plugin \"{s}\" has a command timeout that is not a positive whole number of seconds", .{name});
                    return null;
                }
                parsed.timeout_seconds = @intCast(timeout.integer);
            }
            if (trimmed(object, "mode")) |mode| {
                parsed.mode = std.meta.stringToEnum(CommandMode, mode) orelse {
                    try self.add(.err, "plugin \"{s}\" has a command mode that is neither copy nor link (got \"{s}\")", .{ name, mode });
                    return null;
                };
            }
            return .{ .command = parsed };
        }
        try self.add(.err, "plugin \"{s}\" has an unknown source type \"{s}\"", .{ name, kind });
        return null;
    }

    fn required(self: *Context, name: []const u8, kind: []const u8, object: ObjectMap, key: []const u8) Allocator.Error!?[]const u8 {
        return trimmed(object, key) orelse {
            try self.add(.err, "plugin \"{s}\" has a {s} source without \"{s}\"", .{ name, kind, key });
            return null;
        };
    }

    fn validCommitSha(self: *Context, name: []const u8, object: ObjectMap) Allocator.Error!bool {
        const sha = trimmed(object, "sha") orelse return true;
        if (isHex(sha, sha_hex_len)) return true;
        try self.add(.err, "plugin \"{s}\" has a sha that is not a full 40-character commit hash", .{name});
        return false;
    }
};

pub fn parseText(arena: Allocator, text: []const u8) Allocator.Error!Result {
    var ctx: Context = .{ .arena = arena };
    const raw = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| {
        try ctx.add(.err, "Failed to parse marketplace: {s}", .{@errorName(err)});
        return ctx.finish(null);
    };
    if (raw != .object) {
        try ctx.add(.err, "marketplace must be a JSON object", .{});
        return ctx.finish(null);
    }
    const object = raw.object;
    const name = trimmed(object, "name");
    if (name == null) try ctx.add(.err, "\"name\" is required", .{});
    const owner = ownerOf(object.get("owner"));
    if (owner == null) try ctx.add(.err, "\"owner\" is required and needs a name", .{});
    const listed = object.get("plugins");
    if (listed == null or listed.? != .array) try ctx.add(.err, "\"plugins\" is required and must be an array", .{});
    if (name == null or owner == null or listed == null or listed.? != .array) return ctx.finish(null);

    var plugins: std.ArrayList(Entry) = .empty;
    for (listed.?.array.items, 0..) |item, index| {
        const parsed = (try ctx.parseEntry(index, item)) orelse continue;
        if (hasEntry(plugins.items, parsed.name)) {
            try ctx.add(.err, "plugin \"{s}\" is listed more than once", .{parsed.name});
            continue;
        }
        try plugins.append(arena, parsed);
    }

    var plugin_root: ?[]const u8 = null;
    var description = trimmed(object, "description");
    var version = trimmed(object, "version");
    if (object.get("metadata")) |metadata| {
        if (metadata == .object) {
            plugin_root = trimmed(metadata.object, "pluginRoot");
            if (description == null) description = trimmed(metadata.object, "description");
            if (version == null) version = trimmed(metadata.object, "version");
        } else {
            try ctx.add(.warn, "\"metadata\" must be an object", .{});
        }
    }
    if (plugin_root) |root| {
        if (!isRelativeSource(root)) {
            try ctx.add(.err, "\"metadata.pluginRoot\" must start with \"./\" and stay inside the marketplace (got \"{s}\")", .{root});
            plugin_root = null;
        }
    }
    return ctx.finish(.{
        .name = name.?,
        .owner = owner.?,
        .plugins = plugins.items,
        .plugin_root = plugin_root,
        .description = description,
        .version = version,
    });
}

pub fn exists(arena: Allocator, marketplace_dir: []const u8) Allocator.Error!bool {
    const path = try std.Io.Dir.path.join(arena, &.{ marketplace_dir, file_path });
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn parseDir(arena: Allocator, marketplace_dir: []const u8) Allocator.Error!Result {
    const path = try std.Io.Dir.path.join(arena, &.{ marketplace_dir, file_path });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_marketplace_bytes + 1)) catch |err| {
        var ctx: Context = .{ .arena = arena };
        try ctx.add(.err, "Failed to read {s}: {s}", .{ file_path, @errorName(err) });
        return ctx.finish(null);
    };
    return parseText(arena, bytes);
}

pub fn find(marketplace: Marketplace, name: []const u8) ?Entry {
    for (marketplace.plugins) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

pub fn strictConflict(entry: Entry, plugin_manifest_declares_components: bool) bool {
    return !entry.strict and entry.declares_components and plugin_manifest_declares_components;
}

pub fn installSource(arena: Allocator, marketplace_dir: []const u8, marketplace: Marketplace, entry: Entry) Allocator.Error!?[]const u8 {
    switch (entry.source) {
        .relative_path => |relative| {
            if (marketplace.plugin_root) |root| return try std.Io.Dir.path.resolveAlloc(arena, &.{ marketplace_dir, root, relative });
            return try std.Io.Dir.path.resolveAlloc(arena, &.{ marketplace_dir, relative });
        },
        .github => |github| {
            if (github.sha) |sha| return try std.fmt.allocPrint(arena, "{s}{s}/commit/{s}", .{ github_host, github.repo, sha });
            if (github.ref) |ref| return try std.fmt.allocPrint(arena, "{s}{s}/tree/{s}", .{ github_host, github.repo, ref });
            return try std.fmt.allocPrint(arena, "{s}{s}", .{ github_host, github.repo });
        },
        .archive => |archive| return archive.url,
        .url, .git_subdir, .npm, .command => return null,
    }
}

fn hasEntry(entries: []const Entry, name: []const u8) bool {
    for (entries) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return true;
    }
    return false;
}

fn declaresComponents(object: ObjectMap) bool {
    for (component_keys) |key| {
        if (object.get(key) != null) return true;
    }
    return false;
}

fn ownerOf(value: ?Value) ?Owner {
    const raw = value orelse return null;
    if (raw != .object) return null;
    const name = trimmed(raw.object, "name") orelse return null;
    return .{ .name = name, .email = trimmed(raw.object, "email") };
}

fn isRelativeSource(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "./")) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isOwnerRepo(repo: []const u8) bool {
    const slash = std.mem.findScalar(u8, repo, '/') orelse return false;
    if (slash == 0 or slash + 1 == repo.len) return false;
    return std.mem.findScalar(u8, repo[slash + 1 ..], '/') == null;
}

fn isHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn boolField(object: ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn trimmed(object: ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    const text = std.mem.trim(u8, value.string, " \t\r\n");
    return if (text.len == 0) null else text;
}

const testing = std.testing;

test "claude marketplace needs name, owner and plugins and reads the optional metadata" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = try parseText(arena,
        \\{"name":"acme-tools","owner":{"name":"Acme","email":"dev@acme.test"},
        \\"metadata":{"pluginRoot":"./plugins","description":"Acme plugins","version":"2.0.0"},
        \\"plugins":[{"name":"formatter","source":"./formatter","description":"Formats","version":"1.0.0"}]}
    );
    try testing.expect(!full.hasErrors());
    const marketplace = full.marketplace.?;
    try testing.expectEqualStrings("acme-tools", marketplace.name);
    try testing.expectEqualStrings("Acme", marketplace.owner.name);
    try testing.expectEqualStrings("dev@acme.test", marketplace.owner.email.?);
    try testing.expectEqualStrings("./plugins", marketplace.plugin_root.?);
    try testing.expectEqualStrings("Acme plugins", marketplace.description.?);
    try testing.expectEqualStrings("2.0.0", marketplace.version.?);
    try testing.expectEqual(@as(usize, 1), marketplace.plugins.len);
    try testing.expectEqualStrings("Formats", find(marketplace, "formatter").?.description.?);
    try testing.expect(find(marketplace, "absent") == null);

    const bare = try parseText(arena, "{\"description\":\"no required keys\"}");
    try testing.expect(bare.marketplace == null);
    try testing.expectEqual(@as(usize, 3), bare.diagnostics.len);

    const not_json = try parseText(arena, "{nope");
    try testing.expect(not_json.marketplace == null);
    try testing.expect(not_json.hasErrors());
}

test "claude marketplace entries need a name and a source, default to strict, and report a strict conflict" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"name":"m","owner":{"name":"o"},"plugins":[
        \\{"name":"plain","source":"./plain"},
        \\{"name":"loose","source":"./loose","strict":false,"defaultEnabled":false,"commands":["./commands"]},
        \\{"name":"plain","source":"./again"},
        \\{"source":"./nameless"},
        \\{"name":"sourceless"},
        \\7]}
    );
    const marketplace = parsed.marketplace.?;
    try testing.expectEqual(@as(usize, 2), marketplace.plugins.len);
    try testing.expectEqual(@as(usize, 4), parsed.diagnostics.len);
    const plain = find(marketplace, "plain").?;
    try testing.expect(plain.strict);
    try testing.expect(plain.default_enabled);
    try testing.expect(!plain.declares_components);
    try testing.expect(!strictConflict(plain, true));
    const loose = find(marketplace, "loose").?;
    try testing.expect(!loose.strict);
    try testing.expect(!loose.default_enabled);
    try testing.expect(loose.declares_components);
    try testing.expect(strictConflict(loose, true));
    try testing.expect(!strictConflict(loose, false));
}

test "claude marketplace reads every source type and refuses malformed ones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"name":"m","owner":{"name":"o"},"plugins":[
        \\{"name":"gh","source":{"source":"github","repo":"acme/tools","ref":"v2","sha":"0123456789abcdef0123456789abcdef01234567"}},
        \\{"name":"git","source":{"source":"url","url":"https://gitlab.test/acme/tools.git","ref":"main"}},
        \\{"name":"sub","source":{"source":"git-subdir","url":"https://gitlab.test/acme/mono.git","path":"plugins/sub"}},
        \\{"name":"pkg","source":{"source":"npm","package":"@acme/plugin","version":"^1.2.0","registry":"https://npm.acme.test"}},
        \\{"name":"zip","source":{"source":"archive","url":"https://dl.acme.test/p.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
        \\{"name":"cmd","source":{"source":"command","command":"make plugin"}},
        \\{"name":"cmd-link","source":{"source":"command","command":"make plugin","timeout":120,"mode":"link"}},
        \\{"name":"bare-path","source":"plugins/x"},
        \\{"name":"escape","source":"./../x"},
        \\{"name":"bad-repo","source":{"source":"github","repo":"acme"}},
        \\{"name":"short-sha","source":{"source":"github","repo":"acme/tools","sha":"abc123"}},
        \\{"name":"bad-digest","source":{"source":"archive","url":"https://dl.acme.test/p.zip","sha256":"abc"}},
        \\{"name":"bad-mode","source":{"source":"command","command":"x","mode":"move"}},
        \\{"name":"no-package","source":{"source":"npm"}},
        \\{"name":"mystery","source":{"source":"ftp","url":"ftp://x"}}]}
    );
    const marketplace = parsed.marketplace.?;
    try testing.expectEqual(@as(usize, 7), marketplace.plugins.len);
    try testing.expectEqual(@as(usize, 8), parsed.diagnostics.len);

    const github = find(marketplace, "gh").?.source.github;
    try testing.expectEqualStrings("acme/tools", github.repo);
    try testing.expectEqualStrings("v2", github.ref.?);
    try testing.expectEqual(@as(usize, 40), github.sha.?.len);
    try testing.expectEqualStrings("main", find(marketplace, "git").?.source.url.ref.?);
    try testing.expectEqualStrings("plugins/sub", find(marketplace, "sub").?.source.git_subdir.path);
    const npm = find(marketplace, "pkg").?.source.npm;
    try testing.expectEqualStrings("@acme/plugin", npm.package);
    try testing.expectEqualStrings("^1.2.0", npm.version.?);
    try testing.expectEqualStrings("https://npm.acme.test", npm.registry.?);
    try testing.expectEqual(@as(usize, 64), find(marketplace, "zip").?.source.archive.sha256.?.len);
    const default_command = find(marketplace, "cmd").?.source.command;
    try testing.expectEqual(default_command_timeout_seconds, default_command.timeout_seconds);
    try testing.expectEqual(CommandMode.copy, default_command.mode);
    const linked = find(marketplace, "cmd-link").?.source.command;
    try testing.expectEqual(@as(u32, 120), linked.timeout_seconds);
    try testing.expectEqual(CommandMode.link, linked.mode);
}

test "claude marketplace turns relative, github and archive sources into install sources" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseText(arena,
        \\{"name":"m","owner":{"name":"o"},"metadata":{"pluginRoot":"./plugins"},"plugins":[
        \\{"name":"local","source":"./formatter"},
        \\{"name":"pinned","source":{"source":"github","repo":"acme/tools","ref":"v2","sha":"0123456789abcdef0123456789abcdef01234567"}},
        \\{"name":"branch","source":{"source":"github","repo":"acme/tools","ref":"main"}},
        \\{"name":"head","source":{"source":"github","repo":"acme/tools"}},
        \\{"name":"zip","source":{"source":"archive","url":"https://dl.acme.test/p.zip"}},
        \\{"name":"pkg","source":{"source":"npm","package":"p"}}]}
    );
    const marketplace = parsed.marketplace.?;
    try testing.expectEqualStrings("/srv/market/plugins/formatter", (try installSource(arena, "/srv/market", marketplace, find(marketplace, "local").?)).?);
    try testing.expectEqualStrings("https://github.com/acme/tools/commit/0123456789abcdef0123456789abcdef01234567", (try installSource(arena, "/srv/market", marketplace, find(marketplace, "pinned").?)).?);
    try testing.expectEqualStrings("https://github.com/acme/tools/tree/main", (try installSource(arena, "/srv/market", marketplace, find(marketplace, "branch").?)).?);
    try testing.expectEqualStrings("https://github.com/acme/tools", (try installSource(arena, "/srv/market", marketplace, find(marketplace, "head").?)).?);
    try testing.expectEqualStrings("https://dl.acme.test/p.zip", (try installSource(arena, "/srv/market", marketplace, find(marketplace, "zip").?)).?);
    try testing.expect((try installSource(arena, "/srv/market", marketplace, find(marketplace, "pkg").?)) == null);
}

test "claude marketplace is read from .claude-plugin/marketplace.json in a directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try testing.expect(!try exists(arena, root));
    try testing.expect((try parseDir(arena, root)).marketplace == null);

    try tmp.dir.createDirPath(testing.io, ".claude-plugin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_path, .data = "{\"name\":\"m\",\"owner\":{\"name\":\"o\"},\"plugins\":[]}" });
    try testing.expect(try exists(arena, root));
    try testing.expectEqualStrings("m", (try parseDir(arena, root)).marketplace.?.name);
}
