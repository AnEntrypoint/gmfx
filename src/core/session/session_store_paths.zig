const std = @import("std");
const session_layout = @import("session_layout.zig");

const Allocator = std.mem.Allocator;

pub fn validateSessionId(session_id: []const u8) !void {
    return session_layout.validateSessionId(session_id);
}

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    return session_layout.sessionDirPath(alloc, sessions_dir, session_id);
}

pub fn generateSessionId(alloc: Allocator) ![]u8 {
    return session_layout.generateSessionId(alloc);
}

pub fn sessionJsonPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    const session_dir = try sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    return std.Io.Dir.path.join(alloc, &.{ session_dir, "session.json" });
}

pub fn normalizeWorkspaceRoot(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and workspace_root[end - 1] == '/') {
        end -= 1;
    }
    return workspace_root[0..end];
}

pub fn validateWorkspaceRoot(workspace_root: []const u8) error{InvalidDurableField}!void {
    if (workspace_root.len == 0 or
        workspace_root.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(workspace_root) or
        !std.Io.Dir.path.isAbsolute(workspace_root))
    {
        return error.InvalidDurableField;
    }
}
