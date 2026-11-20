const std = @import("std");
const io_mod = @import("../shared/io.zig");
const archive = @import("archive.zig");
const sources = @import("source.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const cwd = std.Io.Dir.cwd;

pub const user_agent = "fx-plugins";
const scratch_dir_name = "tmp";
const commit_marker = "Grit::Commit/";
const commit_sha_len = 40;

pub const Error = error{
    PluginDownloadFailed,
    PluginChecksumMismatch,
    PluginCommitUnresolved,
    UnsupportedPluginSource,
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const Fetcher = struct {
    context: ?*anyopaque = null,
    get: *const fn (context: ?*anyopaque, arena: Allocator, url: []const u8) anyerror!Response,

    pub fn fetch(self: Fetcher, arena: Allocator, url: []const u8) anyerror!Response {
        return self.get(self.context, arena, url);
    }
};

pub const live: Fetcher = .{ .get = liveGet };

fn liveGet(_: ?*anyopaque, arena: Allocator, url: []const u8) anyerror!Response {
    var client: std.http.Client = .{ .allocator = arena, .io = io_mod.getIo() };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = user_agent },
            .accept_encoding = .omit,
        },
        .response_writer = &body.writer,
    });
    return .{ .status = result.status, .body = body.written() };
}

pub const GithubResolution = struct {
    zip_url: []const u8,
    ref: sources.GithubRef,
};

pub const Fetched = struct {
    root: []const u8,
    scratch_dir: []const u8,
    github: ?store.GithubInstall = null,
};

pub fn fetchPlugin(
    arena: Allocator,
    home: []const u8,
    source: sources.Source,
    now_ms: i64,
    fetcher: Fetcher,
    expected_sha256: ?[]const u8,
) !Fetched {
    var github: ?store.GithubInstall = null;
    const zip_url = switch (source) {
        .local_path => return error.UnsupportedPluginSource,
        .zip_url => |url| url,
        .github => |repo| blk: {
            const resolution = try resolveGithub(arena, fetcher, repo);
            const installed_sha = installedCommitSha(arena, fetcher, repo.owner, repo.repo, resolution.ref) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            github = .{
                .owner = repo.owner,
                .repo = repo.repo,
                .ref_kind = @tagName(resolution.ref.kind),
                .ref_value = resolution.ref.value,
                .installed_sha = installed_sha,
            };
            if (installed_sha) |sha| break :blk try std.fmt.allocPrint(arena, "https://codeload.github.com/{s}/{s}/zip/{s}", .{ repo.owner, repo.repo, sha });
            break :blk resolution.zip_url;
        },
    };

    const response = fetcher.fetch(arena, zip_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PluginDownloadFailed,
    };
    if (response.status != .ok) return error.PluginDownloadFailed;
    if (expected_sha256) |expected| {
        const actual = sha256Hex(response.body);
        if (!std.ascii.eqlIgnoreCase(expected, &actual)) return error.PluginChecksumMismatch;
    }

    const io = io_mod.getIo();
    const store_dir = try store.storeDir(arena, home);
    const scratch_dir = try std.fmt.allocPrint(arena, "{s}/{s}/fetch-{d}", .{ store_dir, scratch_dir_name, now_ms });
    cwd().deleteTree(io, scratch_dir) catch {};
    try cwd().createDirPath(io, scratch_dir);
    errdefer cwd().deleteTree(io, scratch_dir) catch {};
    const zip_path = try std.Io.Dir.path.join(arena, &.{ scratch_dir, "plugin.zip" });
    try cwd().writeFile(io, .{ .sub_path = zip_path, .data = response.body });
    const tree_dir = try std.Io.Dir.path.join(arena, &.{ scratch_dir, "tree" });
    const root = try archive.extractZipFile(arena, zip_path, tree_dir);
    return .{ .root = root, .scratch_dir = scratch_dir, .github = github };
}

