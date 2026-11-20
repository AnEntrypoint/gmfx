const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const availability = @import("availability.zig");
const manager = @import("manager.zig");
const remote = @import("remote.zig");
const sources = @import("source.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const env_names = [_][]const u8{ "FX_PLUGIN_MARKETPLACE_URL", "KIMI_CODE_PLUGIN_MARKETPLACE_URL" };
pub const catalog_path_suffix = "/plugins/marketplace";
pub const trusted_catalog_urls = [_][]const u8{};
pub const official_source_prefixes = [_][]const u8{};
const max_catalog_bytes: usize = 8 * 1024 * 1024;
const sha256_hex_len = 64;

pub const Tier = enum { official, curated };
pub const Classification = enum { official, third_party };
pub const Platform = enum { darwin, win32, linux, cloud };
pub const Client = enum { desktop, cli };

pub const host_client: Client = .cli;

pub fn hostPlatform() ?Platform {
    return switch (builtin.os.tag) {
        .macos => .darwin,
        .windows => .win32,
        .linux => .linux,
        else => null,
    };
}

pub const Entry = struct {
    id: []const u8,
    display_name: []const u8,
    source: []const u8,
    classification: ?Classification = null,
    tier: ?Tier = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    sha256sum: ?[]const u8 = null,
    clients: ?[]const Client = null,
    platforms: ?[]const Platform = null,
};

pub const Catalog = struct {
    source: []const u8,
    version: ?[]const u8 = null,
    plugins: []const Entry = &.{},
};

pub const LocationKind = enum { remote, local };

pub const Location = struct {
    kind: LocationKind,
    resolved: []const u8,
};

pub const Failure = struct {
    message: []const u8 = "",
};

pub const Error = error{
    PluginMarketplaceNotConfigured,
    PluginMarketplaceUntrustedHost,
    PluginMarketplaceUnreadable,
    PluginMarketplaceInvalid,
    MarketplacePluginNotFound,
    MarketplaceEntryNeedsSha256,
    MarketplaceEntryUnsupportedHost,
};

pub fn catalogUrl(arena: Allocator, base_url: []const u8) ![]const u8 {
    const normalized = std.mem.trimEnd(u8, std.mem.trim(u8, base_url, " \t\r\n"), "/");
    if (normalized.len == 0) return error.PluginMarketplaceNotConfigured;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ normalized, catalog_path_suffix });
}

pub fn configuredSource(explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |source| {
        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    for (env_names) |name| {
        const value = std.mem.trim(u8, io_mod.getenv(name) orelse continue, " \t\r\n");
        if (value.len > 0) return value;
    }
    return null;
}

pub fn isTrustedCatalogUrl(source: []const u8) bool {
    const normalized = std.mem.trimEnd(u8, std.mem.trim(u8, source, " \t\r\n"), "/");
    for (trusted_catalog_urls) |trusted| {
        if (std.mem.eql(u8, normalized, trusted)) return true;
    }
    return false;
}

pub fn isOfficialSource(source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "https://")) return false;
    for (official_source_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }
    return false;
}

pub fn remoteCatalogAllowed(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    const plain = "http://";
    if (!std.mem.startsWith(u8, url, plain)) return false;
    const after_scheme = url[plain.len..];
    const authority_end = std.mem.findAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    const authority = after_scheme[0..authority_end];
    if (std.mem.startsWith(u8, authority, "[::1]")) return authority.len == 5 or authority[5] == ':';
    const host_end = std.mem.findScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..host_end];
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

pub fn resolveLocation(arena: Allocator, source: []const u8, work_dir: []const u8, home: ?[]const u8) !Location {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return error.PluginMarketplaceNotConfigured;
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return .{ .kind = .remote, .resolved = trimmed };
    }
    const file_scheme = "file://";
    if (std.mem.startsWith(u8, trimmed, file_scheme)) return .{ .kind = .local, .resolved = trimmed[file_scheme.len..] };
    return .{ .kind = .local, .resolved = try resolveLocalPath(arena, trimmed, work_dir, home) };
}

