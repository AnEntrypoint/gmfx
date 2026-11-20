const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const gate_settings = @import("../config/commit_gate_settings.zig");
const git_invocation = @import("git_invocation.zig");
const safe_git = @import("safe_git.zig");

const Allocator = std.mem.Allocator;
const Token = git_invocation.Token;

pub const Settings = gate_settings.Settings;

pub const Check = enum {
    explicit_paths,
    forbid_trailers,
    author,
    check_command,
};

pub const Failure = struct {
    check: Check,
    detail: []const u8,
};

pub const HeadCommit = struct {
    author: []const u8,
    message: []const u8,
};

pub const CheckRun = union(enum) {
    passed,
    failed: struct { exit_code: ?u8, tail: []const u8 },
    timed_out,
    unavailable: []const u8,
};

pub const Probe = struct {
    context: *anyopaque,
    configured_author: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8) Allocator.Error!?[]const u8,
    head_commit: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8) Allocator.Error!?HeadCommit,
    read_file: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8, path: []const u8) Allocator.Error!?[]const u8,
    run_check: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8, timeout_s: u32) Allocator.Error!CheckRun,
};

const max_settings_bytes = 4 * 1024 * 1024;
const max_message_file_bytes = 64 * 1024;
const max_check_output_bytes = 256 * 1024;
const check_tail_bytes = 2000;
const check_tail_lines = 20;
const git_probe_timeout_s = 10;

pub fn refusalFor(arena: Allocator, command: []const u8, cwd: []const u8, workspace_root: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.find(u8, command, "git") == null) return null;
    const actions = try gatedActions(arena, command);
    if (actions.len == 0) return null;
    const settings = try loadSettings(arena, workspace_root);
    if (!settings.active()) return null;
    var native: u8 = 0;
    return evaluateActions(arena, settings, actions, cwd, workspace_root, nativeProbe(&native));
}

pub fn evaluate(
    arena: Allocator,
    settings: Settings,
    command: []const u8,
    cwd: []const u8,
    workspace_root: []const u8,
    probe: Probe,
) Allocator.Error!?[]const u8 {
    if (!settings.active()) return null;
    return evaluateActions(arena, settings, try gatedActions(arena, command), cwd, workspace_root, probe);
}

const Action = union(enum) {
    add: git_invocation.Git,
    commit: git_invocation.Git,
    push: git_invocation.Git,
};

fn gatedActions(arena: Allocator, command: []const u8) Allocator.Error![]Action {
    var out: std.ArrayList(Action) = .empty;
    for (try git_invocation.simpleCommands(arena, command)) |simple| {
        const git = (try git_invocation.gitOf(arena, simple.words)) orelse continue;
        if (std.mem.eql(u8, git.subcommand, "add") or std.mem.eql(u8, git.subcommand, "stage")) {
            try out.append(arena, .{ .add = git });
        } else if (std.mem.eql(u8, git.subcommand, "commit")) {
            if (!hasFlag(git.args, "--dry-run")) try out.append(arena, .{ .commit = git });
        } else if (std.mem.eql(u8, git.subcommand, "push")) {
            if (!hasFlag(git.args, "--dry-run") and !hasFlag(git.args, "-n")) try out.append(arena, .{ .push = git });
        }
    }
    return out.items;
}

