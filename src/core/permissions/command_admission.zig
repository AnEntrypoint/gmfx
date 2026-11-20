const std = @import("std");
const auto_classifier = @import("auto_classifier.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const command_environment = @import("../execution/command_environment.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const sensitive_file = @import("sensitive_file.zig");
const types = @import("../shared/types.zig");

pub const CommandExecutionMode = enum {
    captured,
    tty,
};

pub const CommandContext = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,
    execution_mode: CommandExecutionMode = .captured,
    workspace_root: ?[]const u8 = null,
};

pub const AdmissionFingerprint = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,
    execution_mode: CommandExecutionMode = .captured,

    pub fn init(ctx: CommandContext) AdmissionFingerprint {
        return .{
            .command = ctx.command,
            .resolved_cwd = ctx.resolved_cwd,
            .target_os = ctx.target_os,
            .environment = ctx.environment,
            .execution_mode = ctx.execution_mode,
        };
    }

    pub fn matches(self: AdmissionFingerprint, ctx: CommandContext) bool {
        return std.mem.eql(u8, self.command, ctx.command) and
            std.mem.eql(u8, self.resolved_cwd, ctx.resolved_cwd) and
            self.target_os == ctx.target_os and
            self.environment.eql(ctx.environment) and
            self.execution_mode == ctx.execution_mode;
    }

    pub fn eql(self: AdmissionFingerprint, other: AdmissionFingerprint) bool {
        return self.matches(.{
            .command = other.command,
            .resolved_cwd = other.resolved_cwd,
            .target_os = other.target_os,
            .environment = other.environment,
            .execution_mode = other.execution_mode,
        });
    }
};

pub const ShellAuthorizationSource = enum {
    configured_rule,
    session_state,
    session_grant,
    interactive_once,
    interactive_always,
    auto_mode,
    auto_classifier,
    yolo,
    js_host,
};

pub const CommandExecutionAuthority = union(enum) {
    direct_only: AdmissionFingerprint,
    shell_allowed: struct {
        fingerprint: AdmissionFingerprint,
        source: ShellAuthorizationSource,
        grant_epoch: ?u64 = null,
    },
};

pub const VisionPathExecutionTarget = struct {
    canonical_path: []const u8,
    identity: file_mutation_contract.FileIdentity,
};

pub const VisionPathExecutionAuthority = struct {
    targets: []const VisionPathExecutionTarget,
};

pub const ToolExecutionAuthority = union(enum) {
    ordinary,
    run_command: CommandExecutionAuthority,
    file_mutation: file_mutation_contract.FileExecutionAuthorization,
    vision_paths: VisionPathExecutionAuthority,
};

pub const HumanApprovalProvenance = enum {
    none,
    once,
    always,
    always_tree,
};

pub const PermissionOutcome = struct {
    decision: types.ToolPermissionDecision = .policy_denied,
    execution_authority: ?ToolExecutionAuthority = null,
    human_approval: HumanApprovalProvenance = .none,
    denial_reason: ?types.ToolPermissionDenialReason = null,
    requirement: ?PermissionRequirement = null,
    rule_reason: ?[]const u8 = null,
    tool_failure: ?[]const u8 = null,
    feedback: ?[]const u8 = null,
    auto_review_result: ?auto_classifier.Result = null,
    auto_review_failure: ?auto_classifier.InvalidReason = null,
};

pub const PermissionRequirement = enum {
    configured_rule,
    approval_required,
};

pub const DefaultApproval = union(enum) {
    direct_only: AdmissionFingerprint,
    approval_required: command_effect.ApprovalReason,
};

pub fn defaultForRunCommand(
    alloc: std.mem.Allocator,
    command_ctx: CommandContext,
    permission_mode: types.PermissionMode,
) DefaultApproval {
    if (permission_mode == .ask and command_ctx.execution_mode != .tty and inWorkspaceGitWrite(command_ctx)) {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const bypass = manualBypassReason(arena_state.allocator(), command_ctx.command) catch
            return .{ .approval_required = .planning_failure };
        if (bypass == null) return .{ .direct_only = .init(command_ctx) };
    }
    const requires_shell_authority = command_ctx.execution_mode == .tty or
        switch (command_ctx.environment) {
            .user => true,
            .clean => permission_mode != .auto,
            .legacy, .workspace_clean => false,
        };
    if (requires_shell_authority) {
        return .{ .approval_required = .dynamic_shell };
    }
    if (permission_mode == .ask) {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const bypass = manualBypassReason(arena_state.allocator(), command_ctx.command) catch
            return .{ .approval_required = .planning_failure };
        if (bypass) |reason| return .{ .approval_required = reason };
    }
    var admission = command_effect.plan(
        alloc,
        command_ctx.command,
        command_ctx.resolved_cwd,
        false,
        command_ctx.target_os,
    ) catch return .{ .approval_required = .planning_failure };
    defer admission.deinit(alloc);

    return switch (admission) {
        .direct_read_only => .{ .direct_only = .init(command_ctx) },
        .approval_required => |reason| .{ .approval_required = reason },
    };
}

