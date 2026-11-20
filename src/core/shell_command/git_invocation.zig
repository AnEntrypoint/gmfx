const std = @import("std");
const command_lex = @import("command_lex.zig");

const Allocator = std.mem.Allocator;

pub const Token = command_lex.ArgvToken;

pub const Simple = struct {
    words: []const Token,
    background: bool = false,
};

pub const Invocation = struct {
    name: []const u8,
    args: []const Token,
    assignments: []const Token,
};

pub const Git = struct {
    subcommand: []const u8,
    args: []const Token,
    assignments: []const Token,
    config: []const []const u8,
};

const separators = [_][]const u8{ ";", "&&", "||", "|", "&", "(", ")", "{", "}" };
const wrappers = [_][]const u8{ "sudo", "doas", "env", "command", "exec", "nohup", "builtin", "nice", "time", "timeout", "stdbuf", "unbuffer" };
const wrapper_value_options = [_][]const u8{
    "-u", "--user",       "-g", "--group", "-h",           "--host",   "-p", "--prompt",       "-C",      "--chdir",
    "-n", "--adjustment", "-k", "-s",      "--kill-after", "--signal", "-S", "--split-string", "--unset", "-i",
    "-o", "-e",
};
const git_value_options = [_][]const u8{ "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env" };

pub fn simpleCommands(arena: Allocator, command: []const u8) Allocator.Error![]Simple {
    const argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const tokens = argv.tokens;
    var out: std.ArrayList(Simple) = .empty;
    var start: usize = 0;
    var heredoc_end: ?[]const u8 = null;
    var in_heredoc = false;
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        const starts_line = index > 0 and lineBreakBetween(command, tokens[index - 1], token);
        if (in_heredoc) {
            if (starts_line and std.mem.eql(u8, token.value, heredoc_end.?) and endsLine(command, tokens, index)) {
                in_heredoc = false;
                heredoc_end = null;
            }
            start = index + 1;
            continue;
        }
        if (starts_line) {
            if (start < index) try out.append(arena, .{ .words = tokens[start..index] });
            start = index;
            if (heredoc_end != null) {
                in_heredoc = true;
                index -= 1;
                continue;
            }
        }
        if (!token.quoted and std.mem.eql(u8, token.value, "<<") and index + 1 < tokens.len) {
            heredoc_end = std.mem.trimStart(u8, tokens[index + 1].value, "-");
            continue;
        }
        if (!isSeparator(token)) continue;
        if (start < index) {
            try out.append(arena, .{
                .words = tokens[start..index],
                .background = std.mem.eql(u8, token.value, "&"),
            });
        }
        start = index + 1;
    }
    if (!in_heredoc and start < tokens.len) try out.append(arena, .{ .words = tokens[start..] });
    return out.items;
}

fn lineBreakBetween(command: []const u8, before: Token, after: Token) bool {
    if (before.end > after.start or after.start > command.len) return false;
    const gap = command[before.end..after.start];
    const newline = std.mem.findScalar(u8, gap, '\n') orelse return false;
    return newline == 0 or gap[newline - 1] != '\\';
}

fn endsLine(command: []const u8, tokens: []const Token, index: usize) bool {
    if (index + 1 >= tokens.len) return true;
    return lineBreakBetween(command, tokens[index], tokens[index + 1]);
}

fn isSeparator(token: Token) bool {
    if (token.quoted) return false;
    return contains(&separators, token.value);
}

pub fn invocationOf(words: []const Token) ?Invocation {
    var rest = words;
    var first_assignment: usize = 0;
    var assignment_count: usize = 0;
    var offset: usize = 0;
    while (rest.len > 0) {
        if (command_lex.is_safe_env_assignment(rest[0].value) or isAssignment(rest[0].value)) {
            if (assignment_count == 0) first_assignment = offset;
            assignment_count += 1;
            rest = rest[1..];
            offset += 1;
            continue;
        }
        const name = basename(rest[0].value);
        if (!contains(&wrappers, name)) break;
        rest = rest[1..];
        offset += 1;
        while (rest.len > 0 and rest[0].value.len > 1 and rest[0].value[0] == '-') {
            const takes_value = std.mem.findScalar(u8, rest[0].value, '=') == null and contains(&wrapper_value_options, rest[0].value);
            const step: usize = if (takes_value and rest.len > 1) 2 else 1;
            rest = rest[step..];
            offset += step;
        }
        if (std.mem.eql(u8, name, "timeout") and rest.len > 0 and isDuration(rest[0].value)) {
            rest = rest[1..];
            offset += 1;
        }
    }
    if (rest.len == 0) return null;
    const assignments = if (assignment_count == 0) words[0..0] else words[first_assignment..offset];
    return .{ .name = basename(rest[0].value), .args = rest[1..], .assignments = assignments };
}

