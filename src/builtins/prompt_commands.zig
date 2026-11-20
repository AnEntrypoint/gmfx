const std = @import("std");

const Allocator = std.mem.Allocator;

pub const init_instructions =
    \\Please analyze this codebase and create an AGENTS.md file at the workspace root. fx gives that file to every later session that works in this repository.
    \\
    \\What to add:
    \\1. The commands a contributor runs most, such as how to build, lint and test, including how to run a single test.
    \\2. The high-level architecture and structure of the code: the big picture that takes reading several files to understand.
    \\
    \\Usage notes:
    \\- If an AGENTS.md already exists, improve it in place instead of starting over.
    \\- Keep it short. Leave out generic advice such as "write helpful error messages" or "never commit secrets".
    \\- Do not list every component or file that a directory listing already shows.
    \\- If the repository has Cursor rules (.cursor/rules/ or .cursorrules), Copilot instructions (.github/copilot-instructions.md) or a CLAUDE.md, carry over their important parts.
    \\- If there is a README.md, carry over its important parts.
    \\- Do not invent sections such as "Common Development Tasks" or "Tips for Development" unless the repository's own files contain them.
    \\
;

pub fn initPrompt(alloc: Allocator, rest: []const u8) Allocator.Error![]u8 {
    const focus = std.mem.trim(u8, rest, " \t\r\n");
    if (focus.len == 0) return alloc.dupe(u8, init_instructions);
    return std.fmt.allocPrint(alloc, "{s}\n## The user's focus\n\n{s}\n", .{ init_instructions, focus });
}

pub const default_loop_interval = "10m";

pub const LoopRequest = struct {
    interval: []const u8,
    prompt: []const u8,
};

pub fn parseLoop(rest: []const u8) ?LoopRequest {
    const text = std.mem.trim(u8, rest, " \t\r\n");
    if (text.len == 0) return null;
    const end = std.mem.findAny(u8, text, " \t") orelse text.len;
    const first = text[0..end];
    if (!isInterval(first)) return .{ .interval = default_loop_interval, .prompt = text };
    const prompt = std.mem.trim(u8, text[end..], " \t");
    if (prompt.len == 0) return null;
    return .{ .interval = first, .prompt = prompt };
}

fn isInterval(word: []const u8) bool {
    if (word.len < 2) return false;
    if (std.mem.findScalar(u8, "smhd", word[word.len - 1]) == null) return false;
    const count = std.fmt.parseUnsigned(u32, word[0 .. word.len - 1], 10) catch return false;
    return count > 0;
}

pub fn loopPrompt(alloc: Allocator, request: LoopRequest) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "The user ran `/loop`. Schedule the prompt below to run every {s} for as long as this session stays open. " ++
            "Call the `CronCreate` tool once with `recurring` true, a 5-field cron expression that matches that interval " ++
            "(round an interval shorter than one minute up to every minute), and the prompt text exactly as written. " ++
            "Then tell the user the schedule and the task id, and that they can ask you to cancel or change it.\n\n" ++
            "## Prompt to repeat\n\n{s}\n",
        .{ request.interval, request.prompt },
    );
}

test "/init asks for AGENTS.md and appends the user's focus when one is given" {
    const alloc = std.testing.allocator;
    const plain = try initPrompt(alloc, "  ");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(init_instructions, plain);
    try std.testing.expect(std.mem.find(u8, plain, "AGENTS.md") != null);

    const focused = try initPrompt(alloc, " cover the release steps ");
    defer alloc.free(focused);
    try std.testing.expect(std.mem.startsWith(u8, focused, init_instructions));
    try std.testing.expect(std.mem.endsWith(u8, focused, "## The user's focus\n\ncover the release steps\n"));
}

test "/loop reads a leading interval, defaults to ten minutes, and needs a prompt" {
    try std.testing.expect(parseLoop("   ") == null);
    try std.testing.expect(parseLoop("5m") == null);

    const timed = parseLoop(" 5m check the deploy ").?;
    try std.testing.expectEqualStrings("5m", timed.interval);
    try std.testing.expectEqualStrings("check the deploy", timed.prompt);

    const untimed = parseLoop("check the deploy").?;
    try std.testing.expectEqualStrings(default_loop_interval, untimed.interval);
    try std.testing.expectEqualStrings("check the deploy", untimed.prompt);

    const not_an_interval = parseLoop("0m check").?;
    try std.testing.expectEqualStrings(default_loop_interval, not_an_interval.interval);
    try std.testing.expectEqualStrings("0m check", not_an_interval.prompt);

    const prompt = try loopPrompt(std.testing.allocator, timed);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "every 5m ") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "`CronCreate`") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "## Prompt to repeat\n\ncheck the deploy\n"));
}