const in_workspace_git_write_subcommands = [_][]const u8{
    "add",    "commit", "restore",     "checkout", "switch", "stash", "tag", "branch",
    "merge",  "rebase", "cherry-pick", "reset",    "rm",     "mv",    "am",  "apply",
    "revert",
};
const git_shell_metacharacters = ";&|<>`$()\n\r";

fn inWorkspaceGitWrite(command_ctx: CommandContext) bool {
    const root = command_ctx.workspace_root orelse return false;
    if (!pathWithin(command_ctx.resolved_cwd, root)) return false;
    if (std.mem.indexOfAny(u8, command_ctx.command, git_shell_metacharacters) != null) return false;
    var words = std.mem.tokenizeAny(u8, command_ctx.command, " \t");
    const executable = words.next() orelse return false;
    if (!std.mem.eql(u8, executable, "git")) return false;
    const subcommand = words.next() orelse return false;
    return containsName(&in_workspace_git_write_subcommands, subcommand);
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    const trimmed_root = trimTrailingSlashes(root);
    if (!std.mem.startsWith(u8, path, trimmed_root)) return false;
    return path.len == trimmed_root.len or path[trimmed_root.len] == '/';
}

const max_nested_shell_depth = 4;

const privilege_wrappers = [_][]const u8{ "sudo", "doas" };
const privilege_value_options = [_][]const u8{
    "-u", "--user",       "-g", "--group",           "-h", "--host",       "-p", "--prompt",
    "-C", "--close-from", "-T", "--command-timeout", "-U", "--other-user", "-r", "--role",
    "-t", "--type",
};
const launch_wrappers = [_][]const u8{ "env", "command", "exec", "nohup", "builtin", "nice" };
const wrapper_value_options = [_][]const u8{
    "-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "-n", "--adjustment",
};
const nested_shells = [_][]const u8{ "sh", "bash", "dash", "zsh", "ksh", "ash" };
const simple_dangerous_commands = [_][]const u8{
    "shutdown",         "halt",          "poweroff", "reboot", "bcdedit", "diskpart", "format",
    "restart-computer", "stop-computer", "mkfs",     "wipefs",
};
const systemctl_value_options = [_][]const u8{ "-H", "--host", "-M", "--machine" };
const systemctl_dangerous_subcommands = [_][]const u8{ "poweroff", "reboot", "halt", "kexec" };
const dd_safe_device_targets = [_][]const u8{
    "/dev/null", "/dev/zero", "/dev/full", "/dev/random", "/dev/urandom", "/dev/stdin", "/dev/stdout", "/dev/stderr",
};
const rm_safe_temp_roots = [_][]const u8{ "/tmp", "/temp" };

const Scan = struct {
    depth: usize,
    critical_root: ?[]const u8,
};

pub fn dangerousShellCommand(arena: std.mem.Allocator, command: []const u8) !bool {
    return dangerousShellText(arena, command, .{ .depth = 0, .critical_root = null });
}

pub fn criticalRemovalShellCommand(arena: std.mem.Allocator, command: []const u8, workspace_root: []const u8) !bool {
    return dangerousShellText(arena, command, .{ .depth = 0, .critical_root = workspace_root });
}

fn dangerousShellText(arena: std.mem.Allocator, command: []const u8, scan: Scan) anyerror!bool {
    const argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    var simple_start: usize = 0;
    for (argv.tokens, 0..) |token, index| {
        if (!isCommandSeparator(token)) continue;
        if (try dangerousInvocation(arena, argv.tokens[simple_start..index], scan)) return true;
        simple_start = index + 1;
    }
    return dangerousInvocation(arena, argv.tokens[simple_start..], scan);
}

