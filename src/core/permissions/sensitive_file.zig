const std = @import("std");

const sensitive_basenames = [_][]const u8{ ".env", "id_rsa", "id_ed25519", "id_ecdsa", "credentials" };
const env_exemptions = [_][]const u8{ ".env.example", ".env.sample", ".env.template" };
const public_key_basenames = [_][]const u8{ "id_rsa.pub", "id_ed25519.pub", "id_ecdsa.pub" };
const sensitive_basename_prefixes = [_][]const u8{ "id_rsa", "id_ed25519", "id_ecdsa", "credentials" };
const dot_variant_suffixes = [_][]const u8{ ".bak", ".backup", ".copy", ".disabled", ".key", ".old", ".orig", ".pem", ".save", ".tmp" };
const sensitive_directory_pairs = [_][2][]const u8{ .{ ".aws", "credentials" }, .{ ".gcp", "credentials" } };
const env_prefix = ".env.";
const git_control_directory = ".git";
const path_separators = "/\\";

pub fn isSensitiveFile(path: []const u8) bool {
    const name = basename(path);
    if (listed(&env_exemptions, name)) return false;
    if (listed(&public_key_basenames, name)) return false;
    if (listed(&sensitive_basenames, name)) return true;
    if (std.ascii.startsWithIgnoreCase(name, env_prefix)) return true;
    for (sensitive_basename_prefixes) |prefix| {
        if (name.len <= prefix.len or !std.ascii.startsWithIgnoreCase(name, prefix)) continue;
        const suffix = name[prefix.len..];
        if (suffix[0] == '-' or suffix[0] == '_') return true;
        if (suffix[0] == '.' and listed(&dot_variant_suffixes, suffix)) return true;
    }
    for (sensitive_directory_pairs) |pair| {
        if (hasDirectoryPair(path, pair)) return true;
    }
    return false;
}

pub fn isGitControlPath(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, path_separators);
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, git_control_directory)) return true;
    }
    return false;
}

fn listed(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    return path[start..end];
}

fn hasDirectoryPair(path: []const u8, pair: [2][]const u8) bool {
    var previous: ?[]const u8 = null;
    var parts = std.mem.tokenizeAny(u8, path, path_separators);
    while (parts.next()) |part| {
        if (previous) |parent| {
            if (std.ascii.eqlIgnoreCase(parent, pair[0]) and std.ascii.eqlIgnoreCase(part, pair[1])) return true;
        }
        previous = part;
    }
    return false;
}

test "sensitive file names follow the Kimi list" {
    const sensitive = [_][]const u8{
        "/work/.env",
        "/work/.ENV",
        "/work/.env.local",
        "/work/.env.production",
        "/home/me/.ssh/id_rsa",
        "/home/me/.ssh/id_ed25519",
        "/home/me/.ssh/id_ecdsa",
        "/home/me/.ssh/id_rsa.bak",
        "/home/me/.ssh/id_rsa.pem",
        "/home/me/.ssh/id_rsa-work",
        "/home/me/.ssh/id_ed25519_github",
        "/home/me/.aws/credentials",
        "/home/me/.aws/credentials/profile",
        "/home/me/.gcp/credentials/key.json",
        "/work/credentials",
        "/work/credentials.old",
        "C:\\Users\\me\\.ssh\\id_rsa",
        ".env",
    };
    for (sensitive) |path| try std.testing.expect(isSensitiveFile(path));
}

test "sensitive file check leaves templates, public keys and look-alikes alone" {
    const ordinary = [_][]const u8{
        "/work/.env.example",
        "/work/.env.sample",
        "/work/.env.template",
        "/home/me/.ssh/id_rsa.pub",
        "/home/me/.ssh/id_ed25519.pub",
        "/home/me/.ssh/id_ecdsa.pub",
        "/work/src/main.zig",
        "/work/.envrc",
        "/work/env",
        "/work/credentials.json",
        "/work/credentialsfile",
        "/work/id_rsa.txt",
        "/work/aws/credentials.md",
        "",
    };
    for (ordinary) |path| try std.testing.expect(!isSensitiveFile(path));
}

test "git control paths are any path under a .git component" {
    const control = [_][]const u8{
        "/work/.git/config",
        "/work/.git/hooks/pre-commit",
        "/work/.git/index",
        "/work/.GIT/HEAD",
        "/work/sub/.git",
        "C:\\work\\.git\\config",
    };
    for (control) |path| try std.testing.expect(isGitControlPath(path));
    const ordinary = [_][]const u8{
        "/work/.gitignore",
        "/work/.github/workflows/ci.yml",
        "/work/git/config",
        "/work/src/git.zig",
        "",
    };
    for (ordinary) |path| try std.testing.expect(!isGitControlPath(path));
}
