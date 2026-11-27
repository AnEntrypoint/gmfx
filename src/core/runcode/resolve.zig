const std = @import("std");
const io_mod = @import("../shared/io.zig");
const cordis = @import("cordis.zig");
const host_module = @import("host_module.zig");

pub const Mode = enum { import, require };

pub const Failure = error{ ModuleNotFound, PackagePathNotExported, PackageInvalid } || host_module.Error;

const embedded_package = "@freddie/freddie-runtime";
const embedded_prefix = cordis.prefix;
const max_package_bytes: usize = 4 * 1024 * 1024;

const Root = union(enum) {
    disk: []const u8,
    embedded,
};

const Request = struct {
    package: []const u8,
    key: []const u8,
};

const Match = struct {
    prefix: []const u8,
    capture: []const u8,
    target: std.json.Value,
};

pub fn reply(alloc: std.mem.Allocator, request_text: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, request_text, '\n');
    const mode_text = lines.next() orelse "";
    const base = lines.next() orelse "";
    const specifier = lines.rest();
    const mode: Mode = if (std.mem.eql(u8, mode_text, "require")) .require else .import;
    return resolve(alloc, mode, base, specifier) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ModuleNotFound => std.fmt.allocPrint(alloc, "!Cannot find module '{s}' imported from {s}", .{ specifier, base }),
        error.PackagePathNotExported => std.fmt.allocPrint(alloc, "!Package subpath for '{s}' is not exported by its package", .{specifier}),
        error.PackageInvalid => std.fmt.allocPrint(alloc, "!Invalid package.json for '{s}'", .{specifier}),
        error.ModuleNotProvided => std.fmt.allocPrint(alloc, "!'{s}' is not provided by fx:host yet; it is on the gap list in docs/host-interface.md", .{specifier}),
    };
}

pub fn resolve(alloc: std.mem.Allocator, mode: Mode, base: []const u8, specifier: []const u8) (Failure || std.mem.Allocator.Error)![]u8 {
    if (try host_module.target(specifier)) |found| return alloc.dupe(u8, found);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (try importMapTarget(arena, specifier)) |mapped| return alloc.dupe(u8, mapped);
    const request = (try splitRequest(arena, specifier)) orelse return error.ModuleNotFound;
    const conditions: []const []const u8 = switch (mode) {
        .import => &.{ "import", "default" },
        .require => &.{ "require", "default" },
    };
    if (!std.mem.startsWith(u8, base, embedded_prefix)) {
        var dir = std.fs.path.dirname(base) orelse "/";
        while (true) {
            const package_dir = try std.fs.path.join(arena, &.{ dir, "node_modules", request.package });
            if (try locate(arena, .{ .disk = package_dir }, request, conditions)) |found| return alloc.dupe(u8, found);
            if (std.mem.eql(u8, dir, "/")) break;
            dir = std.fs.path.dirname(dir) orelse "/";
        }
    }
    if (std.mem.eql(u8, request.package, embedded_package)) {
        if (try locate(arena, .embedded, request, conditions)) |found| return alloc.dupe(u8, found);
    }
    return error.ModuleNotFound;
}

fn jsRoot() ?[]const u8 {
    return io_mod.getenv("FX_JS_ROOT");
}

fn joinRoot(arena: std.mem.Allocator, parts: []const []const u8) (Failure || std.mem.Allocator.Error)![]u8 {
    return std.fs.path.join(arena, parts) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PackageInvalid,
    };
}

fn importMapTarget(arena: std.mem.Allocator, specifier: []const u8) (Failure || std.mem.Allocator.Error)!?[]const u8 {
    const root = jsRoot() orelse return null;
    const map_path = try joinRoot(arena, &.{ root, "fx.importmap.json" });
    const text = readDisk(arena, map_path) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch return error.PackageInvalid;
    const imports = switch (parsed.value) {
        .object => |object| object.get("imports") orelse return null,
        else => return null,
    };
    const target = switch (imports) {
        .object => |map| map.get(specifier) orelse return null,
        else => return null,
    };
    const relative = switch (target) {
        .string => |value| value,
        else => return null,
    };
    return try joinRoot(arena, &.{ root, relative });
}