pub fn resolveLocalPath(arena: Allocator, input: []const u8, work_dir: []const u8, home: ?[]const u8) ![]const u8 {
    if (home) |home_dir| {
        if (std.mem.eql(u8, input, "~")) return home_dir;
        if (std.mem.startsWith(u8, input, "~/")) return std.Io.Dir.path.join(arena, &.{ home_dir, input[2..] });
    }
    if (std.Io.Dir.path.isAbsolute(input)) return input;
    return std.Io.Dir.path.resolveAlloc(arena, &.{ work_dir, input });
}

pub fn parse(arena: Allocator, raw: []const u8, location: Location, failure: *Failure) error{ OutOfMemory, PluginMarketplaceInvalid }!Catalog {
    const document = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "Plugin marketplace is not valid JSON: {s}", .{@errorName(err)}),
    };
    if (document != .object) return fail(arena, failure, "Plugin marketplace must be an object.", .{});
    const raw_plugins = document.object.get("plugins") orelse return fail(arena, failure, "Plugin marketplace must contain a \"plugins\" array.", .{});
    if (raw_plugins != .array) return fail(arena, failure, "Plugin marketplace must contain a \"plugins\" array.", .{});

    const plugins = try arena.alloc(Entry, raw_plugins.array.items.len);
    for (raw_plugins.array.items, 0..) |item, index| {
        plugins[index] = try parseEntry(arena, item, index, location, failure);
    }
    return .{
        .source = location.resolved,
        .version = stringField(document.object, "version"),
        .plugins = plugins,
    };
}

fn fail(arena: Allocator, failure: *Failure, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, PluginMarketplaceInvalid } {
    failure.message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.PluginMarketplaceInvalid;
}

fn parseEntry(arena: Allocator, value: Value, index: usize, location: Location, failure: *Failure) error{ OutOfMemory, PluginMarketplaceInvalid }!Entry {
    if (value != .object) return fail(arena, failure, "Plugin marketplace entry {d} must be an object.", .{index + 1});
    const object = value.object;
    const id = stringField(object, "id") orelse return fail(arena, failure, "Plugin marketplace entry {d} must define \"id\".", .{index + 1});
    if (object.get("type")) |raw_type| {
        if (raw_type != .string) return fail(arena, failure, "Plugin marketplace entry {s} \"type\" must be a string.", .{id});
        const kind = std.mem.trim(u8, raw_type.string, " \t\r\n");
        if (!std.mem.eql(u8, kind, "plugin") and !std.mem.eql(u8, kind, "managed") and !std.mem.eql(u8, kind, "guide")) {
            return fail(arena, failure, "Plugin marketplace entry {s} \"type\" must be \"plugin\". Legacy aliases \"managed\" and \"guide\" are also accepted.", .{id});
        }
    }
    const source = stringField(object, "source") orelse stringField(object, "url") orelse stringField(object, "downloadUrl") orelse
        return fail(arena, failure, "Plugin marketplace entry {s} must define \"source\".", .{id});

    var classification: ?Classification = null;
    var tier: ?Tier = null;
    if (object.get("distribution")) |distribution| {
        if (distribution != .object) return fail(arena, failure, "Plugin marketplace entry {s} must define \"distribution\".", .{id});
        const category = stringField(distribution.object, "category") orelse "";
        const category_tag = std.meta.stringToEnum(Classification, category) orelse
            return fail(arena, failure, "Plugin marketplace entry {s} \"distribution.category\" must be one of: official, third_party.", .{id});
        classification = category_tag;
        tier = switch (category_tag) {
            .official => .official,
            .third_party => .curated,
        };
    } else if (object.get("tier")) |raw_tier| {
        if (raw_tier != .string) return fail(arena, failure, "Plugin marketplace entry {s} \"tier\" must be a string.", .{id});
        const name = std.mem.trim(u8, raw_tier.string, " \t\r\n");
        if (name.len > 0) {
            const tier_tag = std.meta.stringToEnum(Tier, name) orelse
                return fail(arena, failure, "Plugin marketplace entry {s} \"tier\" must be one of: official, curated.", .{id});
            tier = tier_tag;
            classification = switch (tier_tag) {
                .official => .official,
                .curated => .third_party,
            };
        }
    }

    const sha256sum = stringField(object, "sha256sum");
    if (sha256sum) |digest| {
        if (!isSha256Hex(digest)) return fail(arena, failure, "Plugin marketplace entry {s} \"sha256sum\" must be a SHA-256 hex digest.", .{id});
    }

    return .{
        .id = id,
        .display_name = stringField(object, "displayName") orelse stringField(object, "name") orelse id,
        .source = try resolveEntrySource(arena, source, location),
        .classification = classification,
        .tier = tier,
        .version = stringField(object, "version"),
        .description = stringField(object, "description") orelse stringField(object, "shortDescription"),
        .homepage = stringField(object, "homepage") orelse stringField(object, "websiteURL"),
        .sha256sum = sha256sum,
        .clients = try parseClients(arena, object.get("clients")),
        .platforms = try parsePlatforms(arena, object.get("platforms"), id, failure),
    };
}

