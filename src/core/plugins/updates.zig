const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const manager = @import("manager.zig");
const marketplace = @import("marketplace.zig");
const remote = @import("remote.zig");
const sources = @import("source.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;

const notice_state_file_name = "update-notices.json";
const max_notice_state_bytes: usize = 1024 * 1024;
const short_sha_len = 12;

pub const Channel = enum { github, marketplace };

pub const Status = struct {
    id: []const u8,
    channel: Channel,
    installed_version: []const u8,
    latest_version: []const u8,
    update_available: bool,
};

pub fn checkGithubRecord(arena: Allocator, fetcher: remote.Fetcher, record: store.Record) !?Status {
    const github = record.github orelse return null;
    if (!std.mem.eql(u8, record.source_kind, store.source_kind_github)) return null;
    const installed_kind = std.meta.stringToEnum(sources.RefKind, github.ref_kind) orelse return null;

    if (pinnedRef(arena, record, installed_kind)) |pinned| {
        switch (pinned.kind) {
            .tag, .sha => return .{
                .id = record.id,
                .channel = .github,
                .installed_version = github.ref_value,
                .latest_version = github.ref_value,
                .update_available = false,
            },
            .branch => {
                const latest_sha = try remote.commitSha(arena, fetcher, github.owner, github.repo, pinned.value);
                return .{
                    .id = record.id,
                    .channel = .github,
                    .installed_version = github.ref_value,
                    .latest_version = latest_sha[0..short_sha_len],
                    .update_available = !installedAt(github, latest_sha),
                };
            },
        }
    }

    const latest = try remote.resolveGithub(arena, fetcher, .{ .owner = github.owner, .repo = github.repo });
    var update_available = installed_kind != latest.ref.kind or !std.mem.eql(u8, github.ref_value, latest.ref.value);
    if (!update_available and latest.ref.kind != .sha) {
        const latest_sha = try remote.commitSha(arena, fetcher, github.owner, github.repo, latest.ref.value);
        update_available = !installedAt(github, latest_sha);
    }
    return .{
        .id = record.id,
        .channel = .github,
        .installed_version = github.ref_value,
        .latest_version = latest.ref.value,
        .update_available = update_available,
    };
}

fn installedAt(github: store.GithubInstall, sha: []const u8) bool {
    const installed_sha = github.installed_sha orelse return false;
    return std.ascii.eqlIgnoreCase(installed_sha, sha);
}

fn pinnedRef(arena: Allocator, record: store.Record, installed_kind: sources.RefKind) ?sources.GithubRef {
    const github = record.github orelse return null;
    const recorded: ?sources.GithubRef = if (installed_kind == .sha or (installed_kind == .branch and !std.mem.eql(u8, github.ref_value, "HEAD")))
        .{ .kind = installed_kind, .value = github.ref_value }
    else
        null;
    const resolved = sources.resolve(arena, record.source) catch return recorded;
    return switch (resolved) {
        .github => |repo| repo.ref,
        else => recorded,
    };
}

pub fn checkGithub(arena: Allocator, plugins: []const manager.Plugin, fetcher: remote.Fetcher) Allocator.Error![]const Status {
    var out: std.ArrayList(Status) = .empty;
    for (plugins) |plugin| {
        const status = checkGithubRecord(arena, fetcher, plugin.record) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try out.append(arena, status orelse continue);
    }
    std.mem.sort(Status, out.items, {}, lessThanById);
    return out.toOwnedSlice(arena);
}

fn lessThanById(_: void, lhs: Status, rhs: Status) bool {
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

pub fn checkMarketplace(arena: Allocator, plugins: []const manager.Plugin, catalog: marketplace.Catalog) Allocator.Error![]const Status {
    var out: std.ArrayList(Status) = .empty;
    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.record.origin, store.origin_custom)) continue;
        const entry = marketplace.findEntry(catalog, plugin.record.catalog_id orelse plugin.record.id) orelse continue;
        const latest = entry.version orelse continue;
        const loaded = plugin.manifest orelse continue;
        const installed = loaded.version orelse continue;
        try out.append(arena, .{
            .id = plugin.record.id,
            .channel = .marketplace,
            .installed_version = installed,
            .latest_version = latest,
            .update_available = isNewer(latest, installed),
        });
    }
    std.mem.sort(Status, out.items, {}, lessThanById);
    return out.toOwnedSlice(arena);
}

pub fn isNewer(latest: []const u8, installed: []const u8) bool {
    const latest_version = std.SemanticVersion.parse(latest) catch return false;
    const installed_version = std.SemanticVersion.parse(installed) catch return false;
    return latest_version.order(installed_version) == .gt;
}

