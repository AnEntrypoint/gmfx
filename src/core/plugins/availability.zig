const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const marketplace = @import("marketplace.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;

const availability_file_name = "availability.json";
const availability_version: u8 = 1;
const max_availability_bytes: usize = 4 * 1024 * 1024;
const source_key_prefix = "sha256:";
const sha256_hex_len = std.crypto.hash.sha2.Sha256.digest_length * 2;

pub const Entry = struct {
    id: []const u8,
    clients: ?[]const marketplace.Client = null,
    platforms: ?[]const marketplace.Platform = null,
    artifact_source_key: ?[]const u8 = null,
    checked_at_ms: i64 = 0,
};

pub const Source = struct {
    key: []const u8,
    entries: []const Entry = &.{},
};

pub const File = struct {
    version: u8 = availability_version,
    sources: []const Source = &.{},
};

const offered_nowhere: Entry = .{ .id = "", .clients = &.{}, .platforms = &.{} };

pub fn filePath(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{ store.plugins_dir_name, availability_file_name });
}

pub fn sourceKey(arena: Allocator, source: []const u8) ![]const u8 {
    const normalized = std.mem.trim(u8, source, " \t\r\n");
    if (isSourceKey(normalized)) return normalized;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ source_key_prefix, &hex });
}

fn isSourceKey(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, source_key_prefix)) return false;
    const hex = text[source_key_prefix.len..];
    if (hex.len != sha256_hex_len) return false;
    for (hex) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

pub fn read(arena: Allocator, home: []const u8) !File {
    const path = try filePath(arena, home);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_availability_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const file = std.json.parseFromSliceLeaky(File, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPluginAvailabilityCache,
    };
    if (file.version != availability_version) return error.InvalidPluginAvailabilityCache;
    return file;
}

pub fn readOrEmpty(arena: Allocator, home: []const u8) Allocator.Error!File {
    return read(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => File{},
    };
}

pub fn update(arena: Allocator, home: []const u8, catalog: marketplace.Catalog, now_ms: i64) !bool {
    const key = try sourceKey(arena, catalog.source);
    const latest = try readOrEmpty(arena, home);
    const existing: []const Entry = if (findSource(latest, key)) |source| source.entries else &.{};

    var merged: std.ArrayList(Entry) = .empty;
    var changed = false;
    for (catalog.plugins) |plugin| {
        const incoming: Entry = .{
            .id = plugin.id,
            .clients = plugin.clients,
            .platforms = plugin.platforms,
            .artifact_source_key = try sourceKey(arena, plugin.source),
            .checked_at_ms = now_ms,
        };
        if (findEntry(existing, plugin.id)) |known| {
            if (!sameHosts(known, incoming)) changed = true;
        } else {
            changed = true;
        }
        try merged.append(arena, incoming);
    }
    if (!changed) return false;
    for (existing) |known| {
        if (findEntry(merged.items, known.id) == null) try merged.append(arena, known);
    }

    var sources: std.ArrayList(Source) = .empty;
    for (latest.sources) |source| {
        if (!std.mem.eql(u8, source.key, key)) try sources.append(arena, source);
    }
    try sources.append(arena, .{ .key = key, .entries = merged.items });
    try write(arena, home, .{ .sources = sources.items });
    return true;
}

fn write(alloc: Allocator, home: []const u8, file: File) !void {
    const dir = try store.storeDir(alloc, home);
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir);
    const path = try filePath(alloc, home);
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

fn findSource(file: File, key: []const u8) ?Source {
    for (file.sources) |source| {
        if (std.mem.eql(u8, source.key, key)) return source;
    }
    return null;
}