pub fn isSha256Hex(text: []const u8) bool {
    if (text.len != sha256_hex_len) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn parseClients(arena: Allocator, value: ?Value) Allocator.Error!?[]const Client {
    const raw = value orelse return null;
    var out: std.ArrayList(Client) = .empty;
    if (raw != .array) return try out.toOwnedSlice(arena);
    for (raw.array.items) |item| {
        if (item != .string) continue;
        const client = std.meta.stringToEnum(Client, item.string) orelse continue;
        if (std.mem.findScalar(Client, out.items, client) == null) try out.append(arena, client);
    }
    return try out.toOwnedSlice(arena);
}

fn parsePlatforms(arena: Allocator, value: ?Value, id: []const u8, failure: *Failure) error{ OutOfMemory, PluginMarketplaceInvalid }!?[]const Platform {
    const raw = value orelse return null;
    if (raw != .array or raw.array.items.len == 0) {
        return fail(arena, failure, "Plugin marketplace entry {s} \"platforms\" must be a non-empty array.", .{id});
    }
    var out: std.ArrayList(Platform) = .empty;
    for (raw.array.items) |item| {
        const platform = (if (item == .string) platformNamed(item.string) else null) orelse
            return fail(arena, failure, "Plugin marketplace entry {s} \"platforms\" must contain only: macos, windows, linux, cloud, darwin, win32.", .{id});
        if (std.mem.findScalar(Platform, out.items, platform) == null) try out.append(arena, platform);
    }
    return try out.toOwnedSlice(arena);
}

fn platformNamed(name: []const u8) ?Platform {
    if (std.mem.eql(u8, name, "macos") or std.mem.eql(u8, name, "darwin")) return .darwin;
    if (std.mem.eql(u8, name, "windows") or std.mem.eql(u8, name, "win32")) return .win32;
    if (std.mem.eql(u8, name, "linux")) return .linux;
    if (std.mem.eql(u8, name, "cloud")) return .cloud;
    return null;
}

fn resolveEntrySource(arena: Allocator, source: []const u8, location: Location) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) return source;
    const file_scheme = "file://";
    if (std.mem.startsWith(u8, source, file_scheme)) return source[file_scheme.len..];
    if (std.mem.eql(u8, source, "~") or std.mem.startsWith(u8, source, "~/")) {
        const home = io_mod.homeDir() orelse return source;
        if (source.len == 1) return home;
        return std.Io.Dir.path.join(arena, &.{ home, source[2..] });
    }
    if (std.Io.Dir.path.isAbsolute(source)) return source;
    return switch (location.kind) {
        .remote => relativeToUrl(arena, location.resolved, source),
        .local => std.Io.Dir.path.resolveAlloc(arena, &.{ std.Io.Dir.path.dirname(location.resolved) orelse ".", source }),
    };
}