pub fn noticeLine(arena: Allocator, status: Status) Allocator.Error![]const u8 {
    return switch (status.channel) {
        .github => std.fmt.allocPrint(arena, "Update detected: {s} {s} is available on GitHub (installed {s}). Run /plugins update {s} to install it.", .{ status.id, status.latest_version, status.installed_version, status.id }),
        .marketplace => std.fmt.allocPrint(arena, "Update detected: {s} {s} is available in the marketplace (installed {s}). Run /plugins update {s} to install it.", .{ status.id, status.latest_version, status.installed_version, status.id }),
    };
}

pub const Notified = struct {
    id: []const u8,
    version: []const u8,
};

pub const NoticeState = struct {
    notified: []const Notified = &.{},
};

pub fn noticeStatePath(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{ store.plugins_dir_name, notice_state_file_name });
}

pub fn readNoticeState(arena: Allocator, home: []const u8) Allocator.Error!NoticeState {
    const path = noticeStatePath(arena, home) catch return error.OutOfMemory;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_notice_state_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    return std.json.parseFromSliceLeaky(NoticeState, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => NoticeState{},
    };
}

pub fn unseenNotices(arena: Allocator, home: []const u8, statuses: []const Status) ![]const []const u8 {
    const state = try readNoticeState(arena, home);
    var remembered: std.ArrayList(Notified) = .empty;
    try remembered.appendSlice(arena, state.notified);
    var lines: std.ArrayList([]const u8) = .empty;
    for (statuses) |status| {
        if (!status.update_available) continue;
        if (alreadyNotified(remembered.items, status)) continue;
        try lines.append(arena, try noticeLine(arena, status));
        try remember(arena, &remembered, status);
    }
    if (lines.items.len > 0) try writeNoticeState(arena, home, .{ .notified = remembered.items });
    return lines.toOwnedSlice(arena);
}

fn alreadyNotified(remembered: []const Notified, status: Status) bool {
    for (remembered) |entry| {
        if (std.mem.eql(u8, entry.id, status.id)) return std.mem.eql(u8, entry.version, status.latest_version);
    }
    return false;
}

fn remember(arena: Allocator, remembered: *std.ArrayList(Notified), status: Status) Allocator.Error!void {
    for (remembered.items) |*entry| {
        if (!std.mem.eql(u8, entry.id, status.id)) continue;
        entry.version = status.latest_version;
        return;
    }
    try remembered.append(arena, .{ .id = status.id, .version = status.latest_version });
}

fn writeNoticeState(alloc: Allocator, home: []const u8, state: NoticeState) !void {
    const dir = try store.storeDir(alloc, home);
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir);
    const path = try noticeStatePath(alloc, home);
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

const testing = std.testing;

fn githubRecord(source: []const u8, ref_kind: []const u8, ref_value: []const u8, installed_sha: ?[]const u8) store.Record {
    return .{
        .id = "tools",
        .root = "/p/tools",
        .source = source,
        .source_kind = store.source_kind_github,
        .github = .{ .owner = "acme", .repo = "tools", .ref_kind = ref_kind, .ref_value = ref_value, .installed_sha = installed_sha },
    };
}

const old_sha = "1111111111111111111111111111111111111111";
const new_sha = "2222222222222222222222222222222222222222";

test "a plugin pinned to a tag or commit never reports an update" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var offline: remote.CannedFetcher = .{ .replies = &.{} };

    const tagged = (try checkGithubRecord(arena, offline.fetcher(), githubRecord("https://github.com/acme/tools/releases/tag/v1.0.0", "tag", "v1.0.0", old_sha))).?;
    try testing.expect(!tagged.update_available);
    try testing.expectEqualStrings("v1.0.0", tagged.latest_version);
    const committed = (try checkGithubRecord(arena, offline.fetcher(), githubRecord("https://github.com/acme/tools/commit/" ++ old_sha, "sha", old_sha, old_sha))).?;
    try testing.expect(!committed.update_available);
    try testing.expectEqual(@as(usize, 0), offline.requested.items.len);
}

test "a plugin pinned to a branch reports an update when the branch head moved" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://github.com/acme/tools/commits/main.atom", .body = "Grit::Commit/" ++ new_sha },
    } };
    const source = "https://github.com/acme/tools/tree/main";

    const moved = (try checkGithubRecord(arena, canned.fetcher(), githubRecord(source, "branch", "main", old_sha))).?;
    try testing.expect(moved.update_available);
    try testing.expectEqualStrings(new_sha[0..12], moved.latest_version);
    const current = (try checkGithubRecord(arena, canned.fetcher(), githubRecord(source, "branch", "main", new_sha))).?;
    try testing.expect(!current.update_available);
}

