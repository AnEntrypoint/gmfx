const std = @import("std");
const command_lex = @import("../shell_command/command_lex.zig");
const paths = @import("paths.zig");

const Allocator = std.mem.Allocator;
const ArgvToken = command_lex.ArgvToken;

pub const Target = struct {
    command: []const u8,
    cwd: []const u8,
    main_checkout: []const u8,
    home: []const u8,
};

const escape_hint = "to retire the tower workspace deliberately, turn tower mode off and remove .tower/comms manually in a terminal — this guard only intercepts agent Bash calls.";
const git_clean_message = "`git clean` with force and -x/-X is not allowed when its scope covers the tower main checkout — it would delete .tower/comms, the tower protocol state, which git does not track and cannot restore. Run the clean inside your own tower worktree or a temporary `git worktree add` checkout instead; " ++ escape_hint;
const git_reset_message = "`git reset --hard` is not allowed in the tower main checkout — it would silently discard base-checkout work the tower fleet depends on. Run it inside your own tower worktree or a temporary worktree instead; " ++ escape_hint;
const rm_format = "`rm` is not allowed on tower protocol paths (\"{s}\") — .tower/comms holds the tower protocol state and deleting it orphans the fleet. Remove paths inside your own worktree instead; " ++ escape_hint;
const unanalyzable_message = "this Bash command mentions git clean / git reset / rm and the tower guard could not parse it safely, so it is blocked conservatively — a misread command could delete .tower/comms, the tower protocol state. Split it into simpler commands or run it inside your tower worktree.";

const max_nested_depth = 4;

const privilege_wrappers = [_][]const u8{ "sudo", "doas" };
const privilege_value_options = [_][]const u8{ "-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt", "-C", "--close-from", "-T", "--command-timeout", "-U", "--other-user", "-r", "--role", "-t", "--type" };
const launch_wrappers = [_][]const u8{ "env", "command", "exec", "nohup", "builtin", "nice", "time" };
const wrapper_value_options = [_][]const u8{ "-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "-n", "--adjustment", "-o", "--output", "-f", "--format" };
const nested_shells = [_][]const u8{ "sh", "bash", "dash", "zsh", "ksh", "ash" };
const separators = [_][]const u8{ ";", "&&", "||", "&", "(", ")", "{", "}" };

const Layout = struct {
    main: []const u8,
    tower_root: []const u8,
    comms: []const u8,
    worktrees: []const u8,
};

const Ctx = struct {
    arena: Allocator,
    layout: Layout,
    home: []const u8,
    depth: usize,
};

const Walk = struct {
    veto: ?[]const u8 = null,
    cwd: []const u8,
};

const Bucket = enum { comms, tower_ancestor, protected_interior };

pub fn needsGuard(command: []const u8) bool {
    if (hasWord(command, "rm")) return true;
    return hasWord(command, "git") and (hasWord(command, "clean") or hasWord(command, "reset"));
}

pub fn analyze(arena: Allocator, target: Target) Allocator.Error!?[]const u8 {
    if (!needsGuard(target.command)) return null;
    const main = try normalizePath(arena, target.main_checkout);
    const layout: Layout = .{
        .main = main,
        .tower_root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ main, paths.tower_root }),
        .comms = try std.fmt.allocPrint(arena, "{s}/{s}", .{ main, paths.comms_dir }),
        .worktrees = try std.fmt.allocPrint(arena, "{s}/{s}", .{ main, paths.worktrees_dir }),
    };
    const ctx: Ctx = .{ .arena = arena, .layout = layout, .home = target.home, .depth = 0 };
    const walk = try analyzeText(ctx, target.command, try normalizePath(arena, target.cwd));
    return walk.veto;
}

fn analyzeText(ctx: Ctx, text: []const u8, cwd: []const u8) Allocator.Error!Walk {
    var current = cwd;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const argv = command_lex.tokenize_argv(ctx.arena, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .veto = unanalyzable_message, .cwd = current },
        };
        const walk = try analyzeTokens(ctx, argv.tokens, current);
        if (walk.veto != null) return .{ .veto = walk.veto, .cwd = current };
        current = walk.cwd;
    }
    return .{ .cwd = current };
}