fn relativeToUrl(arena: Allocator, base: []const u8, reference: []const u8) Allocator.Error![]const u8 {
    const scheme_end = (std.mem.find(u8, base, "://") orelse return reference) + "://".len;
    const without_query = base[0 .. std.mem.findAny(u8, base, "?#") orelse base.len];
    const path_start = if (std.mem.findScalar(u8, without_query[scheme_end..], '/')) |at| scheme_end + at else without_query.len;
    if (std.mem.startsWith(u8, reference, "/")) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ without_query[0..path_start], reference });
    }
    const last_slash = std.mem.findScalarLast(u8, without_query[path_start..], '/');
    const directory = if (last_slash) |at| without_query[0 .. path_start + at + 1] else try std.fmt.allocPrint(arena, "{s}/", .{without_query[0..path_start]});
    const relative = if (std.mem.startsWith(u8, reference, "./")) reference[2..] else reference;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ directory, relative });
}

fn stringField(object: ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn installableOnHost(clients: ?[]const Client, platforms: ?[]const Platform, client: Client, platform: ?Platform) bool {
    if (clients) |supported| {
        if (std.mem.findScalar(Client, supported, client) == null) return false;
    }
    const supported_platforms = platforms orelse return true;
    const host = platform orelse return false;
    return std.mem.findScalar(Platform, supported_platforms, host) != null;
}

pub fn visibleOnHost(clients: ?[]const Client, platforms: ?[]const Platform, client: Client, platform: ?Platform) bool {
    if (clients) |supported| {
        if (std.mem.findScalar(Client, supported, client) == null) return false;
    }
    const supported_platforms = platforms orelse return true;
    if (platform) |host| {
        if (std.mem.findScalar(Platform, supported_platforms, host) != null) return true;
    }
    for (supported_platforms) |candidate| {
        if (candidate != .cloud) return false;
    }
    return true;
}

pub fn findEntry(catalog: Catalog, id: []const u8) ?Entry {
    for (catalog.plugins) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, id)) return entry;
    }
    return null;
}

pub fn load(
    arena: Allocator,
    home: []const u8,
    work_dir: []const u8,
    explicit_source: ?[]const u8,
    fetcher: remote.Fetcher,
    now_ms: i64,
    failure: *Failure,
) !Catalog {
    const source = configuredSource(explicit_source) orelse return error.PluginMarketplaceNotConfigured;
    const location = try resolveLocation(arena, source, work_dir, home);
    const raw = switch (location.kind) {
        .local => std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), location.resolved, arena, .limited(max_catalog_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PluginMarketplaceUnreadable,
        },
        .remote => from_remote: {
            if (!remoteCatalogAllowed(location.resolved)) return error.PluginMarketplaceUntrustedHost;
            const response = fetcher.fetch(arena, location.resolved) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.PluginMarketplaceUnreadable,
            };
            if (response.status != .ok) return error.PluginMarketplaceUnreadable;
            break :from_remote response.body;
        },
    };
    const catalog = try parse(arena, raw, location, failure);
    _ = availability.update(arena, home, catalog, now_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    return catalog;
}

pub const InstallRequest = struct {
    trusted: bool = false,
    fetcher: remote.Fetcher = remote.live,
};

pub fn entryNeedsTrustPrompt(catalog: Catalog, entry: Entry) bool {
    if (isOfficialSource(entry.source)) return false;
    const classified_official = if (entry.classification) |classification| classification == .official else false;
    return !(classified_official and isTrustedCatalogUrl(catalog.source));
}