fn splitRequest(arena: std.mem.Allocator, specifier: []const u8) !?Request {
    if (specifier.len == 0 or specifier[0] == '.' or specifier[0] == '/') return null;
    const name_end = packageNameEnd(specifier) orelse return null;
    const rest = specifier[name_end..];
    const key = if (rest.len == 0) "." else try std.fmt.allocPrint(arena, ".{s}", .{rest});
    return .{ .package = specifier[0..name_end], .key = key };
}

fn packageNameEnd(specifier: []const u8) ?usize {
    if (specifier[0] != '@') return std.mem.indexOfScalar(u8, specifier, '/') orelse specifier.len;
    const slash = std.mem.indexOfScalar(u8, specifier, '/') orelse return null;
    return std.mem.indexOfScalarPos(u8, specifier, slash + 1, '/') orelse specifier.len;
}

fn locate(arena: std.mem.Allocator, root: Root, request: Request, conditions: []const []const u8) (Failure || std.mem.Allocator.Error)!?[]const u8 {
    const text: ?[]const u8 = switch (root) {
        .disk => |dir| readDisk(arena, try std.fs.path.join(arena, &.{ dir, "package.json" })),
        .embedded => cordis.source("package.json"),
    };
    const package_json = text orelse return fileForKey(arena, root, request.key);
    const parsed = std.json.parseFromSlice(std.json.Value, arena, package_json, .{}) catch return error.PackageInvalid;
    if (parsed.value != .object) return error.PackageInvalid;
    if (parsed.value.object.get("exports")) |exports| {
        const target = (try exportTarget(arena, exports, request, conditions)) orelse return error.PackagePathNotExported;
        if (try fileAt(arena, root, stripDot(target))) |found| return found;
        return error.ModuleNotFound;
    }
    if (std.mem.eql(u8, request.key, ".")) {
        const main = if (parsed.value.object.get("main")) |value| switch (value) {
            .string => |text_value| text_value,
            else => "index.js",
        } else "index.js";
        return firstExisting(arena, root, stripDot(main));
    }
    return firstExisting(arena, root, request.key[2..]);
}

fn fileForKey(arena: std.mem.Allocator, root: Root, key: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, key, ".")) return firstExisting(arena, root, "index.js");
    return firstExisting(arena, root, key[2..]);
}

fn stripDot(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
}

fn firstExisting(arena: std.mem.Allocator, root: Root, plain: []const u8) !?[]const u8 {
    if (try fileAt(arena, root, plain)) |found| return found;
    if (try fileAt(arena, root, try std.fmt.allocPrint(arena, "{s}.js", .{plain}))) |found| return found;
    return fileAt(arena, root, try std.fmt.allocPrint(arena, "{s}/index.js", .{plain}));
}

fn fileAt(arena: std.mem.Allocator, root: Root, plain: []const u8) !?[]const u8 {
    switch (root) {
        .disk => |dir| {
            const path = try std.fs.path.join(arena, &.{ dir, plain });
            return if (isFile(path)) path else null;
        },
        .embedded => {
            if (cordis.source(plain) == null) return null;
            return try std.fmt.allocPrint(arena, "{s}{s}", .{ embedded_prefix, plain });
        },
    }
}