fn evaluateActions(
    arena: Allocator,
    settings: Settings,
    actions: []const Action,
    cwd: []const u8,
    workspace_root: []const u8,
    probe: Probe,
) Allocator.Error!?[]const u8 {
    var failures: std.ArrayList(Failure) = .empty;
    var commits = false;
    for (actions) |action| switch (action) {
        .add => |git| if (settings.explicit_paths) {
            if (addStagesEverything(git.args)) |form| try failures.append(arena, .{
                .check = .explicit_paths,
                .detail = try arena.print("`git add {s}` stages every change in the tree. Stage the files you changed by name: git add <path>...", .{form}),
            });
        },
        .commit => |git| {
            commits = true;
            const commit = try readCommit(arena, git, cwd, probe);
            if (settings.explicit_paths and commit.all) try failures.append(arena, .{
                .check = .explicit_paths,
                .detail = "`git commit -a` commits every tracked change. Stage the files you changed with git add <path>... and commit without -a.",
            });
            if (settings.forbid_trailers) {
                if (commit.trailer_flag) |flag| {
                    try failures.append(arena, .{
                        .check = .forbid_trailers,
                        .detail = try arena.print("`{s}` adds an attribution trailer to the commit message. Remove that flag.", .{flag}),
                    });
                } else if (commit.message) |message| {
                    if (trailerLine(message)) |line| try failures.append(arena, .{
                        .check = .forbid_trailers,
                        .detail = try arena.print("the commit message carries an attribution trailer (\"{s}\"). Remove that line.", .{clip(line, 120)}),
                    });
                } else if (commit.message_unreadable) try failures.append(arena, .{
                    .check = .forbid_trailers,
                    .detail = "the commit message could not be read before the commit. Pass it with -m, or -F and a file inside the workspace.",
                });
            }
            if (settings.author) |expected| {
                const effective = commit.author orelse try probe.configured_author(probe.context, arena, cwd);
                try appendAuthorFailure(arena, &failures, expected, effective, "the effective git author");
            }
        },
        .push => {
            if (!settings.forbid_trailers and settings.author == null) continue;
            const head = (try probe.head_commit(probe.context, arena, cwd)) orelse continue;
            if (settings.forbid_trailers) {
                if (trailerLine(head.message)) |line| try failures.append(arena, .{
                    .check = .forbid_trailers,
                    .detail = try arena.print("the commit at HEAD carries an attribution trailer (\"{s}\"). Amend the message before pushing.", .{clip(line, 120)}),
                });
            }
            if (settings.author) |expected| try appendAuthorFailure(arena, &failures, expected, head.author, "the author of the commit at HEAD");
        },
    };
    if (commits and failures.items.len == 0) {
        if (settings.check_command) |check| {
            const check_cwd = if (workspace_root.len > 0) workspace_root else cwd;
            switch (try probe.run_check(probe.context, arena, check_cwd, check, settings.check_timeout_s)) {
                .passed => {},
                .failed => |failed| try failures.append(arena, .{
                    .check = .check_command,
                    .detail = if (failed.exit_code) |code|
                        try arena.print("`{s}` exited {d}. Last output:\n{s}", .{ check, code, try indent(arena, failed.tail) })
                    else
                        try arena.print("`{s}` ended without an exit code. Last output:\n{s}", .{ check, try indent(arena, failed.tail) }),
                }),
                .timed_out => try failures.append(arena, .{
                    .check = .check_command,
                    .detail = try arena.print("`{s}` did not finish within {d} seconds.", .{ check, settings.check_timeout_s }),
                }),
                .unavailable => |reason| try failures.append(arena, .{
                    .check = .check_command,
                    .detail = try arena.print("`{s}` could not be run ({s}).", .{ check, reason }),
                }),
            }
        }
    }
    if (failures.items.len == 0) return null;
    return try refusalText(arena, settings, failures.items);
}

fn appendAuthorFailure(
    arena: Allocator,
    failures: *std.ArrayList(Failure),
    expected: []const u8,
    effective: ?[]const u8,
    subject: []const u8,
) Allocator.Error!void {
    const name = effective orelse {
        try failures.append(arena, .{
            .check = .author,
            .detail = try arena.print("{s} could not be read, and \"{s}\" is expected. Commit with --author=\"{s} <email>\" or set user.name.", .{ subject, expected, expected }),
        });
        return;
    };
    if (std.mem.eql(u8, std.mem.trim(u8, name, " \t"), expected)) return;
    try failures.append(arena, .{
        .check = .author,
        .detail = try arena.print("{s} is \"{s}\", and \"{s}\" is expected. Commit with --author=\"{s} <email>\" or set user.name.", .{ subject, clip(name, 80), expected, expected }),
    });
}

pub fn refusalText(arena: Allocator, settings: Settings, failures: []const Failure) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "Commit gate refused this command; nothing ran. Failing checks:\n");
    for (failures) |failure| {
        try out.print(arena, "- {s}: {s}\n", .{ @tagName(failure.check), failure.detail });
    }
    try out.appendSlice(arena, "Fix each cause, then run the command again. Do not route around the gate with another command form.\n");
    if (settings.check_command) |check| {
        try out.print(arena, "Not covered: anything `{s}` does not run.", .{check});
    } else {
        try out.appendSlice(arena, "Not covered: builds and tests; no commit_gate.check_command is set.");
    }
    return out.items;
}