fn analyzeTokens(ctx: Ctx, tokens: []const ArgvToken, cwd: []const u8) Allocator.Error!Walk {
    var current = cwd;
    var scopes: std.ArrayList([]const u8) = .empty;
    var stages: std.ArrayList([]const ArgvToken) = .empty;
    var stage: std.ArrayList(ArgvToken) = .empty;
    var skip_target = false;
    for (tokens) |token| {
        if (skip_target) {
            skip_target = false;
            if (isWordToken(token)) continue;
        }
        if (isRedirectToken(token)) {
            if (stage.items.len > 0 and isFdPrefix(stage.items[stage.items.len - 1], token)) stage.items.len -= 1;
            skip_target = true;
            continue;
        }
        if (std.mem.eql(u8, token.raw, "|")) {
            try stages.append(ctx.arena, try stage.toOwnedSlice(ctx.arena));
            continue;
        }
        if (isSeparator(token.raw)) {
            try stages.append(ctx.arena, try stage.toOwnedSlice(ctx.arena));
            const walk = try runItem(ctx, stages.items, current);
            stages.clearRetainingCapacity();
            if (walk.veto != null) return .{ .veto = walk.veto, .cwd = current };
            current = walk.cwd;
            if (std.mem.eql(u8, token.raw, "(")) {
                try scopes.append(ctx.arena, current);
            } else if (std.mem.eql(u8, token.raw, ")") and scopes.items.len > 0) {
                current = scopes.items[scopes.items.len - 1];
                scopes.items.len -= 1;
            }
            continue;
        }
        try stage.append(ctx.arena, token);
    }
    try stages.append(ctx.arena, try stage.toOwnedSlice(ctx.arena));
    const walk = try runItem(ctx, stages.items, current);
    return .{ .veto = walk.veto, .cwd = walk.cwd };
}

fn runItem(ctx: Ctx, stages: []const []const ArgvToken, cwd: []const u8) Allocator.Error!Walk {
    if (stages.len == 1) return runStage(ctx, stages[0], cwd);
    for (stages) |stage| {
        const walk = try runStage(ctx, stage, cwd);
        if (walk.veto != null) return .{ .veto = walk.veto, .cwd = cwd };
    }
    return .{ .cwd = cwd };
}

fn runStage(ctx: Ctx, tokens: []const ArgvToken, cwd: []const u8) Allocator.Error!Walk {
    var index: usize = 0;
    while (index < tokens.len and isAssignment(tokens[index].raw)) index += 1;
    if (index >= tokens.len) return .{ .cwd = cwd };
    const name_token = tokens[index];
    if (isDynamic(name_token.raw) or name_token.value.len == 0) return .{ .cwd = cwd };
    var args: std.ArrayList([]const u8) = .empty;
    var dropped = false;
    for (tokens[index + 1 ..]) |token| {
        if (isDynamic(token.raw)) {
            dropped = true;
            continue;
        }
        if (token.value.len > 0) try args.append(ctx.arena, token.value);
    }
    return analyzeInvocation(ctx, try normalizeName(ctx.arena, name_token.value), args.items, dropped, cwd);
}

fn analyzeInvocation(ctx: Ctx, name: []const u8, args: []const []const u8, dropped: bool, cwd: []const u8) Allocator.Error!Walk {
    if (contains(&privilege_wrappers, name)) {
        const rest = dropLeadingOptions(args, &privilege_value_options);
        if (rest.len == 0) return .{ .cwd = cwd };
        return analyzeInvocation(ctx, try normalizeName(ctx.arena, rest[0]), rest[1..], dropped, cwd);
    }
    if (contains(&launch_wrappers, name)) {
        const rest = dropLaunchWrapperOperands(name, args);
        if (rest.len == 0) return .{ .cwd = cwd };
        return analyzeInvocation(ctx, try normalizeName(ctx.arena, rest[0]), rest[1..], dropped, cwd);
    }
    if (contains(&nested_shells, name)) {
        const payload = nestedPayload(args) orelse return .{ .cwd = cwd };
        if (ctx.depth >= max_nested_depth) return .{ .cwd = cwd };
        var nested = ctx;
        nested.depth += 1;
        const walk = try analyzeText(nested, payload, cwd);
        return .{ .veto = walk.veto, .cwd = cwd };
    }
    if (std.mem.eql(u8, name, "eval")) {
        if (args.len == 0 or ctx.depth >= max_nested_depth) return .{ .cwd = cwd };
        var nested = ctx;
        nested.depth += 1;
        const walk = try analyzeText(nested, try std.mem.join(ctx.arena, " ", args), cwd);
        return .{ .veto = walk.veto, .cwd = cwd };
    }
    if (std.mem.eql(u8, name, "busybox")) {
        if (args.len == 0 or std.mem.startsWith(u8, args[0], "-")) return .{ .cwd = cwd };
        return analyzeInvocation(ctx, try normalizeName(ctx.arena, args[0]), args[1..], dropped, cwd);
    }
    if (std.mem.eql(u8, name, "cd")) {
        var index: usize = 0;
        while (index < args.len and (std.mem.eql(u8, args[index], "-L") or std.mem.eql(u8, args[index], "-P") or std.mem.eql(u8, args[index], "--"))) index += 1;
        if (index >= args.len) return .{ .cwd = if (dropped) cwd else try normalizePath(ctx.arena, ctx.home) };
        if (std.mem.eql(u8, args[index], "-")) return .{ .cwd = cwd };
        return .{ .cwd = try resolveOperand(ctx, cwd, args[index]) };
    }
    if (std.mem.eql(u8, name, "git")) return analyzeGit(ctx, args, dropped, cwd);
    if (std.mem.eql(u8, name, "rm")) return analyzeRm(ctx, args, cwd);
    return .{ .cwd = cwd };
}

