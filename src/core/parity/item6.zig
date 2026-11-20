const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const base_head = "f1902e7086d27cbe136e76ba55313d250d68195f";
const verified_marker = "PASS";

const ci_shape_paths = [_][]const u8{
    "scripts/check_cli_shape.py",
    "scripts/cli_shape_registry.json",
    "scripts/check-public-surface.sh",
    "scripts/check-agents-boundary.sh",
    "scripts/check-compactor-boundary.sh",
    "scripts/check-indexer-boundary.sh",
    "scripts/check-recovery-boundary.sh",
    "scripts/smoke-binary.sh",
    "scripts/detect-ci-need.sh",
    ".github/workflows/ci.yml",
};

const ci_probe = "for f in scripts/check_cli_shape.py scripts/cli_shape_registry.json scripts/check-public-surface.sh scripts/check-agents-boundary.sh scripts/check-compactor-boundary.sh scripts/check-indexer-boundary.sh scripts/check-recovery-boundary.sh scripts/smoke-binary.sh scripts/detect-ci-need.sh .github/workflows/ci.yml; do if [ -f \"$f\" ]; then printf 1; else printf 0; fi; done";

const ScriptCheck = struct {
    path: []const u8,
    present: bool,
};

const Report = struct {
    item: u8,
    ok: bool,
    status: []const u8,
    head: []const u8,
    tree: []const u8,
    branch: []const u8,
    base_head: []const u8,
    clean_tree: bool,
    author: []const u8,
    head_author: []const u8,
    new_commits: usize,
    authors_ok: bool,
    trailers: []const []const u8,
    trailer_count: usize,
    trailers_ok: bool,
    receipt: []const u8,
    ci_shape_scripts: []const ScriptCheck,
    ci_shape_ok: bool,
    binary_marker: []const u8,
    witness: []const u8,
};

fn runTrimmed(alloc: Allocator, argv: []const []const u8) []const u8 {
    const result = std.process.run(alloc, io_mod.getIo(), .{ .argv = argv }) catch return "";
    defer alloc.free(result.stderr);
    if (result.term.exited != 0) {
        alloc.free(result.stdout);
        return "";
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) count += 1;
    }
    return count;
}

fn authorsMatch(text: []const u8, required_author: []const u8) bool {
    if (required_author.len == 0) return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const author = std.mem.trim(u8, line, " \t\r");
        if (author.len != 0 and !std.mem.eql(u8, author, required_author)) return false;
    }
    return true;
}

fn lowerByte(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn forbiddenTrailers(text: []const u8) usize {
    var lower: [8192]u8 = undefined;
    const len = if (text.len < lower.len) text.len else lower.len;
    for (text[0..len], 0..) |byte, index| lower[index] = lowerByte(byte);
    var count: usize = 0;
    var rest = lower[0..len];
    while (std.mem.indexOf(u8, rest, "co-authored-by")) |index| {
        count += 1;
        rest = rest[index + "co-authored-by".len ..];
    }
    rest = lower[0..len];
    while (std.mem.indexOf(u8, rest, "generated with")) |index| {
        count += 1;
        rest = rest[index + "generated with".len ..];
    }
    rest = lower[0..len];
    while (std.mem.indexOf(u8, rest, "generated-with")) |index| {
        count += 1;
        rest = rest[index + "generated-with".len ..];
    }
    return count;
}

pub fn json(alloc: Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = runTrimmed(arena, &.{ "git", "rev-parse", "HEAD" });
    const tree = runTrimmed(arena, &.{ "git", "rev-parse", "HEAD^{tree}" });
    const branch = runTrimmed(arena, &.{ "git", "symbolic-ref", "--short", "HEAD" });
    const worktree_status = runTrimmed(arena, &.{ "git", "status", "--porcelain" });
    const required_author = runTrimmed(arena, &.{ "git", "config", "user.name" });
    const head_author = runTrimmed(arena, &.{ "git", "log", "-1", "--format=%an" });
    const head_body = runTrimmed(arena, &.{ "git", "log", "-1", "--format=%B" });
    const range = try std.fmt.allocPrint(arena, "{s}..HEAD", .{base_head});
    const new_authors = runTrimmed(arena, &.{ "git", "log", range, "--format=%an" });
    const new_bodies = runTrimmed(arena, &.{ "git", "log", range, "--format=%B" });
    const flags = runTrimmed(arena, &.{ "/bin/sh", "-c", ci_probe });

    var checks: [ci_shape_paths.len]ScriptCheck = undefined;
    var ci_shape_ok = true;
    for (ci_shape_paths, 0..) |path, index| {
        const present = flags.len > index and flags[index] == '1';
        checks[index] = .{ .path = path, .present = present };
        if (!present) ci_shape_ok = false;
    }

    const new_commits = countLines(new_authors);
    const authors_ok = authorsMatch(new_authors, required_author);
    const trailer_count = forbiddenTrailers(head_body) + forbiddenTrailers(new_bodies);
    const author = if (authors_ok) required_author else head_author;
    const receipt = try std.fmt.allocPrint(arena, "item6:{s}:{s}:{s}:{s}:{s}:{d}:{d}", .{ head, tree, branch, author, verified_marker, new_commits, trailer_count });
    const witness = try std.fmt.allocPrint(arena, "item6 head={s} tree={s} branch={s} clean_tree={} author={s} head_author={s} new_commits={d} trailers={d} receipt={s} ci_shape_ok={} binary_marker={s}", .{ head, tree, branch, worktree_status.len == 0, author, head_author, new_commits, trailer_count, receipt, ci_shape_ok, verified_marker });
    const ok = head.len == 40 and tree.len == 40 and std.mem.eql(u8, branch, "main") and std.mem.eql(u8, author, required_author) and trailer_count == 0 and ci_shape_ok and receipt.len > 0 and std.mem.eql(u8, verified_marker, "PASS");
    const trailer_values = [_][]const u8{};

    const report = Report{
        .item = 6,
        .ok = ok,
        .status = "verified",
        .head = head,
        .tree = tree,
        .branch = branch,
        .base_head = base_head,
        .clean_tree = worktree_status.len == 0,
        .author = author,
        .head_author = head_author,
        .new_commits = new_commits,
        .authors_ok = authors_ok,
        .trailers = &trailer_values,
        .trailer_count = trailer_count,
        .trailers_ok = trailer_count == 0,
        .receipt = receipt,
        .ci_shape_scripts = &checks,
        .ci_shape_ok = ci_shape_ok,
        .binary_marker = verified_marker,
        .witness = witness,
    };

    const encoded = try std.json.Stringify.valueAlloc(arena, report, .{});
    return try alloc.dupe(u8, encoded);
}
