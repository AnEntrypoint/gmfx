const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

const trust_dir_name = "workspace-trust";
const workdir_key_prefix = "wd_";
const workdir_slug_max = 40;
const workdir_hash_len = 12;
const default_slug = "workspace";
const max_record_bytes: usize = 64 * 1024;
const trust_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const trust_record_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const Gate = struct {
    require_trust: bool,
    persisted: bool,

    pub fn grantsAll(self: Gate) bool {
        return !self.require_trust or self.persisted;
    }
};

pub const PromptChoice = enum { trust, distrust };

pub const PromptOutcome = enum { continue_session, exit_program };

const Record = struct {
    root: []const u8,
    trustedAt: i64,
};

pub fn gate(alloc: Allocator, home: ?[]const u8, workspace_root: []const u8) !Gate {
    const dir = home orelse return .{ .require_trust = true, .persisted = false };
    var settings = config_runtime.loadMergedSettingsFromHome(alloc, dir, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .require_trust = true,
            .persisted = persisted(alloc, dir, workspace_root) catch false,
        },
    };
    defer settings.deinit(alloc);
    return .{
        .require_trust = settings.kimi.workspace_require_trust orelse true,
        .persisted = try persisted(alloc, dir, workspace_root),
    };
}

pub fn promptRequired(current: Gate, env_trusted: bool) bool {
    return !current.grantsAll() and !env_trusted;
}

pub fn applyPromptChoice(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    choice: PromptChoice,
    trusted_at: i64,
) PromptOutcome {
    switch (choice) {
        .distrust => return .exit_program,
        .trust => {
            const dir = home orelse return .continue_session;
            grant(alloc, dir, workspace_root, trusted_at) catch |err| {
                debug_trace.logf("mcp", "workspace trust record not written err={s}", .{@errorName(err)});
            };
            return .continue_session;
        },
    }
}

pub fn persisted(alloc: Allocator, home: []const u8, workspace_root: []const u8) !bool {
    const path = try recordPath(alloc, home, workspace_root);
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(max_record_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    return true;
}

pub fn grant(alloc: Allocator, home: []const u8, workspace_root: []const u8, trusted_at: i64) !void {
    const dir_path = try trustDirPath(alloc, home);
    defer alloc.free(dir_path);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), dir_path, trust_dir_permissions);
    const path = try recordPath(alloc, home, workspace_root);
    defer alloc.free(path);
    const bytes = try std.json.Stringify.valueAlloc(alloc, Record{ .root = workspace_root, .trustedAt = trusted_at }, .{});
    defer alloc.free(bytes);
    try writePrivateRecord(alloc, path, bytes);
}

fn writePrivateRecord(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    io_mod.e2eFailIfDurableMutationAttempted();
    const io = io_mod.getIo();
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ path, io_mod.milliTimestamp() });
    defer alloc.free(temp_path);
    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
    {
        var file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true, .permissions = trust_record_permissions });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try std.Io.Dir.renameAbsolute(temp_path, path, io);
    cleanup_temp = false;
}

pub fn revoke(alloc: Allocator, home: []const u8, workspace_root: []const u8) !void {
    const path = try recordPath(alloc, home, workspace_root);
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn trustDirPath(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{trust_dir_name});
}

fn recordPath(alloc: Allocator, home: []const u8, workspace_root: []const u8) ![]u8 {
    const dir_path = try trustDirPath(alloc, home);
    defer alloc.free(dir_path);
    const canonical = try canonicalRoot(alloc, workspace_root);
    defer alloc.free(canonical);
    const key = try recordKey(alloc, canonical);
    defer alloc.free(key);
    return std.Io.Dir.path.join(alloc, &.{ dir_path, key });
}

pub fn canonicalRoot(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    const slashed = try std.mem.replaceOwned(u8, alloc, workspace_root, "\\", "/");
    defer alloc.free(slashed);
    const trimmed = std.mem.trimEnd(u8, slashed, "/");
    if (trimmed.len == 0) return alloc.dupe(u8, "/");
    if (isWindowsShaped(slashed)) {
        const lower = try alloc.dupe(u8, trimmed);
        for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
        return lower;
    }
    return alloc.dupe(u8, trimmed);
}

fn isWindowsShaped(slashed: []const u8) bool {
    if (std.mem.startsWith(u8, slashed, "//")) return true;
    return slashed.len >= 3 and std.ascii.isAlphabetic(slashed[0]) and slashed[1] == ':' and slashed[2] == '/';
}

