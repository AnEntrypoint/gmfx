const std = @import("std");

const Allocator = std.mem.Allocator;

pub const RefKind = enum { branch, tag, sha };

pub const GithubRef = struct {
    kind: RefKind,
    value: []const u8,
};

pub const Github = struct {
    owner: []const u8,
    repo: []const u8,
    ref: ?GithubRef = null,
};

pub const Source = union(enum) {
    local_path: []const u8,
    zip_url: []const u8,
    github: Github,
};

pub fn resolve(arena: Allocator, raw: []const u8) !Source {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (try parseGithub(arena, trimmed)) |github| return .{ .github = github };
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return .{ .zip_url = trimmed };
    }
    if (!std.Io.Dir.path.isAbsolute(trimmed)) return error.RelativePluginSource;
    return .{ .local_path = trimmed };
}

fn parseGithub(arena: Allocator, raw: []const u8) !?Github {
    const https = "https://";
    if (!std.mem.startsWith(u8, raw, https)) return null;
    const after_scheme = raw[https.len..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    if (!std.mem.eql(u8, host, "github.com") and !std.mem.eql(u8, host, "www.github.com")) return null;

    const path_end = std.mem.indexOfAny(u8, after_scheme, "?#") orelse after_scheme.len;
    const path = after_scheme[host_end..path_end];

    var segments_list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len > 0) try segments_list.append(arena, part);
    }
    const segments = segments_list.items;
    if (segments.len < 2) return null;

    const owner = segments[0];
    const repo_raw = segments[1];
    const repo = if (std.mem.endsWith(u8, repo_raw, ".git")) repo_raw[0 .. repo_raw.len - ".git".len] else repo_raw;
    const rest = segments[2..];
    if (rest.len == 0) return Github{ .owner = owner, .repo = repo };

    const head = rest[0];
    if (std.mem.eql(u8, head, "tree") and rest.len >= 2) {
        const value = try decodeJoin(arena, rest[1..]);
        const kind: RefKind = if (isShaLike(value)) .sha else .branch;
        return Github{ .owner = owner, .repo = repo, .ref = .{ .kind = kind, .value = value } };
    }
    if (std.mem.eql(u8, head, "releases") and rest.len >= 3 and std.mem.eql(u8, rest[1], "tag")) {
        const value = try decodeJoin(arena, rest[2..]);
        return Github{ .owner = owner, .repo = repo, .ref = .{ .kind = .tag, .value = value } };
    }
    if (std.mem.eql(u8, head, "commit") and rest.len >= 2) {
        const value = try decodeJoin(arena, rest[1..]);
        return Github{ .owner = owner, .repo = repo, .ref = .{ .kind = .sha, .value = value } };
    }
    return null;
}

fn decodeJoin(arena: Allocator, segments: []const []const u8) ![]const u8 {
    var decoded: std.ArrayList([]const u8) = .empty;
    for (segments) |segment| {
        try decoded.append(arena, try percentDecode(arena, segment));
    }
    return std.mem.join(arena, "/", decoded.items);
}

fn percentDecode(arena: Allocator, segment: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < segment.len) {
        if (segment[index] == '%' and index + 2 < segment.len) {
            if (std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16)) |byte| {
                try out.append(arena, byte);
                index += 3;
                continue;
            } else |_| {}
        }
        try out.append(arena, segment[index]);
        index += 1;
    }
    return out.toOwnedSlice(arena);
}

fn isShaLike(value: []const u8) bool {
    if (value.len < 7 or value.len > 40) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

test "source resolves github repo, tree, tag, commit and sha forms" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = try resolve(arena, "https://github.com/acme/tools.git");
    try std.testing.expectEqualStrings("acme", bare.github.owner);
    try std.testing.expectEqualStrings("tools", bare.github.repo);
    try std.testing.expect(bare.github.ref == null);

    const branch = try resolve(arena, "https://github.com/acme/tools/tree/main");
    try std.testing.expectEqual(RefKind.branch, branch.github.ref.?.kind);
    try std.testing.expectEqualStrings("main", branch.github.ref.?.value);

    const nested = try resolve(arena, "https://www.github.com/acme/tools/tree/release/v2");
    try std.testing.expectEqualStrings("release/v2", nested.github.ref.?.value);

    const tag = try resolve(arena, "https://github.com/acme/tools/releases/tag/v1.2.0");
    try std.testing.expectEqual(RefKind.tag, tag.github.ref.?.kind);
    try std.testing.expectEqualStrings("v1.2.0", tag.github.ref.?.value);

    const commit = try resolve(arena, "https://github.com/acme/tools/commit/abcdef1234");
    try std.testing.expectEqual(RefKind.sha, commit.github.ref.?.kind);

    const tree_sha = try resolve(arena, "https://github.com/acme/tools/tree/0123456789");
    try std.testing.expectEqual(RefKind.sha, tree_sha.github.ref.?.kind);
}

test "source decodes percent-encoded ref segments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const encoded = try resolve(arena, "https://github.com/acme/tools/tree/feature%2Fnew%20ui");
    try std.testing.expectEqualStrings("feature/new ui", encoded.github.ref.?.value);
}

test "source keeps other https urls as zip URLs and rejects relative local paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zip = try resolve(arena, "https://example.test/plugins/p.zip");
    try std.testing.expectEqualStrings("https://example.test/plugins/p.zip", zip.zip_url);

    const unmatched = try resolve(arena, "https://github.com/acme/tools/blob/main/README.md");
    try std.testing.expectEqualStrings("https://github.com/acme/tools/blob/main/README.md", unmatched.zip_url);

    const local = try resolve(arena, "  /srv/plugins/acme  ");
    try std.testing.expectEqualStrings("/srv/plugins/acme", local.local_path);

    try std.testing.expectError(error.RelativePluginSource, resolve(arena, "relative/path"));
}
