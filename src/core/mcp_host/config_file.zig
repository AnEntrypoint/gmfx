const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const json = std.json;

pub const File = enum { profile, project };

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Entry = union(enum) {
    stdio: struct { command: []const u8, args: []const []const u8 = &.{}, env: []const Pair = &.{} },
    http: struct { url: []const u8, headers: []const Pair = &.{}, sse: bool = false },
};

pub const Error = Allocator.Error || error{
    Unreadable,
    NotAnObject,
    BothKeys,
    Exists,
};

pub fn add(alloc: Allocator, file: File, text: ?[]const u8, name: []const u8, entry: Entry) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, true)).?;
    if (servers.contains(name)) return error.Exists;
    try servers.put(a, name, try entryValue(a, entry));
    return render(alloc, root);
}

pub const Removed = struct {
    text: []u8,
    url: ?[]u8,

    pub fn deinit(r: *Removed, alloc: Allocator) void {
        alloc.free(r.text);
        if (r.url) |url| alloc.free(url);
        r.* = undefined;
    }
};

pub fn remove(alloc: Allocator, file: File, text: []const u8, name: []const u8) Error!?Removed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, false)) orelse return null;
    const old = servers.get(name) orelse return null;
    const url: ?[]u8 = if (old == .object) if (old.object.get("url")) |u| switch (u) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    } else null else null;
    errdefer if (url) |u| alloc.free(u);
    _ = servers.orderedRemove(name);
    return .{ .text = try render(alloc, root), .url = url };
}

pub fn has(alloc: Allocator, file: File, text: []const u8, name: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var root = parse(arena.allocator(), text) catch return false;
    const servers = (serversOf(arena.allocator(), file, &root, false) catch return false) orelse return false;
    return servers.contains(name);
}

const local_projects_key = "projects";

fn localServersOf(a: Allocator, root: *json.Value, project_root: []const u8, create: bool) Error!?*json.ObjectMap {
    if (root.* != .object) return error.NotAnObject;
    var holder: *json.Value = root;
    for ([_][]const u8{ local_projects_key, project_root, "mcpServers" }) |key| {
        if (holder.object.getPtr(key) == null) {
            if (!create) return null;
            try holder.object.put(a, key, .{ .object = .empty });
        }
        holder = holder.object.getPtr(key).?;
        if (holder.* != .object) return error.NotAnObject;
    }
    return &holder.object;
}

pub fn addLocal(alloc: Allocator, text: ?[]const u8, project_root: []const u8, name: []const u8, entry: Entry) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try localServersOf(a, &root, project_root, true)).?;
    if (servers.contains(name)) return error.Exists;
    try servers.put(a, name, try entryValue(a, entry));
    return render(alloc, root);
}

pub fn removeLocal(alloc: Allocator, text: []const u8, project_root: []const u8, name: []const u8) Error!?Removed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try localServersOf(a, &root, project_root, false)) orelse return null;
    const old = servers.get(name) orelse return null;
    const url: ?[]u8 = if (old == .object) if (old.object.get("url")) |u| switch (u) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    } else null else null;
    errdefer if (url) |u| alloc.free(u);
    _ = servers.orderedRemove(name);
    return .{ .text = try render(alloc, root), .url = url };
}

pub fn hasLocal(alloc: Allocator, text: []const u8, project_root: []const u8, name: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var root = parse(arena.allocator(), text) catch return false;
    const servers = (localServersOf(arena.allocator(), &root, project_root, false) catch return false) orelse return false;
    return servers.contains(name);
}

pub fn updateLocal(alloc: Allocator, profile_path: []const u8, project_root: []const u8, change: Change) !Updated {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = try read(alloc, profile_path);
    defer if (text) |t| alloc.free(t);
    switch (change) {
        .add => |a| {
            const next = try addLocal(alloc, text, project_root, a.name, a.entry);
            defer alloc.free(next);
            try write(alloc, .profile, profile_path, next);
            return .added;
        },
        .remove => |name| {
            const removed = (try removeLocal(alloc, text orelse return .missing, project_root, name)) orelse return .missing;
            defer alloc.free(removed.text);
            errdefer if (removed.url) |u| alloc.free(u);
            try write(alloc, .profile, profile_path, removed.text);
            return .{ .removed = removed.url };
        },
    }
}

pub const Change = union(enum) {
    add: struct { name: []const u8, entry: Entry },
    remove: []const u8,
};

pub const Updated = union(enum) {
    added,
    removed: ?[]u8,
    missing,
};