fn analyzeGit(ctx: Ctx, args: []const []const u8, dropped: bool, cwd: []const u8) Allocator.Error!Walk {
    if (dropped) return .{ .cwd = cwd };
    var git_cwd = cwd;
    var subcommand: ?[]const u8 = null;
    var subargs: []const []const u8 = &.{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-C")) {
            if (index + 1 >= args.len) return .{ .cwd = cwd };
            git_cwd = try resolveOperand(ctx, git_cwd, args[index + 1]);
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        subcommand = arg;
        subargs = args[index + 1 ..];
        break;
    }
    const sub = subcommand orelse return .{ .cwd = cwd };
    if (std.mem.eql(u8, sub, "clean")) return .{ .veto = try gitCleanVeto(ctx, subargs, git_cwd), .cwd = cwd };
    if (std.mem.eql(u8, sub, "reset")) return .{ .veto = gitResetVeto(ctx, subargs, git_cwd), .cwd = cwd };
    return .{ .cwd = cwd };
}

fn gitCleanVeto(ctx: Ctx, args: []const []const u8, git_cwd: []const u8) Allocator.Error!?[]const u8 {
    var force_count: usize = 0;
    var ignored = false;
    var dry_run = false;
    var interactive = false;
    var pathspecs: std.ArrayList([]const u8) = .empty;
    var options_ended = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!options_ended and std.mem.eql(u8, arg, "--")) {
            options_ended = true;
            continue;
        }
        if (!options_ended and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--force")) {
                force_count += 1;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--interactive")) {
                interactive = true;
            } else if (std.mem.eql(u8, arg, "--exclude")) {
                index += 1;
            }
            continue;
        }
        if (!options_ended and isShortFlags(arg)) {
            const exclude_at = std.mem.findScalar(u8, arg, 'e');
            const cluster = if (exclude_at) |at| arg[0..at] else arg;
            force_count += std.mem.count(u8, cluster, "f");
            if (std.mem.findScalar(u8, cluster, 'n') != null) dry_run = true;
            if (std.mem.findScalar(u8, cluster, 'i') != null) interactive = true;
            if (std.mem.findScalar(u8, cluster, 'x') != null or std.mem.findScalar(u8, cluster, 'X') != null) ignored = true;
            if (exclude_at) |at| {
                if (at == arg.len - 1) index += 1;
            }
            continue;
        }
        try pathspecs.append(ctx.arena, arg);
    }
    if (dry_run or interactive or force_count == 0) return null;
    if (!ignored) return null;
    if (pathspecs.items.len == 0) {
        return if (within(ctx.layout.comms, git_cwd)) git_clean_message else null;
    }
    const git_slot = slotDepth(git_cwd, ctx.layout.worktrees);
    for (pathspecs.items) |spec| {
        const abs = try resolveOperand(ctx, git_cwd, spec);
        if (git_slot) |depth| {
            if (depth >= 1) {
                if (slotDepth(abs, ctx.layout.worktrees)) |spec_depth| {
                    if (spec_depth >= 1) continue;
                }
            }
        }
        if (operandBucket(ctx.layout, abs) != null) return git_clean_message;
    }
    return null;
}

fn gitResetVeto(ctx: Ctx, args: []const []const u8, git_cwd: []const u8) ?[]const u8 {
    if (!contains(args, "--hard")) return null;
    if (!within(git_cwd, ctx.layout.main)) return null;
    if (within(git_cwd, ctx.layout.worktrees) and !std.mem.eql(u8, git_cwd, ctx.layout.worktrees)) return null;
    return git_reset_message;
}