const Commit = struct {
    all: bool = false,
    trailer_flag: ?[]const u8 = null,
    message: ?[]const u8 = null,
    message_unreadable: bool = false,
    author: ?[]const u8 = null,
};

fn readCommit(arena: Allocator, git: git_invocation.Git, cwd: []const u8, probe: Probe) Allocator.Error!Commit {
    var commit: Commit = .{};
    var message: std.ArrayList(u8) = .empty;
    var has_message = false;
    var index: usize = 0;
    const args = git.args;
    while (index < args.len) : (index += 1) {
        const value = args[index].value;
        if (std.mem.eql(u8, value, "--")) break;
        if (value.len < 2 or value[0] != '-') continue;
        if (value[1] == '-') {
            if (std.mem.eql(u8, value, "--all")) {
                commit.all = true;
            } else if (std.mem.eql(u8, value, "--signoff") or std.mem.eql(u8, value, "--trailer") or std.mem.startsWith(u8, value, "--trailer=")) {
                commit.trailer_flag = value;
            } else if (longValue(args, &index, "--message")) |text| {
                try appendMessage(arena, &message, text);
                has_message = true;
            } else if (longValue(args, &index, "--file")) |path| {
                try appendMessageFile(arena, &message, &commit, cwd, path, probe);
                has_message = true;
            } else if (longValue(args, &index, "--author")) |author| {
                commit.author = authorName(author);
            }
            continue;
        }
        var at: usize = 1;
        while (at < value.len) : (at += 1) {
            switch (value[at]) {
                'a' => commit.all = true,
                's' => commit.trailer_flag = "-s",
                'm', 'F', 'C', 'c', 't' => {
                    const inline_value = value[at + 1 ..];
                    const text = if (inline_value.len > 0) inline_value else blk: {
                        if (index + 1 >= args.len) break :blk "";
                        index += 1;
                        break :blk args[index].value;
                    };
                    switch (value[at]) {
                        'm' => {
                            try appendMessage(arena, &message, text);
                            has_message = true;
                        },
                        'F' => {
                            try appendMessageFile(arena, &message, &commit, cwd, text, probe);
                            has_message = true;
                        },
                        else => {},
                    }
                    break;
                },
                else => {},
            }
        }
    }
    if (commit.author == null) {
        if (git_invocation.assignmentValue(git.assignments, "GIT_AUTHOR_NAME")) |name| {
            commit.author = name;
        } else if (git_invocation.configValue(git.config, "user.name")) |name| {
            commit.author = name;
        }
    }
    if (has_message and !commit.message_unreadable) commit.message = message.items;
    return commit;
}

fn longValue(args: []const Token, index: *usize, comptime name: []const u8) ?[]const u8 {
    const value = args[index.*].value;
    if (std.mem.startsWith(u8, value, name ++ "=")) return value[name.len + 1 ..];
    if (!std.mem.eql(u8, value, name)) return null;
    if (index.* + 1 >= args.len) return "";
    index.* += 1;
    return args[index.*].value;
}

fn appendMessage(arena: Allocator, message: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    if (message.items.len > 0) try message.appendSlice(arena, "\n\n");
    try message.appendSlice(arena, text);
}

fn appendMessageFile(
    arena: Allocator,
    message: *std.ArrayList(u8),
    commit: *Commit,
    cwd: []const u8,
    path: []const u8,
    probe: Probe,
) Allocator.Error!void {
    if (path.len == 0 or std.mem.eql(u8, path, "-")) {
        commit.message_unreadable = true;
        return;
    }
    const text = (try probe.read_file(probe.context, arena, cwd, path)) orelse {
        commit.message_unreadable = true;
        return;
    };
    try appendMessage(arena, message, text);
}

fn authorName(author: []const u8) []const u8 {
    const open = std.mem.findScalar(u8, author, '<') orelse return std.mem.trim(u8, author, " \t");
    return std.mem.trim(u8, author[0..open], " \t");
}

fn hasFlag(args: []const Token, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.value, "--")) return false;
        if (std.mem.eql(u8, arg.value, flag)) return true;
    }
    return false;
}