pub fn update(alloc: Allocator, profile_path: []const u8, file: File, path: []const u8, change: Change) !Updated {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = try read(alloc, path);
    defer if (text) |t| alloc.free(t);
    switch (change) {
        .add => |a| {
            const next = try add(alloc, file, text, a.name, a.entry);
            defer alloc.free(next);
            try write(alloc, file, path, next);
            return .added;
        },
        .remove => |name| {
            const removed = (try remove(alloc, file, text orelse return .missing, name)) orelse return .missing;
            defer alloc.free(removed.text);
            errdefer if (removed.url) |u| alloc.free(u);
            try write(alloc, file, path, removed.text);
            return .{ .removed = removed.url };
        },
    }
}

pub const max_read_bytes: usize = 1024 * 1024;

pub fn read(alloc: Allocator, path: []const u8) !?[]u8 {
    var f = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &f, max_read_bytes);
}

const profile_lock_deadline_ms: u64 = 2_000;

pub fn lockProfile(profile_path: []const u8) !io_mod.TimedAdvisoryLock {
    var dir = try profileDir(profile_path);
    defer dir.close();
    return io_mod.acquireTimedAdvisoryLock(&dir, "mcp.lock", profile_lock_deadline_ms);
}

pub fn replaceProfile(alloc: Allocator, profile_path: []const u8, text: []const u8) !void {
    var dir = try profileDir(profile_path);
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, std.Io.Dir.path.basename(profile_path), text);
}

fn profileDir(profile_path: []const u8) !io_mod.VerifiedDir {
    const parent = std.Io.Dir.path.dirname(profile_path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.Io.Dir.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.Io.Dir.path.basename(parent));
}

fn write(alloc: Allocator, file: File, path: []const u8, text: []const u8) !void {
    switch (file) {
        .profile => try replaceProfile(alloc, path, text),
        .project => {
            if (std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .sym_link or stat.nlink > 1) return error.Linked;
            } else |err| if (err != error.FileNotFound) return err;
            try io_mod.writeFileAtomic(alloc, path, text);
        },
    }
}

fn parse(a: Allocator, text: ?[]const u8) Error!json.Value {
    const t = text orelse return .{ .object = .empty };
    if (std.mem.trim(u8, t, " \t\r\n").len == 0) return .{ .object = .empty };
    return json.parseFromSliceLeaky(json.Value, a, t, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

fn serversOf(a: Allocator, file: File, root: *json.Value, create: bool) Error!?*json.ObjectMap {
    if (root.* != .object) return error.NotAnObject;
    const top = &root.object;
    const current = top.getPtr("mcpServers");
    const old = if (file == .profile) top.getPtr("mcp") else null;
    if (current != null and old != null) return error.BothKeys;
    const value = current orelse old orelse {
        if (!create) return null;
        try top.put(a, "mcpServers", .{ .object = .empty });
        return &top.getPtr("mcpServers").?.object;
    };
    if (value.* != .object) return error.NotAnObject;
    return &value.object;
}

fn entryValue(a: Allocator, entry: Entry) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    switch (entry) {
        .stdio => |s| {
            try object.put(a, "command", .{ .string = s.command });
            if (s.args.len > 0) {
                var args: json.Array = .init(a);
                for (s.args) |arg| try args.append(.{ .string = arg });
                try object.put(a, "args", .{ .array = args });
            }
            if (s.env.len > 0) try object.put(a, "env", try pairs(a, s.env));
        },
        .http => |h| {
            try object.put(a, "type", .{ .string = if (h.sse) "sse" else "http" });
            try object.put(a, "url", .{ .string = h.url });
            if (h.headers.len > 0) try object.put(a, "headers", try pairs(a, h.headers));
        },
    }
    return .{ .object = object };
}

fn pairs(a: Allocator, list: []const Pair) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    for (list) |p| try object.put(a, p.key, .{ .string = p.value });
    return .{ .object = object };
}

fn render(alloc: Allocator, root: json.Value) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

test "add keeps every key it doesn't know, in order, with numbers as written" {
    const before =
        \\{"theme":"dark","mcpServers":{"a":{"command":"x","environment":{"K":"v"},"startupTimeoutMs":1.50,"extra":[1,2]}},"zz":true}
    ;
    const after = try add(testing.allocator, .profile, before, "web", .{ .http = .{ .url = "https://mcp.example/mcp", .headers = &.{.{ .key = "X-Key", .value = "${KEY}" }} } });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(
        \\{
        \\  "theme": "dark",
        \\  "mcpServers": {
        \\    "a": {
        \\      "command": "x",
        \\      "environment": {
        \\        "K": "v"
        \\      },
        \\      "startupTimeoutMs": 1.50,
        \\      "extra": [
        \\        1,
        \\        2
        \\      ]
        \\    },
        \\    "web": {
        \\      "type": "http",
        \\      "url": "https://mcp.example/mcp",
        \\      "headers": {
        \\        "X-Key": "${KEY}"
        \\      }
        \\    }
        \\  },
        \\  "zz": true
        \\}
        \\
    , after);
}