pub fn sha256Hex(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn resolveGithub(arena: Allocator, fetcher: Fetcher, repo: sources.Github) !GithubResolution {
    if (repo.ref) |ref| return .{ .zip_url = try codeloadUrl(arena, repo.owner, repo.repo, ref), .ref = ref };
    if (try latestReleaseTag(arena, fetcher, repo.owner, repo.repo)) |tag| {
        const ref: sources.GithubRef = .{ .kind = .tag, .value = tag };
        return .{ .zip_url = try codeloadUrl(arena, repo.owner, repo.repo, ref), .ref = ref };
    }
    return .{
        .zip_url = try std.fmt.allocPrint(arena, "https://codeload.github.com/{s}/{s}/zip/HEAD", .{ repo.owner, repo.repo }),
        .ref = .{ .kind = .branch, .value = "HEAD" },
    };
}

const LatestRelease = struct {
    tag_name: ?[]const u8 = null,
};

pub fn latestReleaseTag(arena: Allocator, fetcher: Fetcher, owner: []const u8, repo: []const u8) !?[]const u8 {
    const url = try std.fmt.allocPrint(arena, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ owner, repo });
    const response = fetcher.fetch(arena, url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (response.status != .ok) return null;
    const release = std.json.parseFromSliceLeaky(LatestRelease, arena, response.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const tag = std.mem.trim(u8, release.tag_name orelse return null, " \t\r\n");
    return if (tag.len == 0) null else tag;
}

pub fn installedCommitSha(arena: Allocator, fetcher: Fetcher, owner: []const u8, repo: []const u8, ref: sources.GithubRef) !?[]const u8 {
    if (ref.kind == .sha and ref.value.len == commit_sha_len) return try std.ascii.allocLowerString(arena, ref.value);
    return try commitSha(arena, fetcher, owner, repo, ref.value);
}

pub fn commitSha(arena: Allocator, fetcher: Fetcher, owner: []const u8, repo: []const u8, ref: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "https://github.com/{s}/{s}/commits/{s}.atom", .{ owner, repo, try encodeRefPath(arena, ref) });
    const response = fetcher.fetch(arena, url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PluginCommitUnresolved,
    };
    if (response.status != .ok) return error.PluginCommitUnresolved;
    const at = std.mem.find(u8, response.body, commit_marker) orelse return error.PluginCommitUnresolved;
    const start = at + commit_marker.len;
    if (start + commit_sha_len > response.body.len) return error.PluginCommitUnresolved;
    const candidate = response.body[start .. start + commit_sha_len];
    for (candidate) |byte| {
        if (!std.ascii.isHex(byte)) return error.PluginCommitUnresolved;
    }
    return std.ascii.allocLowerString(arena, candidate);
}

pub fn codeloadUrl(arena: Allocator, owner: []const u8, repo: []const u8, ref: sources.GithubRef) ![]const u8 {
    const encoded = try encodeRefPath(arena, ref.value);
    return switch (ref.kind) {
        .tag => std.fmt.allocPrint(arena, "https://codeload.github.com/{s}/{s}/zip/refs/tags/{s}", .{ owner, repo, encoded }),
        .sha, .branch => std.fmt.allocPrint(arena, "https://codeload.github.com/{s}/{s}/zip/{s}", .{ owner, repo, encoded }),
    };
}

fn encodeRefPath(arena: Allocator, ref: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ref) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(arena, byte);
        } else {
            try out.appendSlice(arena, try std.fmt.allocPrint(arena, "%{X:0>2}", .{byte}));
        }
    }
    return out.toOwnedSlice(arena);
}

pub const CannedReply = struct {
    url: []const u8,
    status: std.http.Status = .ok,
    body: []const u8 = "",
};

pub const CannedFetcher = struct {
    replies: []const CannedReply,
    requested: std.ArrayList([]const u8) = .empty,

    pub fn fetcher(self: *CannedFetcher) Fetcher {
        return .{ .context = self, .get = cannedGet };
    }

    fn cannedGet(context: ?*anyopaque, arena: Allocator, url: []const u8) anyerror!Response {
        const self: *CannedFetcher = @ptrCast(@alignCast(context orelse return error.CannedFetcherMissing));
        try self.requested.append(arena, try arena.dupe(u8, url));
        for (self.replies) |reply| {
            if (std.mem.eql(u8, reply.url, url)) return .{ .status = reply.status, .body = reply.body };
        }
        return .{ .status = .not_found, .body = "" };
    }
};