pub fn addStagesEverything(args: []const Token) ?[]const u8 {
    var options = true;
    var pathspecs: usize = 0;
    var update = false;
    for (args) |arg| {
        const value = arg.value;
        if (options and std.mem.eql(u8, value, "--")) {
            options = false;
            continue;
        }
        if (options and value.len > 1 and value[0] == '-') {
            if (std.mem.eql(u8, value, "--all") or std.mem.eql(u8, value, "--no-ignore-removal")) return value;
            if (std.mem.eql(u8, value, "--update")) update = true;
            if (value[1] != '-') {
                if (std.mem.findScalar(u8, value, 'A') != null) return value;
                if (std.mem.findScalar(u8, value, 'u') != null) update = true;
            }
            continue;
        }
        pathspecs += 1;
        if (isWholeTreePathspec(arg)) return value;
    }
    if (update and pathspecs == 0) return "-u";
    return null;
}

fn isWholeTreePathspec(arg: Token) bool {
    const value = arg.value;
    for ([_][]const u8{ ".", "./", ":/", ":/*", ":/.", ":(top)", ":(top).", "--all" }) |whole| {
        if (std.mem.eql(u8, value, whole)) return true;
    }
    return !arg.quoted and (std.mem.eql(u8, value, "*") or std.mem.eql(u8, value, "./*") or std.mem.eql(u8, value, "**"));
}

pub fn trailerLine(message: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (isAttributionTrailer(line) or isGeneratedByLine(line)) return line;
    }
    return null;
}

fn isAttributionTrailer(line: []const u8) bool {
    const colon = std.mem.findScalar(u8, line, ':') orelse return false;
    const key = line[0..colon];
    if (key.len < 4 or key.len > 40) return false;
    for (key) |ch| {
        if (!std.ascii.isAlphabetic(ch) and ch != '-') return false;
    }
    return std.ascii.endsWithIgnoreCase(key, "-by");
}

fn isGeneratedByLine(line: []const u8) bool {
    var start: usize = 0;
    while (start < line.len and !std.ascii.isAlphabetic(line[start])) start += 1;
    const text = line[start..];
    return std.ascii.startsWithIgnoreCase(text, "generated with ") or std.ascii.startsWithIgnoreCase(text, "generated by ");
}

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn indent(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, "    ");
        try out.appendSlice(arena, std.mem.trimEnd(u8, line, "\r"));
    }
    return out.items;
}

pub fn outputTail(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    var start = trimmed.len;
    var lines: usize = 0;
    while (start > 0) {
        if (trimmed.len - (start - 1) > check_tail_bytes) break;
        if (trimmed[start - 1] == '\n') {
            lines += 1;
            if (lines == check_tail_lines) break;
        }
        start -= 1;
    }
    while (start < trimmed.len and (trimmed[start] & 0xC0) == 0x80) start += 1;
    return trimmed[start..];
}

