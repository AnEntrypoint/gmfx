const std = @import("std");

const system_prompt = @embedFile("../builtins/system_prompt.md");
const working_loop_heading = "# Working loop\n";

const working_loop = section: {
    @setEvalBranchQuota(4_000_000);
    const start = std.mem.find(u8, system_prompt, working_loop_heading) orelse
        @compileError("system prompt no longer contains: " ++ working_loop_heading);
    const body = system_prompt[start..];
    const next = std.mem.find(u8, body[working_loop_heading.len..], "\n# ");
    break :section if (next) |offset| body[0 .. working_loop_heading.len + offset + 1] else body;
};

pub const Entry = struct {
    skill: []const u8,
    file: []const u8,
    text: []const u8,

    pub fn served(self: Entry) ?[]const u8 {
        return if (self.text.len > 0) self.text else null;
    }
};

pub const entries = [_]Entry{
    .{ .skill = "fx", .file = "WORKING-LOOP.md", .text = working_loop },
    .{ .skill = "fx", .file = "SYSTEM.md", .text = system_prompt },
};

pub fn find(skill: []const u8, file: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.skill, skill) and std.mem.eql(u8, entry.file, file)) return entry;
    }
    return null;
}

test "the working loop is served as the matching section of the default system prompt" {
    const entry = find("fx", "WORKING-LOOP.md") orelse return error.TestUnexpectedResult;
    const body = entry.served() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, body, working_loop_heading));
    try std.testing.expect(std.mem.find(u8, body, "Do each thing once") != null);
    try std.testing.expect(std.mem.find(u8, body, "\n# ") == null);
    try std.testing.expect(std.mem.find(u8, system_prompt, body) != null);
}

test "the default system prompt is served whole" {
    const entry = find("fx", "SYSTEM.md") orelse return error.TestUnexpectedResult;
    const body = entry.served() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, body, "# Identity and context\n"));
    try std.testing.expectEqualStrings(system_prompt, body);
}

test "an entry with no text is not served" {
    const empty = Entry{ .skill = "fx", .file = "EMPTY.md", .text = "" };
    try std.testing.expect(empty.served() == null);
}

test "find returns null for a skill or file that is not in the table" {
    try std.testing.expect(find("fx", "MISSING.md") == null);
    try std.testing.expect(find("nope", "SYSTEM.md") == null);
}