fn exportTarget(arena: std.mem.Allocator, exports: std.json.Value, request: Request, conditions: []const []const u8) (Failure || std.mem.Allocator.Error)!?[]const u8 {
    if (!isSubpathMap(exports)) {
        if (!std.mem.eql(u8, request.key, ".")) return null;
        return resolveTarget(arena, exports, conditions, null);
    }
    const object = exports.object;
    if (object.get(request.key)) |target| return resolveTarget(arena, target, conditions, null);
    var best: ?Match = null;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const pattern = entry.key_ptr.*;
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse continue;
        const prefix = pattern[0..star];
        const suffix = pattern[star + 1 ..];
        if (request.key.len < prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, request.key, prefix) or !std.mem.endsWith(u8, request.key, suffix)) continue;
        if (best == null or prefix.len > best.?.prefix.len) {
            best = .{
                .prefix = prefix,
                .capture = request.key[prefix.len .. request.key.len - suffix.len],
                .target = entry.value_ptr.*,
            };
        }
    }
    const match = best orelse return null;
    return resolveTarget(arena, match.target, conditions, match.capture);
}

fn isSubpathMap(value: std.json.Value) bool {
    if (value != .object) return false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, ".")) return true;
    }
    return false;
}

fn resolveTarget(arena: std.mem.Allocator, target: std.json.Value, conditions: []const []const u8, capture: ?[]const u8) (Failure || std.mem.Allocator.Error)!?[]const u8 {
    switch (target) {
        .string => |text| {
            const resolved = if (capture) |value| try std.mem.replaceOwned(u8, arena, text, "*", value) else text;
            if (!std.mem.startsWith(u8, resolved, "./")) return error.PackageInvalid;
            return resolved;
        },
        .array => |items| {
            for (items.items) |item| {
                if (try resolveTarget(arena, item, conditions, capture)) |found| return found;
            }
            return null;
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (!isCondition(entry.key_ptr.*, conditions)) continue;
                if (try resolveTarget(arena, entry.value_ptr.*, conditions, capture)) |found| return found;
            }
            return null;
        },
        .null => return null,
        else => return error.PackageInvalid,
    }
}

fn isCondition(key: []const u8, conditions: []const []const u8) bool {
    for (conditions) |condition| {
        if (std.mem.eql(u8, condition, key)) return true;
    }
    return false;
}

fn readDisk(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const io = io_mod.getIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return io_mod.readFileToEnd(arena, &file, max_package_bytes) catch null;
}

fn isFile(path: []const u8) bool {
    const io = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test "bare specifiers follow exports conditions and subpath patterns" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "node_modules/pkg/src");
    try tmp.dir.createDirPath(io, "node_modules/solo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/package.json", .data = "{\"name\":\"pkg\",\"exports\":{\".\":{\"import\":\"./src/index.mjs\",\"require\":\"./src/index.cjs\"},\"./*\":{\"default\":\"./src/*.js\"}}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/src/index.mjs", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/src/index.cjs", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/src/fs.js", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/solo/package.json", .data = "{\"name\":\"solo\",\"exports\":{\".\":\"./src/index.js\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/solo/src/index.js", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir);
    const base = try std.fmt.allocPrint(alloc, "{s}/entry.js", .{dir});
    defer alloc.free(base);

    const esm = try resolve(alloc, .import, base, "pkg");
    defer alloc.free(esm);
    try std.testing.expect(std.mem.endsWith(u8, esm, "/src/index.mjs"));
    const cjs = try resolve(alloc, .require, base, "pkg");
    defer alloc.free(cjs);
    try std.testing.expect(std.mem.endsWith(u8, cjs, "/src/index.cjs"));
    const sub = try resolve(alloc, .import, base, "pkg/fs");
    defer alloc.free(sub);
    try std.testing.expect(std.mem.endsWith(u8, sub, "/src/fs.js"));
    try std.testing.expectError(error.PackagePathNotExported, resolve(alloc, .import, base, "solo/fs"));
}

test "the embedded freddie runtime resolves its subpath exports" {
    const alloc = std.testing.allocator;
    const found = try resolve(alloc, .import, "/nowhere/entry.js", "@freddie/freddie-runtime/fs-promises");
    defer alloc.free(found);
    try std.testing.expectEqualStrings("freddie:src/fs-promises.js", found);
}