pub fn loadSettings(arena: Allocator, workspace_root: []const u8) Allocator.Error!Settings {
    const home = io_mod.homeDir() orelse return .{};
    const path = profile_paths.settingsPath(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    return gate_settings.parseSettingsText(arena, bytes, workspace_root);
}

fn nativeProbe(context: *u8) Probe {
    return .{
        .context = context,
        .configured_author = nativeConfiguredAuthor,
        .head_commit = nativeHeadCommit,
        .read_file = nativeReadFile,
        .run_check = nativeRunCheck,
    };
}

fn nativeConfiguredAuthor(_: *anyopaque, arena: Allocator, cwd: []const u8) Allocator.Error!?[]const u8 {
    if (io_mod.getenv("GIT_AUTHOR_NAME")) |name| {
        if (name.len > 0) return try arena.dupe(u8, name);
    }
    const output = (try safeGitOutput(arena, cwd, .config_get, &.{"user.name"})) orelse return null;
    const name = std.mem.trim(u8, output, " \t\r\n");
    return if (name.len == 0) null else name;
}

fn nativeHeadCommit(_: *anyopaque, arena: Allocator, cwd: []const u8) Allocator.Error!?HeadCommit {
    const output = (try safeGitOutput(arena, cwd, .log, &.{ "-1", "--format=%an%n%B" })) orelse return null;
    const newline = std.mem.findScalar(u8, output, '\n') orelse return null;
    return .{ .author = output[0..newline], .message = output[newline + 1 ..] };
}

fn safeGitOutput(arena: Allocator, cwd: []const u8, subcommand: safe_git.Subcommand, args: []const []const u8) Allocator.Error!?[]const u8 {
    const ready = switch (try safe_git.prepare(arena, cwd)) {
        .ready => |ready| ready,
        .refused => return null,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(arena, &argv, ready, subcommand);
    try argv.appendSlice(arena, args);
    var environment = try safe_git.environment(arena);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdout_limit = .limited(max_message_file_bytes),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(git_probe_timeout_s), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!result.term.success()) return null;
    return result.stdout;
}

fn nativeReadFile(_: *anyopaque, arena: Allocator, cwd: []const u8, path: []const u8) Allocator.Error!?[]const u8 {
    const absolute = if (std.Io.Dir.path.isAbsolute(path)) path else try std.Io.Dir.path.join(arena, &.{ cwd, path });
    return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), absolute, arena, .limited(max_message_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn nativeRunCheck(_: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8, timeout_s: u32) Allocator.Error!CheckRun {
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ "/bin/sh", "-c", command },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_check_output_bytes),
        .stderr_limit = .limited(max_check_output_bytes),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return .timed_out,
        else => {
            debug_trace.logf("core", "commit gate check could not run err={s}", .{@errorName(err)});
            return .{ .unavailable = @errorName(err) };
        },
    };
    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    if (exit_code == 0) return .passed;
    const combined = if (result.stderr.len == 0)
        result.stdout
    else if (result.stdout.len == 0)
        result.stderr
    else
        try std.mem.concat(arena, u8, &.{ result.stdout, "\n", result.stderr });
    return .{ .failed = .{ .exit_code = exit_code, .tail = outputTail(combined) } };
}

const testing = std.testing;

const FakeProbe = struct {
    author: ?[]const u8 = "Example Author",
    head: ?HeadCommit = null,
    file: ?[]const u8 = null,
    check: CheckRun = .passed,
    checks_run: usize = 0,
    last_check_cwd: []const u8 = "",

    fn probe(self: *FakeProbe) Probe {
        return .{
            .context = self,
            .configured_author = configuredAuthor,
            .head_commit = headCommit,
            .read_file = readFile,
            .run_check = runCheck,
        };
    }

    fn of(context: *anyopaque) *FakeProbe {
        return @ptrCast(@alignCast(context));
    }

    fn configuredAuthor(context: *anyopaque, _: Allocator, _: []const u8) Allocator.Error!?[]const u8 {
        return of(context).author;
    }

    fn headCommit(context: *anyopaque, _: Allocator, _: []const u8) Allocator.Error!?HeadCommit {
        return of(context).head;
    }

    fn readFile(context: *anyopaque, _: Allocator, _: []const u8, _: []const u8) Allocator.Error!?[]const u8 {
        return of(context).file;
    }

    fn runCheck(context: *anyopaque, _: Allocator, cwd: []const u8, _: []const u8, _: u32) Allocator.Error!CheckRun {
        const self = of(context);
        self.checks_run += 1;
        self.last_check_cwd = cwd;
        return self.check;
    }
};

fn refusal(arena: Allocator, settings: Settings, command: []const u8, fake: *FakeProbe) !?[]const u8 {
    return evaluate(arena, settings, command, "/w/sub", "/w", fake.probe());
}

fn expectRefused(arena: Allocator, settings: Settings, command: []const u8, fake: *FakeProbe, needles: []const []const u8) !void {
    const text = (try refusal(arena, settings, command, fake)) orelse {
        std.debug.print("expected a refusal for: {s}\n", .{command});
        return error.TestExpectedRefusal;
    };
    for (needles) |needle| {
        if (std.mem.find(u8, text, needle) == null) {
            std.debug.print("refusal for {s} lacks {s}:\n{s}\n", .{ command, needle, text });
            return error.TestExpectedNeedle;
        }
    }
}

fn expectAllowed(arena: Allocator, settings: Settings, command: []const u8, fake: *FakeProbe) !void {
    if (try refusal(arena, settings, command, fake)) |text| {
        std.debug.print("unexpected refusal for {s}:\n{s}\n", .{ command, text });
        return error.TestUnexpectedRefusal;
    }
}