fn analyzeRm(ctx: Ctx, args: []const []const u8, cwd: []const u8) Allocator.Error!Walk {
    var recursive = false;
    var operands: std.ArrayList([]const u8) = .empty;
    var options_ended = false;
    for (args) |arg| {
        if (!options_ended and std.mem.eql(u8, arg, "--")) {
            options_ended = true;
            continue;
        }
        if (!options_ended and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--recursive")) recursive = true;
            continue;
        }
        if (!options_ended and isShortFlags(arg)) {
            if (std.mem.findScalar(u8, arg, 'r') != null or std.mem.findScalar(u8, arg, 'R') != null) recursive = true;
            continue;
        }
        try operands.append(ctx.arena, arg);
    }
    for (operands.items) |operand| {
        const bucket = operandBucket(ctx.layout, try resolveOperand(ctx, cwd, operand)) orelse continue;
        if (bucket == .comms or recursive) {
            return .{ .veto = try std.fmt.allocPrint(ctx.arena, rm_format, .{operand}), .cwd = cwd };
        }
    }
    return .{ .cwd = cwd };
}

fn operandBucket(layout: Layout, abs: []const u8) ?Bucket {
    if (within(abs, layout.comms)) return .comms;
    if (within(layout.tower_root, abs)) return .tower_ancestor;
    if (!within(abs, layout.tower_root)) return null;
    if (slotDepth(abs, layout.worktrees)) |depth| {
        if (depth >= 2) return null;
    }
    return .protected_interior;
}

fn within(candidate: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, candidate, base) or std.mem.eql(u8, base, "/")) return true;
    return std.mem.startsWith(u8, candidate, base) and candidate.len > base.len and candidate[base.len] == '/';
}

fn slotDepth(path: []const u8, worktrees: []const u8) ?usize {
    if (std.mem.eql(u8, path, worktrees)) return 0;
    if (!within(path, worktrees)) return null;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, path[worktrees.len + 1 ..], '/');
    while (parts.next()) |part| {
        if (part.len > 0) count += 1;
    }
    return count;
}

fn resolveOperand(ctx: Ctx, cwd: []const u8, operand: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, operand, "~")) return normalizePath(ctx.arena, ctx.home);
    if (std.mem.startsWith(u8, operand, "~/")) return normalizePath(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.home, operand[2..] }));
    if (std.mem.startsWith(u8, operand, "/")) return normalizePath(ctx.arena, operand);
    return normalizePath(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ cwd, operand }));
}

fn normalizePath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, path, '/');
    while (pieces.next()) |piece| {
        if (piece.len == 0 or std.mem.eql(u8, piece, ".")) continue;
        if (std.mem.eql(u8, piece, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
            continue;
        }
        try parts.append(arena, piece);
    }
    return std.fmt.allocPrint(arena, "/{s}", .{try std.mem.join(arena, "/", parts.items)});
}

fn normalizeName(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var start = raw.len;
    while (start > 0 and raw[start - 1] != '/' and raw[start - 1] != '\\') start -= 1;
    const lower = try std.ascii.allocLowerString(arena, raw[start..]);
    if (std.mem.endsWith(u8, lower, ".exe")) return lower[0 .. lower.len - ".exe".len];
    return lower;
}

fn nestedPayload(args: []const []const u8) ?[]const u8 {
    var payload_index: ?usize = null;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (!isShortFlags(arg)) break;
        if (std.mem.findScalar(u8, arg, 'c') != null) payload_index = i + 1;
    }
    const index = payload_index orelse return null;
    if (index >= args.len) return null;
    return args[index];
}

fn dropLeadingOptions(args: []const []const u8, value_options: []const []const u8) []const []const u8 {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return args[index + 1 ..];
        if (std.mem.eql(u8, arg, "-") or !std.mem.startsWith(u8, arg, "-")) return args[index..];
        if (std.mem.findScalar(u8, arg, '=') == null and contains(value_options, arg)) index += 1;
    }
    return args[args.len..];
}

fn dropLaunchWrapperOperands(name: []const u8, args: []const []const u8) []const []const u8 {
    var rest = dropLeadingOptions(args, &wrapper_value_options);
    if (std.mem.eql(u8, name, "env")) {
        var index: usize = if (rest.len > 0 and std.mem.eql(u8, rest[0], "-")) 1 else 0;
        while (index < rest.len and isAssignment(rest[index])) index += 1;
        rest = rest[index..];
    }
    return rest;
}

fn isWordToken(token: ArgvToken) bool {
    return !isRedirectToken(token) and !isSeparator(token.raw) and !std.mem.eql(u8, token.raw, "|");
}