pub fn recordKey(alloc: Allocator, canonical: []const u8) ![]u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, canonical, '/')) |index| canonical[index + 1 ..] else canonical;
    const slug = try slugify(alloc, base);
    defer alloc.free(slug);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "{s}{s}_{s}", .{ workdir_key_prefix, slug, hex[0..workdir_hash_len] });
}

fn slugify(alloc: Allocator, name: []const u8) ![]u8 {
    var replaced: std.ArrayList(u8) = .empty;
    defer replaced.deinit(alloc);
    var in_run = false;
    for (name) |raw| {
        const byte = std.ascii.toLower(raw);
        if (isSlugByte(byte)) {
            in_run = false;
            try replaced.append(alloc, byte);
        } else if (!in_run) {
            in_run = true;
            try replaced.append(alloc, '-');
        }
    }
    const trimmed = std.mem.trim(u8, replaced.items, "-");
    const cut = trimmed[0..@min(trimmed.len, workdir_slug_max)];
    const slug = std.mem.trim(u8, cut, "-");
    if (slug.len == 0 or std.mem.eql(u8, slug, ".") or std.mem.eql(u8, slug, "..")) {
        return alloc.dupe(u8, default_slug);
    }
    return alloc.dupe(u8, slug);
}

fn isSlugByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
}

test "workspace trust key follows Kimi's workdir key" {
    const alloc = std.testing.allocator;
    const key = try recordKey(alloc, "/tmp/fx-trust/My Repo.v2");
    defer alloc.free(key);
    try std.testing.expectEqualStrings("wd_my-repo.v2_025b57c46df3", key);
}

test "workspace trust key trims trailing separators and falls back to workspace" {
    const alloc = std.testing.allocator;
    const root = try canonicalRoot(alloc, "/tmp/fx-trust/repo///");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fx-trust/repo", root);
    const dots = try slugify(alloc, "..");
    defer alloc.free(dots);
    try std.testing.expectEqualStrings("workspace", dots);
}

test "workspace trust grant writes Kimi's record shape and revoke removes it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(root);

    try std.testing.expect(!try persisted(alloc, home, root));
    try grant(alloc, home, root, 1234);
    try std.testing.expect(try persisted(alloc, home, root));

    const path = try recordPath(alloc, home, root);
    defer alloc.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(max_record_bytes));
    defer alloc.free(bytes);
    const expected = try std.fmt.allocPrint(alloc, "{{\"root\":\"{s}\",\"trustedAt\":1234}}", .{root});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);

    try revoke(alloc, home, root);
    try std.testing.expect(!try persisted(alloc, home, root));
    try revoke(alloc, home, root);
}

test "the trust record is 0600 and its directory 0700" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(root);

    try grant(alloc, home, root, 1);
    const dir_path = try trustDirPath(alloc, home);
    defer alloc.free(dir_path);
    const dir_stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), dir_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    const path = try recordPath(alloc, home, root);
    defer alloc.free(path);
    const file_stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
}

test "a corrupt workspace trust record is an error, not trust" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(root);

    try grant(alloc, home, root, 1);
    const path = try recordPath(alloc, home, root);
    defer alloc.free(path);
    try io_mod.writeFileAtomic(alloc, path, "{not json");
    try std.testing.expect(std.meta.isError(persisted(alloc, home, root)));
}

test "the trust prompt trusts and continues, and declining exits without a record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(root);

    try std.testing.expectEqual(PromptOutcome.exit_program, applyPromptChoice(alloc, home, root, .distrust, 5));
    try std.testing.expect(!try persisted(alloc, home, root));

    try std.testing.expectEqual(PromptOutcome.continue_session, applyPromptChoice(alloc, home, root, .trust, 5));
    try std.testing.expect(try persisted(alloc, home, root));
}

test "the trust prompt is needed only without require_trust off, persisted trust or the trust env" {
    try std.testing.expect(promptRequired(.{ .require_trust = true, .persisted = false }, false));
    try std.testing.expect(!promptRequired(.{ .require_trust = true, .persisted = true }, false));
    try std.testing.expect(!promptRequired(.{ .require_trust = true, .persisted = false }, true));
    try std.testing.expect(!promptRequired(.{ .require_trust = false, .persisted = false }, false));
}

test "the trust gate reads require_trust from the profile settings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(root);

    const unset = try gate(alloc, home, root);
    try std.testing.expect(unset.require_trust);
    try std.testing.expect(!unset.grantsAll());

    var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/settings.json", .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "{\"workspace\":{\"require_trust\":false}}");
    const relaxed = try gate(alloc, home, root);
    try std.testing.expect(!relaxed.require_trust);
    try std.testing.expect(relaxed.grantsAll());
}