fn isCommandSeparator(token: command_lex.ArgvToken) bool {
    if (token.quoted) return false;
    for ([_][]const u8{ ";", "&&", "||", "|", "&", "(", ")", "{", "}" }) |operator| {
        if (std.mem.eql(u8, token.value, operator)) return true;
    }
    return false;
}

fn dangerousInvocation(arena: std.mem.Allocator, words: []const command_lex.ArgvToken, scan: Scan) anyerror!bool {
    var rest = words;
    while (rest.len > 0 and isEnvAssignment(rest[0].value)) rest = rest[1..];
    if (rest.len == 0) return false;
    const name = commandBasename(rest[0].value);
    const args = rest[1..];

    if (containsName(&privilege_wrappers, name)) {
        return dangerousInvocation(arena, argumentsAfterOptions(args, &privilege_value_options), scan);
    }
    if (containsName(&launch_wrappers, name)) {
        var inner = argumentsAfterOptions(args, &wrapper_value_options);
        if (std.ascii.eqlIgnoreCase(name, "env")) {
            while (inner.len > 0 and isEnvAssignment(inner[0].value)) inner = inner[1..];
        }
        return dangerousInvocation(arena, inner, scan);
    }
    if (containsName(&nested_shells, name)) {
        for (args, 0..) |arg, index| {
            if (std.mem.eql(u8, arg.value, "--")) break;
            if (!isShortOptionGroup(arg.value)) break;
            if (std.mem.indexOfScalar(u8, arg.value, 'c') == null or index + 1 >= args.len) continue;
            if (scan.depth >= max_nested_shell_depth) return false;
            return dangerousShellText(arena, args[index + 1].value, .{ .depth = scan.depth + 1, .critical_root = scan.critical_root });
        }
        return false;
    }
    if (scan.critical_root) |root| {
        return std.mem.eql(u8, name, "rm") and try dangerousRemoval(arena, args, root);
    }
    if (containsName(&simple_dangerous_commands, name) or std.ascii.startsWithIgnoreCase(name, "mkfs.")) return true;
    if (std.ascii.eqlIgnoreCase(name, "init") or std.ascii.eqlIgnoreCase(name, "telinit")) {
        for (args) |arg| {
            if (std.mem.eql(u8, arg.value, "0") or std.mem.eql(u8, arg.value, "6")) return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(name, "systemctl")) {
        const subcommands = argumentsAfterOptions(args, &systemctl_value_options);
        return subcommands.len > 0 and containsName(&systemctl_dangerous_subcommands, subcommands[0].value);
    }
    if (std.ascii.eqlIgnoreCase(name, "dd")) {
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg.value, "of=")) continue;
            const target = arg.value["of=".len..];
            if (std.mem.startsWith(u8, target, "/dev/") and !containsExactName(&dd_safe_device_targets, target)) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "rm")) return dangerousRemoval(arena, args, null);
    return false;
}

fn dangerousRemoval(arena: std.mem.Allocator, args: []const command_lex.ArgvToken, critical_root: ?[]const u8) !bool {
    var recursive = false;
    var force = false;
    var operands: std.ArrayList([]const u8) = .empty;
    var options_ended = false;
    for (args) |arg| {
        const value = arg.value;
        if (!options_ended and std.mem.eql(u8, value, "--")) {
            options_ended = true;
            continue;
        }
        if (options_ended) {
            try operands.append(arena, value);
        } else if (std.mem.eql(u8, value, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, value, "--force")) {
            force = true;
        } else if (isShortOptionGroup(value)) {
            if (std.mem.indexOfAny(u8, value, "rR") != null) recursive = true;
            if (std.mem.indexOfScalar(u8, value, 'f') != null) force = true;
        } else {
            try operands.append(arena, value);
        }
    }
    if (!recursive or !force) return false;
    if (operands.items.len == 0) return critical_root == null;
    for (operands.items) |operand| {
        if (critical_root) |root| {
            if (isCriticalRemovalOperand(operand, root)) return true;
        } else if (!isSafeTempRemovalOperand(operand)) {
            return true;
        }
    }
    return false;
}

const critical_home_operands = [_][]const u8{ "~", "$HOME", "${HOME}" };