pub fn gitOf(arena: Allocator, words: []const Token) Allocator.Error!?Git {
    const invocation = invocationOf(words) orelse return null;
    if (!std.mem.eql(u8, invocation.name, "git")) return null;
    var config: std.ArrayList([]const u8) = .empty;
    var args = invocation.args;
    while (args.len > 0) {
        const value = args[0].value;
        if (value.len == 0 or value[0] != '-') break;
        if (std.mem.eql(u8, value, "-c") and args.len > 1) try config.append(arena, args[1].value);
        const step: usize = if (contains(&git_value_options, value) and args.len > 1) 2 else 1;
        args = args[step..];
    }
    if (args.len == 0) return null;
    return .{
        .subcommand = args[0].value,
        .args = args[1..],
        .assignments = invocation.assignments,
        .config = config.items,
    };
}

pub fn assignmentValue(assignments: []const Token, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (assignments) |token| {
        const equals = std.mem.findScalar(u8, token.value, '=') orelse continue;
        if (std.mem.eql(u8, token.value[0..equals], name)) found = token.value[equals + 1 ..];
    }
    return found;
}

pub fn configValue(config: []const []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (config) |entry| {
        const equals = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(entry[0..equals], name)) found = entry[equals + 1 ..];
    }
    return found;
}

fn isAssignment(value: []const u8) bool {
    const equals = std.mem.findScalar(u8, value, '=') orelse return false;
    if (equals == 0 or std.ascii.isDigit(value[0])) return false;
    for (value[0..equals]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isDuration(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isDigit(value[0])) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.' and ch != 's' and ch != 'm' and ch != 'h' and ch != 'd') return false;
    }
    return true;
}

pub fn basename(value: []const u8) []const u8 {
    const index = std.mem.findScalarLast(u8, value, '/') orelse return value;
    return value[index + 1 ..];
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const testing = std.testing;

fn expectGit(arena: Allocator, command: []const u8, index: usize, subcommand: []const u8, first_arg: ?[]const u8) !void {
    const simple = try simpleCommands(arena, command);
    try testing.expect(index < simple.len);
    const git = (try gitOf(arena, simple[index].words)) orelse return error.TestExpectedGit;
    try testing.expectEqualStrings(subcommand, git.subcommand);
    if (first_arg) |arg| try testing.expectEqualStrings(arg, git.args[0].value) else try testing.expectEqual(@as(usize, 0), git.args.len);
}

test "git invocations are found after separators, line breaks, wrappers and global options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectGit(arena, "git add -A", 0, "add", "-A");
    try expectGit(arena, "cd repo && git commit -m x", 1, "commit", "-m");
    try expectGit(arena, "git status\ngit push --force", 1, "push", "--force");
    try expectGit(arena, "GIT_AUTHOR_NAME=someone git -C sub -c user.name=other commit", 0, "commit", null);
    try expectGit(arena, "sudo -u build env LANG=C /usr/bin/git add .", 0, "add", ".");
    try expectGit(arena, "timeout 30 git fetch origin", 0, "fetch", "origin");
    try expectGit(arena, "git add a.txt \\\n  b.txt", 0, "add", "a.txt");

    const quoted = try simpleCommands(arena, "echo \"git add -A\" 'git commit -a'");
    try testing.expectEqual(@as(usize, 1), quoted.len);
    try testing.expect((try gitOf(arena, quoted[0].words)) == null);
}

test "assignments and -c values in front of git are read back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const simple = try simpleCommands(arena, "GIT_AUTHOR_NAME='Example Author' git -c user.name=other -c core.editor=true commit -m x");
    const git = (try gitOf(arena, simple[0].words)).?;
    try testing.expectEqualStrings("Example Author", assignmentValue(git.assignments, "GIT_AUTHOR_NAME").?);
    try testing.expectEqualStrings("other", configValue(git.config, "user.name").?);
    try testing.expectEqual(@as(?[]const u8, null), configValue(git.config, "user.email"));
}

test "a trailing ampersand marks a background command, and redirections do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const background = try simpleCommands(arena, "npm start > out.log 2>&1 &");
    try testing.expectEqual(@as(usize, 1), background.len);
    try testing.expect(background[0].background);

    const chained = try simpleCommands(arena, "make && ./run 2>&1 | tee log; echo '&'");
    try testing.expectEqual(@as(usize, 4), chained.len);
    for (chained) |simple| try testing.expect(!simple.background);

    const mid = try simpleCommands(arena, "server & sleep 1; curl localhost");
    try testing.expect(mid[0].background);
    try testing.expect(!mid[1].background);
}

test "heredoc bodies are not read as commands, and commands after them are" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command =
        \\cat > notes.txt <<EOF
        \\git add -A
        \\pkill node
        \\EOF
        \\git status
    ;
    const simple = try simpleCommands(arena, command);
    try testing.expectEqual(@as(usize, 2), simple.len);
    try testing.expectEqualStrings("cat", invocationOf(simple[0].words).?.name);
    try expectGit(arena, command, 1, "status", null);
}

test "an unbalanced command yields no commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try simpleCommands(arena_state.allocator(), "git commit -m \"open")).len);
}