pub fn installEntry(arena: Allocator, home: []const u8, catalog: Catalog, id: []const u8, now_ms: i64, request: InstallRequest) !manager.Plugin {
    const entry = findEntry(catalog, id) orelse return error.MarketplacePluginNotFound;
    if (!installableOnHost(entry.clients, entry.platforms, host_client, hostPlatform())) return error.MarketplaceEntryUnsupportedHost;
    const resolved = try sources.resolve(arena, entry.source);
    if (resolved == .zip_url) {
        if (entry.sha256sum == null) return error.MarketplaceEntryNeedsSha256;
        if (!std.mem.startsWith(u8, entry.source, "https://")) return error.MarketplaceInstallNeedsZipUrl;
    }
    return manager.install(arena, home, entry.source, now_ms, .{
        .trusted = request.trusted or !entryNeedsTrustPrompt(catalog, entry),
        .expected_id = entry.id,
        .expected_sha256 = if (resolved == .zip_url) entry.sha256sum else null,
        .origin = store.origin_marketplace,
        .catalog_id = entry.id,
        .marketplace_source = try availability.sourceKey(arena, catalog.source),
        .fetcher = request.fetcher,
    });
}

const testing = std.testing;

const sample_catalog =
    \\{"version":"3","plugins":[
    \\  {"id":"acme","displayName":"Acme Tools","source":"./acme.zip","tier":"official","version":"1.2.0",
    \\   "sha256sum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\   "platforms":["macos","linux"],"clients":["cli","tablet"]},
    \\  {"id":"helper","url":"https://github.com/acme/helper","distribution":{"category":"third_party"},"description":"Helps"},
    \\  {"id":"plain","downloadUrl":"/abs/plain.zip","type":"managed"}
    \\]}
;

test "catalog parsing keeps tier, classification, platforms, clients and resolves entry sources against the catalog" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: Failure = .{};

    const catalog = try parse(arena, sample_catalog, .{ .kind = .remote, .resolved = "https://plugins.example.test/v1/plugins/marketplace?x=1" }, &failure);
    try testing.expectEqualStrings("3", catalog.version.?);
    try testing.expectEqual(@as(usize, 3), catalog.plugins.len);

    const acme = catalog.plugins[0];
    try testing.expectEqualStrings("Acme Tools", acme.display_name);
    try testing.expectEqualStrings("https://plugins.example.test/v1/plugins/acme.zip", acme.source);
    try testing.expectEqual(Tier.official, acme.tier.?);
    try testing.expectEqual(Classification.official, acme.classification.?);
    try testing.expectEqualSlices(Platform, &.{ .darwin, .linux }, acme.platforms.?);
    try testing.expectEqualSlices(Client, &.{.cli}, acme.clients.?);
    try testing.expectEqualStrings("1.2.0", acme.version.?);

    const helper = catalog.plugins[1];
    try testing.expectEqualStrings("helper", helper.display_name);
    try testing.expectEqual(Tier.curated, helper.tier.?);
    try testing.expectEqual(Classification.third_party, helper.classification.?);
    try testing.expect(helper.platforms == null);
    try testing.expect(helper.sha256sum == null);

    const plain = catalog.plugins[2];
    try testing.expectEqualStrings("/abs/plain.zip", plain.source);
    try testing.expect(plain.tier == null);

    const local = try parse(arena, sample_catalog, .{ .kind = .local, .resolved = "/srv/catalog/marketplace.json" }, &failure);
    try testing.expectEqualStrings("/srv/catalog/acme.zip", local.plugins[0].source);
    try testing.expectEqualStrings("/abs/plain.zip", local.plugins[2].source);
}

test "catalog parsing names the entry and field that is wrong" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const location: Location = .{ .kind = .local, .resolved = "/srv/marketplace.json" };
    var failure: Failure = .{};

    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "[]", location, &failure));
    try testing.expectEqualStrings("Plugin marketplace must be an object.", failure.message);
    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "{\"plugins\":[{\"id\":\"a\"}]}", location, &failure));
    try testing.expectEqualStrings("Plugin marketplace entry a must define \"source\".", failure.message);
    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "{\"plugins\":[{\"id\":\"a\",\"source\":\"/a\",\"tier\":\"gold\"}]}", location, &failure));
    try testing.expectEqualStrings("Plugin marketplace entry a \"tier\" must be one of: official, curated.", failure.message);
    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "{\"plugins\":[{\"id\":\"a\",\"source\":\"/a\",\"sha256sum\":\"abc\"}]}", location, &failure));
    try testing.expectEqualStrings("Plugin marketplace entry a \"sha256sum\" must be a SHA-256 hex digest.", failure.message);
    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "{\"plugins\":[{\"id\":\"a\",\"source\":\"/a\",\"platforms\":[\"beos\"]}]}", location, &failure));
    try testing.expectError(error.PluginMarketplaceInvalid, parse(arena, "{\"plugins\":[{\"id\":\"a\",\"source\":\"/a\",\"platforms\":[]}]}", location, &failure));
}