fn isCriticalRemovalOperand(operand: []const u8, workspace_root: []const u8) bool {
    if (operand.len == 0) return false;
    var trimmed = trimTrailingSlashes(operand);
    if (std.mem.endsWith(u8, trimmed, "/*")) trimmed = trimTrailingSlashes(trimmed[0 .. trimmed.len - 1]);
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "*")) return true;
    if (containsExactName(&critical_home_operands, trimmed)) return true;
    const root = trimTrailingSlashes(workspace_root);
    return root.len > 0 and std.mem.eql(u8, trimmed, root);
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn isSafeTempRemovalOperand(operand: []const u8) bool {
    var segments = std.mem.splitScalar(u8, operand, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    for (rm_safe_temp_roots) |root| {
        if (std.mem.eql(u8, operand, root) or
            (std.mem.startsWith(u8, operand, root) and operand.len > root.len and operand[root.len] == '/')) return true;
    }
    return false;
}

const git_control_writers = [_][]const u8{ "rm", "mv", "cp", "tee" };

pub fn writesGitControlPath(arena: std.mem.Allocator, command: []const u8) !bool {
    const argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const tokens = argv.tokens;
    var command_start = true;
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (isCommandSeparator(token)) {
            command_start = true;
            continue;
        }
        if (!token.quoted and isWriteRedirection(token.value)) {
            if (index + 1 < tokens.len) {
                if (sensitive_file.isGitControlPath(tokens[index + 1].value)) return true;
                index += 1;
            }
            continue;
        }
        if (command_start and !isEnvAssignment(token.value)) {
            command_start = false;
            if (writesGitControlOperands(tokens[index..])) return true;
        }
    }
    return false;
}

const manual_bypass_wrappers = privilege_wrappers ++ launch_wrappers;
const git_redirecting_options = [_][]const u8{ "-C", "--git-dir", "--work-tree" };

pub fn manualBypassReason(arena: std.mem.Allocator, command: []const u8) !?command_effect.ApprovalReason {
    const argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .command_owned_input,
    };
    const tokens = argv.tokens;
    var command_start = true;
    for (tokens, 0..) |token, index| {
        if (isCommandSeparator(token)) {
            command_start = true;
            continue;
        }
        if (std.mem.indexOfAny(u8, token.raw, "$`") != null) return .dynamic_shell;
        if (!token.quoted and std.mem.indexOfAny(u8, token.raw, "*?[") != null) return .dynamic_shell;
        if (!command_start or isEnvAssignment(token.value)) continue;
        command_start = false;
        const name = commandBasename(token.value);
        if (containsName(&manual_bypass_wrappers, name)) return .process_or_system;
        const next = if (index + 1 < tokens.len) tokens[index + 1].value else continue;
        if (std.mem.eql(u8, name, "cd") and sensitive_file.isGitControlPath(next)) return .unsafe_git;
        if (std.mem.eql(u8, name, "git") and isGitRedirectingOption(next)) return .unsafe_git;
    }
    return null;
}

fn isGitRedirectingOption(value: []const u8) bool {
    if (containsName(&git_redirecting_options, value)) return true;
    return std.mem.startsWith(u8, value, "--git-dir=") or std.mem.startsWith(u8, value, "--work-tree=");
}

fn isWriteRedirection(value: []const u8) bool {
    const kind = command_lex.redirection_kind(value) orelse return false;
    return kind == .write_path or kind == .read_write_path;
}

fn writesGitControlOperands(words: []const command_lex.ArgvToken) bool {
    if (words.len == 0 or words[0].quoted) return false;
    if (!containsName(&git_control_writers, commandBasename(words[0].value))) return false;
    var index: usize = 1;
    while (index < words.len and !isCommandSeparator(words[index])) : (index += 1) {
        const word = words[index];
        if (!word.quoted and command_lex.redirection_kind(word.value) != null) {
            index += 1;
            continue;
        }
        if (word.value.len > 0 and word.value[0] == '-') continue;
        if (sensitive_file.isGitControlPath(word.value)) return true;
    }
    return false;
}

fn argumentsAfterOptions(
    args: []const command_lex.ArgvToken,
    value_options: []const []const u8,
) []const command_lex.ArgvToken {
    var index: usize = 0;
    while (index < args.len) {
        const value = args[index].value;
        if (std.mem.eql(u8, value, "--")) return args[index + 1 ..];
        if (value.len == 0 or value[0] != '-' or std.mem.eql(u8, value, "-")) return args[index..];
        if (std.mem.indexOfScalar(u8, value, '=') == null and containsExactName(value_options, value)) index += 1;
        index += 1;
    }
    return args[@min(index, args.len)..];
}