test "an unpinned plugin reports an update when a newer release tag exists or the tag moved" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://api.github.com/repos/acme/tools/releases/latest", .body = "{\"tag_name\":\"v2.0.0\"}" },
        .{ .url = "https://github.com/acme/tools/commits/v2.0.0.atom", .body = "Grit::Commit/" ++ new_sha },
    } };
    const source = "https://github.com/acme/tools";

    const behind = (try checkGithubRecord(arena, canned.fetcher(), githubRecord(source, "tag", "v1.0.0", old_sha))).?;
    try testing.expect(behind.update_available);
    try testing.expectEqualStrings("v2.0.0", behind.latest_version);
    try testing.expectEqualStrings("v1.0.0", behind.installed_version);
    const same = (try checkGithubRecord(arena, canned.fetcher(), githubRecord(source, "tag", "v2.0.0", new_sha))).?;
    try testing.expect(!same.update_available);
    const retagged = (try checkGithubRecord(arena, canned.fetcher(), githubRecord(source, "tag", "v2.0.0", old_sha))).?;
    try testing.expect(retagged.update_available);

    const local: store.Record = .{ .id = "local", .root = "/p/local", .source = "/src/local" };
    try testing.expect((try checkGithubRecord(arena, canned.fetcher(), local)) == null);
}

test "the github check skips plugins it cannot reach and sorts the rest by id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://github.com/acme/tools/commits/main.atom", .body = "Grit::Commit/" ++ new_sha },
    } };
    var reachable = githubRecord("https://github.com/acme/tools/tree/main", "branch", "main", old_sha);
    reachable.id = "zeta";
    var unreachable_record = githubRecord("https://github.com/acme/gone/tree/main", "branch", "main", old_sha);
    unreachable_record.id = "alpha";
    unreachable_record.github.?.repo = "gone";
    var pinned = githubRecord("https://github.com/acme/tools/releases/tag/v1", "tag", "v1", old_sha);
    pinned.id = "beta";
    const plugins = [_]manager.Plugin{ .{ .record = reachable }, .{ .record = unreachable_record }, .{ .record = pinned } };

    const statuses = try checkGithub(arena, &plugins, canned.fetcher());
    try testing.expectEqual(@as(usize, 2), statuses.len);
    try testing.expectEqualStrings("beta", statuses[0].id);
    try testing.expectEqualStrings("zeta", statuses[1].id);
    try testing.expect(statuses[1].update_available);
}

test "the marketplace check compares semantic versions for catalog plugins only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]marketplace.Entry{
        .{ .id = "acme", .display_name = "Acme", .source = "https://example.test/acme.zip", .version = "1.3.0" },
        .{ .id = "custom", .display_name = "Custom", .source = "https://example.test/custom.zip", .version = "9.0.0" },
    };
    const catalog: marketplace.Catalog = .{ .source = "https://example.test/catalog.json", .plugins = &entries };
    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "acme", .root = "/p/acme", .source = "https://example.test/acme.zip", .origin = store.origin_marketplace, .catalog_id = "acme" },
            .manifest = .{ .name = "acme", .id = "acme", .version = "1.2.9" },
        },
        .{
            .record = .{ .id = "custom", .root = "/p/custom", .source = "/src/custom" },
            .manifest = .{ .name = "custom", .id = "custom", .version = "1.0.0" },
        },
    };

    const statuses = try checkMarketplace(arena, &plugins, catalog);
    try testing.expectEqual(@as(usize, 1), statuses.len);
    try testing.expectEqualStrings("acme", statuses[0].id);
    try testing.expect(statuses[0].update_available);
    try testing.expect(isNewer("1.10.0", "1.9.0"));
    try testing.expect(!isNewer("1.0.0", "1.0.0"));
    try testing.expect(!isNewer("latest", "1.0.0"));
}

test "an update is announced once per version" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const statuses = [_]Status{
        .{ .id = "acme", .channel = .marketplace, .installed_version = "1.0.0", .latest_version = "1.1.0", .update_available = true },
        .{ .id = "steady", .channel = .github, .installed_version = "v1", .latest_version = "v1", .update_available = false },
    };
    const first = try unseenNotices(arena, home, &statuses);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("Update detected: acme 1.1.0 is available in the marketplace (installed 1.0.0). Run /plugins update acme to install it.", first[0]);
    try testing.expectEqual(@as(usize, 0), (try unseenNotices(arena, home, &statuses)).len);

    const newer = [_]Status{.{ .id = "acme", .channel = .marketplace, .installed_version = "1.0.0", .latest_version = "1.2.0", .update_available = true }};
    try testing.expectEqual(@as(usize, 1), (try unseenNotices(arena, home, &newer)).len);
    try testing.expectEqual(@as(usize, 1), (try readNoticeState(arena, home)).notified.len);
}