test "add writes a stdio server, into a new file under mcpServers" {
    const after = try add(testing.allocator, .project, null, "local", .{ .stdio = .{ .command = "node", .args = &.{ "server.js", "--x" }, .env = &.{.{ .key = "A", .value = "1" }} } });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "local": {
        \\      "command": "node",
        \\      "args": [
        \\        "server.js",
        \\        "--x"
        \\      ],
        \\      "env": {
        \\        "A": "1"
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , after);
}

test "an older profile keeps its mcp key; a project file never uses it" {
    const old_profile = "{\"mcp\":{\"a\":{\"command\":\"x\"}}}";
    const profile = try add(testing.allocator, .profile, old_profile, "b", .{ .stdio = .{ .command = "y" } });
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.find(u8, profile, "\"mcpServers\"") == null);
    try testing.expect(has(testing.allocator, .profile, profile, "b"));

    const project = try add(testing.allocator, .project, old_profile, "b", .{ .stdio = .{ .command = "y" } });
    defer testing.allocator.free(project);
    try testing.expect(has(testing.allocator, .project, project, "b"));
    try testing.expect(!has(testing.allocator, .project, project, "a"));
    try testing.expect(std.mem.find(u8, project, "\"mcp\": {") != null);
}

test "add refuses what it can't edit safely" {
    const a = testing.allocator;
    const entry: Entry = .{ .stdio = .{ .command = "y" } };
    try testing.expectError(error.Exists, add(a, .profile, "{\"mcpServers\":{\"b\":{}}}", "b", entry));
    try testing.expectError(error.BothKeys, add(a, .profile, "{\"mcp\":{},\"mcpServers\":{}}", "b", entry));
    try testing.expectError(error.Unreadable, add(a, .profile, "{\"mcpServers\":{},\"mcpServers\":{}}", "b", entry));
    try testing.expectError(error.Unreadable, add(a, .profile, "{nope", "b", entry));
    try testing.expectError(error.NotAnObject, add(a, .profile, "[]", "b", entry));
    try testing.expectError(error.NotAnObject, add(a, .profile, "{\"mcpServers\":[]}", "b", entry));
    const blank = try add(a, .profile, " \n", "b", entry);
    defer a.free(blank);
    try testing.expect(has(a, .profile, blank, "b"));
}

test "remove drops one entry, keeps the rest in order, and returns its url" {
    const a = testing.allocator;
    const before = "{\"x\":1,\"mcpServers\":{\"a\":{\"command\":\"x\"},\"web\":{\"type\":\"http\",\"url\":\"https://w/mcp\"},\"c\":{\"command\":\"z\"}}}";
    var removed = (try remove(a, .profile, before, "web")).?;
    defer removed.deinit(a);
    try testing.expectEqualStrings("https://w/mcp", removed.url.?);
    try testing.expect(!has(a, .profile, removed.text, "web"));
    const order_a = std.mem.find(u8, removed.text, "\"a\"").?;
    const order_c = std.mem.find(u8, removed.text, "\"c\"").?;
    try testing.expect(order_a < order_c);
    try testing.expect(std.mem.find(u8, removed.text, "\"x\": 1") != null);

    var stdio = (try remove(a, .profile, before, "a")).?;
    defer stdio.deinit(a);
    try testing.expect(stdio.url == null);
    try testing.expect(try remove(a, .profile, before, "missing") == null);
    try testing.expect(try remove(a, .project, "{\"mcp\":{\"a\":{}}}", "a") == null);
}