fn isShortOptionGroup(value: []const u8) bool {
    if (value.len < 2 or value[0] != '-') return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
    }
    return true;
}

fn isEnvAssignment(token: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    if (equals == 0) return false;
    if (std.ascii.isDigit(token[0])) return false;
    for (token[0..equals]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn commandBasename(value: []const u8) []const u8 {
    const index = std.mem.lastIndexOfAny(u8, value, "/\\") orelse return value;
    return value[index + 1 ..];
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    }
    return false;
}

fn containsExactName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "dangerous shell commands follow the Kimi command rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "shutdown now",
        "env FOO=1 sudo shutdown -h now",
        "mkfs.ext4 /dev/sdb1",
        "dd if=/dev/zero of=/dev/sdb",
        "printf ok && shutdown -h now",
        "bash -c 'rm -rf public'",
        "systemctl poweroff",
        "rm -rf public",
        "sudo rm -rf public",
        "rm -rf",
        "rm -rf /tmp/../etc",
    }) |command| {
        try std.testing.expect(try dangerousShellCommand(arena, command));
    }
    for ([_][]const u8{
        "touch generated.txt",
        "rm -rf /tmp/scratch",
        "sudo rm -rf /tmp/scratch",
        "dd if=/dev/urandom of=/dev/null",
        "git status",
        "bash ./script.sh",
        "systemctl status nginx",
        "kill 1234",
        "cd src && npm test",
    }) |command| {
        try std.testing.expect(!try dangerousShellCommand(arena, command));
    }
}

test "critical removal covers the filesystem root, home and the workspace root only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "/work/proj";
    for ([_][]const u8{
        "rm -rf /",
        "rm -rf /*",
        "rm -fr //",
        "rm -rf ~",
        "rm -rf $HOME",
        "rm -rf ${HOME}/",
        "rm -rf /work/proj",
        "rm -rf /work/proj/",
        "rm -rf /tmp/x /",
        "sudo rm -rf /",
        "bash -c 'rm -rf ~'",
    }) |command| {
        try std.testing.expect(try criticalRemovalShellCommand(arena, command, root));
    }
    for ([_][]const u8{
        "rm -rf public",
        "rm -rf /tmp/build",
        "rm -rf /work/proj/sub",
        "rm file",
        "rm -r -f",
        "rm -rf ''",
        "shutdown now",
        "mkfs.ext4 /dev/sdb1",
    }) |command| {
        try std.testing.expect(!try criticalRemovalShellCommand(arena, command, root));
    }
}

test "Bash writes into a git control path are found through redirection and file commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "echo x > .git/config",
        "echo x>.git/config",
        "echo x >> ./.git/hooks/pre-commit",
        "echo x >| .git/HEAD",
        "echo x &> .git/index",
        "rm .git/index",
        "rm -f -- .git/index",
        "mv staged .git/config",
        "cp template .git/config",
        "printf x | tee -a .git/config",
        "echo ok && rm -rf .git",
        "FOO=1 rm .git/index",
        "rm -f ./.git/index 2>/dev/null",
    }) |command| {
        try std.testing.expect(try writesGitControlPath(arena, command));
    }
    for ([_][]const u8{
        "cat .git/config",
        "git status",
        "echo rm .git/index",
        "echo '>' .git/config",
        "echo x > notes.txt",
        "echo x > .github/workflows/ci.yml",
        "rm -rf node_modules",
        "tee -a README.md",
    }) |command| {
        try std.testing.expect(!try writesGitControlPath(arena, command));
    }
}

test "normalized default emits direct-only only for a direct plan" {
    const direct_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .target_os = .macos,
    };
    const direct = defaultForRunCommand(std.testing.allocator, direct_ctx, .ask);
    switch (direct) {
        .direct_only => |fingerprint| try std.testing.expect(fingerprint.matches(direct_ctx)),
        .approval_required => return error.TestExpectedDirectOnly,
    }

    const write_ctx = CommandContext{
        .command = "touch created.txt",
        .resolved_cwd = "/workspace",
        .target_os = .macos,
    };
    try std.testing.expectEqual(
        command_effect.ApprovalReason.filesystem_write,
        defaultForRunCommand(std.testing.allocator, write_ctx, .ask).approval_required,
    );
}