test "the catalog URL is the base URL plus the marketplace path and an explicit source beats the environment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("https://api.example.test/v1/plugins/marketplace", try catalogUrl(arena, " https://api.example.test/v1// "));
    try testing.expectError(error.PluginMarketplaceNotConfigured, catalogUrl(arena, "  "));
    try testing.expectEqualStrings("/srv/catalog.json", configuredSource("  /srv/catalog.json ").?);
    try testing.expectEqualStrings("FX_PLUGIN_MARKETPLACE_URL", env_names[0]);
    try testing.expectEqualStrings("KIMI_CODE_PLUGIN_MARKETPLACE_URL", env_names[1]);
}

test "remote catalogs must be https unless they are served from this machine" {
    try testing.expect(remoteCatalogAllowed("https://plugins.example.test/plugins/marketplace"));
    try testing.expect(remoteCatalogAllowed("http://localhost:8080/plugins/marketplace"));
    try testing.expect(remoteCatalogAllowed("http://127.0.0.1/catalog.json"));
    try testing.expect(remoteCatalogAllowed("http://[::1]:9000/catalog.json"));
    try testing.expect(!remoteCatalogAllowed("http://plugins.example.test/plugins/marketplace"));
    try testing.expect(!remoteCatalogAllowed("http://localhost.evil.test/catalog.json"));
    try testing.expect(!remoteCatalogAllowed("ftp://localhost/catalog.json"));
    try testing.expect(!isTrustedCatalogUrl("https://plugins.example.test/plugins/marketplace"));
    try testing.expect(!isOfficialSource("https://plugins.example.test/official/acme.zip"));
}

test "marketplace locations are remote URLs, file URLs, home paths, or paths under the working directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const remote_location = try resolveLocation(arena, " https://example.test/c.json ", "/work", "/home/u");
    try testing.expectEqual(LocationKind.remote, remote_location.kind);
    try testing.expectEqualStrings("https://example.test/c.json", remote_location.resolved);
    try testing.expectEqualStrings("/srv/c.json", (try resolveLocation(arena, "file:///srv/c.json", "/work", "/home/u")).resolved);
    try testing.expectEqualStrings("/home/u/c.json", (try resolveLocation(arena, "~/c.json", "/work", "/home/u")).resolved);
    try testing.expectEqualStrings("/work/sub/c.json", (try resolveLocation(arena, "sub/c.json", "/work", "/home/u")).resolved);
    try testing.expectError(error.PluginMarketplaceNotConfigured, resolveLocation(arena, "  ", "/work", null));
}

test "a host sees entries for its client and platform, and cloud-only entries stay visible but not installable" {
    const mac_only = [_]Platform{.darwin};
    const cloud_only = [_]Platform{.cloud};
    const desktop_only = [_]Client{.desktop};

    try testing.expect(installableOnHost(null, null, .cli, .linux));
    try testing.expect(!installableOnHost(null, &mac_only, .cli, .linux));
    try testing.expect(installableOnHost(null, &mac_only, .cli, .darwin));
    try testing.expect(!installableOnHost(&desktop_only, null, .cli, .linux));
    try testing.expect(!installableOnHost(null, &mac_only, .cli, null));
    try testing.expect(!installableOnHost(null, &cloud_only, .cli, .linux));
    try testing.expect(visibleOnHost(null, &cloud_only, .cli, .linux));
    try testing.expect(!visibleOnHost(null, &mac_only, .cli, .linux));
    try testing.expect(!visibleOnHost(&desktop_only, &cloud_only, .cli, .linux));
}