fn findEntry(entries: []const Entry, id: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn sameHosts(lhs: Entry, rhs: Entry) bool {
    return sameSet(marketplace.Client, lhs.clients, rhs.clients) and sameSet(marketplace.Platform, lhs.platforms, rhs.platforms);
}

fn sameSet(comptime Tag: type, lhs: ?[]const Tag, rhs: ?[]const Tag) bool {
    const left = lhs orelse return rhs == null;
    const right = rhs orelse return false;
    for (left) |tag| {
        if (std.mem.findScalar(Tag, right, tag) == null) return false;
    }
    for (right) |tag| {
        if (std.mem.findScalar(Tag, left, tag) == null) return false;
    }
    return true;
}

pub fn entryFor(arena: Allocator, file: File, record: store.Record) !?Entry {
    if (std.mem.eql(u8, record.origin, store.origin_custom)) return null;
    const provenance_unknown = !std.mem.eql(u8, record.origin, store.origin_marketplace);
    const catalog_id = record.catalog_id orelse (if (provenance_unknown) record.id else return null);
    const original_key = try sourceKey(arena, record.source);

    if (record.marketplace_source) |marketplace_source| {
        const source = findSource(file, try sourceKey(arena, marketplace_source)) orelse return null;
        const entry = findEntry(source.entries, catalog_id) orelse return null;
        if (provenance_unknown and !cameFrom(entry, original_key)) return null;
        return entry;
    }

    var matches: std.ArrayList(Entry) = .empty;
    var from_same_artifact: std.ArrayList(Entry) = .empty;
    for (file.sources) |source| {
        const entry = findEntry(source.entries, catalog_id) orelse continue;
        try matches.append(arena, entry);
        if (cameFrom(entry, original_key)) try from_same_artifact.append(arena, entry);
    }
    if (provenance_unknown) {
        if (from_same_artifact.items.len == 1) return from_same_artifact.items[0];
        return if (from_same_artifact.items.len == 0) null else offered_nowhere;
    }
    if (matches.items.len == 1) return matches.items[0];
    if (matches.items.len == 0) return null;
    if (from_same_artifact.items.len == 1) return from_same_artifact.items[0];
    return offered_nowhere;
}

fn cameFrom(entry: Entry, original_key: []const u8) bool {
    const artifact_key = entry.artifact_source_key orelse return false;
    return std.mem.eql(u8, artifact_key, original_key);
}

pub fn supports(arena: Allocator, file: File, record: store.Record, client: marketplace.Client, platform: ?marketplace.Platform) !bool {
    const entry = (try entryFor(arena, file, record)) orelse return true;
    return marketplace.installableOnHost(entry.clients, entry.platforms, client, platform);
}

const testing = std.testing;

fn catalogWith(plugins: []const marketplace.Entry) marketplace.Catalog {
    return .{ .source = "https://example.test/catalog.json", .plugins = plugins };
}

test "availability records a catalog once and rewrites only when clients or platforms change" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try testing.expectEqual(@as(usize, 0), (try read(arena, home)).sources.len);

    const linux_only = [_]marketplace.Platform{.linux};
    const first = [_]marketplace.Entry{.{ .id = "acme", .display_name = "Acme", .source = "https://example.test/acme.zip", .platforms = &linux_only }};
    try testing.expect(try update(arena, home, catalogWith(&first), 10));
    try testing.expect(!(try update(arena, home, catalogWith(&first), 20)));

    const stored = try read(arena, home);
    try testing.expectEqual(@as(usize, 1), stored.sources.len);
    try testing.expect(std.mem.startsWith(u8, stored.sources[0].key, "sha256:"));
    try testing.expectEqual(@as(i64, 10), stored.sources[0].entries[0].checked_at_ms);
    try testing.expectEqual(marketplace.Platform.linux, stored.sources[0].entries[0].platforms.?[0]);

    const mac_only = [_]marketplace.Platform{.darwin};
    const second = [_]marketplace.Entry{.{ .id = "acme", .display_name = "Acme", .source = "https://example.test/acme.zip", .platforms = &mac_only }};
    try testing.expect(try update(arena, home, catalogWith(&second), 30));
    try testing.expectEqual(marketplace.Platform.darwin, (try read(arena, home)).sources[0].entries[0].platforms.?[0]);
}

test "a marketplace plugin is supported only on the clients and platforms its catalog entry names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog_key = try sourceKey(arena, "https://example.test/catalog.json");
    const mac_only = [_]marketplace.Platform{.darwin};
    const desktop_only = [_]marketplace.Client{.desktop};
    const entries = [_]Entry{
        .{ .id = "mac-tool", .platforms = &mac_only },
        .{ .id = "desktop-tool", .clients = &desktop_only },
        .{ .id = "anywhere" },
    };
    const sources = [_]Source{.{ .key = catalog_key, .entries = &entries }};
    const file: File = .{ .sources = &sources };

    const mac_tool: store.Record = .{ .id = "mac-tool", .root = "/p", .source = "https://example.test/mac.zip", .origin = store.origin_marketplace, .catalog_id = "mac-tool", .marketplace_source = catalog_key };
    try testing.expect(!(try supports(arena, file, mac_tool, .cli, .linux)));
    try testing.expect(try supports(arena, file, mac_tool, .cli, .darwin));

    const desktop_tool: store.Record = .{ .id = "desktop-tool", .root = "/p", .source = "https://example.test/d.zip", .origin = store.origin_marketplace, .catalog_id = "desktop-tool" };
    try testing.expect(!(try supports(arena, file, desktop_tool, .cli, .linux)));
    try testing.expect(try supports(arena, file, desktop_tool, .desktop, .linux));

    const anywhere: store.Record = .{ .id = "anywhere", .root = "/p", .source = "https://example.test/a.zip", .origin = store.origin_marketplace, .catalog_id = "anywhere" };
    try testing.expect(try supports(arena, file, anywhere, .cli, .linux));

    const custom: store.Record = .{ .id = "mac-tool", .root = "/p", .source = "/src/mac-tool" };
    try testing.expect(try supports(arena, file, custom, .cli, .linux));

    const uncatalogued: store.Record = .{ .id = "other", .root = "/p", .source = "https://example.test/o.zip", .origin = store.origin_marketplace, .catalog_id = "other" };
    try testing.expect(try supports(arena, file, uncatalogued, .cli, .linux));
}

test "a plugin of unknown origin is filtered only when its artifact matches the catalog entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mac_only = [_]marketplace.Platform{.darwin};
    const entries = [_]Entry{.{ .id = "mac-tool", .platforms = &mac_only, .artifact_source_key = try sourceKey(arena, "https://example.test/mac.zip") }};
    const sources = [_]Source{.{ .key = try sourceKey(arena, "https://example.test/catalog.json"), .entries = &entries }};
    const file: File = .{ .sources = &sources };

    const same_artifact: store.Record = .{ .id = "mac-tool", .root = "/p", .source = "https://example.test/mac.zip", .origin = store.origin_unknown };
    try testing.expect(!(try supports(arena, file, same_artifact, .cli, .linux)));

    const other_artifact: store.Record = .{ .id = "mac-tool", .root = "/p", .source = "https://elsewhere.test/mac.zip", .origin = store.origin_unknown };
    try testing.expect(try supports(arena, file, other_artifact, .cli, .linux));
}

test "an availability cache that is not this version is reported and read as empty by the tolerant reader" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fx/plugins");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fx/plugins/availability.json", .data = "{\"version\":9,\"sources\":[]}" });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try testing.expectError(error.InvalidPluginAvailabilityCache, read(arena, home));
    try testing.expectEqual(@as(usize, 0), (try readOrEmpty(arena, home)).sources.len);
}