fn isRedirectToken(token: ArgvToken) bool {
    const raw = token.raw;
    if (raw.len == 0) return false;
    return raw[0] == '<' or raw[0] == '>' or std.mem.startsWith(u8, raw, "&>");
}

fn isSeparator(raw: []const u8) bool {
    return contains(&separators, raw);
}

fn isFdPrefix(prev: ArgvToken, op: ArgvToken) bool {
    if (prev.end != op.start or prev.raw.len == 0) return false;
    for (prev.raw) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn isAssignment(text: []const u8) bool {
    const eq = std.mem.findScalar(u8, text, '=') orelse return false;
    if (eq == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..eq]) |byte| {
        if (!isWordByte(byte)) return false;
    }
    return true;
}

fn isShortFlags(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |byte| {
        if (!std.ascii.isAlphabetic(byte)) return false;
    }
    return true;
}

fn isDynamic(raw: []const u8) bool {
    for (raw) |byte| {
        switch (byte) {
            '$', '`', '*', '?', '[', ']', '{', '}' => return true,
            else => {},
        }
    }
    return false;
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.find(u8, text[start..], word)) |offset| {
        const at = start + offset;
        const after = at + word.len;
        const before_ok = at == 0 or !isWordByte(text[at - 1]);
        const after_ok = after == text.len or !isWordByte(text[after]);
        if (before_ok and after_ok) return true;
        start = at + 1;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn testTarget(command: []const u8, cwd: []const u8) Target {
    return .{ .command = command, .cwd = cwd, .main_checkout = "/repo", .home = "/home/worker" };
}

test "tower Bash guard gates on rm and on git clean or reset only" {
    try std.testing.expect(needsGuard("rm -rf build"));
    try std.testing.expect(needsGuard("git -C /repo clean -fdx"));
    try std.testing.expect(needsGuard("git reset --hard"));
    try std.testing.expect(!needsGuard("git status"));
    try std.testing.expect(!needsGuard("echo cleaned trimmed"));
}

test "tower Bash guard vetoes rm of the protocol directory and a recursive removal of a worktree slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const protocol = (try analyze(arena, testTarget("rm .tower/comms/state.json", "/repo"))).?;
    try std.testing.expect(std.mem.find(u8, protocol, "tower protocol paths") != null);
    try std.testing.expect((try analyze(arena, testTarget("rm -r .tower/worktrees/wt-1", "/repo"))) != null);
    try std.testing.expect((try analyze(arena, testTarget("rm -rf .tower", "/repo"))) != null);
}

test "tower Bash guard lets a worker remove paths inside its own worktree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try analyze(arena, testTarget("rm -rf .tower/worktrees/wt-1/build", "/repo"))) == null);
    try std.testing.expect((try analyze(arena, testTarget("rm .tower/worktrees/wt-1/a.txt", "/repo"))) == null);
}

test "tower Bash guard follows cd and privilege wrappers before judging the operand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try analyze(arena, testTarget("cd .tower/comms && rm state.json", "/repo"))) != null);
    try std.testing.expect((try analyze(arena, testTarget("sudo rm -rf .tower/comms", "/repo"))) != null);
    try std.testing.expect((try analyze(arena, testTarget("cd /tmp && rm -rf .tower/comms", "/repo"))) == null);
    try std.testing.expect((try analyze(arena, testTarget("cd .tower/worktrees/wt-1 && rm -rf build", "/repo"))) == null);
}

test "tower Bash guard vetoes git reset --hard in the main checkout and allows it inside a worktree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reset = (try analyze(arena, testTarget("git reset --hard", "/repo"))).?;
    try std.testing.expect(std.mem.find(u8, reset, "git reset --hard") != null);
    try std.testing.expect((try analyze(arena, testTarget("git reset --hard", "/repo/.tower/worktrees/wt-1"))) == null);
}

test "tower Bash guard vetoes forced git clean over the protocol directory and allows a dry run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try analyze(arena, testTarget("git clean -fdx", "/repo"))) != null);
    try std.testing.expect((try analyze(arena, testTarget("git clean -fdx -- .tower/comms", "/repo"))) != null);
    try std.testing.expect((try analyze(arena, testTarget("git clean -nfdx", "/repo"))) == null);
}

test "tower Bash guard blocks a command it cannot tokenize when it mentions a guarded verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocked = (try analyze(arena, testTarget("rm -rf 'unterminated", "/repo"))).?;
    try std.testing.expect(std.mem.find(u8, blocked, "could not parse it safely") != null);
}