test "explicit user environment always requires shell authority" {
    const user_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .target_os = .macos,
        .environment = .{ .user = "/bin/zsh" },
    };
    for ([_]types.PermissionMode{ .auto, .ask }) |permission_mode| {
        try std.testing.expectEqual(
            command_effect.ApprovalReason.dynamic_shell,
            defaultForRunCommand(std.testing.allocator, user_ctx, permission_mode).approval_required,
        );
    }
}

test "explicit clean environment is direct only in automatic mode" {
    const clean_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .target_os = .macos,
        .environment = .{ .clean = "/bin/zsh" },
    };
    const automatic = defaultForRunCommand(std.testing.allocator, clean_ctx, .auto);
    switch (automatic) {
        .direct_only => |fingerprint| try std.testing.expect(fingerprint.matches(clean_ctx)),
        .approval_required => return error.TestExpectedDirectOnly,
    }
    try std.testing.expectEqual(
        command_effect.ApprovalReason.dynamic_shell,
        defaultForRunCommand(std.testing.allocator, clean_ctx, .ask).approval_required,
    );
    var write_ctx = clean_ctx;
    write_ctx.command = "touch created.txt";
    try std.testing.expectEqual(
        command_effect.ApprovalReason.filesystem_write,
        defaultForRunCommand(std.testing.allocator, write_ctx, .auto).approval_required,
    );
}

test "manual mode approves in-workspace git writes and keeps remote, bypass and tty shapes asking" {
    const alloc = std.testing.allocator;
    const root = "/work/repo";
    const inside: CommandContext = .{
        .command = "git commit -m save",
        .resolved_cwd = "/work/repo/src",
        .target_os = .macos,
        .environment = .{ .user = "/bin/zsh" },
        .workspace_root = root,
    };
    try std.testing.expect(defaultForRunCommand(alloc, inside, .ask) == .direct_only);

    var outside = inside;
    outside.resolved_cwd = "/work/other";
    var push = inside;
    push.command = "git push origin main";
    var bypass = inside;
    bypass.command = "git -C .git commit -m save";
    var tty = inside;
    tty.execution_mode = .tty;
    var no_root = inside;
    no_root.workspace_root = null;
    var prefix_sibling = inside;
    prefix_sibling.resolved_cwd = "/work/repo-other";
    for ([_]CommandContext{ outside, push, bypass, tty, no_root, prefix_sibling }) |ctx| {
        try std.testing.expect(defaultForRunCommand(alloc, ctx, .ask) == .approval_required);
    }
}

test "manual bypass shapes need approval: cd into .git, git -C, variables, globs and wrappers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocked = [_][]const u8{ "cd .git && git status", "git -C .git log", "echo $HOME", "ls *.zig", "sudo ls", "env ls", "git --git-dir=.git status" };
    for (blocked) |command| {
        try std.testing.expect((try manualBypassReason(arena, command)) != null);
    }
    const allowed = [_][]const u8{ "git status", "ls src", "echo 'plain text'", "cd src && ls" };
    for (allowed) |command| {
        try std.testing.expectEqual(@as(?command_effect.ApprovalReason, null), try manualBypassReason(arena, command));
    }
}

test "manual mode admission sends a bypass shape to approval instead of a read-only plan" {
    const ctx: CommandContext = .{
        .command = "cd .git && git status",
        .resolved_cwd = "/work",
        .target_os = @import("builtin").target.os.tag,
    };
    switch (defaultForRunCommand(std.testing.allocator, ctx, .ask)) {
        .approval_required => |reason| try std.testing.expect(reason == .unsafe_git),
        .direct_only => return error.TestExpectedApproval,
    }
}

test "critical removal denies rm of the current directory and of a bare glob, not of a named path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const critical = [_][]const u8{ "rm -rf .", "rm -rf ./", "rm -rf ./*", "rm -rf *", "rm -fr *" };
    for (critical) |command| {
        try std.testing.expect(try criticalRemovalShellCommand(arena, command, "/work/ws"));
    }
    const ordinary = [_][]const u8{ "rm -rf build", "rm -rf src/*.zig" };
    for (ordinary) |command| {
        try std.testing.expect(!try criticalRemovalShellCommand(arena, command, "/work/ws"));
    }
}