const testing = std.testing;

test "a github source without a ref installs the latest release tag and falls back to HEAD" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var with_release: CannedFetcher = .{ .replies = &.{
        .{ .url = "https://api.github.com/repos/acme/tools/releases/latest", .body = "{\"tag_name\":\"v1.2.0\",\"name\":\"x\"}" },
    } };
    const tagged = try resolveGithub(arena, with_release.fetcher(), .{ .owner = "acme", .repo = "tools" });
    try testing.expectEqual(sources.RefKind.tag, tagged.ref.kind);
    try testing.expectEqualStrings("v1.2.0", tagged.ref.value);
    try testing.expectEqualStrings("https://codeload.github.com/acme/tools/zip/refs/tags/v1.2.0", tagged.zip_url);

    var without_release: CannedFetcher = .{ .replies = &.{} };
    const head = try resolveGithub(arena, without_release.fetcher(), .{ .owner = "acme", .repo = "tools" });
    try testing.expectEqual(sources.RefKind.branch, head.ref.kind);
    try testing.expectEqualStrings("HEAD", head.ref.value);
    try testing.expectEqualStrings("https://codeload.github.com/acme/tools/zip/HEAD", head.zip_url);

    const pinned = try resolveGithub(arena, without_release.fetcher(), .{ .owner = "acme", .repo = "tools", .ref = .{ .kind = .branch, .value = "feature/new ui" } });
    try testing.expectEqualStrings("https://codeload.github.com/acme/tools/zip/feature/new%20ui", pinned.zip_url);
}

test "a commit sha is read from the commits feed and a full sha ref needs no request" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var canned: CannedFetcher = .{ .replies = &.{
        .{ .url = "https://github.com/acme/tools/commits/main.atom", .body = "<id>tag:github.com,2008:Grit::Commit/0123456789ABCDEF0123456789abcdef01234567</id>" },
        .{ .url = "https://github.com/acme/tools/commits/empty.atom", .body = "<feed></feed>" },
    } };
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", try commitSha(arena, canned.fetcher(), "acme", "tools", "main"));
    try testing.expectError(error.PluginCommitUnresolved, commitSha(arena, canned.fetcher(), "acme", "tools", "empty"));
    try testing.expectError(error.PluginCommitUnresolved, commitSha(arena, canned.fetcher(), "acme", "tools", "gone"));

    const requests_before = canned.requested.items.len;
    const full = "ABCDEF0123456789abcdef0123456789abcdef01";
    const direct = try installedCommitSha(arena, canned.fetcher(), "acme", "tools", .{ .kind = .sha, .value = full });
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", direct.?);
    try testing.expectEqual(requests_before, canned.requested.items.len);
}

test "a fetched zip is checked against the expected sha256 before anything is extracted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const zip_bytes = try archive.buildStoredZip(arena, &.{
        .{ .name = "kimi.plugin.json", .data = "{\"name\":\"zipped\"}" },
    });
    var canned: CannedFetcher = .{ .replies = &.{
        .{ .url = "https://example.test/p.zip", .body = zip_bytes },
    } };
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.PluginChecksumMismatch, fetchPlugin(arena, home, .{ .zip_url = "https://example.test/p.zip" }, 1, canned.fetcher(), wrong));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".fx/plugins/tmp/fetch-1", .{}));
    try testing.expectError(error.PluginDownloadFailed, fetchPlugin(arena, home, .{ .zip_url = "https://example.test/missing.zip" }, 2, canned.fetcher(), null));

    const right = sha256Hex(zip_bytes);
    const fetched = try fetchPlugin(arena, home, .{ .zip_url = "https://example.test/p.zip" }, 3, canned.fetcher(), &right);
    try testing.expect(std.mem.endsWith(u8, fetched.root, "/plugins/tmp/fetch-3/tree"));
    try testing.expect(fetched.github == null);
    const manifest_text = try cwd().readFileAlloc(testing.io, try std.Io.Dir.path.join(arena, &.{ fetched.root, "kimi.plugin.json" }), arena, .limited(1024));
    try testing.expectEqualStrings("{\"name\":\"zipped\"}", manifest_text);
}
