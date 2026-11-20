pub const Host = struct {
    context: *anyopaque,
    allow: *const fn (context: *anyopaque, server: []const u8, tool: []const u8, arguments: ?[]const u8) bool,
    log: *const fn (context: *anyopaque, server: []const u8, line: []const u8) void,
};