test "a linked config file is never edited, whether a symlink or a hard link" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.json", .data = "{}" });
    try tmp.dir.symLink(io, "shared.json", "soft.json", .{});
    try tmp.dir.hardLink("shared.json", tmp.dir, "hard.json", io, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.json", .data = "{}" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const Case = struct { name: []const u8, want: enum { linked, written, no_dir } };
    for ([_]Case{
        .{ .name = "soft.json", .want = .linked },
        .{ .name = "hard.json", .want = .linked },
        .{ .name = "plain.json", .want = .written },
        .{ .name = "missing.json", .want = .written },
        .{ .name = "no-dir/mcp.json", .want = .no_dir },
    }) |case| {
        const path = try std.Io.Dir.path.join(alloc, &.{ root, case.name });
        defer alloc.free(path);
        const text = "{\"mcpServers\":{}}";
        switch (case.want) {
            .linked => try testing.expectError(error.Linked, write(alloc, .project, path, text)),
            .written => {
                try write(alloc, .project, path, text);
                const got = try tmp.dir.readFileAlloc(io, case.name, alloc, .limited(64));
                defer alloc.free(got);
                try testing.expectEqualStrings(text, got);
            },
            .no_dir => try testing.expectError(error.FileNotFound, write(alloc, .project, path, text)),
        }
    }

    const shared = try tmp.dir.readFileAlloc(io, "shared.json", alloc, .limited(64));
    defer alloc.free(shared);
    try testing.expectEqualStrings("{}", shared);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "read returns a file's text, follows a symlink, and refuses a fifo without blocking" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.json", .data = "{\"mcp\":{}}" });
    try tmp.dir.symLink(io, "plain.json", "soft.json", .{});
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    for ([_][]const u8{ "plain.json", "soft.json" }) |name| {
        const path = try std.Io.Dir.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        const text = (try read(alloc, path)).?;
        defer alloc.free(text);
        try testing.expectEqualStrings("{\"mcp\":{}}", text);
    }

    const missing = try std.Io.Dir.path.join(alloc, &.{ root, "missing.json" });
    defer alloc.free(missing);
    try testing.expect(try read(alloc, missing) == null);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ root, "fifo.json" }, 0);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try testing.expectError(error.DurablePathUnsafe, read(alloc, fifo));
}

test "the profile's first write creates ~/.fx readable only by its owner" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", "mcp.json" });
    defer alloc.free(path);
    try write(alloc, .profile, path, "{\"mcpServers\":{}}");
    const dir = try tmp.dir.statFile(io, ".fx", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir.permissions.toMode() & 0o777);
    const file = try tmp.dir.statFile(io, ".fx/mcp.json", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), file.permissions.toMode() & 0o777);
}

test "add writes an SSE server with type sse, and an HTTP one with type http" {
    const sse = try add(testing.allocator, .project, null, "old", .{ .http = .{ .url = "https://o.example/sse", .sse = true } });
    defer testing.allocator.free(sse);
    try testing.expect(std.mem.find(u8, sse, "\"type\": \"sse\"") != null);
    const http = try add(testing.allocator, .project, null, "web", .{ .http = .{ .url = "https://w.example/mcp" } });
    defer testing.allocator.free(http);
    try testing.expect(std.mem.find(u8, http, "\"type\": \"http\"") != null);
}

test "a local server is written under projects[root].mcpServers, beside the servers for every project, and removed from there" {
    const before =
        \\{
        \\  "mcpServers": {
        \\    "everywhere": {
        \\      "command": "node"
        \\    }
        \\  }
        \\}
    ;
    const added = try addLocal(testing.allocator, before, "/work/app", "mine", .{ .http = .{ .url = "https://m.example/mcp" } });
    defer testing.allocator.free(added);
    try testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "everywhere": {
        \\      "command": "node"
        \\    }
        \\  },
        \\  "projects": {
        \\    "/work/app": {
        \\      "mcpServers": {
        \\        "mine": {
        \\          "type": "http",
        \\          "url": "https://m.example/mcp"
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , added);
    try testing.expect(hasLocal(testing.allocator, added, "/work/app", "mine"));
    try testing.expect(!hasLocal(testing.allocator, added, "/work/other", "mine"));
    try testing.expect(!hasLocal(testing.allocator, added, "/work/app", "everywhere"));
    try testing.expect(!has(testing.allocator, .profile, added, "mine"));
    try testing.expectError(error.Exists, addLocal(testing.allocator, added, "/work/app", "mine", .{ .stdio = .{ .command = "x" } }));

    var removed = (try removeLocal(testing.allocator, added, "/work/app", "mine")).?;
    defer removed.deinit(testing.allocator);
    try testing.expectEqualStrings("https://m.example/mcp", removed.url.?);
    try testing.expect(!hasLocal(testing.allocator, removed.text, "/work/app", "mine"));
    try testing.expect(has(testing.allocator, .profile, removed.text, "everywhere"));
    try testing.expect((try removeLocal(testing.allocator, added, "/work/other", "mine")) == null);
}