test "loading a remote catalog refuses plain http hosts and caches availability for the catalog" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var failure: Failure = .{};

    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://plugins.example.test/plugins/marketplace", .body = sample_catalog },
    } };
    try testing.expectError(error.PluginMarketplaceUntrustedHost, load(arena, home, home, "http://plugins.example.test/plugins/marketplace", canned.fetcher(), 1, &failure));
    try testing.expectError(error.PluginMarketplaceUnreadable, load(arena, home, home, "https://plugins.example.test/missing", canned.fetcher(), 1, &failure));

    const catalog = try load(arena, home, home, "https://plugins.example.test/plugins/marketplace", canned.fetcher(), 5, &failure);
    try testing.expectEqual(@as(usize, 3), catalog.plugins.len);
    const cached = try availability.read(arena, home);
    try testing.expectEqual(@as(usize, 1), cached.sources.len);
    try testing.expectEqual(@as(usize, 3), cached.sources[0].entries.len);
}

test "a catalog install of a zip needs https and the catalog sha256, and records where it came from" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const archive = @import("archive.zig");
    const zip_bytes = try archive.buildStoredZip(arena, &.{
        .{ .name = "kimi.plugin.json", .data = "{\"name\":\"acme\"}" },
    });
    const digest = remote.sha256Hex(zip_bytes);
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://plugins.example.test/acme.zip", .body = zip_bytes },
        .{ .url = "https://plugins.example.test/unsigned.zip", .body = zip_bytes },
    } };
    const cloud_only = [_]Platform{.cloud};
    const entries = [_]Entry{
        .{ .id = "acme", .display_name = "Acme", .source = "https://plugins.example.test/acme.zip", .sha256sum = &digest },
        .{ .id = "unsigned", .display_name = "Unsigned", .source = "https://plugins.example.test/unsigned.zip" },
        .{ .id = "plain", .display_name = "Plain", .source = "http://plugins.example.test/acme.zip", .sha256sum = &digest },
        .{ .id = "elsewhere", .display_name = "Elsewhere", .source = "https://plugins.example.test/acme.zip", .sha256sum = &digest, .platforms = &cloud_only },
    };
    const catalog: Catalog = .{ .source = "https://plugins.example.test/plugins/marketplace", .plugins = &entries };

    try testing.expectError(error.MarketplacePluginNotFound, installEntry(arena, home, catalog, "missing", 1, .{ .trusted = true, .fetcher = canned.fetcher() }));
    try testing.expectError(error.MarketplaceEntryNeedsSha256, installEntry(arena, home, catalog, "unsigned", 1, .{ .trusted = true, .fetcher = canned.fetcher() }));
    try testing.expectError(error.MarketplaceInstallNeedsZipUrl, installEntry(arena, home, catalog, "plain", 1, .{ .trusted = true, .fetcher = canned.fetcher() }));
    try testing.expectError(error.MarketplaceEntryUnsupportedHost, installEntry(arena, home, catalog, "elsewhere", 1, .{ .trusted = true, .fetcher = canned.fetcher() }));
    try testing.expectError(error.PluginTrustRequired, installEntry(arena, home, catalog, "acme", 1, .{ .fetcher = canned.fetcher() }));

    const installed = try installEntry(arena, home, catalog, "ACME", 2, .{ .trusted = true, .fetcher = canned.fetcher() });
    try testing.expectEqualStrings(store.origin_marketplace, installed.record.origin);
    try testing.expectEqualStrings("acme", installed.record.catalog_id.?);
    try testing.expect(std.mem.startsWith(u8, installed.record.marketplace_source.?, "sha256:"));
    try testing.expect(entryNeedsTrustPrompt(catalog, entries[0]));
}