test "with every check off the gate lets every commit through and runs nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeProbe = .{ .author = "someone else", .check = .{ .failed = .{ .exit_code = 1, .tail = "boom" } } };
    for ([_][]const u8{
        "git add -A && git commit -am 'x\n\nCo-Authored-By: A <a@example.invalid>'",
        "git push --force",
        "git commit --signoff -m x",
    }) |command| try expectAllowed(arena, .{}, command, &fake);
    try testing.expectEqual(@as(usize, 0), fake.checks_run);
}

test "explicit_paths refuses whole-tree staging and names the alternative" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeProbe = .{};
    const on: Settings = .{ .explicit_paths = true };
    for ([_][]const u8{
        "git add -A",
        "git add --all",
        "git add .",
        "git add -u",
        "git add -Av",
        "git add :/",
        "git add *",
        "cd repo && git add . && git status",
        "git stage -A",
        "git -C sub add .",
    }) |command| try expectRefused(arena, on, command, &fake, &.{ "- explicit_paths:", "git add <path>..." });
    for ([_][]const u8{ "git commit -a -m x", "git commit -am x", "git commit --all -m x" }) |command| {
        try expectRefused(arena, on, command, &fake, &.{ "- explicit_paths:", "commit without -a" });
    }
    for ([_][]const u8{
        "git add src/main.zig docs/",
        "git add -u src/",
        "git add -- ./file",
        "git add '*.zig'",
        "echo \"git add -A\"",
        "git commit -m 'explain git add -A'",
        "git add -n -A extra && true",
        "git log --all",
        "git commit --dry-run -a",
    }) |command| {
        if (std.mem.eql(u8, command, "git add -n -A extra && true")) {
            try expectRefused(arena, on, command, &fake, &.{"- explicit_paths:"});
        } else {
            try expectAllowed(arena, on, command, &fake);
        }
    }
}

test "forbid_trailers refuses attribution trailers from every message source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeProbe = .{};
    const on: Settings = .{ .forbid_trailers = true };
    for ([_][]const u8{
        "git commit -m 'fix parser\n\nCo-Authored-By: Helper <helper@example.invalid>'",
        "git commit -m 'fix parser' -m 'Signed-off-by: Helper <helper@example.invalid>'",
        "git commit --message='fix\n\nco-authored-by: x <x@example.invalid>'",
        "git commit -m \"fix\n\n Generated with [a tool](https://example.invalid)\"",
        "git commit -m\"fix\n\nReviewed-by: R <r@example.invalid>\"",
        "git commit -m \"$(cat <<'EOF'\nfix\n\nCo-Authored-By: Helper <helper@example.invalid>\nEOF\n)\"",
    }) |command| try expectRefused(arena, on, command, &fake, &.{ "- forbid_trailers:", "attribution trailer" });
    try expectRefused(arena, on, "git commit -s -m fix", &fake, &.{ "- forbid_trailers:", "`-s`" });
    try expectRefused(arena, on, "git commit --signoff -m fix", &fake, &.{"`--signoff`"});
    try expectRefused(arena, on, "git commit --trailer 'Co-Authored-By: x' -m fix", &fake, &.{"`--trailer`"});

    fake.file = "fix\n\nCo-Authored-By: Helper <helper@example.invalid>\n";
    try expectRefused(arena, on, "git commit -F msg.txt", &fake, &.{"Co-Authored-By: Helper"});
    fake.file = "fix the parser\n\nIt lost the last token.\n";
    try expectAllowed(arena, on, "git commit -F msg.txt", &fake);
    fake.file = null;
    try expectRefused(arena, on, "git commit -F msg.txt", &fake, &.{"could not be read"});
    try expectRefused(arena, on, "git commit -F -", &fake, &.{"could not be read"});

    for ([_][]const u8{
        "git commit -m 'fix parser: stand-by mode stays off'",
        "git commit -m 'Thanks: reviewed by the team'",
        "git commit -m 'docs: describe Co-Authored-By handling'",
        "git commit",
        "git log --format=%B -1",
    }) |command| try expectAllowed(arena, on, command, &fake);
}

