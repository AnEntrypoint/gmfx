const std = @import("std");
const sensitive_file = @import("../permissions/sensitive_file.zig");

const Allocator = std.mem.Allocator;

pub const redacted_value = "<redacted>";

const env_basename = ".env";
const env_prefix = ".env.";
const comment_marker = '#';
const assignment_marker = '=';
const line_padding = " \t\r";

pub fn isSensitiveEnvFile(path: []const u8) bool {
    if (!sensitive_file.isSensitiveFile(path)) return false;
    const name = basename(path);
    return std.ascii.eqlIgnoreCase(name, env_basename) or std.ascii.startsWithIgnoreCase(name, env_prefix);
}

pub fn redactEnvAssignmentLine(alloc: Allocator, line: []const u8) Allocator.Error![]const u8 {
    const body = std.mem.trim(u8, line, line_padding);
    if (body.len == 0 or body[0] == comment_marker) return alloc.dupe(u8, line);
    const carriage_return = if (std.mem.endsWith(u8, line, "\r")) "\r" else "";
    const assignment = std.mem.indexOfScalar(u8, line, assignment_marker) orelse
        return std.mem.concat(alloc, u8, &.{ redacted_value, carriage_return });
    const value = std.mem.trim(u8, line[assignment + 1 ..], line_padding);
    if (value.len == 0) return alloc.dupe(u8, line);
    return std.mem.concat(alloc, u8, &.{ line[0 .. assignment + 1], redacted_value, carriage_return });
}

pub fn redactEnvText(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = text;
    while (rest.len != 0) {
        const newline = std.mem.indexOfScalar(u8, rest, '\n');
        const line = rest[0 .. newline orelse rest.len];
        const shown = try redactEnvAssignmentLine(alloc, line);
        defer alloc.free(shown);
        try out.appendSlice(alloc, shown);
        if (newline) |index| {
            try out.append(alloc, '\n');
            rest = rest[index + 1 ..];
        } else {
            rest = rest[rest.len..];
        }
    }
    return out.toOwnedSlice(alloc);
}

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    return path[start..end];
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn expectRedacted(expected: []const u8, line: []const u8) !void {
    const shown = try redactEnvAssignmentLine(std.testing.allocator, line);
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings(expected, shown);
}

test "redactEnvAssignmentLine hides every assigned value and keeps the key" {
    try expectRedacted("API_KEY=<redacted>", "API_KEY=sk-live-123");
    try expectRedacted("export TOKEN=<redacted>", "export TOKEN=\"abc def\"");
    try expectRedacted("  URL=<redacted>", "  URL=postgres://u:p@host/db?x=1");
    try expectRedacted("KEY=<redacted>\r", "KEY=value\r");
}

test "redactEnvAssignmentLine keeps blank lines, comments and empty assignments" {
    try expectRedacted("", "");
    try expectRedacted("   ", "   ");
    try expectRedacted("# database settings", "# database settings");
    try expectRedacted("EMPTY=", "EMPTY=");
    try expectRedacted("EMPTY=  \r", "EMPTY=  \r");
}

test "redactEnvAssignmentLine hides lines that carry no assignment" {
    try expectRedacted("<redacted>", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC");
    try expectRedacted("<redacted>\r", "continued-secret\"\r");
}

test "redactEnvText redacts each line and preserves line endings" {
    const shown = try redactEnvText(std.testing.allocator, "# top\nA=1\n\nB=two words\n");
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("# top\nA=<redacted>\n\nB=<redacted>\n", shown);

    const unterminated = try redactEnvText(std.testing.allocator, "A=1\nB=2");
    defer std.testing.allocator.free(unterminated);
    try std.testing.expectEqualStrings("A=<redacted>\nB=<redacted>", unterminated);
}

test "isSensitiveEnvFile covers env files and leaves templates and keys alone" {
    try std.testing.expect(isSensitiveEnvFile("/work/.env"));
    try std.testing.expect(isSensitiveEnvFile("/work/.ENV.local"));
    try std.testing.expect(isSensitiveEnvFile(".env.production"));
    try std.testing.expect(!isSensitiveEnvFile("/work/.env.example"));
    try std.testing.expect(!isSensitiveEnvFile("/home/me/.ssh/id_rsa"));
    try std.testing.expect(!isSensitiveEnvFile("/work/src/env.zig"));
}