test "author refuses a commit whose effective author differs from the expected name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const on: Settings = .{ .author = "Example Author" };
    var fake: FakeProbe = .{ .author = "Example Author" };
    try expectAllowed(arena, on, "git commit -m x", &fake);
    try expectAllowed(arena, on, "git commit --author='Example Author <a@example.invalid>' -m x", &fake);
    try expectRefused(arena, on, "git commit --author='Other Person <o@example.invalid>' -m x", &fake, &.{ "- author:", "\"Other Person\"", "\"Example Author\" is expected" });
    try expectRefused(arena, on, "GIT_AUTHOR_NAME='Other Person' git commit -m x", &fake, &.{"\"Other Person\""});
    try expectRefused(arena, on, "git -c user.name='Other Person' commit -m x", &fake, &.{"\"Other Person\""});

    fake.author = "Other Person";
    try expectRefused(arena, on, "git commit -m x", &fake, &.{ "- author:", "the effective git author is \"Other Person\"" });
    try expectAllowed(arena, on, "git -c user.name='Example Author' commit -m x", &fake);
    fake.author = null;
    try expectRefused(arena, on, "git commit -m x", &fake, &.{ "- author:", "could not be read" });
}

test "check_command runs once before a commit and its failing tail is in the refusal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const on: Settings = .{ .check_command = "make check", .check_timeout_s = 30 };
    var fake: FakeProbe = .{};
    try expectAllowed(arena, on, "git add src/a.zig && git commit -m x", &fake);
    try testing.expectEqual(@as(usize, 1), fake.checks_run);
    try testing.expectEqualStrings("/w", fake.last_check_cwd);

    try expectAllowed(arena, on, "git add src/a.zig", &fake);
    try expectAllowed(arena, on, "git push", &fake);
    try testing.expectEqual(@as(usize, 1), fake.checks_run);

    fake.check = .{ .failed = .{ .exit_code = 2, .tail = "test parser... FAIL\n1 failed" } };
    try expectRefused(arena, on, "git commit -m x", &fake, &.{ "- check_command: `make check` exited 2.", "    test parser... FAIL\n    1 failed", "Not covered: anything `make check` does not run." });
    fake.check = .timed_out;
    try expectRefused(arena, on, "git commit -m x", &fake, &.{"did not finish within 30 seconds"});
    fake.check = .{ .unavailable = "FileNotFound" };
    try expectRefused(arena, on, "git commit -m x", &fake, &.{"could not be run (FileNotFound)"});
}

test "one refusal names every failing check, and the check command waits for the others" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const on: Settings = .{ .explicit_paths = true, .forbid_trailers = true, .author = "Example Author", .check_command = "make check" };
    var fake: FakeProbe = .{ .author = "Other Person", .check = .{ .failed = .{ .exit_code = 1, .tail = "boom" } } };
    try expectRefused(
        arena,
        on,
        "git add -A && git commit -am 'x\n\nCo-Authored-By: Helper <h@example.invalid>'",
        &fake,
        &.{ "Commit gate refused this command; nothing ran.", "- explicit_paths: `git add -A`", "- explicit_paths: `git commit -a`", "- forbid_trailers:", "- author:", "Do not route around the gate" },
    );
    try testing.expectEqual(@as(usize, 0), fake.checks_run);
}

test "a push is refused when the commit at HEAD breaks the trailer or author rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const on: Settings = .{ .forbid_trailers = true, .author = "Example Author" };
    var fake: FakeProbe = .{ .head = .{ .author = "Example Author", .message = "fix parser\n" } };
    try expectAllowed(arena, on, "git push origin main", &fake);
    fake.head = .{ .author = "Other Person", .message = "fix\n\nCo-Authored-By: Helper <h@example.invalid>\n" };
    try expectRefused(arena, on, "git push origin main", &fake, &.{ "- forbid_trailers: the commit at HEAD", "- author: the author of the commit at HEAD is \"Other Person\"" });
    try expectAllowed(arena, on, "git push --dry-run", &fake);
    fake.head = null;
    try expectAllowed(arena, on, "git push", &fake);
}

test "the tail of a failing check keeps its last lines within the byte bound" {
    try testing.expectEqualStrings("b\nc", outputTail("b\nc\n\n"));
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..100) |line| try many.print(testing.allocator, "line {d}\n", .{line});
    const tail = outputTail(many.items);
    try testing.expect(std.mem.endsWith(u8, tail, "line 99"));
    try testing.expectEqual(@as(usize, check_tail_lines - 1), std.mem.count(u8, tail, "\n"));
    var long: [check_tail_bytes * 2]u8 = undefined;
    @memset(&long, 'x');
    try testing.expect(outputTail(&long).len <= check_tail_bytes);
}
